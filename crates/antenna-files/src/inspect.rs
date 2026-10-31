// SPDX-License-Identifier: AGPL-3.0-only
//! Archives (SPEC §10 step 3: "archives are not unpacked", "checks for archive bombs", "archive depth limits").
//!
//! An archive is not unpacked to disk and is not handed to the agent piece by piece. What is checked:
//! - ZIP: the central directory without unpacking: entry count, declared size and compression ratio (bomb), overlapping
//!   entries (Fifield's "overlapping files" bomb), dangerous paths (`..`, absolute, device names), symlinks,
//!   encryption, nested archives (depth 1: a nested one is not opened, it becomes a finding), executable entries,
//!   Office macros;
//! - tar: 512-byte headers: paths, links (sym/hard), special files (devices, FIFO), size;
//! - gzip: the stream is fed into a capped counter (not accumulated in memory): compression ratio and the type inside;
//!   a tar inside is parsed from the same stream;
//! - bzip2/xz/zstd/7z/RAR: not parsed (finding `archive_not_inspected`).

use std::io::{Cursor, Read};

use crate::detect::{Kind, refine_zip, sniff};
use crate::names::archive_path_problem;
use crate::report::{ContentClass, Finding, Severity};

/// More entries than this is a risk.
pub const MAX_ENTRIES: usize = 10_000;
/// More declared unpacked volume than this is a threat (bomb).
pub const MAX_UNPACKED: u64 = 10 << 30;
/// Compression ratio above which (at a large volume) the archive is considered a bomb.
pub const MAX_RATIO: u64 = 100;
/// Unpacked volume from which [`MAX_RATIO`] applies.
pub const RATIO_FLOOR: u64 = 100 << 20;
/// How much gzip to unpack for measuring.
pub const GZIP_MEASURE_LIMIT: u64 = 1 << 30;
/// Lines in the preview file list.
pub const LISTING_LINES: usize = 500;

const NESTED_EXT: &[&str] = &[
    "zip", "jar", "apk", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar", "cab", "iso", "dmg",
    "docx", "xlsx", "pptx", "odt",
];
const EXEC_EXT: &[&str] = &[
    "exe", "dll", "scr", "bat", "cmd", "com", "ps1", "psm1", "vbs", "vbe", "js", "jse", "wsf",
    "wsh", "hta", "msi", "msp", "jar", "sh", "bash", "zsh", "command", "app", "elf", "so", "dylib",
    "py", "pl", "rb", "lnk", "desktop",
];

fn ext_of(name: &str) -> String {
    name.rsplit('/')
        .next()
        .and_then(|n| n.rsplit_once('.'))
        .map(|(_, e)| e.to_lowercase())
        .unwrap_or_default()
}

/// Archive parsing result.
#[derive(Debug, Default)]
pub struct ArchiveInfo {
    /// Refined type (for ZIP: OOXML/ODF/JAR/APK).
    pub kind: Option<Kind>,
    /// Findings.
    pub findings: Vec<Finding>,
    /// File list for the preview.
    pub listing: String,
    /// Entries.
    pub entries: usize,
    /// Declared unpacked volume.
    pub unpacked: u64,
    /// What the members are by their content (D-130): ZIP, tar and gzip only; `None` when the members were not opened
    /// at all (another format, or an OOXML/ODF/JAR/APK container, which is a document or a program, not a folder).
    pub members: Option<Members>,
}

/// How many bytes of each archive member are read to tell what it is (the same window [`sniff`] looks at).
pub const MEMBER_HEAD: u64 = 8192;

/// What the members of an archive are, each by its first bytes (D-130): opened in the worker's memory only, never
/// unpacked to disk or handed to anyone. A nested archive is not opened (depth 1), so it counts as not opened.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Members {
    /// Text that does not read as code.
    pub text: usize,
    /// Code and markup (text by content; by kind or by name).
    pub code: usize,
    /// Native executables (ELF, PE, Mach-O).
    pub executables: usize,
    /// Disk images, installers, packages.
    pub installers: usize,
    /// Anything else (images, documents, fonts, other binaries).
    pub other: usize,
    /// Members that were not opened: encrypted, unreadable, nested archives, beyond the entry limit.
    pub unopened: usize,
}

