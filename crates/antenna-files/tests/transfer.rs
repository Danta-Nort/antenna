// SPDX-License-Identifier: AGPL-3.0-only
//! Transfer (SPEC §10, §18): ciphertext as an iroh-blobs blob, per-link store and ACL, resumption after a drop,
//! substitution.
//!
//! The nodes are real iroh endpoints on 127.0.0.1 (the pairwise link endpoint, as in slice 1); blobs are `FsStore`s in
//! temporary directories.

mod common;

use std::time::{Duration, Instant};

use antenna_files::blobs::LinkBlobs;
use antenna_files::crypt::{FileSecret, StreamDecryptor, ciphertext_len};
use futures::StreamExt;
use iroh::protocol::Router;
use iroh_blobs::api::remote::GetProgressItem;
use iroh_blobs::protocol::{ChunkRangesSeq, GetRequest, ObserveRequest, PushRequest};

use common::{Synth, addr, ep, synth_hash};

/// A sender with one link: the link endpoint, the link store, a Router with the ACL.
struct Side {
    ep: iroh::Endpoint,
    blobs: LinkBlobs,
    router: Router,
}

async fn sender(dir: &std::path::Path, peer: iroh::EndpointId) -> Side {
    let ep = ep().await;
    let blobs = LinkBlobs::open(dir, peer).await.unwrap();
    let router = Router::builder(ep.clone())
        .accept(iroh_blobs::ALPN, blobs.protocol())
        .spawn();
    Side { ep, blobs, router }
}

async fn decrypt_all(
    blobs: &LinkBlobs,
    hash: iroh_blobs::Hash,
    secret: &FileSecret,
) -> antenna_files::Result<antenna_files::crypt::Plain> {
    use tokio::io::AsyncReadExt;
    let mut r = blobs.reader(hash);
    let mut d = StreamDecryptor::new(secret);
    let mut buf = vec![0u8; 1 << 20];
    let mut out = Vec::new();
    loop {
        let n = r.read(&mut buf).await.unwrap();
        if n == 0 {
            break;
        }
        out.clear();
        d.update(&buf[..n], &mut out)?;
    }
    out.clear();
    d.finish(&mut out)
}

#[tokio::test]
async fn small_file_roundtrip_store_holds_only_ciphertext() {
    let t = tempfile::tempdir().unwrap();
    let b_ep = ep().await;
    let a = sender(&t.path().join("a"), b_ep.id()).await;
    let secret = FileSecret::random();
    let marker = b"PLAINTEXT-MARKER-0123456789 must never reach the blob store";
    let mut plain = marker.repeat(5000);
    plain.extend_from_slice(b"end");
    let out = common::offered(&a.blobs, std::io::Cursor::new(plain.clone()), &secret).await;
    assert_eq!(out.blob_size, ciphertext_len(plain.len() as u64));
    assert_eq!(out.plain.blake3, *blake3::hash(&plain).as_bytes());

    let b = LinkBlobs::open(t.path().join("b"), a.ep.id())
        .await
        .unwrap();
    let conn = b_ep.connect(addr(&a.ep), iroh_blobs::ALPN).await.unwrap();
    let f = b
        .fetch(conn, out.blob, out.blob_size, "t", |_| {})
        .await
        .unwrap();
    assert_eq!(f.downloaded, out.blob_size);
    let p = decrypt_all(&b, out.blob, &secret).await.unwrap();
    assert_eq!(p, out.plain);
    // The store directories of both sides contain no plaintext.
    b.shutdown().await.unwrap();
    a.router.shutdown().await.unwrap();
    for side in ["a", "b"] {
        for e in walk(&t.path().join(side)) {
            let bytes = std::fs::read(&e).unwrap();
            assert!(
                !bytes.windows(16).any(|w| w == &marker[..16]),
                "plaintext found in {}",
                e.display()
            );
        }
    }
}

fn walk(p: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                out.push(p);
            }
        }
    }
    out
}

