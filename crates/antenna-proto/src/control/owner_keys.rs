// SPDX-License-Identifier: Apache-2.0
//! Owner keys (v7, `docs/CONTROL.md` §22, D-102, experimental): a P-256 key the owner enrolled with the password signs
//! an owner command instead of the password, one challenge and one command per signature. This module holds the wire
//! types and the exact layout of what is signed; the signature check itself is the daemon's (this crate does no
//! cryptography).
//!
//! A proof travels on the request's own line, next to it: `{"req":<R>,"proof":{key_id, nonce, sig}}`. What is signed
//! covers the exact bytes `R` the daemon parses, not a re-encoding of them, so a client and the daemon cannot disagree
//! about what was approved.

use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

use super::SecretString;

/// Domain-separation label of the signed message (`docs/CONTROL.md` §22.2).
pub const PROOF_LABEL: &[u8] = b"antenna/owner-proof/v1";
/// How long a challenge is valid, ms.
pub const CHALLENGE_TTL_MS: u64 = 60_000;
/// How many challenges may be outstanding; a newer one pushes out the oldest.
pub const CHALLENGES_MAX: usize = 16;
/// How many owner keys a node keeps.
pub const OWNER_KEYS_MAX: usize = 8;
/// Proofs and unlock slots are refused this long after the last correct password (D-102: the password is asked every
/// 14 days so that it is not forgotten), ms.
pub const PASSWORD_EVERY_MS: u64 = 14 * 24 * 60 * 60 * 1000;
/// After this many failed proofs in a row, proofs are refused until a correct password.
pub const PROOF_FAILS_MAX: u32 = 3;
/// Length of an owner key's label, bytes.
pub const LABEL_MAX: usize = 64;
/// Length of an uncompressed P-256 public key (X9.62: `0x04 ‖ X ‖ Y`).
pub const PUBLIC_KEY_LEN: usize = 65;
/// Length of a fixed-size P-256 signature (`r ‖ s`).
pub const SIGNATURE_LEN: usize = 64;

/// The proof next to a request: an enrolled key's signature over a challenge and the request's bytes.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OwnerProof {
    /// The signing key ([`OwnerKeyInfo::key_id`]).
    pub key_id: String,
    /// The challenge's nonce, 64 hex characters (`owner_challenge`).
    pub nonce: String,
    /// The signature, base64 of 64 bytes `r ‖ s`.
    pub sig: String,
}

impl std::fmt::Debug for OwnerProof {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OwnerProof")
            .field("key_id", &self.key_id)
            .finish_non_exhaustive()
    }
}

/// A line that carries a proof: exactly the keys `req` and `proof`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProvenLine<'a> {
    /// The request as it appears on the line, byte for byte.
    #[serde(borrow)]
    pub req: &'a RawValue,
    /// The proof.
    pub proof: OwnerProof,
}

/// Top-level keys of a line, values unparsed: enough to see whether it carries a proof.
#[derive(Deserialize)]
struct LineKeys<'a> {
    #[serde(borrow, default)]
    proof: Option<&'a RawValue>,
}

impl<'a> ProvenLine<'a> {
    /// The line's proof and request bytes, when the line carries a `proof` key: `None` for an ordinary line (or one
    /// that is not JSON, which the ordinary parser reports); `Some(Err)` for a proof line that is malformed.
    pub fn parse(line: &'a str) -> Option<Result<Self, serde_json::Error>> {
        let keys: LineKeys<'a> = serde_json::from_str(line).ok()?;
        keys.proof?;
        Some(serde_json::from_str(line))
    }

    /// The exact bytes of the request that the signature covers (`R` in `docs/CONTROL.md` §22.2).
    pub fn req_bytes(&self) -> &'a [u8] {
        self.req.get().as_bytes()
    }
}

/// The signed message: `PROOF_LABEL ‖ 0x00 ‖ nonce ‖ request_hash`, where `request_hash` is SHA-256 of the request's
/// bytes ([`ProvenLine::req_bytes`]). Fixed-length fields after the label, so the encoding is unambiguous.
pub fn proof_message(nonce: &[u8; 32], request_hash: &[u8; 32]) -> Vec<u8> {
    let mut m = Vec::with_capacity(PROOF_LABEL.len() + 1 + 64);
    m.extend_from_slice(PROOF_LABEL);
    m.push(0);
    m.extend_from_slice(nonce);
    m.extend_from_slice(request_hash);
    m
}

