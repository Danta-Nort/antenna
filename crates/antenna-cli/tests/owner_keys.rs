// SPDX-License-Identifier: AGPL-3.0-only
//! Owner keys (v7, `docs/CONTROL.md` §22, D-102, experimental) against real daemons: a signature by an enrolled P-256
//! key over a one-time challenge and the exact request stands in for the owner password on one command; an unlock slot
//! opens the keys. Software keys stand in for the window's Secure Enclave key (the daemon cannot tell them apart; the
//! public test key is accepted only by a debug build started with `ANTENNA_OWNER_TEST_KEY=1`).
//!
//! The test process talks to the socket itself (raw lines): the challenge is bound to the client process, so the
//! challenge and the request must come from one process, as they do from the window.
//!
//! Run: `cargo build -p antennad -p antenna-cli && cargo test -p antenna-cli --test owner_keys`.

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    process::Command,
    time::Duration,
};

use aws_lc_rs::{
    digest,
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair},
};
use common::*;
use data_encoding::{BASE64, HEXLOWER};
use serde_json::{Value, json};

const TEST_KEY_ENV: &str = antenna_core::owner_keys::test_key::ENV;

/// A software P-256 key in place of the Secure Enclave's.
struct Key(EcdsaKeyPair);

impl Key {
    fn random() -> Self {
        let doc =
            EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &SystemRandom::new())
                .unwrap();
        Self(EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, doc.as_ref()).unwrap())
    }

    /// The public test key (its private key is published in `antenna_core::owner_keys::test_key`).
    fn test_key() -> Self {
        let der = BASE64
            .decode(antenna_core::owner_keys::test_key::PKCS8.as_bytes())
            .unwrap();
        Self(EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der).unwrap())
    }

    fn public_b64(&self) -> String {
        BASE64.encode(self.0.public_key().as_ref())
    }

    fn id(&self) -> String {
        let h = digest::digest(&digest::SHA256, self.0.public_key().as_ref());
        HEXLOWER.encode(&h.as_ref()[..8])
    }

    /// `"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(request bytes)`, signed (CONTROL §22.2).
    fn sign(&self, nonce_hex: &str, req: &str) -> String {
        let mut m = b"antenna/owner-proof/v1\0".to_vec();
        m.extend_from_slice(&HEXLOWER.decode(nonce_hex.as_bytes()).unwrap());
        m.extend_from_slice(digest::digest(&digest::SHA256, req.as_bytes()).as_ref());
        BASE64.encode(self.0.sign(&SystemRandom::new(), &m).unwrap().as_ref())
    }
}

/// A node; `test_key`: started with `ANTENNA_OWNER_TEST_KEY=1`.
fn node(root: &Path, name: &str, test_key: bool, extra: &[&str]) -> Node {
    let mut n = Node::new(root, name, Net::Local);
    if test_key {
        n.extra_env.push((TEST_KEY_ENV.into(), "1".into()));
    }
    n.extra_args = extra.iter().map(|s| s.to_string()).collect();
    n.start();
    n.init();
    n
}

/// One connection of this process: hello (owner, with a session token if given) and one raw line → every reply line.
fn line(n: &Node, session: Option<&str>, raw: &str) -> Vec<Value> {
    let mut s = UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = match session {
        Some(t) => json!({"hello": {"proto": "x-control/7", "role": "owner", "session": t}}),
        None => json!({"hello": {"proto": "x-control/7", "role": "owner"}}),
    };
    s.write_all(format!("{hello}\n{raw}\n").as_bytes()).unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    let v: Vec<Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert!(v[0].get("hello_ok").is_some(), "{v:?}");
    v
}

/// The final message of a reply.
fn last(v: &[Value]) -> &Value {
    v.last().unwrap()
}

fn err(v: &[Value]) -> String {
    last(v)["err"]["code"]
        .as_str()
        .unwrap_or_else(|| panic!("expected an error: {v:?}"))
        .to_string()
}