impl Members {
    /// Every member was opened and typed.
    pub fn complete(&self) -> bool {
        self.unopened == 0
    }

    /// The archive's class: what its most dangerous members are, then whether everything is text.
    pub fn class(&self) -> ContentClass {
        if self.executables > 0 {
            ContentClass::Executable
        } else if self.installers > 0 {
            ContentClass::Installer
        } else if self.other > 0 {
            ContentClass::Other
        } else if self.code > 0 {
            ContentClass::Code
        } else {
            ContentClass::Text
        }
    }

    fn add(&mut self, head: &[u8], name: &str) {
        let n = match member_class(head, name) {
            None => &mut self.unopened,
            Some(ContentClass::Text) => &mut self.text,
            Some(ContentClass::Code) => &mut self.code,
            Some(ContentClass::Executable) => &mut self.executables,
            Some(ContentClass::Installer) => &mut self.installers,
            Some(ContentClass::Other) => &mut self.other,
        };
        *n = n.saturating_add(1);
    }
}

/// Document containers that are ZIP inside: as members they are documents, not nested folders.
const DOC_ZIP_EXT: &[&str] = &[
    "docx", "docm", "dotx", "xlsx", "xlsm", "xltx", "pptx", "pptm", "potx", "ppsx", "odt", "ods",
    "odp", "odg", "ott", "epub",
];

/// What one archive member is, from its first [`MEMBER_HEAD`] bytes and its name; `None` for a nested archive, which
/// is not opened.
fn member_class(head: &[u8], name: &str) -> Option<ContentClass> {
    let kind = sniff(head);
    if kind.is_native_executable() {
        return Some(ContentClass::Executable);
    }
    if kind == Kind::Apk || crate::detect::installer_format(head, kind, name).is_some() {
        return Some(ContentClass::Installer);
    }
    if kind.is_zip_family() || kind.is_archive() {
        return DOC_ZIP_EXT
            .contains(&ext_of(name).as_str())
            .then_some(ContentClass::Other);
    }
    if kind.is_text() || kind == Kind::Empty {
        return Some(if kind == Kind::Rtf {
            ContentClass::Other
        } else if matches!(kind, Kind::Html | Kind::Xml | Kind::Svg | Kind::Script)
            || crate::detect::is_code_name(name)
        {
            ContentClass::Code
        } else {
            ContentClass::Text
        });
    }
    Some(ContentClass::Other)
}

/// Opens every ZIP member in memory for its first bytes (D-130): an encrypted or unreadable member, and anything past
/// [`MAX_ENTRIES`], counts as not opened.
fn zip_members(z: &mut zip::ZipArchive<Cursor<&[u8]>>) -> Members {
    let mut m = Members::default();
    for i in 0..z.len() {
        if i >= MAX_ENTRIES {
            m.unopened = m.unopened.saturating_add(z.len() - i);
            break;
        }
        let f = match z.by_index(i) {
            Ok(f) => f,
            Err(_) => {
                m.unopened += 1;
                continue;
            }
        };
        if f.is_dir() {
            continue;
        }
        if f.encrypted() {
            m.unopened += 1;
            continue;
        }
        let name = String::from_utf8_lossy(f.name_raw()).into_owned();
        let mut head = Vec::with_capacity(MEMBER_HEAD as usize);
        if f.take(MEMBER_HEAD).read_to_end(&mut head).is_err() {
            m.unopened += 1;
            continue;
        }
        m.add(&head, &name);
    }
    m
}

struct Entry {
    name: String,
    size: u64,
    symlink: bool,
    special: bool,
    hardlink: bool,
}

