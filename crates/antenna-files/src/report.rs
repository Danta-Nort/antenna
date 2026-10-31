// SPDX-License-Identifier: AGPL-3.0-only
//! File check result (SPEC §10, pipeline step 3) and preview (step 4): types shared by the sandbox worker and the
//! daemon.

use serde::{Deserialize, Serialize};

use crate::detect::Kind;

/// Check verdict, a protocol format (`antenna_proto::files::Verdict`): the same value travels in the sender's manifest.
pub use antenna_proto::files::Verdict;

/// Finding severity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    /// Information (does not affect the verdict): "archive: 12 files", "looks like prompt injection".
    Info,
    /// Risk → [`Verdict::Suspicious`].
    Warn,
    /// Threat → [`Verdict::Threat`].
    Threat,
}

/// Check finding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Finding {
    /// Machine-readable code (`eicar`, `zip_bomb`, `polyglot_zip_trailer`, `secret:private_key`…).
    pub code: String,
    /// Severity.
    pub severity: Severity,
    /// Short explanation without file content (at most 200 characters).
    pub detail: String,
}

impl Finding {
    /// New finding.
    pub fn new(code: impl Into<String>, severity: Severity, detail: impl Into<String>) -> Self {
        let mut detail: String = detail.into();
        if detail.chars().count() > 200 {
            detail = detail.chars().take(200).collect();
        }
        Self {
            code: code.into(),
            severity,
            detail,
        }
    }
}

/// What the content is, for the rules that depend on it (D-130). The worker decides it from the content (the head of
/// the file, and of every member of an archive it opened); a name only ever adds "installer" or "code" to text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContentClass {
    /// Text that does not read as code (notes, prose, data), or an archive of only such text.
    Text,
    /// Code and markup: text-based source code, HTML/CSS/JS, scripts as text, config, notebooks; or an archive whose
    /// members are all text, at least one of them code. Antenna never runs it.
    Code,
    /// A native executable (ELF, PE, Mach-O), or an archive that holds one.
    Executable,
    /// A disk image, an installer or a package, or an archive that holds one.
    Installer,
    /// Anything else: documents, images, media, data, other binaries, an archive of mixed content.
    Other,
}

impl ContentClass {
    /// String for the control protocol (`FileInfo.class`).
    pub fn as_str(self) -> &'static str {
        match self {
            ContentClass::Text => "text",
            ContentClass::Code => "code",
            ContentClass::Executable => "executable",
            ContentClass::Installer => "installer",
            ContentClass::Other => "other",
        }
    }

    /// Text-based: code and markup, or other text.
    pub fn is_text(self) -> bool {
        matches!(self, ContentClass::Text | ContentClass::Code)
    }
}

/// Check report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckReport {
    /// Outcome.
    pub verdict: Verdict,
    /// Type by signature.
    pub kind: Kind,
    /// MIME by signature.
    pub mime: String,
    /// Findings.
    pub findings: Vec<Finding>,
    /// How many bytes went through the checks.
    pub scanned_bytes: u64,
    /// Which engines ran (`signature`, `archive`, `secrets`, `yara-x 1.21.0`, `cdr`, `av:clamscan`…).
    pub engines: Vec<String>,
    /// How the worker was isolated (`landlock=full abi=4 seccomp rlimits`); empty outside the sandbox.
    pub sandbox: String,
    /// What the content is (D-130); absent in reports made before it and when the check did not run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<ContentClass>,
    /// An archive whose members were not all opened and typed (encrypted, nested archives, a format the worker does
    /// not open, too large, unreadable): what it holds is not known (D-130).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub uninspected: bool,
}

impl CheckReport {
    /// Verdict from the findings.
    pub fn verdict_of(findings: &[Finding]) -> Verdict {
        match findings.iter().map(|f| f.severity).max() {
            Some(Severity::Threat) => Verdict::Threat,
            Some(Severity::Warn) => Verdict::Suspicious,
            _ => Verdict::Clean,
        }
    }

    /// A "check did not run" report.
    pub fn failed(reason: &str, detail: impl Into<String>) -> Self {
        Self {
            verdict: Verdict::Failed,
            kind: Kind::Unknown,
            mime: "application/octet-stream".into(),
            findings: vec![Finding::new(reason, Severity::Threat, detail)],
            scanned_bytes: 0,
            engines: vec![],
            sandbox: String::new(),
            class: None,
            uninspected: false,
        }
    }

    /// Adds a finding and recomputes the verdict (except `Failed`, which is never lowered).
    pub fn push(&mut self, f: Finding) {
        self.findings.push(f);
        if self.verdict != Verdict::Failed {
            self.verdict = Self::verdict_of(&self.findings);
        }
    }
}

/// Preview kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PreviewKind {
    /// The image is redrawn into a clean PNG.
    Image,
    /// PDF: pages as pixels + text.
    Pdf,
    /// Office/ODF document: text.
    Document,
    /// Text.
    Text,
    /// Archive: file list (the archive is not unpacked).
    Archive,
    /// No preview (a type without a safe preview).
    None,
}

/// Raster image from the worker: only 8-bit RGBA pixels. The daemon assembles the PNG (the Dangerzone scheme: what
/// leaves the sandbox is pixels, not a file in a format that would need parsing again).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawImage {
    /// Width.
    pub width: u32,
    /// Height.
    pub height: u32,
    /// `width * height * 4` bytes of RGBA.
    #[serde(with = "serde_bytes")]
    pub rgba: Vec<u8>,
}

impl std::fmt::Debug for RawImage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RawImage({}x{})", self.width, self.height)
    }
}

/// Preview from the worker (raw: pixels and text).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawPreview {
    /// Kind.
    pub kind: PreviewKind,
    /// Text (extracted for a PDF, a listing for an archive).
    pub text: Option<String>,
    /// Images/pages.
    pub images: Vec<RawImage>,
    /// The preview is incomplete (more pages/text than the limit).
    pub truncated: bool,
}

/// The safe preview the agent sees (`antenna files preview`): sanitized text, images as PNG assembled by the daemon.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preview {
    /// Kind.
    pub kind: PreviewKind,
    /// Text without control characters (except `\n` and `\t`).
    pub text: Option<String>,
    /// PNG without metadata (IHDR, IDAT, IEND).
    pub images: Vec<serde_bytes::ByteBuf>,
    /// The preview is incomplete.
    pub truncated: bool,
}

impl std::fmt::Debug for Preview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Preview({:?}, text: {} chars, {} images, truncated: {})",
            self.kind,
            self.text.as_ref().map_or(0, |t| t.chars().count()),
            self.images.len(),
            self.truncated
        )
    }
}
