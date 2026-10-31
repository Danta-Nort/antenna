// SPDX-License-Identifier: AGPL-3.0-only
//! A received file whose name is already taken in the link folder (preview.8, found on a real Mac: re-sent release files
//! with the same BLAKE3 could not be accepted at all). The same content is accepted without a second copy, by the owner
//! and by the daemon itself at level 5; another file with that name is saved under the next free number,
//! `name (2).ext` (D-128), unless the owner gave a name of their own. Real `antennad` and `antenna`.

// The file check needs the worker sandbox (D-P-12); on other OSes it fails closed and files never reach "checked".
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    path::Path,
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

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

/// The newest file in the owner's list (`files pending --all`) that matches `f`.
fn wait_file(n: &Node, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    let t = Instant::now();
    loop {
        let files = n.json(&["files", "pending", "--all"])["files"]
            .as_array()
            .unwrap()
            .clone();
        if let Some(x) = files.iter().rev().find(|x| f(x)) {
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

fn names_in(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// Level 3: the owner accepts a re-sent identical file in one step (`duplicate: true`, nothing new written); a
/// different file with the same name is saved as `notes (2).txt` (D-128), and refused with `file_name_taken` only
/// under a taken name the owner chose. Seen failing before the fix: the second accept answered `file_name_taken` (and
/// the window's dialog then did nothing).
#[test]
fn the_owner_accepts_a_resent_identical_file_without_a_second_copy() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    let path = write(&root.path().join("out/notes.txt"), b"the same notes\n");
    for round in 0..2 {
        let o = a.x(&["--json", "share", "bob", &path]);
        assert!(o.status.success(), "{o:?}");
        let f = wait_file(b, "checked", |x| {
            x["state"] == "checked" && x["name"] == "notes.txt"
        });
        let acc = b.json(&["files", "accept", f["id"].as_str().unwrap()]);
        assert_eq!(acc["state"], "accepted", "round {round}: {acc}");
        assert_eq!(acc["saved_as"], "notes.txt", "{acc}");
        assert_eq!(
            acc["duplicate"].as_bool().unwrap_or(false),
            round == 1,
            "round {round}: {acc}"
        );
    }
    let shared = b.links().join("alice").join("shared");
    assert_eq!(
        names_in(&shared),
        ["notes.txt"],
        "one copy, no 'notes (2).txt'"
    );
    // Another file with the same name: with the owner's own `--name` taken, refused as before; without one, saved
    // under the next free number (D-128), the first copy untouched.
    let other = write(&root.path().join("other/notes.txt"), b"different notes\n");
    let o = a.x(&["--json", "share", "bob", &other]);
    assert!(o.status.success(), "{o:?}");
    let f = wait_file(b, "the different file", |x| {
        x["state"] == "checked" && x["name"] == "notes.txt"
    });
    let id = f["id"].as_str().unwrap();
    let o = b.x(&["--json", "files", "accept", id, "--name", "NOTES.txt"]);
    assert!(!o.status.success());
    assert_eq!(last_json(&o.stdout)["error"], "file_name_taken", "{o:?}");
    let acc = b.json(&["files", "accept", id]);
    assert_eq!(acc["state"], "accepted", "{acc}");
    assert_eq!(acc["saved_as"], "notes (2).txt", "{acc}");
    assert_eq!(names_in(&shared), ["notes (2).txt", "notes.txt"]);
    assert_eq!(
        std::fs::read(shared.join("notes.txt")).unwrap(),
        b"the same notes\n"
    );
    assert_eq!(
        std::fs::read(shared.join("notes (2).txt")).unwrap(),
        b"different notes\n"
    );
}

/// The field report of 2026-10-06: an agent re-sent `DECISIONS.md` with new content to a level-5 own computer three
/// times over an afternoon; the recipient's `shared/` kept the first copy, nothing else was saved, and the sending
/// agent saw "sent" and could not tell. Now (D-128) the daemon saves new content under the next free number,
/// `DECISIONS (2).md`, and the same content again is that file, without a copy. The recipient's records and its agent's
/// `inbox` name the saved file; the sender's node gets `name_number` in the receipt (`file-saved-as/0`), so the sending
/// agent is told the name, and the sender's audit log says it. Negative control (seen failing): without the number the
/// second version stays in quarantine and the test times out waiting for it to be accepted.
#[test]
fn at_level_5_new_content_under_a_taken_name_is_saved_under_the_next_number() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let writer = a.agent_add("writer", &["--local-level", "0"]);
    let reader = b.agent_add("reader", &["--local-level", "0"]);
    let src = a.links().join("bob/shared/DECISIONS.md");
    let shared = b.links().join("alice").join("shared");
    let rounds: [(&[u8], &str); 3] = [
        (b"# Decisions\nv1\n", "DECISIONS.md"),
        (b"# Decisions\nv2, with more\n", "DECISIONS (2).md"),
        (b"# Decisions\nv2, with more\n", "DECISIONS (2).md"),
    ];
    for (round, (body, saved)) in rounds.iter().enumerate() {
        write(&src, body);
        let r = a.agent_ok(&writer, &["share", "bob", src.to_str().unwrap()]);
        let id = r["file"]["id"]
            .as_str()
            .or(r["id"].as_str())
            .unwrap()
            .to_string();
        let f = wait_file(b, "the daemon's own accept", |x| {
            x["id"] == id.as_str() && x["state"] == "accepted"
        });
        assert_eq!(f["saved_as"], *saved, "round {round}: {f}");
        assert_eq!(std::fs::read(shared.join(saved)).unwrap(), *body);
        // The same content again is that file: no third copy
        assert_eq!(names_in(&shared).len(), round.min(1) + 1, "round {round}");
        // The sending agent learns it was accepted and saved, and under which name when it is not the offered one
        let t = Instant::now();
        let answer = loop {
            let v = a.agent_ok(&writer, &["inbox", "--wait", "--timeout", "5s"]);
            if let Some(x) = v["files"]
                .as_array()
                .and_then(|f| f.iter().find(|x| x["id"] == id.as_str()).cloned())
            {
                break x;
            }
            assert!(
                t.elapsed() < Duration::from_secs(60),
                "round {round}: the sending agent was not told"
            );
        };
        assert_eq!(answer["direction"], "out", "{answer}");
        assert_eq!(answer["state"], "accepted", "{answer}");
        if round == 0 {
            assert!(answer["saved_as"].is_null(), "{answer}");
        } else {
            assert_eq!(answer["saved_as"], "DECISIONS (2).md", "{answer}");
        }
    }
    assert_eq!(names_in(&shared), ["DECISIONS (2).md", "DECISIONS.md"]);
    assert_eq!(
        std::fs::read(shared.join("DECISIONS.md")).unwrap(),
        b"# Decisions\nv1\n",
        "the first copy is untouched"
    );
    let pending = b.json(&["files", "pending"])["files"]
        .as_array()
        .unwrap()
        .clone();
    assert!(pending.is_empty(), "nothing waits: {pending:?}");
    // The recipient's agent gets the saved files with their names and paths
    let v = b.agent_ok(&reader, &["inbox"]);
    let files = v["files"].as_array().cloned().unwrap_or_default();
    let numbered = files
        .iter()
        .find(|x| x["saved_as"] == "DECISIONS (2).md" && x["duplicate"].as_bool() != Some(true))
        .unwrap_or_else(|| panic!("the reader has the numbered copy: {v}"));
    assert_eq!(numbered["name"], "DECISIONS.md");
    assert!(
        numbered["saved_path"]
            .as_str()
            .is_some_and(|p| p.ends_with("shared/DECISIONS (2).md")),
        "{numbered}"
    );
    // The sender's audit log has the contact's receipt with the number
    let log = a.json(&["log", "bob"]);
    assert!(
        log["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["source"] == "dag"
                && e["author"] == "contact"
                && e["action"] == "accept_file"
                && e["reason"] == "saved as copy (2)"),
        "{log}"
    );
}

/// A level-5 file the daemon cannot save by itself for another reason (here the link's `shared` is not a folder) is
/// not dropped silently: it waits for the owner with the reason in `held` (D-128), and the owner's accept, once the
/// folder is fixed, saves it and clears the reason.
#[test]
fn at_level_5_a_file_that_cannot_be_saved_waits_with_the_reason() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let shared = b.links().join("alice").join("shared");
    write(&shared, b"not a folder");
    let path = write(&root.path().join("out/plan.txt"), b"the plan\n");
    let o = a.x(&["--json", "share", "bob", &path]);
    assert!(o.status.success(), "{o:?}");
    let f = wait_file(b, "held", |x| {
        x["state"] == "checked" && x["name"] == "plan.txt" && !x["held"].is_null()
    });
    assert_eq!(f["held"]["code"], "forbidden", "{f}");
    let o = b.x(&["files", "pending"]);
    let human = String::from_utf8_lossy(&o.stdout);
    assert!(human.contains("not saved by itself: forbidden"), "{human}");
    std::fs::remove_file(&shared).unwrap();
    let acc = b.json(&["files", "accept", f["id"].as_str().unwrap()]);
    assert_eq!(acc["state"], "accepted", "{acc}");
    assert!(acc["held"].is_null(), "{acc}");
    assert_eq!(
        std::fs::read(shared.join("plan.txt")).unwrap(),
        b"the plan\n"
    );
}

/// Level 5: the daemon accepts a re-sent identical file by itself instead of leaving it in quarantine (the release
/// files the maintainer's Mac received twice).
#[test]
fn at_level_5_a_resent_identical_file_is_accepted_by_itself() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let path = write(
        &root
            .path()
            .join("out/antenna-0.1.0-preview.7-manifest.json"),
        b"{\"not\":\"a real manifest\"}\n",
    );
    let name = "antenna-0.1.0-preview.7-manifest.json";
    for round in 1..=2 {
        let o = a.x(&["--json", "share", "bob", &path]);
        assert!(o.status.success(), "{o:?}");
        let t = Instant::now();
        loop {
            let all = b.json(&["files", "pending", "--all"])["files"]
                .as_array()
                .unwrap()
                .clone();
            let accepted = all
                .iter()
                .filter(|x| x["state"] == "accepted" && x["name"] == name)
                .count();
            if accepted == round {
                break;
            }
            assert!(
                t.elapsed() < Duration::from_secs(60),
                "round {round}: the copy was not accepted by the daemon: {all:?}"
            );
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    let pending: Vec<Value> = b.json(&["files", "pending"])["files"]
        .as_array()
        .unwrap()
        .clone();
    assert!(
        pending.is_empty(),
        "nothing left for the owner: {pending:?}"
    );
    let shared = b.links().join("alice").join("shared");
    assert_eq!(
        names_in(&shared),
        ["antenna-0.1.0-preview.7-manifest.json"],
        "one copy"
    );
}

/// One owner request with a session held by the test: the final reply line (`ok` or `err`).
fn raw_owner(n: &Node, req: Value) -> Value {
    use std::io::{BufRead, BufReader, Write};
    let held = n.held_session();
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = serde_json::json!({"hello": {"proto": "x-control/7", "role": "owner", "session": held.token}});
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", serde_json::json!({ "req": req })).unwrap();
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if v.get("ok").is_some() || v.get("err").is_some() {
            return v;
        }
    }
    Value::Null
}

/// `file_name_check` answers before any accept: the contact's name is `free` when unused, `same_file` when the
/// identical file is there, `taken` with a free name when another file has it (ignoring case), `invalid` for a name the
/// rules refuse; accepting under the suggested name works. The agent has no such command.
#[test]
fn the_daemon_names_a_free_name_and_checks_a_new_one() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    let first = write(&root.path().join("one/report.tar.gz"), b"first\n");
    let o = a.x(&["--json", "share", "bob", &first]);
    assert!(o.status.success(), "{o:?}");
    let f = wait_file(b, "checked", |x| x["state"] == "checked");
    let id1 = f["id"].as_str().unwrap().to_string();
    let r = raw_owner(b, serde_json::json!({"cmd": "file_name_check", "id": id1}));
    assert_eq!(r["ok"]["state"], "free", "{r}");
    b.json(&["files", "accept", &id1]);

    // The same file again: same_file. Another one with the name: taken, and the first free name is offered.
    let o = a.x(&["--json", "share", "bob", &first]);
    assert!(o.status.success());
    let again = wait_file(b, "the copy", |x| x["state"] == "checked");
    let r = raw_owner(
        b,
        serde_json::json!({"cmd": "file_name_check", "id": again["id"]}),
    );
    assert_eq!(r["ok"]["state"], "same_file", "{r}");
    b.json(&["files", "accept", again["id"].as_str().unwrap()]);
    let other = write(&root.path().join("two/report.tar.gz"), b"second\n");
    let o = a.x(&["--json", "share", "bob", &other]);
    assert!(o.status.success());
    let f2 = wait_file(b, "the other file", |x| x["state"] == "checked");
    let id2 = f2["id"].as_str().unwrap().to_string();
    let r = raw_owner(b, serde_json::json!({"cmd": "file_name_check", "id": id2}));
    assert_eq!(r["ok"]["state"], "taken", "{r}");
    assert_eq!(
        r["ok"]["suggestion"], "report (2).tar.gz",
        "a double extension stays whole: {r}"
    );
    let r = raw_owner(
        b,
        serde_json::json!({"cmd": "file_name_check", "id": id2, "name": "REPORT.tar.gz"}),
    );
    assert_eq!(r["ok"]["state"], "taken", "ignoring case: {r}");
    let r = raw_owner(
        b,
        serde_json::json!({"cmd": "file_name_check", "id": id2, "name": "../x"}),
    );
    assert_eq!(r["ok"]["state"], "invalid", "{r}");
    assert!(
        r["ok"]["message"].as_str().is_some_and(|m| !m.is_empty()),
        "{r}"
    );
    let r = raw_owner(
        b,
        serde_json::json!({"cmd": "file_name_check", "id": id2, "name": "notes-2.txt"}),
    );
    assert_eq!(r["ok"]["state"], "free", "{r}");
    let acc = b.json(&["files", "accept", &id2, "--name", "report (2).tar.gz"]);
    assert_eq!(acc["saved_as"], "report (2).tar.gz", "{acc}");
    let shared = b.links().join("alice").join("shared");
    assert_eq!(names_in(&shared), ["report (2).tar.gz", "report.tar.gz"]);
}
