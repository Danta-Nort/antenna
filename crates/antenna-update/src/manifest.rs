// SPDX-License-Identifier: AGPL-3.0-only
//! The release manifest `antenna-<version>-manifest.json` (`docs/UPDATES.md` §2).
//!
//! The signature covers the exact bytes of the file, so the JSON is never re-serialized for verification. Fields this
//! version does not know are ignored (a later release may add information); a change in what an existing field means
//! needs a new `format`. Platform fields (`os`, `arch`, `kind`) are strings: an asset for a platform this version does
//! not know (a future `windows`) is skipped instead of making the whole manifest unreadable.

use std::{io::Read, path::Path};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{Error, Result, Version, code, hex, is_hex};

/// `format` of this manifest version.
pub const FORMAT: &str = "antenna-release-manifest/1";
/// `product`.
pub const PRODUCT: &str = "antenna";
/// Largest manifest accepted.
pub const MAX_BYTES: usize = 64 * 1024;
/// Most assets in one manifest.
pub const MAX_ASSETS: usize = 64;
/// Largest asset.
pub const MAX_ASSET_SIZE: u64 = 4 << 30;

/// The release manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    /// [`FORMAT`].
    pub format: String,
    /// [`PRODUCT`].
    pub product: String,
    /// Release version (`0.1.0-preview.3`).
    pub version: String,
    /// `preview` or `stable`.
    pub channel: String,
    /// When the manifest was made, UTC, `YYYY-MM-DDTHH:MM:SSZ`.
    pub created: String,
    /// Build commit, as `antenna --version` prints it (hex, 7–40 characters).
    pub commit: String,
    /// Release files.
    pub assets: Vec<Asset>,
    /// The catalog of local models this release was built with (`packaging/models.json`'s `models`, D-104): the same
    /// list is compiled into its daemon, and the release tool checks the two are equal. Optional: older readers ignore
    /// it (§2 of `docs/UPDATES.md`), and this crate does not interpret it (`antenna_proto::models` does).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models: Vec<serde_json::Value>,
}

/// A release file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Asset {
    /// File name, as published (no directories).
    pub name: String,
    /// `macos` or `linux`.
    pub os: String,
    /// `arm64`, `x86_64` or `universal` (macOS only).
    pub arch: String,
    /// `app` (the window with the core inside) or `cli` (the CLI and the daemon only), installed by `antenna
    /// update`; or, installed by the system package manager instead (D-109, not a kind `antenna update` ever asks
    /// for): `deb_app`/`deb_cli`, `rpm_app`/`rpm_cli`.
    pub kind: String,
    /// Size in bytes.
    pub size: u64,
    /// SHA-256 of the file, lowercase hex (the same as in `SHA256SUMS.txt`).
    pub sha256: String,
    /// BLAKE3 of the file, lowercase hex (the hash Antenna's file transfer shows for a received file).
    pub blake3: String,
}

/// Where an update is installed: OS, architecture and kind of installation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Platform {
    /// `macos` / `linux`.
    pub os: &'static str,
    /// `arm64` / `x86_64`.
    pub arch: &'static str,
    /// `app` / `cli`.
    pub kind: &'static str,
}

impl Platform {
    /// The OS and architecture this binary was built for, with the given installation kind.
    pub fn this(kind: &'static str) -> Self {
        let os = std::env::consts::OS;
        let arch = match std::env::consts::ARCH {
            "aarch64" => "arm64",
            "x86_64" => "x86_64",
            other => other,
        };
        Self { os, arch, kind }
    }

    /// Whether an asset is for this platform (a universal macOS asset fits both Mac architectures).
    pub fn fits(&self, a: &Asset) -> bool {
        a.os == self.os
            && a.kind == self.kind
            && (a.arch == self.arch || (a.os == "macos" && a.arch == "universal"))
    }
}

impl std::fmt::Display for Platform {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} {} ({})", self.os, self.arch, self.kind)
    }
}

fn bad(msg: impl Into<String>) -> Error {
    Error::new(code::BAD_MANIFEST, msg)
}

/// A file name that is safe to join to a directory: no separators, no `..`, no hidden files, a short ASCII alphabet.
pub fn is_plain_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'+'))
}

