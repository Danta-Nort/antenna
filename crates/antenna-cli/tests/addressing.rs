// SPDX-License-Identifier: AGPL-3.0-only
//! Addressing, topics and batch approvals (v6; `docs/PROTOCOL.md` §23, `docs/CONTROL.md` §20, DECISIONS D-90…D-92).
//!
//! A message names who it is for: the other side's person, one of its agents, or everyone. The daemon, not the agent,
//! decides what an agent reads: never a message addressed to another agent or to the person (the link's wake agent
//! excepted, `tests/wake.rs`), messages to everyone only when the owner allows it. Topics are a field of the signed
//! message; history verification is unchanged.
//!
//! Run: `cargo test -p antenna-cli --test addressing` (from the workspace root; `cargo build -p antennad` first when
//! running a single package).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::time::{Duration, Instant};

use common::*;
use serde_json::{Value, json};

const T: Duration = Duration::from_secs(20);

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

fn texts(v: &Value) -> Vec<String> {
    v["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"].is_null() || m["kind"] == "text")
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect()
}

fn history(n: &Node, contact: &str) -> Vec<Value> {
    n.json(&["history", contact, "--limit", "500"])["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"] == "text")
        .cloned()
        .collect()
}

fn verified(n: &Node, contact: &str) -> Value {
    n.json(&["verify", contact])["status"].clone()
}

