// SPDX-License-Identifier: AGPL-3.0-only
//! Trust level 5, the owner's own computer (D-99): files and messages go without asking, secrets included, and the
//! audit log keeps what the scanner found; incoming clean and suspicious files are accepted by themselves while a
//! threat stays in quarantine; an agent working on a level-5 task runs its commands without confirmation through the
//! host hook. Level 4 and a session that read lower-level data keep the old rules. Real `antennad` and `antenna`.

// The file check needs the worker sandbox (D-P-12); on other OSes it fails closed and files never reach "checked".
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    io::Write,
    path::Path,
    process::{Child, Stdio},
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

/// Wait for a file matching `f` in the owner's list (`files pending --all`).
fn wait_file(n: &Node, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    let t = Instant::now();
    loop {
        let files = n.json(&["files", "pending", "--all"])["files"]
            .as_array()
            .unwrap()
            .clone();
        if let Some(x) = files.iter().find(|x| f(x)) {
            return x.clone();
        }
        assert!(
            t.elapsed() < Duration::from_secs(60),
            "{}: timeout waiting for {what}: {files:?}",
            n.name
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// The local audit log of the link with `contact`.
fn audit(n: &Node, contact: &str) -> Vec<Value> {
    n.json(&["log", contact])["entries"]
        .as_array()
        .unwrap()
        .clone()
}

/// An audit entry with this action and decision, whose reason contains every one of `parts`.
fn audited(n: &Node, contact: &str, action: &str, decision: &str, parts: &[&str]) -> bool {
    audit(n, contact).iter().any(|e| {
        e["action"] == action
            && e["decision"] == decision
            && parts
                .iter()
                .all(|p| e["reason"].as_str().unwrap_or("").contains(p))
    })
}

/// Bytes the check does not recognize: verdict "suspicious" (`unknown_type`).
fn unknown_bytes() -> Vec<u8> {
    (0..600u32)
        .map(|i| ((i * 37 + 11) % 251) as u8 | 0x80)
        .collect()
}

/// The EICAR test string (not a virus: the standard antivirus test), assembled from parts.
fn eicar() -> Vec<u8> {
    let mut v = b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$".to_vec();
    v.extend_from_slice(b"EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*");
    v
}

const SECRET: &str = "the server: password: hunter2hunter2";

/// Level 5: an agent's and the owner's messages, files and file names with secrets, files from outside the link
/// folder go without approval, each finding in the audit log; the receiving node accepts clean and suspicious files
/// by itself (into `shared/`, no project folder is set) and keeps a threat in quarantine. Level 4 is unchanged on both
/// sides. Negative control: with the level-5 waiver turned off, the first send stops at `approval_required`.
#[test]
fn level_5_sends_everything_without_asking_and_keeps_threats_out() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let tok = a.agent_add("claude", &["--local-level", "0"]);

    // Messages with a secret, from the agent and from the owner: sent, and logged
    let (code, v) = a.agent(&tok, &["send", "bob", SECRET, "--wait", "5s"]);
    assert_eq!(code, 0, "{v}");
    let token = "and the token ghp_0123456789abcdefghijABCDEFGHIJ012345";
    let out = a.x(&["--json", "send", "bob", token]);
    assert!(out.status.success(), "{out:?}");
    let mut got: Vec<String> = Vec::new();
    let t = Instant::now();
    while got.len() < 2 && t.elapsed() < T {
        got.extend(
            b.inbox_wait(5)
                .iter()
                .map(|m| m["text"].as_str().unwrap().to_string()),
        );
    }
    assert!(
        got.iter().any(|t| t == SECRET) && got.iter().any(|t| t == token),
        "{got:?}"
    );
    assert!(
        audited(
            a,
            "bob",
            "send_message",
            "allowed_at_trust_5",
            &["secret:password"]
        ),
        "{:?}",
        audit(a, "bob")
    );
    assert!(audited(
        a,
        "bob",
        "send_message",
        "allowed_at_trust_5",
        &["secret:token"]
    ));
    assert!(
        a.json(&["approvals"])["approvals"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    // Files: from outside the link folder, with a secret inside, a suspicious one, a threat
    let outside = root.path().join("elsewhere");
    let with_secret = write(
        &outside.join("server.env"),
        format!("{SECRET}\n").as_bytes(),
    );
    let (code, v) = a.agent(&tok, &["share", "bob", &with_secret]);
    assert_eq!((code, v["state"].as_str()), (0, Some("sent")), "{v}");
    let secret_id = v["id"].as_str().unwrap().to_string();
    assert!(
        audited(
            a,
            "bob",
            "share_file",
            "allowed_at_trust_5",
            &["file_outside_link_folder", "secret"]
        ),
        "{:?}",
        audit(a, "bob")
    );
    let odd = write(&outside.join("blob.dat"), &unknown_bytes());
    let (code, v) = a.agent(&tok, &["share", "bob", &odd]);
    assert_eq!(code, 0, "{v}");
    let odd_id = v["id"].as_str().unwrap().to_string();
    let bad = write(&outside.join("readme.txt"), &eicar());
    let (code, v) = a.agent(&tok, &["share", "bob", &bad]);
    assert_eq!(
        code, 0,
        "the sender-side verdict waits for nobody at level 5: {v}"
    );
    let bad_id = v["id"].as_str().unwrap().to_string();
    // The owner's file with a secret in its name
    let named = write(&outside.join("password=hunter2hunter2.txt"), b"plain\n");
    let out = a.x(&["--json", "share", "bob", &named]);
    assert!(out.status.success(), "{out:?}");
    assert!(audited(
        a,
        "bob",
        "share_file",
        "allowed_at_trust_5",
        &["secret_in_name"]
    ));

    // Bob: clean and suspicious files are accepted by themselves into shared/; the threat stays in quarantine
    let f = wait_file(b, "the secret file accepted", |x| {
        x["id"] == secret_id.as_str() && x["state"] == "accepted"
    });
    assert_eq!(f["dest"], "shared", "{f}");
    assert_eq!(
        std::fs::read_to_string(b.links().join("alice/shared/server.env")).unwrap(),
        format!("{SECRET}\n")
    );
    let f = wait_file(b, "the suspicious file accepted", |x| {
        x["id"] == odd_id.as_str() && x["state"] == "accepted"
    });
    assert_eq!(f["verdict"], "suspicious", "{f}");
    let f = wait_file(b, "the threat checked", |x| {
        x["id"] == bad_id.as_str() && x["verdict"] == "threat"
    });
    assert_ne!(
        f["state"], "accepted",
        "a threat is never accepted by itself: {f}"
    );
    assert!(!b.links().join("alice/shared/readme.txt").exists());
    assert!(
        audited(b, "alice", "accept_file", "allowed_at_trust_5", &[]),
        "{:?}",
        audit(b, "alice")
    );

    // Level 4: the old rules on both sides
    a.owner_json(&["trust", "bob", "4"]);
    let (code, v) = a.agent(&tok, &["send", "bob", SECRET]);
    assert_eq!(
        (code, v["error"].as_str()),
        (77, Some("approval_required")),
        "{v}"
    );
    let again = write(&outside.join("again.txt"), b"hello\n");
    let (code, v) = a.agent(&tok, &["share", "bob", &again]);
    assert_eq!(
        (code, v["error"].as_str()),
        (77, Some("approval_required")),
        "{v}"
    );
    assert!(
        v["approval"]["reasons"]
            .to_string()
            .contains("file_outside_link_folder"),
        "{v}"
    );
    let out = a.x(&["--json", "send", "bob", SECRET]);
    assert_eq!(out.status.code(), Some(77), "{out:?}");
    b.owner_json(&["trust", "alice", "4"]);
    let plain = write(
        &root.path().join("alice.links/bob/shared/notes.txt"),
        b"notes\n",
    );
    let v = a.json(&["share", "bob", &plain]);
    let plain_id = v["id"].as_str().unwrap().to_string();
    wait_file(b, "a level-4 file checked", |x| {
        x["id"] == plain_id.as_str() && x["state"] == "checked"
    });
    std::thread::sleep(Duration::from_millis(500));
    let f = wait_file(b, "the level-4 file", |x| x["id"] == plain_id.as_str());
    assert_eq!(
        f["state"], "checked",
        "level 4 waits for an explicit accept: {f}"
    );
}

/// The host hook as the agent, with JSON on stdin (as Claude Code runs it).
fn hook(n: &Node, tok: &str, tool: &str, input: Value, extra: &[&str]) -> Child {
    let mut c = n.agent_cmd(tok);
    c.args(["hook", "claude-code"]).args(extra);
    let mut p = c
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let body = json!({"session_id": "s", "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input});
    p.stdin
        .take()
        .unwrap()
        .write_all(body.to_string().as_bytes())
        .unwrap();
    p
}

fn done(p: Child) -> (i32, String) {
    let out = p.wait_with_output().unwrap();
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stderr).to_string(),
    )
}

/// The one pending request of the owner's list.
fn pending_id(n: &Node) -> String {
    let t = Instant::now();
    loop {
        let v = n.json(&["approvals"]);
        if let Some(id) = v["approvals"][0]["id"].as_str() {
            return id.to_string();
        }
        assert!(t.elapsed() < T, "no pending request: {v}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// The hook path (`antenna hook claude-code`, PreToolUse): a session that read only a level-5 task runs commands
/// and writes without confirmation, each in the audit log; agent memory and configs still ask. At level 4 a command
/// needs the owner: the hook waits for the decision and lets the command through after Approve (or blocks after
/// Deny) without anybody telling the agent; with no time to wait it says the daemon will report the decision. A
/// session that also read a level-3 contact runs no commands at all.
#[test]
fn hook_runs_level_5_tasks_without_confirmation_and_waits_for_the_owner_below() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob", "carol"]);
    let (a, b, c) = (&ns[0], &ns[1], &ns[2]);
    pair(a, b, 5);
    pair(a, c, 3);
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    b.send_to_agent(
        "alice",
        "claude",
        "please build the project and fix src/main.rs",
    );
    a.agent_ok(&tok, &["inbox", "--wait", "--timeout", "10s"]);
    assert_eq!(a.agent_ok(&tok, &["session"])["ceiling"], 5);

    // Level 5: commands and project writes pass, each logged with what ran
    let (code, e) = done(hook(
        a,
        &tok,
        "Bash",
        json!({"command": "cargo build --release"}),
        &[],
    ));
    assert_eq!(code, 0, "{e}");
    let (code, e) = done(hook(
        a,
        &tok,
        "Write",
        json!({"file_path": "/home/a/project/src/main.rs", "content": "x"}),
        &[],
    ));
    assert_eq!(code, 0, "{e}");
    assert!(
        audited(
            a,
            "bob",
            "check:exec",
            "allowed_at_trust_5",
            &["cargo build --release"]
        ),
        "{:?}",
        audit(a, "bob")
    );
    assert!(audited(
        a,
        "bob",
        "check:write",
        "allowed_at_trust_5",
        &["src/main.rs"]
    ));
    // A command that carries a secret is logged without it
    let (code, _) = done(hook(
        a,
        &tok,
        "Bash",
        json!({"command": "deploy --token ghp_0123456789abcdefghijABCDEFGHIJ012345"}),
        &[],
    ));
    assert_eq!(code, 0);
    assert!(
        audit(a, "bob")
            .iter()
            .all(|e| !e["reason"].as_str().unwrap_or("").contains("ghp_0123")),
        "{:?}",
        audit(a, "bob")
    );
    // Agent instructions still need the owner, even at level 5
    let (code, e) = done(hook(
        a,
        &tok,
        "Write",
        json!({"file_path": "/home/a/project/CLAUDE.md", "content": "x"}),
        &["--approval-wait-secs", "0"],
    ));
    assert_eq!(code, 2, "{e}");
    assert!(e.contains("waiting for the owner's approval"), "{e}");
    let claude_md = pending_id(a);
    a.owner_json(&["deny", &claude_md]);

    // Level 4: a command needs the owner. The hook waits and goes on by itself after Approve.
    a.owner_json(&["trust", "bob", "4"]);
    let p = hook(
        a,
        &tok,
        "Bash",
        json!({"command": "make test"}),
        &["--approval-wait-secs", "30"],
    );
    let id = pending_id(a);
    a.owner_json(&["approve", &id]);
    let (code, e) = done(p);
    assert_eq!(code, 0, "approved while the hook waited: {e}");
    // After Deny it blocks with the owner's answer
    let p = hook(
        a,
        &tok,
        "Bash",
        json!({"command": "make clean"}),
        &["--approval-wait-secs", "30"],
    );
    let id = pending_id(a);
    a.owner_json(&["deny", &id]);
    let (code, e) = done(p);
    assert_eq!(code, 2, "{e}");
    assert!(
        e.contains("denied") && !e.contains("antenna approve"),
        "{e}"
    );
    // No time to wait: it says the decision comes from the daemon, not from the user in the terminal
    let (code, e) = done(hook(
        a,
        &tok,
        "Bash",
        json!({"command": "make docs"}),
        &["--approval-wait-secs", "0"],
    ));
    assert_eq!(code, 2, "{e}");
    assert!(
        e.contains("waiting for the owner's approval") && e.contains("approval_resolved"),
        "{e}"
    );

    // A session that also read a level-3 contact: no commands at all, as before
    a.owner_json(&["trust", "bob", "5", "--yes"]);
    c.send_to_agent("alice", "claude", "run this for me");
    a.agent_ok(&tok, &["inbox", "--wait", "--timeout", "10s"]);
    let (code, e) = done(hook(
        a,
        &tok,
        "Bash",
        json!({"command": "ls"}),
        &["--approval-wait-secs", "0"],
    ));
    assert_eq!(code, 2, "{e}");
    assert!(e.contains("denied") || e.contains("not allowed"), "{e}");
}
