// SPDX-License-Identifier: AGPL-3.0-only
//! File type by signature (SPEC §10 step 3: "type detection by signature", not by extension) and polyglot indicators.
//!
//! Runs only inside the sandbox worker (and at the sender, for the manifest's `mime` field), but the parsing itself is
//! minimal: magic bytes, no format parsers.

use serde::{Deserialize, Serialize};

use crate::report::{Finding, Severity};

/// Content type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Empty file.
    Empty,
    /// UTF-8/UTF-16 text.
    Text,
    /// HTML.
    Html,
    /// XML.
    Xml,
    /// SVG (shown as text, not rendered).
    Svg,
    /// RTF.
    Rtf,
    /// Script with `#!`.
    Script,
    /// PDF.
    Pdf,
    /// PNG.
    Png,
    /// JPEG.
    Jpeg,
    /// GIF.
    Gif,
    /// WebP.
    Webp,
    /// BMP.
    Bmp,
    /// ICO.
    Ico,
    /// TIFF (no preview).
    Tiff,
    /// ZIP.
    Zip,
    /// Word OOXML.
    Docx,
    /// Excel OOXML.
    Xlsx,
    /// PowerPoint OOXML.
    Pptx,
    /// OpenDocument.
    Odf,
    /// Java JAR (executable archive).
    Jar,
    /// Android APK (executable archive).
    Apk,
    /// gzip.
    Gzip,
    /// bzip2.
    Bzip2,
    /// xz.
    Xz,
    /// zstd.
    Zstd,
    /// 7z.
    SevenZip,
    /// RAR.
    Rar,
    /// tar.
    Tar,
    /// OLE2 (legacy .doc/.xls/.ppt, .msi).
    Ole2,
    /// ELF.
    Elf,
    /// PE/DOS (Windows).
    Pe,
    /// Mach-O.
    MachO,
    /// WebAssembly.
    Wasm,
    /// Java class.
    JavaClass,
    /// SQLite.
    Sqlite,
    /// Apple disk image (UDIF, `.dmg`): recognized by its trailer ([`is_udif`]), not by the first bytes. macOS mounts
    /// it, and it can hold apps and installers; the contents are not inspected and there is no preview.
    Dmg,
    /// Unknown binary.
    Unknown,
}

impl Kind {
    /// MIME.
    pub fn mime(self) -> &'static str {
        use Kind::*;
        match self {
            Empty => "application/x-empty",
            Text => "text/plain",
            Html => "text/html",
            Xml => "application/xml",
            Svg => "image/svg+xml",
            Rtf => "application/rtf",
            Script => "text/x-script",
            Pdf => "application/pdf",
            Png => "image/png",
            Jpeg => "image/jpeg",
            Gif => "image/gif",
            Webp => "image/webp",
            Bmp => "image/bmp",
            Ico => "image/vnd.microsoft.icon",
            Tiff => "image/tiff",
            Zip => "application/zip",
            Docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            Xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            Pptx => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            Odf => "application/vnd.oasis.opendocument",
            Jar => "application/java-archive",
            Apk => "application/vnd.android.package-archive",
            Gzip => "application/gzip",
            Bzip2 => "application/x-bzip2",
            Xz => "application/x-xz",
            Zstd => "application/zstd",
            SevenZip => "application/x-7z-compressed",
            Rar => "application/vnd.rar",
            Tar => "application/x-tar",
            Ole2 => "application/x-ole-storage",
            Elf => "application/x-elf",
            Pe => "application/vnd.microsoft.portable-executable",
            MachO => "application/x-mach-binary",
            Wasm => "application/wasm",
            JavaClass => "application/java-vm",
            Sqlite => "application/vnd.sqlite3",
            Dmg => "application/x-apple-diskimage",
            Unknown => "application/octet-stream",
        }
    }

    /// Executable code (machine code or bytecode).
    pub fn is_executable(self) -> bool {
        matches!(
            self,
            Kind::Elf
                | Kind::Pe
                | Kind::MachO
                | Kind::Wasm
                | Kind::JavaClass
                | Kind::Jar
                | Kind::Apk
        )
    }

    /// Native machine code the OS loads and runs: ELF, PE, Mach-O (D-130). Bytecode (WebAssembly, Java) needs a
    /// runtime and is not counted here.
    pub fn is_native_executable(self) -> bool {
        matches!(self, Kind::Elf | Kind::Pe | Kind::MachO)
    }

    /// A folder-like archive whose members decide what it is (D-130): ZIP, tar, gzip, and the formats the check does
    /// not open. OOXML/ODF/JAR/APK are ZIP inside, but a document or a program, not a folder.
    pub fn is_container(self) -> bool {
        matches!(
            self,
            Kind::Zip
                | Kind::Tar
                | Kind::Gzip
                | Kind::Bzip2
                | Kind::Xz
                | Kind::Zstd
                | Kind::SevenZip
                | Kind::Rar
        )
    }

    /// Archive or compressed stream.
    pub fn is_archive(self) -> bool {
        matches!(
            self,
            Kind::Zip
                | Kind::Jar
                | Kind::Apk
                | Kind::Gzip
                | Kind::Bzip2
                | Kind::Xz
                | Kind::Zstd
                | Kind::SevenZip
                | Kind::Rar
                | Kind::Tar
        )
    }

    /// ZIP family (OOXML, ODF, JAR, APK are ZIP too).
    pub fn is_zip_family(self) -> bool {
        matches!(
            self,
            Kind::Zip | Kind::Docx | Kind::Xlsx | Kind::Pptx | Kind::Odf | Kind::Jar | Kind::Apk
        )
    }

    /// Raster image that gets redrawn into PNG.
    pub fn is_raster_image(self) -> bool {
        matches!(
            self,
            Kind::Png | Kind::Jpeg | Kind::Gif | Kind::Webp | Kind::Bmp | Kind::Ico
        )
    }

    /// Text type (shown as text).
    pub fn is_text(self) -> bool {
        matches!(
            self,
            Kind::Text | Kind::Html | Kind::Xml | Kind::Svg | Kind::Rtf | Kind::Script
        )
    }

    /// Extensions that honestly match the type (lowercase, without the dot). Empty means any.
    pub fn extensions(self) -> &'static [&'static str] {
        use Kind::*;
        match self {
            Png => &["png"],
            Jpeg => &["jpg", "jpeg", "jpe", "jfif"],
            Gif => &["gif"],
            Webp => &["webp"],
            Bmp => &["bmp", "dib"],
            Ico => &["ico", "cur"],
            Tiff => &["tif", "tiff"],
            Pdf => &["pdf"],
            Docx => &["docx", "docm", "dotx", "dotm"],
            Xlsx => &["xlsx", "xlsm", "xltx", "xltm"],
            Pptx => &["pptx", "pptm", "potx", "ppsx"],
            Odf => &["odt", "ods", "odp", "odg", "ott"],
            Dmg => &["dmg"],
            _ => &[],
        }
    }
}