fn challenge(n: &Node, session: Option<&str>) -> String {
    let r = line(n, session, r#"{"req":{"cmd":"owner_challenge"}}"#);
    let ok = &last(&r)["ok"];
    assert_eq!(ok["type"], "owner_challenge", "{r:?}");
    ok["nonce"].as_str().unwrap().to_string()
}

fn proof_line(req: &str, key_id: &str, nonce: &str, sig: &str) -> String {
    format!(
        r#"{{"req":{req},"proof":{}}}"#,
        json!({"key_id": key_id, "nonce": nonce, "sig": sig})
    )
}

/// A challenge for `owner_key_add`'s proof of possession (`enroll: true`).
fn enroll_challenge(n: &Node) -> String {
    let r = line(
        n,
        None,
        r#"{"req":{"cmd":"owner_challenge","enroll":true}}"#,
    );
    last(&r)["ok"]["nonce"]
        .as_str()
        .unwrap_or_else(|| panic!("{r:?}"))
        .to_string()
}

/// A fresh challenge, `req` signed by `key`, sent with the proof.
fn proven(n: &Node, key: &Key, req: &str) -> Vec<Value> {
    let nonce = challenge(n, None);
    line(
        n,
        None,
        &proof_line(req, &key.id(), &nonce, &key.sign(&nonce, req)),
    )
}

/// The same with an enroll challenge (for `owner_key_add`).
fn proven_enroll(n: &Node, key: &Key, req: &str) -> Vec<Value> {
    let nonce = enroll_challenge(n);
    line(
        n,
        None,
        &proof_line(req, &key.id(), &nonce, &key.sign(&nonce, req)),
    )
}

/// Enrolls `key` with the password and its proof of possession; returns the reply.
fn enroll(n: &Node, key: &Key, unlock: bool) -> Value {
    let req = json!({"cmd": "owner_key_add", "public_key": key.public_b64(), "label": "Test Mac",
                     "unlock": unlock, "password": n.password})
    .to_string();
    let r = proven_enroll(n, key, &req);
    let ok = last(&r)["ok"].clone();
    assert_eq!(ok["type"], "owner_key_added", "{r:?}");
    ok
}

/// A correct password (`antenna login`): failed proofs are forgotten, the 14-day clock starts again.
fn password_once(n: &Node) {
    n.login();
}

fn approvals(n: &Node, tok: &str, count: usize) -> Vec<(String, String)> {
    (0..count)
        .map(|i| {
            let (code, v) = n.agent(
                tok,
                &["send", "bob", &format!("report part {i}"), "--wait", "0"],
            );
            assert_eq!(
                (code, v["error"].as_str()),
                (77, Some("approval_required")),
                "{v}"
            );
            (
                v["approval"]["id"].as_str().unwrap().to_string(),
                v["approval"]["fingerprint"].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

fn state_of(n: &Node, id: &str) -> String {
    let all = n.json(&["approvals", "--all"]);
    all["approvals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == id)
        .map(|a| a["state"].as_str().unwrap().to_string())
        .unwrap_or_default()
}

fn approve(id: &str, fp: &str) -> String {
    json!({"cmd": "approve", "id": id, "password": "", "fingerprint": fp}).to_string()
}

/// CONTROL §22.2, proposal §6 "Owner proof": a valid proof approves one request; another key, a removed key, another
/// command's hash, another approval fingerprint, a replayed or foreign nonce, a malformed signature and a batch with
/// one tampered item are all refused, each with its own code, and nothing is approved by them.
///
/// Negative controls (run once, 2026-10-06): with `owner_keys::verify` returning `Ok(())` at once, an enrollment
/// signed by another key than the one enrolled was accepted and the test failed; with the bind comparison removed from
/// `ProofState::take`, the challenge issued to a `perl` child process approved a request and the test failed.
#[test]
fn an_owner_proof_stands_in_for_the_password_on_one_command() {
    let root = tempfile::tempdir().unwrap();
    let a = node(root.path(), "alice", true, &[]);
    let b = node(root.path(), "bob", false, &[]);
    pair(&a, &b, 3);
    // An agent that read the owner's project (label 5) writing to a level 3 contact: every send waits for approval
    let tok = a.agent_add("claude", &["--local-level", "5"]);
    let ap = approvals(&a, &tok, 8);

    // Enrolling: the password and a proof by the new key; without either it is refused
    let k = Key::random();
    let add_req = |pw: &str, key: &Key| {
        json!({"cmd": "owner_key_add", "public_key": key.public_b64(), "label": "Mac", "password": pw})
            .to_string()
    };
    let r = line(
        &a,
        None,
        &format!(r#"{{"req":{}}}"#, add_req(&a.password, &k)),
    );
    assert_eq!(err(&r), "bad_request", "no proof of possession: {r:?}");
    let r = proven_enroll(&a, &k, &add_req("wrong password!", &k));
    assert_eq!(err(&r), "wrong_password", "{r:?}");
    password_once(&a);
    let other = Key::random();
    let nonce = enroll_challenge(&a);
    let req = add_req(&a.password, &k);
    let r = line(
        &a,
        None,
        &proof_line(&req, &k.id(), &nonce, &other.sign(&nonce, &req)),
    );
    assert_eq!(err(&r), "proof_invalid", "signed by another key: {r:?}");
    // A challenge serves its purpose only: a plain one does not enroll
    let r = proven(&a, &k, &req);
    assert_eq!(err(&r), "challenge_invalid", "a plain challenge: {r:?}");
    let added = enroll(&a, &k, true);
    assert_eq!(added["key"]["key_id"], k.id());
    assert_eq!(added["key"]["unlock"], true);
    assert_eq!(
        BASE64
            .decode(added["slot_key"].as_str().unwrap().as_bytes())
            .unwrap()
            .len(),
        32
    );
    // The same key twice is refused; the public test key is accepted by this debug daemon (it was asked to)
    let r = proven_enroll(&a, &k, &add_req(&a.password, &k));
    assert_eq!(err(&r), "bad_request", "{r:?}");
    enroll(&a, &Key::test_key(), false);
    let list = a.json(&["owner-key", "list"]);
    assert_eq!(list["keys"].as_array().unwrap().len(), 2, "{list}");
    assert_eq!(list["test_key"], true, "{list}");

    // Valid: one approval, with the fingerprint the owner saw, from a connection without an owner session
    let (id0, fp0) = &ap[0];
    let req = approve(id0, fp0);
    let nonce = challenge(&a, None);
    let good = proof_line(&req, &k.id(), &nonce, &k.sign(&nonce, &req));
    let r = line(&a, None, &good);
    assert_eq!(last(&r)["ok"]["state"], "approved", "{r:?}");
    // Replayed: the same line again (the same nonce and signature)
    let r = line(&a, None, &good);
    assert_eq!(err(&r), "challenge_invalid", "replayed: {r:?}");
    // An enroll challenge does not approve
    let (id1, fp1) = &ap[1];
    let r = proven_enroll(&a, &k, &approve(id1, fp1));
    assert_eq!(err(&r), "challenge_invalid", "an enroll challenge: {r:?}");
    password_once(&a);
    // The test key signs too
    let (id7, fp7) = &ap[7];
    let r = proven(&a, &Key::test_key(), &approve(id7, fp7));
    assert_eq!(last(&r)["ok"]["state"], "approved", "{r:?}");
    password_once(&a);

    // Another key (never enrolled)
    let (id1, fp1) = &ap[1];
    let r = proven(&a, &Key::random(), &approve(id1, fp1));
    assert_eq!(err(&r), "owner_key_unknown", "{r:?}");
    // Another command's hash: signed for request 2, sent for request 1
    let (id2, fp2) = &ap[2];
    let nonce = challenge(&a, None);
    let r = line(
        &a,
        None,
        &proof_line(
            &approve(id1, fp1),
            &k.id(),
            &nonce,
            &k.sign(&nonce, &approve(id2, fp2)),
        ),
    );
    assert_eq!(err(&r), "proof_invalid", "another command: {r:?}");
    password_once(&a);
    // Another approval fingerprint: signed with one, sent with another
    let nonce = challenge(&a, None);
    let r = line(
        &a,
        None,
        &proof_line(
            &approve(id1, fp1),
            &k.id(),
            &nonce,
            &k.sign(&nonce, &approve(id1, "0000000000000000")),
        ),
    );
    assert_eq!(err(&r), "proof_invalid", "another fingerprint: {r:?}");
    // A valid proof for a fingerprint that is not the request's: the proof holds, the binding does not
    let r = proven(&a, &k, &approve(id1, "0000000000000000"));
    assert_eq!(err(&r), "approval_mismatch", "{r:?}");
    password_once(&a);
    // A malformed signature
    let nonce = challenge(&a, None);
    let r = line(
        &a,
        None,
        &proof_line(
            &approve(id1, fp1),
            &k.id(),
            &nonce,
            &BASE64.encode(&[7u8; 64]),
        ),
    );
    assert_eq!(err(&r), "proof_invalid", "{r:?}");
    let nonce = challenge(&a, None);
    let r = line(
        &a,
        None,
        &proof_line(&approve(id1, fp1), &k.id(), &nonce, "not base64"),
    );
    assert_eq!(err(&r), "proof_invalid", "{r:?}");
    password_once(&a);
    // A foreign nonce: issued to another process (a perl child), used by this one
    let foreign = Command::new("perl")
        .arg("-MIO::Socket::UNIX")
        .arg("-e")
        .arg(
            r#"my $s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "connect: $!";
               print $s qq({"hello":{"proto":"x-control/7","role":"owner"}}\n{"req":{"cmd":"owner_challenge"}}\n);
               shutdown($s, 1); print while <$s>;"#,
        )
        .arg(a.dir.join("antennad.sock"))
        .output()
        .unwrap();
    let so = String::from_utf8_lossy(&foreign.stdout);
    let nonce: Value = serde_json::from_str(so.lines().last().unwrap_or("{}")).unwrap();
    let nonce = nonce["ok"]["nonce"]
        .as_str()
        .unwrap_or_else(|| panic!("perl challenge: {so}"))
        .to_string();
    let req = approve(id1, fp1);
    let r = line(
        &a,
        None,
        &proof_line(&req, &k.id(), &nonce, &k.sign(&nonce, &req)),
    );
    assert_eq!(err(&r), "challenge_invalid", "foreign: {r:?}");
    // Bound to a session token: issued with one, used without it
    let held = a.held_session();
    let nonce = challenge(&a, Some(&held.token));
    let r = line(
        &a,
        None,
        &proof_line(&req, &k.id(), &nonce, &k.sign(&nonce, &req)),
    );
    assert_eq!(err(&r), "challenge_invalid", "issued to a session: {r:?}");
    password_once(&a);
    // Never issued
    let nonce = HEXLOWER.encode(&[3u8; 32]);
    let r = line(
        &a,
        None,
        &proof_line(&req, &k.id(), &nonce, &k.sign(&nonce, &req)),
    );
    assert_eq!(err(&r), "challenge_invalid", "{r:?}");
    password_once(&a);
    for (id, _) in &ap[1..3] {
        assert_eq!(state_of(&a, id), "pending", "nothing above approved {id}");
    }

    // A password next to a proof; a proof on a password-only command; a proof on a command without a password
    let with_pw = json!({"cmd": "approve", "id": id1, "password": a.password}).to_string();
    let r = proven(&a, &k, &with_pw);
    assert_eq!(err(&r), "bad_request", "{r:?}");
    let r = proven(&a, &k, r#"{"cmd":"update_authorize","action":"install"}"#);
    assert_eq!(err(&r), "password_required", "{r:?}");
    let r = proven(&a, &k, r#"{"cmd":"contacts"}"#);
    assert_eq!(err(&r), "bad_request", "{r:?}");
    let r = proven(&a, &k, r#"{"cmd":"subscribe"}"#);
    assert_eq!(err(&r), "bad_request", "{r:?}");

    // A batch: one touch for the listed items; one tampered item refuses the whole call
    let items = |fps: [&str; 3]| {
        json!({"cmd": "approve_many", "password": "", "items": [
            {"id": ap[3].0, "fingerprint": fps[0]},
            {"id": ap[4].0, "fingerprint": fps[1]},
            {"id": ap[5].0, "fingerprint": fps[2]},
        ]})
        .to_string()
    };
    let honest = items([&ap[3].1, &ap[4].1, &ap[5].1]);
    let tampered = items([&ap[3].1, "0000000000000000", &ap[5].1]);
    let nonce = challenge(&a, None);
    let r = line(
        &a,
        None,
        &proof_line(&tampered, &k.id(), &nonce, &k.sign(&nonce, &honest)),
    );
    assert_eq!(err(&r), "proof_invalid", "{r:?}");
    for (id, _) in &ap[3..6] {
        assert_eq!(state_of(&a, id), "pending", "{id}");
    }
    let r = proven(&a, &k, &honest);
    let res = last(&r)["ok"]["results"].as_array().unwrap().clone();
    assert!(
        res.iter().all(|x| x["approval"]["state"] == "approved"),
        "{r:?}"
    );

    // A removed key: no password or session needed to remove; its proofs are refused afterwards
    let k2 = Key::random();
    enroll(&a, &k2, false);
    let r = line(
        &a,
        None,
        &json!({"req": {"cmd": "owner_key_remove", "key_id": k2.id()}}).to_string(),
    );
    assert_eq!(last(&r)["ok"]["state"], "removed", "{r:?}");
    let (id6, fp6) = &ap[6];
    let r = proven(&a, &k2, &approve(id6, fp6));
    assert_eq!(err(&r), "owner_key_unknown", "{r:?}");
    let r = line(
        &a,
        None,
        &json!({"req": {"cmd": "owner_key_remove", "key_id": k2.id()}}).to_string(),
    );
    assert_eq!(err(&r), "not_found", "{r:?}");
    password_once(&a);

    // Three failed proofs in a row: the password is asked before any Touch ID prompt; a correct one resets that
    for _ in 0..3 {
        let r = proven(&a, &Key::random(), &approve(id6, fp6));
        assert_ne!(err(&r), "approval", "{r:?}");
    }
    let r = line(&a, None, r#"{"req":{"cmd":"owner_challenge"}}"#);
    assert_eq!(err(&r), "password_required", "{r:?}");
    std::thread::sleep(Duration::from_millis(1100)); // the D-37 pause after the third failure
    password_once(&a);
    let r = proven(&a, &k, &approve(id6, fp6));
    assert_eq!(last(&r)["ok"]["state"], "approved", "{r:?}");

    // Sign-in with a proof: `login {hold}` opens a session for this process's connections
    let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
    let login = r#"{"cmd":"login","password":"","hold":true}"#;
    let nonce = challenge(&a, None);
    s.write_all(
        format!(
            "{}\n{}\n",
            json!({"hello": {"proto": "x-control/7", "role": "owner"}}),
            proof_line(login, &k.id(), &nonce, &k.sign(&nonce, login))
        )
        .as_bytes(),
    )
    .unwrap();
    let mut rd = std::io::BufReader::new(s.try_clone().unwrap());
    let mut token = None;
    for _ in 0..3 {
        let mut l = String::new();
        std::io::BufRead::read_line(&mut rd, &mut l).unwrap();
        let v: Value = serde_json::from_str(&l).unwrap();
        assert!(v.get("err").is_none(), "{v}");
        if v["event"]["kind"] == "session" {
            token = v["event"]["token"].as_str().map(str::to_string);
            break;
        }
    }
    let token = token.expect("a held session from the proof");
    let r = line(&a, Some(&token), r#"{"req":{"cmd":"owner_key_list"}}"#);
    assert_eq!(last(&r)["ok"]["type"], "owner_keys", "{r:?}");
    assert!(
        last(&r)["ok"]["keys"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["key_id"] == k.id() && x["last_used_ms"].is_u64()),
        "{r:?}"
    );
    drop(s);

    // Agents have none of it: the commands do not exist for them, a proof line is not an agent line
    for req in [
        json!({"cmd": "owner_challenge"}),
        json!({"cmd": "owner_key_list"}),
        json!({"cmd": "owner_key_remove", "key_id": k.id()}),
        json!({"cmd": "owner_key_add", "public_key": k.public_b64(), "label": "x", "password": a.password}),
    ] {
        let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
        s.write_all(
            format!(
                "{}\n{}\n",
                json!({"hello": {"proto": "x-control/7", "role": "agent", "token": tok}}),
                json!({ "req": req })
            )
            .as_bytes(),
        )
        .unwrap();
        s.shutdown(std::net::Shutdown::Write).unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).unwrap();
        assert!(out.contains("\"unknown_command\""), "{req}: {out}");
    }
    let mut s = UnixStream::connect(a.dir.join("antennad.sock")).unwrap();
    let send = r#"{"cmd":"send","contact":"bob","text":"hi","wait_ms":0}"#;
    s.write_all(
        format!(
            "{}\n{}\n",
            json!({"hello": {"proto": "x-control/7", "role": "agent", "token": tok}}),
            proof_line(send, &k.id(), "00", "AA==")
        )
        .as_bytes(),
    )
    .unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    assert!(out.contains("\"bad_request\""), "{out}");
    for args in [
        &["owner-key", "list"][..],
        &["owner-key", "remove", &k.id()],
    ] {
        let (c, v) = a.agent(&tok, args);
        assert_eq!(
            (c, v["error"].as_str()),
            (2, Some("unknown_command")),
            "{args:?}: {v}"
        );
    }
    assert_eq!(
        a.json(&["owner-key", "list"])["keys"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

/// CONTROL §22.4, proposal §6 "Keystore slot": the slot opens the keys; a wrong slot key, another key's ID or a
/// removed key do not; the password slot is unaffected (the same `keystore.cbor` bytes, and it still unlocks); a slot
/// opens nothing but the keys (no owner session).
///
/// Negative control (run once, 2026-10-06): with the database check of `check_slot_unlock` skipped, the slot of the
/// removed key still unlocked the node and the test failed.
#[test]
fn an_unlock_slot_opens_the_keys_and_nothing_else() {
    let root = tempfile::tempdir().unwrap();
    let a = node(root.path(), "alice", false, &[]);
    let ks_before = std::fs::read(a.dir.join("keystore.cbor")).unwrap();
    let k = Key::random();
    let added = enroll(&a, &k, true);
    let slot_key = added["slot_key"].as_str().unwrap().to_string();
    assert_eq!(
        std::fs::read(a.dir.join("keystore.cbor")).unwrap(),
        ks_before,
        "the password slot is never rewritten"
    );
    assert!(a.dir.join("keyslots.cbor").exists());
    let unlock = |key_id: &str, slot: &str| {
        line(
            &a,
            None,
            &json!({"req": {"cmd": "unlock", "password": "", "key_id": key_id, "slot_key": slot}})
                .to_string(),
        )
    };
    let state = || a.json(&["status"])["state"].as_str().unwrap().to_string();
    a.json(&["lock"]);
    assert_eq!(state(), "locked");
    // A wrong slot key, another key's ID, a slot key next to a password
    let r = unlock(&k.id(), &BASE64.encode(&[5u8; 32]));
    assert_eq!(err(&r), "slot_invalid", "{r:?}");
    let r = unlock(&Key::random().id(), &slot_key);
    assert_eq!(err(&r), "owner_key_unknown", "{r:?}");
    let r = line(
        &a,
        None,
        &json!({"req": {"cmd": "unlock", "password": a.password, "key_id": k.id(), "slot_key": slot_key}})
            .to_string(),
    );
    assert_eq!(err(&r), "bad_request", "{r:?}");
    let r = unlock(&k.id(), "short");
    assert_eq!(err(&r), "bad_request", "{r:?}");
    assert_eq!(state(), "locked");
    // The slot opens the keys; it opens no owner session (the window signs in with a proof next)
    let r = unlock(&k.id(), &slot_key);
    assert_eq!(last(&r)["ok"]["state"], "unlocked", "{r:?}");
    assert_eq!(state(), "unlocked");
    let r = line(&a, None, r#"{"req":{"cmd":"contacts"}}"#);
    assert_eq!(err(&r), "login_required", "{r:?}");
    // The password slot still unlocks
    a.json(&["lock"]);
    a.unlock();
    assert_eq!(state(), "unlocked");
    // A removed key's slot is gone
    let slots_copy = std::fs::read(a.dir.join("keyslots.cbor")).unwrap();
    let r = line(
        &a,
        None,
        &json!({"req": {"cmd": "owner_key_remove", "key_id": k.id()}}).to_string(),
    );
    assert_eq!(last(&r)["ok"]["state"], "removed", "{r:?}");
    assert!(!a.dir.join("keyslots.cbor").exists());
    a.json(&["lock"]);
    let r = unlock(&k.id(), &slot_key);
    assert_eq!(err(&r), "owner_key_unknown", "{r:?}");
    assert_eq!(state(), "locked");
    // A slot left behind (a copy of the file put back) still opens the root key, but the database no longer has the
    // key: the daemon refuses before anything starts and drops the stale slot (the database is the source)
    std::fs::write(a.dir.join("keyslots.cbor"), &slots_copy).unwrap();
    let r = unlock(&k.id(), &slot_key);
    assert_eq!(err(&r), "owner_key_unknown", "a stale slot: {r:?}");
    assert_eq!(state(), "locked");
    assert!(
        !a.dir.join("keyslots.cbor").exists(),
        "the stale slot is removed"
    );
    a.unlock();
}

/// D-102: the password is asked again a set time after the last one (14 days; this daemon is started with a test
/// switch that can only shorten it): proofs and unlock slots are refused with `password_required` until a correct
/// password, which starts the clock again.
///
/// Negative control (run once, 2026-10-06): with the due check removed from `refuse_if_password_due`, the challenge
/// after the period was issued and the test failed.
#[test]
fn the_password_is_asked_again_after_its_period() {
    let root = tempfile::tempdir().unwrap();
    let a = node(
        root.path(),
        "alice",
        false,
        &[
            "--owner-password-every-ms",
            "4000",
            "--owner-challenge-ttl-ms",
            "1500",
        ],
    );
    let k = Key::random();
    let slot_key = enroll(&a, &k, true)["slot_key"]
        .as_str()
        .unwrap()
        .to_string();
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"pairings","wait":false,"timeout_ms":null,"password":""}"#,
    );
    assert_eq!(last(&r)["ok"]["type"], "pairings", "{r:?}");
    // An expired challenge (this daemon's challenges live 1.5 s)
    let nonce = challenge(&a, None);
    std::thread::sleep(Duration::from_millis(1700));
    let pairings = r#"{"cmd":"pairings","wait":false,"timeout_ms":null,"password":""}"#;
    let r = line(
        &a,
        None,
        &proof_line(pairings, &k.id(), &nonce, &k.sign(&nonce, pairings)),
    );
    assert_eq!(err(&r), "challenge_invalid", "expired: {r:?}");
    // The period passes
    std::thread::sleep(Duration::from_millis(2500));
    let r = line(&a, None, r#"{"req":{"cmd":"owner_challenge"}}"#);
    assert_eq!(err(&r), "password_required", "{r:?}");
    // A challenge for enrolling is still issued (owner_key_add carries the password), but no other proof passes with it
    let r = line(
        &a,
        None,
        r#"{"req":{"cmd":"owner_challenge","enroll":true}}"#,
    );
    let nonce = last(&r)["ok"]["nonce"]
        .as_str()
        .unwrap_or_else(|| panic!("{r:?}"))
        .to_string();
    let r = line(
        &a,
        None,
        &proof_line(pairings, &k.id(), &nonce, &k.sign(&nonce, pairings)),
    );
    assert_eq!(err(&r), "password_required", "{r:?}");
    let k2 = Key::random();
    let add = json!({"cmd": "owner_key_add", "public_key": k2.public_b64(), "label": "Second Mac",
                     "password": a.password})
    .to_string();
    let r = line(
        &a,
        None,
        r#"{"req":{"cmd":"owner_challenge","enroll":true}}"#,
    );
    let nonce = last(&r)["ok"]["nonce"].as_str().unwrap().to_string();
    let r = line(
        &a,
        None,
        &proof_line(&add, &k2.id(), &nonce, &k2.sign(&nonce, &add)),
    );
    assert_eq!(last(&r)["ok"]["type"], "owner_key_added", "{r:?}");
    // That password started the clock again; let it pass once more for the slot
    let r = proven(&a, &k, pairings);
    assert_eq!(last(&r)["ok"]["type"], "pairings", "{r:?}");
    std::thread::sleep(Duration::from_millis(4200));
    a.json(&["lock"]);
    let r = line(
        &a,
        None,
        &json!({"req": {"cmd": "unlock", "password": "", "key_id": k.id(), "slot_key": slot_key}})
            .to_string(),
    );
    assert_eq!(err(&r), "password_required", "{r:?}");
    assert_eq!(a.json(&["status"])["state"], "locked");
    // The password: the clock starts again
    a.unlock();
    let r = proven(&a, &k, pairings);
    assert_eq!(last(&r)["ok"]["type"], "pairings", "{r:?}");
}

/// D-102, D-82's pattern: the public test key is accepted only by a debug build started with `ANTENNA_OWNER_TEST_KEY=1`
/// (the release check is `packaging/linux/check-install.sh`). Without the variable this debug daemon refuses it.
///
/// Negative control (run once, 2026-10-06): with `test_key_accepted` returning `true`, the enrollment succeeded and the
/// test failed.
#[test]
fn the_public_test_key_needs_a_build_that_asks_for_it() {
    let root = tempfile::tempdir().unwrap();
    let a = node(root.path(), "alice", false, &[]);
    let t = Key::test_key();
    let req = json!({"cmd": "owner_key_add", "public_key": t.public_b64(), "label": "test",
                     "password": a.password})
    .to_string();
    let r = proven_enroll(&a, &t, &req);
    assert_eq!(err(&r), "owner_key_refused", "{r:?}");
    let list = a.json(&["owner-key", "list"]);
    assert_eq!(list["test_key"], false, "{list}");
    assert!(list["keys"].as_array().unwrap().is_empty(), "{list}");
    // A software key that is not the published one enrolls like a Secure Enclave key (the daemon cannot tell them
    // apart; the password decides)
    enroll(&a, &Key::random(), false);
}

/// D-131, CONTROL §22.2: the password commands that took only the password before take an owner proof too. A replayed,
/// a stale and a wrong-key proof are refused before anything runs; for each command a valid proof is accepted (the
/// command runs: its effect, or its own refusal past the owner check). Turning automatic installs on still takes the password
/// (it opens the root key kept for the restart, D-103), and so does `init`.
///
/// Negative controls (run once, 2026-10-06): with the D-131 entries removed from `Request::accepts_proof`, the first
/// valid proof (`update_authorize`) was refused and the test failed; with `owner_keys::verify` returning `Ok(())` at
/// once, the wrong-key proof was accepted and the test failed.
#[test]
fn every_password_command_takes_a_proof_except_three() {
    let root = tempfile::tempdir().unwrap();
    let a = node(
        root.path(),
        "mini",
        false,
        &["--owner-challenge-ttl-ms", "1500"],
    );
    let b = node(root.path(), "lap", false, &[]);
    let c = node(root.path(), "server", false, &[]);
    // Own computers at ∞ both ways, so the device commands have something to act on
    pair(&a, &b, 5);
    pair(&a, &c, 5);
    let k = Key::random();
    enroll(&a, &k, false);

    // Refused before anything runs. A replayed proof: the same line twice
    let lend = r#"{"cmd":"device_lend_set","enabled":true}"#;
    a.json(&["devices", "lend", "off"]);
    let nonce = challenge(&a, None);
    let lend_line = proof_line(lend, &k.id(), &nonce, &k.sign(&nonce, lend));
    assert_eq!(
        last(&line(&a, None, &lend_line))["ok"]["this"]["lend"],
        true
    );
    a.json(&["devices", "lend", "off"]);
    let r = line(&a, None, &lend_line);
    assert_eq!(err(&r), "challenge_invalid", "replayed: {r:?}");
    password_once(&a);
    // A stale proof: its challenge expired (this daemon's live 1.5 s)
    let revoke_server = r#"{"cmd":"device_revoke","contact":"server","password":""}"#;
    let nonce = challenge(&a, None);
    let stale = proof_line(
        revoke_server,
        &k.id(),
        &nonce,
        &k.sign(&nonce, revoke_server),
    );
    std::thread::sleep(Duration::from_millis(1700));
    let r = line(&a, None, &stale);
    assert_eq!(err(&r), "challenge_invalid", "expired: {r:?}");
    password_once(&a);
    // A wrong key: the enrolled key's ID with another key's signature; a key never enrolled
    let other = Key::random();
    let nonce = challenge(&a, None);
    let r = line(
        &a,
        None,
        &proof_line(
            revoke_server,
            &k.id(),
            &nonce,
            &other.sign(&nonce, revoke_server),
        ),
    );
    assert_eq!(err(&r), "proof_invalid", "wrong key: {r:?}");
    password_once(&a);
    let r = proven(&a, &other, revoke_server);
    assert_eq!(err(&r), "owner_key_unknown", "{r:?}");
    password_once(&a);
    assert!(
        a.contacts().iter().any(|x| x["label"] == "server"),
        "nothing above revoked the server"
    );
    assert_eq!(a.json(&["devices"])["this"]["lend"], false, "nor lent it");

    // Valid proofs: each command runs
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"update_authorize","action":"install","version":"9.9.9","password":""}"#,
    );
    assert_eq!(last(&r)["ok"]["type"], "update_authorized", "{r:?}");
    let r = proven(&a, &k, lend);
    assert_eq!(last(&r)["ok"]["this"]["lend"], true, "{r:?}");
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"update_auto_set","enabled":false,"password":""}"#,
    );
    assert_eq!(last(&r)["ok"]["type"], "update_auto", "{r:?}");
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"file_allow","contact":"server","entries":[".dmg"],"password":""}"#,
    );
    assert_eq!(last(&r)["ok"]["type"], "file_allow", "{r:?}");
    // Past the owner check, these refuse for their own reasons: no such model, no such device, no such request
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"local_agent_add","name":"loc","model":"no-such-model","password":""}"#,
    );
    let code = err(&r);
    assert!(
        !matches!(
            code.as_str(),
            "password_required"
                | "wrong_password"
                | "proof_invalid"
                | "challenge_invalid"
                | "bad_request"
        ),
        "{r:?}"
    );
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"device_keys_confirm","contact":"nobody","key_ids":[],"password":""}"#,
    );
    assert_eq!(err(&r), "not_found", "{r:?}");
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"device_decide","contact":"lap","id":"k2nosuchreq","decision":"approve","fingerprint":"0000000000000000"}"#,
    );
    // The laptop accepts no key of this computer yet: refused there, after the owner check here
    assert_eq!(err(&r), "forbidden", "{r:?}");
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"device_revoke","contact":"lap","password":""}"#,
    );
    assert_eq!(last(&r)["ok"]["type"], "revoked", "{r:?}");
    assert!(
        !a.contacts().iter().any(|x| x["label"] == "lap"),
        "the lost computer is gone"
    );

    // What keeps the password: turning automatic installs on, setting the password
    let r = proven(
        &a,
        &k,
        r#"{"cmd":"update_auto_set","enabled":true,"password":""}"#,
    );
    assert_eq!(err(&r), "password_required", "{r:?}");
    let r = proven(&a, &k, r#"{"cmd":"init","password":""}"#);
    assert_eq!(err(&r), "password_required", "{r:?}");
}

/// The window's Touch ID folder name for a socket path (FNV-1a 64, `touchIdFolderName`).
fn touch_folder(socket: &Path) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in socket.to_string_lossy().as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// A stand-in for `antenna-touchid` (the Swift helper needs a Mac): a `python3` script that passes each line to this
/// test's signer over a socket in the folder and prints its answer. The signer signs with a software key, or answers
/// as a cancelled sheet.
struct FakeTouch {
    helper: std::path::PathBuf,
    asked: std::sync::Arc<std::sync::Mutex<Vec<Value>>>,
    cancel: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

fn fake_touch(root: &Path, dir: &Path, key: Key) -> FakeTouch {
    use std::io::{BufRead, BufReader};
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Arc, Mutex, atomic::AtomicBool, atomic::Ordering};
    let helper = root.join("antenna-touchid");
    std::fs::write(
        &helper,
        "#!/usr/bin/env python3\nimport os, socket, sys\n\
         s = socket.socket(socket.AF_UNIX)\ns.connect(os.path.join(sys.argv[1], 'helper.sock'))\n\
         f = s.makefile('rw')\nfor line in sys.stdin:\n    f.write(line)\n    f.flush()\n\
         \x20   sys.stdout.write(f.readline())\n    sys.stdout.flush()\n",
    )
    .unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
    let asked = Arc::new(Mutex::new(Vec::new()));
    let cancel = Arc::new(AtomicBool::new(false));
    let listener = std::os::unix::net::UnixListener::bind(dir.join("helper.sock")).unwrap();
    let (a2, c2) = (asked.clone(), cancel.clone());
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(mut conn) = conn else { break };
            let mut lines = BufReader::new(conn.try_clone().unwrap()).lines();
            while let Some(Ok(l)) = lines.next() {
                let v: Value = serde_json::from_str(&l).unwrap();
                a2.lock().unwrap().push(v.clone());
                let out = if c2.load(Ordering::SeqCst) {
                    json!({"error": "cancelled", "message": "cancelled"})
                } else {
                    json!({"sig": key.sign(v["nonce"].as_str().unwrap(), v["request"].as_str().unwrap())})
                };
                conn.write_all(format!("{out}\n").as_bytes()).unwrap();
            }
        }
    });
    FakeTouch {
        helper,
        asked,
        cancel,
    }
}

