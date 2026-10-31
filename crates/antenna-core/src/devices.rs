// SPDX-License-Identifier: AGPL-3.0-only
//! Own devices (`docs/PROTOCOL.md` §24, `docs/CONTROL.md` §27, D-106; experimental): what this node keeps about the
//! owner's other computers (contacts at trust level 5), the challenges it issues for approvals answered from another
//! own device, the check of such an answer, its own device key, and the computers removed as lost.
//!
//! The check of a remote approval is the D-102 owner proof, unchanged: ECDSA P-256 / SHA-256 (`aws-lc-rs`) over
//! `"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(request)`, where the nonce is this node's, issued to that one
//! link, used once, and the request is the exact signed text, which names the link and the approval request with its
//! fingerprint. The key must be one the owner of this node confirmed for that device (with the password, once). No
//! new construction: the same message, the same verification, a nonce pool per link instead of per client process.
//!
//! The device key is this node's own P-256 key (generated with `aws-lc-rs`, kept in the encrypted database). It signs
//! a remote approval only after the owner typed the password on this computer, for the computers whose owner has no
//! Touch ID there (Linux, a Mac without it): it stands for "the password was typed on that device", which the other
//! device's owner chose to accept when confirming it.

use std::collections::{BTreeMap, HashMap, VecDeque};

use antenna_proto::{
    LinkId,
    control::{DeviceKeyInfo, code},
    device::{self, DeviceKey, KEY_PASSWORD, RemoteDecision, RemoteRequest},
};
use aws_lc_rs::{
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair},
};
use data_encoding::{BASE64, HEXLOWER};
use serde::{Deserialize, Serialize};

use crate::{
    crypto,
    error::{Error, Result},
    owner_keys,
    store::Db,
};

/// `meta` key of the records about the other devices (JSON, link hex → [`Record`]).
const META_RECORDS: &str = "devices";
/// `meta` key of this node's device key (PKCS#8, base64).
const META_DEVICE_KEY: &str = "device_key";
/// `meta` key of "Lend this computer to my teams" (`on`).
const META_LEND: &str = "device_lend";
/// `meta` key of the computers removed here as lost (JSON list of [`Lost`]).
const META_LOST: &str = "devices_lost";
/// The label of the device key in the list the other devices see.
pub const DEVICE_KEY_LABEL: &str = "password";
/// How long the other devices are told about a computer removed as lost.
pub const LOST_KEEP_MS: u64 = 30 * 24 * 60 * 60 * 1000;
/// At most this many challenges outstanding per link; a newer one pushes out the oldest.
pub const CHALLENGES_PER_LINK: usize = 16;
/// After this many failed remote proofs in a row from one device, its remote approvals pause.
pub const FAILS_MAX: u32 = 3;
/// How long they pause (doubling with every further failure, at most 10 minutes).
pub const PAUSE_MS: u64 = 60_000;

/// What this node keeps about one of the owner's other computers.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    /// Its keys the owner confirmed here: approvals signed by them are accepted.
    #[serde(default)]
    pub confirmed: Vec<KeyEntry>,
    /// The last status it sent, without its approval requests (kept for when it is offline).
    #[serde(default)]
    pub last: Option<device::DeviceStatus>,
    /// When that arrived (this computer's clock).
    #[serde(default)]
    pub received_ms: Option<u64>,
    /// Another own device reported it as lost: that device's label and when.
    #[serde(default)]
    pub lost_by: Option<(String, u64)>,
}

/// A confirmed key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KeyEntry {
    /// Key ID.
    pub key_id: String,
    /// The public key, base64 of 65 bytes.
    pub public: String,
    /// Its label there.
    pub label: String,
    /// `touch_id` / `password`.
    pub kind: String,
    /// When the owner confirmed it.
    pub confirmed_ms: u64,
}