fn common_entry_findings(info: &mut ArchiveInfo, e: &Entry, flagged: &mut [bool; 6]) {
    if let Some(p) = archive_path_problem(&e.name)
        && !flagged[0]
    {
        flagged[0] = true;
        info.findings.push(Finding::new(
            format!("archive_{p}"),
            Severity::Threat,
            "an archive entry has a dangerous path (zip-slip)",
        ));
    }
    if e.symlink && !flagged[1] {
        flagged[1] = true;
        info.findings.push(Finding::new(
            "archive_symlink",
            Severity::Threat,
            "the archive contains a symbolic link",
        ));
    }
    if e.hardlink && !flagged[2] {
        flagged[2] = true;
        info.findings.push(Finding::new(
            "archive_hardlink",
            Severity::Threat,
            "the archive contains a hard link",
        ));
    }
    if e.special && !flagged[3] {
        flagged[3] = true;
        info.findings.push(Finding::new(
            "archive_special_file",
            Severity::Threat,
            "the archive contains a device or FIFO entry",
        ));
    }
    let ext = ext_of(&e.name);
    if NESTED_EXT.contains(&ext.as_str()) && !flagged[4] {
        flagged[4] = true;
        info.findings.push(Finding::new(
            "nested_archive",
            Severity::Warn,
            "the archive contains another archive; depth limit is 1, nested archives are not inspected",
        ));
    }
    if EXEC_EXT.contains(&ext.as_str()) && !flagged[5] {
        flagged[5] = true;
        info.findings.push(Finding::new(
            "executable_entry",
            Severity::Warn,
            format!("the archive contains executable or script files (.{ext})"),
        ));
    }
    if info.entries < LISTING_LINES {
        let kind = if e.symlink {
            " -> symlink"
        } else if e.hardlink {
            " -> hardlink"
        } else {
            ""
        };
        info.listing
            .push_str(&format!("{:>12}  {}{}\n", e.size, escape(&e.name), kind));
    }
}

/// Entry name for display: control and invisible characters as `\u{..}`.
fn escape(name: &str) -> String {
    crate::text::escape_visible(name, 300)
}

fn bomb_check(info: &mut ArchiveInfo, packed: u64) {
    if info.unpacked > MAX_UNPACKED
        || (info.unpacked > RATIO_FLOOR && info.unpacked / packed.max(1) > MAX_RATIO)
    {
        info.findings.push(Finding::new(
            "archive_bomb",
            Severity::Threat,
            format!(
                "declared unpacked size {} bytes from {packed} bytes (ratio {})",
                info.unpacked,
                info.unpacked / packed.max(1)
            ),
        ));
    }
    if info.entries > MAX_ENTRIES {
        info.findings.push(Finding::new(
            "archive_too_many_entries",
            Severity::Warn,
            format!("{} entries", info.entries),
        ));
    }
}

