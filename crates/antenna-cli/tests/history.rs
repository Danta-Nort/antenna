// SPDX-License-Identifier: AGPL-3.0-only
//! Acceptance tests of v0.1 slice 3, "history and integrity" (SPEC §7, §8, §9, §13, §18): two (three) real `antennad`
//! daemons, directly over 127.0.0.1. Message signatures, offline branches and merge, "History verified" after
//! restarting both, a manual DB edit with the divergence located, a DB rollback from a backup and rekey, receipts in
//! the shared DAG, the owner session.
//!
//! Run: `cargo test -p antenna-cli --test history -- --nocapture` (from the workspace root, so that `antennad` is
//! built).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    process::Command,
    time::{Duration, Instant},
};

use antenna_core::{
    e2e, history, keystore,
    store::{Db, FILE_NAME},
};
use antenna_proto::{Auth, Body, Envelope, EnvelopeCore};
use common::*;
use serde_json::{Value, json};

fn two(root: &std::path::Path) -> (Node, Node) {
    let mut a = Node::new(root, "alice", Net::Local);
    let mut b = Node::new(root, "bob", Net::Local);
    a.start();
    b.start();
    a.init();
    b.init();
    (a, b)
}

/// A node's DB (daemon stopped): the key comes from the keystore with the owner password, as in the daemon.
fn open_db(n: &Node) -> Db {
    let root = keystore::unlock(&n.dir, n.password.as_bytes()).unwrap();
    Db::open(&n.dir.join(FILE_NAME), &root.db_key()).unwrap()
}

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `antenna verify <contact>` → verification state.
fn verify(n: &Node, contact: &str) -> Value {
    n.json(&["verify", contact])["status"].clone()
}

fn texts(n: &Node, contact: &str) -> Vec<String> {
    n.json(&["history", contact, "--limit", "500"])["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"] == "text")
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect()
}

/// SPEC §7: the author's signature with context. A message tampered with after signing (text changed, ID recomputed,
/// old signature) is rejected by the recipient even when the E2E ciphertext is genuine. The genuine message arrives
/// later through verification.
#[test]
fn tampered_message_is_rejected_by_signature() {
    let root = tempfile::tempdir().unwrap();
    let (mut a, mut b) = two(root.path());
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "hello")["status"], "delivered");
    assert_eq!(b.inbox()[0]["text"], "hello");
    b.stop();
    let q = a.json(&["send", "bob", "pay 10 EUR", "--wait", "0"]);
    assert_eq!(q["status"], "queued");
    a.stop();
    // An attacker with access to A's DB changes a queued message and encrypts it properly with the link ratchet.
    {
        let mut db = open_db(&a);
        let link = db.links().unwrap().remove(0);
        let item = db.outbox(&link.link_id).unwrap().remove(0);
        let m = Db::message_by_id(db.conn(), &link.link_id, &item.msg_id)
            .unwrap()
            .unwrap();
        let mut core: EnvelopeCore = antenna_proto::from_cbor(&m.core).unwrap();
        core.body = Body::Text("pay 1000 EUR".into());
        let core_b = antenna_proto::to_cbor(&core).unwrap();
        let env = Envelope {
            id: history::message_id(&core_b),
            core: core_b,
            auth: Some(Auth::Sig(m.sig.clone())),
        };
        let tx = db.tx().unwrap();
        let enc = e2e::encrypt(
            &tx,
            &link.link_id,
            &link.sig_local_addr,
            &link.sig_remote_addr,
            &antenna_proto::to_cbor(&env).unwrap(),
        )
        .unwrap();
        Db::outbox_set_blob(&tx, item.seq, &history::seal(&link.link_id, &enc).unwrap()).unwrap();
        tx.commit().unwrap();
    }
    a.start();
    a.unlock();
    b.start();
    b.unlock();
    // The recipient rejects it: the signature does not match; after 5 rejections the sender drops the message from the
    // queue.
    wait_until("tampered message failed", Duration::from_secs(30), || {
        a.contact("bob")["failed"] == 1
    });
    assert!(b.log().contains("bad_signature"), "{}", b.log());
    assert!(!texts(&b, "alice").contains(&"pay 1000 EUR".to_string()));
    // The genuine message (signature over the real text) arrives as a resend during verification.
    let st = verify(&a, "bob");
    wait_until("genuine message recovered", Duration::from_secs(10), || {
        texts(&b, "alice").contains(&"pay 10 EUR".to_string())
    });
    println!("AFTER TAMPER: alice sees {}", st["state"]);
    assert!(!texts(&b, "alice").contains(&"pay 1000 EUR".to_string()));
}