#[tokio::test]
async fn acl_blob_of_link_a_is_not_available_to_link_b_even_by_hash() {
    // Node S is linked with B (link 1) and with C (link 2): each link has its own endpoint and store (SPEC §10, Q-1).
    let t = tempfile::tempdir().unwrap();
    let b_ep = ep().await;
    let c_ep = ep().await;
    let s1 = sender(&t.path().join("s-link1"), b_ep.id()).await;
    let s2 = sender(&t.path().join("s-link2"), c_ep.id()).await;
    let secret = FileSecret::random();
    let x = common::offered(&s1.blobs, Synth::new(1, 300_000), &secret).await;
    // Something was sent in link 2 as well (its store is not empty).
    let y = common::offered(&s2.blobs, Synth::new(2, 1000), &FileSecret::random()).await;

    let c_store = LinkBlobs::open(t.path().join("c"), s2.ep.id())
        .await
        .unwrap();
    // 1) C knows hash X and asks for it over its own link (link 2's endpoint): refused, not a single byte.
    let conn = c_ep.connect(addr(&s2.ep), iroh_blobs::ALPN).await.unwrap();
    let r = tokio::time::timeout(
        Duration::from_secs(10),
        c_store.fetch(conn, x.blob, x.blob_size, "t", |_| {}),
    )
    .await;
    assert!(
        matches!(r, Ok(Err(_))),
        "C must not get blob X of link 1: {r:?}"
    );
    assert_eq!(c_store.local(x.blob).await.unwrap().0, 0);
    // 2) C goes to link 1's endpoint: the ACL rejects the connection (wrong EndpointId).
    let conn = c_ep.connect(addr(&s1.ep), iroh_blobs::ALPN).await.unwrap();
    let r = tokio::time::timeout(
        Duration::from_secs(10),
        c_store.fetch(conn, x.blob, x.blob_size, "t", |_| {}),
    )
    .await;
    assert!(
        matches!(r, Ok(Err(_))),
        "C must not get blob X via link 1 endpoint: {r:?}"
    );
    assert_eq!(c_store.local(x.blob).await.unwrap().0, 0);
    assert!(
        s1.blobs
            .acl_stats()
            .denied_connections
            .load(std::sync::atomic::Ordering::Relaxed)
            >= 1
    );
    // 3) C gets its own blob.
    let conn = c_ep.connect(addr(&s2.ep), iroh_blobs::ALPN).await.unwrap();
    c_store
        .fetch(conn, y.blob, y.blob_size, "t", |_| {})
        .await
        .unwrap();
    // 4) B gets X over link 1.
    let b_store = LinkBlobs::open(t.path().join("b"), s1.ep.id())
        .await
        .unwrap();
    let conn = b_ep.connect(addr(&s1.ep), iroh_blobs::ALPN).await.unwrap();
    b_store
        .fetch(conn, x.blob, x.blob_size, "t", |_| {})
        .await
        .unwrap();
    // 5) The same file in two links gives different blobs (STREAM salt): no dedup across links.
    let x2 = common::offered(&s2.blobs, Synth::new(1, 300_000), &secret).await;
    assert_ne!(x.blob, x2.blob);
    assert_eq!(x.plain, x2.plain);
    for s in [s1, s2] {
        s.router.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn only_offered_whole_blobs_are_served_push_observe_and_hashseq_are_refused() {
    let t = tempfile::tempdir().unwrap();
    let b_ep = ep().await;
    let a = sender(&t.path().join("a"), b_ep.id()).await;
    let offered = common::offered(&a.blobs, Synth::new(3, 50_000), &FileSecret::random()).await;
    // A blob that is in A's store but was not sent in this link (for example, one received from the contact).
    let private = a
        .blobs
        .store()
        .blobs()
        .add_bytes(b"not offered".to_vec())
        .await
        .unwrap();
    let b = LinkBlobs::open(t.path().join("b"), a.ep.id())
        .await
        .unwrap();

    // A blob that was not sent: refused.
    let conn = b_ep.connect(addr(&a.ep), iroh_blobs::ALPN).await.unwrap();
    assert!(
        b.fetch(conn.clone(), private.hash, 11, "t", |_| {})
            .await
            .is_err()
    );
    // A hash-seq request (children) for a sent blob: refused.
    let s = b
        .store()
        .remote()
        .execute_get(conn.clone(), GetRequest::all(offered.blob));
    let r = tokio::time::timeout(Duration::from_secs(10), s.complete()).await;
    assert!(
        matches!(r, Ok(Err(_))),
        "hash-seq request must be refused: {r:?}"
    );
    // observe (to learn whether a blob exists): refused.
    let mut obs = std::pin::pin!(
        b.store()
            .remote()
            .observe(conn.clone(), ObserveRequest::new(offered.blob))
    );
    let first = tokio::time::timeout(Duration::from_secs(10), obs.next())
        .await
        .unwrap();
    assert!(
        matches!(first, Some(Err(_)) | None),
        "observe must be refused: {first:?}"
    );
    // push into A's store: refused, A's store does not change.
    let pushed = b
        .store()
        .blobs()
        .add_bytes(vec![8u8; 200_000])
        .await
        .unwrap();
    // The push client in iroh-blobs 0.103 returns Ok without waiting for the server, so we judge by A's store.
    let _ = tokio::time::timeout(
        Duration::from_secs(10),
        b.store()
            .remote()
            .execute_push(
                conn.clone(),
                PushRequest::new(pushed.hash, ChunkRangesSeq::root()),
            )
            .complete(),
    )
    .await;
    for _ in 0..20 {
        assert!(
            !a.blobs.store().blobs().has(pushed.hash).await.unwrap(),
            "push wrote into our store"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        a.blobs
            .acl_stats()
            .denied_requests
            .load(std::sync::atomic::Ordering::Relaxed)
            >= 3
    );
    // A sent blob is served.
    b.fetch(conn, offered.blob, offered.blob_size, "t", |_| {})
        .await
        .unwrap();
    a.router.shutdown().await.unwrap();
}

#[tokio::test]
async fn tampered_provider_data_is_not_accepted() {
    // A byte substituted in the sender's data: bao verification at the recipient keeps the blob from becoming complete.
    let t = tempfile::tempdir().unwrap();
    let b_ep = ep().await;
    let a = sender(&t.path().join("a"), b_ep.id()).await;
    let out = common::offered(&a.blobs, Synth::new(4, 4 << 20), &FileSecret::random()).await;
    a.blobs.store().sync_db().await.unwrap();
    let hex = out.blob.to_hex().to_string();
    let f = walk(&t.path().join("a"))
        .into_iter()
        .find(|p| {
            p.file_name().unwrap().to_string_lossy().starts_with(&hex)
                && p.extension().is_some_and(|e| e == "data")
        })
        .expect("data file");
    let mut bytes = std::fs::read(&f).unwrap();
    bytes[3 * 1024 * 1024 + 17] ^= 0xFF;
    std::fs::write(&f, &bytes).unwrap();
    let b = LinkBlobs::open(t.path().join("b"), a.ep.id())
        .await
        .unwrap();
    let conn = b_ep.connect(addr(&a.ep), iroh_blobs::ALPN).await.unwrap();
    let r = b.fetch(conn, out.blob, out.blob_size, "t", |_| {}).await;
    assert!(r.is_err(), "tampered blob must not complete");
    let (local, complete) = b.local(out.blob).await.unwrap();
    assert!(!complete);
    assert!(local < out.blob_size);
    a.router.shutdown().await.unwrap();
}

/// Transfers `size` bytes with a connection drop at ~40 % and a restart of the recipient's store, then resumes.
async fn transfer_with_resume(size: u64) -> (Duration, u64, u64) {
    let base = std::env::var_os("X_FILES_BIG_TMP")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let t = tempfile::tempdir_in(base).unwrap();
    let need = 2 * ciphertext_len(size) + (256 << 20);
    if let Some(free) = common::free_bytes(t.path()) {
        assert!(free > need, "not enough disk: need {need}, free {free}");
    }
    let b_ep = ep().await;
    let a = sender(&t.path().join("a"), b_ep.id()).await;
    let secret = FileSecret::random();
    let t0 = Instant::now();
    let out = common::offered(&a.blobs, Synth::new(9, size), &secret).await;
    let enc_time = t0.elapsed();
    let expected_hash = synth_hash(9, size);
    assert_eq!(out.plain.blake3, expected_hash);

    let bdir = t.path().join("b");
    let t1 = Instant::now();
    {
        let b = LinkBlobs::open(&bdir, a.ep.id()).await.unwrap();
        b.store()
            .tags()
            .set(format!("in/{}", out.blob.to_hex()), out.blob)
            .await
            .unwrap();
        let conn = b_ep.connect(addr(&a.ep), iroh_blobs::ALPN).await.unwrap();
        let mut s = std::pin::pin!(b.store().remote().fetch(conn.clone(), out.blob).stream());
        let cut = out.blob_size * 4 / 10;
        while let Some(item) = s.next().await {
            match item {
                GetProgressItem::Progress(n) if n >= cut => {
                    conn.close(1u32.into(), b"simulated network drop");
                    break;
                }
                GetProgressItem::Progress(_) => {}
                GetProgressItem::Done(_) => panic!("finished before the cut"),
                GetProgressItem::Error(e) => panic!("{e:#}"),
            }
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
        let (had, complete) = b.local(out.blob).await.unwrap();
        assert!(!complete && had > 0, "had {had}");
        b.shutdown().await.unwrap(); // "daemon restart"
    }
    let b = LinkBlobs::open(&bdir, a.ep.id()).await.unwrap();
    let conn = b_ep.connect(addr(&a.ep), iroh_blobs::ALPN).await.unwrap();
    let f = b
        .fetch(conn, out.blob, out.blob_size, "t", |_| {})
        .await
        .unwrap();
    let xfer = t1.elapsed();
    assert!(
        f.had > 0 && f.downloaded < out.blob_size,
        "resume must fetch only the rest: {f:?}"
    );
    assert_eq!(f.had + f.downloaded, out.blob_size);
    let t2 = Instant::now();
    let p = decrypt_all(&b, out.blob, &secret).await.unwrap();
    let dec_time = t2.elapsed();
    assert_eq!(p.blake3, expected_hash, "hash must match after resume");
    assert_eq!(p.len, size);
    println!(
        "size {size} B: encrypt+import {enc_time:?}, transfer with drop+resume {xfer:?} (resumed from {} B, fetched {} B), decrypt+BLAKE3 {dec_time:?}",
        f.had, f.downloaded
    );
    b.shutdown().await.unwrap();
    a.router.shutdown().await.unwrap();
    (xfer, f.had, f.downloaded)
}

#[tokio::test]
async fn resume_after_drop_64mib() {
    transfer_with_resume(64 << 20).await;
}

/// SPEC §18: "A 1 GB file is transferred, resumes after a network drop, and the hash matches". Long-running (2 × 1 GiB
/// of disk in a temporary directory, removed afterwards); run explicitly: `cargo test --release -- --ignored one_gib`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn one_gib_with_drop_and_resume() {
    transfer_with_resume(1 << 30).await;
}