impl KeyEntry {
    /// For the `devices` reply.
    pub fn info(&self) -> DeviceKeyInfo {
        DeviceKeyInfo {
            key_id: self.key_id.clone(),
            label: self.label.clone(),
            kind: self.kind.clone(),
            public_key: self.public.clone(),
            confirmed_ms: Some(self.confirmed_ms),
        }
    }
}

/// An announced key for the `devices` reply.
pub fn key_info(k: &DeviceKey) -> DeviceKeyInfo {
    DeviceKeyInfo {
        key_id: k.key_id.clone(),
        label: k.label.clone(),
        kind: k.kind.clone(),
        public_key: BASE64.encode(&k.public),
        confirmed_ms: None,
    }
}

/// The records, by link (hex).
pub type Records = BTreeMap<String, Record>;

/// The records in the database.
pub fn load(db: &Db) -> Result<Records> {
    match db.meta_get(META_RECORDS)? {
        None => Ok(Records::new()),
        Some(s) => serde_json::from_str(&s)
            .map_err(|e| Error::internal(format!("devices in the database: {e}"))),
    }
}

/// Stores the records.
pub fn save(db: &Db, r: &Records) -> Result<()> {
    let s = serde_json::to_string(r).map_err(|e| Error::internal(format!("devices: {e}")))?;
    db.meta_set(META_RECORDS, &s)
}

/// A status as kept: without the approval requests (they are stale by the time anyone reads a stored copy, and their
/// quotes need not sit on disk twice).
pub fn stored(status: &device::DeviceStatus) -> device::DeviceStatus {
    device::DeviceStatus {
        approvals: Vec::new(),
        ..status.clone()
    }
}

/// A status arrived from `link`: keep it, and keep confirmed only the keys it still announces with the same public
/// key (a key its owner turned off there is not accepted here any more). Returns whether a confirmed key was dropped.
pub fn note_status(r: &mut Record, status: &device::DeviceStatus, now: u64) -> bool {
    let before = r.confirmed.len();
    r.confirmed.retain(|c| {
        status
            .keys
            .iter()
            .any(|k| k.key_id == c.key_id && BASE64.encode(&k.public) == c.public)
    });
    r.last = Some(stored(status));
    r.received_ms = Some(now);
    r.confirmed.len() != before
}

/// Confirm `key_ids` (all offered when empty) of the device's last status. Errors: nothing announced, an unknown ID,
/// a key that is not a P-256 point.
pub fn confirm(r: &mut Record, key_ids: &[String], now: u64) -> Result<()> {
    let Some(last) = &r.last else {
        return Err(Error::new(
            code::NOT_FOUND,
            "this computer has not told this one its keys yet: it needs this version of Antenna and a connection",
        ));
    };
    let wanted: Vec<&DeviceKey> = if key_ids.is_empty() {
        last.keys.iter().collect()
    } else {
        key_ids
            .iter()
            .map(|id| {
                last.keys.iter().find(|k| &k.key_id == id).ok_or_else(|| {
                    Error::new(code::NOT_FOUND, format!("that computer offers no key {id}"))
                })
            })
            .collect::<Result<_>>()?
    };
    if wanted.is_empty() {
        return Err(Error::new(code::NOT_FOUND, "that computer offers no keys"));
    }
    for k in wanted {
        // The ID must be the key's own (the curve check is the same as for local owner keys)
        let public = owner_keys::parse_public(&BASE64.encode(&k.public))?;
        if owner_keys::key_id(&public) != k.key_id {
            return Err(Error::bad_request("that key's ID does not match it"));
        }
        if r.confirmed.iter().any(|c| c.key_id == k.key_id) {
            continue;
        }
        r.confirmed.push(KeyEntry {
            key_id: k.key_id.clone(),
            public: BASE64.encode(&k.public),
            label: k.label.clone(),
            kind: k.kind.clone(),
            confirmed_ms: now,
        });
    }
    Ok(())
}

