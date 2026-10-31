// SPDX-License-Identifier: AGPL-3.0-only
//! Acceptance tests of v0.1 slice 1, "link" (SPEC §18 within the slice), fast mode: two (three) real `antennad` daemons
//! with separate data dirs, directly over 127.0.0.1 without a relay. The test through the n0 relay is `tests/relay.rs`
//! (#[ignore]).
//!
//! Run: `cargo test -p antenna-cli --test link -- --nocapture` (from the workspace root, so that `antennad` is built).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    io::{BufRead, BufReader},
    process::Stdio,
    sync::mpsc,
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

fn two_nodes(root: &std::path::Path) -> (Node, Node) {
    let mut a = Node::new(root, "alice", Net::Local);
    let mut b = Node::new(root, "bob", Net::Local);
    a.start();
    b.start();
    a.init();
    b.init();
    (a, b)
}

/// Facts, not code: the TLS group (rustls), the session and SPQR versions (libsignal state), the message version.
fn assert_pq_facts(c: &Value) {
    assert_eq!(c["transport"]["pairing_kx_group"], "X25519MLKEM768", "{c}");
    assert_eq!(c["transport"]["last_kx_group"], "X25519MLKEM768", "{c}");
    assert_eq!(c["e2e"]["session_version"], 4, "{c}");
    assert_eq!(c["e2e"]["pq_ratchet"], "NegotiationComplete(V1)", "{c}");
    assert_eq!(c["e2e"]["last_rx_version"], 4, "{c}");
    assert!(
        c["e2e"]["last_rx_pq_len"].as_u64().unwrap() > 0,
        "SPQR chunk in messages: {c}"
    );
}

#[test]
fn link_is_created_and_e2e_messages_flow_with_pq() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let p = pair(&a, &b, 3);
    println!(
        "PAIRING: link {}…, pairing_ms A={} B={}, wall (CLI start → both linked, incl. typing the code) {} ms",
        &p.link_id[..12],
        p.pairing_ms_a,
        p.pairing_ms_b,
        p.wall_ms
    );
    let ca = a.contact("bob");
    let cb = b.contact("alice");
    assert_eq!(ca["link_id"], cb["link_id"]);
    assert_eq!(ca["role"], "inviter");
    assert_eq!(cb["role"], "joiner");
    assert_eq!(ca["trust"], 3);
    assert_eq!(ca["net_mode"], "direct");
    // Pairwise: one side's own endpoint is the other side's peer_endpoint.
    assert_eq!(ca["local_endpoint"], cb["peer_endpoint"]);
    assert_eq!(cb["local_endpoint"], ca["peer_endpoint"]);

    let s1 = a.send("bob", "héllo, Bob 👋");
    assert_eq!(s1["status"], "delivered", "{s1}");
    assert_eq!(s1["lamport"], 1);
    let m = b.inbox();
    assert_eq!(m.len(), 1);
    assert_eq!(m[0]["text"], "héllo, Bob 👋");
    assert_eq!(m[0]["contact"], "alice");
    assert_eq!(m[0]["id"], s1["id"]);
    let s2 = b.send("alice", "hi Alice");
    assert_eq!(s2["status"], "delivered");
    // DAG: the reply references the head (A's message), lamport grows.
    assert_eq!(s2["parents"], serde_json::json!([s1["id"]]));
    assert_eq!(s2["lamport"], 2);
    let m = a.inbox();
    assert_eq!(m[0]["text"], "hi Alice");
    // A couple more round trips, so that SPQR completes negotiation in both directions.
    a.send("bob", "3");
    b.send("alice", "4");
    assert_eq!(b.inbox().len(), 1);
    assert_eq!(a.inbox().len(), 1);
    let ca = a.contact("bob");
    let cb = b.contact("alice");
    assert_pq_facts(&ca);
    assert_pq_facts(&cb);
    assert_eq!(ca["heads"], cb["heads"], "both sides agree on the head");
    assert_eq!(ca["lamport"], 4);
    println!(
        "FACTS: tls={} session_version={} spqr={} last_rx_version={}",
        ca["transport"]["last_kx_group"],
        ca["e2e"]["session_version"],
        ca["e2e"]["pq_ratchet"],
        ca["e2e"]["last_rx_version"]
    );
}