/// Detects the type from the first bytes (the first 8 KiB are enough).
pub fn sniff(head: &[u8]) -> Kind {
    let s = |sig: &[u8]| head.starts_with(sig);
    if head.is_empty() {
        return Kind::Empty;
    }
    if s(b"\x89PNG\r\n\x1a\n") {
        return Kind::Png;
    }
    if s(b"\xFF\xD8\xFF") {
        return Kind::Jpeg;
    }
    if s(b"GIF87a") || s(b"GIF89a") {
        return Kind::Gif;
    }
    if s(b"RIFF") && head.len() >= 12 && &head[8..12] == b"WEBP" {
        return Kind::Webp;
    }
    if s(b"BM") && head.len() >= 18 {
        let dib = u32::from_le_bytes([head[14], head[15], head[16], head[17]]);
        if matches!(dib, 12 | 40 | 52 | 56 | 64 | 108 | 124) {
            return Kind::Bmp;
        }
    }
    if s(b"\x00\x00\x01\x00") && head.len() >= 6 && u16::from_le_bytes([head[4], head[5]]) > 0 {
        return Kind::Ico;
    }
    if s(b"II*\x00") || s(b"MM\x00*") {
        return Kind::Tiff;
    }
    if s(b"%PDF-") {
        return Kind::Pdf;
    }
    if s(b"PK\x03\x04") || s(b"PK\x05\x06") {
        return Kind::Zip; // refined from the file list (`refine_zip`)
    }
    if s(b"\x1F\x8B") {
        return Kind::Gzip;
    }
    if s(b"BZh") && head.len() >= 4 && head[3].is_ascii_digit() {
        return Kind::Bzip2;
    }
    if s(b"\xFD7zXZ\x00") {
        return Kind::Xz;
    }
    if s(b"\x28\xB5\x2F\xFD") {
        return Kind::Zstd;
    }
    if s(b"7z\xBC\xAF\x27\x1C") {
        return Kind::SevenZip;
    }
    if s(b"Rar!\x1A\x07") {
        return Kind::Rar;
    }
    if head.len() >= 262 && &head[257..262] == b"ustar" {
        return Kind::Tar;
    }
    if s(b"\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1") {
        return Kind::Ole2;
    }
    if s(b"\x7FELF") {
        return Kind::Elf;
    }
    if s(b"MZ") {
        return Kind::Pe;
    }
    if s(b"\xFE\xED\xFA\xCE")
        || s(b"\xFE\xED\xFA\xCF")
        || s(b"\xCE\xFA\xED\xFE")
        || s(b"\xCF\xFA\xED\xFE")
    {
        return Kind::MachO;
    }
    if s(b"\xCA\xFE\xBA\xBE") && head.len() >= 8 {
        // Fat Mach-O: the number of architectures is small (as in file(1): < 20); Java class: minor ‖ major ≥ 45.
        let n = u32::from_be_bytes([head[4], head[5], head[6], head[7]]);
        return if n < 20 { Kind::MachO } else { Kind::JavaClass };
    }
    if s(b"\x00asm") {
        return Kind::Wasm;
    }
    if s(b"SQLite format 3\x00") {
        return Kind::Sqlite;
    }
    if s(b"{\\rtf") {
        return Kind::Rtf;
    }
    if let Some(text) = as_text_head(head) {
        let t = text.trim_start_matches('\u{FEFF}').trim_start();
        let lower: String = t.chars().take(1024).collect::<String>().to_lowercase();
        if t.starts_with("#!") {
            return Kind::Script;
        }
        if lower.contains("<svg") {
            return Kind::Svg;
        }
        if lower.starts_with("<!doctype html")
            || lower.starts_with("<html")
            || lower.contains("<script")
        {
            return Kind::Html;
        }
        if lower.starts_with("<?xml") {
            return Kind::Xml;
        }
        return Kind::Text;
    }
    Kind::Unknown
}