/// The keys announced in the last status that are not confirmed.
pub fn offered(r: &Record) -> Vec<DeviceKeyInfo> {
    r.last
        .as_ref()
        .map(|s| {
            s.keys
                .iter()
                .filter(|k| !r.confirmed.iter().any(|c| c.key_id == k.key_id))
                .map(key_info)
                .collect()
        })
        .unwrap_or_default()
}

/// This node's device key: made on first use and kept in the encrypted database.
pub fn device_key(db: &Db) -> Result<EcdsaKeyPair> {
    if let Some(b64) = db.meta_get(META_DEVICE_KEY)? {
        let der = zeroize::Zeroizing::new(
            BASE64
                .decode(b64.as_bytes())
                .map_err(|_| Error::internal("device key in the database: not base64"))?,
        );
        return EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der)
            .map_err(|_| Error::internal("device key in the database: unreadable"));
    }
    let doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &SystemRandom::new())
        .map_err(|_| Error::internal("device key: cannot generate"))?;
    let b64 = zeroize::Zeroizing::new(BASE64.encode(doc.as_ref()));
    db.meta_set(META_DEVICE_KEY, &b64)?;
    tracing::info!("devices: a device key was made for approvals answered from this computer");
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, doc.as_ref())
        .map_err(|_| Error::internal("device key: unreadable"))
}

/// The device key as the other devices see it.
pub fn device_key_announced(key: &EcdsaKeyPair) -> DeviceKey {
    let public = key.public_key().as_ref().to_vec();
    DeviceKey {
        key_id: owner_keys::key_id(&public),
        public,
        label: DEVICE_KEY_LABEL.into(),
        kind: KEY_PASSWORD.into(),
    }
}

/// The owner proof of D-102 by the device key: `request` is the exact text, `nonce` the other device's challenge.
pub fn sign(key: &EcdsaKeyPair, nonce: &[u8; 32], request: &str) -> Result<Vec<u8>> {
    let m = antenna_proto::control::owner_keys::proof_message(
        nonce,
        &crypto::sha256(&[request.as_bytes()]),
    );
    key.sign(&SystemRandom::new(), &m)
        .map(|s| s.as_ref().to_vec())
        .map_err(|_| Error::internal("device key: cannot sign"))
}

/// "Lend this computer to my teams".
pub fn lend(db: &Db) -> Result<bool> {
    Ok(db.meta_get(META_LEND)?.as_deref() == Some("on"))
}

/// Sets it.
pub fn set_lend(db: &Db, on: bool) -> Result<()> {
    db.meta_set(META_LEND, if on { "on" } else { "off" })
}

/// A computer removed here as lost.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Lost {
    /// Its label here.
    pub contact: String,
    /// The public keys it had announced (base64).
    pub keys: Vec<String>,
    /// When.
    pub at_ms: u64,
}

/// The lost computers still announced (younger than [`LOST_KEEP_MS`]).
pub fn lost(db: &Db, now: u64) -> Result<Vec<Lost>> {
    let all: Vec<Lost> = match db.meta_get(META_LOST)? {
        None => Vec::new(),
        Some(s) => serde_json::from_str(&s)
            .map_err(|e| Error::internal(format!("lost devices in the database: {e}")))?,
    };
    Ok(all
        .into_iter()
        .filter(|l| now.saturating_sub(l.at_ms) < LOST_KEEP_MS)
        .collect())
}

/// Adds one (the newest [`device::MAX_LOST`] are kept).
pub fn add_lost(db: &Db, l: Lost, now: u64) -> Result<()> {
    let mut all = lost(db, now)?;
    all.retain(|x| x.keys != l.keys);
    all.push(l);
    let skip = all.len().saturating_sub(device::MAX_LOST);
    let all: Vec<Lost> = all.into_iter().skip(skip).collect();
    let s = serde_json::to_string(&all).map_err(|e| Error::internal(format!("lost: {e}")))?;
    db.meta_set(META_LOST, &s)
}