/// SPEC §8: both wrote offline → two branches → the next message merges them; "History verified" and the 3-emoji
/// fingerprint are the same on both sides, including after restarting both nodes (SPEC §18).
#[test]
fn offline_branches_merge_and_history_is_verified_after_restart_of_both() {
    let root = tempfile::tempdir().unwrap();
    let (mut a, mut b) = two(root.path());
    pair(&a, &b, 3);
    a.send("bob", "a1");
    b.send("alice", "b1");
    assert_eq!(b.inbox().len(), 1);
    assert_eq!(a.inbox().len(), 1);
    // Both write offline: B is down and A writes; A is down and B writes.
    b.stop();
    let a_off = a.json(&["send", "bob", "a-offline", "--wait", "0"]);
    assert_eq!(a_off["status"], "queued");
    a.stop();
    b.start();
    b.unlock();
    let b_off = b.json(&["send", "alice", "b-offline", "--wait", "0"]);
    assert_eq!(b_off["status"], "queued");
    assert_eq!(
        a_off["parents"], b_off["parents"],
        "both branches grow from the same head"
    );
    a.start();
    a.unlock();
    wait_until("both queues drained", Duration::from_secs(20), || {
        a.contact("bob")["outbox"] == 0 && b.contact("alice")["outbox"] == 0
    });
    let heads_a = a.contact("bob")["heads"].clone();
    assert_eq!(
        heads_a.as_array().unwrap().len(),
        2,
        "two branches: {heads_a}"
    );
    assert_eq!(heads_a, b.contact("alice")["heads"]);
    // The next message references both heads: a merge.
    let m = a.send("bob", "merge");
    assert_eq!(m["status"], "delivered");
    let mut want = vec![
        a_off["id"].as_str().unwrap().to_string(),
        b_off["id"].as_str().unwrap().to_string(),
    ];
    want.sort();
    assert_eq!(m["parents"], json!(want));
    wait_until("merge seen by B", Duration::from_secs(10), || {
        b.contact("alice")["heads"] == json!([m["id"]])
    });
    let va = verify(&a, "bob");
    let vb = verify(&b, "alice");
    println!(
        "VERIFIED: alice {} {}  bob {} {}",
        va["state"], va["fingerprint"], vb["state"], vb["fingerprint"]
    );
    assert_eq!(va["state"], "verified", "{va}");
    assert_eq!(vb["state"], "verified", "{vb}");
    assert_eq!(va["fingerprint"], vb["fingerprint"]);
    assert_eq!(va["fingerprint"].as_str().unwrap().chars().count(), 3);
    assert_eq!(va["counts"], json!([3, 2]));
    // Restart both: after unlocking, verification on the first connection gives "History verified" again.
    a.stop();
    b.stop();
    a.start();
    b.start();
    a.unlock();
    b.unlock();
    let t = Instant::now();
    wait_until("verified after restart", Duration::from_secs(20), || {
        a.contact("bob")["history"]["state"] == "verified"
            && b.contact("alice")["history"]["state"] == "verified"
    });
    println!(
        "RESTART: both verified {} ms after unlock (presence hello → sync)",
        t.elapsed().as_millis()
    );
    let ra = a.contact("bob")["history"].clone();
    assert_eq!(
        ra["fingerprint"], va["fingerprint"],
        "same heads, same fingerprint"
    );
    assert_eq!(
        b.contact("alice")["history"]["fingerprint"],
        va["fingerprint"]
    );
}

