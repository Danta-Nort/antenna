// SPDX-License-Identifier: AGPL-3.0-only
//! LAN without internet (SPEC §18 "nodes in the same LAN without internet find each other and talk, mDNS enabled
//! manually"; SPEC §4; D-77, PROTOCOL §22).
//!
//! The test moves itself into a **separate network namespace** (`unshare -rn`): it has only `lo` with multicast, no
//! internet, no relay, and mDNS packets never reach the host network. Two real `antennad` daemons (relay off) are
//! paired, then restarted on new ports (the old ones are held by the test), so their saved addresses of each other are
//! stale and the nodes can find each other only through mDNS. Without `antenna lan on` the message does not arrive
//! (negative control); after it, it does.
//!
//! Run: `cargo test -p antenna-cli --test lan -- --nocapture` (from the workspace root). Without `unshare`/user
//! namespaces (CI with AppArmor) the test reports SKIP and checks nothing.

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    net::UdpSocket,
    process::Command,
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

const INNER: &str = "ANTENNA_TEST_IN_NETNS";

/// Rerun this test inside a new network namespace with `lo` and a multicast route; `true` means it ran and passed,
/// `false` means there is no namespace (SKIP).
fn run_in_netns(test: &str) -> bool {
    let probe = Command::new("unshare")
        .args(["-rn", "true"])
        .status()
        .is_ok_and(|s| s.success());
    if !probe {
        eprintln!("SKIP {test}: no `unshare -rn` (user/network namespaces) on this machine");
        return false;
    }
    let exe = std::env::current_exe().unwrap();
    let st = Command::new("unshare")
        .args([
            "-rn",
            "sh",
            "-c",
            "ip link set lo up && ip link set lo multicast on && ip route add 224.0.0.0/4 dev lo && exec \"$0\" \"$@\"",
        ])
        .arg(exe)
        .args([test, "--exact", "--nocapture", "--test-threads=1"])
        .env(INNER, "1")
        .status()
        .unwrap();
    assert!(st.success(), "inner run failed: {st:?}");
    true
}

fn port_of(c: &Value) -> u16 {
    c["local_addrs"]
        .as_array()
        .unwrap()
        .iter()
        .find_map(|a| a.as_str()?.strip_prefix("ip:"))
        .unwrap()
        .rsplit(':')
        .next()
        .unwrap()
        .parse()
        .unwrap()
}

fn lan_on(n: &Node) -> Value {
    let out = n.x_stdin(
        &["--json", "lan", "on", "--password-stdin"],
        &format!("{}\n", n.password),
    );
    assert!(out.status.success(), "{out:?}");
    last_json(&out.stdout)
}

#[test]
fn nodes_in_one_lan_without_internet_find_each_other() {
    if std::env::var_os(INNER).is_none() {
        run_in_netns("nodes_in_one_lan_without_internet_find_each_other");
        return;
    }
    // Inside: no interfaces other than lo.
    let ip = Command::new("ip").args(["-br", "link"]).output().unwrap();
    let links = String::from_utf8_lossy(&ip.stdout);
    assert_eq!(
        links.lines().count(),
        1,
        "only lo in the namespace: {links}"
    );

    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    let mut b = Node::new(root.path(), "bob", Net::Local);
    for n in [&mut a, &mut b] {
        n.start();
        n.init();
    }
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "before the move")["status"], "delivered");
    assert_eq!(b.inbox().len(), 1);
    // LAN is off by default.
    let st = a.json(&["lan"]);
    assert_eq!(
        (st["enabled"].as_bool(), st["listening"].as_bool()),
        (Some(false), Some(false)),
        "{st}"
    );

    // "Moving": the nodes restart on new ports, the old ones are held, so their saved addresses of each other are
    // stale.
    let old = [port_of(&a.contact("bob")), port_of(&b.contact("alice"))];
    for n in [&mut a, &mut b] {
        n.stop();
    }
    let _held: Vec<UdpSocket> = old
        .iter()
        .map(|p| UdpSocket::bind(("127.0.0.1", *p)).unwrap())
        .collect();
    for n in [&mut a, &mut b] {
        n.start();
        n.unlock();
    }
    let new = [port_of(&a.contact("bob")), port_of(&b.contact("alice"))];
    assert!(old[0] != new[0] && old[1] != new[1], "{old:?} → {new:?}");

    // Without LAN: no addresses, nothing arrives (negative control).
    let s = a.json(&["send", "bob", "hello over the LAN", "--wait", "4s"]);
    assert_eq!(s["status"], "queued", "{s}");
    std::thread::sleep(Duration::from_secs(2));
    assert!(b.inbox().is_empty(), "nothing can arrive without the LAN");

    // The owner turns LAN on at both nodes (password); the nodes find each other only through mDNS.
    let t = Instant::now();
    let st = lan_on(&b);
    assert_eq!(
        (st["enabled"].as_bool(), st["listening"].as_bool()),
        (Some(true), Some(true)),
        "{st}"
    );
    // Bob has nothing to deliver: he only listens and does not announce himself on the network.
    assert_eq!(st["links"][0]["beacon"], false, "{st}");
    let sa = lan_on(&a);
    assert_eq!(
        sa["links"][0]["beacon"], true,
        "alice has a message for bob: {sa}"
    );
    let mut got = Vec::new();
    while got.is_empty() {
        assert!(
            t.elapsed() < Duration::from_secs(60),
            "not found over mDNS in 60 s; alice: {}, bob: {}",
            a.json(&["lan"]),
            b.json(&["lan"])
        );
        std::thread::sleep(Duration::from_millis(200));
        got = b.inbox();
    }
    println!(
        "LAN: from `lan on` to the message at bob: {} ms",
        t.elapsed().as_millis()
    );
    assert_eq!(got[0]["text"], "hello over the LAN");
    if std::env::var_os("LAN_DEBUG").is_some() {
        for n in ["alice", "bob"] {
            let log =
                std::fs::read_to_string(root.path().join(format!("{n}.log"))).unwrap_or_default();
            for l in log
                .lines()
                .filter(|l| l.contains("lan") || l.contains("deliver") || l.contains("connect"))
            {
                println!("{n}: {l}");
            }
        }
    }
    // Bob has Alice's discovered address (new port); Alice had an announcement (or has already dropped it: the contact
    // is reachable).
    let sb = b.json(&["lan"]);
    let found = sb["links"][0]["found"].as_array().unwrap();
    assert!(
        found
            .iter()
            .any(|x| x.as_str() == Some(&format!("127.0.0.1:{}", new[0]))),
        "{sb}"
    );
    // And in the other direction.
    assert_eq!(b.send("alice", "and back")["status"], "delivered");
    assert_eq!(a.inbox()[0]["text"], "and back");

    // Turned off: no announcements and no discoveries.
    let off = b.json(&["lan", "off"]);
    assert_eq!(off["enabled"], false, "{off}");
    assert!(
        off["links"]
            .as_array()
            .unwrap()
            .iter()
            .all(|l| l["found"].as_array().unwrap().is_empty())
    );
}