/// Another device reported computers as lost: every record here whose last announced keys share one with a lost
/// computer loses its confirmed keys (it only takes a way in away, as `owner_key_remove` does) and is marked. Returns
/// the links marked now.
pub fn apply_lost(
    records: &mut Records,
    reporter_link: &str,
    reporter: &str,
    lost: &[device::LostDevice],
) -> Vec<String> {
    let mut marked = Vec::new();
    for (link, r) in records.iter_mut() {
        if link == reporter_link {
            continue;
        }
        let Some(last) = &r.last else { continue };
        let hit = lost.iter().find(|l| {
            l.keys
                .iter()
                .any(|lk| last.keys.iter().any(|k| crypto::ct_eq(&k.public, lk)))
        });
        if let Some(l) = hit {
            let fresh = r.lost_by.is_none() || !r.confirmed.is_empty();
            r.confirmed.clear();
            if r.lost_by.is_none() {
                r.lost_by = Some((reporter.to_string(), l.at_ms));
            }
            if fresh {
                marked.push(link.clone());
            }
        }
    }
    marked
}

/// Challenges issued for remote decisions, per link, and failed proofs in a row per link (memory only).
#[derive(Debug, Default)]
pub struct Challenges {
    issued: HashMap<LinkId, VecDeque<([u8; 32], u64)>>,
    fails: HashMap<LinkId, (u32, u64)>,
}

impl Challenges {
    /// A new challenge for one decision that comes over `link`.
    pub fn issue(&mut self, link: LinkId, now: u64, ttl_ms: u64) -> ([u8; 32], u64) {
        let q = self.issued.entry(link).or_default();
        q.retain(|(_, exp)| *exp > now);
        while q.len() >= CHALLENGES_PER_LINK {
            q.pop_front();
        }
        let nonce = crypto::random::<32>();
        let exp = now.saturating_add(ttl_ms);
        q.push_back((nonce, exp));
        (nonce, exp)
    }

    /// Takes the challenge a decision names: once, whether or not its proof then verifies; only on the link it was
    /// issued to, only while fresh.
    pub fn take(&mut self, link: &LinkId, nonce: &[u8; 32], now: u64) -> Result<()> {
        let bad = |why: &str| {
            Error::new(
                code::CHALLENGE_INVALID,
                format!("the challenge {why}: ask that computer for a new one"),
            )
        };
        let q = self
            .issued
            .get_mut(link)
            .ok_or_else(|| bad("was not issued to this computer"))?;
        let i = q
            .iter()
            .position(|(n, _)| crypto::ct_eq(n, nonce))
            .ok_or_else(|| bad("is unknown or already used"))?;
        let (_, exp) = q.remove(i).ok_or_else(|| bad("is unknown"))?;
        if exp <= now {
            return Err(bad("expired"));
        }
        Ok(())
    }

    /// Refused while the device's remote approvals pause after failed proofs.
    pub fn check_pause(&self, link: &LinkId, now: u64) -> Result<()> {
        match self.fails.get(link) {
            Some((_, until)) if now < *until => Err(Error::new(
                code::RATE_LIMITED,
                format!(
                    "too many failed approvals from that computer; try again in {} s",
                    (until - now).div_ceil(1000)
                ),
            )),
            _ => Ok(()),
        }
    }

    /// Records the outcome of a proof from `link`.
    pub fn record(&mut self, link: LinkId, ok: bool, now: u64) {
        if ok {
            self.fails.remove(&link);
            return;
        }
        let e = self.fails.entry(link).or_insert((0, 0));
        e.0 += 1;
        if e.0 >= FAILS_MAX {
            let pause = PAUSE_MS << (e.0 - FAILS_MAX).min(3);
            e.1 = now.saturating_add(pause);
        }
    }

    /// `lock` and the end of a link: nothing issued survives.
    pub fn forget(&mut self, link: &LinkId) {
        self.issued.remove(link);
        self.fails.remove(link);
    }
}

