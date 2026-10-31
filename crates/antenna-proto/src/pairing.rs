// SPDX-License-Identifier: Apache-2.0
//! Pairing v0 messages (`docs/PROTOCOL.md` §6) and protocol constants (§5, §7).
//!
//! Formats and domain-separation labels only. The computations (HKDF, HMAC, SHA-256) are in the core.

use serde::{Deserialize, Serialize};

/// ALPN of the invite's ephemeral endpoint.
pub const ALPN_PAIR: &[u8] = b"x/pair/0";
/// TLS exporter label for channel binding.
pub const EXPORTER_LABEL: &[u8] = b"EXPORTER-x-pair-v0";
/// The only TLS key exchange group allowed for pairing.
pub const KX_GROUP: &str = "X25519MLKEM768";
/// Algorithm suite (part of the transcript; there are no legacy modes).
pub const SUITE: &str = "x-pair/1;tls13:X25519MLKEM768;kdf:HKDF-SHA256;mac:HMAC-SHA256;hash:SHA-256;sig:Ed25519+ML-DSA-65;e2e:libsignal-PQXDH-MLKEM1024+SPQR";
/// Maximum pairing frame size.
pub const MAX_FRAME: usize = 64 * 1024;
/// How many failed attempts (wrong secret and the like) an invite tolerates.
pub const MAX_ATTEMPTS: u32 = 5;
/// Number of SAS digits.
pub const SAS_DIGITS: usize = 6;

/// QUIC close code: a non-post-quantum TLS group was negotiated.
pub const CLOSE_NOT_PQ: u32 = 2;

/// Domain-separation labels (`docs/PROTOCOL.md` §7). All are ASCII without a terminating NUL.
pub mod label {
    /// HKDF salt of the PSK-MAC key.
    pub const PSK_SALT: &[u8] = b"x/pair/v0/psk-salt";
    /// HKDF info of the PSK-MAC key.
    pub const PSK_KEY: &[u8] = b"x/pair/v0/psk-mac-key";
    /// Prefix of the PSK-MAC message.
    /// v1 (F-3): the MAC covers the whole M1 body, hence the new label: v0 and v1 formats do not mix.
    pub const PSK_PROOF: &[u8] = b"x/pair/v1/psk-proof";
    /// Commitment prefix.
    pub const COMMIT: &[u8] = b"x/pair/v0/commit";
    /// Transcript hash prefix.
    pub const TRANSCRIPT: &[u8] = b"x/pair/v0/transcript";
    /// HKDF-Extract salt for the PRK.
    pub const PRK: &[u8] = b"x/pair/v0/prk";
    /// Info of role A's key.
    pub const KEY_A: &[u8] = b"x/pair/v0/key/A";
    /// Info of role B's key.
    pub const KEY_B: &[u8] = b"x/pair/v0/key/B";
    /// Info of link_id.
    pub const LINK_ID: &[u8] = b"x/pair/v0/link-id";
    /// Key confirmation prefix.
    pub const KEY_CONFIRM: &[u8] = b"x/pair/v0/key-confirm";
    /// Prefix of "owner B entered the correct code".
    pub const CODE_ENTERED: &[u8] = b"x/pair/v0/code-entered";
    /// Prefix of "owner A confirmed".
    pub const OWNER_CONFIRMED: &[u8] = b"x/pair/v0/owner-confirmed";
    /// HKDF salt of the SAS.
    pub const SAS_SALT: &[u8] = b"x/pair/v0/sas-salt";
    /// HKDF info of the SAS.
    pub const SAS_INFO: &[u8] = b"x/pair/v0/sas-digits";
    /// Plaintext of the first ratchet message (B → A), followed by TH.
    pub const SESSION_INIT: &[u8] = b"x/pair/v0/session-init";
    /// Plaintext of the ratchet reply (A → B), followed by TH.
    pub const SESSION_ACK: &[u8] = b"x/pair/v0/session-ack";
}

/// Allowed abort reasons (`docs/PROTOCOL.md` §6). Foreign strings are never shown to a person as is.
pub const ABORT_REASONS: &[&str] = &[
    "version",
    "suite",
    "auth",
    "commit",
    "key_confirm",
    "sas_mismatch",
    "owner_rejected",
    "timeout",
    "protocol",
    "busy",
    "internal",
];

/// Maximum number of direct addresses in the hints.
pub const MAX_DIRECT_ADDRS: usize = 16;