/// A link through the website (D-74): the node issues `https://antenna.contact/#…` and `antenna://pair#…` next to it;
/// one can join with any of the three forms (web address, `antenna://`, the historical `x://`): the body is the same,
/// and the prefix is not part of the cryptography.
#[test]
fn invite_link_is_a_web_address_and_every_form_joins() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    a.init();
    let mut joiners = Vec::new();
    for (name, form) in [("bob", "web"), ("carol", "app"), ("dave", "legacy")] {
        let mut n = Node::new(root.path(), name, Net::Local);
        n.start();
        n.init();
        let (mut inv, _) = invite(&a, 3, name, true);
        let created = inv
            .seen
            .iter()
            .find(|v| v["kind"] == "invite_created")
            .cloned()
            .unwrap();
        let web = created["link"].as_str().unwrap().to_string();
        let app = created["link_app"].as_str().unwrap().to_string();
        assert!(web.starts_with("https://antenna.contact/#"), "{web}");
        assert!(app.starts_with("antenna://pair#"), "{app}");
        let body = web.trim_start_matches("https://antenna.contact/#");
        assert_eq!(app.trim_start_matches("antenna://pair#"), body);
        let link = match form {
            "web" => web.clone(),
            "app" => app.clone(),
            _ => format!("x://pair#{body}"),
        };
        let mut j = join(&n, &link, 3, "alice");
        let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
        j.event("need_input", T);
        j.write_line(&sas);
        let (ca, ra) = inv.finish(T);
        let (cb, rb) = j.finish(T);
        assert_eq!((ca, cb), (0, 0), "{form}: {ra} / {rb}");
        assert_eq!(ra["link_id"], rb["link_id"]);
        joiners.push(n);
    }
    for (n, label) in joiners.iter().zip(["bob", "carol", "dave"]) {
        assert_eq!(a.send(label, "hi")["status"], "delivered");
        assert_eq!(n.inbox()[0]["text"], "hi");
    }
    // The link is not visible without the password: `pairings` without the password returns neither the web link nor
    // the app link.
    let (_p, _) = invite(&a, 3, "erin", false);
    let r = a.json(&["pairing"]);
    let list = r["invites"].as_array().unwrap();
    assert!(!list.is_empty(), "{r}");
    for i in list {
        assert_eq!(i["link"], "", "{i}");
        assert!(i.get("link_app").is_none(), "{i}");
    }
    let out = a.x_stdin(
        &["--json", "pairing", "--reveal", "--password-stdin"],
        &format!("{}\n", a.password),
    );
    assert!(out.status.success(), "{out:?}");
    let r = last_json(&out.stdout);
    let i = &r["invites"].as_array().unwrap()[0];
    assert!(
        i["link"]
            .as_str()
            .unwrap()
            .starts_with("https://antenna.contact/#"),
        "{i}"
    );
    assert!(
        i["link_app"]
            .as_str()
            .unwrap()
            .starts_with("antenna://pair#"),
        "{i}"
    );
}