/// Parses a ZIP (and OOXML/ODF/JAR/APK) without unpacking.
pub fn inspect_zip(data: &[u8]) -> ArchiveInfo {
    let mut info = ArchiveInfo::default();
    let mut z = match zip::ZipArchive::new(Cursor::new(data)) {
        Ok(z) => z,
        Err(e) => {
            info.findings.push(Finding::new(
                "archive_malformed",
                Severity::Threat,
                format!("ZIP central directory cannot be read: {e}"),
            ));
            return info;
        }
    };
    let mut names = Vec::new();
    let mut spans: Vec<(u64, u64)> = Vec::new();
    let mut flagged = [false; 6];
    let mut encrypted = false;
    let mut macros = false;
    let mut embedded = false;
    for i in 0..z.len() {
        let f = match z.by_index_raw(i) {
            Ok(f) => f,
            Err(e) => {
                info.findings.push(Finding::new(
                    "archive_malformed",
                    Severity::Threat,
                    format!("ZIP entry {i} cannot be read: {e}"),
                ));
                break;
            }
        };
        let name = String::from_utf8_lossy(f.name_raw()).into_owned();
        let size = f.size();
        let csize = f.compressed_size();
        info.unpacked = info.unpacked.saturating_add(size);
        if let Some(start) = f.data_start() {
            spans.push((f.header_start(), start.saturating_add(csize)));
        }
        if size > RATIO_FLOOR && size / csize.max(1) > 1000 {
            info.findings.push(Finding::new(
                "archive_bomb",
                Severity::Threat,
                format!("entry {i}: {size} bytes from {csize} bytes"),
            ));
        }
        encrypted |= f.encrypted();
        let lname = name.to_lowercase();
        macros |= lname.ends_with("vbaproject.bin")
            || lname.starts_with("basic/")
            || lname.ends_with(".bas");
        embedded |= lname.contains("/embeddings/") || lname.contains("/activex/");
        let e = Entry {
            name: name.clone(),
            size,
            symlink: f.is_symlink(),
            special: f
                .unix_mode()
                .is_some_and(|m| matches!(m & 0o170000, 0o020000 | 0o060000 | 0o010000 | 0o140000)),
            hardlink: false,
        };
        info.entries += 1;
        common_entry_findings(&mut info, &e, &mut flagged);
        names.push(name);
    }
    spans.sort_unstable();
    if spans.windows(2).any(|w| w[1].0 < w[0].1) {
        info.findings.push(Finding::new(
            "archive_bomb_overlap",
            Severity::Threat,
            "ZIP entries overlap (overlapping-file zip bomb)",
        ));
    }
    if encrypted {
        info.findings.push(Finding::new(
            "archive_encrypted",
            Severity::Warn,
            "the archive has encrypted entries; their contents cannot be checked",
        ));
    }
    let mimetype = z.by_name("mimetype").ok().and_then(|mut f| {
        let mut s = String::new();
        f.by_ref().take(256).read_to_string(&mut s).ok()?;
        Some(s)
    });
    let kind = refine_zip(&names, mimetype.as_deref());
    if macros && matches!(kind, Kind::Docx | Kind::Xlsx | Kind::Pptx | Kind::Odf) {
        info.findings.push(Finding::new(
            "office_macros",
            Severity::Warn,
            "the document contains macros",
        ));
    }
    if embedded && matches!(kind, Kind::Docx | Kind::Xlsx | Kind::Pptx) {
        info.findings.push(Finding::new(
            "office_embedded_objects",
            Severity::Warn,
            "the document contains embedded objects (OLE/ActiveX)",
        ));
    }
    if matches!(kind, Kind::Docx | Kind::Xlsx | Kind::Pptx) {
        info.findings.extend(ooxml_active_parts(&mut z, &names));
    }
    if kind == Kind::Zip {
        info.findings.push(Finding::new(
            "archive",
            Severity::Info,
            format!(
                "ZIP archive: {} entries, {} bytes unpacked (not unpacked)",
                info.entries, info.unpacked
            ),
        ));
    }
    bomb_check(&mut info, data.len() as u64);
    // A plain ZIP is a folder of files: what each member is decides its class (D-130). A bomb's or a broken archive's
    // members are not opened: it is a threat whatever they are.
    if kind == Kind::Zip && !info.findings.iter().any(|f| f.severity == Severity::Threat) {
        info.members = Some(zip_members(&mut z));
    }
    info.kind = Some(kind);
    info
}