/// What a checked remote decision allows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Checked {
    /// Approve `id` with this fingerprint; `key_id` signed it.
    Approve {
        /// Request ID.
        id: String,
        /// The fingerprint the owner saw.
        fingerprint: String,
        /// The key that signed.
        key_id: String,
    },
    /// Deny `id`.
    Deny {
        /// Request ID.
        id: String,
    },
}

/// Checks a remote decision that came over `link` (hex), in the order of `docs/PROTOCOL.md` §24: the text and the link
/// it names, then (approve) the challenge (taken by `take`, once), the key (confirmed here for this device), the
/// signature. The trust level and the confirmed-at-all check come before (the caller's).
pub fn check_decision(
    link: &LinkId,
    confirmed: &[KeyEntry],
    d: &RemoteDecision,
    take: impl FnOnce(&[u8; 32]) -> Result<()>,
) -> Result<Checked> {
    d.check()
        .map_err(|f| Error::bad_request(format!("remote decision: bad {f}")))?;
    let req = RemoteRequest::parse(&d.request)
        .map_err(|e| Error::bad_request(format!("remote decision: {e}")))?;
    if req.link() != link.to_hex() {
        return Err(Error::bad_request(
            "the signed request names another link: it was made for another computer",
        ));
    }
    match req {
        RemoteRequest::RemoteDeny { id, .. } => Ok(Checked::Deny { id }),
        RemoteRequest::RemoteApprove {
            id, fingerprint, ..
        } => {
            let (Some(nonce), Some(key_id), Some(sig)) = (&d.nonce, &d.key_id, &d.sig) else {
                return Err(Error::new(
                    code::PROOF_INVALID,
                    "an approval from another device carries a challenge, a key and a signature",
                ));
            };
            take(nonce)?;
            let k = confirmed
                .iter()
                .find(|k| &k.key_id == key_id)
                .ok_or_else(|| {
                    Error::new(
                        code::OWNER_KEY_UNKNOWN,
                        "this computer's owner has not confirmed that key of the other device: confirm it in My devices",
                    )
                })?;
            let public = owner_keys::parse_public(&k.public)?;
            owner_keys::verify(
                &public,
                nonce,
                &crypto::sha256(&[d.request.as_bytes()]),
                &BASE64.encode(sig),
            )?;
            Ok(Checked::Approve {
                id,
                fingerprint,
                key_id: key_id.clone(),
            })
        }
    }
}

/// Codes of a remote decision's failures that count as a failed proof.
pub fn counts_as_failed(c: &str) -> bool {
    matches!(
        c,
        code::PROOF_INVALID | code::CHALLENGE_INVALID | code::OWNER_KEY_UNKNOWN
    )
}

/// 64 hex → 32 bytes.
pub fn nonce_from_hex(s: &str) -> Result<[u8; 32]> {
    HEXLOWER
        .decode(s.as_bytes())
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| Error::bad_request("nonce: 64 hex characters"))
}

/// This computer's name and OS release, read once (Linux: `/proc/sys/kernel/hostname`, `/etc/os-release`; macOS:
/// `kern.hostname`, `kern.osproductversion`). Nothing here needs a permission or starts a process.
pub fn machine_names() -> (String, String) {
    let clean = |s: String, max: usize| -> String {
        let s: String = s.trim().chars().filter(|c| !c.is_control()).collect();
        device::cut(&s, max)
    };
    #[cfg(target_os = "linux")]
    let (host, os) = {
        let host = std::fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default();
        let os = std::fs::read_to_string("/etc/os-release")
            .unwrap_or_default()
            .lines()
            .find_map(|l| l.strip_prefix("PRETTY_NAME="))
            .map(|v| v.trim_matches('"').to_string())
            .unwrap_or_default();
        (host, os)
    };
    #[cfg(target_os = "macos")]
    let (host, os) = {
        use antenna_sys::darwin::sysctl_string;
        let host = sysctl_string("kern.hostname").unwrap_or_default();
        let host = host.strip_suffix(".local").unwrap_or(&host).to_string();
        let os = sysctl_string("kern.osproductversion")
            .map(|v| format!("macOS {v}"))
            .unwrap_or_default();
        (host, os)
    };
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let (host, os) = (String::new(), String::new());
    (clean(host, 64), clean(os, 64))
}