#[test]
fn direct_latency_is_under_200ms() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    pair(&a, &b, 3);
    // Warm-up: the first message brings the connection up.
    let t = Instant::now();
    a.send("bob", "warmup");
    let cold = t.elapsed().as_millis();
    b.inbox();
    let n = 20;
    let mut e2e = Vec::new();
    let mut daemon = Vec::new();
    for i in 0..n {
        // B is already waiting (`antenna inbox --wait`) and A sends: time from starting `antenna send` to output at B.
        let mut w = b
            .cmd()
            .args(["--json", "inbox", "--wait", "--timeout", "10s"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        std::thread::sleep(Duration::from_millis(150)); // The waiter has connected to the daemon.
        let out = w.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut l = String::new();
            BufReader::new(out).read_line(&mut l).unwrap();
            tx.send((Instant::now(), l)).unwrap();
        });
        let t0 = Instant::now();
        let st = a
            .cmd()
            .args(["--json", "send", "bob", &format!("ping {i}"), "--wait", "0"])
            .output()
            .unwrap();
        assert!(st.status.success());
        let (t1, line) = rx.recv_timeout(Duration::from_secs(10)).expect("delivered");
        let _ = w.wait();
        let v: Value = serde_json::from_str(&line).unwrap();
        let msg = &v["messages"][0];
        assert_eq!(msg["text"], format!("ping {i}"));
        e2e.push(t1.duration_since(t0).as_millis());
        daemon.push((msg["received_ms"].as_u64().unwrap() - msg["ts"].as_u64().unwrap()) as u128);
    }
    let (emin, emed, emax) = stats(&mut e2e);
    let (dmin, dmed, dmax) = stats(&mut daemon);
    println!(
        "LATENCY direct 127.0.0.1, {n} msgs (debug build, deps -O2): \
         CLI send→inbox output min/median/max = {emin}/{emed}/{emax} ms; \
         daemon A envelope ts → B stored min/median/max = {dmin}/{dmed}/{dmax} ms; first (cold) send incl. connect = {cold} ms"
    );
    assert!(emed <= 200, "median latency {emed} ms > 200 ms");
    assert!(dmax <= 200, "daemon-to-daemon max {dmax} ms > 200 ms");
}

#[test]
fn wrong_sas_rejects_link_and_burns_invite() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let (mut inv, link) = invite(&a, 3, "bob", true);
    let mut j = join(&b, &link, 3, "alice");
    let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
    j.event("need_input", T);
    j.write_line(&wrong_code(&sas));
    let (cb, rb) = j.finish(T);
    let (ca, ra) = inv.finish(T);
    assert_eq!(cb, 1, "{rb}");
    assert_eq!(rb["error"], "sas_mismatch", "{rb}");
    assert_ne!(ca, 0, "{ra}");
    assert_eq!(ra["error"], "sas_mismatch", "{ra}");
    assert!(
        a.contacts().is_empty() && b.contacts().is_empty(),
        "no link on either side"
    );
    // The invite is burned: the link no longer works.
    let (c, r) = join(&b, &link, 3, "alice").finish(T);
    assert_eq!(c, 1);
    assert_eq!(r["error"], "invite_unavailable", "{r}");
}

#[test]
fn reusing_a_link_is_rejected() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let mut c = Node::new(root.path(), "carol", Net::Local);
    c.start();
    c.init();
    // 1) While the pairing session is running, a second connection with the same link is rejected.
    let (mut inv, link) = invite(&a, 3, "bob", false);
    let mut j = join(&b, &link, 3, "alice");
    let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
    let (ci, ri) = join(&c, &link, 3, "alice").finish(T);
    assert_eq!(ci, 1);
    assert_eq!(ri["error"], "invite_unavailable", "concurrent reuse: {ri}");
    // 2) Complete an honest pairing.
    j.event("need_input", T);
    j.write_line(&sas);
    inv.event("need_input", T);
    // A's owner types the code they read out (F-6: the CLI does not fill it in).
    inv.write_line(&sas);
    assert_eq!(inv.finish(T).0, 0);
    assert_eq!(j.finish(T).0, 0);
    // 3) After success the link is dead.
    let (cr, rr) = join(&c, &link, 3, "alice").finish(T);
    assert_eq!(cr, 1);
    assert_eq!(
        rr["error"], "invite_unavailable",
        "reuse after success: {rr}"
    );
    assert!(c.contacts().is_empty());
    assert_eq!(a.contacts().len(), 1);
}

