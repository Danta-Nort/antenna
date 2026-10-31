// SPDX-License-Identifier: AGPL-3.0-only
//! Migration from the preview build `x` (D-56): a node created under the old names (`~/.local/share/x`, `x.db`, the
//! `xd.sock` socket, `~/X/links`) starts, after the update, with `antennad` without directory arguments; the data is
//! moved once, and the keys, link, history and link folders are in place. While the old daemon is running, `antennad`
//! does not touch the directory.
//!
//! Run: `cargo test -p antenna-cli --test migration -- --nocapture` (from the workspace root, so that
//! `antennad`).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

use common::*;

fn texts(n: &Node, contact: &str) -> Vec<String> {
    n.json(&["history", contact, "--limit", "100"])["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"] == "text")
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect()
}

/// Rename the node's DB files the way the preview build named them.
fn to_preview_names(dir: &Path) {
    for suffix in ["", "-wal", "-shm"] {
        let from = dir.join(format!("antenna.db{suffix}"));
        if from.exists() {
            std::fs::rename(&from, dir.join(format!("x.db{suffix}"))).unwrap();
        }
    }
    // After a crash of the old daemon its socket file remains.
    std::fs::write(dir.join("xd.sock"), b"").unwrap();
}

#[test]
fn preview_node_is_migrated_once_with_keys_history_and_links() {
    let root = tempfile::tempdir().unwrap();
    // Keep it short: on macOS a socket path is ≤ 103 bytes (`<tmp>/hb/.local/share/antenna/antennad.sock`).
    let home = root.path().join("hb");
    let old_dir = home.join(".local/share/x");
    let new_dir = home.join(".local/share/antenna");
    std::fs::create_dir_all(home.join(".local/share")).unwrap();

    let mut a = Node::new(root.path(), "alice", Net::Local);
    let mut b = Node::new(root.path(), "bob", Net::Local);
    b.dir = old_dir.clone();
    b.links_dir = Some(home.join("X/links"));
    a.start();
    b.start();
    a.init();
    b.init();
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "before 1")["status"], "delivered");
    assert_eq!(b.send("alice", "before 2")["status"], "delivered");
    std::fs::create_dir_all(home.join("X/links/alice/shared")).unwrap();
    std::fs::write(home.join("X/links/alice/shared/note.txt"), b"note").unwrap();
    // A file in B's quarantine (checked, not accepted): after the move, the blob store and quarantine records must keep
    // working.
    #[cfg(target_os = "linux")]
    let file_id = {
        let src = root.path().join("src/report.txt");
        std::fs::create_dir_all(src.parent().unwrap()).unwrap();
        std::fs::write(&src, b"numbers before the update\n").unwrap();
        let id = a.json(&["share", "bob", src.to_str().unwrap()])["id"]
            .as_str()
            .unwrap()
            .to_string();
        let t = Instant::now();
        while !b.json(&["files", "pending", "--all"])["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["id"] == id.as_str() && f["state"] == "checked")
        {
            assert!(
                t.elapsed() < Duration::from_secs(60),
                "file not checked at bob"
            );
            std::thread::sleep(Duration::from_millis(200));
        }
        id
    };
    b.stop();
    to_preview_names(&old_dir);

    // The update: the same $HOME, `antennad` without --data-dir and --links-dir.
    b.dir = new_dir.clone();
    b.links_dir = None;
    b.home = Some(home.clone());
    let t = Instant::now();
    b.start();
    println!("MIGRATION: started on the moved data in {:?}", t.elapsed());
    assert!(
        !old_dir.exists(),
        "the preview data dir is moved, not copied"
    );
    assert!(new_dir.join("antenna.db").exists());
    assert!(!new_dir.join("x.db").exists() && !new_dir.join("xd.sock").exists());
    assert!(new_dir.join("antennad.sock").exists());
    assert_eq!(
        std::fs::read(home.join("Antenna/links/alice/shared/note.txt")).unwrap(),
        b"note"
    );
    assert!(!home.join("X").exists(), "empty ~/X is removed");
    let log = b.log();
    assert!(
        log.contains("moved the data of the preview build `x`")
            && log.contains("renamed the database"),
        "{log}"
    );

    // The keys are the same (the password fits), history and the link are in place.
    assert_eq!(b.json(&["status"])["state"], "locked");
    b.unlock();
    let h = texts(&b, "alice");
    assert!(
        h.contains(&"before 1".to_string()) && h.contains(&"before 2".to_string()),
        "{h:?}"
    );
    assert_eq!(a.send("bob", "after the update")["status"], "delivered");
    assert_eq!(
        b.send("alice", "reply after the update")["status"],
        "delivered"
    );
    assert!(texts(&b, "alice").contains(&"after the update".to_string()));
    // A quarantined file received before the move is accepted after it, into the new link folder.
    #[cfg(target_os = "linux")]
    {
        let acc = b.json(&["files", "accept", &file_id]);
        assert_eq!(acc["state"], "accepted", "{acc}");
        assert_eq!(
            std::fs::read(home.join("Antenna/links/alice/shared/report.txt")).unwrap(),
            b"numbers before the update\n"
        );
    }

    // Second start: nothing to move, the data is the same.
    b.stop();
    b.start();
    b.unlock();
    assert_eq!(texts(&b, "alice").len(), h.len() + 2);
    assert_eq!(
        b.log()
            .matches("moved the data of the preview build")
            .count(),
        1,
        "migration runs once"
    );
}

#[test]
fn running_preview_daemon_blocks_the_move() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("h");
    let old_dir = home.join(".local/share/x");
    std::fs::create_dir_all(&old_dir).unwrap();
    std::fs::write(old_dir.join("keystore.cbor"), b"k").unwrap();
    // "The old xd": its socket accepts connections.
    let _old = std::os::unix::net::UnixListener::bind(old_dir.join("xd.sock")).unwrap();
    let mut c = Command::new(xd_bin());
    c.clean_env();
    for k in [
        "ANTENNA_DATA_DIR",
        "X_DATA_DIR",
        "ANTENNA_SOCKET",
        "X_SOCKET",
        "XDG_DATA_HOME",
    ] {
        c.env_remove(k);
    }
    let mut child = c
        .env("HOME", &home)
        .args(["--relay", "disabled", "--bind-ip", "127.0.0.1"])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let t = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "antennad must refuse to start"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    let mut err = String::new();
    std::io::Read::read_to_string(&mut child.stderr.take().unwrap(), &mut err).unwrap();
    assert!(!status.success());
    assert!(
        err.contains("still running") && err.contains("systemctl --user disable --now xd"),
        "{err}"
    );
    assert!(old_dir.join("keystore.cbor").exists());
    assert!(!home.join(".local/share/antenna").exists());
}