#[cfg(test)]
mod tests {
    use antenna_proto::device::{DeviceStatus, LostDevice, STATUS_VERSION, UpdateFacts};

    use super::*;
    use crate::owner_keys::testing::SoftKey;

    fn link(b: u8) -> LinkId {
        LinkId([b; 32])
    }

    fn status(keys: Vec<DeviceKey>) -> DeviceStatus {
        DeviceStatus {
            v: STATUS_VERSION,
            at_ms: 1,
            name: "mini".into(),
            os: "linux".into(),
            os_version: String::new(),
            arch: "x86_64".into(),
            memory_bytes: 0,
            version: "antennad 0.2.0".into(),
            update: UpdateFacts::default(),
            health: vec![],
            agents: vec![],
            approvals: vec![],
            pending_approvals: 0,
            lend: false,
            keys,
            accepts: vec![],
            lost: vec![],
            approvers: vec![],
        }
    }

    fn announced(k: &SoftKey, kind: &str) -> DeviceKey {
        DeviceKey {
            key_id: k.key_id(),
            public: BASE64.decode(k.public_b64().as_bytes()).unwrap(),
            label: "touchid@mini".into(),
            kind: kind.into(),
        }
    }

    fn approve_text(l: &LinkId, id: &str, fp: &str) -> String {
        RemoteRequest::RemoteApprove {
            link: l.to_hex(),
            id: id.into(),
            fingerprint: fp.into(),
        }
        .to_text()
    }

    fn decision(k: &SoftKey, nonce: [u8; 32], text: &str) -> RemoteDecision {
        RemoteDecision {
            request: text.into(),
            nonce: Some(nonce),
            key_id: Some(k.key_id()),
            sig: Some(
                BASE64
                    .decode(k.sign(&nonce, text.as_bytes()).as_bytes())
                    .unwrap(),
            ),
        }
    }

