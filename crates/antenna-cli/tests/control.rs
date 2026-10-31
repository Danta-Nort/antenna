// SPDX-License-Identifier: AGPL-3.0-only
//! Control protocol v1 (`docs/CONTROL.md`) for UIs (TUI, Flutter): an event subscription over one long-lived
//! connection, paginated link history, contacts with presence. Also compatibility: an `x-control/0` client works.
//!
//! Run: `cargo test -p antenna-cli --test control -- --nocapture` (from the workspace root, so that `antennad` is
//! built).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    sync::mpsc,
    time::{Duration, Instant},
};

use common::*;
use serde_json::{Value, json};

/// A long-lived subscription connection: a background thread puts JSON lines into a channel.
struct Sub {
    _s: UnixStream,
    rx: mpsc::Receiver<Value>,
    seen: Vec<Value>,
}

impl Sub {
    fn open(node: &Node, hello: Value, proto_req: Value) -> Self {
        let mut s = UnixStream::connect(node.dir.join("antennad.sock")).unwrap();
        s.write_all(
            format!(
                "{}\n{}\n",
                json!({ "hello": hello }),
                json!({ "req": proto_req })
            )
            .as_bytes(),
        )
        .unwrap();
        let r = s.try_clone().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for l in BufReader::new(r).lines() {
                let Ok(l) = l else { break };
                if tx.send(serde_json::from_str::<Value>(&l).unwrap()).is_err() {
                    break;
                }
            }
        });
        Self {
            _s: s,
            rx,
            seen: Vec::new(),
        }
    }

    /// Waits for an event matching the condition (already seen events are checked too).
    fn wait(&mut self, what: &str, f: impl Fn(&Value) -> bool) -> Value {
        if let Some(v) = self.seen.iter().find(|v| f(&v["event"])) {
            return v["event"].clone();
        }
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.rx.recv_timeout(left) {
                Ok(v) => {
                    self.seen.push(v.clone());
                    if f(&v["event"]) {
                        return v["event"].clone();
                    }
                }
                Err(_) => panic!("timeout waiting for {what}; seen: {:#?}", self.seen),
            }
        }
    }

    fn all(&mut self) -> Vec<Value> {
        while let Ok(v) = self.rx.recv_timeout(Duration::from_millis(300)) {
            self.seen.push(v);
        }
        self.seen.clone()
    }
}

