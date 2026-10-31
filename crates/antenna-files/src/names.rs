// SPDX-License-Identifier: AGPL-3.0-only
//! File names (SPEC §10 "File names", §15 "Dangerous names, symlinks, auto-executed dot-files").
//!
//! A name from a contact is data, not a path: after normalization it is a single component without separators.
//! - NFC; empty, `.`, `..`, `/`, `\`, NUL: rejected; absolute paths and paths in general: rejected (separators are
//!   forbidden);
//! - control characters (C0, C1, DEL), bidi and zero-width characters (spoofing `txt.exe` → `exe.txt`): rejected;
//! - characters not allowed on Windows (`< > : " | ? *`), a trailing space/dot, reserved device names (`CON`, `PRN`,
//!   `AUX`, `NUL`, `COM0-9`, `LPT0-9`, `CONIN$`, `CONOUT$`, also with an extension: `con.txt`): rejected;
//! - longer than 255 bytes: rejected;
//! - case duplicates (`Report.pdf` when `report.pdf` exists): rejected at acceptance (`NAME_TAKEN`);
//! - dot files and names that tools execute by themselves (`.git`, `.github`, `.vscode`, `.claude`, `.cursor`,
//!   `.envrc`, `Makefile`, `package.json`…): only with a separate approval ([`is_special`]).
//!
//! Symlinks, hard links and special files do not arise when accepting a single file (the daemon writes a regular file
//! itself via `openat(O_NOFOLLOW | O_EXCL)`, see [`crate::accept`]); in archives such entries are check findings
//! (`crate::inspect`).

use unicode_normalization::UnicodeNormalization;

use crate::error::{Error, Result, code};

/// Name length limit (UTF-8 bytes), as on most file systems.
pub const MAX_NAME_BYTES: usize = 255;

fn bad(msg: &str) -> Error {
    Error::new(code::BAD_NAME, msg.to_string())
}

/// Looks like an emoji (Extended_Pictographic, approximated by blocks): ZWJ and variation selectors may follow it.
fn emoji_like(c: char) -> bool {
    matches!(
        c as u32,
        0x00A9 | 0x00AE | 0x203C | 0x2049 | 0x2122 | 0x2139 | 0x2194..=0x21FF | 0x2300..=0x23FF | 0x24C2
            | 0x25A0..=0x27BF | 0x2900..=0x297F | 0x2B00..=0x2BFF | 0x3030 | 0x303D | 0x3297 | 0x3299
            | 0x1F000..=0x1FAFF
    )
}

/// The character is forbidden in a name: control, invisible and formatting characters ([`crate::text::is_invisible`]:
/// bidi, zero width, tags, variation selectors, Hangul fillers…). Exception: emoji. ZWJ and variation selectors right
/// after an emoji (`❤️`, a ZWJ family) are part of the picture, not a way to hide text.
fn forbidden_at(chars: &[char], i: usize) -> bool {
    let c = chars[i];
    if c.is_control() {
        return true;
    }
    if !crate::text::is_invisible(c) {
        return false;
    }
    let joiner = matches!(c as u32, 0x200D | 0xFE0E | 0xFE0F);
    let prev_emoji = i > 0
        && (emoji_like(chars[i - 1]) || matches!(chars[i - 1] as u32, 0xFE0F | 0x1F3FB..=0x1F3FF));
    let next_emoji = chars.get(i + 1).is_some_and(|n| emoji_like(*n));
    !(joiner && prev_emoji && (c != '\u{200D}' || next_emoji))
}

const WINDOWS_RESERVED: &[&str] = &[
    "con", "prn", "aux", "nul", "conin$", "conout$", "com0", "com1", "com2", "com3", "com4",
    "com5", "com6", "com7", "com8", "com9", "com¹", "com²", "com³", "lpt0", "lpt1", "lpt2", "lpt3",
    "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", "lpt¹", "lpt²", "lpt³",
];