/// SPEC §18: a manual change of a message in one side's DB is detected at the next verification, with its location; the
/// link is "read only" until the owner decides; the copy is restored from the contact's copy (signature checked).
#[test]
fn manual_db_edit_is_detected_with_its_place_and_repaired() {
    let root = tempfile::tempdir().unwrap();
    let (a, mut b) = two(root.path());
    pair(&a, &b, 3);
    for t in ["a1", "a2", "a3"] {
        assert_eq!(a.send("bob", t)["status"], "delivered");
    }
    b.send("alice", "b1");
    b.stop();
    // Edit the text of A's message #2 in B's DB (same ID).
    {
        let db = open_db(&b);
        let n = db
            .conn()
            .execute(
                "UPDATE messages SET body = 'a2 FORGED' WHERE body = 'a2'",
                [],
            )
            .unwrap();
        assert_eq!(n, 1);
    }
    b.start();
    b.unlock();
    let v = verify(&b, "alice");
    println!("EDIT DETECTED: {v}");
    assert_eq!(v["state"], "mismatch", "{v}");
    assert_eq!(v["where"]["author"], "contact");
    assert_eq!(v["where"]["n"], 2);
    assert!(v["where"]["seq"].as_i64().is_some());
    assert_eq!(
        (v["who_changed"].as_str(), v["reason"].as_str()),
        (Some("me"), Some("local_copy_damaged"))
    );
    assert_eq!(v["send_blocked"], true);
    // "Read only": sending is blocked until the owner decides.
    let out = b.x(&["--json", "send", "alice", "hi"]);
    assert_eq!(out.status.code(), Some(77));
    assert_eq!(last_json(&out.stdout)["error"], "read_only");
    // The contact sees that B's copy is damaged (its own is intact), and its sending is not blocked.
    wait_until("alice sees bob's damage", Duration::from_secs(10), || {
        a.contact("bob")["history"]["reason"] == "contact_copy_damaged"
    });
    let va = a.contact("bob")["history"].clone();
    assert_eq!(
        (va["who_changed"].as_str(), va["send_blocked"].as_bool()),
        (Some("contact"), Some(false))
    );
    // B's owner decides to restore from A's copy (the author's signature is checked): the history is verified again.
    let r = b.json(&["verify", "alice", "--repair"]);
    println!("REPAIRED: {}", r["status"]);
    assert_eq!(r["status"]["state"], "verified", "{r}");
    assert!(texts(&b, "alice").contains(&"a2".to_string()));
    assert_eq!(b.send("alice", "back")["status"], "delivered");
}

/// Tampering with a recomputed ID (the message is a head, the signature is old): the local check of the copy passes,
/// but the author chains diverge; the search finds the location, and the signatures show whose copy was changed. Both
/// sides are "read only"; the owner accepts the divergence (`verify --accept`).
#[test]
fn changed_message_id_is_located_by_chains_and_signatures_tell_whose_copy() {
    let root = tempfile::tempdir().unwrap();
    let (a, mut b) = two(root.path());
    pair(&a, &b, 3);
    a.send("bob", "a1");
    b.send("alice", "b1");
    let last = a.send("bob", "a2");
    assert_eq!(last["status"], "delivered");
    wait_until("b has a2", Duration::from_secs(10), || {
        texts(&b, "alice").len() == 3
    });
    b.stop();
    {
        let db = open_db(&b);
        let old: Vec<u8> = data_encoding::HEXLOWER
            .decode(last["id"].as_str().unwrap().as_bytes())
            .unwrap();
        let core: Vec<u8> = db
            .conn()
            .query_row("SELECT core FROM messages WHERE id = ?1", [&old], |r| {
                r.get(0)
            })
            .unwrap();
        let mut c: EnvelopeCore = antenna_proto::from_cbor(&core).unwrap();
        c.body = Body::Text("a2 rewritten".into());
        let nc = antenna_proto::to_cbor(&c).unwrap();
        let nid = history::message_id(&nc).0.to_vec();
        let conn = db.conn();
        conn.execute(
            "UPDATE messages SET id = ?2, core = ?3, body = 'a2 rewritten' WHERE id = ?1",
            [&old, &nid, &nc],
        )
        .unwrap();
        conn.execute(
            "UPDATE heads SET msg_id = ?2 WHERE msg_id = ?1",
            [&old, &nid],
        )
        .unwrap();
        conn.execute(
            "UPDATE message_parents SET msg_id = ?2 WHERE msg_id = ?1",
            [&old, &nid],
        )
        .unwrap();
    }
    b.start();
    b.unlock();
    let v = verify(&b, "alice");
    println!("LOCATED: {v}");
    assert_eq!(v["state"], "mismatch", "{v}");
    assert_eq!(
        (v["where"]["author"].as_str(), v["where"]["n"].as_u64()),
        (Some("contact"), Some(2))
    );
    assert_eq!(
        (v["who_changed"].as_str(), v["reason"].as_str()),
        (Some("me"), Some("signature_invalid"))
    );
    assert_eq!(v["where"]["peer_message_id"], last["id"]);
    // A checks B's copy itself (requested as evidence): the signature is invalid, so the contact's copy was changed;
    // A's copy is intact, so A is not blocked (D-44), while B is "read only" until its owner decides.
    wait_until("alice sees the conflict", Duration::from_secs(10), || {
        a.contact("bob")["history"]["reason"] == "signature_invalid"
    });
    let va = a.contact("bob")["history"].clone();
    assert_eq!(
        (
            va["who_changed"].as_str(),
            va["where"]["n"].as_u64(),
            va["send_blocked"].as_bool()
        ),
        (Some("contact"), Some(2), Some(false)),
        "{va}"
    );
    let q = a.json(&["send", "bob", "after divergence", "--wait", "500ms"]);
    assert_eq!(q["status"], "queued", "bob is read-only: {q}");
    assert_eq!(
        b.x(&["--json", "send", "alice", "x"]).status.code(),
        Some(77)
    );
    // B's owner decides to accept the divergence: the link writes again, A's queue gets through.
    let acc = b.owner_json(&["verify", "alice", "--accept"]);
    assert_eq!(acc["status"]["accepted"], true, "{acc}");
    assert_eq!(acc["status"]["send_blocked"], false);
    wait_until("queued message delivered", Duration::from_secs(15), || {
        texts(&b, "alice").contains(&"after divergence".to_string())
    });
    assert_eq!(
        b.json(&["send", "alice", "after accept", "--wait", "0"])["status"],
        "queued"
    );
}