#[test]
fn link_is_inactive_until_both_owners_confirm() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let (mut inv, link) = invite(&a, 3, "bob", false); // Without --confirm: A's owner decides.
    let mut j = join(&b, &link, 3, "alice");
    let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
    j.event("need_input", T);
    j.write_line(&sas); // B's owner entered the correct code.
    // An authenticated "B entered the code" arrived over the network…
    inv.event("peer_entered_code", T);
    inv.event("need_input", T);
    j.wait_for("waiting for A", T, |v| v["what"] == "owner_a_confirm");
    // …and it enables nothing: neither side has a link, sending is impossible.
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        a.contacts().is_empty(),
        "A must not activate on a network message"
    );
    assert!(
        b.contacts().is_empty(),
        "B must not activate before A's owner confirms"
    );
    let out = a.x(&["--json", "send", "bob", "too early"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(last_json(&out.stdout)["error"], "not_found");
    // A's owner declined (did not hear "match") → refusal on both sides, the invite is burned.
    inv.write_line("no");
    let (ca, ra) = inv.finish(T);
    let (cb, rb) = j.finish(T);
    assert_eq!(ca, 1, "{ra}");
    assert_eq!(ra["error"], "rejected");
    assert_eq!(cb, 1, "{rb}");
    assert_eq!(rb["error"], "rejected");
    assert!(a.contacts().is_empty() && b.contacts().is_empty());
    let (c, r) = join(&b, &link, 3, "alice").finish(T);
    assert_eq!((c, r["error"].as_str().unwrap()), (1, "invite_unavailable"));
}

#[test]
fn wrong_link_secret_five_times_burns_invite() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let (mut inv, link) = invite(&a, 3, "bob", true);
    // Replace the secret in the link (the second field): the attacker has the address but not the secret.
    let (pre, body) = link.split_at(link.rfind('#').unwrap() + 1);
    let mut parts: Vec<String> = body.split('.').map(str::to_string).collect();
    parts[1] = "a".repeat(52);
    let bad = format!("{pre}{}", parts.join("."));
    for i in 1..=5 {
        let (c, r) = join(&b, &bad, 3, "alice").finish(T);
        assert_eq!(c, 1);
        assert!(
            r["message"].as_str().unwrap().contains("auth") || r["error"] == "invite_unavailable",
            "attempt {i}: {r}"
        );
        inv.event("attempt_failed", T);
        inv.seen.retain(|v| v["kind"] != "attempt_failed");
    }
    let (ca, ra) = inv.finish(T);
    assert_eq!(ca, 1);
    assert_eq!(ra["error"], "invite_unavailable", "{ra}");
    // And the honest link no longer works.
    let (c, r) = join(&b, &link, 3, "alice").finish(T);
    assert_eq!((c, r["error"].as_str().unwrap()), (1, "invite_unavailable"));
    assert!(a.contacts().is_empty() && b.contacts().is_empty());
}