fn read_small(z: &mut zip::ZipArchive<Cursor<&[u8]>>, name: &str, max: u64) -> Option<String> {
    let f = z.by_name(name).ok()?;
    let mut buf = Vec::new();
    f.take(max).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// Relationships of one OOXML part (`*.rels`): (type, target, whether external). This parses the XML and decodes
/// attributes instead of searching for substrings (single quotes, whitespace and `&#69;xternal` bypassed a substring
/// search).
fn rels_of(xml: &str) -> Vec<(String, String, bool)> {
    use quick_xml::events::Event;
    let mut out = Vec::new();
    let mut r = quick_xml::Reader::from_str(xml);
    loop {
        match r.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e))
                if e.local_name().as_ref().eq_ignore_ascii_case("Relationship") =>
            {
                let (mut ty, mut target, mut external) = (String::new(), String::new(), false);
                for a in e.attributes().flatten() {
                    let Ok(v) = a.normalized_value(quick_xml::XmlVersion::Implicit1_0) else {
                        continue;
                    };
                    match a.key.local_name().as_ref().to_ascii_lowercase().as_str() {
                        "type" => ty = v.to_lowercase(),
                        "target" => target = v.trim().to_lowercase(),
                        "targetmode" => external = v.trim().eq_ignore_ascii_case("external"),
                        _ => {}
                    }
                }
                out.push((ty, target, external));
                if out.len() > 10_000 {
                    break;
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out
}

/// OOXML: external relationships (template, OLE object, frame by reference: the Follina/remote template scheme) and
/// DDE fields.
fn ooxml_active_parts(z: &mut zip::ZipArchive<Cursor<&[u8]>>, names: &[String]) -> Vec<Finding> {
    let mut out = Vec::new();
    let mut external = false;
    let mut dangerous = false;
    for n in names
        .iter()
        .filter(|n| n.to_lowercase().ends_with(".rels"))
        .take(256)
    {
        let Some(x) = read_small(z, n, 1 << 20) else {
            continue;
        };
        for (ty, target, ext) in rels_of(&x) {
            // Outbound hyperlinks are normal in a document; parts that get loaded are the danger.
            if ty.ends_with("/hyperlink") {
                continue;
            }
            let scheme_bad = [
                "mhtml:",
                "ms-msdt",
                "search-ms",
                "file:",
                "\\\\",
                "ms-excel:",
                "ms-word:",
                "ms-powerpoint:",
            ]
            .iter()
            .any(|p| target.contains(p));
            if ext || scheme_bad {
                external = true;
            }
            if scheme_bad {
                dangerous = true;
            }
        }
    }
    if dangerous {
        out.push(Finding::new(
            "office_external_exploit_link",
            Severity::Threat,
            "the document loads an external part through mhtml:/ms-msdt:/file: (Follina-style)",
        ));
    } else if external {
        out.push(Finding::new(
            "office_external_reference",
            Severity::Warn,
            "the document loads a template, object or frame from an external location",
        ));
    }
    // DDE in every part of the document and workbook (headers, sheets, external links), with a shared limit.
    let mut budget: u64 = 64 << 20;
    for n in names.iter().filter(|n| {
        let l = n.to_lowercase();
        (l.starts_with("word/") || l.starts_with("xl/")) && l.ends_with(".xml")
    }) {
        if budget == 0 {
            break;
        }
        let Some(x) = read_small(z, n, budget.min(32 << 20)) else {
            continue;
        };
        budget = budget.saturating_sub(x.len() as u64);
        let u = x.to_uppercase();
        if u.contains("DDEAUTO")
            || u.contains(" DDE ")
            || u.contains(">DDE ")
            || u.contains("DDEDATA")
        {
            out.push(Finding::new(
                "office_dde",
                Severity::Warn,
                "the document has DDE fields (run commands)",
            ));
            break;
        }
    }
    out
}

/// Secrets in ZIP contents: entries are unpacked **into the worker's memory** (not to disk and not to the agent) with
/// a shared limit of `budget` bytes; nested archives and encrypted entries are not opened (`partial`).
pub fn scan_zip_secrets(
    data: &[u8],
    scanner: crate::secrets::TextScanner,
    budget: u64,
) -> (Vec<&'static str>, bool) {
    let mut kinds: Vec<&'static str> = Vec::new();
    let mut partial = false;
    let Ok(mut z) = zip::ZipArchive::new(Cursor::new(data)) else {
        return (kinds, true);
    };
    let mut left = budget;
    for i in 0..z.len() {
        if left == 0 {
            partial = true;
            break;
        }
        let Ok(f) = z.by_index(i) else {
            partial = true;
            continue;
        };
        if f.is_dir() {
            continue;
        }
        if f.encrypted() {
            partial = true;
            continue;
        }
        let mut buf = Vec::new();
        let take = left.min(64 << 20);
        if f.take(take).read_to_end(&mut buf).is_err() {
            partial = true;
            continue;
        }
        left = left.saturating_sub(buf.len() as u64);
        let k = sniff(&buf[..buf.len().min(8192)]);
        if k.is_archive() || k.is_zip_family() {
            partial = true;
        }
        let text = if k.is_text() {
            String::from_utf8_lossy(&buf).into_owned()
        } else {
            crate::secrets::printable_strings(&buf, 8, crate::secrets::MAX_SCAN)
        };
        for kind in crate::secrets::scan_text(&text, scanner).0 {
            if !kinds.contains(&kind) {
                kinds.push(kind);
            }
        }
    }
    (kinds, partial)
}

/// Secrets in a gzip stream (unpacked into the worker's memory in windows, with a `budget` limit).
pub fn scan_gzip_secrets(
    data: &[u8],
    scanner: crate::secrets::TextScanner,
    budget: u64,
) -> (Vec<&'static str>, bool) {
    let mut d = flate2::read::MultiGzDecoder::new(data).take(budget);
    let mut kinds: Vec<&'static str> = Vec::new();
    let mut carry: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 8 << 20];
    let mut total = 0u64;
    loop {
        let n = match d.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => return (kinds, true),
        };
        total += n as u64;
        let mut w = std::mem::take(&mut carry);
        w.extend_from_slice(&buf[..n]);
        let text = crate::secrets::printable_strings(&w, 8, usize::MAX);
        for kind in crate::secrets::scan_text(&text, scanner).0 {
            if !kinds.contains(&kind) {
                kinds.push(kind);
            }
        }
        carry = w[w.len().saturating_sub(8192)..].to_vec();
    }
    (kinds, total >= budget)
}