/// Alice has two agents, `builder` and `chatgpt`, plus `watcher`, which may read messages to everyone. Bob, his
/// agent `lead` and he himself write to each of them, to Alice in person and to everyone. Each agent reads only what is
/// addressed to it (and `watcher` also what is for everyone); nobody but Alice reads what is for her; facts and
/// history follow the same rule.
#[test]
fn an_agent_reads_only_what_is_addressed_to_it() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    let builder = a.agent_add("builder", &["--local-level", "0"]);
    let chatgpt = a.agent_add("chatgpt", &["--local-level", "0"]);
    let watcher = a.agent_add("watcher", &["--local-level", "0", "--everyone"]);
    let lead = b.agent_add("lead", &["--local-level", "0"]);

    let s = b.agent_ok(
        &lead,
        &[
            "send",
            "--to-agent",
            "builder",
            "alice",
            "build preview.4 on the Mac",
        ],
    );
    assert_eq!(
        (
            s["to"].as_str(),
            s["to_agent"].as_str(),
            s["addressed"].as_bool()
        ),
        (Some("agent"), Some("builder"), Some(true)),
        "{s}"
    );
    b.agent_ok(
        &lead,
        &[
            "send",
            "--to-agent",
            "chatgpt",
            "--topic",
            "Avatars",
            "alice",
            "draw three avatars",
        ],
    );
    // Bob in person: to Alice by default, the person
    let s = b.send("alice", "dinner at eight?");
    assert_eq!(s["to"], "person", "{s}");
    b.send_to_everyone("alice", "release is out");
    wait_until("four messages at alice", T, || history(a, "bob").len() == 4);

    // The owner sees all of them, each with its address and topic
    let h = history(a, "bob");
    let by_text = |t: &str| h.iter().find(|m| m["text"] == t).unwrap().clone();
    let m = by_text("build preview.4 on the Mac");
    assert_eq!(
        (
            m["to"].as_str(),
            m["to_agent"].as_str(),
            m["via_agent"].as_str()
        ),
        (Some("agent"), Some("builder"), Some("lead"))
    );
    let m = by_text("draw three avatars");
    assert_eq!(m["topic"]["title"], "Avatars", "{m}");
    assert_eq!(m["topic"]["id"].as_str().unwrap().len(), 32, "{m}");
    assert_eq!(by_text("dinner at eight?")["to"], "person");
    assert_eq!(by_text("release is out")["to"], "everyone");
    assert!(h.iter().all(|m| m["unread"] == true), "{h:?}");

    // Facts without text (`wait`) follow the rule too
    let w = a.agent_ok(&builder, &["wait", "--timeout", "1s"]);
    assert_eq!(w["pending"].as_array().unwrap().len(), 1, "{w}");
    // Each agent: only its own
    let v = a.agent_ok(&builder, &["inbox"]);
    assert_eq!(texts(&v), vec!["build preview.4 on the Mac"], "{v}");
    let m = &v["messages"][0];
    assert_eq!(
        (
            m["from"].as_str(),
            m["via_agent"].as_str(),
            m["to"].as_str(),
            m["to_agent"].as_str()
        ),
        (Some("bob"), Some("lead"), Some("agent"), Some("builder")),
        "{m}"
    );
    let v = a.agent_ok(&chatgpt, &["inbox"]);
    assert_eq!(texts(&v), vec!["draw three avatars"], "{v}");
    assert_eq!(v["messages"][0]["topic"]["title"], "Avatars", "{v}");
    let v = a.agent_ok(&watcher, &["inbox"]);
    assert_eq!(
        texts(&v),
        vec!["release is out"],
        "only what is for everyone: {v}"
    );
    // Nothing more for anyone: the message to the person never reaches an agent
    for t in [&builder, &chatgpt, &watcher] {
        let v = a.agent_ok(t, &["inbox"]);
        assert!(texts(&v).is_empty(), "{v}");
        let w = a.agent_ok(t, &["wait", "--timeout", "1s"]);
        assert!(w["pending"].as_array().unwrap().is_empty(), "{w}");
    }
    // History pages: the same rule (incoming by address, outgoing only the agent's own)
    let v = a.agent_ok(&builder, &["history", "bob", "--limit", "100"]);
    assert_eq!(texts(&v), vec!["build preview.4 on the Mac"], "{v}");
    let v = a.agent_ok(&chatgpt, &["history", "bob", "--limit", "100"]);
    assert_eq!(texts(&v), vec!["draw three avatars"], "{v}");
    // The owner's own conversation is not on an agent's pages either
    a.send("bob", "eight is fine");
    let v = a.agent_ok(&watcher, &["history", "bob", "--limit", "100"]);
    assert_eq!(texts(&v), vec!["release is out"], "{v}");

    // Turning `everyone` on needs the password; off does not
    let out = a.x(&["--json", "agent", "set", "chatgpt", "--everyone", "on"]);
    assert!(!out.status.success(), "{out:?}");
    let v = a.owner_json(&["agent", "set", "chatgpt", "--everyone", "on"]);
    let ag = v["agents"].as_array().unwrap();
    assert!(
        ag.iter()
            .any(|x| x["name"] == "chatgpt" && x["everyone"] == true),
        "{v}"
    );
    b.send_to_everyone("alice", "second release");
    let v = a.agent_ok(&chatgpt, &["inbox", "--wait", "--timeout", "10s"]);
    assert_eq!(texts(&v), vec!["second release"], "{v}");
    let v = a.json(&["agent", "set", "chatgpt", "--everyone", "off"]);
    assert_eq!(v["type"], "agents", "{v}");
    b.send_to_everyone("alice", "third release");
    wait_until("third release", T, || {
        history(a, "bob")
            .iter()
            .any(|m| m["text"] == "third release")
    });
    let v = a.agent_ok(&chatgpt, &["inbox"]);
    assert!(texts(&v).is_empty(), "everyone is off again: {v}");
    let v = a.json(&["agent", "list"]);
    let everyone: Vec<(String, bool)> = v["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| {
            (
                x["name"].as_str().unwrap_or_default().to_string(),
                x["everyone"].as_bool().unwrap(),
            )
        })
        .collect();
    assert!(everyone.contains(&("watcher".into(), true)), "{v}");
    assert!(everyone.contains(&("chatgpt".into(), false)), "{v}");
    assert!(everyone.contains(&("builder".into(), false)), "{v}");

    // `mark_read` with ids: exactly these
    let h = history(a, "bob");
    let unread: Vec<&Value> = h.iter().filter(|m| m["unread"] == true).collect();
    assert!(unread.len() >= 2, "{h:?}");
    let first = unread[0]["id"].as_str().unwrap();
    let before = a.contact("bob")["unread"].as_u64().unwrap();
    raw_owner(
        a,
        json!({"cmd": "mark_read", "contact": "bob", "up_to_seq": 0, "ids": [first]}),
    );
    assert_eq!(a.contact("bob")["unread"].as_u64().unwrap(), before - 1);
    let h = history(a, "bob");
    assert_eq!(
        h.iter().find(|m| m["id"] == first).unwrap()["unread"],
        Value::Null
    );
}

/// One request over a fresh owner connection with an owner session (held by the test): the final JSON line.
fn raw_owner(n: &Node, req: Value) -> Value {
    use std::io::{BufRead, BufReader, Write};
    let held = n.held_session();
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = json!({"hello": {"proto": "x-control/6", "role": "owner", "session": held.token}});
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", json!({ "req": req })).unwrap();
    let mut last = Value::Null;
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if v.get("ok").is_some() || v.get("err").is_some() {
            last = v;
            break;
        }
    }
    assert!(last.get("ok").is_some(), "{last}");
    drop(held);
    last["ok"].clone()
}