#[test]
fn unpaired_key_is_closed_right_after_handshake_direct() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    pair(&a, &b, 3);
    a.send("bob", "warm");
    let cb = b.contact("alice");
    let id_hex = cb["local_endpoint"].as_str().unwrap().to_string();
    let addr = cb["local_addrs"]
        .as_array()
        .unwrap()
        .iter()
        .find_map(|s| s.as_str().unwrap().strip_prefix("ip:").map(str::to_string))
        .expect("direct address");
    let rt = tokio::runtime::Runtime::new().unwrap();
    let res = rt.block_on(async move {
        use antenna_core::transport::{self, EpMode, EpParams, NetConfig, RelayConfig};
        use iroh::{EndpointAddr, SecretKey};
        let net = NetConfig {
            relay: RelayConfig::Disabled,
            bind_ip: Some("127.0.0.1".parse().unwrap()),
        };
        // Someone else's key, the same stack (PQ TLS), the correct link ALPN.
        let ep = transport::bind(
            &net,
            EpParams {
                secret: SecretKey::generate(),
                mode: EpMode::Direct,
                port: None,
                hooks: transport::PairGuard,
                alpns: vec![],
            },
            Duration::from_secs(5),
        )
        .await
        .unwrap();
        let bytes: [u8; 32] = data_encoding::HEXLOWER
            .decode(id_hex.as_bytes())
            .unwrap()
            .try_into()
            .unwrap();
        let id = iroh::PublicKey::from_bytes(&bytes).unwrap();
        let target = EndpointAddr::new(id).with_ip_addr(addr.parse().unwrap());
        let t = Instant::now();
        let r = match tokio::time::timeout(
            Duration::from_secs(10),
            ep.connect(target, antenna_proto::link::ALPN_LINK),
        )
        .await
        {
            Err(_) => "connect timeout".to_string(),
            Ok(Err(e)) => format!("connect refused after {:?}: {e}", t.elapsed()),
            Ok(Ok(conn)) => {
                // TLS succeeded; there must be no application data: the connection is closed with code 403.
                let req = antenna_proto::to_cbor(&antenna_proto::link::LinkRequest::Hello {
                    addrs: Default::default(),
                })
                .unwrap();
                let app = async {
                    let (mut s, mut r) = conn.open_bi().await.map_err(|e| e.to_string())?;
                    transport::write_frame(&mut s, &req)
                        .await
                        .map_err(|e| e.to_string())?;
                    transport::read_frame(&mut r, 1024)
                        .await
                        .map_err(|e| e.to_string())
                };
                let app_result = tokio::time::timeout(Duration::from_secs(5), app).await;
                let reason = conn.closed().await;
                format!(
                    "handshake done, then closed after {:?}: {reason}; app data: {:?}",
                    t.elapsed(),
                    app_result.map(|r| r.is_ok())
                )
            }
        };
        ep.close().await;
        r
    });
    println!("UNPAIRED direct: {res}");
    assert!(
        res.contains("403") || res.contains("refused"),
        "unpaired key must be closed with 403 right after handshake: {res}"
    );
    assert!(
        !res.contains("app data: Ok(true)"),
        "no application data for unpaired key: {res}"
    );
    // The paired contact keeps working.
    assert_eq!(a.send("bob", "still works")["status"], "delivered");
}

#[test]
fn sessions_survive_restart_of_both_daemons_and_offline_queue_drains() {
    let root = tempfile::tempdir().unwrap();
    let (mut a, mut b) = two_nodes(root.path());
    pair(&a, &b, 3);
    a.send("bob", "before restart");
    b.send("alice", "ack");
    assert_eq!(b.inbox().len(), 1);
    assert_eq!(a.inbox().len(), 1);
    // Restart both.
    a.stop();
    b.stop();
    a.start();
    b.start();
    // After a restart the keystore is locked (Q-4).
    let out = a.x(&["--json", "send", "bob", "x"]);
    assert_eq!(out.status.code(), Some(77));
    assert_eq!(last_json(&out.stdout)["error"], "locked");
    // Wrong password.
    let out = a.x_stdin(
        &["--json", "unlock", "--password-stdin"],
        "wrong-password\n",
    );
    assert_eq!(last_json(&out.stdout)["error"], "wrong_password");
    a.unlock();
    b.unlock();
    let s = a.send("bob", "after restart");
    assert_eq!(s["status"], "delivered", "{s}");
    let m = b.inbox_wait(10);
    assert_eq!(m[0]["text"], "after restart");
    assert_eq!(b.send("alice", "pong")["status"], "delivered");
    assert_eq!(a.inbox_wait(10)[0]["text"], "pong");
    assert_pq_facts(&a.contact("bob"));
    // B is offline: A queues, and after B starts the message is delivered by itself (retries with backoff).
    b.stop();
    let q = a.json(&["send", "bob", "while offline", "--wait", "500ms"]);
    assert_eq!(q["status"], "queued");
    assert_eq!(a.contact("bob")["outbox"], 1);
    b.start();
    b.unlock();
    let t = Instant::now();
    let m = b.inbox_wait(20);
    println!(
        "OFFLINE QUEUE: delivered {} ms after B unlocked",
        t.elapsed().as_millis()
    );
    assert_eq!(m[0]["text"], "while offline");
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(a.contact("bob")["outbox"], 0);
    // antenna lock closes access: sending is impossible until unlock.
    let out = b.x(&["--json", "lock"]);
    assert!(out.status.success());
    let out = b.x(&["--json", "send", "alice", "x"]);
    assert_eq!(out.status.code(), Some(77));
}

