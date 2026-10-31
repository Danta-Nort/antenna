// SPDX-License-Identifier: AGPL-3.0-only
//! A contact's agents are visible by name (SPEC §5, §11; `docs/PROTOCOL.md` §21, D-75): an agent of A's owner writes to
//! contact B with its own key in this link, announced by A's link-root, so B sees a message from "alice /
//! claude-backend" (`via_agent` in history, the inbox and the agent wrapper, but not in the taint-free facts), plus
//! `peer_kind` and `agents` in contacts. A forged author without a link-root signature is caught by the unit tests of
//! `antenna_core::agentid` (the same checking code as on receive).
//!
//! Run: `cargo test -p antenna-cli --test peer_agents` (from the workspace root).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::time::{Duration, Instant};

use common::*;
use serde_json::{Value, json};

fn nodes(root: &std::path::Path, names: &[&str]) -> Vec<Node> {
    names
        .iter()
        .map(|n| {
            let mut x = Node::new(root, n, Net::Local);
            x.start();
            x.init();
            x
        })
        .collect()
}

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn history(n: &Node, contact: &str) -> Vec<Value> {
    n.json(&["history", contact, "--limit", "500"])["messages"]
        .as_array()
        .unwrap()
        .clone()
}

fn verified(n: &Node, contact: &str) -> Value {
    n.json(&["verify", contact])["status"].clone()
}