/// As a user would have it: a relay is configured (pairing went through it), then there is no internet and the relay is
/// unreachable. Links come up without the relay (previously: a 20 s wait per link and a failure), and the nodes find
/// each other through mDNS.
#[test]
fn relay_gone_nodes_still_start_and_find_each_other_on_the_lan() {
    if std::env::var_os(INNER).is_none() {
        run_in_netns("relay_gone_nodes_still_start_and_find_each_other_on_the_lan");
        return;
    }
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let net = Net::LocalRelay(relay.url.clone());
    let mut a = Node::new(root.path(), "alice", net.clone());
    let mut b = Node::new(root.path(), "bob", net);
    for n in [&mut a, &mut b] {
        n.start();
        n.init();
    }
    pair(&a, &b, 4);
    assert_eq!(a.send("bob", "while online")["status"], "delivered");
    b.inbox();
    let old = [port_of(&a.contact("bob")), port_of(&b.contact("alice"))];
    // The internet is gone: no relay any more.
    drop(relay);
    for n in [&mut a, &mut b] {
        n.stop();
    }
    let _held: Vec<UdpSocket> = old
        .iter()
        .map(|p| UdpSocket::bind(("127.0.0.1", *p)).unwrap())
        .collect();
    let t = Instant::now();
    for n in [&mut a, &mut b] {
        n.start();
        n.unlock();
    }
    let unlock_ms = t.elapsed().as_millis();
    println!("LAN: both nodes started and unlocked without the relay in {unlock_ms} ms");
    assert!(
        unlock_ms < 15_000,
        "links must not wait 20 s for a dead relay"
    );
    assert_eq!(a.contact("bob")["trust"], 4);
    lan_on(&a);
    lan_on(&b);
    let t = Instant::now();
    assert_eq!(
        a.json(&["send", "bob", "no internet here", "--wait", "30s"])["status"],
        "delivered"
    );
    println!(
        "LAN: send → delivered without the relay in {} ms",
        t.elapsed().as_millis()
    );
    assert_eq!(b.inbox()[0]["text"], "no internet here");
}

/// Levels 1–2 are relay only (SPEC §4, Q-1): they do not use the LAN even when the mode is on.
#[test]
fn trust_1_2_links_are_never_on_the_lan() {
    if std::env::var_os(INNER).is_none() {
        run_in_netns("trust_1_2_links_are_never_on_the_lan");
        return;
    }
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::LocalRelay(relay.url.clone()));
    let mut b = Node::new(root.path(), "bob", Net::LocalRelay(relay.url.clone()));
    for n in [&mut a, &mut b] {
        n.start();
        n.init();
    }
    pair(&a, &b, 2);
    let st = lan_on(&a);
    assert_eq!(st["enabled"], true);
    assert!(
        st["links"].as_array().unwrap().is_empty(),
        "trust 2 is relay-only: {st}"
    );
}