/// A reply without an address goes to whoever wrote the message it answers and stays in its topic; the topic is the
/// same on both sides and listed by `topics`; a plain `antenna send` stays without a topic.
#[test]
fn a_reply_goes_to_its_author_and_keeps_the_topic() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    let builder = a.agent_add("builder", &["--local-level", "0"]);
    let lead = b.agent_add("lead", &["--local-level", "0"]);

    // An agent that has read nothing writes to the person
    let s = a.agent_ok(&builder, &["send", "bob", "hello, anyone?"]);
    assert_eq!(
        (s["to"].as_str(), s["topic"].is_null()),
        (Some("person"), true),
        "{s}"
    );

    let s = b.agent_ok(
        &lead,
        &[
            "send",
            "--to-agent",
            "builder",
            "--topic",
            "Build preview.4",
            "alice",
            "start the build",
        ],
    );
    let topic = s["topic"].clone();
    assert_eq!(topic["title"], "Build preview.4", "{s}");
    a.agent_ok(&builder, &["inbox", "--wait", "--timeout", "10s"]);
    // The reply: to lead, in the same topic
    let r = a.agent_ok(&builder, &["send", "bob", "build is green"]);
    assert_eq!(
        (r["to"].as_str(), r["to_agent"].as_str(), &r["topic"]),
        (Some("agent"), Some("lead"), &topic),
        "{r}"
    );
    let v = b.agent_ok(&lead, &["inbox", "--wait", "--timeout", "10s"]);
    assert_eq!(texts(&v), vec!["build is green"], "{v}");
    let m = &v["messages"][0];
    assert_eq!(
        (m["via_agent"].as_str(), m["to_agent"].as_str(), &m["topic"]),
        (Some("builder"), Some("lead"), &topic),
        "{m}"
    );
    // `topic ""` leaves the topic; a new title starts a new topic; the same title continues it
    let r = a.agent_ok(&builder, &["send", "--topic", "", "bob", "off topic"]);
    assert!(r["topic"].is_null(), "{r}");
    assert_eq!(r["to_agent"], "lead", "still a reply to lead: {r}");
    let r = b.agent_ok(
        &lead,
        &["send", "--topic", "Build preview.4", "alice", "ship it"],
    );
    assert_eq!(r["topic"], topic, "the same title continues the topic: {r}");
    assert_eq!(r["to_agent"], "builder", "{r}");
    // The owner's plain message: the person, no topic (the window passes them explicitly)
    let s = a.send("bob", "I am watching");
    assert_eq!(
        (s["to"].as_str(), s["topic"].is_null()),
        (Some("person"), true),
        "{s}"
    );
    let s = a.json(&[
        "send",
        "--topic",
        "Build preview.4",
        "--to-agent",
        "lead",
        "bob",
        "good work",
    ]);
    assert_eq!(
        (s["to_agent"].as_str(), &s["topic"]),
        (Some("lead"), &topic),
        "{s}"
    );

    // Both sides list the topic with the same ID
    wait_until("topic at bob", T, || {
        b.json(&["topics", "alice"])["topics"]
            .as_array()
            .is_some_and(|t| t.len() == 1)
    });
    for (n, c) in [(a, "bob"), (b, "alice")] {
        let t = n.json(&["topics", c]);
        assert_eq!(t["topics"][0]["id"], topic["id"], "{t}");
        assert_eq!(t["topics"][0]["title"], "Build preview.4", "{t}");
    }
    // A topic ID that does not exist is refused, and so is an agent address without a name
    let bad = raw_owner_err(
        a,
        json!({"cmd": "send", "contact": "bob", "text": "x", "wait_ms": 0, "topic_id": "00".repeat(16)}),
    );
    assert_eq!(bad["code"], "not_found", "{bad}");
    let bad = raw_owner_err(
        a,
        json!({"cmd": "send", "contact": "bob", "text": "x", "wait_ms": 0, "to": "agent"}),
    );
    assert_eq!(bad["code"], "bad_request", "{bad}");
}

/// The same as [`raw_owner`] for a request that must fail: the `err` body.
fn raw_owner_err(n: &Node, req: Value) -> Value {
    use std::io::{BufRead, BufReader, Write};
    let held = n.held_session();
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = json!({"hello": {"proto": "x-control/6", "role": "owner", "session": held.token}});
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", json!({ "req": req })).unwrap();
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if let Some(e) = v.get("err") {
            return e.clone();
        }
        assert!(v.get("ok").is_none(), "expected an error: {v}");
    }
    panic!("no reply");
}