/// A: the owner and two agents write to B. B sees exactly who wrote, A sees which of its agents; history is verified,
/// and the check of one's own copy after a restart is clean (agent messages are in A's side chain).
#[test]
fn the_contact_sees_which_agent_wrote() {
    let root = tempfile::tempdir().unwrap();
    let mut ns = nodes(root.path(), &["alice", "bob"]);
    pair(&ns[0], &ns[1], 3);
    let (a, b) = (&ns[0], &ns[1]);
    // Before the first messages it is unknown who is on the other side.
    assert_eq!(b.contact("alice")["peer_kind"], "unknown");

    let claude = a.agent_add("claude-backend", &["--local-level", "0"]);
    let codex = a.agent_add("codex-infra", &["--local-level", "0"]);
    let s = a.agent_ok(&claude, &["send", "bob", "build is green"]);
    assert_eq!(s["status"], "delivered", "{s}");

    // B: "alice / claude-backend" in the owner's inbox and in history.
    let inbox = b.inbox();
    assert_eq!(inbox.len(), 1, "{inbox:?}");
    assert_eq!(inbox[0]["text"], "build is green");
    assert_eq!(inbox[0]["via_agent"], "claude-backend", "{}", inbox[0]);
    let c = b.contact("alice");
    assert_eq!(c["peer_kind"], "agent", "{c}");
    assert_eq!(c["agents"][0]["name"], "claude-backend", "{c}");
    assert_eq!(c["agents"][0]["state"], "active");

    // The second agent: its own announcement, its own key.
    a.agent_ok(&codex, &["send", "bob", "deploy done"]);
    // A's owner in person.
    assert_eq!(a.send("bob", "and this is me")["status"], "delivered");
    let h = history(b, "alice");
    let who: Vec<(String, Value)> = h
        .iter()
        .filter(|m| m["kind"] == "text")
        .map(|m| {
            (
                m["text"].as_str().unwrap().to_string(),
                m["via_agent"].clone(),
            )
        })
        .collect();
    assert_eq!(
        who,
        vec![
            ("build is green".to_string(), json!("claude-backend")),
            ("deploy done".to_string(), json!("codex-infra")),
            ("and this is me".to_string(), Value::Null),
        ],
        "{h:?}"
    );
    // Announcements are control messages and do not appear in the feed.
    assert!(h.iter().all(|m| m["kind"] != "control"), "{h:?}");
    // And for a human at the terminal: "alice / claude-backend".
    let out = b.x(&["history", "alice"]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.contains("alice / claude-backend build is green"),
        "{text}"
    );
    let out = b.x(&["contacts"]);
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.contains("their agents: claude-backend, codex-infra"),
        "{text}"
    );
    let c = b.contact("alice");
    assert_eq!(c["peer_kind"], "mixed", "{c}");
    let names: Vec<&str> = c["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["claude-backend", "codex-infra"]);

    // A sees which of its own agents wrote (outgoing).
    let ha = history(a, "bob");
    let mine: Vec<Value> = ha
        .iter()
        .filter(|m| m["kind"] == "text")
        .map(|m| m["via_agent"].clone())
        .collect();
    assert_eq!(
        mine,
        vec![json!("claude-backend"), json!("codex-infra"), Value::Null]
    );
    // B writes to A, and A's contact bob is the owner only (Bob's node understands announcements).
    assert_eq!(b.send("alice", "thanks")["status"], "delivered");
    wait_until("bob is a human for alice", T, || {
        a.contact("bob")["peer_kind"] == "human"
    });

    // B's agent reads the inbox: the wrapper names the contact's agent (SPEC §9 "through which agent").
    let reader = b.agent_add("reader", &["--local-level", "0"]);
    let r = b.agent_ok(&reader, &["inbox"]);
    let _ = r; // The agent sees only what arrived after it was created, so send one more, addressed to it (v6).
    a.agent_ok(
        &claude,
        &["send", "--to-agent", "reader", "bob", "one more"],
    );
    wait_until("agent inbox", T, || {
        let v = b.agent_ok(&reader, &["inbox"]);
        let m = &v["messages"];
        m.as_array().is_some_and(|m| {
            m.iter()
                .any(|x| x["text"] == "one more" && x["via_agent"] == "claude-backend")
        })
    });

    // History verification: agent messages are in A's side chain, the copies are equal.
    wait_until("history verified on both sides", T, || {
        verified(a, "bob")["state"] == "verified" && verified(b, "alice")["state"] == "verified"
    });
    assert_eq!(
        verified(a, "bob")["fingerprint"],
        verified(b, "alice")["fingerprint"]
    );
    // Restart both: the check of one's own copy (with agent keys in it) and verification are clean.
    for n in ns.iter_mut() {
        n.stop();
        n.start();
        n.unlock();
    }
    let (a, b) = (&ns[0], &ns[1]);
    wait_until("history verified after restart", T, || {
        verified(a, "bob")["state"] == "verified" && verified(b, "alice")["state"] == "verified"
    });
    // After the restart the agent writes with the same key too (no new announcement needed).
    let claude_after = claude;
    a.agent_ok(&claude_after, &["send", "bob", "after restart"]);
    let last = history(b, "alice").last().unwrap().clone();
    assert_eq!(
        (last["text"].as_str(), last["via_agent"].as_str()),
        (Some("after restart"), Some("claude-backend"))
    );
    assert_eq!(b.contact("alice")["agents"].as_array().unwrap().len(), 2);
}

