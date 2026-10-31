// SPDX-License-Identifier: AGPL-3.0-only
//! Release keys pinned in the binary (SPEC §13: "the release signing key is built into the binary").
//!
//! The list allows rotation: a release may be signed by any key listed here; a new key is added in one release and the
//! old one is removed in a later one, once every installation that matters has the new list (`docs/UPDATES.md` §4).
//!
//! The test key signs the test fixtures. Its seed is public (it is in this file), so it must never be trusted by a
//! build that people run: only debug builds compile the code that accepts it, and only when the environment variable
//! [`test_key::ENV`] is `1`. Release builds (`cargo build --release`, which turns off `debug_assertions`) do not contain
//! that branch at all, and `packaging/linux/check-install.sh` checks that the release binary refuses a test-signed
//! update.

use data_encoding::BASE64;
use ed25519_dalek::{SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::{Error, Result, code, hex};

/// A release key pinned in the binary.
#[derive(Debug, Clone, Copy)]
pub struct PinnedKey {
    /// Key ID: [`key_id`] of the public key (16 hex characters).
    pub id: &'static str,
    /// Ed25519 public key, base64 of 32 bytes.
    pub public: &'static str,
    /// When the key was added (ISO date), for the rotation record.
    pub added: &'static str,
}

/// The release keys this version trusts (`docs/UPDATES.md` §5). An empty list makes `antenna update` refuse every
/// update with `no_release_key`: it fails closed.
pub const RELEASE_KEYS: &[PinnedKey] = &[
    // preview channel key, generated on the build server
    PinnedKey {
        id: "087121c3cde5676e",
        public: "qAtfws8ELvLdb2PH/x0OhFOqbM0hdEZm41CiDS5nsNU=",
        added: "2026-10-03",
    },
];

/// How many distinct pinned keys must have signed a manifest. SPEC §13 asks for two independent keys per release; the
/// signature file already carries several signatures, and raising this number is the whole change once a second key
/// exists (D-82).
pub const REQUIRED_SIGNATURES: usize = 1;

/// The public test key (its seed is in this file).
pub mod test_key {
    /// Seed of the test key. Public on purpose: it signs test fixtures only.
    pub const SEED: [u8; 32] = *b"antenna-update public TEST key!!";
    /// Debug builds accept the test key only when this variable is `1`.
    pub const ENV: &str = "ANTENNA_UPDATE_TEST_KEY";
}

/// Key ID: the first 8 bytes of SHA-256 of the public key, hex.
pub fn key_id(public: &[u8; 32]) -> String {
    hex(&Sha256::digest(public)[..8])
}

/// The test key as a signing key (for fixtures and tests).
pub fn test_signing_key() -> SigningKey {
    SigningKey::from_bytes(&test_key::SEED)
}

/// A key the verifier trusts.
#[derive(Debug, Clone)]
pub struct TrustedKey {
    /// Key ID.
    pub id: String,
    /// Public key.
    pub key: VerifyingKey,
    /// This is the public test key.
    pub test: bool,
}

/// The set of keys a verification trusts.
#[derive(Debug, Clone, Default)]
pub struct KeySet {
    /// Keys.
    pub keys: Vec<TrustedKey>,
}

/// Parses a base64 Ed25519 public key.
pub fn parse_public(b64: &str) -> Result<[u8; 32]> {
    let raw = BASE64
        .decode(b64.trim().as_bytes())
        .map_err(|e| Error::new(code::BAD_SIGNATURE, format!("bad public key: {e}")))?;
    let raw: [u8; 32] = raw
        .as_slice()
        .try_into()
        .map_err(|_| Error::new(code::BAD_SIGNATURE, "a public key is 32 bytes"))?;
    VerifyingKey::from_bytes(&raw)
        .map_err(|_| Error::new(code::BAD_SIGNATURE, "not a valid Ed25519 public key"))?;
    Ok(raw)
}

impl KeySet {
    /// The keys pinned in this binary; in a debug build, plus the test key when [`test_key::ENV`] is `1`.
    pub fn pinned() -> Self {
        let s = Self::from_pinned(RELEASE_KEYS);
        // Compiled into debug builds only: a release build has no way to trust the test key.
        #[cfg(debug_assertions)]
        let s = {
            let mut s = s;
            if std::env::var(test_key::ENV).as_deref() == Ok("1") {
                s.add_test_key();
            }
            s
        };
        s
    }

    /// Keys from a pinned list. A malformed entry, or the public test key put into the list by mistake, is skipped (a
    /// unit test keeps the real list clean).
    pub fn from_pinned(list: &[PinnedKey]) -> Self {
        let test = test_signing_key().verifying_key();
        let keys = list
            .iter()
            .filter_map(|k| {
                let raw = parse_public(k.public).ok()?;
                let key = VerifyingKey::from_bytes(&raw).ok()?;
                (key != test && key_id(&raw) == k.id).then(|| TrustedKey {
                    id: k.id.to_string(),
                    key,
                    test: false,
                })
            })
            .collect();
        Self { keys }
    }

    /// Adds the public test key (tests and fixtures).
    pub fn add_test_key(&mut self) {
        let key = test_signing_key().verifying_key();
        let id = key_id(key.as_bytes());
        if !self.keys.iter().any(|k| k.id == id) {
            self.keys.push(TrustedKey {
                id,
                key,
                test: true,
            });
        }
    }

    /// Only the test key (unit tests).
    pub fn test_only() -> Self {
        let mut s = Self::default();
        s.add_test_key();
        s
    }

    /// A set with the given public keys (tests).
    pub fn of(keys: &[VerifyingKey]) -> Self {
        Self {
            keys: keys
                .iter()
                .map(|k| TrustedKey {
                    id: key_id(k.as_bytes()),
                    key: *k,
                    test: false,
                })
                .collect(),
        }
    }

    /// A set with public keys given as base64 (`antenna-release verify --public`).
    pub fn from_base64(keys: &[String]) -> Result<Self> {
        let mut v = Vec::new();
        for k in keys {
            let raw = parse_public(k)?;
            v.push(
                VerifyingKey::from_bytes(&raw).map_err(|_| {
                    Error::new(code::BAD_SIGNATURE, "not a valid Ed25519 public key")
                })?,
            );
        }
        Ok(Self::of(&v))
    }

    /// Whether no key is trusted.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// IDs of the trusted keys.
    pub fn ids(&self) -> Vec<String> {
        self.keys.iter().map(|k| k.id.clone()).collect()
    }

    /// Whether the test key is in the set.
    pub fn has_test_key(&self) -> bool {
        self.keys.iter().any(|k| k.test)
    }
}

/// The line to paste into [`RELEASE_KEYS`] for a new public key.
pub fn pin_line(public: &[u8; 32], added: &str) -> String {
    format!(
        "    PinnedKey {{ id: \"{}\", public: \"{}\", added: \"{added}\" }},",
        key_id(public),
        BASE64.encode(public)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pinned_list_is_clean() {
        // Every pinned entry parses, its ID matches its key, and the public test key is not among them.
        let test = test_signing_key().verifying_key();
        for k in RELEASE_KEYS {
            let raw = parse_public(k.public).unwrap();
            assert_eq!(key_id(&raw), k.id, "pinned key {} has a wrong id", k.public);
            assert_ne!(
                VerifyingKey::from_bytes(&raw).unwrap(),
                test,
                "the test key must never be pinned"
            );
            assert_eq!(k.added.len(), 10, "added is an ISO date");
        }
        assert_eq!(
            KeySet::from_pinned(RELEASE_KEYS).keys.len(),
            RELEASE_KEYS.len()
        );
        assert!(!KeySet::from_pinned(RELEASE_KEYS).has_test_key());
        const { assert!(REQUIRED_SIGNATURES >= 1) };
    }

    #[test]
    fn the_test_key_is_not_accepted_from_a_pinned_list() {
        let pk = test_signing_key().verifying_key().to_bytes();
        let id = key_id(&pk);
        let b64 = BASE64.encode(&pk);
        let leaked = [PinnedKey {
            id: Box::leak(id.into_boxed_str()),
            public: Box::leak(b64.into_boxed_str()),
            added: "2026-10-03",
        }];
        assert!(KeySet::from_pinned(&leaked).is_empty());
    }

    #[test]
    fn a_wrong_id_or_a_bad_key_is_skipped() {
        let k = SigningKey::from_bytes(&[7u8; 32])
            .verifying_key()
            .to_bytes();
        let b64: &'static str = Box::leak(BASE64.encode(&k).into_boxed_str());
        let good: &'static str = Box::leak(key_id(&k).into_boxed_str());
        let list = [
            PinnedKey {
                id: good,
                public: b64,
                added: "2026-10-03",
            },
            PinnedKey {
                id: "0000000000000000",
                public: b64,
                added: "2026-10-03",
            },
            PinnedKey {
                id: good,
                public: "not base64",
                added: "2026-10-03",
            },
        ];
        let s = KeySet::from_pinned(&list);
        assert_eq!(s.ids(), vec![good.to_string()]);
        assert!(pin_line(&k, "2026-10-03").contains(good));
    }

    #[test]
    fn test_key_only_by_request_in_debug_builds() {
        // Without the variable a debug build does not trust the test key either.
        if std::env::var(test_key::ENV).as_deref() != Ok("1") {
            assert!(!KeySet::pinned().has_test_key());
        }
        assert!(KeySet::test_only().has_test_key());
    }
}