/// History verification over a mix of addressed, topic and plain messages in both directions: the copies are equal,
/// the fingerprints match, and after a restart the check of one's own copy (IDs recomputed from `core`) is clean.
#[test]
fn history_verification_holds_across_addressed_and_plain_messages() {
    let root = tempfile::tempdir().unwrap();
    let mut ns = nodes(root.path(), &["alice", "bob"]);
    pair(&ns[0], &ns[1], 3);
    {
        let (a, b) = (&ns[0], &ns[1]);
        let builder = a.agent_add("builder", &["--local-level", "0"]);
        let lead = b.agent_add("lead", &["--local-level", "0"]);
        a.send("bob", "plain from alice");
        b.send("alice", "plain from bob");
        b.agent_ok(
            &lead,
            &[
                "send",
                "--to-agent",
                "builder",
                "--topic",
                "T1",
                "alice",
                "task",
            ],
        );
        a.agent_ok(&builder, &["inbox", "--wait", "--timeout", "10s"]);
        a.agent_ok(&builder, &["send", "bob", "done"]);
        a.send_to_everyone("bob", "to everyone");
        b.json(&["send", "--topic", "T2", "alice", "owner topic"]);
        wait_until("history verified", T, || {
            verified(a, "bob")["state"] == "verified" && verified(b, "alice")["state"] == "verified"
        });
        assert_eq!(
            verified(a, "bob")["fingerprint"],
            verified(b, "alice")["fingerprint"]
        );
        assert_eq!(history(a, "bob").len(), 6);
        assert_eq!(history(b, "alice").len(), 6);
        // The same IDs on both sides, and each side's address of each message is the same
        let ha = history(a, "bob");
        let hb = history(b, "alice");
        for m in &ha {
            let o = hb
                .iter()
                .find(|x| x["id"] == m["id"])
                .expect("same id at bob");
            assert_eq!(
                (&m["to"], &m["to_agent"], &m["topic"]),
                (&o["to"], &o["to_agent"], &o["topic"]),
                "{m} {o}"
            );
        }
    }
    for n in ns.iter_mut() {
        n.stop();
        n.start();
        n.unlock();
    }
    let (a, b) = (&ns[0], &ns[1]);
    wait_until("history verified after restart", T, || {
        verified(a, "bob")["state"] == "verified" && verified(b, "alice")["state"] == "verified"
    });
    assert_eq!(
        verified(a, "bob")["fingerprint"],
        verified(b, "alice")["fingerprint"]
    );
}