/// Normalizes a file name from a contact. Returns a safe single component in NFC or a `bad_file_name` error.
pub fn normalize(raw: &str) -> Result<String> {
    let name: String = raw.nfc().collect();
    if name.is_empty() {
        return Err(bad("empty name"));
    }
    if name == "." || name == ".." {
        return Err(bad("dot path component"));
    }
    if name.len() > MAX_NAME_BYTES {
        return Err(bad("name longer than 255 bytes"));
    }
    if name.contains(['/', '\\']) {
        return Err(bad("path separators are not allowed"));
    }
    let chars: Vec<char> = name.chars().collect();
    if (0..chars.len()).any(|i| forbidden_at(&chars, i)) {
        return Err(bad(
            "control, bidi or zero-width characters are not allowed",
        ));
    }
    if name.contains(['<', '>', ':', '"', '|', '?', '*']) {
        return Err(bad("characters not allowed on Windows"));
    }
    if name.ends_with([' ', '.']) || name.starts_with(' ') {
        return Err(bad("leading space or trailing space/dot"));
    }
    if name.starts_with('-') {
        // `-rf`, `--checkpoint-action=exec=…`: the name becomes a flag when the agent runs `tar`/`rm`/`grep *`
        // in the folder.
        return Err(bad("leading dash"));
    }
    let stem = name
        .split('.')
        .next()
        .unwrap_or("")
        .trim_end()
        .to_lowercase();
    if WINDOWS_RESERVED.contains(&stem.as_str()) {
        return Err(bad("reserved device name on Windows"));
    }
    if name.starts_with('~') && name.len() == 1 {
        return Err(bad("home directory shorthand"));
    }
    Ok(name)
}

/// Comparison key for case duplicates: NFKC + lowercase (Unicode), the way case-insensitive file systems (APFS, NTFS)
/// compare, with a margin.
pub fn fold_key(name: &str) -> String {
    name.nfkc().collect::<String>().to_lowercase()
}

/// Names (lowercase) that tools read or execute by themselves.
const AUTO_EXEC: &[&str] = &[
    // Build and tests
    "makefile",
    "gnumakefile",
    "justfile",
    "rakefile",
    "gemfile",
    "taskfile.yml",
    "taskfile.yaml",
    "package.json",
    "package-lock.json",
    "pnpm-workspace.yaml",
    "bunfig.toml",
    "deno.json",
    "deno.jsonc",
    "composer.json",
    "cargo.toml",
    "build.rs",
    "rust-toolchain",
    "rust-toolchain.toml",
    "setup.py",
    "setup.cfg",
    "pyproject.toml",
    "conftest.py",
    "noxfile.py",
    "tox.ini",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "gradlew",
    "pom.xml",
    "build.sbt",
    "cmakelists.txt",
    "meson.build",
    "build.zig",
    "directory.build.props",
    "directory.build.targets",
    "dockerfile",
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
    "vagrantfile",
    "flake.nix",
    "default.nix",
    "shell.nix",
    "mise.toml",
    // More build, package and CI files
    "podfile",
    "fastfile",
    "appfile",
    "pipfile",
    "sconstruct",
    "sconscript",
    "tiltfile",
    "containerfile",
    "build",
    "build.bazel",
    "workspace",
    "workspace.bazel",
    "module.bazel",
    "earthfile",
    "brewfile",
    "procfile",
    "sitecustomize.py",
    "usercustomize.py",
    "conanfile.py",
    "conanfile.txt",
    "karma.conf.js",
    "gulpfile.js",
    "gruntfile.js",
    "jakefile.js",
    "webpack.config.js",
    "vite.config.js",
    "vite.config.ts",
    "rollup.config.js",
    "jest.config.js",
    "vitest.config.ts",
    "babel.config.js",
    "eslint.config.js",
    ".eslintrc.js",
    "prettier.config.js",
    "tsconfig.json",
    "go.mod",
    "go.work",
    "mix.exs",
    "rebar.config",
    "stack.yaml",
    "package.yaml",
    "dune-project",
    "makefile.pl",
    "build.pl",
    "requirements.txt",
    "uv.toml",
    "poetry.lock",
    // Instructions for agents
    "claude.md",
    "claude.local.md",
    "agents.md",
    "agents.override.md",
    "gemini.md",
    "copilot-instructions.md",
    // OS autorun
    "desktop.ini",
    "autorun.inf",
];

/// Extensions of shortcuts, autorun entries and scripts that the OS executes on double click (the exec bit does not
/// matter there).
const AUTO_EXEC_EXT: &[&str] = &[
    ".desktop",
    ".lnk",
    ".url",
    ".scf",
    ".library-ms",
    ".webloc",
    ".fileloc",
    ".inetloc",
    ".terminal",
    ".command",
    ".bat",
    ".cmd",
    ".ps1",
    ".psm1",
    ".vbs",
    ".vbe",
    ".jse",
    ".wsf",
    ".wsh",
    ".hta",
    ".reg",
    ".scr",
    ".pif",
    ".msi",
    ".msc",
    ".exe",
    ".com",
    ".appref-ms",
    ".applescript",
    ".scpt",
];

/// Configs that bundlers and linters execute as code (`vite.config.ts`, `eslint.config.js`…).
fn is_config_code(l: &str) -> bool {
    [
        ".config.js",
        ".config.mjs",
        ".config.cjs",
        ".config.ts",
        ".config.mts",
        ".config.cts",
    ]
    .iter()
    .any(|e| l.ends_with(e))
}