#[test]
fn second_init_is_refused_and_unknown_backend_is_honest() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    let out = a.x(&["--json", "init", "--key-backend", "systemd-creds"]);
    assert_eq!(out.status.code(), Some(69), "{out:?}");
    a.init();
    let out = a.x_stdin(
        &["--json", "init", "--password-stdin"],
        "another-password\n",
    );
    assert_eq!(last_json(&out.stdout)["error"], "already_initialized");
    let st = a.json(&["status"]);
    assert_eq!(st["state"], "unlocked");
    assert_eq!(st["relay"], "disabled");
}

#[test]
fn auto_confirm_is_refused_by_a_normal_daemon() {
    // `antenna invite --confirm` removes the protection of SPEC §6 item 9; a normal daemon does not accept it.
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.allow_auto_confirm = false;
    a.start();
    a.init();
    let out = a.owner(&["invite", "--trust", "3", "--confirm"]);
    assert_eq!(out.status.code(), Some(77), "{out:?}");
    assert_eq!(last_json(&out.stdout)["error"], "forbidden");
}

#[test]
fn lock_during_pairing_cancels_the_invite() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let (mut inv, link) = invite(&a, 3, "bob", false);
    let mut j = join(&b, &link, 3, "alice");
    inv.event("sas", T);
    j.event("need_input", T);
    assert!(a.x(&["lock"]).status.success());
    let (ca, ra) = inv.finish(T);
    assert_eq!(ca, 77, "{ra}");
    assert_eq!(ra["error"], "locked", "{ra}");
    j.close_stdin();
    let (cb, _) = j.finish(T);
    assert_ne!(cb, 0);
    a.unlock();
    assert!(a.contacts().is_empty() && b.contacts().is_empty());
}

/// D-95: once the joiner entered the code, the inviter's owner confirms with one action and no code: `yes` in the
/// `invite` dialog, or `antenna pairing confirm <id>` (with the password) for an invite nobody watches. A typed code is
/// still accepted and checked.
#[test]
fn the_inviter_confirms_without_retyping_once_the_joiner_entered_the_code() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let mut c = Node::new(root.path(), "carol", Net::Local);
    c.start();
    c.init();
    // 1) The `invite` dialog: the daemon offers the confirmation without the code; `yes` creates the link.
    let (mut inv, link) = invite(&a, 3, "bob", false);
    let mut j = join(&b, &link, 3, "alice");
    let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
    j.event("need_input", T);
    j.write_line(&sas);
    let ni = inv.wait_for("confirm", T, |v| {
        v["kind"] == "need_input" && v["what"] == "confirm"
    });
    assert_eq!(ni["confirm_without_code"], true, "{ni}");
    let listed = a.json(&["pairing"]);
    assert_eq!(
        listed["invites"][0]["confirm_without_code"], true,
        "{listed}"
    );
    inv.write_line("yes");
    let (ca, ra) = inv.finish(T);
    assert_eq!((ca, ra["type"].as_str()), (0, Some("linked")), "{ra}");
    assert_eq!(j.finish(T).0, 0);
    assert_eq!(
        a.send("bob", "linked with one click")["status"],
        "delivered"
    );

    // 2) An invite nobody watches: early is refused, after the joiner's entry the command needs only the password.
    let v = a.owner_json(&["invite", "--detach", "--trust", "3", "--label", "carol"]);
    let (id, link) = (
        v["id"].as_str().unwrap().to_string(),
        v["link"].as_str().unwrap().to_string(),
    );
    let mut j = join(&c, &link, 3, "alice");
    let v = a.owner_json(&["pairing", "--wait", "--timeout", "20s", "--reveal"]);
    let sas = v["invites"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["id"] == id.as_str())
        .and_then(|i| i["sas"].as_str())
        .unwrap_or_else(|| panic!("{v}"))
        .to_string();
    let out = a.owner(&["pairing", "confirm", &id]);
    assert_eq!(out.status.code(), Some(1), "{out:?}");
    assert!(
        last_json(&out.stdout)["message"]
            .as_str()
            .unwrap()
            .contains("nothing to confirm yet"),
        "{out:?}"
    );
    j.event("need_input", T);
    j.write_line(&sas);
    wait_until_phase(&a, &id, "needs_confirm");
    // The password is still asked: a wrong one confirms nothing.
    let out = a.x_stdin(
        &["--json", "pairing", "confirm", &id, "--password-stdin"],
        "wrong-password\n",
    );
    assert_eq!(last_json(&out.stdout)["error"], "wrong_password", "{out:?}");
    let v = a.owner_json(&["pairing", "confirm", &id]);
    assert_eq!(v["type"], "linked", "{v}");
    assert_eq!(j.finish(T).0, 0);
    assert_eq!(a.contacts().len(), 2);
}