fn is_utc_time(s: &str) -> bool {
    // YYYY-MM-DDTHH:MM:SSZ
    let b = s.as_bytes();
    b.len() == 20
        && b.iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b'T',
            13 | 16 => *c == b':',
            19 => *c == b'Z',
            _ => c.is_ascii_digit(),
        })
}

impl Manifest {
    /// Parses and validates the manifest bytes.
    pub fn parse(bytes: &[u8]) -> Result<(Self, Version)> {
        if bytes.len() > MAX_BYTES {
            return Err(bad(format!("manifest larger than {MAX_BYTES} bytes")));
        }
        let m: Manifest = serde_json::from_slice(bytes)
            .map_err(|e| bad(format!("manifest is not valid: {e}")))?;
        let v = m.validate()?;
        Ok((m, v))
    }

    /// Checks every field; returns the parsed version.
    pub fn validate(&self) -> Result<Version> {
        if self.format != FORMAT {
            return Err(bad(format!(
                "manifest format {:?} is not supported by this version (it reads {FORMAT})",
                self.format
            )));
        }
        if self.product != PRODUCT {
            return Err(bad(format!(
                "not an Antenna release (product {:?})",
                self.product
            )));
        }
        let v: Version = self.version.parse().map_err(|e| bad(format!("{e}")))?;
        match self.channel.as_str() {
            "preview" => {}
            "stable" if !v.is_prerelease() => {}
            "stable" => return Err(bad("a pre-release version cannot be on the stable channel")),
            other => return Err(bad(format!("unknown channel {other:?}"))),
        }
        if !is_utc_time(&self.created) {
            return Err(bad("created must look like 2026-10-03T12:00:00Z"));
        }
        if !(7..=40).contains(&self.commit.len())
            || !self
                .commit
                .bytes()
                .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Err(bad("commit must be lowercase hex, 7–40 characters"));
        }
        if self.assets.is_empty() || self.assets.len() > MAX_ASSETS {
            return Err(bad(format!("a release has 1–{MAX_ASSETS} assets")));
        }
        let marker = format!("-{}-", self.version);
        for (i, a) in self.assets.iter().enumerate() {
            if !is_plain_name(&a.name) || !a.name.contains(&marker) {
                return Err(bad(format!(
                    "asset name {:?} must be a plain file name containing {marker:?}",
                    a.name
                )));
            }
            if self.assets[..i].iter().any(|b| b.name == a.name) {
                return Err(bad(format!("asset {:?} is listed twice", a.name)));
            }
            if a.size == 0 || a.size > MAX_ASSET_SIZE {
                return Err(bad(format!("asset {:?}: bad size {}", a.name, a.size)));
            }
            if !is_hex(&a.sha256, 64) || !is_hex(&a.blake3, 64) {
                return Err(bad(format!(
                    "asset {:?}: sha256 and blake3 must be 64 lowercase hex characters",
                    a.name
                )));
            }
            for (what, s) in [("os", &a.os), ("arch", &a.arch), ("kind", &a.kind)] {
                if s.is_empty()
                    || s.len() > 32
                    || !s
                        .bytes()
                        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
                {
                    return Err(bad(format!("asset {:?}: bad {what} {s:?}", a.name)));
                }
            }
        }
        Ok(v)
    }

    /// The asset for this platform.
    pub fn asset_for(&self, p: &Platform) -> Result<&Asset> {
        let mut fit = self.assets.iter().filter(|a| p.fits(a));
        match (fit.next(), fit.next()) {
            (Some(a), None) => Ok(a),
            (Some(_), Some(_)) => Err(bad(format!(
                "the release lists more than one asset for {p}"
            ))),
            (None, _) => Err(Error::new(
                code::WRONG_PLATFORM,
                format!(
                    "release {} has no asset for {p} (it has: {})",
                    self.version,
                    self.assets
                        .iter()
                        .map(|a| format!("{} {} {}", a.os, a.arch, a.kind))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            )),
        }
    }

    /// Canonical bytes for a new manifest (pretty JSON with a final newline). Verification never uses this: it uses the
    /// bytes as published.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut b = serde_json::to_vec_pretty(self).expect("a manifest serializes");
        b.push(b'\n');
        b
    }
}

/// The manifest file name of a version.
pub fn manifest_name(version: &str) -> String {
    format!("antenna-{version}-manifest.json")
}