/// SPEC §8, §18: restoring the database from "yesterday's backup" (a copy of the DB file) blocks sending until a rekey
/// confirmed by the owners; the contact sees the rollback; after the rekey, what was lost comes back through
/// verification.
#[test]
fn db_restored_from_backup_blocks_sending_until_rekey() {
    let root = tempfile::tempdir().unwrap();
    let (mut a, mut b) = two(root.path());
    pair(&a, &b, 3);
    a.send("bob", "a1");
    b.send("alice", "b1");
    assert_eq!(b.inbox().len(), 1);
    assert_eq!(a.inbox().len(), 1);
    // "Yesterday's backup": a copy of the stopped B's DB file.
    b.stop();
    let db = b.dir.join(FILE_NAME);
    let backup = root.path().join("bob-antenna.db.backup");
    std::fs::copy(&db, &backup).unwrap();
    b.start();
    b.unlock();
    assert_eq!(b.send("alice", "b2 after backup")["status"], "delivered");
    assert_eq!(a.send("bob", "a2 after backup")["status"], "delivered");
    assert_eq!(b.inbox_wait(10)[0]["text"], "a2 after backup");
    // Restore the DB from the backup.
    b.stop();
    std::fs::copy(&backup, &db).unwrap();
    for ext in ["-wal", "-shm"] {
        let _ = std::fs::remove_file(b.dir.join(format!("{FILE_NAME}{ext}")));
    }
    b.start();
    b.unlock();
    let h = b.contact("alice")["history"].clone();
    println!("ROLLBACK: {h}");
    assert_eq!(
        (h["state"].as_str(), h["rollback"].as_str()),
        (Some("rolled_back"), Some("local_counter"))
    );
    let out = b.x(&["--json", "send", "alice", "from the past"]);
    assert_eq!(out.status.code(), Some(77), "{out:?}");
    assert_eq!(last_json(&out.stdout)["error"], "rekey_required");
    // The contact sees the rollback (by the side's state and by message numbers) and holds back delivery.
    let va = verify(&a, "bob");
    assert_eq!(va["state"], "peer_rolled_back", "{va}");
    let q = a.json(&["send", "bob", "while bob is rolled back", "--wait", "500ms"]);
    assert_eq!(q["status"], "queued");
    // Rekey: both sides confirm with the password; the side that rolled back proposes a fresh bundle and reads out a
    // code, the other side enters this code (the confirmation names exactly this proposal).
    let rb = b.owner_json(&["rekey", "alice"]);
    assert_eq!(rb["state"], "waiting_for_contact", "{rb}");
    let code = rb["code"].as_str().unwrap().to_string();
    assert_eq!(code.len(), 6);
    // The side without a rollback cannot propose (otherwise a holder of a stolen copy of the contact's DB would get it
    // accepted without a code).
    let own = a.owner(&["rekey", "bob"]);
    assert_eq!(last_json(&own.stdout)["error"], "bad_request", "{own:?}");
    let wrong = a.owner(&["rekey", "bob", "--code", &wrong_code(&code)]);
    assert_eq!(
        last_json(&wrong.stdout)["error"],
        "sas_mismatch",
        "{wrong:?}"
    );
    let names = antenna_proto::sas::to_names(&code, true).unwrap();
    let ra = a.owner_json(&["rekey", "bob", "--code", &names]);
    // A's answer waits for a second code from B's owner: the answer could also come from a holder of a stolen copy of
    // A's keys.
    assert_eq!(ra["state"], "waiting_for_contact", "{ra}");
    let code2 = ra["code"].as_str().unwrap().to_string();
    assert_eq!(code2.len(), 6);
    assert_ne!(code2, code);
    let still = b.x(&["--json", "send", "alice", "not yet"]);
    assert_eq!(
        last_json(&still.stdout)["error"],
        "rekey_required",
        "{still:?}"
    );
    let again = b.owner(&["rekey", "alice"]);
    assert_eq!(
        last_json(&again.stdout)["error"],
        "bad_request",
        "{again:?}"
    );
    let wrong = b.owner(&["rekey", "alice", "--code", &wrong_code(&code2)]);
    assert_eq!(
        last_json(&wrong.stdout)["error"],
        "sas_mismatch",
        "{wrong:?}"
    );
    let still = b.x(&["--json", "send", "alice", "not yet"]);
    assert_eq!(
        last_json(&still.stdout)["error"],
        "rekey_required",
        "{still:?}"
    );
    // Restarting A in the middle of the rekey and entering the first code again gives the same answer and the same
    // second code (the accepted proposal is stored in the DB; B would treat a new answer as a conflict).
    a.stop();
    a.start();
    a.unlock();
    let ra2 = a.owner_json(&["rekey", "bob", "--code", &code]);
    assert_eq!(ra2["code"], code2.as_str(), "{ra2}");
    let t = Instant::now();
    let rb2 = b.owner_json(&["rekey", "alice", "--code", &code2]);
    assert_eq!(rb2["state"], "done", "{rb2}");
    println!(
        "REKEY: {} ms after the second owner's confirmation",
        t.elapsed().as_millis()
    );
    // What was lost in the rollback comes back through verification; A's queue is delivered by the new session.
    let t = Instant::now();
    while !(b.contact("alice")["history"]["state"] == "verified" && a.contact("bob")["outbox"] == 0)
    {
        if t.elapsed() > Duration::from_secs(20) {
            let tail = |s: String| {
                s.lines()
                    .rev()
                    .filter(|l| !l.contains("Request::contacts"))
                    .take(40)
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            panic!(
                "not recovered:\nB {}\nA {}\nA outbox {}\n--- B log (reversed)\n{}\n--- A log (reversed)\n{}",
                b.contact("alice")["history"],
                a.contact("bob")["history"],
                a.contact("bob")["outbox"],
                tail(b.log()),
                tail(a.log())
            );
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let tb = texts(&b, "alice");
    for want in [
        "a1",
        "b1",
        "b2 after backup",
        "a2 after backup",
        "while bob is rolled back",
    ] {
        assert!(tb.contains(&want.to_string()), "{want}: {tb:?}");
    }
    assert_eq!(b.send("alice", "after rekey")["status"], "delivered");
    let m = a.inbox_wait(10);
    assert!(m.iter().any(|x| x["text"] == "after rekey"), "{m:?}");
    assert_eq!(verify(&a, "bob")["state"], "verified");
}

/// A second, different rekey proposal burns both, and a burned code is not accepted later either: a bundle crafted for
/// an overheard code cannot take the place of the real one.
#[test]
fn conflicting_rekey_offers_burn_the_heard_code() {
    let root = tempfile::tempdir().unwrap();
    let (a, mut b) = two(root.path());
    pair(&a, &b, 3);
    a.send("bob", "a1");
    b.stop();
    let db = b.dir.join(FILE_NAME);
    let backup = root.path().join("bob-antenna.db.backup");
    std::fs::copy(&db, &backup).unwrap();
    b.start();
    b.unlock();
    assert_eq!(b.send("alice", "b1")["status"], "delivered");
    b.stop();
    std::fs::copy(&backup, &db).unwrap();
    for ext in ["-wal", "-shm"] {
        let _ = std::fs::remove_file(b.dir.join(format!("{FILE_NAME}{ext}")));
    }
    b.start();
    b.unlock();
    let rb = b.owner_json(&["rekey", "alice"]);
    let code = rb["code"].as_str().unwrap().to_string();
    // Repeating `antenna rekey` within the window gives the same proposal and the same code (the contact never has
    // two).
    assert_eq!(b.owner_json(&["rekey", "alice"])["code"], code.as_str());
    // Restarting B loses the in-memory proposal: a new, different proposal burns both.
    b.stop();
    b.start();
    b.unlock();
    let second = b.owner(&["rekey", "alice"]);
    let e = last_json(&second.stdout);
    assert_eq!(e["error"], "pairing_failed", "{second:?}");
    assert!(
        e["message"]
            .as_str()
            .unwrap()
            .contains("conflicting_offers"),
        "{e}"
    );
    // The window after a conflict: new proposals are not accepted.
    let third = b.owner(&["rekey", "alice"]);
    assert_eq!(
        last_json(&third.stdout)["error"],
        "pairing_failed",
        "{third:?}"
    );
    // The overheard code is burned.
    let late = a.owner(&["rekey", "bob", "--code", &code]);
    let e = last_json(&late.stdout);
    assert_eq!(e["error"], "not_found", "{late:?}");
    assert!(e["message"].as_str().unwrap().contains("discarded"), "{e}");
}

/// SPEC §9, Q-16: agent actions on a contact's request are signed `receipt` entries in the shared link history;
/// `antenna log` reads them from the DAG on both sides.
#[test]
fn agent_actions_become_signed_receipts_in_the_shared_history() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path());
    pair(&a, &b, 3);
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let s = b.send_to_agent("alice", "claude", "please summarize the report");
    let mid = s["id"].as_str().unwrap().to_string();
    let r = a.agent_ok(&tok, &["inbox"]);
    assert_eq!(r["messages"][0]["text"], "please summarize the report");
    let find = |n: &Node, contact: &str, author: &str| -> Option<Value> {
        n.json(&["log", contact])["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| {
                e["source"] == "dag"
                    && e["author"] == author
                    && e["actor"] == "claude"
                    && e["action"] == "read_messages"
            })
            .cloned()
    };
    wait_until("bob sees alice's receipt", Duration::from_secs(10), || {
        find(&b, "alice", "contact").is_some()
    });
    let e = find(&b, "alice", "contact").unwrap();
    println!("RECEIPT at bob: {e}");
    assert_eq!(e["decision"], "allowed");
    assert_eq!(e["refs"], json!([mid]));
    assert!(find(&a, "bob", "me").is_some());
    // In the link history: type receipt, signed and verified together with the rest of the history.
    let h = a.json(&["history", "bob"]);
    assert!(
        h["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["kind"] == "receipt" && m["receipt"]["actor"] == "claude"),
        "{h}"
    );
    // The trust level and policy details do not go into the receipt (SPEC §7: the level is stored only locally).
    assert!(!e.to_string().contains("trust"), "{e}");
    assert_eq!(verify(&b, "alice")["state"], "verified");
}

/// Q-14b: without an open session a process with the same uid is not the owner. A session is opened with the password:
/// per terminal or (without a terminal) per parent process, like `sudo`; the window holds its session in its
/// connection.
#[test]
fn owner_needs_a_session_and_a_process_without_one_is_not_the_owner() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    a.init();
    let sh = |script: &str| -> String {
        // setsid: no controlling terminal; `sh` is the parent of the `x` commands inside. macOS has no `setsid`
        // program, so python does the same (`os.setsid` + exec), PORTABILITY §4.
        let mut cmd = if cfg!(target_os = "macos") {
            let mut c = Command::new("/usr/bin/python3");
            c.args([
                "-c",
                "import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])",
            ]);
            c
        } else {
            Command::new("setsid")
        };
        let out = cmd
            .clean_env()
            .args(["sh", "-c", script])
            .env("X", x_bin())
            .env("D", &a.dir)
            .env("P", &a.password)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).to_string()
    };
    let o = sh(r#""$X" --data-dir "$D" --json contacts; echo "EXIT=$?""#);
    println!("NO SESSION: {o}");
    assert!(
        o.contains("\"error\":\"login_required\"") && o.contains("EXIT=77"),
        "{o}"
    );
    // Status works without a session.
    let o = sh(r#""$X" --data-dir "$D" --json status; echo "EXIT=$?""#);
    assert!(o.contains("EXIT=0"), "{o}");
    // A wrong password does not open a session.
    let o = sh(
        r#"echo wrong-pass | "$X" --data-dir "$D" --json login --password-stdin; echo "EXIT=$?""#,
    );
    assert!(o.contains("wrong_password"), "{o}");
    // The parent's session: later `x` calls of the same sh are the owner; after logout they are not.
    let o = sh(
        r#"printf '%s\n' "$P" | "$X" --data-dir "$D" --json login --password-stdin
           "$X" --data-dir "$D" --json contacts; echo "EXIT1=$?"
           "$X" --data-dir "$D" --json logout
           "$X" --data-dir "$D" --json contacts; echo "EXIT2=$?""#,
    );
    println!("SESSION: {o}");
    assert!(o.contains("\"kind\":\"parent\""), "{o}");
    assert!(o.contains("EXIT1=0") && o.contains("EXIT2=77"), "{o}");
    // One parent's session does not open another's (an agent in a neighboring process is not the owner).
    let o = sh(r#""$X" --data-dir "$D" --json contacts; echo "EXIT=$?""#);
    assert!(o.contains("EXIT=77"), "{o}");
    // Trust commands still need the password, and it proves the owner by itself.
    let o = sh(
        r#"printf '%s\n' "$P" | "$X" --data-dir "$D" --json agent add bot --local-level 0 --password-stdin; echo "EXIT=$?""#,
    );
    assert!(o.contains("agent_added") && o.contains("EXIT=0"), "{o}");
    // The window: a session in the connection; the token works only from the same process.
    let held = a.held_session();
    let raw = |hello: Value| -> Vec<Value> {
        let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
        s.write_all(
            format!(
                "{}\n{}\n",
                json!({"hello": hello}),
                json!({"req": {"cmd": "contacts"}})
            )
            .as_bytes(),
        )
        .unwrap();
        s.shutdown(std::net::Shutdown::Write).unwrap();
        BufReader::new(s)
            .lines()
            .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
            .collect()
    };
    let r = raw(json!({"proto": "x-control/2", "role": "owner", "session": held.token}));
    assert_eq!(r[0]["hello_ok"]["session"], "held");
    assert_eq!(r[1]["ok"]["type"], "contacts", "{r:?}");
    let r = raw(json!({"proto": "x-control/2", "role": "owner", "session": "xos_forged"}));
    assert_eq!(r[1]["err"]["code"], "login_required", "{r:?}");
    // The window closed the session connection, so the token is no longer valid.
    let token = held.token.clone();
    drop(held);
    std::thread::sleep(Duration::from_millis(300));
    let r = raw(json!({"proto": "x-control/2", "role": "owner", "session": token}));
    assert_eq!(r[0]["hello_ok"]["session"], "none", "{r:?}");
    assert_eq!(r[1]["err"]["code"], "login_required", "{r:?}");
}

/// The `invite` watch connection (the window's path): after the joiner entered the code the daemon says
/// `confirm_without_code`, and a "yes" without a code links (D-95); a typed code is still checked: a code of another
/// invite is refused with an `input_rejected` event and the invite stays alive (formal model F-4/F-6). With two invites
/// showing codes at once the code is required: `tests/link.rs::two_invites_with_codes_at_once_need_the_typed_code`.
#[test]
fn invite_follow_confirmation_by_click_or_by_the_typed_code() {
    let root = tempfile::tempdir().unwrap();
    let (mut a, b) = two(root.path());
    a.allow_auto_confirm = false;
    a.stop();
    a.start();
    a.unlock();
    let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
    s.write_all(
        format!(
            "{}\n{}\n",
            json!({"hello": {"proto": "x-control/2", "role": "owner"}}),
            json!({"req": {"cmd": "invite", "trust": 3, "ttl_secs": 120, "label": "bob", "auto_confirm": false,
                           "follow": true, "password": a.password}})
        )
        .as_bytes(),
    )
    .unwrap();
    let mut r = BufReader::new(s.try_clone().unwrap());
    let mut next = |what: &str| -> Value {
        loop {
            let mut l = String::new();
            assert!(r.read_line(&mut l).unwrap() > 0, "eof waiting for {what}");
            let v: Value = serde_json::from_str(&l).unwrap();
            if v["event"]["kind"] == what || v.get("ok").is_some() || v.get("err").is_some() {
                return v;
            }
        }
    };
    let link = next("invite_created")["event"]["link"]
        .as_str()
        .unwrap()
        .to_string();
    let mut j = join(&b, &link, 3, "alice");
    let sas = next("sas")["event"]["code"].as_str().unwrap().to_string();
    j.event("need_input", T);
    j.write_line(&sas);
    let ni = next("need_input");
    assert_eq!(ni["event"]["what"], "confirm", "{ni}");
    assert_eq!(ni["event"]["confirm_without_code"], true, "{ni}");
    // "Yes" with someone else's code.
    s.write_all(
        format!(
            "{}\n",
            json!({"input": {"confirm": {"yes": true, "code": wrong_code(&sas)}}})
        )
        .as_bytes(),
    )
    .unwrap();
    let e = next("input_rejected");
    assert_eq!(e["event"]["code"], "sas_mismatch", "{e}");
    // The owner's click: "yes" without a code.
    s.write_all(format!("{}\n", json!({"input": {"confirm": {"yes": true}}})).as_bytes())
        .unwrap();
    let done = next("never");
    assert_eq!(done["ok"]["type"], "linked", "{done}");
    assert_eq!(j.finish(T).0, 0);
}

/// API for the UI (DESIGN "needed from the daemon"): unread counts and `mark_read`, renaming, `revoke` wipes the link
/// keys (SPEC §5, §13).
#[test]
fn unread_mark_read_rename_and_revoke() {
    let root = tempfile::tempdir().unwrap();
    let (mut a, b) = two(root.path());
    pair(&a, &b, 3);
    b.send("alice", "one");
    b.send("alice", "two");
    wait_until("two unread", Duration::from_secs(10), || {
        a.contact("bob")["unread"] == 2
    });
    let c = a.contact("bob");
    assert_eq!(c["rights"]["level"], 3);
    let held = a.held_session();
    let h = a.json(&["history", "bob"]);
    let first_in = h["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["direction"] == "in")
        .unwrap()["seq"]
        .as_i64()
        .unwrap();
    let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
    s.write_all(
        format!(
            "{}\n{}\n",
            json!({"hello": {"proto": "x-control/2", "role": "owner", "session": held.token}}),
            json!({"req": {"cmd": "mark_read", "contact": "bob", "up_to_seq": first_in}})
        )
        .as_bytes(),
    )
    .unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    let lines: Vec<Value> = BufReader::new(s)
        .lines()
        .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
        .collect();
    assert_eq!(lines[1]["ok"]["contacts"][0]["unread"], 1, "{lines:?}");
    // Renaming.
    let r = a.json(&["rename", "bob", "Robert"]);
    assert_eq!(r["contacts"][0]["label"], "Robert");
    assert_eq!(a.send("Robert", "renamed")["status"], "delivered");
    // revoke: the link keys are wiped, the link is gone from contacts, the history stays by default.
    let link_id = a.contact("Robert")["link_id"].as_str().unwrap().to_string();
    let v = a.owner_json(&["revoke", "Robert"]);
    assert_eq!(
        (v["type"].as_str(), v["history_deleted"].as_bool()),
        (Some("revoked"), Some(false))
    );
    assert!(a.contacts().is_empty());
    let q = b.json(&["send", "alice", "are you there", "--wait", "1s"]);
    assert_eq!(q["status"], "queued", "revoked link takes nothing");
    a.stop();
    let db = open_db(&a);
    let (state, seed): (String, Vec<u8>) = db
        .conn()
        .query_row(
            "SELECT state, root_ed25519_seed FROM links WHERE hex(link_id) = upper(?1)",
            [&link_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(state, "revoked");
    assert!(seed.iter().all(|b| *b == 0), "link-root seed wiped");
    let sessions: i64 = db
        .conn()
        .query_row("SELECT count(*) FROM sig_session", [], |r| r.get(0))
        .unwrap();
    assert_eq!(sessions, 0, "ratchet state wiped");
    let kept: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM messages WHERE kind = 'text'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(kept >= 3, "history kept by default");
}

/// Levels 1–2 are relay only (SPEC §4): verification runs over the same relay connection; "History verified" and
/// receipts work the same way.
#[test]
fn history_is_verified_over_a_relay_only_link() {
    let root = tempfile::tempdir().unwrap();
    let relay = LocalRelay::start();
    let mut a = Node::new(root.path(), "alice", Net::LocalRelay(relay.url.clone()));
    let mut b = Node::new(root.path(), "bob", Net::LocalRelay(relay.url.clone()));
    a.start();
    b.start();
    a.init();
    b.init();
    pair(&a, &b, 2);
    assert_eq!(a.contact("bob")["net_mode"], "relay_only");
    a.send("bob", "via relay");
    b.send("alice", "back via relay");
    let t = Instant::now();
    let va = verify(&a, "bob");
    println!(
        "RELAY VERIFY: {} ms, {}",
        t.elapsed().as_millis(),
        va["state"]
    );
    assert_eq!(va["state"], "verified", "{va}");
    wait_until("bob verified", Duration::from_secs(10), || {
        b.contact("alice")["history"]["state"] == "verified"
    });
    assert_eq!(
        b.contact("alice")["history"]["fingerprint"],
        va["fingerprint"]
    );
}
