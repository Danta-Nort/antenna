// SPDX-License-Identifier: Apache-2.0
//! File formats (SPEC §7 "Files and streams", §10; `docs/PROTOCOL.md` §19): the manifest, the signed manifest,
//! a file offer inside a link message and a request for a file from a contact's `shared/`.
//!
//! Data only. Manifest signing, `xfile/0` encryption (STREAM) and verification are done by the AGPL crate
//! `antenna-files` with audited crates (signature: Ed25519 over context [`MANIFEST_SIG_CONTEXT`] ‖ 0x00 ‖ link ID ‖
//! recipient key ‖ `body`; ciphertext format: PROTOCOL §19).

use serde::{Deserialize, Serialize};

/// Manifest format version.
pub const MANIFEST_VERSION: u8 = 0;
/// Manifest signature context.
pub const MANIFEST_SIG_CONTEXT: &[u8] = b"x/file-manifest/v0";
/// Maximum length of the manifest's CBOR body.
pub const MAX_MANIFEST: usize = 16 * 1024;
/// Maximum length of the path in a file request.
pub const MAX_REQUEST_PATH: usize = 1024;

/// Verdict of a file check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// No threats found; all checks were completed.
    Clean,
    /// Some risk (macros, JavaScript in a PDF, nested archive, secrets, not everything checked): the owner decides.
    Suspicious,
    /// A threat (EICAR/signature, bomb, polyglot, executable under a different name, dangerous paths in an archive).
    Threat,
    /// The check did not run (no sandbox, the worker crashed or was killed at a limit, timeout): cannot be accepted
    /// without `--force`.
    Failed,
}

impl Verdict {
    /// String for the CLI/JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            Verdict::Clean => "clean",
            Verdict::Suspicious => "suspicious",
            Verdict::Threat => "threat",
            Verdict::Failed => "failed",
        }
    }
}

/// Check result at the sender (only a hint for the recipient: the real check happens at the recipient, SPEC §10).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SenderCheck {
    /// Sender's verdict.
    pub verdict: Verdict,
    /// Finding codes (without details: details may contain file data).
    pub findings: Vec<String>,
}

/// File manifest: everything the recipient knows before downloading (SPEC §10 item 1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// Format version (0).
    pub v: u8,
    /// Random file ID (16 bytes): distinguishes repeated sends of the same content.
    #[serde(with = "serde_bytes")]
    pub file_id: [u8; 16],
    /// Name at the sender (contact data: the recipient normalizes it on receipt).
    pub name: String,
    /// MIME type determined by content at the sender (not by extension).
    pub mime: String,
    /// Size of the plaintext content.
    pub size: u64,
    /// BLAKE3 of the plaintext content.
    #[serde(with = "serde_bytes")]
    pub blake3: [u8; 32],
    /// iroh-blobs blob hash = BLAKE3 of the `xfile/0` ciphertext.
    #[serde(with = "serde_bytes")]
    pub blob: [u8; 32],
    /// Ciphertext size.
    pub blob_size: u64,
    /// Check at the sender.
    pub sender_check: SenderCheck,
    /// Creation time, Unix ms.
    pub created_ms: u64,
}

/// Signed manifest: the CBOR bytes of a [`Manifest`] and the author's signature over them with the link context.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignedManifest {
    /// CBOR [`Manifest`]: exactly the signed bytes.
    #[serde(with = "serde_bytes")]
    pub body: Vec<u8>,
    /// Ed25519.
    #[serde(with = "serde_bytes")]
    pub sig: Vec<u8>,
}

impl std::fmt::Debug for SignedManifest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SignedManifest({} bytes)", self.body.len())
    }
}

/// File offer: the body of a `file` message (`Body::File`), inside Triple Ratchet: the signed manifest and the
/// file secret (32 bytes) from which the STREAM key is derived. The secret is not part of the signed manifest body.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileOffer {
    /// Signed manifest.
    pub manifest: SignedManifest,
    /// File secret.
    #[serde(with = "serde_bytes")]
    pub secret: [u8; 32],
}

impl std::fmt::Debug for FileOffer {
    // The file secret never reaches the logs.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "FileOffer({:?}, secret: ..)", self.manifest)
    }
}

/// Request for a file from a contact's `shared/` (`antenna request`): the body of a `request` message
/// (`Body::FileRequest`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileRequest {
    /// Path inside `shared/` (with `/` separators, no `..` and no absolute paths).
    pub path: String,
}

/// What happened to a file, as its recipient's node tells the sender (`docs/PROTOCOL.md` §19 "The file's fate", D-130,
/// feature `file-fate/0`): the closed vocabulary of a receipt's `why` and the shape of its `rules`.
///
/// A receipt that says why names the reason and the rules of the recipient's check that matched (finding codes such
/// as `active_content` or `archive_member_executable`), never a name, a path or any of the file's content. Rules of
/// the recipient's own configuration (extra YARA rules, an antivirus) go by their kind only (`yara:extra`, `av`), so a
/// contact cannot read the recipient's private rule names from them.
pub mod fate {
    /// Held: the check found a threat (blocked: the same reason on a `reject_file` / `denied`).
    pub const THREAT: &str = "threat";
    /// Held: a native executable (ELF, PE, Mach-O) or an archive that holds one.
    pub const EXECUTABLE: &str = "executable";
    /// Held: a disk image, an installer or a package, or an archive that holds one.
    pub const INSTALLER: &str = "installer";
    /// Held: an archive whose members could not all be opened (encrypted, nested, an unsupported format, too large).
    pub const UNINSPECTED: &str = "uninspected";
    /// Held: the check could not run or did not finish (could not verify is not clean).
    pub const CHECK_FAILED: &str = "check_failed";
    /// Held: the check found something the recipient's owner reviews (the recipient's rules for this contact).
    pub const REVIEW: &str = "review";
    /// Held: the recipient's daemon could not save it by itself (the folder, the disk, every numbered name taken).
    pub const NOT_SAVED: &str = "not_saved";
    /// Blocked: the content did not match its signed manifest.
    pub const DAMAGED: &str = "damaged";
    /// Blocked before the download: the recipient's limits for this contact (files at this level, the daily volume,
    /// the number of files waiting), one reason for all of them, so that it does not tell which.
    pub const LIMIT: &str = "limit";