/// The detached signature file name of a version.
pub fn signature_name(version: &str) -> String {
    format!("{}.sig", manifest_name(version))
}

/// Platform of a release file by its name (the names `packaging/` produces), or `None` for files that are not assets
/// (`SHA256SUMS.txt`, `*.sha256`, the manifest and its signature).
pub fn classify_name(
    name: &str,
    version: &str,
) -> Option<(&'static str, &'static str, &'static str)> {
    let arch = |s: &str| -> Option<&'static str> {
        match s {
            "arm64" => Some("arm64"),
            "x86_64" => Some("x86_64"),
            "universal" => Some("universal"),
            _ => None,
        }
    };
    if let Some(rest) = name.strip_prefix(&format!("Antenna-{version}-macos-")) {
        return arch(rest.strip_suffix(".dmg")?).map(|a| ("macos", a, "app"));
    }
    if let Some(rest) = name.strip_prefix(&format!("antenna-{version}-macos-")) {
        return arch(rest.strip_suffix("-cli.tar.gz")?).map(|a| ("macos", a, "cli"));
    }
    // .deb and .rpm (D-109, WP11): not installed by `antenna update` (the system package manager does), so they get
    // their own kinds (`deb_app`/`deb_cli`, `rpm_app`/`rpm_cli`) instead of `app`/`cli`; an installer that resolves a
    // platform by (os, arch, kind) never asks for one of these, so there is no ambiguity with the archives above.
    if let Some(rest) = name.strip_prefix(&format!("antenna-desktop-{version}-linux-")) {
        if let Some(a) = rest.strip_suffix(".tar.gz") {
            return arch(a)
                .filter(|a| *a != "universal")
                .map(|a| ("linux", a, "app"));
        }
        if let Some(a) = rest.strip_suffix(".deb") {
            return arch(a)
                .filter(|a| *a != "universal")
                .map(|a| ("linux", a, "deb_app"));
        }
        if let Some(a) = rest.strip_suffix(".rpm") {
            return arch(a)
                .filter(|a| *a != "universal")
                .map(|a| ("linux", a, "rpm_app"));
        }
        return None;
    }
    if let Some(rest) = name.strip_prefix(&format!("antenna-{version}-linux-")) {
        if let Some(a) = rest.strip_suffix(".tar.gz") {
            return arch(a)
                .filter(|a| *a != "universal")
                .map(|a| ("linux", a, "cli"));
        }
        if let Some(a) = rest.strip_suffix(".deb") {
            return arch(a)
                .filter(|a| *a != "universal")
                .map(|a| ("linux", a, "deb_cli"));
        }
        if let Some(a) = rest.strip_suffix(".rpm") {
            return arch(a)
                .filter(|a| *a != "universal")
                .map(|a| ("linux", a, "rpm_cli"));
        }
        return None;
    }
    None
}