fn octal(field: &[u8]) -> Option<u64> {
    if field.first().is_some_and(|b| b & 0x80 != 0) {
        // base-256 (GNU): large sizes
        let mut v: u64 = (field[0] & 0x7F) as u64;
        for b in &field[1..] {
            v = v.checked_mul(256)?.checked_add(*b as u64)?;
        }
        return Some(v);
    }
    let s = std::str::from_utf8(field).ok()?;
    let s = s.trim_matches(|c: char| c == '\0' || c == ' ');
    if s.is_empty() {
        return Some(0);
    }
    u64::from_str_radix(s, 8).ok()
}

fn cstr(field: &[u8]) -> String {
    let end = field.iter().position(|b| *b == 0).unwrap_or(field.len());
    String::from_utf8_lossy(&field[..end]).into_owned()
}

/// Parses a tar from a stream (headers; data is skipped). `packed` is the source file size (for the compression ratio).
pub fn inspect_tar(mut r: impl Read, packed: u64) -> ArchiveInfo {
    let mut info = ArchiveInfo {
        kind: Some(Kind::Tar),
        ..Default::default()
    };
    let mut flagged = [false; 6];
    let mut members = Members::default();
    let mut hdr = [0u8; 512];
    let mut long_name: Option<String> = None;
    let mut zero_blocks = 0;
    loop {
        if r.read_exact(&mut hdr).is_err() {
            break; // end of stream (including a truncated archive)
        }
        if hdr.iter().all(|b| *b == 0) {
            zero_blocks += 1;
            if zero_blocks == 2 {
                break;
            }
            continue;
        }
        zero_blocks = 0;
        let Some(size) = octal(&hdr[124..136]) else {
            info.findings.push(Finding::new(
                "archive_malformed",
                Severity::Threat,
                "bad tar header",
            ));
            break;
        };
        let typeflag = hdr[156];
        let Some(padded) = size.div_ceil(512).checked_mul(512) else {
            info.findings.push(Finding::new(
                "archive_malformed",
                Severity::Threat,
                "bad tar entry size",
            ));
            break;
        };
        let mut name = cstr(&hdr[0..100]);
        if &hdr[257..262] == b"ustar" {
            let prefix = cstr(&hdr[345..500]);
            if !prefix.is_empty() {
                name = format!("{prefix}/{name}");
            }
        }
        match typeflag {
            b'L' | b'x' | b'g' => {
                // A GNU long name or a pax extended header: read it (with a limit) and apply it to the next entry.
                if size > 1 << 20 {
                    info.findings.push(Finding::new(
                        "archive_malformed",
                        Severity::Threat,
                        "huge tar extension header",
                    ));
                    break;
                }
                let mut buf = vec![0u8; padded as usize];
                if r.read_exact(&mut buf).is_err() {
                    break;
                }
                buf.truncate(size as usize);
                if typeflag == b'L' {
                    long_name = Some(cstr(&buf));
                } else if typeflag == b'x' {
                    for rec in String::from_utf8_lossy(&buf).lines() {
                        if let Some((_, kv)) = rec.split_once(' ')
                            && let Some(p) = kv.strip_prefix("path=")
                        {
                            long_name = Some(p.to_string());
                        }
                    }
                }
                continue;
            }
            _ => {}
        }
        if let Some(n) = long_name.take() {
            name = n;
        }
        let e = Entry {
            name,
            size,
            symlink: typeflag == b'2',
            hardlink: typeflag == b'1',
            special: matches!(typeflag, b'3' | b'4' | b'6'),
        };
        info.entries += 1;
        info.unpacked = info.unpacked.saturating_add(size);
        common_entry_findings(&mut info, &e, &mut flagged);
        if info.entries > 10 * MAX_ENTRIES {
            members.unopened += 1;
            break;
        }
        // A regular file's first bytes say what it is (D-130); links and special files are threats already, a
        // directory has no data, any other entry type is not opened
        let mut skip = padded;
        match typeflag {
            b'0' | 0 | b'7' => {
                let take = size.min(MEMBER_HEAD);
                let mut head = vec![0u8; take as usize];
                if r.read_exact(&mut head).is_err() {
                    members.unopened += 1;
                    break;
                }
                members.add(&head, &e.name);
                skip = padded - take;
            }
            b'1' | b'2' | b'3' | b'4' | b'5' | b'6' => {}
            _ => members.unopened += 1,
        }
        // Skip the rest of the entry data.
        if std::io::copy(&mut r.by_ref().take(skip), &mut std::io::sink()).ok() != Some(skip) {
            members.unopened += 1;
            break;
        }
    }
    info.members = Some(members);
    bomb_check(&mut info, packed);
    info.findings.push(Finding::new(
        "archive",
        Severity::Info,
        format!(
            "tar archive: {} entries, {} bytes (not unpacked)",
            info.entries, info.unpacked
        ),
    ));
    info
}

