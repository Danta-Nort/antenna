// SPDX-License-Identifier: AGPL-3.0-only
//! "Escalate to" (D-118, CONTROL §29): an agent's question goes to its supervisor, the owner (a record the owner answers)
//! or a contact the owner named (a message from the agent under the policy of `send`). Real `antennad` and `antenna`, a
//! real MCP server over stdio.

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    time::{Duration, Instant},
};

use common::*;
use serde_json::{Value, json};

fn node(root: &std::path::Path, name: &str) -> Node {
    let mut n = Node::new(root, name, Net::Local);
    n.start();
    n.init();
    n
}

/// An owner subscription (x-control/7) held by an owner session, reading events in the background.
struct Subscription {
    lines: BufReader<UnixStream>,
}

impl Subscription {
    fn open(n: &Node) -> Self {
        let held = n.held_session();
        let mut s = UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
        s.set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        writeln!(
            s,
            "{}",
            json!({"hello": {"proto": "x-control/7", "role": "owner", "session": held.token}})
        )
        .unwrap();
        writeln!(s, "{}", json!({"req": {"cmd": "subscribe"}})).unwrap();
        // The session must stay open while the subscription runs
        std::mem::forget(held);
        Subscription {
            lines: BufReader::new(s),
        }
    }

    /// Events of `kind` within `within`.
    fn events(&mut self, kind: &str, within: Duration) -> Vec<Value> {
        let t = Instant::now();
        let mut out = Vec::new();
        while t.elapsed() < within {
            let mut l = String::new();
            if let Ok(n) = self.lines.read_line(&mut l)
                && n > 0
                && let Ok(v) = serde_json::from_str::<Value>(&l)
                && v["event"]["kind"] == kind
            {
                out.push(v["event"].clone());
            }
        }
        out
    }
}