/// Batch approvals: one password for the call, each request approved on its own and used up only by the request it
/// was made for; a wrong fingerprint fails that item alone; a wrong password approves nothing; deny-many needs no
/// password or session; agents have neither command.
#[test]
fn batch_approvals_check_the_password_once_and_each_binding() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    // An agent that read the owner's project (label 5) writing to a level 3 contact: every send needs approval
    let tok = a.agent_add("claude", &["--local-level", "5"]);
    let mut ids = Vec::new();
    let mut fps = Vec::new();
    for i in 0..5 {
        let (code, v) = a.agent(
            &tok,
            &["send", "bob", &format!("report part {i}"), "--wait", "0"],
        );
        assert_eq!(
            (code, v["error"].as_str()),
            (77, Some("approval_required")),
            "{v}"
        );
        ids.push(v["approval"]["id"].as_str().unwrap().to_string());
        fps.push(v["approval"]["fingerprint"].as_str().unwrap().to_string());
    }
    // Agents have neither command
    for line in [
        json!({"cmd": "approve_many", "items": [{"id": ids[0]}], "password": a.password}),
        json!({"cmd": "deny_many", "ids": [ids[0]]}),
        json!({"cmd": "agent_set", "name": "claude", "everyone": true}),
    ] {
        let (code, v) = agent_raw(a, &tok, line);
        assert_eq!(v["code"], "unknown_command", "{code} {v}");
    }
    // A wrong password: nothing is approved
    let wrong = raw_any(
        a,
        None,
        json!({"cmd": "approve_many", "items": [{"id": ids[0]}, {"id": ids[1]}], "password": "wrong"}),
    );
    assert_eq!(wrong["err"]["code"], "wrong_password", "{wrong}");
    // Over 3 requests in 10 minutes are "quiet" (SPEC §9): listed with `--all`
    let pending = a.json(&["approvals", "--all"]);
    assert!(
        ids.iter().all(|id| pending["approvals"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["id"] == id.as_str() && x["state"] == "pending")),
        "still pending: {pending}"
    );

    // One password, three requests (the second with a tampered fingerprint) and one unknown ID
    let r = raw_any(
        a,
        None,
        json!({"cmd": "approve_many", "password": a.password, "items": [
            {"id": ids[0], "fingerprint": fps[0]},
            {"id": ids[1], "fingerprint": "0000000000000000"},
            {"id": ids[2]},
            {"id": "nosuchid"},
        ]}),
    );
    let res = r["ok"]["results"]
        .as_array()
        .unwrap_or_else(|| panic!("{r}"));
    let state = |i: usize| -> (Option<&str>, Option<&str>) {
        (
            res[i]["approval"]["state"].as_str(),
            res[i]["error"]["code"].as_str(),
        )
    };
    assert_eq!(state(0), (Some("approved"), None), "{r}");
    assert_eq!(state(1), (None, Some("approval_mismatch")), "{r}");
    assert_eq!(state(2), (Some("approved"), None), "{r}");
    assert_eq!(state(3), (None, Some("not_found")), "{r}");
    // Each approval is used up by exactly its own request: another text does not take it
    let (code, v) = a.agent(&tok, &["send", "bob", "something else", "--wait", "0"]);
    assert_eq!(
        (code, v["error"].as_str()),
        (77, Some("approval_required")),
        "{v}"
    );
    let v = a.agent_ok(
        &tok,
        &["send", "bob", "report part 0", "--approval", &ids[0]],
    );
    assert_eq!(v["status"], "delivered", "{v}");
    let (code, v) = a.agent(
        &tok,
        &[
            "send",
            "bob",
            "report part 1",
            "--approval",
            &ids[1],
            "--wait",
            "0",
        ],
    );
    assert_eq!(
        (code, v["error"].as_str()),
        (75, Some("approval_pending")),
        "the tampered one stays pending: {v}"
    );
    let (code, v) = a.agent(
        &tok,
        &[
            "send",
            "bob",
            "report part 0",
            "--approval",
            &ids[2],
            "--wait",
            "0",
        ],
    );
    assert_eq!(
        (code, v["error"].as_str()),
        (1, Some("approval_mismatch")),
        "part 2's approval is not part 0's: {v}"
    );
    let v = a.agent_ok(&tok, &["send", "bob", "report part 2"]);
    assert_eq!(v["status"], "delivered", "found by its request hash: {v}");
    // Each approval is in the audit log on its own
    let log = a.json(&["log", "bob", "--limit", "200"]);
    let approved = log["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["decision"] == "approved_by_owner")
        .count();
    assert_eq!(approved, 2, "{log}");

    // Deny-many: no password and no session (a raw connection from the test process has no owner session)
    let r = raw_any(
        a,
        Some(false),
        json!({"cmd": "deny_many", "ids": [ids[1], ids[3], ids[4]]}),
    );
    let res = r["ok"]["results"]
        .as_array()
        .unwrap_or_else(|| panic!("{r}"));
    assert!(
        res.iter().all(|x| x["approval"]["state"] == "denied"),
        "{r}"
    );
    let pending = a.json(&["approvals"]);
    assert!(
        pending["approvals"].as_array().unwrap().is_empty(),
        "{pending}"
    );
    // The CLI: several IDs in one command
    let mut more = Vec::new();
    for i in 5..7 {
        let (_, v) = a.agent(
            &tok,
            &["send", "bob", &format!("report part {i}"), "--wait", "0"],
        );
        more.push(v["approval"]["id"].as_str().unwrap().to_string());
    }
    let v = a.owner_json(&["approve", &more[0], &more[1]]);
    assert_eq!(v["type"], "approvals_decided", "{v}");
    assert!(
        v["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|x| x["approval"]["state"] == "approved"),
        "{v}"
    );
}

/// A raw owner request: `session` `Some(false)` means without an owner session, `None` with a held one.
fn raw_any(n: &Node, session: Option<bool>, req: Value) -> Value {
    use std::io::{BufRead, BufReader, Write};
    let held = if session.is_none() {
        Some(n.held_session())
    } else {
        None
    };
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = match &held {
        Some(h) => json!({"hello": {"proto": "x-control/6", "role": "owner", "session": h.token}}),
        None => json!({"hello": {"proto": "x-control/6", "role": "owner"}}),
    };
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", json!({ "req": req })).unwrap();
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if v.get("ok").is_some() || v.get("err").is_some() {
            return v;
        }
    }
    panic!("no reply");
}