/// An MCP agent replies to a contact: the contact sees the reply as from this agent; the contact's MCP agent sees
/// `via_agent`.
#[test]
fn mcp_agents_on_both_sides_see_each_other_by_name() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    let ta = a.agent_add("claude", &["--local-level", "0"]);
    let tb = b.agent_add("codex", &["--local-level", "0"]);
    let mut ma = Mcp::start(a, &ta);
    let mut mb = Mcp::start(b, &tb);
    let (e, v) = ma.call(
        "send_message",
        json!({"contact": "bob", "text": "ping from claude", "to_agent": "codex"}),
    );
    assert!(!e, "{v}");
    // A fact without text and without taint carries no agent name: the contact chose the name, it is their data (like a
    // file name, D-F-19).
    let (e, v) = mb.call("wait_for_message", json!({"timeout_secs": 10}));
    assert!(!e, "{v}");
    assert_eq!(v["pending"][0]["from"], "alice", "{v}");
    assert!(!v.to_string().contains("claude"), "{v}");
    let (e, v) = mb.call("read_inbox", json!({"contact": "alice"}));
    assert!(!e, "{v}");
    let m = &v["messages"][0];
    assert_eq!(
        (
            m["from"].as_str(),
            m["via_agent"].as_str(),
            m["text"].as_str()
        ),
        (Some("alice"), Some("claude"), Some("ping from claude")),
        "{m}"
    );
    assert_eq!(
        (m["to"].as_str(), m["to_agent"].as_str()),
        (Some("agent"), Some("codex")),
        "{m}"
    );
    // A reply without an address goes to whoever wrote the message it answers (v6, CONTROL §20): claude
    let (e, v) = mb.call(
        "send_message",
        json!({"contact": "alice", "text": "pong from codex"}),
    );
    assert!(!e, "{v}");
    assert_eq!(
        (v["to"].as_str(), v["to_agent"].as_str()),
        (Some("agent"), Some("claude")),
        "{v}"
    );
    let (_, v) = ma.call("read_inbox", json!({"contact": "bob"}));
    assert_eq!(v["messages"][0]["via_agent"], "codex", "{v}");
    assert_eq!(a.contact("bob")["peer_kind"], "agent");
    assert_eq!(b.contact("alice")["peer_kind"], "agent");
    ma.stop();
    mb.stop();
}

