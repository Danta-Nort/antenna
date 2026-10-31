// SPDX-License-Identifier: AGPL-3.0-only
//! File manifest (SPEC §10, pipeline step 1): name, type by content, size, BLAKE3 of the plaintext, the sender's check
//! result, signed with the link key before the transfer. The download decision and the level's limits are applied from
//! the manifest while the recipient does not have the file yet.
//!
//! The manifest is a hint (SPEC §10 "Why the check is not on the sender's side"): the recipient checks the file itself
//! anyway. The signature exists so the manifest cannot be swapped in transit and stays evidence in the history.
//!
//! The signature is Ed25519 with context (SPEC §7 "Signature with context"):
//! `msg = "x/file-manifest/v0" ‖ 0x00 ‖ link_id (32) ‖ recipient key (32) ‖ body`, where `body` is exactly the CBOR
//! bytes that were sent (no canonicalization needed, as with the message envelope, DECISIONS D-19).
//!
//! The types are the protocol format in `antenna_proto::files` (Apache-2.0); this module holds field validation,
//! signing and signature verification ([`ManifestExt`], [`SignedManifestExt`]). In the daemon the signing key is the
//! side's link-root Ed25519 key (the same one that signs messages).

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};

use crate::codec::{from_cbor, to_cbor};
use crate::crypt::ciphertext_len;
use crate::error::{Error, Result, code};

pub use antenna_proto::files::{
    FileOffer, MANIFEST_SIG_CONTEXT as SIG_CONTEXT, MANIFEST_VERSION, MAX_MANIFEST as MAX_BODY,
    Manifest, SenderCheck, SignedManifest,
};

/// Name length limit in the manifest (UTF-8 bytes; normalization happens at acceptance).
pub const MAX_NAME: usize = 1024;

/// Who signs the manifest. In stage A, a test key; in stage B, the link's link-root Ed25519 key (daemon keystore).
pub trait ManifestSigner {
    /// The author's public key.
    fn verifying_key(&self) -> [u8; 32];
    /// Signs a message.
    fn sign_bytes(&self, msg: &[u8]) -> [u8; 64];
}

impl ManifestSigner for SigningKey {
    fn verifying_key(&self) -> [u8; 32] {
        SigningKey::verifying_key(self).to_bytes()
    }
    fn sign_bytes(&self, msg: &[u8]) -> [u8; 64] {
        self.sign(msg).to_bytes()
    }
}

fn signed_message(link_id: &[u8; 32], recipient: &[u8; 32], body: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(SIG_CONTEXT.len() + 1 + 64 + body.len());
    m.extend_from_slice(SIG_CONTEXT);
    m.push(0);
    m.extend_from_slice(link_id);
    m.extend_from_slice(recipient);
    m.extend_from_slice(body);
    m
}

fn bad(msg: impl Into<String>) -> Error {
    Error::new(code::BAD_MANIFEST, msg)
}

/// Manifest field validation.
pub trait ManifestExt {
    /// Validates the fields (at the recipient after the signature check and at the sender before signing).
    fn validate(&self) -> Result<()>;
}

impl ManifestExt for Manifest {
    fn validate(&self) -> Result<()> {
        if self.v != MANIFEST_VERSION {
            return Err(bad(format!("unsupported manifest version {}", self.v)));
        }
        if self.name.is_empty() || self.name.len() > MAX_NAME {
            return Err(bad("name length"));
        }
        // Only the clearly dangerous is rejected here (control, tag and bidi characters); the rest is handled by name
        // normalization at acceptance, which can also rename (emoji with ZWJ must not reject the whole file).
        if self
            .name
            .chars()
            .any(|c| c.is_control() || crate::text::is_smuggling(c))
        {
            return Err(bad("name has control, tag or bidi characters"));
        }
        if self.mime.is_empty()
            || self.mime.len() > 128
            || !self.mime.bytes().all(|b| b.is_ascii_graphic())
        {
            return Err(bad("mime"));
        }
        if self.blob_size != ciphertext_len(self.size) {
            return Err(bad("blob size does not match the plaintext size"));
        }
        if self.sender_check.findings.len() > 64
            || self
                .sender_check
                .findings
                .iter()
                .any(|f| f.is_empty() || f.len() > 64 || !f.bytes().all(|b| b.is_ascii_graphic()))
        {
            return Err(bad("sender findings"));
        }
        Ok(())
    }
}

/// Manifest signing and signature verification.
pub trait SignedManifestExt: Sized {
    /// Signs the manifest for link `link_id` and recipient `recipient`.
    fn seal(
        m: &Manifest,
        signer: &impl ManifestSigner,
        link_id: &[u8; 32],
        recipient: &[u8; 32],
    ) -> Result<Self>;
    /// Verifies the author's signature with the link context and parses the manifest.
    fn open(&self, author: &[u8; 32], link_id: &[u8; 32], recipient: &[u8; 32])
    -> Result<Manifest>;
}