/// `owner_challenge` reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnerChallenge {
    /// 32 random bytes, hex.
    pub nonce: String,
    /// When the challenge expires (unix ms).
    pub expires_ms: u64,
    /// After this moment proofs are refused until the password is used again (unix ms).
    pub password_due_ms: u64,
}

/// An enrolled owner key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnerKeyInfo {
    /// The first 8 bytes of SHA-256 of the 65-byte public key, hex.
    pub key_id: String,
    /// The owner's label ("This Mac (Touch ID)").
    pub label: String,
    /// When it was enrolled (unix ms).
    pub created_ms: u64,
    /// When it last signed a command that verified (unix ms).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_ms: Option<u64>,
    /// It has an unlock slot (`unlock {key_id, slot_key}`).
    pub unlock: bool,
}

/// `owner_key_list` reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnerKeys {
    /// The keys, oldest first.
    pub keys: Vec<OwnerKeyInfo>,
    /// After this moment proofs and unlock slots are refused until the password is used again (unix ms).
    pub password_due_ms: u64,
    /// This build accepts the public test key (only a debug build with `ANTENNA_OWNER_TEST_KEY=1`).
    pub test_key: bool,
}

/// `owner_key_add` reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnerKeyAdded {
    /// The new key.
    pub key: OwnerKeyInfo,
    /// The unlock slot's key, base64 of 32 bytes, shown once (only with `unlock: true`): the window seals it to its
    /// Secure Enclave key and drops it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slot_key: Option<SecretString>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_proof_line_keeps_the_request_bytes() {
        let line = r#"{"req":{"cmd":"approve","id":"k2", "password":""},"proof":{"key_id":"a1","nonce":"00","sig":"AA=="}}"#;
        let p = ProvenLine::parse(line).unwrap().unwrap();
        // Byte for byte, including the space a client put in: the signature covers what was sent.
        assert_eq!(
            p.req_bytes(),
            br#"{"cmd":"approve","id":"k2", "password":""}"#
        );
        assert_eq!(p.proof.key_id, "a1");
        assert!(!format!("{:?}", p.proof).contains("AA=="));
        // Order of the keys does not matter.
        let line2 = r#"{"proof":{"key_id":"a1","nonce":"00","sig":"AA=="},"req":{"cmd":"lock"}}"#;
        assert_eq!(
            ProvenLine::parse(line2).unwrap().unwrap().req_bytes(),
            br#"{"cmd":"lock"}"#
        );
    }

    #[test]
    fn ordinary_and_malformed_lines() {
        // No proof: the ordinary parser takes it.
        assert!(ProvenLine::parse(r#"{"req":{"cmd":"lock"}}"#).is_none());
        assert!(ProvenLine::parse("not json").is_none());
        // A proof in the text of a message is not a proof.
        assert!(ProvenLine::parse(r#"{"req":{"cmd":"send","text":"\"proof\":1"}}"#).is_none());
        // A proof line with anything else, or a malformed proof, is refused.
        for bad in [
            r#"{"req":{"cmd":"lock"},"proof":{"key_id":"a","nonce":"b","sig":"c"},"x":1}"#,
            r#"{"req":{"cmd":"lock"},"proof":{"key_id":"a","nonce":"b"}}"#,
            r#"{"req":{"cmd":"lock"},"proof":{"key_id":"a","nonce":"b","sig":"c","extra":1}}"#,
            r#"{"proof":{"key_id":"a","nonce":"b","sig":"c"}}"#,
        ] {
            assert!(ProvenLine::parse(bad).unwrap().is_err(), "{bad}");
        }
    }

    #[test]
    fn the_signed_message_layout() {
        let m = proof_message(&[1; 32], &[2; 32]);
        assert_eq!(&m[..22], b"antenna/owner-proof/v1");
        assert_eq!(m[22], 0);
        assert_eq!(&m[23..55], &[1; 32]);
        assert_eq!(&m[55..], &[2; 32]);
        assert_eq!(m.len(), 87);
    }

    #[test]
    fn slot_key_is_not_in_debug() {
        let r = OwnerKeyAdded {
            key: OwnerKeyInfo {
                key_id: "01b3e9c533123cb8".into(),
                label: "Mac".into(),
                created_ms: 1,
                last_used_ms: None,
                unlock: true,
            },
            slot_key: Some(SecretString("c2VjcmV0".into())),
        };
        assert!(!format!("{r:?}").contains("c2VjcmV0"));
        assert!(serde_json::to_string(&r).unwrap().contains("c2VjcmV0"));
    }
}
