// SPDX-License-Identifier: AGPL-3.0-only
//! Owner keys (v7, `docs/CONTROL.md` §22, D-102, experimental): P-256 keys the owner enrolled with the password, whose
//! signatures stand in for the password on one owner command each.
//!
//! Verification is ECDSA P-256 with SHA-256 from `aws-lc-rs` (`ECDSA_P256_SHA256_FIXED`), the TLS provider already in
//! every build (`docs/STACK.md`); nothing here builds a primitive of its own. The keys are kept in the encrypted
//! database (`meta`), the challenges and the count of failed proofs only in memory.

use std::collections::VecDeque;

use antenna_proto::control::{
    OwnerKeyInfo, code,
    owner_keys::{CHALLENGES_MAX, LABEL_MAX, PUBLIC_KEY_LEN, SIGNATURE_LEN, proof_message},
};
use aws_lc_rs::signature::{ECDSA_P256_SHA256_FIXED, ParsedPublicKey};
use data_encoding::{BASE64, HEXLOWER};
use serde::{Deserialize, Serialize};

use crate::{
    crypto,
    error::{Error, Result},
    store::Db,
};

/// `meta` key of the enrolled keys (a JSON list).
const META_KEYS: &str = "owner_keys";
/// `meta` key of the last moment the owner password was checked correctly (unix ms, decimal).
const META_PASSWORD_MS: &str = "owner_password_ms";

/// The public test key (D-82's pattern): its private key is in this file, so only a debug build that asks for it
/// trusts it.
pub mod test_key {
    /// Debug builds accept the test key only when this variable is `1`.
    pub const ENV: &str = "ANTENNA_OWNER_TEST_KEY";
    /// The public key, base64 of the 65-byte X9.62 point.
    pub const PUBLIC: &str =
        "BPcpOpocd8N5toWe1+F6lK+AU62/2qoTm5PZNlZIpsl9jTesqC2CuI6DrymmK5qk5RwfuiAXRDt0/imLMGqrz38=";
    /// Its key ID.
    pub const KEY_ID: &str = "01b3e9c533123cb8";
    /// The private key, PKCS#8 DER in base64. Public on purpose: tests and fixtures sign with it (the scalar is
    /// SHA-256 of "antenna owner-proof public TEST key").
    pub const PKCS8: &str = "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgqr2E8T1OOXd8++EMFL6D+SAk4412xtz4w910vUoSVRShRANCAAT3KTqaHHfDebaFntfhepSvgFOtv9qqE5uT2TZWSKbJfY03rKgtgriOg68ppiuapOUcH7ogF0Q7dP4pizBqq89/";
}

/// Whether this build trusts the public test key: a debug build started with [`test_key::ENV`] `1`. Release builds do
/// not contain the branch that reads the variable at all (`packaging/linux/check-install.sh` checks the release
/// binary).
pub fn test_key_accepted() -> bool {
    #[cfg(debug_assertions)]
    let accepted = std::env::var(test_key::ENV).as_deref() == Ok("1");
    #[cfg(not(debug_assertions))]
    let accepted = false;
    accepted
}

/// Key ID: the first 8 bytes of SHA-256 of the 65-byte public key, hex.
pub fn key_id(public: &[u8]) -> String {
    HEXLOWER.encode(&crypto::sha256(&[public])[..8])
}

/// A public key from the wire: base64 of exactly 65 bytes, uncompressed (`0x04`), a point on P-256.
pub fn parse_public(b64: &str) -> Result<[u8; PUBLIC_KEY_LEN]> {
    let raw = BASE64
        .decode(b64.trim().as_bytes())
        .map_err(|_| Error::bad_request("public_key is not base64"))?;
    let raw: [u8; PUBLIC_KEY_LEN] = raw.as_slice().try_into().map_err(|_| {
        Error::bad_request("public_key is the 65-byte uncompressed X9.62 form of a P-256 point")
    })?;
    if raw[0] != 0x04 {
        return Err(Error::bad_request(
            "public_key is the 65-byte uncompressed X9.62 form of a P-256 point",
        ));
    }
    ParsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, raw)
        .map_err(|_| Error::bad_request("public_key is not a P-256 point"))?;
    Ok(raw)
}