impl SignedManifestExt for SignedManifest {
    fn seal(
        m: &Manifest,
        signer: &impl ManifestSigner,
        link_id: &[u8; 32],
        recipient: &[u8; 32],
    ) -> Result<Self> {
        m.validate()?;
        let body = to_cbor(m)?;
        if body.len() > MAX_BODY {
            return Err(bad("manifest too large"));
        }
        let sig = signer.sign_bytes(&signed_message(link_id, recipient, &body));
        Ok(Self {
            body,
            sig: sig.to_vec(),
        })
    }

    fn open(
        &self,
        author: &[u8; 32],
        link_id: &[u8; 32],
        recipient: &[u8; 32],
    ) -> Result<Manifest> {
        if self.body.len() > MAX_BODY {
            return Err(bad("manifest too large"));
        }
        let sig: [u8; 64] = self
            .sig
            .as_slice()
            .try_into()
            .map_err(|_| bad("signature length"))?;
        let vk = VerifyingKey::from_bytes(author).map_err(|_| bad("author key"))?;
        vk.verify_strict(
            &signed_message(link_id, recipient, &self.body),
            &Signature::from_bytes(&sig),
        )
        .map_err(|_| bad("manifest signature does not verify"))?;
        let m: Manifest = from_cbor(&self.body, MAX_BODY, "manifest")?;
        m.validate()?;
        Ok(m)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypt::random_bytes;
    use crate::report::Verdict;

    fn manifest() -> Manifest {
        Manifest {
            v: 0,
            file_id: random_bytes(),
            name: "report.pdf".into(),
            mime: "application/pdf".into(),
            size: 1000,
            blake3: random_bytes(),
            blob: random_bytes(),
            blob_size: ciphertext_len(1000),
            sender_check: SenderCheck {
                verdict: Verdict::Clean,
                findings: vec![],
            },
            created_ms: 1,
        }
    }

    #[test]
    fn signature_binds_link_recipient_and_body() {
        let k = SigningKey::from_bytes(&random_bytes());
        let author = ManifestSigner::verifying_key(&k);
        let (link, rcpt) = (random_bytes::<32>(), random_bytes::<32>());
        let m = manifest();
        let s = SignedManifest::seal(&m, &k, &link, &rcpt).unwrap();
        assert_eq!(s.open(&author, &link, &rcpt).unwrap(), m);
        // Another link, another recipient, another author: rejected.
        assert!(s.open(&author, &random_bytes(), &rcpt).is_err());
        assert!(s.open(&author, &link, &random_bytes()).is_err());
        let other = SigningKey::from_bytes(&random_bytes());
        assert!(
            s.open(&ManifestSigner::verifying_key(&other), &link, &rcpt)
                .is_err()
        );
        // Substituted body (size): rejected.
        let mut bad = s.clone();
        let mut m2 = m.clone();
        m2.size = 1;
        m2.blob_size = ciphertext_len(1);
        bad.body = to_cbor(&m2).unwrap();
        assert_eq!(
            bad.open(&author, &link, &rcpt).unwrap_err().code,
            code::BAD_MANIFEST
        );
        // Trailing bytes after the CBOR: rejected even with a "valid" signature over the trailing bytes.
        let mut tail = m.clone();
        tail.name = "x".into();
        let mut body = to_cbor(&tail).unwrap();
        body.push(0);
        let sig = k.sign_bytes(&signed_message(&link, &rcpt, &body));
        let t = SignedManifest {
            body,
            sig: sig.to_vec(),
        };
        assert!(t.open(&author, &link, &rcpt).is_err());
    }

    #[test]
    fn invalid_fields_are_rejected() {
        let k = SigningKey::from_bytes(&random_bytes());
        let (link, rcpt) = (random_bytes::<32>(), random_bytes::<32>());
        let mut m = manifest();
        m.blob_size += 1;
        assert!(SignedManifest::seal(&m, &k, &link, &rcpt).is_err());
        let mut m = manifest();
        m.mime = "text/plain; x=\u{202e}".into();
        assert!(SignedManifest::seal(&m, &k, &link, &rcpt).is_err());
        let mut m = manifest();
        m.v = 1;
        assert!(SignedManifest::seal(&m, &k, &link, &rcpt).is_err());
    }

    #[test]
    fn offer_debug_hides_the_secret() {
        let k = SigningKey::from_bytes(&random_bytes());
        let s = SignedManifest::seal(&manifest(), &k, &[1; 32], &[2; 32]).unwrap();
        let o = FileOffer {
            manifest: s,
            secret: [0xAB; 32],
        };
        let d = format!("{o:?}");
        assert!(
            !d.contains("171") && !d.to_lowercase().contains("ab, ab"),
            "{d}"
        );
    }
}