#[test]
fn subscription_streams_pairing_messages_statuses_contacts_and_approvals() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    let mut b = Node::new(root.path(), "bob", Net::Local);
    for n in [&mut a, &mut b] {
        n.start();
        n.init();
    }
    // The window holds the owner session in the connection (Q-14b): no session, no subscription.
    let mut nosess = Sub::open(
        &a,
        json!({"proto": "x-control/1", "role": "owner"}),
        json!({"cmd": "subscribe"}),
    );
    nosess.wait("login_required", |_| true);
    assert_eq!(nosess.seen[0]["hello_ok"]["session"], "none");
    let e = nosess.all();
    assert_eq!(e[1]["err"]["code"], "login_required", "{e:?}");
    let held = a.held_session();
    let owner = json!({"proto": "x-control/1", "role": "owner", "session": held.token});
    let mut sub = Sub::open(&a, owner.clone(), json!({"cmd": "subscribe"}));
    let first = sub.wait("hello_ok", |_| true);
    assert!(first.is_null(), "first line is hello_ok, not an event");
    assert_eq!(sub.seen[0]["hello_ok"]["proto"], "x-control/1");
    assert_eq!(sub.seen[0]["hello_ok"]["session"], "held");
    sub.wait("subscribed", |e| {
        e["kind"] == "subscribed" && e["role"] == "owner"
    });

    // Pairing stages and a new contact.
    pair(&a, &b, 3);
    let phases: Vec<String> = {
        sub.wait("invite linked", |e| {
            e["kind"] == "invite" && e["invite"]["phase"] == "linked"
        });
        sub.seen
            .iter()
            .filter(|v| v["event"]["kind"] == "invite")
            .map(|v| v["event"]["invite"]["phase"].as_str().unwrap().to_string())
            .collect()
    };
    println!("INVITE PHASES: {phases:?}");
    assert_eq!(phases.first().map(String::as_str), Some("waiting"));
    assert!(phases.iter().any(|p| p == "code_ready"));
    let c = sub.wait("contact bob", |e| {
        e["kind"] == "contact" && e["contact"]["contact"] == "bob"
    });
    assert_eq!(
        (
            c["contact"]["trust"].as_u64(),
            c["contact"]["net_mode"].as_str()
        ),
        (Some(3), Some("direct"))
    );

    // Outgoing: a message (queued) → status delivered; incoming comes with text (the subscriber is the owner).
    let s = a.send("bob", "one");
    let id = s["id"].as_str().unwrap().to_string();
    let m = sub.wait("out message", |e| {
        e["kind"] == "message" && e["message"]["id"] == id.as_str()
    });
    assert_eq!(
        (
            m["message"]["direction"].as_str(),
            m["message"]["status"].as_str()
        ),
        (Some("out"), Some("queued"))
    );
    sub.wait("delivered", |e| {
        e["kind"] == "message_status" && e["id"] == id.as_str() && e["status"] == "delivered"
    });
    sub.wait("presence online", |e| {
        e["kind"] == "contact" && e["contact"]["presence"] == "online"
    });
    b.send("alice", "two");
    let m = sub.wait("in message", |e| {
        e["kind"] == "message" && e["message"]["direction"] == "in"
    });
    assert_eq!(
        (m["contact"].as_str(), m["message"]["text"].as_str()),
        (Some("bob"), Some("two"))
    );

    // A level change is a contact event.
    a.owner_json(&["trust", "bob", "4"]);
    sub.wait("trust 4", |e| {
        e["kind"] == "contact" && e["contact"]["trust"] == 4
    });

    // An approval request and the owner's decision.
    let tok = a.agent_add("claude", &["--local-level", "5"]);
    let (code, v) = a.agent(&tok, &["send", "bob", "project details", "--wait", "0"]);
    assert_eq!(code, 77, "{v}");
    let aid = v["approval"]["id"].as_str().unwrap().to_string();
    sub.wait("approval pending", |e| {
        e["kind"] == "approval"
            && e["approval"]["id"] == aid.as_str()
            && e["approval"]["state"] == "pending"
    });
    a.owner_json(&["approve", &aid]);
    sub.wait("approval approved", |e| {
        e["kind"] == "approval"
            && e["approval"]["id"] == aid.as_str()
            && e["approval"]["state"] == "approved"
    });

    // An agent subscription: incoming messages as facts only, without text; other agents' approval requests are not
    // visible.
    let mut asub = Sub::open(
        &a,
        json!({"proto": "x-control/1", "role": "agent", "token": tok}),
        json!({"cmd": "subscribe"}),
    );
    asub.wait("agent subscribed", |e| {
        e["kind"] == "subscribed" && e["role"] == "agent"
    });
    // v6 (CONTROL §20): a message to the person is not the agent's, not even as a fact
    b.send("alice", "for the person only");
    sub.wait("the person's message", |e| {
        e["kind"] == "message" && e["message"]["text"] == "for the person only"
    });
    b.send_to_agent("alice", "claude", "secret plan for alice only");
    let f = asub.wait("fact", |e| e["kind"] == "message_fact");
    assert_eq!(
        (
            f["contact"].as_str(),
            f["trust"].as_u64(),
            f["chars"].as_u64()
        ),
        (Some("bob"), Some(4), Some(26))
    );
    let agent_events = serde_json::to_string(&asub.all()).unwrap();
    assert!(!agent_events.contains("secret plan"), "{agent_events}");
    assert_eq!(
        agent_events.matches("message_fact").count(),
        1,
        "one fact: the message to the person gave none: {agent_events}"
    );
    assert!(!agent_events.contains("\"invite\""), "{agent_events}");
    // Contacts: presence that takes the level into account, and the kind of the other side (v5: Bob wrote himself and
    // his node announces agents, so a human).
    let c = a.contact("bob");
    assert_eq!(
        (c["presence"].as_str(), c["peer_kind"].as_str()),
        (Some("online"), Some("human")),
        "{c}"
    );
}