#[test]
fn a_question_to_the_owner_is_answered_once_and_reaches_only_its_agent() {
    let root = tempfile::tempdir().unwrap();
    let a = node(root.path(), "alice");
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let other = a.agent_add("other", &["--local-level", "0"]);
    let mut sub = Subscription::open(&a);

    // The agent asks; the owner sees it (event and list), the question as the agent wrote it
    let q = a.agent_ok(
        &tok,
        &[
            "escalate",
            "Should I delete the old migrations? They look unused.",
        ],
    );
    assert_eq!(
        (q["type"].as_str(), q["state"].as_str(), q["to"].as_str()),
        (Some("escalation"), Some("open"), Some("owner")),
        "{q}"
    );
    let id = q["id"].as_str().unwrap().to_string();
    let evs = sub.events("escalation", Duration::from_secs(2));
    assert_eq!(evs.len(), 1, "{evs:?}");
    assert_eq!(
        evs[0]["question"],
        "Should I delete the old migrations? They look unused."
    );
    let list = a.json(&["questions"]);
    assert_eq!(list["escalations"][0]["id"], id, "{list}");
    assert_eq!(list["escalations"][0]["agent"], "claude");

    // Nothing for the agent yet; another agent cannot read it
    let w = a.agent_ok(&tok, &["wait", "--timeout", "1s"]);
    assert!(w.get("escalations").is_none(), "{w}");
    let (c, v) = a.agent(&other, &["escalation", &id]);
    assert_eq!((c, v["error"].as_str()), (1, Some("not_found")), "{v}");

    // The agents' own subscriptions (what `agent_watch` gives a waker): only the agent that asked hears of the answer
    let mut ev_claude = Proc::spawn({
        let mut c = a.agent_cmd(&tok);
        c.args(["--json", "events"]);
        c
    });
    let mut ev_other = Proc::spawn({
        let mut c = a.agent_cmd(&other);
        c.args(["--json", "events"]);
        c
    });
    ev_claude.event("subscribed", T);
    ev_other.event("subscribed", T);

    // The owner answers: the agent's wait returns it, once
    let ans = a.json(&[
        "answer",
        &id,
        "No: keep them, the release script reads them.",
    ]);
    let e = ev_claude.event("escalation", T);
    assert_eq!(
        (e["id"].as_str(), e["state"].as_str()),
        (Some(id.as_str()), Some("answered")),
        "{e}"
    );
    std::thread::sleep(Duration::from_secs(1));
    let _ = ev_other.child.kill();
    let (_, seen) = ev_other.finish_all(T);
    assert!(
        !seen.iter().any(|v| v["kind"] == "escalation"),
        "another agent heard of it: {seen:?}"
    );
    let _ = ev_claude.child.kill();
    assert_eq!(ans["state"], "answered", "{ans}");
    let w = a.agent_ok(&tok, &["wait", "--timeout", "5s"]);
    assert_eq!(w["escalations"][0]["id"], id, "{w}");
    assert_eq!(
        w["escalations"][0]["answer"],
        "No: keep them, the release script reads them."
    );
    let w = a.agent_ok(&tok, &["wait", "--timeout", "1s"]);
    assert!(w.get("escalations").is_none(), "given once: {w}");
    let g = a.agent_ok(&tok, &["escalation", &id]);
    assert_eq!(g["state"], "answered");
    // Only an open question is answered
    let out = a.x(&["--json", "answer", &id, "again"]);
    assert_eq!(last_json(&out.stdout)["error"], "denied", "{out:?}");
    let evs = sub.events("escalation", Duration::from_secs(1));
    assert_eq!(
        evs.iter().filter(|e| e["state"] == "answered").count(),
        1,
        "{evs:?}"
    );

    // Dismissed, and an agent that waits in `escalate` gets the answer there
    let q2 = a.agent_ok(
        &tok,
        &["escalate", "Is the staging server mine to restart?"],
    );
    let id2 = q2["id"].as_str().unwrap().to_string();
    a.json(&["answer", &id2, "--dismiss"]);
    let i = a.agent_ok(&tok, &["inbox"]);
    assert_eq!(i["escalations"][0]["state"], "dismissed", "{i}");
    let waiting = a
        .agent_cmd(&tok)
        .args([
            "--json",
            "escalate",
            "Which branch: main or release?",
            "--wait",
            "30s",
        ])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let t = Instant::now();
    let id3 = loop {
        let l = a.json(&["questions"]);
        if let Some(e) = l["escalations"].as_array().and_then(|v| {
            v.iter()
                .find(|e| e["question"] == "Which branch: main or release?")
        }) {
            break e["id"].as_str().unwrap().to_string();
        }
        assert!(t.elapsed() < Duration::from_secs(10), "{l}");
        std::thread::sleep(Duration::from_millis(100));
    };
    a.json(&["answer", &id3, "release"]);
    let out = waiting.wait_with_output().unwrap();
    let v = last_json(&out.stdout);
    assert_eq!(
        (v["state"].as_str(), v["answer"].as_str()),
        (Some("answered"), Some("release")),
        "{v}"
    );
    assert!(t.elapsed() < Duration::from_secs(20));

    // Limits: an empty question, an answer and a dismissal at once
    let (c, v) = a.agent(&tok, &["escalate", "   "]);
    assert_eq!((c, v["error"].as_str()), (1, Some("bad_request")), "{v}");
}

