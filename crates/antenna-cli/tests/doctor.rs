// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna doctor` (D-96 phase 1) against real daemons, and the facts it reads: the home relay of each link endpoint
//! in `contacts` (`transport.relay`), through the test's local iroh relay (levels 1–2 connect only through a relay,
//! SPEC §4). The refused MCP host (`token_bound_elsewhere`) is checked next to the D-97 test in `agents.rs`.
//!
//! Run: `cargo test -p antenna-cli --test doctor -- --nocapture` (from the workspace root, so that `antennad` is
//! built).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    process::Command,
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `antenna --json doctor`: (exit code, the report).
fn doctor(n: &Node) -> (i32, Value) {
    let out = n.x(&["--json", "doctor"]);
    (out.status.code().unwrap_or(-1), last_json(&out.stdout))
}

fn findings(r: &Value, code: &str) -> Vec<Value> {
    r["findings"]
        .as_array()
        .unwrap_or_else(|| panic!("{r}"))
        .iter()
        .filter(|f| f["code"] == code)
        .cloned()
        .collect()
}

fn same_url(a: &Value, b: &str) -> bool {
    a.as_str()
        .is_some_and(|a| a.trim_end_matches('/') == b.trim_end_matches('/'))
}

/// A trust 2 link is relay only: `contacts` shows its endpoint connected to the local relay, and the doctor finds
/// nothing. Once the relay is gone, `connected` turns false within a bounded wait and the doctor names the contact,
/// its level and mode, the relay and iroh's error, and says that this link cannot connect at all.
///
/// Negative control (run once, 2026-10-05): with `transport::home_relay` reporting `connected: true` always, the wait
/// for `connected == false` timed out and the test failed; with the doctor's `relay_findings` skipping every link, the
/// `relay_unreachable` assertion failed.
#[test]
fn the_doctor_names_a_relay_only_link_whose_relay_is_gone() {
    let root = tempfile::tempdir().unwrap();
    let relay = LocalRelay::start();
    let mut a = Node::new(root.path(), "alice", Net::LocalRelay(relay.url.clone()));
    let mut b = Node::new(root.path(), "bob", Net::LocalRelay(relay.url.clone()));
    for n in [&mut a, &mut b] {
        n.start();
        n.init();
    }
    pair(&a, &b, 2);
    let c = a.contact("bob");
    assert_eq!(c["net_mode"], "relay_only", "{c}");
    let r = &c["transport"]["relay"];
    assert_eq!(r["connected"], true, "{c}");
    assert!(same_url(&r["url"], &relay.url), "{r} vs {}", relay.url);
    assert!(r.get("error").is_none(), "no error while connected: {r}");
    let (code, rep) = doctor(&a);
    assert_eq!(code, 0, "{rep}");
    assert_eq!(rep["state"], "unlocked", "{rep}");
    assert!(same_url(&rep["relay"], &relay.url), "{rep}");
    assert_eq!(
        rep["findings"],
        serde_json::json!([]),
        "the relay runs: {rep}"
    );
    assert!(rep["checked_ms"].as_u64().is_some_and(|t| t > 0), "{rep}");
    assert!(rep.get("skipped").is_none(), "{rep}");

    // The relay goes away.
    let url = relay.url.clone();
    let t = Instant::now();
    drop(relay);
    wait_until(
        "the link endpoint to lose its relay",
        Duration::from_secs(60),
        || a.contact("bob")["transport"]["relay"]["connected"] == false,
    );
    let lost_ms = t.elapsed().as_millis();
    // iroh records the failed reconnection attempts a moment later.
    wait_until("iroh's error", Duration::from_secs(30), || {
        a.contact("bob")["transport"]["relay"]["error"].is_string()
    });
    let r = a.contact("bob")["transport"]["relay"].clone();
    println!(
        "RELAY DOWN: connected=false after {lost_ms} ms, error after {} ms: {r}",
        t.elapsed().as_millis()
    );
    assert!(same_url(&r["url"], &url), "the home relay is kept: {r}");
    let err = r["error"].as_str().unwrap();
    assert!(
        !err.is_empty() && err.chars().count() <= 200 && !err.chars().any(char::is_control),
        "{err:?}"
    );

    let (code, rep) = doctor(&a);
    assert_eq!(code, 0, "the checks ran: {rep}");
    let f = findings(&rep, "relay_unreachable");
    assert_eq!(f.len(), 1, "{rep}");
    let f = &f[0];
    assert_eq!(f["contact"], "bob", "{f}");
    assert_eq!(
        f["severity"], "error",
        "a relay-only link cannot connect at all: {f}"
    );
    assert_eq!(f["facts"]["trust"], 2, "{f}");
    assert_eq!(f["facts"]["net_mode"], "relay_only", "{f}");
    assert_eq!(f["facts"]["relay_only"], true, "{f}");
    assert!(same_url(&f["facts"]["relay_url"], &url), "{f}");
    assert!(f["facts"]["error"].is_string(), "{f}");
    let detail = f["detail"].as_str().unwrap();
    assert!(
        detail.starts_with("bob (trust 2, relay only) cannot reach its relay")
            && detail.contains("cannot connect at all"),
        "{detail}"
    );
    assert!(f["fix"].as_str().is_some_and(|s| !s.is_empty()), "{f}");

    // The same for a person: one line per fact, the finding and what to do.
    let out = a.x(&["doctor"]);
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.starts_with("daemon: antennad ") && text.contains(", unlocked\nrelay: http://"),
        "{text}"
    );
    assert!(
        text.contains("relay_unreachable (error): bob (trust 2, relay only)"),
        "{text}"
    );
    assert!(text.contains("\n  what to do: "), "{text}");
}