/// Checks a signature (base64 of 64 bytes `r ‖ s`) by `public` over the owner proof message of `nonce` and
/// `request_hash` (`docs/CONTROL.md` §22.2).
pub fn verify(
    public: &[u8; PUBLIC_KEY_LEN],
    nonce: &[u8; 32],
    request_hash: &[u8; 32],
    sig_b64: &str,
) -> Result<()> {
    let bad = || {
        Error::new(
            code::PROOF_INVALID,
            "the owner proof does not verify: use the password",
        )
    };
    let sig = BASE64
        .decode(sig_b64.trim().as_bytes())
        .map_err(|_| bad())?;
    if sig.len() != SIGNATURE_LEN {
        return Err(bad());
    }
    let key = ParsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, public).map_err(|_| bad())?;
    key.verify_sig(&proof_message(nonce, request_hash), &sig)
        .map_err(|_| bad())
}

/// A checked label: 1–64 bytes, no control characters, trimmed.
pub fn label(s: &str) -> Result<String> {
    let s = s.trim();
    if s.is_empty() || s.len() > LABEL_MAX || s.chars().any(char::is_control) {
        return Err(Error::bad_request(
            "label: 1–64 bytes without control characters",
        ));
    }
    Ok(s.to_string())
}

/// A slot key from the wire: base64 of 32 bytes.
pub fn parse_slot_key(b64: &str) -> Result<zeroize::Zeroizing<[u8; 32]>> {
    let raw = zeroize::Zeroizing::new(
        BASE64
            .decode(b64.trim().as_bytes())
            .map_err(|_| Error::bad_request("slot_key is base64 of 32 bytes"))?,
    );
    let mut k = zeroize::Zeroizing::new([0u8; 32]);
    if raw.len() != 32 {
        return Err(Error::bad_request("slot_key is base64 of 32 bytes"));
    }
    k.copy_from_slice(&raw);
    Ok(k)
}

/// An enrolled key as stored.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KeyRecord {
    /// Key ID.
    pub key_id: String,
    /// The public key, base64 of 65 bytes.
    pub public: String,
    /// Label.
    pub label: String,
    /// Enrolled (unix ms).
    pub created_ms: u64,
    /// Last proof that verified (unix ms).
    #[serde(default)]
    pub last_used_ms: Option<u64>,
    /// It has an unlock slot.
    #[serde(default)]
    pub unlock: bool,
}

impl KeyRecord {
    /// The public key bytes (checked again: the database is the source, but a value that is not a point is refused).
    pub fn public(&self) -> Result<[u8; PUBLIC_KEY_LEN]> {
        parse_public(&self.public)
    }

    /// For `owner_key_list`.
    pub fn info(&self) -> OwnerKeyInfo {
        OwnerKeyInfo {
            key_id: self.key_id.clone(),
            label: self.label.clone(),
            created_ms: self.created_ms,
            last_used_ms: self.last_used_ms,
            unlock: self.unlock,
        }
    }

    /// This is the public test key.
    pub fn is_test_key(&self) -> bool {
        self.key_id == test_key::KEY_ID || self.public == test_key::PUBLIC
    }
}

/// The enrolled keys.
pub fn load(db: &Db) -> Result<Vec<KeyRecord>> {
    match db.meta_get(META_KEYS)? {
        None => Ok(Vec::new()),
        Some(s) => serde_json::from_str(&s)
            .map_err(|e| Error::internal(format!("owner keys in the database: {e}"))),
    }
}

/// Stores the enrolled keys.
pub fn save(db: &Db, keys: &[KeyRecord]) -> Result<()> {
    let s = serde_json::to_string(keys).map_err(|e| Error::internal(format!("owner keys: {e}")))?;
    db.meta_set(META_KEYS, &s)
}

/// When the owner password was last checked correctly (unix ms); `None` on a node that has not seen it since v7.
pub fn password_ms(db: &Db) -> Result<Option<u64>> {
    Ok(db.meta_get(META_PASSWORD_MS)?.and_then(|s| s.parse().ok()))
}

/// Records a correct owner password now.
pub fn note_password(db: &Db, now: u64) -> Result<()> {
    db.meta_set(META_PASSWORD_MS, &now.to_string())
}

/// After this moment proofs and unlock slots are refused until the password is used again (`every_ms`: 14 days,
/// `PASSWORD_EVERY_MS`, shorter only in tests).
pub fn password_due_ms(last: Option<u64>, every_ms: u64) -> u64 {
    last.map_or(0, |ms| ms.saturating_add(every_ms))
}

/// The error for a proof that waits for the password.
pub fn password_due_error() -> Error {
    Error::new(
        code::PASSWORD_REQUIRED,
        "enter the owner password: it is asked every 14 days, and after three failed Touch ID attempts",
    )
}

