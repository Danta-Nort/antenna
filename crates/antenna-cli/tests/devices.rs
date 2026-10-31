// SPDX-License-Identifier: AGPL-3.0-only
//! My devices (`docs/PROTOCOL.md` §24, `docs/CONTROL.md` §27, D-106; experimental) against real daemons: two of the
//! owner's computers at ∞ to each other tell each other what they are (version, OS, agents, pending approval
//! requests, the keys they answer approvals with); an approval request of one is answered from the other with an
//! owner proof the asking computer verifies against keys its owner confirmed; a lost computer is revoked from another
//! own device and the rest stop accepting its keys; lending a computer to teams is the owner's switch.
//!
//! Software P-256 keys stand in for the window's Secure Enclave key, as in `owner_keys.rs`: the daemon cannot tell them
//! apart, and it is what the window's Touch ID signs (the D-102 message over the asking computer's challenge).
//!
//! Run: `cargo build -p antennad -p antenna-cli && cargo test -p antenna-cli --test devices`.

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    time::{Duration, Instant},
};

use aws_lc_rs::{
    digest,
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair},
};
use common::*;
use data_encoding::{BASE64, HEXLOWER};
use serde_json::{Value, json};

/// A software P-256 key in place of the Secure Enclave's.
struct Key(EcdsaKeyPair);

impl Key {
    fn random() -> Self {
        let doc =
            EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &SystemRandom::new())
                .unwrap();
        Self(EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, doc.as_ref()).unwrap())
    }

    fn public_b64(&self) -> String {
        BASE64.encode(self.0.public_key().as_ref())
    }

    fn id(&self) -> String {
        let h = digest::digest(&digest::SHA256, self.0.public_key().as_ref());
        HEXLOWER.encode(&h.as_ref()[..8])
    }

    /// The D-102 owner proof: `"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(text)`, signed.
    fn sign(&self, nonce_hex: &str, text: &str) -> String {
        let mut m = b"antenna/owner-proof/v1\0".to_vec();
        m.extend_from_slice(&HEXLOWER.decode(nonce_hex.as_bytes()).unwrap());
        m.extend_from_slice(digest::digest(&digest::SHA256, text.as_bytes()).as_ref());
        BASE64.encode(self.0.sign(&SystemRandom::new(), &m).unwrap().as_ref())
    }
}

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

