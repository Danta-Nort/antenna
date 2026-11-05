// SPDX-License-Identifier: AGPL-3.0-only
//! What an agent is given (`docs/CONTROL.md` §14, §20): every message whole and nothing marked read that it was not
//! given; files saved for it, with where they are and their SHA-256 next to BLAKE3; the answer about a file it sent;
//! the agent CLI with global options before the command. Real daemons, real CLI.
//!
//! Run: `cargo test -p antenna-cli --test agent_view` (from the workspace root; `cargo build -p antennad` first when
//! running a single package).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::path::Path;
use std::time::{Duration, Instant};

use common::*;

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

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout waiting for {what}");
        std::thread::sleep(Duration::from_millis(150));
    }
}

fn incoming_texts(n: &Node, contact: &str) -> usize {
    n.json(&["history", contact, "--limit", "500"])["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"] == "text" && m["direction"] == "in")
        .count()
}

fn sha256_hex(b: &[u8]) -> String {
    data_encoding_hex(&antenna_core::crypto::sha256(&[b]))
}

fn data_encoding_hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Long messages: one `inbox` reply holds at most 32,000 characters of text (the first message always whole), and
/// what does not fit stays unread for the next call, so an MCP host that cuts a long tool result never makes the
/// daemon mark unseen text as read. The human output of the agent CLI gives each message whole, a command line in it
/// on one line. Negative control (seen failing): with the budget off, the first call returns all three messages.
#[test]
fn an_agent_gets_every_message_whole_and_the_rest_waits_unread() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    let tok = a.agent_add("builder", &["--local-level", "0"]);
    for (i, c) in ["a", "b", "c"].iter().enumerate() {
        let text = format!("part {i}: {}", c.repeat(20_000));
        let s = b.send_to_agent("alice", "builder", &text);
        assert_eq!(s["type"], "sent", "{s}");
    }
    wait_until("three messages at alice", T, || {
        incoming_texts(a, "bob") == 3
    });

    let mut got = Vec::new();
    for round in 0..3 {
        let v = a.agent_ok(&tok, &["inbox"]);
        let msgs = v["messages"].as_array().unwrap();
        assert_eq!(
            msgs.len(),
            1,
            "round {round}: one 20,000-character message per reply: {}",
            msgs.len()
        );
        let t = msgs[0]["text"].as_str().unwrap();
        assert_eq!(t.chars().count(), 20_008, "whole");
        got.push(t[..6].to_string());
        assert_eq!(
            v["more"] == true,
            round < 2,
            "round {round}: more = {}",
            v["more"]
        );
    }
    assert_eq!(got, ["part 0", "part 1", "part 2"]);
    let v = a.agent_ok(&tok, &["inbox"]);
    assert!(v["messages"].as_array().unwrap().is_empty(), "{v}");

    // The human output: a message longer than a screen comes whole, a command in it on one line
    let cmd = format!(
        "cargo test --manifest-path /srv/{}/Cargo.toml -- --nocapture",
        "x".repeat(90)
    );
    let text = format!("Please run:\n{cmd}\n{}", "z".repeat(6_000));
    b.send_to_agent("alice", "builder", &text);
    wait_until("the fourth message", T, || incoming_texts(a, "bob") == 4);
    let out = a.agent_cmd(&tok).args(["inbox"]).output().unwrap();
    assert!(out.status.success(), "{out:?}");
    let s = String::from_utf8(out.stdout).unwrap();
    assert!(s.lines().any(|l| l == format!("    │ {cmd}")), "{s}");
    assert!(s.contains(&"z".repeat(6_000)), "the whole text");
    assert!(!s.contains("not shown"), "{s}");

    // A global option before the command (the field report: "no such command: <the data dir>")
    let dir = a.dir.to_string_lossy().to_string();
    let agent_cli = |args: &[&str]| {
        std::process::Command::new(x_bin())
            .clean_env()
            .env("ANTENNA_AGENT_TOKEN", &tok)
            .args(args)
            .output()
            .unwrap()
    };
    let out = agent_cli(&["--data-dir", &dir, "--json", "inbox"]);
    assert!(out.status.success(), "{out:?}");
    let out = agent_cli(&["--json", "--data-dir", &dir, "agent", "tasks", "builder"]);
    assert_eq!(out.status.code(), Some(2), "{out:?}");
    assert_eq!(last_json(&out.stdout)["command"], "agent", "{out:?}");
    let out = agent_cli(&["--data-dir", &dir, "agent", "tasks", "builder"]);
    assert_eq!(out.status.code(), Some(2), "{out:?}");
    let err = String::from_utf8(out.stderr).unwrap();
    assert!(
        err.contains("`antenna agent tasks` is the owner's command"),
        "{err}"
    );
    assert!(
        !err.contains(&format!("{dir:?}")),
        "the data dir is not a command: {err}"
    );
}