/// The node's state comes first: a locked node is `keys_locked`, a node without keys `not_initialized`, no daemon at
/// the socket `daemon_down` with the "daemon unavailable" exit code (75, D-23) and the report printed anyway. Without
/// an owner session and without a terminal the link and agent checks are skipped with a reason, not failed.
#[test]
fn the_doctor_reports_the_node_state_and_what_it_could_not_check() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    let (code, rep) = doctor(&a);
    assert_eq!(code, 0, "{rep}");
    assert_eq!(rep["state"], "uninitialized", "{rep}");
    assert_eq!(findings(&rep, "not_initialized").len(), 1, "{rep}");

    a.init();
    let (code, rep) = doctor(&a);
    assert_eq!(code, 0, "{rep}");
    assert_eq!(rep["findings"], serde_json::json!([]), "{rep}");
    assert_eq!(rep["relay"], "disabled", "{rep}");

    // No session: the CLI runs under `sh`, so the test process's session (bound to it as the parent) does not apply,
    // and there is no terminal to ask for the password.
    let out = Command::new("sh")
        .clean_env()
        .arg("-c")
        .arg(r#""$X_BIN" --data-dir "$X_DIR" --json doctor </dev/null; e=$?; exit $e"#)
        .env("X_BIN", x_bin())
        .env("X_DIR", &a.dir)
        .output()
        .unwrap();
    let rep = last_json(&out.stdout);
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    assert_eq!(rep["state"], "unlocked", "{rep}");
    assert_eq!(rep["skipped"]["code"], "login_required", "{rep}");
    assert!(
        rep["skipped"]["detail"]
            .as_str()
            .is_some_and(|d| d.contains("antenna login")),
        "{rep}"
    );

    let out = a.x(&["lock"]);
    assert!(out.status.success(), "{out:?}");
    let (code, rep) = doctor(&a);
    assert_eq!(code, 0, "{rep}");
    assert_eq!(rep["state"], "locked", "{rep}");
    let f = findings(&rep, "keys_locked");
    assert_eq!(f.len(), 1, "{rep}");
    assert!(
        f[0]["fix"].as_str().unwrap().contains("antenna unlock"),
        "{f:?}"
    );
    let out = a.x(&["doctor"]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("keys_locked (error): "), "{text}");

    a.stop();
    let (code, rep) = doctor(&a);
    assert_eq!(code, 75, "{rep}");
    assert_eq!(rep["state"], "unreachable", "{rep}");
    assert_eq!(rep["daemon"], Value::Null, "{rep}");
    let f = findings(&rep, "daemon_down");
    assert_eq!(f.len(), 1, "{rep}");
    assert!(
        f[0]["detail"].as_str().unwrap().contains("antennad.sock"),
        "{f:?}"
    );
    let out = a.x(&["doctor"]);
    assert_eq!(out.status.code(), Some(75), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("daemon_down (error): "),
        "{out:?}"
    );
}