/// Who a challenge was issued to: the client process (PID and start time, read from the socket on connect) and its
/// owner session token, if it presented one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bind {
    /// PID.
    pub pid: i32,
    /// Start time (Linux: ticks since boot; macOS: `p_uniqueid`).
    pub start: u64,
    /// SHA-256 of the `hello.session` token.
    pub session: Option<[u8; 32]>,
}

#[derive(Debug)]
struct Issued {
    nonce: [u8; 32],
    bind: Bind,
    expires_ms: u64,
    /// For `owner_key_add`'s proof of possession only; a plain challenge is for every other proof.
    enroll: bool,
}

/// Outstanding challenges and the failed proofs in a row (memory only; `lock` clears them).
#[derive(Debug, Default)]
pub struct ProofState {
    issued: VecDeque<Issued>,
    /// Failed proofs (and unlock slots) in a row since the last correct password.
    pub fails: u32,
}

impl ProofState {
    /// A new challenge for `bind`, valid `ttl_ms` (60 s, `CHALLENGE_TTL_MS`, shorter only in tests); the oldest
    /// outstanding one is pushed out beyond [`CHALLENGES_MAX`].
    pub fn issue(&mut self, bind: Bind, now: u64, ttl_ms: u64, enroll: bool) -> ([u8; 32], u64) {
        self.issued.retain(|c| c.expires_ms > now);
        while self.issued.len() >= CHALLENGES_MAX {
            self.issued.pop_front();
        }
        let nonce = crypto::random::<32>();
        let expires_ms = now.saturating_add(ttl_ms);
        self.issued.push_back(Issued {
            nonce,
            bind,
            expires_ms,
            enroll,
        });
        (nonce, expires_ms)
    }

    /// Takes the challenge named by a proof: once, whether or not the proof then verifies. Refused when it was never
    /// issued here, is used or expired, or was issued to another client.
    pub fn take(
        &mut self,
        nonce_hex: &str,
        bind: &Bind,
        now: u64,
        enroll: bool,
    ) -> Result<[u8; 32]> {
        let bad = |why: &str| {
            Error::new(
                code::CHALLENGE_INVALID,
                format!("the owner proof's challenge {why}: ask for a new one"),
            )
        };
        let nonce: [u8; 32] = HEXLOWER
            .decode(nonce_hex.as_bytes())
            .ok()
            .and_then(|v| v.try_into().ok())
            .ok_or_else(|| bad("is not 64 hex characters"))?;
        let i = self
            .issued
            .iter()
            .position(|c| crypto::ct_eq(&c.nonce, &nonce))
            .ok_or_else(|| bad("is unknown or already used"))?;
        let c = self.issued.remove(i).ok_or_else(|| bad("is unknown"))?;
        if c.expires_ms <= now {
            return Err(bad("expired"));
        }
        if c.bind != *bind {
            return Err(bad("was issued to another client"));
        }
        if c.enroll != enroll {
            return Err(bad(if c.enroll {
                "was issued for enrolling a key"
            } else {
                "was not issued for enrolling a key"
            }));
        }
        Ok(nonce)
    }

    /// `lock`: nothing issued survives it.
    pub fn clear(&mut self) {
        self.issued.clear();
    }
}

#[cfg(test)]
pub(crate) mod testing {
    //! Signing with software keys, for tests only (the daemon itself only verifies).
    use aws_lc_rs::{
        rand::SystemRandom,
        signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair},
    };

    use super::*;

    /// A software P-256 key.
    pub struct SoftKey(pub EcdsaKeyPair);

    impl SoftKey {
        /// A new random key.
        pub fn random() -> Self {
            let doc = EcdsaKeyPair::generate_pkcs8(
                &ECDSA_P256_SHA256_FIXED_SIGNING,
                &SystemRandom::new(),
            )
            .unwrap();
            Self(EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, doc.as_ref()).unwrap())
        }

        /// The public test key.
        pub fn test_key() -> Self {
            let der = BASE64.decode(test_key::PKCS8.as_bytes()).unwrap();
            Self(EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der).unwrap())
        }

        /// Base64 of the public key.
        pub fn public_b64(&self) -> String {
            BASE64.encode(self.0.public_key().as_ref())
        }

        /// Its key ID.
        pub fn key_id(&self) -> String {
            key_id(self.0.public_key().as_ref())
        }

        /// Base64 of a signature over the proof message.
        pub fn sign(&self, nonce: &[u8; 32], request: &[u8]) -> String {
            let m = proof_message(nonce, &crypto::sha256(&[request]));
            BASE64.encode(self.0.sign(&SystemRandom::new(), &m).unwrap().as_ref())
        }
    }
}