/// The start of the file as text: UTF-8 (a truncated last character is allowed) or UTF-16 with a BOM; no NUL and
/// almost no control characters.
pub fn as_text_head(head: &[u8]) -> Option<String> {
    if head.starts_with(b"\xFF\xFE") || head.starts_with(b"\xFE\xFF") {
        return Some(decode_utf16(head));
    }
    let valid = match std::str::from_utf8(head) {
        Ok(s) => s,
        Err(e) if e.error_len().is_none() => std::str::from_utf8(&head[..e.valid_up_to()]).ok()?,
        Err(_) => return None,
    };
    let control = valid
        .chars()
        .filter(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t' | '\x0C'))
        .count();
    if valid.contains('\0') || control * 100 > valid.len().max(1) {
        return None;
    }
    Some(valid.to_string())
}

/// UTF-16 with a BOM → String (broken pairs replaced).
pub fn decode_utf16(b: &[u8]) -> String {
    let be = b.starts_with(b"\xFE\xFF");
    let units = b[2.min(b.len())..].as_chunks::<2>().0.iter().map(|p| {
        if be {
            u16::from_be_bytes(*p)
        } else {
            u16::from_le_bytes(*p)
        }
    });
    char::decode_utf16(units)
        .map(|r| r.unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect()
}

/// Size of the UDIF trailer (the `koly` block).
pub const UDIF_TRAILER: usize = 512;

/// The file ends with a UDIF trailer: the 512-byte `koly` block (version 4, header size 512, big-endian) that macOS
/// reads a disk image from. `tail` is the end of the file (at least [`UDIF_TRAILER`] bytes for a match).
pub fn is_udif(tail: &[u8]) -> bool {
    let Some(start) = tail.len().checked_sub(UDIF_TRAILER) else {
        return false;
    };
    let k = &tail[start..];
    k.starts_with(b"koly") && k[4..8] == 4u32.to_be_bytes() && k[8..12] == 512u32.to_be_bytes()
}

/// Refines the type from the end of the file: a UDIF disk image starts with whatever its first block holds (raw
/// sectors, zlib or bzip2 data), so only a start that is not a recognized format becomes [`Kind::Dmg`]. A recognized
/// format that also ends with a UDIF trailer stays what it is, and [`polyglot_findings`] reports it.
pub fn refine_by_tail(kind: Kind, tail: &[u8]) -> Kind {
    if matches!(kind, Kind::Unknown | Kind::Bzip2) && is_udif(tail) {
        Kind::Dmg
    } else {
        kind
    }
}

/// Refines a ZIP type from the file names inside (OOXML, ODF, JAR, APK).
pub fn refine_zip(names: &[String], mimetype_entry: Option<&str>) -> Kind {
    let has = |p: &str| names.iter().any(|n| n == p);
    let prefix = |p: &str| names.iter().any(|n| n.starts_with(p));
    if let Some(m) = mimetype_entry
        && m.starts_with("application/vnd.oasis.opendocument")
    {
        return Kind::Odf;
    }
    if has("[Content_Types].xml") {
        if prefix("word/") {
            return Kind::Docx;
        }
        if prefix("xl/") {
            return Kind::Xlsx;
        }
        if prefix("ppt/") {
            return Kind::Pptx;
        }
    }
    if has("AndroidManifest.xml") && prefix("classes") {
        return Kind::Apk;
    }
    if has("META-INF/MANIFEST.MF") && names.iter().any(|n| n.ends_with(".class")) {
        return Kind::Jar;
    }
    Kind::Zip
}

/// The extension of a file name, lowercase, without the dot (empty when there is none).
fn ext_lower(name: &str) -> String {
    name.rsplit('/')
        .next()
        .and_then(|n| n.rsplit_once('.'))
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default()
}

/// Packages that install software when opened, recognized inside zip-based formats by their name (D-130).
const ZIP_PACKAGE_EXT: &[&str] = &[
    "ipa",
    "msix",
    "msixbundle",
    "appx",
    "appxbundle",
    "xapk",
    "apks",
    "aab",
];

/// Disk images and installers a system mounts or runs by their extension, whatever their first bytes look like
/// (D-130): only for content that is not otherwise recognized.
const INSTALLER_EXT: &[&str] = &[
    "dmg", "iso", "img", "pkg", "mpkg", "msi", "msp", "msm", "deb", "udeb", "rpm", "snap",
    "flatpak", "appimage", "vhd", "vhdx", "vmdk", "qcow2", "cab",
];

/// An installer, a package or a disk image (D-130), by its format first and by its name only when the content is not
/// recognized otherwise: xar (`.pkg`, `.xip`), RPM, squashfs (`.snap`), a cabinet, Debian packages (`ar` named
/// `.deb`), Windows Installer (OLE2 named `.msi`), zip-based app packages (`.ipa`, `.msix`, …), and unrecognized
/// content named as a disk image or installer. A name can only make a file count as an installer, never stop it.
/// `None` otherwise (Apple disk images and Android packages are their own [`Kind`]s).
pub fn installer_format(head: &[u8], kind: Kind, name: &str) -> Option<&'static str> {
    let ext = ext_lower(name);
    if head.starts_with(b"xar!") {
        return Some("xar package");
    }
    if head.starts_with(&[0xED, 0xAB, 0xEE, 0xDB]) {
        return Some("RPM package");
    }
    if head.starts_with(b"hsqs") || head.starts_with(b"sqsh") {
        return Some("squashfs image");
    }
    if head.starts_with(b"MSCF") {
        return Some("cabinet");
    }
    if head.starts_with(b"!<arch>\n") && matches!(ext.as_str(), "deb" | "udeb" | "ipk") {
        return Some("Debian package");
    }
    if kind == Kind::Ole2 && matches!(ext.as_str(), "msi" | "msp" | "msm") {
        return Some("Windows Installer package");
    }
    if kind.is_zip_family() && ZIP_PACKAGE_EXT.contains(&ext.as_str()) {
        return Some("app package");
    }
    if kind == Kind::Unknown && INSTALLER_EXT.contains(&ext.as_str()) {
        return Some("disk image or installer");
    }
    None
}

/// Extensions of code and markup: source code, scripts, styles, markup, config, notebooks (D-130).
const CODE_EXT: &[&str] = &[
    "js",
    "mjs",
    "cjs",
    "jsx",
    "ts",
    "tsx",
    "mts",
    "cts",
    "css",
    "scss",
    "sass",
    "less",
    "html",
    "htm",
    "xhtml",
    "vue",
    "svelte",
    "astro",
    "py",
    "pyi",
    "ipynb",
    "rb",
    "pl",
    "pm",
    "php",
    "sh",
    "bash",
    "zsh",
    "fish",
    "ps1",
    "psm1",
    "bat",
    "cmd",
    "vbs",
    "applescript",
    "lua",
    "go",
    "rs",
    "c",
    "h",
    "cc",
    "cpp",
    "cxx",
    "hpp",
    "hh",
    "m",
    "mm",
    "swift",
    "kt",
    "kts",
    "java",
    "scala",
    "groovy",
    "gradle",
    "cs",
    "fs",
    "fsx",
    "dart",
    "r",
    "jl",
    "ex",
    "exs",
    "erl",
    "hrl",
    "hs",
    "ml",
    "mli",
    "clj",
    "cljs",
    "elm",
    "zig",
    "nim",
    "sql",
    "graphql",
    "gql",
    "proto",
    "json",
    "jsonc",
    "json5",
    "yaml",
    "yml",
    "toml",
    "ini",
    "cfg",
    "conf",
    "env",
    "properties",
    "xml",
    "xsd",
    "xsl",
    "plist",
    "svg",
    "md",
    "mdx",
    "rst",
    "tex",
    "cmake",
    "mk",
    "make",
    "tf",
    "hcl",
    "nix",
    "dockerfile",
    "lock",
    "patch",
    "diff",
    "wat",
];

/// Well-known names of code and build files without an extension (D-130).
const CODE_NAMES: &[&str] = &[
    "makefile",
    "dockerfile",
    "containerfile",
    "gemfile",
    "rakefile",
    "podfile",
    "pipfile",
    "procfile",
    "justfile",
    "vagrantfile",
    "jenkinsfile",
    "brewfile",
    "build",
    "workspace",
];

/// A name that says code or markup (D-130): an extension of [`CODE_EXT`] or a name of [`CODE_NAMES`], ignoring case.
/// Used only together with text content: the name never makes binary content count as code.
pub fn is_code_name(name: &str) -> bool {
    let base = name.rsplit('/').next().unwrap_or(name).to_ascii_lowercase();
    CODE_NAMES.contains(&base.as_str()) || CODE_EXT.contains(&ext_lower(&base).as_str())
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn find_ci(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len())
        .position(|w| w.eq_ignore_ascii_case(needle))
}

/// PNG chunks that hold metadata the format defines: content credentials (C2PA, `caBX`), EXIF, an ICC profile.
const PNG_METADATA: &[&[u8; 4]] = &[b"caBX", b"eXIf", b"iCCP"];
/// The PNG text keyword of an XMP packet (`iTXt`, or in older writers `tEXt`/`zTXt`).
const PNG_XMP_KEYWORD: &[u8] = b"XML:com.adobe.xmp\0";
/// JPEG application segments that hold metadata, by marker and the identifier their payload starts with: JFIF, EXIF,
/// XMP and extended XMP, ICC, multi-picture, content credentials (C2PA in JUMBF, APP11 `JP`), Photoshop, Adobe.
const JPEG_METADATA: &[(u8, &[u8])] = &[
    (0xE0, b"JFIF\0"),
    (0xE0, b"JFXX\0"),
    (0xE1, b"Exif\0\0"),
    (0xE1, b"http://ns.adobe.com/xap/1.0/\0"),
    (0xE1, b"http://ns.adobe.com/xmp/extension/\0"),
    (0xE2, b"ICC_PROFILE\0"),
    (0xE2, b"MPF\0"),
    (0xEB, b"JP"),
    (0xED, b"Photoshop 3.0\0"),
    (0xEE, b"Adobe"),
];
/// WebP (RIFF) chunks that hold metadata: XMP, EXIF, an ICC profile, content credentials.
const WEBP_METADATA: &[&[u8; 4]] = &[b"XMP ", b"EXIF", b"ICCP", b"C2PA"];

/// Where the image format's own metadata lies in `head` (D-129): the data of PNG chunks for content credentials,
/// EXIF, ICC and XMP text, of JPEG application segments with a metadata identifier, of WebP metadata chunks. Parsed by
/// the container's own lengths, without decoding anything; it stops at the image data (PNG `IDAT`, JPEG start of
/// scan) and at the first length that does not fit. `complete`: `head` is the whole file, so a chunk that claims to
/// run past its end is not metadata but a broken file, and hides nothing; otherwise `head` is the start of a larger
/// file and the last chunk is taken to its end. A text chunk under another keyword, a comment, an unknown chunk, and
/// anything after the image's end stay outside: markup there is still read.
pub fn image_metadata(kind: Kind, head: &[u8], complete: bool) -> Vec<std::ops::Range<usize>> {
    let mut out = Vec::new();
    let fits =
        |a: usize, len: usize| !complete || a.checked_add(len).is_some_and(|e| e <= head.len());
    let clip = |a: usize, len: usize| a..a.saturating_add(len).min(head.len());
    match kind {
        Kind::Png => {
            let mut pos = 8usize;
            while let Some(h) = head.get(pos..pos + 8) {
                let len = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as usize;
                let ty = &h[4..8];
                let data = pos + 8;
                if ty == b"IDAT" || ty == b"IEND" || len > 1 << 31 || !fits(data, len) {
                    break;
                }
                let payload = head.get(data..).unwrap_or_default();
                let xmp = matches!(ty, b"iTXt" | b"tEXt" | b"zTXt")
                    && payload.starts_with(PNG_XMP_KEYWORD);
                if PNG_METADATA.iter().any(|m| *m == ty) || xmp {
                    out.push(clip(data, len));
                }
                let Some(next) = data.checked_add(len).and_then(|e| e.checked_add(4)) else {
                    break;
                };
                pos = next;
            }
        }
        Kind::Jpeg => {
            let mut pos = 2usize;
            while let Some(&[0xFF, m]) = head.get(pos..pos + 2) {
                match m {
                    // Fill bytes before a marker
                    0xFF => pos += 1,
                    // Markers without a length
                    0x01 | 0xD0..=0xD8 => pos += 2,
                    // Start of scan (entropy-coded data follows), end of image
                    0xDA | 0xD9 => break,
                    _ => {
                        let Some(l) = head.get(pos + 2..pos + 4) else {
                            break;
                        };
                        let len = u16::from_be_bytes([l[0], l[1]]) as usize;
                        if len < 2 || !fits(pos + 2, len) {
                            break;
                        }
                        let data = pos + 4;
                        let payload = head.get(data..).unwrap_or_default();
                        if JPEG_METADATA
                            .iter()
                            .any(|(mk, id)| *mk == m && payload.starts_with(id))
                        {
                            out.push(clip(data, len - 2));
                        }
                        pos += 2 + len;
                    }
                }
            }
        }
        Kind::Webp => {
            let mut pos = 12usize;
            while let Some(h) = head.get(pos..pos + 8) {
                let len = u32::from_le_bytes([h[4], h[5], h[6], h[7]]) as usize;
                let data = pos + 8;
                if !fits(data, len) {
                    break;
                }
                if WEBP_METADATA.iter().any(|m| m[..] == h[..4]) {
                    out.push(clip(data, len));
                }
                let Some(next) = data.checked_add(len).and_then(|e| e.checked_add(len & 1)) else {
                    break;
                };
                pos = next;
            }
        }
        _ => {}
    }
    out
}

/// `bytes` with the metadata ranges blanked out.
fn without(bytes: &[u8], ranges: &[std::ops::Range<usize>]) -> Vec<u8> {
    let mut v = bytes.to_vec();
    for r in ranges {
        let (a, b) = (r.start.min(v.len()), r.end.min(v.len()));
        v[a..b].fill(0);
    }
    v
}

/// Polyglot indicators: the file also parses as another format (SPEC §10 step 3, §15).
///
/// `head` is the start of the file (up to 8 KiB), `tail` is the end (up to 64 KiB + 22), `whole` is the whole file if
/// it is fully in memory.
pub fn polyglot_findings(
    kind: Kind,
    head: &[u8],
    tail: &[u8],
    whole: Option<&[u8]>,
) -> Vec<Finding> {
    let mut out = Vec::new();
    let head1k = &head[..head.len().min(1024)];
    // PDF readers look for `%PDF-` in the first 1024 bytes.
    if kind != Kind::Pdf
        && let Some(off) = find(head1k, b"%PDF-")
    {
        out.push(Finding::new(
            "polyglot_pdf_header",
            Severity::Threat,
            format!("{} file also has a PDF header at offset {off}", kind.mime()),
        ));
    }
    // ZIP is read from the end: the end of central directory record is in the last 64 KiB.
    if !kind.is_zip_family() && find(tail, b"PK\x05\x06").is_some() {
        out.push(Finding::new(
            "polyglot_zip_trailer",
            Severity::Threat,
            format!(
                "{} file also ends with a ZIP central directory",
                kind.mime()
            ),
        ));
    }
    // macOS mounts a disk image by its trailer, whatever the start of the file says.
    if kind != Kind::Dmg && is_udif(tail) {
        out.push(Finding::new(
            "polyglot_dmg_trailer",
            Severity::Threat,
            format!(
                "{} file also ends with an Apple disk image (UDIF) trailer",
                kind.mime()
            ),
        ));
    }
    // Browsers sniff HTML from the first 512–1024 bytes. An image's own metadata is not read here: XMP is XML and
    // content credentials (C2PA) carry text by design (generated images have both near the start), no browser takes a
    // file that starts with an image signature for HTML, and the preview is rebuilt from pixels without any of it.
    // The PDF check above reads the raw bytes: a PDF reader looks for its header wherever it lies.
    if !kind.is_text() {
        let seen = without(
            head1k,
            &image_metadata(kind, whole.unwrap_or(head), whole.is_some()),
        );
        for tag in [
            &b"<script"[..],
            b"<html",
            b"<iframe",
            b"<svg",
            b"<body",
            b"javascript:",
        ] {
            if find_ci(&seen, tag).is_some() {
                out.push(Finding::new(
                    "polyglot_html",
                    Severity::Threat,
                    format!(
                        "binary {} file contains HTML/script markup in its first 1 KiB",
                        kind.mime()
                    ),
                ));
                break;
            }
        }
    }
    // Data after the logical end of the format.
    if let Some(data) = whole {
        match kind {
            Kind::Png => match png_trailing(data) {
                Some(0) => {}
                Some(n) => out.push(Finding::new(
                    "trailing_data",
                    Severity::Warn,
                    format!("{n} bytes after the PNG IEND chunk"),
                )),
                None => out.push(Finding::new(
                    "malformed_png",
                    Severity::Warn,
                    "PNG chunk structure is broken",
                )),
            },
            Kind::Gif => {
                if data.last() != Some(&0x3B) {
                    out.push(Finding::new(
                        "trailing_data",
                        Severity::Warn,
                        "GIF does not end with the trailer byte",
                    ));
                }
            }
            Kind::Jpeg => {
                let end = data.len() - data.iter().rev().take_while(|b| **b == 0).count();
                if end < 2 || &data[end - 2..end] != b"\xFF\xD9" {
                    out.push(Finding::new(
                        "trailing_data",
                        Severity::Warn,
                        "JPEG does not end with EOI",
                    ));
                }
            }
            Kind::Pdf => {
                let t = &data[data.len().saturating_sub(1024)..];
                if find(t, b"%%EOF").is_none() {
                    out.push(Finding::new(
                        "trailing_data",
                        Severity::Warn,
                        "no %%EOF in the last 1 KiB of the PDF",
                    ));
                }
            }
            _ => {}
        }
    }
    out
}

/// How many bytes follow the PNG IEND chunk; `None` means the chunk structure is broken.
fn png_trailing(data: &[u8]) -> Option<usize> {
    let mut pos = 8usize;
    loop {
        let len = u32::from_be_bytes(data.get(pos..pos + 4)?.try_into().ok()?) as usize;
        let ty = data.get(pos + 4..pos + 8)?;
        let end = pos.checked_add(12)?.checked_add(len)?;
        if end > data.len() {
            return None;
        }
        if ty == b"IEND" {
            return Some(data.len() - end);
        }
        pos = end;
    }
}

/// The type promised by the name's extension (to compare with the content).
fn kind_for_ext(ext: &str) -> Option<Kind> {
    use Kind::*;
    Some(match ext {
        "png" => Png,
        "jpg" | "jpeg" | "jpe" | "jfif" => Jpeg,
        "gif" => Gif,
        "webp" => Webp,
        "bmp" | "dib" => Bmp,
        "ico" | "cur" => Ico,
        "tif" | "tiff" => Tiff,
        "pdf" => Pdf,
        "docx" | "docm" | "dotx" | "dotm" => Docx,
        "xlsx" | "xlsm" | "xltx" | "xltm" => Xlsx,
        "pptx" | "pptm" | "potx" | "ppsx" => Pptx,
        "odt" | "ods" | "odp" | "odg" | "ott" => Odf,
        "zip" => Zip,
        "gz" | "tgz" => Gzip,
        "tar" => Tar,
        "svg" => Svg,
        "dmg" => Dmg,
        _ => return None,
    })
}

/// The name's extension does not match the content: an executable/script posing as a document is a threat, anything
/// else is a risk. Unrecognized binary content is a risk (it has no safe preview, and the agent cannot see what it is).
pub fn extension_findings(kind: Kind, declared_name: &str) -> Vec<Finding> {
    let mut out = Vec::new();
    let ext = declared_name
        .rsplit_once('.')
        .map(|(_, e)| e.to_lowercase())
        .unwrap_or_default();
    let doc_like = [
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "txt", "md", "csv", "doc", "docx",
        "xls", "xlsx", "ppt", "pptx", "odt", "rtf", "html", "json", "zip", "mp4", "mp3", "mov",
    ];
    if (kind.is_executable() || kind == Kind::Script) && doc_like.contains(&ext.as_str()) {
        out.push(Finding::new(
            "disguised_executable",
            Severity::Threat,
            format!("content is {} but the name says .{ext}", kind.mime()),
        ));
    } else if let Some(expected) = kind_for_ext(&ext)
        && expected != kind
        && !(expected == Kind::Zip && kind.is_zip_family())
    {
        out.push(Finding::new(
            "extension_mismatch",
            Severity::Warn,
            format!("content is {} but the name says .{ext}", kind.mime()),
        ));
    }
    if kind.is_executable() {
        out.push(Finding::new(
            "executable",
            Severity::Warn,
            format!("executable code ({})", kind.mime()),
        ));
    }
    if kind == Kind::Unknown {
        out.push(Finding::new(
            "unknown_type",
            Severity::Warn,
            "content type is not recognized: no checks by format and no safe preview",
        ));
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn signatures() {
        assert_eq!(sniff(b""), Kind::Empty);
        assert_eq!(sniff(b"\x89PNG\r\n\x1a\nxxxx"), Kind::Png);
        assert_eq!(sniff(b"%PDF-1.7\n"), Kind::Pdf);
        assert_eq!(sniff(b"\x7FELF\x02\x01"), Kind::Elf);
        assert_eq!(sniff(b"MZ\x90\x00"), Kind::Pe);
        assert_eq!(sniff(b"#!/bin/sh\nrm -rf ~\n"), Kind::Script);
        assert_eq!(
            sniff(b"<?xml version=\"1.0\"?><svg xmlns=\"\"/>"),
            Kind::Svg
        );
        assert_eq!(sniff(b"  <!DOCTYPE html><html>"), Kind::Html);
        assert_eq!(sniff("γεια σου, κόσμε\n".as_bytes()), Kind::Text);
        assert_eq!(sniff(b"\xFF\xFEh\x00i\x00"), Kind::Text);
        assert_eq!(sniff(b"\x00\x01\x02\x03\x04"), Kind::Unknown);
        assert_eq!(sniff(b"\xCA\xFE\xBA\xBE\x00\x00\x00\x34"), Kind::JavaClass);
        assert_eq!(sniff(b"\xCA\xFE\xBA\xBE\x00\x00\x00\x02"), Kind::MachO);
    }

    /// A UDIF trailer as `hdiutil` writes it: `koly`, version 4, header size 512, the rest of the block.
    fn koly() -> Vec<u8> {
        let mut k = vec![0u8; UDIF_TRAILER];
        k[..4].copy_from_slice(b"koly");
        k[4..8].copy_from_slice(&4u32.to_be_bytes());
        k[8..12].copy_from_slice(&512u32.to_be_bytes());
        k
    }

    #[test]
    fn disk_images_by_their_trailer() {
        // A compressed (UDZO) image: zlib blocks, then the trailer.
        let mut dmg = b"x\xda\x01\x02\x03\x04".to_vec();
        dmg.extend_from_slice(&[0x5A; 4096]);
        dmg.extend_from_slice(&koly());
        assert_eq!(sniff(&dmg[..64]), Kind::Unknown);
        assert!(is_udif(&dmg));
        assert_eq!(refine_by_tail(Kind::Unknown, &dmg), Kind::Dmg);
        assert_eq!(Kind::Dmg.mime(), "application/x-apple-diskimage");
        // A bzip2 (UDBZ) image starts like a bzip2 stream.
        let mut udbz = b"BZh91AY&SY".to_vec();
        udbz.extend_from_slice(&koly());
        assert_eq!(refine_by_tail(sniff(&udbz), &udbz), Kind::Dmg);
        // The block must be the very end, with the right version and size.
        let mut shifted = dmg.clone();
        shifted.push(0);
        assert!(!is_udif(&shifted));
        let mut v3 = dmg.clone();
        let n = v3.len();
        v3[n - 512 + 7] = 3;
        assert!(!is_udif(&v3));
        assert!(!is_udif(b"koly"));
        // Not a disk image: unknown stays unknown.
        assert_eq!(refine_by_tail(Kind::Unknown, &[0x5A; 4096]), Kind::Unknown);
        // The verdict stays conservative: no "unknown type", but no free pass either.
        let f = extension_findings(Kind::Dmg, "Antenna.dmg");
        assert!(f.is_empty(), "{f:?}");
        assert_eq!(
            extension_findings(Kind::Dmg, "photo.png")[0].code,
            "extension_mismatch"
        );
        assert!(polyglot_findings(Kind::Dmg, &dmg[..64], &dmg, Some(&dmg)).is_empty());
    }

    #[test]
    fn a_recognized_file_with_a_disk_image_trailer_is_a_polyglot() {
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend_from_slice(&[0, 0, 0, 0]);
        png.extend_from_slice(b"IEND");
        png.extend_from_slice(&[0xAE, 0x42, 0x60, 0x82]);
        png.extend_from_slice(&koly());
        assert_eq!(refine_by_tail(Kind::Png, &png), Kind::Png);
        let f = polyglot_findings(Kind::Png, &png, &png, Some(&png));
        assert!(
            f.iter()
                .any(|f| f.code == "polyglot_dmg_trailer" && f.severity == Severity::Threat),
            "{f:?}"
        );
    }

    #[test]
    fn polyglots() {
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend_from_slice(&[0, 0, 0, 0]);
        png.extend_from_slice(b"IEND");
        png.extend_from_slice(&[0xAE, 0x42, 0x60, 0x82]);
        assert!(polyglot_findings(Kind::Png, &png, &png, Some(&png)).is_empty());
        let mut with_zip = png.clone();
        with_zip.extend_from_slice(b"PK\x05\x06\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0");
        let f = polyglot_findings(Kind::Png, &with_zip, &with_zip, Some(&with_zip));
        assert!(
            f.iter()
                .any(|f| f.code == "polyglot_zip_trailer" && f.severity == Severity::Threat)
        );
        assert!(f.iter().any(|f| f.code == "trailing_data"));
        let jpeg_pdf = b"\xFF\xD8\xFF\xE0garbage %PDF-1.4 obj".to_vec();
        assert!(
            polyglot_findings(Kind::Jpeg, &jpeg_pdf, &jpeg_pdf, None)
                .iter()
                .any(|f| f.code == "polyglot_pdf_header")
        );
        let gif_html = b"GIF89a<script>alert(1)</script>".to_vec();
        assert!(
            polyglot_findings(Kind::Gif, &gif_html, &gif_html, None)
                .iter()
                .any(|f| f.code == "polyglot_html")
        );
    }

    /// A PNG chunk with its CRC (the CRC-32 of gzip, which is PNG's).
    fn png_chunk(ty: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut c = (data.len() as u32).to_be_bytes().to_vec();
        c.extend_from_slice(ty);
        c.extend_from_slice(data);
        let mut crc = flate2::Crc::new();
        crc.update(ty);
        crc.update(data);
        c.extend_from_slice(&crc.sum().to_be_bytes());
        c
    }

    /// A PNG as image generators write it (D-129): IHDR, then an XMP packet in `iTXt` and content credentials in
    /// `caBX` before the image data. The metadata here carries markup on purpose, so that the old check flags it.
    pub(crate) fn generated_png(extra: &[Vec<u8>]) -> Vec<u8> {
        let mut p = b"\x89PNG\r\n\x1a\n".to_vec();
        let mut ihdr = 1u32.to_be_bytes().to_vec();
        ihdr.extend_from_slice(&1u32.to_be_bytes());
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
        p.extend(png_chunk(b"IHDR", &ihdr));
        // Extra chunks right after the header, within the first KiB a browser sniffs
        for e in extra {
            p.extend_from_slice(e);
        }
        let mut xmp = PNG_XMP_KEYWORD.to_vec();
        xmp.extend_from_slice(b"\0\0\0\0<?xpacket begin=''?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF>\
            <rdf:Description dc:description='an icon &lt;svg&gt;'><dc:source><svg viewBox='0 0 1 1'/></dc:source>\
            </rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>");
        p.extend(png_chunk(b"iTXt", &xmp));
        let mut jumbf = b"\x00\x00\x00\x20jumb\x00\x00\x00\x18jumdc2pa\x00\x11\x00\x10\x80\x00\xaa\x00\x38\x9b\x71c2pa\0"
            .to_vec();
        jumbf.extend_from_slice(b"{\"title\":\"AppIcon.png\",\"actions\":[{\"action\":\"c2pa.created\"}],\"note\":\"<html><body>\"}");
        jumbf.extend(vec![0x5Au8; 600]);
        p.extend(png_chunk(b"caBX", &jumbf));
        // One transparent pixel: a filter byte and RGBA zero, deflated
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        std::io::Write::write_all(&mut z, &[0, 0, 0, 0, 0]).unwrap();
        p.extend(png_chunk(b"IDAT", &z.finish().unwrap()));
        p.extend(png_chunk(b"IEND", b""));
        p
    }

    fn html_polyglot(kind: Kind, data: &[u8]) -> bool {
        polyglot_findings(kind, &data[..data.len().min(8192)], data, Some(data))
            .iter()
            .any(|f| f.code == "polyglot_html")
    }

    /// The maintainer's ChatGPT icon (2026-10-06): `polyglot_html` came from the PNG's own metadata. XMP and content
    /// credentials are metadata now; markup in a chunk of another kind, or after the image's end, is still a threat.
    #[test]
    fn image_metadata_is_not_read_as_html() {
        let png = generated_png(&[]);
        assert!(png.len() > 1024 && find_ci(&png[..1024], b"<svg").is_some());
        assert_eq!(sniff(&png), Kind::Png);
        assert!(!html_polyglot(Kind::Png, &png), "XMP and C2PA are metadata");
        assert!(polyglot_findings(Kind::Png, &png, &png, Some(&png)).is_empty());
        // A text chunk that is HTML, under any other keyword: a polyglot as before
        let mut comment = b"Comment\0".to_vec();
        comment.extend_from_slice(b"<script>alert(1)</script>");
        let p = generated_png(&[png_chunk(b"tEXt", &comment)]);
        assert!(html_polyglot(Kind::Png, &p));
        // An unknown chunk with markup, and HTML right after IEND within the first KiB
        assert!(html_polyglot(
            Kind::Png,
            &generated_png(&[png_chunk(b"htMl", b"<html><body>")])
        ));
        let mut tiny = b"\x89PNG\r\n\x1a\n".to_vec();
        tiny.extend(png_chunk(b"IEND", b""));
        tiny.extend_from_slice(b"<html><script>alert(1)</script>");
        assert!(html_polyglot(Kind::Png, &tiny));
        // A caBX chunk that claims more than the file holds hides nothing
        for len in [u32::MAX, 4096] {
            let mut short = b"\x89PNG\r\n\x1a\n".to_vec();
            short.extend_from_slice(&len.to_be_bytes());
            short.extend_from_slice(b"caBX<html>");
            assert!(html_polyglot(Kind::Png, &short), "{len}");
        }
        // The start of a large file (not in memory whole): the last chunk read is taken to the end of what is there
        let big = generated_png(&[]);
        let cut = &big[..900];
        assert!(
            !polyglot_findings(Kind::Png, cut, cut, None)
                .iter()
                .any(|f| f.code == "polyglot_html")
        );
    }

    #[test]
    fn jpeg_and_webp_metadata_is_not_read_as_html() {
        let seg = |m: u8, payload: &[u8]| {
            let mut s = vec![0xFF, m];
            s.extend_from_slice(&((payload.len() + 2) as u16).to_be_bytes());
            s.extend_from_slice(payload);
            s
        };
        let mut xmp = b"http://ns.adobe.com/xap/1.0/\0".to_vec();
        xmp.extend_from_slice(b"<x:xmpmeta><svg/></x:xmpmeta>");
        let mut jpeg = vec![0xFF, 0xD8];
        jpeg.extend(seg(0xE0, b"JFIF\0\x01\x01\0\0\x01\0\x01\0\0"));
        jpeg.extend(seg(0xE1, &xmp));
        jpeg.extend(seg(0xEB, b"JP\0\x01<html>c2pa"));
        jpeg.extend_from_slice(&[0xFF, 0xDA, 0, 2, 0xFF, 0xD9]);
        assert!(
            !html_polyglot(Kind::Jpeg, &jpeg),
            "XMP and C2PA segments are metadata"
        );
        // A comment segment, or an application segment of no known kind, with markup: still a threat
        let mut com = vec![0xFF, 0xD8];
        com.extend(seg(0xFE, b"<script>alert(1)</script>"));
        assert!(html_polyglot(Kind::Jpeg, &com));
        let mut app = vec![0xFF, 0xD8];
        app.extend(seg(0xE1, b"<html><body>"));
        assert!(html_polyglot(Kind::Jpeg, &app));
        // WebP: XMP and EXIF chunks are metadata, another chunk is not
        let chunk = |t: &[u8; 4], d: &[u8]| {
            let mut c = t.to_vec();
            c.extend_from_slice(&(d.len() as u32).to_le_bytes());
            c.extend_from_slice(d);
            if d.len() % 2 == 1 {
                c.push(0);
            }
            c
        };
        let webp = |chunks: &[Vec<u8>]| {
            let body: Vec<u8> = chunks.concat();
            let mut w = b"RIFF".to_vec();
            w.extend_from_slice(&((body.len() + 4) as u32).to_le_bytes());
            w.extend_from_slice(b"WEBP");
            w.extend(body);
            w
        };
        let ok = webp(&[
            chunk(b"VP8X", &[0; 10]),
            chunk(b"XMP ", b"<x:xmpmeta><svg/></x:xmpmeta>"),
            chunk(b"EXIF", b"MM\0*<html>"),
        ]);
        assert_eq!(sniff(&ok), Kind::Webp);
        assert!(!html_polyglot(Kind::Webp, &ok));
        assert!(html_polyglot(
            Kind::Webp,
            &webp(&[chunk(b"VP8X", &[0; 10]), chunk(b"ABCD", b"<script>")])
        ));
    }

    #[test]
    fn disguised() {
        assert_eq!(
            extension_findings(Kind::Elf, "invoice.pdf")[0].code,
            "disguised_executable"
        );
        assert_eq!(
            extension_findings(Kind::Png, "photo.jpg")[0].code,
            "extension_mismatch"
        );
        assert!(extension_findings(Kind::Png, "photo.png").is_empty());
        assert!(extension_findings(Kind::Text, "notes").is_empty());
        assert_eq!(
            extension_findings(Kind::Text, "photo.png")[0].code,
            "extension_mismatch"
        );
        assert!(extension_findings(Kind::Docx, "a.zip").is_empty());
        assert_eq!(
            extension_findings(Kind::Unknown, "data.bin")[0].code,
            "unknown_type"
        );
    }
}