    /// Negative controls (run once each, 2026-10-06): with the link comparison removed, the decision made for another
    /// link was accepted; with `take` not called, the replay was accepted; with the key lookup ignoring the key ID, the
    /// unconfirmed key was not told apart (`proof_invalid` instead of `owner_key_unknown`). Each failed this test.
    #[test]
    fn a_remote_approval_holds_only_for_its_link_challenge_key_and_request() {
        let k = SoftKey::random();
        let other = SoftKey::random();
        let mut r = Record::default();
        note_status(
            &mut r,
            &status(vec![
                announced(&k, "touch_id"),
                announced(&other, "touch_id"),
            ]),
            5,
        );
        confirm(&mut r, &[k.key_id()], 6).unwrap();
        let mut ch = Challenges::default();
        let l = link(1);
        let (n, _) = ch.issue(l, 10, 60_000);
        let text = approve_text(&l, "k2", "9c41");
        let d = decision(&k, n, &text);
        let ok = check_decision(&l, &r.confirmed, &d, |x| ch.take(&l, x, 20)).unwrap();
        assert_eq!(
            ok,
            Checked::Approve {
                id: "k2".into(),
                fingerprint: "9c41".into(),
                key_id: k.key_id()
            }
        );
        let e = |x: Result<Checked>| x.unwrap_err().code;
        // Replayed: the challenge was used.
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &d, |x| ch.take(&l, x, 20))),
            code::CHALLENGE_INVALID
        );
        // Another request: the signature covers the exact text (another fingerprint, another ID).
        let (n2, _) = ch.issue(l, 10, 60_000);
        let mut d2 = decision(&k, n2, &text);
        d2.request = approve_text(&l, "k2", "0000");
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &d2, |x| ch.take(&l, x, 20))),
            code::PROOF_INVALID
        );
        let (n3, _) = ch.issue(l, 10, 60_000);
        let mut d3 = decision(&k, n3, &text);
        d3.request = approve_text(&l, "k9", "9c41");
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &d3, |x| ch.take(&l, x, 20))),
            code::PROOF_INVALID
        );
        // A key the owner never confirmed here (announced, but not confirmed).
        let (n4, _) = ch.issue(l, 10, 60_000);
        let d4 = decision(&other, n4, &text);
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &d4, |x| ch.take(&l, x, 20))),
            code::OWNER_KEY_UNKNOWN
        );
        // A text made for another link (relayed through another device): refused before the challenge is touched.
        let (n5, _) = ch.issue(l, 10, 60_000);
        let relayed = decision(&k, n5, &approve_text(&link(2), "k2", "9c41"));
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &relayed, |x| ch.take(&l, x, 20))),
            code::BAD_REQUEST
        );
        // A challenge issued on another link is unknown on this one.
        let (n6, _) = ch.issue(link(2), 10, 60_000);
        let d6 = decision(&k, n6, &text);
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &d6, |x| ch.take(&l, x, 20))),
            code::CHALLENGE_INVALID
        );
        // Expired.
        let (n7, exp) = ch.issue(l, 10, 60_000);
        let d7 = decision(&k, n7, &text);
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &d7, |x| ch.take(&l, x, exp))),
            code::CHALLENGE_INVALID
        );
        // An approval without its proof.
        let bare = RemoteDecision {
            request: text.clone(),
            nonce: None,
            key_id: None,
            sig: None,
        };
        assert_eq!(
            e(check_decision(&l, &r.confirmed, &bare, |x| ch.take(&l, x, 20))),
            code::PROOF_INVALID
        );
        // A deny needs no proof, but names this link too.
        let deny = RemoteDecision {
            request: RemoteRequest::RemoteDeny {
                link: l.to_hex(),
                id: "k2".into(),
            }
            .to_text(),
            ..bare
        };
        assert_eq!(
            check_decision(&l, &[], &deny, |_| unreachable!()).unwrap(),
            Checked::Deny { id: "k2".into() }
        );
    }

    #[test]
    fn the_device_key_signs_what_an_owner_key_would() {
        let key = EcdsaKeyPair::from_pkcs8(
            &ECDSA_P256_SHA256_FIXED_SIGNING,
            EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &SystemRandom::new())
                .unwrap()
                .as_ref(),
        )
        .unwrap();
        let a = device_key_announced(&key);
        assert_eq!(a.check(), Ok(()));
        let mut r = Record::default();
        note_status(&mut r, &status(vec![a.clone()]), 1);
        confirm(&mut r, &[], 2).unwrap();
        let l = link(3);
        let mut ch = Challenges::default();
        let (n, _) = ch.issue(l, 0, 60_000);
        let text = approve_text(&l, "k2", "9c41");
        let d = RemoteDecision {
            request: text.clone(),
            nonce: Some(n),
            key_id: Some(a.key_id.clone()),
            sig: Some(sign(&key, &n, &text).unwrap()),
        };
        assert!(check_decision(&l, &r.confirmed, &d, |x| ch.take(&l, x, 1)).is_ok());
    }

    #[test]
    fn confirmed_keys_follow_what_the_device_announces() {
        let k = SoftKey::random();
        let k2 = SoftKey::random();
        let mut r = Record::default();
        assert_eq!(confirm(&mut r, &[], 1).unwrap_err().code, code::NOT_FOUND);
        note_status(
            &mut r,
            &status(vec![announced(&k, "touch_id"), announced(&k2, "password")]),
            1,
        );
        assert_eq!(offered(&r).len(), 2);
        assert_eq!(
            confirm(&mut r, &["0000000000000000".into()], 1)
                .unwrap_err()
                .code,
            code::NOT_FOUND
        );
        confirm(&mut r, &[k.key_id()], 2).unwrap();
        assert_eq!(offered(&r).len(), 1);
        // The device stops announcing the key (Touch ID turned off there): it is no longer accepted here.
        assert!(note_status(
            &mut r,
            &status(vec![announced(&k2, "password")]),
            3
        ));
        assert!(r.confirmed.is_empty());
        // The same ID with another public key is not the confirmed key.
        confirm(&mut r, &[], 4).unwrap();
        let mut swapped = announced(&k2, "password");
        swapped.public = BASE64.decode(k.public_b64().as_bytes()).unwrap();
        assert!(note_status(&mut r, &status(vec![swapped.clone()]), 5));
        assert!(r.confirmed.is_empty());
        // A key whose ID is not its own is refused.
        assert_eq!(confirm(&mut r, &[], 6).unwrap_err().code, code::BAD_REQUEST);
        // Stored without approvals.
        let mut s = status(vec![]);
        s.pending_approvals = 1;
        s.approvals = vec![];
        assert!(stored(&s).approvals.is_empty());
    }

    #[test]
    fn lost_reports_remove_confirmed_keys_of_that_computer_only() {
        let lost_key = SoftKey::random();
        let other = SoftKey::random();
        let mut records = Records::new();
        let mut a = Record::default();
        note_status(&mut a, &status(vec![announced(&lost_key, "touch_id")]), 1);
        confirm(&mut a, &[], 1).unwrap();
        let mut b = Record::default();
        note_status(&mut b, &status(vec![announced(&other, "touch_id")]), 1);
        confirm(&mut b, &[], 1).unwrap();
        records.insert("aa".into(), a);
        records.insert("bb".into(), b);
        records.insert("cc".into(), Record::default());
        let report = vec![LostDevice {
            keys: vec![serde_bytes::ByteBuf::from(
                BASE64.decode(lost_key.public_b64().as_bytes()).unwrap(),
            )],
            at_ms: 7,
        }];
        // The reporter's own record is never touched.
        let mut copy = records.clone();
        assert!(apply_lost(&mut copy, "aa", "laptop", &report).is_empty());
        assert_eq!(
            apply_lost(&mut records, "rr", "laptop", &report),
            vec!["aa".to_string()]
        );
        assert!(records["aa"].confirmed.is_empty());
        assert_eq!(records["aa"].lost_by, Some(("laptop".into(), 7)));
        assert_eq!(records["bb"].confirmed.len(), 1);
        // A repeat changes nothing and says nothing.
        assert!(apply_lost(&mut records, "rr", "laptop", &report).is_empty());
    }

    #[test]
    fn failed_proofs_pause_one_device() {
        let mut ch = Challenges::default();
        let l = link(4);
        for _ in 0..FAILS_MAX {
            assert!(ch.check_pause(&l, 0).is_ok());
            ch.record(l, false, 0);
        }
        assert_eq!(ch.check_pause(&l, 1).unwrap_err().code, code::RATE_LIMITED);
        assert!(ch.check_pause(&link(5), 1).is_ok());
        assert!(ch.check_pause(&l, PAUSE_MS).is_ok());
        ch.record(l, true, PAUSE_MS);
        assert!(ch.check_pause(&l, PAUSE_MS).is_ok());
        // At most 16 outstanding: the oldest goes.
        let first = ch.issue(l, 0, 60_000).0;
        for _ in 0..CHALLENGES_PER_LINK {
            ch.issue(l, 0, 60_000);
        }
        assert!(ch.take(&l, &first, 1).is_err());
    }

    #[test]
    fn machine_names_are_one_short_line() {
        let (host, os) = machine_names();
        assert!(
            host.len() <= 64 && !host.chars().any(char::is_control),
            "{host}"
        );
        assert!(os.len() <= 64 && !os.chars().any(char::is_control), "{os}");
    }
}