#[cfg(test)]
mod tests {
    use antenna_proto::control::owner_keys::{CHALLENGE_TTL_MS, PASSWORD_EVERY_MS};

    use super::testing::SoftKey;
    use super::*;

    fn bind(pid: i32) -> Bind {
        Bind {
            pid,
            start: 7,
            session: None,
        }
    }

    #[test]
    fn the_test_key_constants_agree() {
        let k = SoftKey::test_key();
        assert_eq!(k.public_b64(), test_key::PUBLIC);
        assert_eq!(k.key_id(), test_key::KEY_ID);
        assert_eq!(
            key_id(&parse_public(test_key::PUBLIC).unwrap()),
            test_key::KEY_ID
        );
    }

    /// Negative control (run once, 2026-10-06): with `verify` returning `Ok(())` early, every refusal below passed as
    /// a valid proof and the test failed on the first one.
    #[test]
    fn a_signature_verifies_only_for_its_key_nonce_and_request() {
        let k = SoftKey::random();
        let other = SoftKey::random();
        let pk = parse_public(&k.public_b64()).unwrap();
        let nonce = [9u8; 32];
        let req = br#"{"cmd":"approve","id":"k2","password":"","fingerprint":"9c41"}"#;
        let h = crypto::sha256(&[req]);
        let sig = k.sign(&nonce, req);
        assert!(verify(&pk, &nonce, &h, &sig).is_ok());
        // Another key, another nonce, another request (another fingerprint), a malformed signature.
        let e = |r: Result<()>| r.unwrap_err().code;
        assert_eq!(
            e(verify(&pk, &nonce, &h, &other.sign(&nonce, req))),
            code::PROOF_INVALID
        );
        assert_eq!(e(verify(&pk, &[8; 32], &h, &sig)), code::PROOF_INVALID);
        let req2 = br#"{"cmd":"approve","id":"k2","password":"","fingerprint":"0000"}"#;
        assert_eq!(
            e(verify(&pk, &nonce, &crypto::sha256(&[req2]), &sig)),
            code::PROOF_INVALID
        );
        assert_eq!(
            e(verify(&pk, &nonce, &h, "not base64!")),
            code::PROOF_INVALID
        );
        assert_eq!(
            e(verify(&pk, &nonce, &h, &BASE64.encode(&[0u8; 64]))),
            code::PROOF_INVALID
        );
        assert_eq!(
            e(verify(&pk, &nonce, &h, &BASE64.encode(&[1u8; 63]))),
            code::PROOF_INVALID
        );
        // A DER signature (CryptoKit's other form) is not the fixed form and is refused.
        let mut der = vec![0x30, 0x44, 0x02, 0x20];
        der.extend_from_slice(&BASE64.decode(sig.as_bytes()).unwrap()[..32]);
        der.extend_from_slice(&[0x02, 0x20]);
        der.extend_from_slice(&BASE64.decode(sig.as_bytes()).unwrap()[32..]);
        assert_eq!(
            e(verify(&pk, &nonce, &h, &BASE64.encode(&der))),
            code::PROOF_INVALID
        );
    }