    /// `why` of a `check_file` / `held` receipt.
    pub const HELD_WHY: &[&str] = &[
        THREAT,
        EXECUTABLE,
        INSTALLER,
        UNINSPECTED,
        CHECK_FAILED,
        REVIEW,
        NOT_SAVED,
    ];
    /// `why` of a `reject_file` / `denied` receipt.
    pub const BLOCKED_WHY: &[&str] = &[THREAT, DAMAGED, LIMIT];
    /// The most rules one receipt names.
    pub const MAX_RULES: usize = 16;
    /// The longest rule, in bytes.
    pub const MAX_RULE: usize = 64;

    /// A rule as a receipt carries it: 1 to [`MAX_RULE`] bytes of `a-z`, `0-9`, `_`, `:`, `.`, `-`.
    pub fn valid_rule(s: &str) -> bool {
        !s.is_empty()
            && s.len() <= MAX_RULE
            && s.bytes().all(|b| {
                b.is_ascii_lowercase()
                    || b.is_ascii_digit()
                    || matches!(b, b'_' | b':' | b'.' | b'-')
            })
    }

    /// A finding code as the sender may see it: the recipient's own rules by their kind only, anything outside the
    /// rule alphabet as `other`.
    pub fn wire_rule(code: &str) -> String {
        if code.starts_with("yara:") && code.matches(':').count() >= 2 {
            return "yara:extra".into();
        }
        if code.starts_with("av:") {
            return "av".into();
        }
        if valid_rule(code) {
            code.to_string()
        } else {
            "other".into()
        }
    }

    /// The rules a receipt carries: in order, each once, at most [`MAX_RULES`].
    pub fn wire_rules<'a>(codes: impl IntoIterator<Item = &'a str>) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for c in codes {
            let r = wire_rule(c);
            if !out.contains(&r) {
                out.push(r);
            }
            if out.len() == MAX_RULES {
                break;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{from_cbor, to_cbor};

    #[test]
    fn fate_rules_never_carry_private_rule_names_or_free_text() {
        assert_eq!(fate::wire_rule("active_content"), "active_content");
        assert_eq!(fate::wire_rule("secret:private_key"), "secret:private_key");
        assert_eq!(
            fate::wire_rule("yara:script_download_and_run"),
            "yara:script_download_and_run"
        );
        assert_eq!(fate::wire_rule("yara:extra:AcmeInternalRule"), "yara:extra");
        assert_eq!(fate::wire_rule("av:clamscan"), "av");
        assert_eq!(fate::wire_rule("Bad Code"), "other");
        assert_eq!(fate::wire_rule(&"x".repeat(65)), "other");
        let many: Vec<String> = (0..40).map(|i| format!("r{i}")).collect();
        let w = fate::wire_rules(many.iter().map(String::as_str));
        assert_eq!(w.len(), fate::MAX_RULES);
        assert_eq!(
            fate::wire_rules(["a", "a", "av:x", "av:y"]),
            vec!["a".to_string(), "av".into()]
        );
        for w in fate::HELD_WHY.iter().chain(fate::BLOCKED_WHY) {
            assert!(fate::valid_rule(w), "{w}");
        }
    }

    #[test]
    fn manifest_wire_shape() {
        let m = Manifest {
            v: 0,
            file_id: [1; 16],
            name: "a.pdf".into(),
            mime: "application/pdf".into(),
            size: 3,
            blake3: [2; 32],
            blob: [3; 32],
            blob_size: 63,
            sender_check: SenderCheck {
                verdict: Verdict::Suspicious,
                findings: vec!["secret:password".into()],
            },
            created_ms: 5,
        };
        let back: Manifest = from_cbor(&to_cbor(&m).unwrap()).unwrap();
        assert_eq!(back, m);
        let v: ciborium::Value = from_cbor(&to_cbor(&m).unwrap()).unwrap();
        let map = v.as_map().unwrap();
        let get = |k: &str| {
            map.iter()
                .find(|(kk, _)| kk.as_text() == Some(k))
                .map(|(_, v)| v.clone())
                .unwrap()
        };
        assert!(get("file_id").is_bytes());
        assert!(get("blake3").is_bytes());
        let sc = get("sender_check");
        let verdict = sc
            .as_map()
            .unwrap()
            .iter()
            .find(|(k, _)| k.as_text() == Some("verdict"))
            .unwrap()
            .1
            .clone();
        assert_eq!(verdict.as_text(), Some("suspicious"));
        let o = FileOffer {
            manifest: SignedManifest {
                body: to_cbor(&m).unwrap(),
                sig: vec![9; 64],
            },
            secret: [7; 32],
        };
        assert!(!format!("{o:?}").contains("7, 7"));
        let back: FileOffer = from_cbor(&to_cbor(&o).unwrap()).unwrap();
        assert_eq!(back, o);
    }
}