/// Route hints to the pairwise endpoint (not part of the transcript).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AddrHints {
    /// Relay URL, if any.
    pub relay: Option<String>,
    /// Direct `ip:port` addresses; empty in "relay only" mode.
    pub direct: Vec<String>,
}

/// A side's public data that is part of the transcript (except `addrs`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Party {
    /// libsignal `IdentityKey` of this link, 33 bytes.
    #[serde(with = "serde_bytes")]
    pub identity_key: Vec<u8>,
    /// Link-root: Ed25519, 32 bytes.
    #[serde(with = "serde_bytes")]
    pub root_ed25519: [u8; 32],
    /// Link-root: ML-DSA-65 (verification key), 1952 bytes.
    #[serde(with = "serde_bytes")]
    pub root_mldsa65: Vec<u8>,
    /// EndpointId of the future pairwise endpoint.
    #[serde(with = "serde_bytes")]
    pub endpoint: [u8; 32],
    /// Route hints.
    pub addrs: AddrHints,
}

/// Length of a libsignal `IdentityKey`.
pub const IDENTITY_KEY_LEN: usize = 33;
/// Length of an ML-DSA-65 verification key.
pub const MLDSA65_VK_LEN: usize = 1952;

impl AddrHints {
    /// Size check (relay ≤ 512 characters, ≤ 16 addresses of ≤ 64 characters each).
    pub fn check(&self) -> bool {
        self.relay.as_ref().is_none_or(|r| r.len() <= 512)
            && self.direct.len() <= MAX_DIRECT_ADDRS
            && self.direct.iter().all(|d| d.len() <= 64)
    }
}

impl Party {
    /// Field length check (point validity is checked by the core).
    pub fn check_lengths(&self) -> bool {
        self.identity_key.len() == IDENTITY_KEY_LEN
            && self.root_mldsa65.len() == MLDSA65_VK_LEN
            && self.addrs.check()
    }
}

/// libsignal prekey bundle of side A.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bundle {
    /// Registration id.
    pub registration_id: u32,
    /// IdentityKey (must match `Party::identity_key` from the transcript).
    #[serde(with = "serde_bytes")]
    pub identity_key: Vec<u8>,
    /// ID of the one-time prekey.
    pub prekey_id: u32,
    /// One-time prekey (X25519).
    #[serde(with = "serde_bytes")]
    pub prekey: Vec<u8>,
    /// ID signed prekey.
    pub signed_prekey_id: u32,
    /// Signed prekey (X25519).
    #[serde(with = "serde_bytes")]
    pub signed_prekey: Vec<u8>,
    /// Signature of the signed prekey by the identity key.
    #[serde(with = "serde_bytes")]
    pub signed_prekey_sig: Vec<u8>,
    /// ID KEM prekey.
    pub kyber_prekey_id: u32,
    /// KEM prekey (ML-KEM-1024).
    #[serde(with = "serde_bytes")]
    pub kyber_prekey: Vec<u8>,
    /// Signature of the KEM prekey by the identity key.
    #[serde(with = "serde_bytes")]
    pub kyber_prekey_sig: Vec<u8>,
}

impl Bundle {
    /// Length check of the bundle fields (X25519 33 B, signatures 64 B, ML-KEM-1024 1569 B).
    pub fn check_lengths(&self) -> bool {
        self.identity_key.len() == IDENTITY_KEY_LEN
            && self.prekey.len() == 33
            && self.signed_prekey.len() == 33
            && self.signed_prekey_sig.len() == 64
            && self.kyber_prekey.len() == 1569
            && self.kyber_prekey_sig.len() == 64
    }
}

/// 32 bytes as a CBOR bstr.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct B32(#[serde(with = "serde_bytes")] pub [u8; 32]);

