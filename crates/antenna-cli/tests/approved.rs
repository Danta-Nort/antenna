// SPDX-License-Identifier: AGPL-3.0-only
//! After the owner approves, the daemon carries out the approved request itself (D-100): an agent's `send_message`,
//! `share_file`, `share_file_content`, `file_accept` and `request_file`, one by one or in a batch. Each runs exactly
//! once under the same binding (request hash and nonce), a request that changed meanwhile fails, and the agent learns
//! the result from the `approval_resolved` event and its next `wait` (MCP `wait_for_message`), so it never has to be
//! told in its terminal. Repeating the call with the approval ID returns the same result. Real `antennad`, `antenna`
//! and an MCP client over stdio.

// Files need the worker sandbox (D-P-12); on other OSes they never reach "checked".
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    path::Path,
    time::{Duration, Instant},
};

use common::*;
use serde_json::{Value, json};

fn nodes(root: &Path, names: &[&str]) -> Vec<Node> {
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

fn write(path: &Path, data: &[u8]) -> String {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, data).unwrap();
    path.to_string_lossy().into_owned()
}

fn files(n: &Node) -> Vec<Value> {
    n.json(&["files", "pending", "--all"])["files"]
        .as_array()
        .unwrap()
        .clone()
}

fn wait_file(n: &Node, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    let t = Instant::now();
    loop {
        let all = files(n);
        if let Some(x) = all.iter().find(|x| f(x)) {
            return x.clone();
        }
        assert!(
            t.elapsed() < Duration::from_secs(60),
            "{}: {what}: {all:?}",
            n.name
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// The agent's `approval_resolved` event for request `id`.
fn resolved(events: &mut Proc, id: &str) -> Value {
    let id = id.to_string();
    events.wait_for("approval_resolved", T, move |v| {
        v["kind"] == "approval_resolved" && v["id"] == id.as_str()
    })
}

/// An agent call that must stop at `approval_required`: its request (which the daemon says it carries out itself).
fn needs_approval(n: &Node, tok: &str, args: &[&str]) -> Value {
    let (code, v) = n.agent(tok, args);
    assert_eq!(
        (code, v["error"].as_str()),
        (77, Some("approval_required")),
        "{args:?}: {v}"
    );
    assert_eq!(v["approval"]["completes"], true, "{v}");
    v["approval"].clone()
}

const SECRET: &str = "the database: password: hunter2hunter2";

/// Every agent action that can wait for approval is carried out by the daemon once the owner approves it, exactly
/// once, and reported to the agent; a changed request fails; a denied one is reported as denied; a batch approval
/// carries out each item. Negative control: with the daemon's run turned off (no `complete_approved`), the first
/// `approval_resolved` never comes.
#[test]
fn the_daemon_carries_out_each_approved_request_once_and_tells_the_agent() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 4);
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let mut events = Proc::spawn({
        let mut c = a.agent_cmd(&tok);
        c.args(["--json", "events"]);
        c
    });
    events.event("subscribed", T);

    // 1) send_message with a secret: approved, sent once by the daemon
    let ap = needs_approval(a, &tok, &["send", "bob", SECRET]);
    let id = ap["id"].as_str().unwrap().to_string();
    a.owner_json(&["approve", &id]);
    let r = resolved(&mut events, &id);
    assert_eq!(
        (r["state"].as_str(), r["result"]["type"].as_str()),
        (Some("completed"), Some("sent")),
        "{r}"
    );
    assert!(
        r["message"]
            .as_str()
            .unwrap()
            .contains("Do not send it again"),
        "{r}"
    );
    let sent = r["result"]["id"].as_str().unwrap().to_string();
    let got = b.inbox_wait(10);
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0]["text"], SECRET);
    // The agent's next `wait` carries it too, once
    let w = a.agent_ok(&tok, &["wait", "--timeout", "1s"]);
    assert_eq!(w["approvals"][0]["id"], id.as_str(), "{w}");
    assert_eq!(w["approvals"][0]["state"], "completed", "{w}");
    let w = a.agent_ok(&tok, &["wait", "--timeout", "1s"]);
    assert!(w.get("approvals").is_none(), "seen once: {w}");
    // An older agent repeats the call with the ID: the same answer, nothing sent again; another text is refused
    let v = a.agent_ok(&tok, &["send", "bob", SECRET, "--approval", &id]);
    assert_eq!(v["id"], sent.as_str(), "{v}");
    let (code, v) = a.agent(
        &tok,
        &[
            "send",
            "bob",
            "password: not-what-was-approved",
            "--approval",
            &id,
        ],
    );
    assert_eq!(
        (code, v["error"].as_str()),
        (1, Some("approval_mismatch")),
        "{v}"
    );
    std::thread::sleep(Duration::from_millis(500));
    assert!(b.inbox().is_empty(), "exactly once");

    // 2) share_file from outside the link folder: approved, sent once
    let outside = root.path().join("elsewhere");
    let report = write(&outside.join("report.txt"), b"quarterly numbers: 42, 17\n");
    let ap = needs_approval(a, &tok, &["share", "bob", &report]);
    let id = ap["id"].as_str().unwrap().to_string();
    a.owner_json(&["approve", &id]);
    let r = resolved(&mut events, &id);
    assert_eq!(
        (r["state"].as_str(), r["result"]["state"].as_str()),
        (Some("completed"), Some("sent")),
        "{r}"
    );
    let file_id = r["result"]["id"].as_str().unwrap().to_string();
    wait_file(b, "report.txt checked", |x| {
        x["id"] == file_id.as_str() && x["state"] == "checked"
    });
    let v = a.agent_ok(&tok, &["share", "bob", &report, "--approval", &id]);
    assert_eq!(v["id"], file_id.as_str(), "the same answer: {v}");
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(
        files(b)
            .iter()
            .filter(|x| x["name"] == "report.txt")
            .count(),
        1
    );

    // 3) A request that changed after the approval: the binding fails, nothing is sent
    let draft = write(&outside.join("draft.txt"), b"version one\n");
    let ap = needs_approval(a, &tok, &["share", "bob", &draft]);
    let id = ap["id"].as_str().unwrap().to_string();
    write(
        &outside.join("draft.txt"),
        b"version two, not what the owner saw\n",
    );
    a.owner_json(&["approve", &id]);
    let r = resolved(&mut events, &id);
    assert_eq!(
        (r["state"].as_str(), r["error"]["code"].as_str()),
        (Some("failed"), Some("approval_mismatch")),
        "{r}"
    );
    std::thread::sleep(Duration::from_millis(500));
    assert!(files(b).iter().all(|x| x["name"] != "draft.txt"));

    // 4) file_accept of a dot-file name: approved, accepted by the daemon. Its unknown content is only a label from
    // level 3 (D-130); the name still needs the owner (SPEC §10)
    let odd: Vec<u8> = (0..600u32)
        .map(|i| ((i * 37 + 11) % 251) as u8 | 0x80)
        .collect();
    let src = write(&root.path().join("bob-src/.blob.dat"), &odd);
    let v = b.json(&["share", "alice", &src]);
    let incoming = v["id"].as_str().unwrap().to_string();
    let f = wait_file(a, ".blob.dat checked", |x| {
        x["id"] == incoming.as_str() && x["state"] == "checked"
    });
    assert_eq!(f["verdict"], "suspicious", "{f}");
    assert!(
        f["labels"]
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l == "unknown_type"),
        "{f}"
    );
    let ap = needs_approval(a, &tok, &["files", "accept", &incoming]);
    let id = ap["id"].as_str().unwrap().to_string();
    a.owner_json(&["approve", &id]);
    let r = resolved(&mut events, &id);
    assert_eq!(
        (r["state"].as_str(), r["result"]["state"].as_str()),
        (Some("completed"), Some("accepted")),
        "{r}"
    );
    assert_eq!(
        std::fs::read(a.links().join("bob/shared/.blob.dat")).unwrap(),
        odd
    );
    let v = a.agent_ok(&tok, &["files", "accept", &incoming, "--approval", &id]);
    assert_eq!(
        v["state"], "accepted",
        "the same answer, not `already accepted`: {v}"
    );

    // 5) request_file with a secret in the path
    let ap = needs_approval(a, &tok, &["request", "bob", "password=hunter2hunter2.txt"]);
    let id = ap["id"].as_str().unwrap().to_string();
    a.owner_json(&["approve", &id]);
    let r = resolved(&mut events, &id);
    assert_eq!(
        (r["state"].as_str(), r["result"]["type"].as_str()),
        (Some("completed"), Some("file_requested")),
        "{r}"
    );

    // 6) Denied: reported as denied, nothing sent
    let ap = needs_approval(a, &tok, &["send", "bob", "password: correct-horse-battery"]);
    let id = ap["id"].as_str().unwrap().to_string();
    a.owner_json(&["deny", &id]);
    let r = resolved(&mut events, &id);
    assert_eq!(r["state"], "denied", "{r}");
    assert!(
        r["message"].as_str().unwrap().contains("do not repeat it"),
        "{r}"
    );

    // 7) A batch approval carries out each item once
    let one = needs_approval(a, &tok, &["send", "bob", "password: first-batch-item"])["id"]
        .as_str()
        .unwrap()
        .to_string();
    let two = needs_approval(a, &tok, &["send", "bob", "password: second-batch-item"])["id"]
        .as_str()
        .unwrap()
        .to_string();
    a.owner_json(&["approve", &one, &two]);
    for id in [&one, &two] {
        assert_eq!(resolved(&mut events, id)["state"], "completed");
    }
    let t = Instant::now();
    let mut texts: Vec<String> = Vec::new();
    while texts.len() < 2 && t.elapsed() < T {
        texts.extend(
            b.inbox_wait(5)
                .iter()
                .map(|m| m["text"].as_str().unwrap().to_string()),
        );
    }
    texts.sort();
    assert_eq!(
        texts,
        ["password: first-batch-item", "password: second-batch-item"]
    );
    std::thread::sleep(Duration::from_millis(500));
    assert!(b.inbox().is_empty(), "each once");
}

