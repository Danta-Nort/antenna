// SPDX-License-Identifier: AGPL-3.0-only
//! Acceptance through the public n0 relays (needs internet), hence `#[ignore]`.
//!
//! Run (from the workspace root, so that `antennad` is built):
//! ```sh
//! cargo test -p antenna-cli --test relay -- --ignored --nocapture
//! ```
//! What is checked: pairing and messages in "relay only" mode (level 2: neither side discloses its IP), the TLS group
//! X25519MLKEM768 through the relay, Triple Ratchet v4 + SPQR, and that an unpaired key through the relay gets **no**
//! answer at all (incoming filter → Ignore before the handshake).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::time::{Duration, Instant};

use common::*;

#[test]
#[ignore = "needs internet access to n0 relays; run with --ignored"]
fn relay_only_link_messages_and_silent_drop_of_unpaired_key() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::RelayN0);
    let mut b = Node::new(root.path(), "bob", Net::RelayN0);
    a.start();
    b.start();
    a.init();
    b.init();
    let p = pair(&a, &b, 2);
    println!(
        "RELAY PAIRING: pairing_ms A={} B={}, wall {} ms",
        p.pairing_ms_a, p.pairing_ms_b, p.wall_ms
    );
    assert!(
        !p.link.contains("MTI3") && p.link.split('.').count() == 3,
        "with a relay the link carries no IP addresses: {}",
        p.link
    );
    let mut lat = Vec::new();
    for i in 0..5 {
        let t = Instant::now();
        let s = a.send("bob", &format!("via relay {i}"));
        assert_eq!(s["status"], "delivered", "{s}");
        lat.push(t.elapsed().as_millis());
    }
    let m = b.inbox();
    assert_eq!(m.len(), 5);
    assert_eq!(b.send("alice", "pong")["status"], "delivered");
    assert_eq!(a.inbox_wait(10)[0]["text"], "pong");
    let (mn, md, mx) = stats(&mut lat);
    println!(
        "RELAY LATENCY (antenna send --wait until delivered): min/median/max = {mn}/{md}/{mx} ms"
    );
    for (n, peer) in [(&a, "bob"), (&b, "alice")] {
        let c = n.contact(peer);
        assert_eq!(c["net_mode"], "relay_only", "{c}");
        assert_eq!(c["transport"]["last_kx_group"], "X25519MLKEM768", "{c}");
        assert_eq!(c["e2e"]["session_version"], 4, "{c}");
        let addrs = c["local_addrs"].as_array().unwrap();
        assert!(
            addrs
                .iter()
                .all(|a| a.as_str().unwrap().starts_with("relay:")),
            "relay-only endpoint must not expose IP: {c}"
        );
        let paths = c["transport"]["last_paths"].as_array().unwrap();
        assert!(
            paths.iter().all(|p| p.as_str().unwrap().contains("relay:")),
            "relay-only link must not use IP paths: {c}"
        );
        println!("RELAY FACTS {}: {}", n.name, c["transport"]);
    }

    // An unpaired key through the relay: no answer at all (timeout), not a refusal.
    let cb = b.contact("alice");
    let id_hex = cb["local_endpoint"].as_str().unwrap().to_string();
    let relay = cb["local_addrs"][0]
        .as_str()
        .unwrap()
        .strip_prefix("relay:")
        .unwrap()
        .to_string();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let res = rt.block_on(async move {
        use antenna_core::transport::{self, EpMode, EpParams, NetConfig, RelayConfig};
        use iroh::{EndpointAddr, SecretKey};
        let net = NetConfig {
            relay: RelayConfig::parse(&relay).unwrap(),
            bind_ip: None,
        };
        let ep = transport::bind(
            &net,
            EpParams {
                secret: SecretKey::generate(),
                mode: EpMode::RelayOnly,
                port: None,
                hooks: transport::PairGuard,
                alpns: vec![],
            },
            Duration::from_secs(20),
        )
        .await
        .unwrap();
        let bytes: [u8; 32] = data_encoding::HEXLOWER
            .decode(id_hex.as_bytes())
            .unwrap()
            .try_into()
            .unwrap();
        let target = EndpointAddr::new(iroh::PublicKey::from_bytes(&bytes).unwrap())
            .with_relay_url(relay.parse().unwrap());
        let t = Instant::now();
        let r = match tokio::time::timeout(
            Duration::from_secs(10),
            ep.connect(target, antenna_proto::link::ALPN_LINK),
        )
        .await
        {
            Err(_) => format!("no response, gave up after {:?}", t.elapsed()),
            Ok(Ok(_)) => "CONNECTED (must not happen)".into(),
            Ok(Err(e)) => format!("error after {:?}: {e}", t.elapsed()),
        };
        ep.close().await;
        r
    });
    println!("UNPAIRED via relay: {res}");
    assert!(res.starts_with("no response"), "{res}");
    assert_eq!(a.send("bob", "still works")["status"], "delivered");
}

#[test]
#[ignore = "needs internet access to n0 relays; run with --ignored"]
fn direct_mode_with_relay_reveals_no_ip_before_sas_and_works_after() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "carol", Net::RelayN0);
    let mut b = Node::new(root.path(), "dave", Net::RelayN0);
    a.start();
    b.start();
    a.init();
    b.init();
    let p = pair(&a, &b, 3);
    println!("DIRECT+RELAY PAIRING: wall {} ms", p.wall_ms);
    for i in 0..3 {
        assert_eq!(a.send("dave", &format!("m{i}"))["status"], "delivered");
    }
    assert_eq!(b.inbox().len(), 3);
    assert_eq!(b.send("carol", "pong")["status"], "delivered");
    assert_eq!(a.inbox_wait(10)[0]["text"], "pong");
    let c = a.contact("dave");
    assert_eq!(c["net_mode"], "direct");
    assert_eq!(c["transport"]["last_kx_group"], "X25519MLKEM768");
    println!("DIRECT+RELAY FACTS: {}", c["transport"]);
}