/// D-131: the CLI confirms an owner command with one touch when the window turned Touch ID on here (its record names
/// an enrolled key), through the helper next to it; the daemon checks the proof. A cancelled sheet is never "allowed":
/// without a terminal the password is then required and nothing changes. `--password-stdin` never uses Touch ID. A
/// record naming a key the daemon does not know falls back to the password.
///
/// Negative control (run once, 2026-10-06): with `touch_for` ignoring `--password-stdin`, the script's command asked
/// the helper for a touch and the test failed.
#[test]
fn the_cli_confirms_with_touch_id_when_it_is_on_here() {
    use std::sync::atomic::Ordering;
    let root = tempfile::tempdir().unwrap();
    let a = node(root.path(), "alice", false, &[]);
    let b = node(root.path(), "bob", false, &[]);
    pair(&a, &b, 3);
    let k = Key::random();
    let key_id = k.id();
    enroll(&a, &k, false);
    let tid = root.path().join("touchid");
    let dir = tid.join(touch_folder(&a.dir.join("antennad.sock")));
    std::fs::create_dir_all(&dir).unwrap();
    let record = |id: &str| {
        std::fs::write(
            dir.join("owner_key.json"),
            json!({"key_id": id, "unlock": false}).to_string(),
        )
        .unwrap();
    };
    record(&key_id);
    std::fs::write(dir.join("signing.key"), b"a Secure Enclave blob").unwrap();
    let t = fake_touch(root.path(), &dir, k);
    let run = |args: &[&str], stdin: Option<&str>| {
        let mut c = a.cmd();
        c.env("ANTENNA_TOUCHID_ROOT", &tid)
            .env("ANTENNA_TOUCHID_HELPER", &t.helper)
            .args(args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let mut p = c.spawn().unwrap();
        let mut input = p.stdin.take().unwrap();
        if let Some(s) = stdin {
            input.write_all(s.as_bytes()).unwrap();
        }
        drop(input);
        p.wait_with_output().unwrap()
    };
    let trust = || a.contact("bob")["trust"].as_u64().unwrap();

    // One touch: the request signed as sent, the password field empty, the sheet naming the command
    let out = run(&["--json", "trust", "bob", "4", "--touch-id"], None);
    assert!(out.status.success(), "{out:?}");
    assert_eq!(trust(), 4);
    {
        let asked = t.asked.lock().unwrap();
        assert_eq!(asked.len(), 1, "{asked:?}");
        assert_eq!(asked[0]["op"], "sign");
        assert_eq!(
            asked[0]["request"],
            r#"{"cmd":"trust","contact":"bob","level":4,"password":""}"#
        );
        assert!(
            asked[0]["reason"]
                .as_str()
                .unwrap()
                .contains("antenna trust bob 4"),
            "{asked:?}"
        );
    }

    // Cancelled: no terminal to ask the password in, so it fails and nothing changes
    t.cancel.store(true, Ordering::SeqCst);
    let out = run(&["--json", "trust", "bob", "2", "--touch-id"], None);
    assert!(!out.status.success(), "{out:?}");
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(said.contains("--password-stdin"), "{said}");
    assert_eq!(trust(), 4, "a cancelled sheet allows nothing");
    t.cancel.store(false, Ordering::SeqCst);

    // A script with --password-stdin keeps the password and never asks for a touch
    t.asked.lock().unwrap().clear();
    let out = run(
        &["--json", "trust", "bob", "3", "--password-stdin"],
        Some(&format!("{}\n", a.password)),
    );
    assert!(out.status.success(), "{out:?}");
    assert_eq!(trust(), 3);
    assert!(t.asked.lock().unwrap().is_empty(), "no touch for a script");

    // A record naming a key the daemon does not know: refused there, then the password (no terminal here)
    record("0123456789abcdef");
    let out = run(&["--json", "trust", "bob", "2", "--touch-id"], None);
    assert!(!out.status.success(), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("not enrolled"),
        "{out:?}"
    );
    assert_eq!(trust(), 3);
}