thread_local! {
    /// Owner sessions held by this test's thread, one per node (the window's way: `login {hold}`).
    static HELD: std::cell::RefCell<Vec<(std::path::PathBuf, Held)>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// This process's owner session on `n` (opened once, held until the test's thread ends).
fn session(n: &Node) -> String {
    HELD.with(|h| {
        let mut h = h.borrow_mut();
        if let Some((_, s)) = h.iter().find(|(d, _)| d == &n.dir) {
            return s.token.clone();
        }
        let s = n.held_session();
        let t = s.token.clone();
        h.push((n.dir.clone(), s));
        t
    })
}

/// One connection of this process: hello (owner, with this thread's held session) and one raw line → every reply
/// line.
fn line(n: &Node, raw: &str) -> Vec<Value> {
    let token = session(n);
    let mut s = UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = json!({"hello": {"proto": "x-control/7", "role": "owner", "session": token}});
    s.write_all(format!("{hello}\n{raw}\n").as_bytes()).unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    out.lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

fn req(n: &Node, r: Value) -> Value {
    line(n, &json!({"req": r}).to_string())
        .last()
        .unwrap()
        .clone()
}

fn ok(n: &Node, r: Value) -> Value {
    let v = req(n, r.clone());
    assert!(v.get("ok").is_some(), "{} {r}: {v}", n.name);
    v["ok"].clone()
}

fn err(n: &Node, r: Value) -> String {
    let v = req(n, r.clone());
    v["err"]["code"]
        .as_str()
        .unwrap_or_else(|| panic!("{} {r}: expected an error: {v}", n.name))
        .to_string()
}

/// Enrolls `key` as an owner key (the password and its proof of possession, CONTROL §22.3).
fn enroll(n: &Node, key: &Key) {
    let nonce = ok(n, json!({"cmd": "owner_challenge", "enroll": true}))["nonce"]
        .as_str()
        .unwrap()
        .to_string();
    let r = json!({"cmd": "owner_key_add", "public_key": key.public_b64(), "label": format!("touchid@{}", n.name),
                   "password": n.password})
    .to_string();
    let proof = json!({"key_id": key.id(), "nonce": nonce, "sig": key.sign(&nonce, &r)});
    let v = line(n, &format!(r#"{{"req":{r},"proof":{proof}}}"#));
    assert_eq!(v.last().unwrap()["ok"]["type"], "owner_key_added", "{v:?}");
}

fn devices(n: &Node) -> Value {
    n.json(&["devices"])
}

fn device(n: &Node, contact: &str) -> Option<Value> {
    devices(n)["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["contact"] == contact)
        .cloned()
}

/// Waits until `n`'s view of `contact` satisfies `f`.
fn wait_device(n: &Node, contact: &str, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    let t = Instant::now();
    loop {
        let d = device(n, contact);
        if let Some(d) = d.as_ref().filter(|d| f(d)) {
            return d.clone();
        }
        assert!(
            t.elapsed() < Duration::from_secs(30),
            "{}: {contact}: {what}: {d:?}",
            n.name
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn key_ids(d: &Value, field: &str) -> Vec<String> {
    d[field]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| k["key_id"].as_str().unwrap().to_string())
        .collect()
}

fn device_key_id(d: &Value, kind: &str, field: &str) -> String {
    d[field]
        .as_array()
        .unwrap()
        .iter()
        .find(|k| k["kind"] == kind)
        .unwrap_or_else(|| panic!("no {kind} key in {field}: {d}"))["key_id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// An agent that read the owner's project (label 5) writing to a level-3 contact: the send waits for approval.
fn pending(n: &Node, tok: &str, to: &str, text: &str) -> (String, String) {
    let (code, v) = n.agent(tok, &["send", to, text, "--wait", "0"]);
    assert_eq!(
        (code, v["error"].as_str()),
        (77, Some("approval_required")),
        "{v}"
    );
    (
        v["approval"]["id"].as_str().unwrap().to_string(),
        v["approval"]["fingerprint"].as_str().unwrap().to_string(),
    )
}

fn approval_state(n: &Node, id: &str) -> String {
    n.json(&["approvals", "--all"])["approvals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == id)
        .map(|a| a["state"].as_str().unwrap().to_string())
        .unwrap_or_default()
}

fn approve_text(link: &str, id: &str, fp: &str) -> String {
    json!({"cmd": "remote_approve", "link": link, "id": id, "fingerprint": fp}).to_string()
}

/// `device_challenge` from `from` to `to`: (link ID, nonce).
fn challenge(from: &Node, to: &str) -> (String, String) {
    let c = ok(from, json!({"cmd": "device_challenge", "contact": to}));
    assert_eq!(c["type"], "device_challenge", "{c}");
    (
        c["link_id"].as_str().unwrap().to_string(),
        c["nonce"].as_str().unwrap().to_string(),
    )
}

fn device_approve(from: &Node, to: &str, text: &str, nonce: &str, key: &Key) -> Value {
    req(
        from,
        json!({"cmd": "device_approve", "contact": to, "request": text, "nonce": nonce, "key_id": key.id(),
               "sig": key.sign(nonce, text)}),
    )
}

fn code_of(v: &Value) -> String {
    v["err"]["code"]
        .as_str()
        .unwrap_or_else(|| panic!("expected an error: {v}"))
        .to_string()
}

/// The view's data both ways, and an approval request of one own computer answered from the other: the asking
/// computer verifies the proof against the keys its owner confirmed, bound to its own challenge and to the exact
/// request. Each refusal of D-106 is seen: no key confirmed yet, a replay, a proof made for another request, a
/// request whose fingerprint changed, a key never confirmed there, the device key before it is confirmed, a device
/// lowered below ∞ (and its keys gone after it is raised again), and a contact that is not an own computer
/// announcing itself and asking for a challenge.
///
/// Negative controls (run once each, 2026-10-06, each seen failing this test): with both level checks off (in
/// `serve_device` and again in `device_status_in`), bob's forged report marked lap lost on mini and removed its keys
/// (either check alone holds: with only the first one off the test passed); with the challenge not taken in
/// `device_decide_in`, the replay passed the proof check (it stopped only at "already approved"); with
/// `owner_keys::verify` skipped in `check_decision`, the proof made for another request approved it; with the hook in
/// `set_trust` removed, the keys confirmed before the drop to 4 were still confirmed after the raise back to 5.
#[test]
fn own_devices_tell_each_other_and_answer_approvals_with_confirmed_keys() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["mini", "lap", "bob"]);
    let (mini, lap, bob) = (&ns[0], &ns[1], &ns[2]);
    pair(mini, lap, 5);
    pair(mini, bob, 3);
    let tok = mini.agent_add("builder", &["--local-level", "5"]);
    // The agent connects once, so the status shows it as seen
    mini.agent_ok(&tok, &["session"]);
    let (id1, fp1) = pending(mini, &tok, "bob", "the build report, part 1");
    let (id_secret, _) = pending(mini, &tok, "bob", "the database: password: hunter2hunter2");

    // 1) The view's data, both ways: version, OS, agents, pending requests (a secret withheld), keys
    let d = wait_device(lap, "mini", "status with two requests", |d| {
        d["status"]["pending_approvals"] == 2
    });
    assert_eq!(d["supported"], true, "{d}");
    assert_eq!(d["presence"], "online", "{d}");
    let st = &d["status"];
    assert!(
        st["version"].as_str().unwrap().starts_with("antennad "),
        "{st}"
    );
    assert_eq!(st["os"], std::env::consts::OS, "{st}");
    assert_eq!(st["arch"], std::env::consts::ARCH, "{st}");
    let agents: Vec<&str> = st["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["name"].as_str().unwrap())
        .collect();
    assert_eq!(agents, ["builder"], "{st}");
    assert!(st["agents"][0]["last_seen_ms"].as_u64().is_some(), "{st}");
    let reqs = st["approvals"].as_array().unwrap();
    let r1 = reqs.iter().find(|a| a["id"] == id1.as_str()).unwrap();
    assert_eq!(r1["fingerprint"], fp1.as_str());
    assert_eq!(r1["quote"], "the build report, part 1");
    assert_eq!(
        (r1["requester"].as_str(), r1["contact"].as_str()),
        (Some("builder"), Some("bob"))
    );
    let rs = reqs.iter().find(|a| a["id"] == id_secret.as_str()).unwrap();
    assert_eq!(rs["quote_withheld"], true, "a secret never travels: {rs}");
    assert_eq!(rs["quote"], "", "{rs}");
    assert!(!d.to_string().contains("hunter2"), "{d}");
    assert_eq!(st["lend"], false);
    // mini sees lap too, and lap's device key (the password there) is offered, not yet confirmed
    let m = wait_device(mini, "lap", "status", |d| d["status"].is_object());
    assert_eq!(key_ids(&m, "confirmed"), Vec::<String>::new());
    let lap_device_key = device_key_id(&m, "password", "offered");
    assert!(m["status"]["approvals"].as_array().unwrap().is_empty());

    // 2) Keys exchanged over the link: lap enrolls a Touch ID key (software here); mini sees it offered
    let k = Key::random();
    enroll(lap, &k);
    let m = wait_device(mini, "lap", "the Touch ID key offered", |d| {
        key_ids(d, "offered").contains(&k.id())
    });
    assert_eq!(device_key_id(&m, "touch_id", "offered"), k.id());
    // Nothing confirmed on mini yet: lap gets a challenge, but its answer is refused
    let (link, nonce) = challenge(lap, "mini");
    let r = device_approve(lap, "mini", &approve_text(&link, &id1, &fp1), &nonce, &k);
    assert_eq!(code_of(&r), "forbidden", "nothing confirmed: {r}");
    assert_eq!(approval_state(mini, &id1), "pending");

    // 3) mini's owner confirms the Touch ID key only (the password once, on mini)
    let out = mini.x(&["--json", "devices", "confirm", "lap", &k.id()]);
    assert!(
        !out.status.success(),
        "confirming needs the password: {out:?}"
    );
    mini.owner_json(&["devices", "confirm", "lap", &k.id()]);
    let m = device(mini, "lap").unwrap();
    assert_eq!(key_ids(&m, "confirmed"), vec![k.id()]);
    assert!(key_ids(&m, "offered").contains(&lap_device_key));
    // lap learns which of its keys mini accepts
    wait_device(lap, "mini", "accepts_mine", |d| {
        d["accepts_mine"] == json!([k.id()])
    });

    // 4) The approval answered from lap: approved on mini, carried out by mini's daemon, bob gets the message
    let (link, nonce) = challenge(lap, "mini");
    assert_eq!(link, d["link_id"].as_str().unwrap());
    let text = approve_text(&link, &id1, &fp1);
    let r = device_approve(lap, "mini", &text, &nonce, &k);
    assert_eq!(r["ok"]["type"], "device_decided", "{r}");
    assert_eq!(r["ok"]["state"], "approved", "{r}");
    let got = bob.inbox_wait(20);
    assert!(
        got.iter().any(|m| m["text"] == "the build report, part 1"),
        "{got:?}"
    );
    wait_device(lap, "mini", "one request left", |d| {
        d["status"]["pending_approvals"] == 1
    });
    let log = mini.json(&["log", "lap"]).to_string();
    assert!(log.contains("device_decision"), "{log}");

    // 5) Replay: the same proof again (its challenge was used)
    let r = device_approve(lap, "mini", &text, &nonce, &k);
    assert_eq!(code_of(&r), "challenge_invalid", "replay: {r}");

    // 6) Another request: a proof made for request 2 sent with the text of request 3
    let (id2, fp2) = pending(mini, &tok, "bob", "the build report, part 2");
    let (id3, fp3) = pending(mini, &tok, "bob", "the build report, part 3");
    let (link, nonce) = challenge(lap, "mini");
    let signed = approve_text(&link, &id2, &fp2);
    let r = req(
        lap,
        json!({"cmd": "device_approve", "contact": "mini", "request": approve_text(&link, &id3, &fp3),
               "nonce": nonce, "key_id": k.id(), "sig": k.sign(&nonce, &signed)}),
    );
    assert_eq!(
        code_of(&r),
        "proof_invalid",
        "a proof for another request: {r}"
    );
    // A correctly signed request whose fingerprint is not the one there
    let (link, nonce) = challenge(lap, "mini");
    let r = device_approve(
        lap,
        "mini",
        &approve_text(&link, &id2, "0000000000000000"),
        &nonce,
        &k,
    );
    assert_eq!(code_of(&r), "approval_mismatch", "another fingerprint: {r}");
    assert_eq!(approval_state(mini, &id2), "pending");
    assert_eq!(approval_state(mini, &id3), "pending");

    // 7) A key mini never confirmed: lap enrolls a second key; its proof is refused
    let k2 = Key::random();
    enroll(lap, &k2);
    wait_device(mini, "lap", "the second key offered", |d| {
        key_ids(d, "offered").contains(&k2.id())
    });
    let (link, nonce) = challenge(lap, "mini");
    let r = device_approve(lap, "mini", &approve_text(&link, &id2, &fp2), &nonce, &k2);
    assert_eq!(
        code_of(&r),
        "owner_key_unknown",
        "a key never confirmed: {r}"
    );
    // The device key (lap's password) before mini confirms it: refused the same way. The CLI finds the request in
    // what mini last said, so wait until mini's status names it.
    wait_device(lap, "mini", "request 2 shown", |d| {
        d["status"]["approvals"]
            .as_array()
            .is_some_and(|a| a.iter().any(|x| x["id"] == id2.as_str()))
    });
    let out = lap.owner(&["devices", "approve", "mini", &id2]);
    assert!(!out.status.success(), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("owner_key_unknown"),
        "{out:?}"
    );
    // Three failed proofs in a row pause lap's approvals on mini for a minute: the refusals above were two, and a
    // correct one resets the count. Confirm the device key, then approve with lap's password.
    mini.owner_json(&["devices", "confirm", "lap", &lap_device_key]);
    let v = lap.owner_json(&["devices", "approve", "mini", &id2]);
    assert_eq!(
        (v["type"].as_str(), v["state"].as_str()),
        (Some("device_decided"), Some("approved")),
        "{v}"
    );
    // A deny needs no password and no proof
    let v = lap.json(&["devices", "deny", "mini", &id3]);
    assert_eq!(v["state"], "denied", "{v}");
    assert_eq!(approval_state(mini, &id3), "denied");

    // 8) A device not at ∞: mini lowers lap to 4. lap's challenge is refused, its keys are dropped on mini, and after
    //    a raise back to 5 nothing old is accepted until the owner confirms again.
    let (id4, fp4) = pending(mini, &tok, "bob", "the build report, part 4");
    mini.owner_json(&["trust", "lap", "4"]);
    let r = req(lap, json!({"cmd": "device_challenge", "contact": "mini"}));
    assert_eq!(code_of(&r), "forbidden", "below ∞: {r}");
    mini.owner_json(&["trust", "lap", "5", "--yes"]);
    let m = wait_device(mini, "lap", "back at ∞", |d| d["status"].is_object());
    assert_eq!(key_ids(&m, "confirmed"), Vec::<String>::new(), "{m}");
    let (link, nonce) = challenge(lap, "mini");
    let r = device_approve(lap, "mini", &approve_text(&link, &id4, &fp4), &nonce, &k);
    assert_eq!(
        code_of(&r),
        "forbidden",
        "the old confirmation is gone: {r}"
    );
    assert_eq!(approval_state(mini, &id4), "pending");

    // 9) A forged announcement: bob is not mini's own computer (mini has him at 3), but bob has mini at ∞ on his
    //    side and claims lap is lost (bob paired with lap at ∞ and revoked it as lost). mini refuses bob's status
    //    and his challenge: lap's keys stay confirmed on mini and lap is not marked lost there.
    mini.owner_json(&["devices", "confirm", "lap"]);
    pair(bob, lap, 5);
    wait_device(bob, "lap", "lap's keys", |d| {
        key_ids(d, "offered").contains(&k.id())
    });
    bob.owner_json(&["devices", "revoke", "lap"]);
    assert_eq!(devices(bob)["this"]["lost"][0]["contact"], "lap");
    bob.owner_json(&["trust", "mini", "5", "--yes"]);
    let r = req(bob, json!({"cmd": "device_challenge", "contact": "mini"}));
    assert_eq!(code_of(&r), "forbidden", "{r}");
    std::thread::sleep(Duration::from_secs(6));
    let m = device(mini, "lap").unwrap();
    assert!(
        m["lost_by"].is_null(),
        "a contact below ∞ cannot report lap lost: {m}"
    );
    assert!(key_ids(&m, "confirmed").contains(&k.id()), "{m}");
    assert!(
        device(mini, "bob").is_none(),
        "bob is not one of mini's devices"
    );
}

/// "Revoke this computer" from another own device (PG-25): the link is wiped there, the lost computer's keys go on a
/// list the owner's other computers are told, and they stop accepting those keys at once and say so; the owner then
/// revokes it there too. Negative control (run once, 2026-10-06): with `apply_lost` not called, srv was never told and
/// kept the lost laptop's keys confirmed; the test failed at "reported lost".
#[test]
fn a_lost_computer_is_revoked_from_another_own_device() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["lap", "mini", "srv"]);
    let (lap, mini, srv) = (&ns[0], &ns[1], &ns[2]);
    pair(lap, mini, 5);
    pair(lap, srv, 5);
    pair(mini, srv, 5);
    let k = Key::random();
    enroll(lap, &k);
    for n in [mini, srv] {
        wait_device(n, "lap", "lap's keys", |d| {
            key_ids(d, "offered").contains(&k.id())
        });
        n.owner_json(&["devices", "confirm", "lap"]);
        assert_eq!(
            key_ids(&device(n, "lap").unwrap(), "offered"),
            Vec::<String>::new()
        );
    }
    // mini reports the laptop as lost
    let out = mini.x(&["--json", "devices", "revoke", "lap"]);
    assert!(
        !out.status.success(),
        "revoking needs the password: {out:?}"
    );
    let v = mini.owner_json(&["devices", "revoke", "lap"]);
    assert_eq!(v["type"], "revoked", "{v}");
    assert!(device(mini, "lap").is_none() || device(mini, "lap").unwrap()["status"].is_null());
    let this = &devices(mini)["this"];
    assert_eq!(this["lost"][0]["contact"], "lap", "{this}");
    assert!(
        this["lost"][0]["key_ids"]
            .as_array()
            .unwrap()
            .contains(&json!(k.id())),
        "{this}"
    );
    // srv is told: lap's keys are no longer accepted there, and lap is marked
    let s = wait_device(srv, "lap", "reported lost", |d| d["lost_by"].is_object());
    assert_eq!(s["lost_by"]["contact"], "mini", "{s}");
    assert_eq!(key_ids(&s, "confirmed"), Vec::<String>::new(), "{s}");
    // srv no longer accepts the lost laptop's key: the refusal comes before the request is looked up, so a made-up
    // request ID shows it
    let (link, nonce) = challenge(lap, "srv");
    let r = device_approve(
        lap,
        "srv",
        &approve_text(&link, "00000000", "0000000000000000"),
        &nonce,
        &k,
    );
    assert_eq!(
        code_of(&r),
        "forbidden",
        "srv no longer accepts the lost laptop's key: {r}"
    );
    // Dismiss clears the mark only; revoking ends the link there too
    let d = srv.json(&["devices", "dismiss", "lap"]);
    let lapd = d["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["contact"] == "lap")
        .unwrap()
        .clone();
    assert!(lapd["lost_by"].is_null(), "{lapd}");
    assert_eq!(key_ids(&lapd, "confirmed"), Vec::<String>::new());
    srv.owner_json(&["devices", "revoke", "lap"]);
    let out = lap.x(&["--json", "send", "srv", "still there?", "--wait", "3"]);
    let sent = String::from_utf8_lossy(&out.stdout);
    assert!(!sent.contains("\"status\":\"delivered\""), "{sent}");
}

/// "Lend this computer to my teams" (PG-14, the opt-in only): off by default, on with the password, off without; the
/// other own devices see it, and a team there lists the computer among its machines (facts only, every slot
/// unavailable until remote workers exist) while it lends itself.
#[test]
fn lending_is_the_owners_switch_and_travels_to_own_devices() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["gpu", "lap"]);
    let (gpu, lap) = (&ns[0], &ns[1]);
    pair(gpu, lap, 5);
    assert_eq!(devices(gpu)["this"]["lend"], false);
    let out = gpu.x_stdin(
        &["--json", "devices", "lend", "on", "--password-stdin"],
        "wrong password\n",
    );
    assert!(!out.status.success(), "{out:?}");
    assert_eq!(devices(gpu)["this"]["lend"], false);
    let v = gpu.owner_json(&["devices", "lend", "on"]);
    assert_eq!(v["this"]["lend"], true, "{v}");
    wait_device(lap, "gpu", "lend on", |d| d["status"]["lend"] == true);
    // A team on lap sees gpu among its machines (facts only: workers there come with remote workers)
    let proj = root.path().join("project");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join("README.md"), "hello\n").unwrap();
    for args in [
        &["init", "-q", "-b", "main"][..],
        &["add", "-A"],
        &[
            "-c",
            "user.name=Ada Owner",
            "-c",
            "user.email=ada@example.com",
            "commit",
            "-q",
            "-m",
            "start",
        ],
    ] {
        let out = std::process::Command::new("git")
            .current_dir(&proj)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {out:?}");
    }
    let lead = lap.agent_add("lead", &["--local-level", "0"]);
    lap.owner_json(&[
        "team",
        "create",
        "web",
        "--project",
        proj.to_str().unwrap(),
        "--lead",
        "lead",
        "--slot",
        &format!("coder:program:1:{}", true_bin()),
    ]);
    let cap = lap.agent_ok(&lead, &["team", "capacity"]);
    let machines = cap["machines"].as_array().unwrap();
    assert_eq!(machines[0]["name"], "this computer", "{cap}");
    let g = machines
        .iter()
        .find(|m| {
            m["name"]
                .as_str()
                .unwrap()
                .starts_with("gpu (own device, online")
        })
        .unwrap_or_else(|| panic!("gpu lends itself: {cap}"));
    assert_eq!(g["sandbox"], "remote", "{g}");
    assert!(g["slots"][0]["unavailable"].is_string(), "{g}");
    let v = gpu.json(&["devices", "lend", "off"]);
    assert_eq!(v["this"]["lend"], false, "{v}");
    wait_device(lap, "gpu", "lend off", |d| d["status"]["lend"] == false);
    let cap = lap.agent_ok(&lead, &["team", "capacity"]);
    assert_eq!(
        cap["machines"].as_array().unwrap().len(),
        1,
        "gpu no longer lends: {cap}"
    );
    // An agent has none of these commands
    let tok = gpu.agent_add("worker", &["--local-level", "0"]);
    let (c, v) = gpu.agent(&tok, &["devices", "lend", "on"]);
    assert_eq!(
        (c, v["error"].as_str()),
        (2, Some("unknown_command")),
        "{v}"
    );
    let _ = err(gpu, json!({"cmd": "device_lend_set", "enabled": true}));
}