/// Byte counter with a limit: reads at most `limit` and remembers whether the limit was hit.
struct Capped<R> {
    inner: R,
    left: u64,
    total: u64,
    head: Vec<u8>,
}

impl<R: Read> Read for Capped<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.left == 0 {
            return Ok(0);
        }
        let max = (buf.len() as u64).min(self.left) as usize;
        let n = self.inner.read(&mut buf[..max])?;
        self.left -= n as u64;
        self.total += n as u64;
        if self.head.len() < 8192 {
            let take = (8192 - self.head.len()).min(n);
            self.head.extend_from_slice(&buf[..take]);
        }
        Ok(n)
    }
}

/// gzip: measures the unpacked volume as a stream (with a limit), detects the type inside, parses a tar.
pub fn inspect_gzip(data: &[u8], name: &str) -> ArchiveInfo {
    let dec = flate2::read::MultiGzDecoder::new(data);
    let mut c = Capped {
        inner: dec,
        left: GZIP_MEASURE_LIMIT,
        total: 0,
        head: Vec::new(),
    };
    // The head first, to see whether there is a tar inside.
    let mut first = [0u8; 8192];
    let mut got = 0;
    let mut err = None;
    while got < first.len() {
        match c.read(&mut first[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) => {
                err = Some(e);
                break;
            }
        }
    }
    let inner = sniff(&first[..got]);
    let inner_warn = if inner.is_executable()
        || inner == Kind::Unknown
        || (inner.is_archive() && inner != Kind::Tar)
    {
        Some(Finding::new(
            "archive_inner_type",
            Severity::Warn,
            format!("gzip contains {} (not inspected)", inner.mime()),
        ))
    } else {
        None
    };
    let mut info = if inner == Kind::Tar && err.is_none() {
        let chained = Cursor::new(first[..got].to_vec()).chain(&mut c);
        let mut i = inspect_tar(chained, data.len() as u64);
        i.unpacked = 0;
        i
    } else {
        // One compressed file: its first bytes say what it is, under its name without `.gz` (D-130)
        let inner_name = name
            .strip_suffix(".gz")
            .or_else(|| name.strip_suffix(".GZ"))
            .unwrap_or(name);
        let mut m = Members::default();
        m.add(&first[..got], inner_name);
        ArchiveInfo {
            members: Some(m),
            ..Default::default()
        }
    };
    if err.is_none()
        && let Err(e) = std::io::copy(&mut c, &mut std::io::sink())
    {
        err = Some(e);
    }
    // A broken stream, or one too large to read to its end: what else it holds is not known
    if (err.is_some() || c.left == 0)
        && let Some(m) = info.members.as_mut()
    {
        m.unopened += 1;
    }
    if let Some(e) = err {
        info.findings.push(Finding::new(
            "archive_malformed",
            Severity::Warn,
            format!("gzip stream is broken: {e}"),
        ));
    }
    info.unpacked = c.total;
    info.kind = Some(Kind::Gzip);
    info.findings.extend(inner_warn);
    if c.left == 0 {
        let ratio = c.total / (data.len() as u64).max(1);
        info.findings.push(if ratio > MAX_RATIO {
            Finding::new(
                "archive_bomb",
                Severity::Threat,
                format!(
                    "gzip unpacks to more than {} bytes from {} bytes",
                    c.total,
                    data.len()
                ),
            )
        } else {
            Finding::new(
                "archive_too_large_to_measure",
                Severity::Warn,
                format!("gzip unpacks to more than {} bytes", c.total),
            )
        });
    } else {
        bomb_check(&mut info, data.len() as u64);
    }
    info.findings.push(Finding::new(
        "archive",
        Severity::Info,
        format!(
            "gzip stream: {} bytes unpacked, inner type {}",
            c.total,
            inner.mime()
        ),
    ));
    if inner != Kind::Tar {
        info.listing = format!("gzip: {} bytes, inner type {}\n", c.total, inner.mime());
    }
    info
}