#[test]
fn history_pages_in_both_directions_with_delivery_status() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    let mut b = Node::new(root.path(), "bob", Net::Local);
    let mut c = Node::new(root.path(), "carol", Net::Local);
    for n in [&mut a, &mut b, &mut c] {
        n.start();
        n.init();
    }
    pair(&a, &b, 3);
    pair(&a, &c, 3);
    // An agent sees history only from the moment it was created (D-30): create it before the conversation. Both may
    // read messages to everyone (v6, CONTROL §20), which Bob's are.
    let early = a.agent_add("early", &["--local-level", "0", "--everyone"]);
    a.send("bob", "before claude");
    let tok = a.agent_add("claude", &["--local-level", "0", "--everyone"]);
    for i in 0..3 {
        a.send("bob", &format!("a{i}"));
        b.send_to_everyone("alice", &format!("b{i}"));
    }
    // B is offline: the outgoing message stays queued.
    b.stop();
    a.json(&["send", "bob", "while offline", "--wait", "0"]);
    let p1 = a.json(&["history", "bob", "--limit", "3"]);
    // Text only: agent receipts (type `receipt`, slice 3) are in the link history too.
    let texts = |p: &Value| -> Vec<String> {
        p["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["kind"] == "text")
            .map(|m| m["text"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(texts(&p1), vec!["a2", "b2", "while offline"]);
    let last = &p1["messages"][2];
    assert_eq!(
        (last["direction"].as_str(), last["status"].as_str()),
        (Some("out"), Some("queued"))
    );
    assert_eq!(p1["messages"][1]["status"], "received");
    assert_eq!(p1["messages"][0]["status"], "delivered");
    let before = p1["next_before"].as_i64().unwrap();
    let p2 = a.json(&[
        "history",
        "bob",
        "--limit",
        "3",
        "--before",
        &before.to_string(),
    ]);
    assert_eq!(texts(&p2), vec!["b0", "a1", "b1"]);
    let p3 = a.json(&[
        "history",
        "bob",
        "--limit",
        "3",
        "--before",
        &p2["next_before"].as_i64().unwrap().to_string(),
    ]);
    assert_eq!(texts(&p3), vec!["before claude", "a0"]);
    assert!(p3["next_before"].is_null(), "start of history");
    // Level 3 presence without a connection: offline.
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(a.contact("bob")["presence"], "offline");
    // For the agent: only after it was created, and only what it may read (v6, CONTROL §20): the owner's own
    // conversation is not on its pages, so a page with only the owner's message is empty and reads nothing.
    let h = a.agent_ok(&tok, &["history", "bob", "--limit", "1"]);
    assert_eq!(texts(&h), Vec::<String>::new(), "{h}");
    let s = a.agent_ok(&tok, &["session"]);
    assert!(s["ceiling"].is_null(), "nothing read: {s}");
    // Incoming messages on the page set the permission ceiling and put the link into "read": to another link only
    // through approval.
    let h = a.agent_ok(&tok, &["history", "bob", "--limit", "2"]);
    assert_eq!(texts(&h), vec!["b2"]);
    assert_eq!(a.agent_ok(&tok, &["session"])["ceiling"], 3);
    let (code, v) = a.agent(
        &tok,
        &["send", "carol", "what alice told bob", "--wait", "0"],
    );
    assert_eq!(
        (code, v["error"].as_str()),
        (77, Some("approval_required")),
        "{v}"
    );
    assert!(
        v["approval"]["reasons"]
            .to_string()
            .contains("cross_link:bob"),
        "{v}"
    );
    let all = a.agent_ok(&tok, &["history", "bob", "--limit", "100"]);
    assert_eq!(
        texts(&all),
        vec!["b0", "b1", "b2"],
        "neither older than the agent nor the owner's"
    );
    assert_eq!(
        texts(&a.agent_ok(&early, &["history", "bob", "--limit", "100"])),
        vec!["b0", "b1", "b2"]
    );
}

#[test]
fn control_v0_clients_still_work() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    a.init();
    let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
    s.write_all(b"{\"hello\":{\"proto\":\"x-control/0\",\"role\":\"owner\"}}\n{\"req\":{\"cmd\":\"status\"}}\n")
        .unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    let lines: Vec<Value> = BufReader::new(s)
        .lines()
        .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
        .collect();
    assert_eq!(lines[0]["hello_ok"]["proto"], "x-control/0");
    assert_eq!(lines[1]["ok"]["state"], "unlocked");
    let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
    s.write_all(b"{\"hello\":{\"proto\":\"x-control/9\",\"role\":\"owner\"}}\n")
        .unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    let mut out = String::new();
    std::io::Read::read_to_string(&mut s, &mut out).unwrap();
    assert!(out.contains("unsupported control protocol"), "{out}");
}

/// Hello + one request over a fresh connection of this test process → every line of the reply. The test process
/// itself has no owner session (`login` opened it for the processes it starts, D-46).
fn once(node: &Node, hello: Value, req: Value) -> Vec<Value> {
    let mut s = UnixStream::connect(node.dir.join("antennad.sock")).unwrap();
    s.write_all(format!("{}\n{}\n", json!({ "hello": hello }), json!({ "req": req })).as_bytes())
        .unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    BufReader::new(s)
        .lines()
        .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
        .collect()
}

/// D-84, approvals housekeeping: an unanswered request closes by itself (the owner and the waiting agent get
/// `approval{state: expired}`, it leaves the pending list and stays in the audit log); denying needs neither the
/// password nor an owner session, like `lock`; approving still needs the password; an agent has no `deny`.
#[test]
fn approval_requests_expire_by_themselves_and_deny_needs_no_password() {
    const TTL_MS: u64 = 4000;
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.extra_args = vec!["--approval-ttl-ms".into(), TTL_MS.to_string()];
    let mut b = Node::new(root.path(), "bob", Net::Local);
    for n in [&mut a, &mut b] {
        n.start();
        n.init();
    }
    pair(&a, &b, 3);
    let bob_link = a.contact("bob")["link_id"].as_str().unwrap().to_string();
    let tok = a.agent_add("claude", &["--local-level", "5"]);
    let held = a.held_session();
    let mut sub = Sub::open(
        &a,
        json!({"proto": "x-control/5", "role": "owner", "session": held.token}),
        json!({"cmd": "subscribe"}),
    );
    sub.wait("subscribed", |e| e["kind"] == "subscribed");
    let mut asub = Sub::open(
        &a,
        json!({"proto": "x-control/5", "role": "agent", "token": tok}),
        json!({"cmd": "subscribe"}),
    );
    asub.wait("agent subscribed", |e| e["kind"] == "subscribed");
    let event = |id: &str, state: &str| {
        let (id, state) = (id.to_string(), state.to_string());
        move |e: &Value| {
            e["kind"] == "approval"
                && e["approval"]["id"] == id.as_str()
                && e["approval"]["state"] == state.as_str()
        }
    };

    // 1) Nobody answers: the request closes by itself.
    let (code, v) = a.agent(&tok, &["send", "bob", "project details", "--wait", "0"]);
    assert_eq!(code, 77, "{v}");
    let first = v["approval"]["id"].as_str().unwrap().to_string();
    assert_eq!(v["approval"]["link_id"], bob_link.as_str(), "{v}");
    assert_eq!(v["approval"]["target_link_id"], bob_link.as_str(), "{v}");
    let t0 = Instant::now();
    sub.wait("pending", event(&first, "pending"));
    let e = sub.wait("expired", event(&first, "expired"));
    let after = t0.elapsed();
    println!("EXPIRED: event {after:?} after the request (lifetime {TTL_MS} ms)");
    assert!(after < Duration::from_millis(TTL_MS + 2500), "{after:?}");
    assert_eq!(e["approval"]["link_id"], bob_link.as_str());
    asub.wait("the waiting agent learns it", event(&first, "expired"));
    // D-100: its next `wait` says so too, in words it can act on
    let w = a.agent_ok(&tok, &["wait", "--timeout", "1s"]);
    assert_eq!(
        (
            w["approvals"][0]["id"].as_str(),
            w["approvals"][0]["state"].as_str()
        ),
        (Some(first.as_str()), Some("expired")),
        "{w}"
    );
    assert_eq!(
        a.json(&["approvals"])["approvals"]
            .as_array()
            .unwrap()
            .len(),
        0,
        "no longer pending"
    );
    let all = a.json(&["approvals", "--all"]);
    assert!(
        all["approvals"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["id"] == first.as_str() && x["state"] == "expired"),
        "{all}"
    );
    let log = a.json(&["log", "bob"]);
    assert!(
        log["entries"].as_array().unwrap().iter().any(|r| {
            r["approval_id"] == first.as_str()
                && r["decision"] == "approval_expired"
                && r["actor"] == "claude"
                && r["source"] == "local"
        }),
        "the audit log keeps it: {log}"
    );
    let (code, v) = a.agent(
        &tok,
        &["send", "bob", "project details", "--approval", &first],
    );
    assert_eq!(
        (code, v["error"].as_str()),
        (1, Some("approval_expired")),
        "{v}"
    );
    let out = a.owner(&["deny", &first]);
    assert_eq!(
        last_json(&out.stdout)["error"],
        "approval_expired",
        "{out:?}"
    );

    // 2) Denying: no password and no session (this test process has none: `hello_ok.session` is "none").
    let (_, v) = a.agent(&tok, &["send", "bob", "more details", "--wait", "0"]);
    let second = v["approval"]["id"].as_str().unwrap().to_string();
    sub.wait("second pending", event(&second, "pending"));
    let owner = json!({"proto": "x-control/5", "role": "owner"});
    let r = once(&a, owner.clone(), json!({"cmd": "approvals", "all": false}));
    assert_eq!(r[0]["hello_ok"]["session"], "none");
    assert_eq!(
        r[1]["err"]["code"], "login_required",
        "no session, no list: {r:?}"
    );
    // Approving still needs the password, every time.
    let r = once(
        &a,
        owner.clone(),
        json!({"cmd": "approve", "id": second, "password": "not-the-password"}),
    );
    assert_eq!(r[1]["err"]["code"], "wrong_password", "{r:?}");
    let r = once(&a, owner.clone(), json!({"cmd": "approve", "id": second}));
    assert_eq!(r[1]["err"]["code"], "bad_request", "{r:?}");
    // An agent has no such command, even with the request ID it was given.
    let r = once(
        &a,
        json!({"proto": "x-control/5", "role": "agent", "token": tok}),
        json!({"cmd": "deny", "id": second, "hour": false}),
    );
    assert_eq!(r[1]["err"]["code"], "unknown_command", "{r:?}");
    let t = Instant::now();
    let r = once(
        &a,
        owner.clone(),
        json!({"cmd": "deny", "id": second, "hour": false}),
    );
    println!("DENY without password or session: {:?}", t.elapsed());
    assert_eq!(r[1]["ok"]["type"], "approval", "{r:?}");
    assert_eq!(r[1]["ok"]["state"], "denied", "{r:?}");
    sub.wait("denied", event(&second, "denied"));
    asub.wait("agent: denied", event(&second, "denied"));
    let (code, v) = a.agent(
        &tok,
        &["send", "bob", "more details", "--approval", &second],
    );
    assert_eq!(
        (code, v["error"].as_str()),
        (1, Some("approval_denied")),
        "{v}"
    );

    // 3) The CLI without a session and without a terminal (a process the test did not start directly, so the test's
    // parent session does not cover it): no password asked, none needed. A password from an older client's script is
    // read and ignored.
    let (_, v) = a.agent(&tok, &["send", "bob", "even more", "--wait", "0"]);
    let third = v["approval"]["id"].as_str().unwrap().to_string();
    sub.wait("third pending", event(&third, "pending"));
    let out = std::process::Command::new("sh")
        .clean_env()
        .arg("-c")
        .arg(r#""$0" "$@"; exit $?"#)
        .arg(a.cmd().get_program())
        .args([
            "--data-dir",
            a.dir.to_str().unwrap(),
            "--json",
            "deny",
            &third,
        ])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    assert_eq!(last_json(&out.stdout)["state"], "denied", "{out:?}");
    sub.wait("third denied", event(&third, "denied"));
    let log = a.json(&["log", "bob"]);
    let decisions: Vec<&str> = log["entries"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["approval_id"] == third.as_str() || r["approval_id"] == second.as_str())
        .filter_map(|r| r["decision"].as_str())
        .collect();
    assert!(
        decisions.contains(&"denied_by_owner"),
        "a denial is an owner decision in the log: {decisions:?}"
    );
}