    /// A signature made by an independent implementation (Python `cryptography` 41, OpenSSL 3.0) with the public test
    /// key over nonce 32 × 0x01 and the request `{"cmd":"owner_key_list"}`: the same bytes a client signs.
    #[test]
    fn a_vector_from_another_implementation_verifies() {
        let pk = parse_public(test_key::PUBLIC).unwrap();
        let nonce = [1u8; 32];
        let h = crypto::sha256(&[br#"{"cmd":"owner_key_list"}"#]);
        assert!(verify(&pk, &nonce, &h, VECTOR_SIG).is_ok());
        assert!(verify(&pk, &[2u8; 32], &h, VECTOR_SIG).is_err());
    }

    /// See [`a_vector_from_another_implementation_verifies`].
    const VECTOR_SIG: &str =
        "6ggbQFoCL5mCy/IXTSN9T83QXaqEB4rLk+Zsh44/zy0BQYBoJcFgPNC6/w4R8muZ+S59uC5qWZSFM5aoMXBbWw==";

    #[test]
    fn public_keys_are_checked() {
        let k = SoftKey::random();
        assert!(parse_public(&k.public_b64()).is_ok());
        let mut raw = BASE64.decode(k.public_b64().as_bytes()).unwrap();
        // Compressed form, wrong length, a point off the curve.
        assert!(parse_public(&BASE64.encode(&raw[..33])).is_err());
        raw[0] = 0x02;
        assert!(parse_public(&BASE64.encode(&raw)).is_err());
        raw[0] = 0x04;
        raw[64] ^= 1;
        assert!(parse_public(&BASE64.encode(&raw)).is_err());
        assert!(parse_public("not base64").is_err());
    }

    /// Negative control (run once, 2026-10-06): without the bind comparison in `take`, the challenge issued to another
    /// process was accepted.
    #[test]
    fn a_challenge_is_used_once_by_its_own_client_while_fresh() {
        let mut s = ProofState::default();
        let (n, exp) = s.issue(bind(1), 1_000, CHALLENGE_TTL_MS, false);
        assert_eq!(exp, 1_000 + CHALLENGE_TTL_MS);
        let hex = HEXLOWER.encode(&n);
        assert_eq!(s.take(&hex, &bind(1), 2_000, false).unwrap(), n);
        // Replayed.
        assert_eq!(
            s.take(&hex, &bind(1), 2_000, false).unwrap_err().code,
            code::CHALLENGE_INVALID
        );
        // Another client (process, or session token); taken by the attempt all the same.
        let (n2, _) = s.issue(bind(1), 1_000, CHALLENGE_TTL_MS, false);
        let hex2 = HEXLOWER.encode(&n2);
        assert_eq!(
            s.take(&hex2, &bind(2), 2_000, false).unwrap_err().code,
            code::CHALLENGE_INVALID
        );
        assert_eq!(
            s.take(&hex2, &bind(1), 2_000, false).unwrap_err().code,
            code::CHALLENGE_INVALID
        );
        let (n3, _) = s.issue(bind(1), 1_000, CHALLENGE_TTL_MS, false);
        let with_session = Bind {
            session: Some([1; 32]),
            ..bind(1)
        };
        assert!(
            s.take(&HEXLOWER.encode(&n3), &with_session, 2_000, false)
                .is_err()
        );
        // Expired.
        let (n4, exp4) = s.issue(bind(1), 1_000, CHALLENGE_TTL_MS, false);
        assert!(
            s.take(&HEXLOWER.encode(&n4), &bind(1), exp4, false)
                .is_err()
        );
        // Never issued, malformed.
        assert!(
            s.take(&HEXLOWER.encode(&[0u8; 32]), &bind(1), 2_000, false)
                .is_err()
        );
        assert!(s.take("zz", &bind(1), 2_000, false).is_err());
        // At most 16 outstanding: the oldest is pushed out.
        let first = s.issue(bind(1), 3_000, CHALLENGE_TTL_MS, false).0;
        for _ in 0..CHALLENGES_MAX {
            s.issue(bind(1), 3_000, CHALLENGE_TTL_MS, false);
        }
        assert!(
            s.take(&HEXLOWER.encode(&first), &bind(1), 3_001, false)
                .is_err()
        );
        // A challenge for enrolling is good only for enrolling, and a plain one never for it
        let (ne, _) = s.issue(bind(1), 3_000, CHALLENGE_TTL_MS, true);
        assert!(
            s.take(&HEXLOWER.encode(&ne), &bind(1), 3_001, false)
                .is_err()
        );
        let (ne, _) = s.issue(bind(1), 3_000, CHALLENGE_TTL_MS, true);
        assert!(s.take(&HEXLOWER.encode(&ne), &bind(1), 3_001, true).is_ok());
        let (np, _) = s.issue(bind(1), 3_000, CHALLENGE_TTL_MS, false);
        assert!(
            s.take(&HEXLOWER.encode(&np), &bind(1), 3_001, true)
                .is_err()
        );
        let (n5, _) = s.issue(bind(1), 3_000, CHALLENGE_TTL_MS, false);
        s.clear();
        assert!(
            s.take(&HEXLOWER.encode(&n5), &bind(1), 3_001, false)
                .is_err()
        );
    }

    #[test]
    fn labels_and_the_password_clock() {
        assert_eq!(
            label("  This Mac (Touch ID) ").unwrap(),
            "This Mac (Touch ID)"
        );
        assert!(label("").is_err());
        assert!(label("a\nb").is_err());
        assert!(label(&"x".repeat(65)).is_err());
        assert_eq!(password_due_ms(None, PASSWORD_EVERY_MS), 0);
        assert_eq!(
            password_due_ms(Some(10), PASSWORD_EVERY_MS),
            10 + PASSWORD_EVERY_MS
        );
    }

    #[test]
    fn debug_builds_trust_the_test_key_only_when_asked() {
        // The variable is not set in the test environment (CleanEnv-style harnesses drop it too).
        if std::env::var(test_key::ENV).is_err() {
            assert!(!test_key_accepted());
        }
    }
}