#[test]
fn a_question_to_a_supervisor_contact_is_a_message_under_the_send_policy() {
    let root = tempfile::tempdir().unwrap();
    let a = node(root.path(), "alice");
    let b = node(root.path(), "bob");
    let c = node(root.path(), "carol");
    pair(&a, &b, 4);
    pair(&a, &c, 3);
    let tok = a.agent_add("claude", &["--local-level", "0", "--links", "bob,carol"]);
    let narrow = a.agent_add("narrow", &["--local-level", "0", "--links", "carol"]);

    // Only a contact among the agent's links; the password every time
    let out = a.x_stdin(
        &[
            "--json",
            "agent",
            "escalate",
            "narrow",
            "--to",
            "bob",
            "--password-stdin",
        ],
        &format!("{}\n", a.password),
    );
    assert_eq!(last_json(&out.stdout)["error"], "bad_request", "{out:?}");
    let _ = narrow;
    let out = a.x_stdin(
        &[
            "--json",
            "agent",
            "escalate",
            "claude",
            "--to",
            "bob",
            "--password-stdin",
        ],
        &format!("{}\n", a.password),
    );
    assert!(out.status.success(), "{out:?}");
    let agents = a.json(&["agent", "list"]);
    let me = agents["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["name"] == "claude")
        .unwrap()
        .clone();
    assert_eq!(me["session"]["escalate_to"], "bob", "{me}");

    // A question to bob: the agent's message to bob in person
    let q = a.agent_ok(
        &tok,
        &["escalate", "Can I merge the payments branch tonight?"],
    );
    assert_eq!(
        (q["state"].as_str(), q["to"].as_str()),
        (Some("sent"), Some("bob")),
        "{q}"
    );
    let in_bob = |needle: &str| -> Option<Value> {
        let h = b.json(&["history", "alice"]);
        h["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["text"].as_str().is_some_and(|t| t.contains(needle)))
            .cloned()
    };
    let t = Instant::now();
    let msg = loop {
        if let Some(m) = in_bob("payments branch") {
            break m;
        }
        assert!(t.elapsed() < Duration::from_secs(20));
        std::thread::sleep(Duration::from_millis(200));
    };
    assert_eq!(msg["via_agent"], "claude", "{msg}");
    assert_eq!(msg["to"], "person", "{msg}");
    assert!(
        msg["text"]
            .as_str()
            .unwrap()
            .starts_with("A question from claude"),
        "{msg}"
    );

    // After reading carol's message (level 3), a question to bob is a flow from carol's link to bob's: the owner
    // approves it first, as for send_message, and the daemon then sends it
    a.agent_ok(&tok, &["send", "carol", "claude here"]);
    let t = Instant::now();
    while !c.contact("alice")["agents"]
        .as_array()
        .is_some_and(|v| v.iter().any(|x| x["name"] == "claude"))
    {
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "carol learns alice's agent"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    c.send_to_agent("alice", "claude", "hi from carol");
    let t = Instant::now();
    while a.agent_ok(&tok, &["inbox", "--contact", "carol"])["messages"]
        .as_array()
        .unwrap()
        .is_empty()
    {
        assert!(t.elapsed() < Duration::from_secs(20));
        std::thread::sleep(Duration::from_millis(200));
    }
    let (code, v) = a.agent(
        &tok,
        &[
            "escalate",
            "Carol asks for the staging keys: may I send them?",
        ],
    );
    assert_eq!(
        (code, v["error"].as_str()),
        (77, Some("approval_required")),
        "{v}"
    );
    assert_eq!(v["approval"]["reasons"][0], "cross_link:carol", "{v}");
    assert!(in_bob("staging keys").is_none());
    let out = a.owner(&["approve", v["approval"]["id"].as_str().unwrap()]);
    assert!(out.status.success(), "{out:?}");
    let t = Instant::now();
    while in_bob("staging keys").is_none() {
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "sent by the daemon after the approval"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    // A question to the owner records what the agent had read when it asked
    let out = a.x_stdin(
        &[
            "--json",
            "agent",
            "escalate",
            "claude",
            "--owner",
            "--password-stdin",
        ],
        &format!("{}\n", a.password),
    );
    assert!(out.status.success(), "{out:?}");
    let q = a.agent_ok(&tok, &["escalate", "Carol wants the keys. Yes or no?"]);
    assert_eq!(q["to"], "owner", "{q}");
    assert_eq!(q["read_from"][0]["contact"], "carol", "{q}");
    assert_eq!(q["read_from"][0]["level"], 3, "{q}");

    // The questions sent to bob are not the owner's to answer: only the last one is listed
    let open = a.json(&["questions"]);
    assert_eq!(open["escalations"].as_array().unwrap().len(), 1, "{open}");
}

#[test]
fn the_mcp_server_offers_escalate_and_says_where_questions_go() {
    let root = tempfile::tempdir().unwrap();
    let a = node(root.path(), "alice");
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let mut m = Mcp::start(&a, &tok);
    assert!(
        m.instructions().contains("goes to the owner"),
        "{}",
        m.instructions()
    );
    let (e, v) = m.call(
        "escalate",
        json!({"question": "May I rename the public API?"}),
    );
    assert!(!e, "{v}");
    let id = v["id"].as_str().unwrap().to_string();
    a.json(&["answer", &id, "Not before 1.0."]);
    let (e, w) = m.call("wait_for_message", json!({"timeout_secs": 5}));
    assert!(!e, "{w}");
    assert_eq!(w["escalations"][0]["answer"], "Not before 1.0.", "{w}");
    let (_, s) = m.call("escalation_status", json!({"id": id}));
    assert_eq!(s["state"], "answered", "{s}");
    m.stop();
}
