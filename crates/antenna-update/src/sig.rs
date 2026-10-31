// SPDX-License-Identifier: AGPL-3.0-only
//! The detached signature `antenna-<version>-manifest.json.sig` (`docs/UPDATES.md` §3).
//!
//! Ed25519 (RFC 8032, `ed25519-dalek`, verified with `verify_strict`) over `"antenna/release-manifest/v1" ‖ 0x00 ‖
//! <the manifest file bytes>`. The context keeps a release signature from being valid as anything else the same key
//! could ever sign. The file holds a list of signatures, so a release can carry the signatures of several keys
//! (rotation, and the two independent keys of SPEC §13).

use data_encoding::BASE64;
use ed25519_dalek::{Signature, Signer, SigningKey};
use serde::{Deserialize, Serialize};

use crate::{
    Error, Result, code, is_hex,
    keys::{KeySet, REQUIRED_SIGNATURES, key_id},
};

/// `format` of the signature file.
pub const FORMAT: &str = "antenna-release-signature/1";
/// Domain-separation context of a release signature.
pub const CONTEXT: &[u8] = b"antenna/release-manifest/v1";
/// Largest signature file accepted.
pub const MAX_BYTES: usize = 16 * 1024;
/// Most signatures in one file.
pub const MAX_SIGNATURES: usize = 16;

/// The signature file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignatureFile {
    /// [`FORMAT`].
    pub format: String,
    /// Signatures over the same manifest.
    pub signatures: Vec<Entry>,
}

/// One signature.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// [`key_id`] of the signing key.
    pub key_id: String,
    /// Ed25519 signature, base64 of 64 bytes.
    pub sig: String,
}

/// The signed message: context, a zero byte, the manifest bytes.
pub fn message(manifest: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(CONTEXT.len() + 1 + manifest.len());
    m.extend_from_slice(CONTEXT);
    m.push(0);
    m.extend_from_slice(manifest);
    m
}

/// Signs manifest bytes.
pub fn sign(manifest: &[u8], key: &SigningKey) -> Entry {
    let sig = key.sign(&message(manifest));
    Entry {
        key_id: key_id(key.verifying_key().as_bytes()),
        sig: BASE64.encode(&sig.to_bytes()),
    }
}

impl SignatureFile {
    /// A file with one signature.
    pub fn new(entry: Entry) -> Self {
        Self {
            format: FORMAT.into(),
            signatures: vec![entry],
        }
    }

    /// Adds a signature (a second key signing the same manifest); replaces an earlier one by the same key.
    pub fn add(&mut self, entry: Entry) {
        self.signatures.retain(|e| e.key_id != entry.key_id);
        self.signatures.push(entry);
    }

    /// Parses the file.
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let bad = |m: String| Error::new(code::BAD_SIGNATURE, m);
        if bytes.len() > MAX_BYTES {
            return Err(bad(format!("signature file larger than {MAX_BYTES} bytes")));
        }
        let f: SignatureFile = serde_json::from_slice(bytes)
            .map_err(|e| bad(format!("signature file is not valid: {e}")))?;
        if f.format != FORMAT {
            return Err(bad(format!(
                "signature format {:?} is not supported by this version (it reads {FORMAT})",
                f.format
            )));
        }
        if f.signatures.is_empty() || f.signatures.len() > MAX_SIGNATURES {
            return Err(bad(format!(
                "a signature file has 1–{MAX_SIGNATURES} signatures"
            )));
        }
        Ok(f)
    }

    /// Bytes to publish (pretty JSON with a final newline).
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut b = serde_json::to_vec_pretty(self).expect("a signature file serializes");
        b.push(b'\n');
        b
    }
}

/// A verified signature.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verified {
    /// IDs of the pinned keys whose signatures verified.
    pub key_ids: Vec<String>,
    /// One of them is the public test key (only possible in a debug build that was asked to trust it).
    pub test_key: bool,
}

