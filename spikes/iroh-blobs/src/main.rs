// SPDX-License-Identifier: AGPL-3.0-only
//! Spike b): iroh-blobs 0.103 on top of iroh 1.3.
//! 1) builds together with iroh =1.3.0 (one iroh version in the tree, see `cargo tree -d`);
//! 2) FsStore → FsStore, 64 MiB, a drop at ~40%, store restart, resuming only what is missing;
//! 3) ACL at the provider: a request from an unpaired EndpointId is rejected (events: ClientConnected);
//! 4) substitution: we corrupt a byte in the provider's data file → the recipient does not accept the blob.

use std::{collections::HashSet, path::Path, time::{Duration, Instant}};

use anyhow::{Context, Result, anyhow, bail};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, endpoint::presets, protocol::Router};
use iroh_blobs::{
    BlobsProtocol, Hash,
    api::remote::GetProgressItem,
    provider::events::{AbortReason, ConnectMode, EventMask, EventSender, ProviderMessage},
    store::fs::FsStore,
};
use n0_future::StreamExt;

const SIZE: usize = 64 * 1024 * 1024;

async fn ep() -> Result<Endpoint> {
    Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Disabled)
        .bind_addr("127.0.0.1:0")?
        .bind()
        .await
        .map_err(|e| anyhow!("{e:#}"))
}

fn acl(allowed: HashSet<EndpointId>) -> EventSender {
    let mask = EventMask { connected: ConnectMode::Intercept, ..EventMask::DEFAULT };
    let (tx, mut rx) = EventSender::channel(32, mask);
    tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if let ProviderMessage::ClientConnected(msg) = msg {
                let ok = matches!(msg.endpoint_id, Some(id) if allowed.contains(&id));
                if !ok {
                    println!("  [provider ACL] reject {:?}", msg.endpoint_id.map(|i| i.fmt_short().to_string()));
                }
                msg.tx.send(if ok { Ok(()) } else { Err(AbortReason::Permission) }).await.ok();
            }
        }
    });
    tx
}