/// Pairing message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum PairMsg {
    /// M1, B → A.
    Join {
        /// Protocol version.
        v: u16,
        /// Algorithm suite.
        suite: String,
        /// Proof of knowledge of the link secret.
        psk_mac: B32,
        /// Commitment `C_B`.
        commit: B32,
        /// `P_B`.
        party: Party,
    },
    /// M2, A → B.
    Offer {
        /// `P_A`.
        party: Party,
        /// `N_A`.
        nonce: B32,
    },
    /// M3, B → A.
    Reveal {
        /// `N_B`.
        nonce: B32,
        /// `kc_B`.
        kc: B32,
    },
    /// M4, A → B.
    KeyConfirm {
        /// `kc_A`.
        kc: B32,
    },
    /// M5, B → A: owner B entered the correct code.
    CodeEntered {
        /// `mac_B`.
        mac: B32,
    },
    /// M6, A → B: owner A confirmed.
    Confirmed {
        /// `mac_A`.
        mac: B32,
        /// A's bundle.
        bundle: Bundle,
    },
    /// M7, B → A: PreKeySignalMessage.
    SessionInit {
        /// libsignal ciphertext.
        #[serde(with = "serde_bytes")]
        ct: Vec<u8>,
    },
    /// M8, A → B: SignalMessage.
    Done {
        /// libsignal ciphertext.
        #[serde(with = "serde_bytes")]
        ct: Vec<u8>,
    },
    /// Abort by either side.
    Abort {
        /// Reason (`docs/PROTOCOL.md` §6).
        reason: String,
    },
}

impl PairMsg {
    /// Message name for diagnostics.
    pub fn name(&self) -> &'static str {
        match self {
            PairMsg::Join { .. } => "join",
            PairMsg::Offer { .. } => "offer",
            PairMsg::Reveal { .. } => "reveal",
            PairMsg::KeyConfirm { .. } => "key_confirm",
            PairMsg::CodeEntered { .. } => "code_entered",
            PairMsg::Confirmed { .. } => "confirmed",
            PairMsg::SessionInit { .. } => "session_init",
            PairMsg::Done { .. } => "done",
            PairMsg::Abort { .. } => "abort",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{from_cbor, to_cbor};

    fn party() -> Party {
        Party {
            identity_key: vec![5; 33],
            root_ed25519: [1; 32],
            root_mldsa65: vec![2; 1952],
            endpoint: [3; 32],
            addrs: AddrHints {
                relay: Some("https://r.example/".into()),
                direct: vec![],
            },
        }
    }

    #[test]
    fn messages_roundtrip() {
        let msgs = vec![
            PairMsg::Join {
                v: 0,
                suite: SUITE.into(),
                psk_mac: B32([1; 32]),
                commit: B32([2; 32]),
                party: party(),
            },
            PairMsg::Offer {
                party: party(),
                nonce: B32([4; 32]),
            },
            PairMsg::Reveal {
                nonce: B32([5; 32]),
                kc: B32([6; 32]),
            },
            PairMsg::KeyConfirm { kc: B32([7; 32]) },
            PairMsg::CodeEntered { mac: B32([8; 32]) },
            PairMsg::SessionInit { ct: vec![1, 2, 3] },
            PairMsg::Done { ct: vec![4] },
            PairMsg::Abort {
                reason: "sas_mismatch".into(),
            },
        ];
        for m in msgs {
            let b = to_cbor(&m).unwrap();
            assert!(b.len() < MAX_FRAME);
            let back: PairMsg = from_cbor(&b).unwrap();
            assert_eq!(back, m);
        }
    }

    #[test]
    fn wire_tag_is_snake_case_variant_name() {
        let b = to_cbor(&PairMsg::KeyConfirm { kc: B32([7; 32]) }).unwrap();
        let v: ciborium::Value = from_cbor(&b).unwrap();
        let m = v.as_map().unwrap();
        assert_eq!(m[0].0.as_text(), Some("key_confirm"));
        assert!(party().check_lengths());
        let mut p = party();
        p.root_mldsa65.pop();
        assert!(!p.check_lengths());
    }

    #[test]
    fn labels_are_distinct() {
        use label::*;
        let all = [
            PSK_SALT,
            PSK_KEY,
            PSK_PROOF,
            COMMIT,
            TRANSCRIPT,
            PRK,
            KEY_A,
            KEY_B,
            LINK_ID,
            KEY_CONFIRM,
            CODE_ENTERED,
            OWNER_CONFIRMED,
            SAS_SALT,
            SAS_INFO,
            SESSION_INIT,
            SESSION_ACK,
        ];
        let set: std::collections::HashSet<_> = all.iter().collect();
        assert_eq!(set.len(), all.len());
        // No label is a prefix of another (otherwise concatenations could collide).
        for a in all {
            for b in all {
                if a != b {
                    assert!(!b.starts_with(a), "{:?} prefix of {:?}", a, b);
                }
            }
        }
    }
}