/// The name needs a separate owner approval: a dot file/directory, an auto-executed or OS-executable name (SPEC §10).
pub fn is_special(name: &str) -> bool {
    let l = name.to_lowercase();
    l.starts_with('.')
        || AUTO_EXEC.contains(&l.as_str())
        || AUTO_EXEC_EXT.iter().any(|e| l.ends_with(e))
        || is_config_code(&l)
}

/// Checks a path inside an archive (for findings, not for acceptance): every component must pass [`normalize`].
/// Returns the reason if the path is dangerous.
pub fn archive_path_problem(path: &str) -> Option<&'static str> {
    if path.starts_with('/') || path.starts_with('\\') {
        return Some("absolute_path");
    }
    if path.len() >= 2 && path.as_bytes()[1] == b':' {
        return Some("absolute_path");
    }
    for comp in path.split(['/', '\\']) {
        if comp.is_empty() {
            continue; // "dir/" for directories
        }
        if comp == ".." {
            return Some("path_traversal");
        }
        if comp == "." {
            continue;
        }
        if normalize(comp).is_err() {
            return Some("bad_entry_name");
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dangerous_names_are_rejected() {
        for n in [
            "",
            ".",
            "..",
            "../etc/passwd",
            "/etc/passwd",
            "a/b",
            "a\\b",
            "C:\\x",
            "x\0y",
            "evil\u{202E}gnp.exe",
            "zero\u{200B}width",
            "line\nbreak",
            "CON",
            "con.txt",
            "Lpt1.log",
            "COM¹",
            "nul .txt",
            "trailing.",
            "trailing ",
            " leading",
            "what?.txt",
            "a:b",
            "~",
            "-rf",
            "--checkpoint-action=exec=sh x.sh",
            "a\u{2060}b",
            "tag\u{E0041}",
            "fill\u{3164}er",
            "soft\u{AD}hyphen",
            "emoji\u{FE0F}",
        ] {
            assert!(normalize(n).is_err(), "{n:?} must be rejected");
        }
        assert!(normalize(&"a".repeat(256)).is_err());
        assert!(normalize(&"a".repeat(255)).is_ok());
    }

    #[test]
    fn emoji_names_are_fine_but_hidden_joiners_are_not() {
        assert!(normalize("\u{2764}\u{FE0F} photo.jpg").is_ok());
        assert!(normalize("family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.png").is_ok());
        assert!(normalize("\u{1F44D}\u{1F3FD} ok.txt").is_ok());
        assert!(normalize("pay\u{200D}pal.txt").is_err());
        assert!(normalize("a\u{FE0F}b.txt").is_err());
        assert!(normalize("\u{1F468}\u{200D}x.txt").is_err());
    }

    #[test]
    fn nfc_and_ordinary_names() {
        // NFD (e + combining acute accent) → NFC (precomposed é)
        let nfd = "re\u{0301}sume\u{0301}.pdf";
        let n = normalize(nfd).unwrap();
        assert_eq!(n, "r\u{e9}sum\u{e9}.pdf");
        assert!(n.chars().count() < nfd.chars().count());
        for ok in [
            "report.pdf",
            "photo 2026-10-02.jpg",
            "a..b",
            "資料.txt",
            "console.log",
            "conx.txt",
        ] {
            assert_eq!(normalize(ok).unwrap(), ok);
        }
        assert_eq!(fold_key("Report.PDF"), fold_key("report.pdf"));
        assert_eq!(fold_key("ﬁle"), fold_key("FILE"));
    }

    #[test]
    fn special_names() {
        for s in [
            ".git",
            ".github",
            ".vscode",
            ".claude",
            ".cursor",
            ".envrc",
            "Makefile",
            "package.json",
            "CLAUDE.md",
            "evil.desktop",
        ] {
            assert!(is_special(s), "{s}");
        }
        for s in ["report.pdf", "make.txt", "packagejson.txt"] {
            assert!(!is_special(s), "{s}");
        }
    }

    #[test]
    fn archive_paths() {
        assert_eq!(
            archive_path_problem("../../.ssh/authorized_keys"),
            Some("path_traversal")
        );
        assert_eq!(archive_path_problem("a/../../b"), Some("path_traversal"));
        assert_eq!(archive_path_problem("/etc/passwd"), Some("absolute_path"));
        assert_eq!(archive_path_problem("C:/Windows/x"), Some("absolute_path"));
        assert_eq!(archive_path_problem("dir/con.txt"), Some("bad_entry_name"));
        assert_eq!(archive_path_problem("dir/sub/file.txt"), None);
        assert_eq!(archive_path_problem("dir/"), None);
    }
}