/// Size, SHA-256 and BLAKE3 of a file, in one pass.
pub fn hash_file(path: &Path) -> Result<(u64, String, String)> {
    let mut f = std::fs::File::open(path).map_err(|e| Error::io(path.display(), e))?;
    let mut sha = Sha256::new();
    let mut b3 = blake3::Hasher::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut size = 0u64;
    loop {
        let n = f.read(&mut buf).map_err(|e| Error::io(path.display(), e))?;
        if n == 0 {
            break;
        }
        sha.update(&buf[..n]);
        b3.update(&buf[..n]);
        size += n as u64;
    }
    Ok((size, hex(&sha.finalize()), hex(b3.finalize().as_bytes())))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn sample(version: &str) -> Manifest {
        Manifest {
            format: FORMAT.into(),
            product: PRODUCT.into(),
            version: version.into(),
            channel: if version.contains('-') {
                "preview"
            } else {
                "stable"
            }
            .into(),
            created: "2026-10-03T12:00:00Z".into(),
            commit: "0123456789ab".into(),
            assets: vec![
                Asset {
                    name: format!("Antenna-{version}-macos-arm64.dmg"),
                    os: "macos".into(),
                    arch: "arm64".into(),
                    kind: "app".into(),
                    size: 10,
                    sha256: "a".repeat(64),
                    blake3: "b".repeat(64),
                },
                Asset {
                    name: format!("antenna-{version}-linux-x86_64.tar.gz"),
                    os: "linux".into(),
                    arch: "x86_64".into(),
                    kind: "cli".into(),
                    size: 10,
                    sha256: "c".repeat(64),
                    blake3: "d".repeat(64),
                },
            ],
            models: Vec::new(),
        }
    }

    #[test]
    fn round_trip_and_unknown_fields() {
        let m = sample("0.1.0-preview.3");
        let (back, v) = Manifest::parse(&m.to_bytes()).unwrap();
        assert_eq!(back, m);
        assert_eq!(v.to_string(), "0.1.0-preview.3");
        // A later release may add fields; this version ignores them.
        let mut j: serde_json::Value = serde_json::from_slice(&m.to_bytes()).unwrap();
        j["notes_url"] = "https://example.com/notes".into();
        j["assets"][0]["signature_kind"] = "adhoc".into();
        assert!(Manifest::parse(&serde_json::to_vec(&j).unwrap()).is_ok());
        // A duplicated field is an error, not "the last one wins".
        let good = String::from_utf8(m.to_bytes()).unwrap();
        let dup = good.replacen('{', "{\"version\": \"9.9.9\",", 1);
        assert_eq!(
            Manifest::parse(dup.as_bytes()).unwrap_err().code,
            code::BAD_MANIFEST
        );
    }

    #[test]
    fn validation() {
        let check = |f: &dyn Fn(&mut Manifest)| {
            let mut m = sample("0.1.0-preview.3");
            f(&mut m);
            Manifest::parse(&m.to_bytes()).map(|_| ()).unwrap_err().code
        };
        assert_eq!(
            check(&|m| m.format = "antenna-release-manifest/2".into()),
            code::BAD_MANIFEST
        );
        assert_eq!(check(&|m| m.product = "other".into()), code::BAD_MANIFEST);
        assert_eq!(check(&|m| m.version = "0.1".into()), code::BAD_MANIFEST);
        assert_eq!(check(&|m| m.channel = "stable".into()), code::BAD_MANIFEST);
        assert_eq!(check(&|m| m.channel = "nightly".into()), code::BAD_MANIFEST);
        assert_eq!(
            check(&|m| m.created = "yesterday".into()),
            code::BAD_MANIFEST
        );
        assert_eq!(check(&|m| m.commit = "XYZ".into()), code::BAD_MANIFEST);
        assert_eq!(check(&|m| m.assets.clear()), code::BAD_MANIFEST);
        assert_eq!(
            check(&|m| m.assets[0].name = "../Antenna-0.1.0-preview.3-macos-arm64.dmg".into()),
            code::BAD_MANIFEST
        );
        assert_eq!(
            check(&|m| m.assets[0].name = ".Antenna-0.1.0-preview.3-macos-arm64.dmg".into()),
            code::BAD_MANIFEST
        );
        assert_eq!(
            check(&|m| m.assets[0].name = "Antenna-0.1.0-preview.2-macos-arm64.dmg".into()),
            code::BAD_MANIFEST
        );
        assert_eq!(
            check(&|m| m.assets[1].name = m.assets[0].name.clone()),
            code::BAD_MANIFEST
        );
        assert_eq!(check(&|m| m.assets[0].size = 0), code::BAD_MANIFEST);
        assert_eq!(
            check(&|m| m.assets[0].sha256 = "A".repeat(64)),
            code::BAD_MANIFEST
        );
        assert_eq!(
            check(&|m| m.assets[0].blake3 = "b".repeat(63)),
            code::BAD_MANIFEST
        );
        assert_eq!(
            check(&|m| m.assets[0].os = "mac os".into()),
            code::BAD_MANIFEST
        );
        let big = vec![b' '; MAX_BYTES + 1];
        assert_eq!(Manifest::parse(&big).unwrap_err().code, code::BAD_MANIFEST);
    }

    #[test]
    fn platform_selection() {
        let mut m = sample("0.1.0-preview.3");
        let mac = Platform {
            os: "macos",
            arch: "arm64",
            kind: "app",
        };
        let linux = Platform {
            os: "linux",
            arch: "x86_64",
            kind: "cli",
        };
        assert_eq!(
            m.asset_for(&mac).unwrap().name,
            "Antenna-0.1.0-preview.3-macos-arm64.dmg"
        );
        assert_eq!(
            m.asset_for(&linux).unwrap().name,
            "antenna-0.1.0-preview.3-linux-x86_64.tar.gz"
        );
        let intel = Platform {
            os: "macos",
            arch: "x86_64",
            kind: "app",
        };
        assert_eq!(m.asset_for(&intel).unwrap_err().code, code::WRONG_PLATFORM);
        let linux_arm = Platform {
            os: "linux",
            arch: "arm64",
            kind: "cli",
        };
        assert_eq!(
            m.asset_for(&linux_arm).unwrap_err().code,
            code::WRONG_PLATFORM
        );
        // A universal macOS build fits both Mac architectures; a future OS is skipped, not an error.
        m.assets[0].arch = "universal".into();
        m.assets.push(Asset {
            os: "windows".into(),
            name: "Antenna-0.1.0-preview.3-windows-x86_64.msi".into(),
            ..m.assets[1].clone()
        });
        assert!(Manifest::parse(&m.to_bytes()).is_ok());
        assert_eq!(m.asset_for(&intel).unwrap().arch, "universal");
        assert_eq!(m.asset_for(&mac).unwrap().arch, "universal");
    }

    #[test]
    fn release_file_names() {
        let v = "0.1.0-preview.3";
        assert_eq!(
            classify_name("Antenna-0.1.0-preview.3-macos-arm64.dmg", v),
            Some(("macos", "arm64", "app"))
        );
        assert_eq!(
            classify_name("antenna-0.1.0-preview.3-macos-arm64-cli.tar.gz", v),
            Some(("macos", "arm64", "cli"))
        );
        assert_eq!(
            classify_name("antenna-0.1.0-preview.3-linux-x86_64.tar.gz", v),
            Some(("linux", "x86_64", "cli"))
        );
        assert_eq!(
            classify_name("antenna-desktop-0.1.0-preview.3-linux-x86_64.tar.gz", v),
            Some(("linux", "x86_64", "app"))
        );
        // D-109: .deb and .rpm packages, with their own kinds (never installed by `antenna update`).
        assert_eq!(
            classify_name("antenna-0.1.0-preview.3-linux-x86_64.deb", v),
            Some(("linux", "x86_64", "deb_cli"))
        );
        assert_eq!(
            classify_name("antenna-0.1.0-preview.3-linux-arm64.rpm", v),
            Some(("linux", "arm64", "rpm_cli"))
        );
        assert_eq!(
            classify_name("antenna-desktop-0.1.0-preview.3-linux-x86_64.deb", v),
            Some(("linux", "x86_64", "deb_app"))
        );
        assert_eq!(
            classify_name("antenna-desktop-0.1.0-preview.3-linux-x86_64.rpm", v),
            Some(("linux", "x86_64", "rpm_app"))
        );
        for not_asset in [
            "SHA256SUMS.txt",
            "antenna-0.1.0-preview.3-manifest.json",
            "antenna-0.1.0-preview.3-manifest.json.sig",
            "Antenna-0.1.0-preview.3-macos-arm64.dmg.sha256",
            "Antenna-0.1.0-preview.2-macos-arm64.dmg",
            "antenna-0.1.0-preview.3-linux-universal.tar.gz",
            "antenna-0.1.0-preview.3-linux-riscv64.tar.gz",
            "antenna-0.1.0-preview.3-linux-universal.deb",
            "antenna-0.1.0-preview.3-linux-riscv64.rpm",
            "antenna-0.1.0-preview.3-linux-x86_64.deb.sha256",
        ] {
            assert_eq!(classify_name(not_asset, v), None, "{not_asset}");
        }
        assert_eq!(manifest_name(v), "antenna-0.1.0-preview.3-manifest.json");
        assert_eq!(
            signature_name(v),
            "antenna-0.1.0-preview.3-manifest.json.sig"
        );
    }

    #[test]
    fn hashes_a_file() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("f");
        std::fs::write(&p, b"abc").unwrap();
        let (n, sha, b3) = hash_file(&p).unwrap();
        assert_eq!(n, 3);
        // SHA-256("abc"), FIPS 180-2 appendix B.1.
        assert_eq!(
            sha,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(b3, hex(blake3::hash(b"abc").as_bytes()));
    }
}