/// A file the daemon accepts by itself from an own computer (trust level 5, D-99) used to be nowhere an agent looks.
/// Now each agent that may see its offer gets it in `inbox` (name, where it is, size, SHA-256 and BLAKE3) after a fact
/// in `wait`; `files list` lists saved files with their paths; the agent's history has the offer; an offer addressed
/// to one agent reaches only that agent; and the agent that sent a file is told the contact accepted and saved it.
/// Negative controls (seen failing): no notice made on accept (the agent's inbox has no file); the offer rule left
/// out of the notice (the other agent is told of a file addressed to `builder`).
#[test]
fn files_saved_for_an_agent_reach_it_with_their_path_and_hashes() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let builder = a.agent_add("builder", &["--local-level", "0"]);
    let other = a.agent_add("other", &["--local-level", "0"]);
    let sender = b.agent_add("sender", &["--local-level", "0"]);

    // Bob in person shares a file with no address: every agent of Alice with the link may see it
    let body = b"hello from the server\n".repeat(40);
    let src = b.links().join("alice/shared/report.txt");
    std::fs::create_dir_all(src.parent().unwrap()).unwrap();
    std::fs::write(&src, &body).unwrap();
    let out = b.x(&["--json", "share", "alice", src.to_str().unwrap()]);
    assert!(out.status.success(), "{out:?}");
    let shared = last_json(&out.stdout);
    let id = shared["file"]["id"]
        .as_str()
        .or(shared["id"].as_str())
        .unwrap()
        .to_string();
    assert_eq!(
        shared["file"]["sha256"]
            .as_str()
            .or(shared["sha256"].as_str()),
        Some(sha256_hex(&body).as_str()),
        "the sender's reply has the SHA-256: {shared}"
    );

    // `wait` ends with a fact about the saved file (no name), `inbox` gives the whole record
    let (c, w) = a.agent(&builder, &["wait", "--timeout", "30s"]);
    assert_eq!(c, 0, "{w}");
    let facts = w["files"].as_array().cloned().unwrap_or_default();
    assert!(
        facts
            .iter()
            .any(|f| f["id"] == id.as_str() && f["state"] == "accepted"),
        "{w}"
    );
    assert!(
        !w.to_string().contains("report.txt"),
        "no name in a fact: {w}"
    );
    let v = a.agent_ok(&builder, &["inbox"]);
    let files = v["files"].as_array().unwrap();
    assert_eq!(files.len(), 1, "{v}");
    let f = &files[0];
    assert_eq!(f["id"], id.as_str());
    assert_eq!(f["name"], "report.txt");
    assert_eq!(f["size"], body.len());
    assert_eq!(f["sha256"], sha256_hex(&body).as_str(), "{f}");
    assert_eq!(f["blake3"].as_str().unwrap().len(), 64);
    let path = f["saved_path"].as_str().unwrap();
    assert_eq!(
        std::fs::read(path).unwrap(),
        body,
        "the file is where the notice says"
    );
    assert!(
        v["session"]["tainted_by"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["contact"] == "bob"),
        "a file's name is the contact's data: {v}"
    );
    // Given once
    let v = a.agent_ok(&builder, &["inbox"]);
    assert!(v["files"].as_array().is_none_or(|f| f.is_empty()), "{v}");

    // `files list` (and `files pending --all`) lists it with its path; `files pending` does not
    let list = a.agent_ok(&builder, &["files", "list"]);
    let saved = list["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == id.as_str())
        .cloned()
        .unwrap_or_else(|| panic!("{list}"));
    assert_eq!(saved["state"], "accepted");
    assert_eq!(saved["saved_path"], path);
    assert_eq!(saved["sha256"], sha256_hex(&body).as_str());
    let pending = a.agent_ok(&builder, &["files", "pending"]);
    assert!(
        !pending["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["id"] == id.as_str()),
        "{pending}"
    );
    let human = a
        .agent_cmd(&builder)
        .args(["files", "list"])
        .output()
        .unwrap();
    let human = String::from_utf8(human.stdout).unwrap();
    assert!(human.contains(path), "{human}");

    // The agent's history has the offer (an unaddressed one is every agent's, as in files_pending)
    let h = a.agent_ok(&builder, &["history", "bob"]);
    assert!(
        h["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["kind"] == "file"),
        "{h}"
    );

    // Bob's agent sends a file to Alice's builder only: builder is told, `other` is not, and the sender learns it
    // was accepted and saved
    let body2 = b"build log line\n".repeat(30);
    let src2 = b.links().join("alice/shared/build.log");
    std::fs::write(&src2, &body2).unwrap();
    let r = b.agent_ok(
        &sender,
        &[
            "share",
            "alice",
            src2.to_str().unwrap(),
            "--to-agent",
            "builder",
        ],
    );
    let id2 = r["file"]["id"]
        .as_str()
        .or(r["id"].as_str())
        .unwrap()
        .to_string();
    let t = Instant::now();
    let rec = loop {
        let v = a.agent_ok(&builder, &["inbox", "--wait", "--timeout", "5s"]);
        if let Some(f) = v["files"]
            .as_array()
            .and_then(|f| f.iter().find(|x| x["id"] == id2.as_str()).cloned())
        {
            break f;
        }
        assert!(t.elapsed() < T, "builder was not told of build.log");
    };
    assert_eq!(rec["name"], "build.log");
    assert_eq!(rec["sha256"], sha256_hex(&body2).as_str());
    let v = a.agent_ok(&other, &["inbox"]);
    let files = v["files"].as_array().cloned().unwrap_or_default();
    assert!(
        files.iter().all(|x| x["id"] != id2.as_str()),
        "a file for builder is not other's business: {v}"
    );
    assert!(
        files.iter().any(|x| x["id"] == id.as_str()),
        "the unaddressed one is: {v}"
    );
    let t = Instant::now();
    let answer = loop {
        let v = b.agent_ok(&sender, &["inbox", "--wait", "--timeout", "5s"]);
        if let Some(f) = v["files"]
            .as_array()
            .and_then(|f| f.iter().find(|x| x["id"] == id2.as_str()).cloned())
        {
            break f;
        }
        assert!(t.elapsed() < T, "the sender was not told");
    };
    assert_eq!(answer["direction"], "out");
    assert_eq!(answer["state"], "accepted", "{answer}");
    assert_eq!(answer["name"], "build.log");
    assert_eq!(answer["sha256"], sha256_hex(&body2).as_str());
    // The owner's own file told no agent of Bob's: the owner sent it
    let out = b.agent_cmd(&sender).args(["inbox"]).output().unwrap();
    assert!(
        !String::from_utf8(out.stdout)
            .unwrap()
            .contains("report.txt")
    );

    // Through MCP: `list_files` gives the saved files with their paths and hashes
    let mut m = Mcp::start(a, &other);
    let (is_err, v) = m.call("list_files", serde_json::json!({}));
    assert!(!is_err, "{v}");
    let listed = v["files"].as_array().unwrap();
    let f = listed
        .iter()
        .find(|x| x["id"] == id.as_str())
        .unwrap_or_else(|| panic!("{v}"));
    assert_eq!(f["saved_path"], path);
    assert_eq!(f["sha256"], sha256_hex(&body).as_str());
    assert!(
        listed.iter().all(|x| x["id"] != id2.as_str()),
        "the file for builder is not listed for other: {v}"
    );
    m.stop();
}

/// What needs the owner's authority is set when the owner makes the agent (D-124), not sent later as one agent's
/// message to another: `agent setup` and `agent add --dir` show the plan and write it after the owner's yes, never
/// over an existing file; without a yes nothing is written; an unknown agent is refused; the agent itself has no such
/// command (`tests/agents.rs`).
#[test]
fn the_owner_sets_up_an_agents_folder_once() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice"]);
    let a = &ns[0];
    a.agent_add("dev", &["--local-level", "5"]);
    let dir = root.path().join("project");
    std::fs::create_dir(&dir).unwrap();
    let d = dir.to_str().unwrap();
    std::fs::write(dir.join("AGENTS.md"), "the owner's own\n").unwrap();
    let setup = [
        "agent",
        "setup",
        "dev",
        "--dir",
        d,
        "--instructions",
        "--git-name",
        "Robin Example",
        "--git-email",
        "robin@example.com",
        "--allow",
        "antenna-tools,git",
    ];

    // Without a yes (no terminal): the plan is shown, nothing is written
    let out = a.x(&setup);
    assert!(out.status.success(), "{out:?}");
    let shown = String::from_utf8(out.stdout).unwrap();
    assert!(
        shown.contains("CLAUDE.md") && shown.contains("@AGENTS.md"),
        "{shown}"
    );
    assert!(
        shown.contains("keep ") && shown.contains("AGENTS.md as it is"),
        "{shown}"
    );
    assert!(shown.contains("mcp__antenna, Bash(git:*)"), "{shown}");
    assert!(shown.contains("Nothing was changed"), "{shown}");
    assert!(!dir.join("CLAUDE.md").exists() && !dir.join(".claude").exists());

    // With the yes: done, the owner's AGENTS.md kept
    let mut yes = vec!["--json"];
    yes.extend_from_slice(&setup);
    yes.push("--yes");
    let v = last_json(&a.x(&yes).stdout);
    assert_eq!(v["done"], true, "{v}");
    assert_eq!(
        std::fs::read_to_string(dir.join("AGENTS.md")).unwrap(),
        "the owner's own\n"
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("CLAUDE.md")).unwrap(),
        "@AGENTS.md\n"
    );
    let s: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join(".claude/settings.json")).unwrap())
            .unwrap();
    assert_eq!(
        s["permissions"]["allow"],
        serde_json::json!(["mcp__antenna", "Bash(git:*)"])
    );
    let email = std::process::Command::new("git")
        .args(["-C", d, "config", "--local", "--get", "user.email"])
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8_lossy(&email.stdout).trim(),
        "robin@example.com"
    );
    // Once: the same again finds nothing to do
    let v = last_json(&a.x(&yes).stdout);
    assert!(
        v["steps"]
            .as_array()
            .unwrap()
            .iter()
            .all(|s| s["step"] == "keep_file"),
        "{v}"
    );

    // An unknown agent, and nothing chosen
    let out = a.x(&[
        "--json",
        "agent",
        "setup",
        "nobody",
        "--dir",
        d,
        "--instructions",
        "--yes",
    ]);
    assert_eq!(last_json(&out.stdout)["error"], "not_found", "{out:?}");
    let out = a.x(&["--json", "agent", "setup", "dev", "--dir", d]);
    assert_eq!(last_json(&out.stdout)["error"], "bad_request", "{out:?}");

    // `agent add --dir`: the new agent's folder, set up in the same command after its yes
    let fresh = root.path().join("fresh");
    std::fs::create_dir(&fresh).unwrap();
    let v = a.owner_json(&[
        "agent",
        "add",
        "codex-dev",
        "--local-level",
        "5",
        "--app",
        "codex",
        "--dir",
        fresh.to_str().unwrap(),
        "--instructions",
        "--yes",
    ]);
    assert_eq!(v["done"], true, "{v}");
    let agents = std::fs::read_to_string(fresh.join("AGENTS.md")).unwrap();
    assert!(agents.contains("the agent `codex-dev`"), "{agents}");
    assert!(
        !fresh.join("CLAUDE.md").exists(),
        "Codex gets AGENTS.md only"
    );
}