/// A raw agent request with its token: (code, err body or ok).
fn agent_raw(n: &Node, token: &str, req: Value) -> (bool, Value) {
    use std::io::{BufRead, BufReader, Write};
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = json!({"hello": {"proto": "x-control/6", "role": "agent", "token": token}});
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", json!({ "req": req })).unwrap();
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if let Some(e) = v.get("err") {
            return (false, e.clone());
        }
        if let Some(o) = v.get("ok") {
            return (true, o.clone());
        }
    }
    panic!("no reply");
}

/// An older-version node: `ANTENNA_LEGACY3_BIN_DIR` holds `antennad` and `antenna` of release `v0.1.0-preview.3`
/// (`git archive v0.1.0-preview.3 | tar -x -C <dir>`, then `cargo build -p antennad -p antenna-cli` there with its
/// own `CARGO_TARGET_DIR`).
fn preview3_node(root: &std::path::Path, name: &str) -> Option<Node> {
    let dir = std::env::var_os("ANTENNA_LEGACY3_BIN_DIR")?;
    let mut n = Node::new(root, name, Net::Local);
    n.bin_dir = Some(dir.into());
    n.start();
    n.init();
    let v = n.x(&["--version"]);
    assert!(
        String::from_utf8_lossy(&v.stdout).contains("0.1.0-preview.3"),
        "{v:?}"
    );
    Some(n)
}

/// Compatibility with `0.1.0-preview.3` (PROTOCOL §23): the old node does not advertise `addr/0`, so it is sent no
/// address or topic (its strict parser would refuse them): nothing is refused or `failed`, history is verified,
/// and the sender keeps its own address locally (`addressed: false`). Its messages carry no address and count as
/// messages to everyone at the new node.
#[test]
#[ignore = "needs ANTENNA_LEGACY3_BIN_DIR with antennad/antenna of v0.1.0-preview.3"]
fn a_preview3_node_gets_no_addressing_fields() {
    let root = tempfile::tempdir().unwrap();
    let Some(old) = preview3_node(root.path(), "old") else {
        panic!("ANTENNA_LEGACY3_BIN_DIR is not set");
    };
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    a.init();
    pair(&a, &old, 3);
    let builder = a.agent_add("builder", &["--local-level", "0"]);
    let all = a.agent_add("all", &["--local-level", "0", "--everyone"]);
    // Learn the old node's features first (a message goes over the link)
    assert_eq!(
        old.send("alice", "hello from preview.3")["status"],
        "delivered"
    );
    wait_until("features known", T, || {
        a.contact("old")["peer_addressing"] == false && verified(&a, "old")["state"] == "verified"
    });
    let s = a.json(&[
        "send",
        "--to-agent",
        "builder",
        "--topic",
        "Avatars",
        "old",
        "to an agent there",
    ]);
    assert_eq!(
        (s["status"].as_str(), s["addressed"].as_bool()),
        (Some("delivered"), Some(false)),
        "{s}"
    );
    let s = a.agent_ok(&builder, &["send", "old", "from builder"]);
    assert_eq!(s["status"], "delivered", "{s}");
    // Kept locally
    let h = history(&a, "old");
    let m = h.iter().find(|m| m["text"] == "to an agent there").unwrap();
    assert_eq!(
        (m["to_agent"].as_str(), m["topic"]["title"].as_str()),
        (Some("builder"), Some("Avatars")),
        "{m}"
    );
    // The old node got ordinary messages
    let oh = history(&old, "alice");
    assert!(
        oh.iter().any(|m| m["text"] == "to an agent there"),
        "{oh:?}"
    );
    assert!(oh.iter().all(|m| m["status"] != "failed"), "{oh:?}");
    assert_eq!(a.contact("old")["failed"], 0);
    // Its message has no address: the agent that may read messages to everyone reads it, the other does not
    old.send("alice", "for anyone");
    let v = a.agent_ok(&all, &["inbox", "--wait", "--timeout", "10s"]);
    assert!(texts(&v).contains(&"for anyone".to_string()), "{v}");
    let v = a.agent_ok(&builder, &["inbox"]);
    assert!(texts(&v).is_empty(), "{v}");
    wait_until("history verified", T, || {
        verified(&a, "old")["state"] == "verified" && verified(&old, "alice")["state"] == "verified"
    });
    assert_eq!(
        verified(&a, "old")["fingerprint"],
        verified(&old, "alice")["fingerprint"]
    );
}