/// MCP: the instructions say approvals are the daemon's; `share_file_content` that needs approval is carried out by
/// the daemon with exactly the bytes given, and `wait_for_message` reports it.
#[test]
fn mcp_agent_gets_the_result_of_an_approved_upload_from_wait_for_message() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 4);
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let mut m = Mcp::start(a, &tok);
    let instr = m.instructions();
    assert!(
        instr.contains("Approvals are handled by the daemon")
            && instr.contains("do not ask the owner"),
        "{instr}"
    );
    let content = format!("{SECRET}\n");
    let (e, v) = m.call(
        "share_file_content",
        json!({"contact": "bob", "name": "db.env", "content_base64": data_encoding::BASE64.encode(content.as_bytes())}),
    );
    assert!(e && v["error"] == "approval_required", "{v}");
    assert_eq!(v["approval"]["completes"], true, "{v}");
    let id = v["approval"]["id"].as_str().unwrap().to_string();
    a.owner_json(&["approve", &id]);
    let (e, w) = m.call("wait_for_message", json!({"timeout_secs": 30}));
    assert!(!e, "{w}");
    let r = &w["approvals"][0];
    assert_eq!(
        (r["id"].as_str(), r["state"].as_str()),
        (Some(id.as_str()), Some("completed")),
        "{w}"
    );
    let file_id = r["result"]["id"].as_str().unwrap().to_string();
    let f = wait_file(b, "db.env checked", |x| {
        x["id"] == file_id.as_str() && x["state"] == "checked"
    });
    assert_eq!(f["name"], "db.env");
    let acc = b.json(&["files", "accept", &file_id]);
    let saved = b
        .links()
        .join("alice")
        .join(acc["dest"].as_str().unwrap())
        .join("db.env");
    assert_eq!(std::fs::read_to_string(saved).unwrap(), content);
    m.stop();
}