/// Verifies the signature file over the exact manifest bytes with the trusted keys.
pub fn verify(manifest: &[u8], sig_file: &[u8], keys: &KeySet) -> Result<Verified> {
    if keys.is_empty() {
        return Err(Error::new(
            code::NO_RELEASE_KEY,
            "this build has no release key pinned, so no update can be verified (it refuses all of them)",
        ));
    }
    let f = SignatureFile::parse(sig_file)?;
    let msg = message(manifest);
    let mut good: Vec<String> = Vec::new();
    let mut test_key = false;
    let mut failed: Vec<String> = Vec::new();
    let mut unknown: Vec<String> = Vec::new();
    for e in &f.signatures {
        if !is_hex(&e.key_id, 16) {
            return Err(Error::new(
                code::BAD_SIGNATURE,
                "a key_id is 16 lowercase hex characters",
            ));
        }
        let Some(k) = keys.keys.iter().find(|k| k.id == e.key_id) else {
            unknown.push(e.key_id.clone());
            continue;
        };
        let raw = BASE64
            .decode(e.sig.as_bytes())
            .ok()
            .and_then(|b| <[u8; 64]>::try_from(b.as_slice()).ok());
        let ok = raw.is_some_and(|b| {
            k.key
                .verify_strict(&msg, &Signature::from_bytes(&b))
                .is_ok()
        });
        if ok {
            if !good.contains(&k.id) {
                good.push(k.id.clone());
                test_key |= k.test;
            }
        } else {
            failed.push(k.id.clone());
        }
    }
    if good.len() >= REQUIRED_SIGNATURES {
        return Ok(Verified {
            key_ids: good,
            test_key,
        });
    }
    let msg = if !failed.is_empty() {
        format!(
            "the signature by release key {} does not match the manifest: the manifest or the signature was altered",
            failed.join(", ")
        )
    } else if good.is_empty() {
        format!(
            "the manifest is signed by key {}, which this version does not trust (it trusts {})",
            unknown.join(", "),
            keys.ids().join(", ")
        )
    } else {
        format!(
            "{} valid signature(s) from pinned keys, {REQUIRED_SIGNATURES} required",
            good.len()
        )
    };
    Err(Error::new(code::BAD_SIGNATURE, msg))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::test_signing_key;

    fn manifest() -> Vec<u8> {
        crate::manifest::tests::sample("0.1.0-preview.3").to_bytes()
    }

    #[test]
    fn valid_signature() {
        let m = manifest();
        let f = SignatureFile::new(sign(&m, &test_signing_key()));
        let v = verify(&m, &f.to_bytes(), &KeySet::test_only()).unwrap();
        assert!(v.test_key);
        assert_eq!(v.key_ids.len(), 1);
    }

    #[test]
    fn wrong_key() {
        let m = manifest();
        let other = SigningKey::from_bytes(&[9u8; 32]);
        let f = SignatureFile::new(sign(&m, &other));
        let e = verify(&m, &f.to_bytes(), &KeySet::test_only()).unwrap_err();
        assert_eq!(e.code, code::BAD_SIGNATURE);
        assert!(e.message.contains("does not trust"), "{}", e.message);
        // The same signature with a forged key_id (claiming to be the trusted key) does not verify either.
        let mut f2 = f.clone();
        f2.signatures[0].key_id = key_id(test_signing_key().verifying_key().as_bytes());
        let e = verify(&m, &f2.to_bytes(), &KeySet::test_only()).unwrap_err();
        assert!(e.message.contains("was altered"), "{}", e.message);
    }

    #[test]
    fn tampered_manifest() {
        let m = manifest();
        let f = SignatureFile::new(sign(&m, &test_signing_key()));
        let mut t = m.clone();
        // One byte: a different version.
        let pos = t.windows(9).position(|w| w == b"preview.3").unwrap();
        t[pos + 8] = b'4';
        assert_eq!(
            verify(&t, &f.to_bytes(), &KeySet::test_only())
                .unwrap_err()
                .code,
            code::BAD_SIGNATURE
        );
        // Whitespace counts too: the signature is over the bytes, not the JSON value.
        let mut ws = m.clone();
        ws.push(b'\n');
        assert!(verify(&ws, &f.to_bytes(), &KeySet::test_only()).is_err());
        // A signature without the context (plain Ed25519 over the file) is not a release signature.
        let plain = test_signing_key().sign(&m);
        let mut f3 = f.clone();
        f3.signatures[0].sig = BASE64.encode(&plain.to_bytes());
        assert!(verify(&m, &f3.to_bytes(), &KeySet::test_only()).is_err());
    }

    #[test]
    fn no_keys_fails_closed() {
        let m = manifest();
        let f = SignatureFile::new(sign(&m, &test_signing_key()));
        assert_eq!(
            verify(&m, &f.to_bytes(), &KeySet::default())
                .unwrap_err()
                .code,
            code::NO_RELEASE_KEY
        );
    }

    #[test]
    fn several_signatures_and_rotation() {
        let m = manifest();
        let old = SigningKey::from_bytes(&[1u8; 32]);
        let new = SigningKey::from_bytes(&[2u8; 32]);
        let mut f = SignatureFile::new(sign(&m, &new));
        f.add(sign(&m, &old));
        f.add(sign(&m, &old));
        assert_eq!(f.signatures.len(), 2);
        // An installation that pins only the old key accepts the release; one that pins only the new key too.
        assert!(verify(&m, &f.to_bytes(), &KeySet::of(&[old.verifying_key()])).is_ok());
        assert!(verify(&m, &f.to_bytes(), &KeySet::of(&[new.verifying_key()])).is_ok());
        let both = verify(
            &m,
            &f.to_bytes(),
            &KeySet::of(&[old.verifying_key(), new.verifying_key()]),
        )
        .unwrap();
        assert_eq!(both.key_ids.len(), 2);
        assert!(!both.test_key);
    }

    /// The test vector of `docs/UPDATES.md` appendix A (the signature was checked independently with Python
    /// `cryptography` and with `openssl pkeyutl -verify -rawin`).
    #[test]
    fn documented_vector() {
        use crate::manifest::{Asset, FORMAT, PRODUCT};
        use sha2::{Digest, Sha256};
        let content = b"test asset\n";
        assert_eq!(
            crate::hex(&Sha256::digest(content)),
            "9a87a1af731a430631c61724944994aece748e045626e75dc8956af26d97e665"
        );
        assert_eq!(
            crate::hex(blake3::hash(content).as_bytes()),
            "2638e610be653e7d589e3127f8eac7bc8e4fce9167b3a197bd4ef7c7b05ca352"
        );
        let m = crate::manifest::Manifest {
            format: FORMAT.into(),
            product: PRODUCT.into(),
            version: "1.0.0".into(),
            channel: "stable".into(),
            created: "2026-10-03T12:00:00Z".into(),
            commit: "0123456789ab".into(),
            assets: vec![Asset {
                name: "antenna-1.0.0-linux-x86_64.tar.gz".into(),
                os: "linux".into(),
                arch: "x86_64".into(),
                kind: "cli".into(),
                size: 11,
                sha256: "9a87a1af731a430631c61724944994aece748e045626e75dc8956af26d97e665".into(),
                blake3: "2638e610be653e7d589e3127f8eac7bc8e4fce9167b3a197bd4ef7c7b05ca352".into(),
            }],
            models: Vec::new(),
        };
        let bytes = m.to_bytes();
        assert_eq!(bytes.len(), 512);
        assert_eq!(
            crate::hex(&Sha256::digest(&bytes)),
            "5a5423e41cbcfe3419301ecae3efa8e26cbcd6af54729f622a41d862ef63d898"
        );
        let pk = test_signing_key().verifying_key();
        assert_eq!(
            BASE64.encode(pk.as_bytes()),
            "oDYEhCKnP+yuyAmJpBTguxGjTqOuDsKDLE/olFiV+Ds="
        );
        let e = sign(&bytes, &test_signing_key());
        assert_eq!(e.key_id, "04e28f3f8c0bb3bf");
        assert_eq!(
            e.sig,
            "eAknF5J9KwNA/BdDJ9ceX7C9OqR8ONEvFYNOUmZtkOX+FBbgQQ6Rv0xkT4I1qOV5WKKq18UiOdiwxgDa5626Dw=="
        );
    }

    #[test]
    fn malformed_signature_files() {
        let m = manifest();
        let keys = KeySet::test_only();
        for bad in [
            &b""[..],
            b"{}",
            br#"{"format":"antenna-release-signature/2","signatures":[]}"#,
            br#"{"format":"antenna-release-signature/1","signatures":[]}"#,
            br#"{"format":"antenna-release-signature/1","signatures":[{"key_id":"XYZ","sig":"AA=="}]}"#,
        ] {
            assert_eq!(verify(&m, bad, &keys).unwrap_err().code, code::BAD_SIGNATURE);
        }
        let id = key_id(test_signing_key().verifying_key().as_bytes());
        let short =
            format!(r#"{{"format":"{FORMAT}","signatures":[{{"key_id":"{id}","sig":"AAAA"}}]}}"#);
        assert_eq!(
            verify(&m, short.as_bytes(), &keys).unwrap_err().code,
            code::BAD_SIGNATURE
        );
    }
}