/// D-95 against the formal model's F-4 (`formal/neg_nocode.pv`): with two invites showing codes at once, a spoken "it
/// matched" may be about either, so neither is confirmed without its code, not even after the other one ended (an
/// attacker can make it fail). The typed code still works.
#[test]
fn two_invites_with_codes_at_once_need_the_typed_code() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two_nodes(root.path());
    let mut c = Node::new(root.path(), "carol", Net::Local);
    c.start();
    c.init();
    let (mut inv1, link1) = invite(&a, 3, "bob", false);
    let (mut inv2, link2) = invite(&a, 3, "carol", false);
    let id1 = inv1.event("invite_created", T)["id"]
        .as_str()
        .unwrap()
        .to_string();
    let mut j1 = join(&b, &link1, 3, "alice");
    let mut j2 = join(&c, &link2, 3, "alice");
    let sas1 = inv1.event("sas", T)["code"].as_str().unwrap().to_string();
    inv2.event("sas", T);
    j2.event("need_input", T);
    // Carol walks away: her invite fails, but it did show its code while Bob's was open.
    j2.child.kill().unwrap();
    let _ = j2.child.wait();
    let (c2, r2) = inv2.finish(T);
    assert_ne!(c2, 0, "{r2}");
    j1.event("need_input", T);
    j1.write_line(&sas1);
    let ni = inv1.wait_for("confirm", T, |v| {
        v["kind"] == "need_input" && v["what"] == "confirm"
    });
    assert!(ni.get("confirm_without_code").is_none(), "{ni}");
    wait_until_phase(&a, &id1, "needs_confirm");
    let listed = a.json(&["pairing"]);
    let i1 = listed["invites"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["id"] == id1.as_str())
        .unwrap()
        .clone();
    assert!(i1.get("confirm_without_code").is_none(), "{i1}");
    // The separate command without the code is refused with `code_required`, and says what to do.
    let out = a.owner(&["pairing", "confirm", &id1]);
    assert_ne!(out.status.code(), Some(0), "{out:?}");
    let e = last_json(&out.stdout);
    assert_eq!(e["error"], "code_required", "{out:?}");
    assert!(e["message"].as_str().unwrap().contains("--code"), "{e}");
    // `yes` in the dialog is refused the same way, and the dialog asks for the code; the code links.
    inv1.write_line("yes");
    let rej = inv1.wait_for("rejected", T, |v| v["kind"] == "input_rejected");
    assert_eq!(rej["code"], "code_required", "{rej}");
    assert!(a.contacts().is_empty() && b.contacts().is_empty());
    // The code the owner read out, typed as the animals (the same number).
    inv1.write_line(&antenna_proto::sas::to_names(&sas1, false).unwrap());
    let (c1, r1) = inv1.finish(T);
    assert_eq!((c1, r1["type"].as_str()), (0, Some("linked")), "{r1}");
    assert_eq!(j1.finish(T).0, 0);
}

fn wait_until_phase(a: &Node, id: &str, phase: &str) {
    let t = Instant::now();
    loop {
        let v = a.json(&["pairing"]);
        if v["invites"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == id && i["phase"] == phase)
        {
            return;
        }
        assert!(t.elapsed() < T, "invite {id} never reached {phase}: {v}");
        std::thread::sleep(Duration::from_millis(100));
    }
}