/// A compressed stream/archive that we do not parse.
pub fn not_inspected(kind: Kind) -> ArchiveInfo {
    ArchiveInfo {
        kind: Some(kind),
        findings: vec![Finding::new(
            "archive_not_inspected",
            Severity::Warn,
            format!(
                "{} archives are not inspected; contents unknown",
                kind.mime()
            ),
        )],
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn zip_with(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (n, d) in entries {
            w.start_file(*n, zip::write::SimpleFileOptions::default())
                .unwrap();
            w.write_all(d).unwrap();
        }
        w.finish().unwrap().into_inner()
    }

    #[test]
    fn clean_zip_and_slip() {
        let z = zip_with(&[("a.txt", b"hello"), ("dir/b.txt", b"world")]);
        let i = inspect_zip(&z);
        assert_eq!(i.kind, Some(Kind::Zip));
        assert!(
            i.findings.iter().all(|f| f.severity == Severity::Info),
            "{:?}",
            i.findings
        );
        assert_eq!(i.entries, 2);
        let z = zip_with(&[("../../.ssh/authorized_keys", b"ssh-ed25519 AAAA")]);
        let i = inspect_zip(&z);
        assert!(
            i.findings
                .iter()
                .any(|f| f.code == "archive_path_traversal"),
            "{:?}",
            i.findings
        );
    }

    #[test]
    fn tar_links_and_devices() {
        fn hdr(name: &str, typeflag: u8, size: u64) -> Vec<u8> {
            let mut h = vec![0u8; 512];
            h[..name.len()].copy_from_slice(name.as_bytes());
            let s = format!("{size:011o}\0");
            h[124..136].copy_from_slice(s.as_bytes());
            h[156] = typeflag;
            h[257..263].copy_from_slice(b"ustar\0");
            h
        }
        let mut t = hdr("ok.txt", b'0', 3);
        t.extend_from_slice(&[b'a'; 512]);
        t.extend(hdr("link", b'2', 0));
        t.extend(hdr("dev", b'3', 0));
        t.extend(hdr("/etc/cron.d/x", b'0', 0));
        t.extend(vec![0u8; 1024]);
        let i = inspect_tar(&t[..], t.len() as u64);
        let codes: Vec<_> = i.findings.iter().map(|f| f.code.as_str()).collect();
        assert!(codes.contains(&"archive_symlink"), "{codes:?}");
        assert!(codes.contains(&"archive_special_file"), "{codes:?}");
        assert!(codes.contains(&"archive_absolute_path"), "{codes:?}");
        assert_eq!(i.entries, 4);
    }
}