/// A contact label with spaces ("atlas server") breaks commands that name its folder, so a new link's folder is the
/// label as one shell word (`atlas-server`, D-125) while the label stays the display name; a folder made before under
/// the label as it is keeps receiving files (no silent move).
#[test]
fn a_label_with_spaces_gets_a_folder_a_shell_takes_as_one_word() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let send = |name: &str| -> String {
        let src = root.path().join(name);
        std::fs::write(&src, format!("{name}\n")).unwrap();
        let out = b.x(&["--json", "share", "alice", src.to_str().unwrap()]);
        assert!(out.status.success(), "{out:?}");
        let id = last_json(&out.stdout)["id"].as_str().unwrap().to_string();
        let t = Instant::now();
        loop {
            let files = a.json(&["files", "pending", "--all"]);
            if let Some(p) = files["files"].as_array().unwrap().iter().find_map(|f| {
                (f["id"] == id.as_str() && f["state"] == "accepted")
                    .then(|| f["saved_path"].as_str().unwrap().to_string())
            }) {
                return p;
            }
            assert!(t.elapsed() < T, "{name} not saved: {files}");
            std::thread::sleep(Duration::from_millis(150));
        }
    };
    a.json(&["rename", "bob", "atlas server"]);
    let p = send("one.txt");
    // Canonical paths on both sides: on macOS the temporary folder is /var/…, a symlink to /private/var/…
    assert_eq!(
        Path::new(&p).canonicalize().unwrap(),
        a.links()
            .join("atlas-server/shared/one.txt")
            .canonicalize()
            .unwrap(),
        "{p}"
    );
    assert_eq!(
        a.contact("atlas server")["label"],
        "atlas server",
        "the label is the display name"
    );
    // An agent learns the folder from its contacts
    let tok = a.agent_add("dev", &["--local-level", "0"]);
    let c = a.agent_ok(&tok, &["contacts"]);
    let folder = c["contacts"][0]["folder"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert_eq!(
        Path::new(&folder).canonicalize().unwrap(),
        a.links().join("atlas-server").canonicalize().unwrap(),
        "{c}"
    );
    // A folder from before under the label as it is
    std::fs::create_dir_all(a.links().join("old box/shared")).unwrap();
    a.json(&["rename", "atlas server", "old box"]);
    let p = send("two.txt");
    assert_eq!(
        Path::new(&p).canonicalize().unwrap(),
        a.links()
            .join("old box/shared/two.txt")
            .canonicalize()
            .unwrap(),
        "{p}"
    );
}