/// PG-20: removing an agent revokes its key in each link where it wrote. The contact lists the key as revoked; a new
/// agent under the same name writes with a new key and a new announcement, accepted and shown under that name; both
/// histories still verify (the revocation is an ordinary message of A's side chain).
#[test]
fn removing_an_agent_revokes_its_key_at_the_contact() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    let states = |n: &Node| -> Vec<(String, String)> {
        n.contact("alice")["agents"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| {
                (
                    x["name"].as_str().unwrap().to_string(),
                    x["state"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    };
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let s = a.agent_ok(&tok, &["send", "bob", "first"]);
    assert_eq!(s["status"], "delivered", "{s}");
    assert_eq!(states(b), vec![("claude".into(), "active".into())]);
    // An agent that never wrote to bob has no key there: nothing to revoke
    a.agent_add("quiet", &["--local-level", "0"]);
    let out = a.owner(&["agent", "remove", "quiet"]);
    assert!(out.status.success(), "{out:?}");

    let out = a.owner(&["agent", "remove", "claude"]);
    assert!(out.status.success(), "{out:?}");
    wait_until("the revocation at bob", T, || {
        states(b) == vec![("claude".to_string(), "revoked".to_string())]
    });
    assert!(
        a.log().contains("agent claude: its key in link"),
        "{}",
        a.log()
    );

    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let s = a.agent_ok(&tok, &["send", "bob", "second"]);
    assert_eq!(s["status"], "delivered", "{s}");
    assert_eq!(
        states(b),
        vec![
            ("claude".to_string(), "revoked".to_string()),
            ("claude".to_string(), "active".to_string())
        ]
    );
    let h = history(b, "alice");
    let texts: Vec<(&str, &str)> = h
        .iter()
        .filter(|m| m["kind"] == "text")
        .map(|m| {
            (
                m["text"].as_str().unwrap(),
                m["via_agent"].as_str().unwrap_or("-"),
            )
        })
        .collect();
    assert_eq!(
        texts,
        vec![("first", "claude"), ("second", "claude")],
        "{h:?}"
    );
    wait_until("history verified on both sides", T, || {
        verified(a, "bob")["state"] == "verified" && verified(b, "alice")["state"] == "verified"
    });
}

/// An older-version node for compatibility tests: `ANTENNA_LEGACY_BIN_DIR` is a directory with `antennad` and `antenna`
/// of release `v0.1.0-preview.1` (build: `git archive v0.1.0-preview.1 | tar -x -C <dir>` and `cargo build -p antennad
/// -p antenna-cli` there with a separate `CARGO_TARGET_DIR`).
fn legacy_node(root: &std::path::Path, name: &str) -> Option<Node> {
    let dir = std::env::var_os("ANTENNA_LEGACY_BIN_DIR")?;
    let mut n = Node::new(root, name, Net::Local);
    n.bin_dir = Some(dir.into());
    n.start();
    n.init();
    let v = n.x(&["--version"]);
    assert!(
        String::from_utf8_lossy(&v.stdout).contains("0.1.0-preview.1"),
        "{v:?}"
    );
    Some(n)
}

/// Compatibility with `0.1.0-preview.1` (PROTOCOL §3, §21): the old node does not understand the web link and joins
/// with `antenna://pair#…` from `link_app`; our agents send it regular messages (signed by link-root), nothing from
/// §21, and there is not a single refusal or `failed`; the new node accepts its `x://pair#…` link; history is verified.
#[test]
#[ignore = "needs ANTENNA_LEGACY_BIN_DIR with antennad/antenna of v0.1.0-preview.1"]
fn legacy_peer_links_by_the_app_link_and_gets_nothing_new() {
    let root = tempfile::tempdir().unwrap();
    let Some(l) = legacy_node(root.path(), "legacy") else {
        panic!("ANTENNA_LEGACY_BIN_DIR is not set");
    };
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    a.init();

    // A invites: the old CLI does not accept the web link, but accepts the app link.
    let (mut inv, web) = invite(&a, 3, "legacy", true);
    let app = inv
        .seen
        .iter()
        .find(|v| v["kind"] == "invite_created")
        .unwrap()["link_app"]
        .as_str()
        .unwrap()
        .to_string();
    let (c, r) = join(&l, &web, 3, "alice").finish(T);
    assert_ne!(c, 0, "preview.1 does not know the web link: {r}");
    let mut j = join(&l, &app, 3, "alice");
    let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
    j.event("need_input", T);
    j.write_line(&sas);
    let (ca, ra) = inv.finish(T);
    let (cl, rl) = j.finish(T);
    assert_eq!((ca, cl), (0, 0), "{ra} / {rl}");

    // A's agent writes to the old node: delivered, and the old node sees a regular message.
    let claude = a.agent_add("claude", &["--local-level", "0"]);
    let s = a.agent_ok(&claude, &["send", "legacy", "from the agent"]);
    assert_eq!(s["status"], "delivered", "{s}");
    assert_eq!(a.send("legacy", "from the owner")["status"], "delivered");
    let got: Vec<String> = l
        .inbox()
        .iter()
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(got, vec!["from the agent", "from the owner"]);
    // Our history remembers which agent wrote; the contact is "unknown" (it does not announce agents); no refusals.
    let h = history(&a, "legacy");
    assert_eq!(h[0]["via_agent"], "claude", "{h:?}");
    assert!(h[1].get("via_agent").is_none(), "{h:?}");
    let c = a.contact("legacy");
    assert_eq!(
        (c["failed"].as_u64(), c["outbox"].as_u64()),
        (Some(0), Some(0)),
        "{c}"
    );
    assert_eq!(c["peer_kind"], "unknown");
    // The old node writes to the new one.
    assert_eq!(l.send("alice", "hi from preview.1")["status"], "delivered");
    let m = a.inbox();
    assert_eq!(m[0]["text"], "hi from preview.1");
    assert!(m[0].get("via_agent").is_none());
    wait_until("history verified with the legacy node", T, || {
        verified(&a, "legacy")["state"] == "verified"
            && verified(&l, "alice")["state"] == "verified"
    });

    // The new node accepts the old node's link (`x://pair#…`).
    let (mut inv, link) = invite(&l, 3, "alice2", true);
    assert!(link.starts_with("x://pair#"), "{link}");
    let mut j = join(&a, &link, 3, "legacy2");
    let sas = inv.event("sas", T)["code"].as_str().unwrap().to_string();
    j.event("need_input", T);
    j.write_line(&sas);
    let (ca, ra) = inv.finish(T);
    let (cb, rb) = j.finish(T);
    assert_eq!((ca, cb), (0, 0), "{ra} / {rb}");
    assert_eq!(a.send("legacy2", "second link")["status"], "delivered");
}