fn find_data_file(root: &Path, hash: &Hash) -> Option<std::path::PathBuf> {
    let hex = hash.to_hex().to_string();
    let mut stack = vec![root.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).ok()?.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.file_name()?.to_string_lossy().starts_with(&hex)
                && p.extension().map(|x| x == "data").unwrap_or(false)
            {
                return Some(p);
            }
        }
    }
    None
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let tmp = std::env::temp_dir().join(format!("x-spike-blobs-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp)?;

    // --- provider ---
    let prov_store = FsStore::load(tmp.join("prov")).await?;
    let data: Vec<u8> = (0..SIZE).map(|_| rand::random::<u8>()).collect();
    let expected = Hash::new(&data); // BLAKE3
    let tag = prov_store.blobs().add_bytes(data.clone()).await?;
    assert_eq!(tag.hash, expected);
    println!("provider: added {} MiB, blake3={}", SIZE >> 20, tag.hash.fmt_short());

    let recv_ep = ep().await?;
    let mallory_ep = ep().await?;
    let prov_ep = ep().await?;
    let prov_addr = EndpointAddr::new(prov_ep.id()).with_ip_addr(prov_ep.bound_sockets()[0]);
    let blobs = BlobsProtocol::new(&prov_store, Some(acl([recv_ep.id()].into_iter().collect())));
    let router = Router::builder(prov_ep).accept(iroh_blobs::ALPN, blobs).spawn();

    // --- 1. ACL: mallory knows the hash but is not paired ---
    {
        let st = FsStore::load(tmp.join("mallory")).await?;
        let conn = mallory_ep.connect(prov_addr.clone(), iroh_blobs::ALPN).await.map_err(|e| anyhow!("{e:#}"))?;
        let r = tokio::time::timeout(Duration::from_secs(10), st.remote().fetch(conn, tag.hash).complete()).await;
        let local = st.remote().local(tag.hash).await?.local_bytes();
        match r {
            Ok(Ok(_)) if local == SIZE as u64 => bail!("ACL: mallory downloaded the blob!"),
            Ok(Ok(_)) => println!("1. ACL OK: mallory got nothing (local_bytes={local})"),
            Ok(Err(e)) => println!("1. ACL OK: mallory fetch failed: {e:#} (local_bytes={local})"),
            Err(_) => println!("1. ACL OK: mallory fetch timed out (local_bytes={local})"),
        }
        st.shutdown().await?;
    }

    // --- 2. interrupted download + resume across store restart ---
    let recv_dir = tmp.join("recv");
    {
        let st = FsStore::load(&recv_dir).await?;
        let conn = recv_ep.connect(prov_addr.clone(), iroh_blobs::ALPN).await.map_err(|e| anyhow!("{e:#}"))?;
        let mut stream = std::pin::pin!(st.remote().fetch(conn.clone(), tag.hash).stream());
        let cut = (SIZE as u64) * 4 / 10;
        while let Some(item) = stream.next().await {
            match item {
                GetProgressItem::Progress(n) if n >= cut => {
                    conn.close(1u32.into(), b"simulated network drop");
                    println!("2a. simulated drop at {} MiB", n >> 20);
                    break;
                }
                GetProgressItem::Progress(_) => {}
                GetProgressItem::Done(_) => bail!("finished before cut"),
                GetProgressItem::Error(e) => bail!("unexpected error {e:#}"),
            }
        }
        drop(stream);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let local = st.remote().local(tag.hash).await?;
        println!("2b. after drop: local_bytes={} MiB complete={}", local.local_bytes() >> 20, local.is_complete());
        st.shutdown().await?; // "daemon restart"
    }
    {
        let st = FsStore::load(&recv_dir).await?;
        let before = st.remote().local(tag.hash).await?.local_bytes();
        let conn = recv_ep.connect(prov_addr.clone(), iroh_blobs::ALPN).await.map_err(|e| anyhow!("{e:#}"))?;
        let t = Instant::now();
        let stats = st.remote().fetch(conn, tag.hash).complete().await.map_err(|e| anyhow!("{e:#}"))?;
        let got = st.blobs().get_bytes(tag.hash).await.map_err(|e| anyhow!("{e:#}"))?;
        let ok = got.as_ref() == data.as_slice() && Hash::new(&got) == expected;
        println!(
            "2c. resume after store reload: had {} MiB, downloaded payload {} MiB in {:?}; content+blake3 match: {}",
            before >> 20,
            stats.payload_bytes_read >> 20,
            t.elapsed(),
            ok
        );
        if !ok || stats.payload_bytes_read >= SIZE as u64 {
            bail!("resume check failed");
        }
        st.shutdown().await?;
    }

    // --- 3. tampered provider data ---
    {
        let small: Vec<u8> = (0..(4 << 20)).map(|_| rand::random::<u8>()).collect();
        let t2 = prov_store.blobs().add_bytes(small.clone()).await?;
        prov_store.sync_db().await.ok();
        let f = find_data_file(&tmp.join("prov"), &t2.hash).context("data file of provider not found")?;
        let mut bytes = std::fs::read(&f)?;
        bytes[3 * 1024 * 1024 + 17] ^= 0xff; // flip one byte in the middle
        std::fs::write(&f, &bytes)?;
        println!("3a. corrupted 1 byte in provider file {}", f.display());
        let st = FsStore::load(tmp.join("recv2")).await?;
        let conn = recv_ep.connect(prov_addr.clone(), iroh_blobs::ALPN).await.map_err(|e| anyhow!("{e:#}"))?;
        let r = st.remote().fetch(conn, t2.hash).complete().await;
        let local = st.remote().local(t2.hash).await?;
        match r {
            Ok(_) if local.is_complete() => bail!("tampered blob accepted!"),
            Ok(_) => println!("3b. OK: fetch returned but blob incomplete (local {} KiB)", local.local_bytes() >> 10),
            Err(e) => println!(
                "3b. OK: tampered chunk rejected: {e:#}; verified prefix kept: {} KiB of {} KiB",
                local.local_bytes() >> 10,
                small.len() >> 10
            ),
        }
        st.shutdown().await?;
    }

    // Router::shutdown calls BlobsProtocol::shutdown, which shuts the store down itself
    // (a second prov_store.shutdown() => "Oneshot recv error: Sender closed").
    router.shutdown().await?;
    let _ = std::fs::remove_dir_all(&tmp);
    println!("DONE");
    Ok(())
}
