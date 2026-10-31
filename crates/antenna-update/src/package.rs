// SPDX-License-Identifier: AGPL-3.0-only
//! An update package: the manifest, its signature and the asset for this platform, found among the files the owner
//! points `antenna update --from` at (a folder, or the files themselves), and verified.
//!
//! Order: the signature over the exact manifest bytes first (with the pinned keys), then the manifest fields, then the
//! version policy (strictly newer), then the asset's size, SHA-256 and BLAKE3. The installer does not trust the owner's
//! copy of the asset after this: it copies the asset into its own staging directory and verifies the copy
//! ([`stage_asset`]), so a file changed after the check is never installed.

use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

use sha2::{Digest, Sha256};

use crate::{
    Error, Result, Version, code, hex,
    keys::KeySet,
    manifest::{self, Asset, Manifest, Platform},
    sig::{self, Verified},
};

/// The files of a package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Located {
    /// The manifest.
    pub manifest: PathBuf,
    /// Its signature.
    pub sig: PathBuf,
    /// Files given explicitly besides the manifest and the signature (candidate assets).
    pub given: Vec<PathBuf>,
    /// The folder of the manifest (where the asset is looked up by name when it was not given).
    pub dir: PathBuf,
}

fn is_manifest_name(n: &str) -> bool {
    n.starts_with("antenna-") && n.ends_with("-manifest.json")
}

fn name_of(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn bad_request(m: impl Into<String>) -> Error {
    Error::new(code::BAD_REQUEST, m)
}

/// Finds the manifest, the signature and the given assets.
pub fn locate(paths: &[PathBuf]) -> Result<Located> {
    if paths.is_empty() {
        return Err(bad_request("--from needs a folder or the release files"));
    }
    if paths.len() == 1 && paths[0].is_dir() {
        let dir = &paths[0];
        // A folder of received files can hold several releases: the newest one by its name (its signature and contents
        // are checked afterwards, as for any other).
        let newest = fs::read_dir(dir)
            .map_err(|e| Error::io(dir.display(), e))?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| is_manifest_name(&name_of(p)) && p.is_file())
            .filter_map(|p| {
                let v: Version = name_of(&p)
                    .strip_prefix("antenna-")?
                    .strip_suffix("-manifest.json")?
                    .parse()
                    .ok()?;
                Some((v, p))
            })
            .max_by(|a, b| a.0.cmp(&b.0));
        let Some((_, m)) = newest else {
            return Err(bad_request(format!(
                "no antenna-<version>-manifest.json in {}",
                dir.display()
            )));
        };
        return Ok(Located {
            sig: sig_next_to(&m),
            given: vec![],
            dir: dir.clone(),
            manifest: m,
        });
    }
    let mut manifest = None;
    let mut sig = None;
    let mut given = Vec::new();
    for p in paths {
        if p.is_dir() {
            return Err(bad_request(format!(
                "{} is a folder: pass one folder, or files only",
                p.display()
            )));
        }
        if !p.is_file() {
            return Err(bad_request(format!("{}: no such file", p.display())));
        }
        let n = name_of(p);
        if is_manifest_name(&n) {
            if manifest.replace(p.clone()).is_some() {
                return Err(bad_request("several manifests given: pass one"));
            }
        } else if n.ends_with("-manifest.json.sig") || n.ends_with(".sig") {
            if sig.replace(p.clone()).is_some() {
                return Err(bad_request("several signature files given: pass one"));
            }
        } else {
            given.push(p.clone());
        }
    }
    let manifest = manifest.ok_or_else(|| {
        bad_request("no antenna-<version>-manifest.json among the files: the manifest is required")
    })?;
    let sig = sig.unwrap_or_else(|| sig_next_to(&manifest));
    let dir = manifest
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    Ok(Located {
        manifest,
        sig,
        given,
        dir,
    })
}

fn sig_next_to(manifest: &Path) -> PathBuf {
    let mut s = manifest.as_os_str().to_owned();
    s.push(".sig");
    PathBuf::from(s)
}

fn read_bounded(p: &Path, max: usize, what: &str) -> Result<Vec<u8>> {
    let f = fs::File::open(p).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            Error::new(
                code::BAD_SIGNATURE,
                format!("{what} {} not found", p.display()),
            )
        } else {
            Error::io(p.display(), e)
        }
    })?;
    let mut b = Vec::new();
    f.take(max as u64 + 1)
        .read_to_end(&mut b)
        .map_err(|e| Error::io(p.display(), e))?;
    if b.len() > max {
        return Err(Error::new(
            code::BAD_MANIFEST,
            format!("{what} {} is larger than {max} bytes", p.display()),
        ));
    }
    Ok(b)
}

/// A release whose manifest verified.
#[derive(Debug, Clone)]
pub struct Release {
    /// The manifest.
    pub manifest: Manifest,
    /// Its version.
    pub version: Version,
    /// The signature check.
    pub sig: Verified,
    /// Where the manifest is.
    pub path: PathBuf,
}

/// Reads and verifies the manifest: signature over the exact bytes first, then the fields.
pub fn open_release(loc: &Located, keys: &KeySet) -> Result<Release> {
    let bytes = read_bounded(&loc.manifest, manifest::MAX_BYTES, "manifest")?;
    let sig_bytes = read_bounded(&loc.sig, sig::MAX_BYTES, "signature file")?;
    let verified = sig::verify(&bytes, &sig_bytes, keys)?;
    let (manifest, version) = Manifest::parse(&bytes)?;
    Ok(Release {
        manifest,
        version,
        sig: verified,
        path: loc.manifest.clone(),
    })
}

/// No downgrades: the update must be strictly newer (`allow_same` lets tests reinstall the same version).
pub fn check_newer(current: &Version, update: &Version, allow_same: bool) -> Result<()> {
    if update > current || (allow_same && update == current) {
        return Ok(());
    }
    Err(Error::new(
        code::NOT_NEWER,
        if update == current {
            format!("{update} is already installed")
        } else {
            format!(
                "{update} is older than the installed {current}: downgrades are refused (roll back with --rollback)"
            )
        },
    ))
}

fn check_hashes(path: &Path, a: &Asset) -> Result<()> {
    let (size, sha, b3) = manifest::hash_file(path)?;
    if size != a.size || sha != a.sha256 || b3 != a.blake3 {
        return Err(Error::new(
            code::HASH_MISMATCH,
            format!(
                "{} does not match the signed manifest (size {size}, expected {}; the file was altered or is damaged)",
                path.display(),
                a.size
            ),
        ));
    }
    Ok(())
}

/// The asset for this platform: from the given files (matched by SHA-256, whatever their names), or next to the
/// manifest by its published name. Its size and hashes are checked.
pub fn find_asset(rel: &Release, loc: &Located, platform: &Platform) -> Result<(Asset, PathBuf)> {
    let want = rel.manifest.asset_for(platform)?.clone();
    if !loc.given.is_empty() {
        let mut other: Option<&Asset> = None;
        for p in &loc.given {
            let (size, sha, b3) = manifest::hash_file(p)?;
            if let Some(a) = rel.manifest.assets.iter().find(|a| a.sha256 == sha) {
                if a.name == want.name {
                    if size != a.size || b3 != a.blake3 {
                        return Err(Error::new(
                            code::HASH_MISMATCH,
                            format!("{} does not match the signed manifest", p.display()),
                        ));
                    }
                    return Ok((want, p.clone()));
                }
                other = Some(a);
            }
        }
        return Err(match other {
            Some(a) => Error::new(
                code::WRONG_PLATFORM,
                format!(
                    "the given file is the release's {} {} {} file ({}); this installation needs {}",
                    a.os, a.arch, a.kind, a.name, want.name
                ),
            ),
            None => Error::new(
                code::HASH_MISMATCH,
                format!(
                    "none of the given files is part of release {} (this installation needs {})",
                    rel.manifest.version, want.name
                ),
            ),
        });
    }
    // The name was checked by Manifest::validate (a plain file name), so joining it cannot leave the folder.
    let p = loc.dir.join(&want.name);
    if !p.is_file() {
        return Err(Error::new(
            code::ASSET_MISSING,
            format!(
                "{} is not next to the manifest in {} (this installation needs that file)",
                want.name,
                loc.dir.display()
            ),
        ));
    }
    check_hashes(&p, &want)?;
    Ok((want, p))
}

/// Copies the asset into the installer's own folder while hashing it, and checks the copy against the manifest. The
/// installer works only with the returned copy.
pub fn stage_asset(src: &Path, a: &Asset, dir: &Path) -> Result<PathBuf> {
    let ext = if a.name.ends_with(".dmg") {
        "dmg"
    } else {
        "tar.gz"
    };
    let dst = dir.join(format!("asset.{ext}"));
    let _ = fs::remove_file(&dst);
    let mut from = fs::File::open(src).map_err(|e| Error::io(src.display(), e))?;
    let mut to = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&dst)
        .map_err(|e| Error::io(dst.display(), e))?;
    let mut sha = Sha256::new();
    let mut b3 = blake3::Hasher::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut size = 0u64;
    loop {
        let n = from
            .read(&mut buf)
            .map_err(|e| Error::io(src.display(), e))?;
        if n == 0 {
            break;
        }
        size += n as u64;
        if size > a.size {
            break;
        }
        sha.update(&buf[..n]);
        b3.update(&buf[..n]);
        to.write_all(&buf[..n])
            .map_err(|e| Error::io(dst.display(), e))?;
    }
    to.sync_all().map_err(|e| Error::io(dst.display(), e))?;
    if size != a.size
        || hex(&sha.finalize()) != a.sha256
        || hex(b3.finalize().as_bytes()) != a.blake3
    {
        let _ = fs::remove_file(&dst);
        return Err(Error::new(
            code::HASH_MISMATCH,
            format!(
                "{} changed after it was checked; nothing was installed",
                src.display()
            ),
        ));
    }
    Ok(dst)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{keys::test_signing_key, manifest::FORMAT, sig::SignatureFile};

    /// A release folder with a test-signed manifest and real files.
    pub(crate) fn release_dir(dir: &Path, version: &str, files: &[(&str, &[u8])]) -> PathBuf {
        let mut assets = Vec::new();
        for (name, data) in files {
            let p = dir.join(name);
            fs::write(&p, data).unwrap();
            let (os, arch, kind) = manifest::classify_name(name, version).unwrap();
            let (size, sha256, blake3) = manifest::hash_file(&p).unwrap();
            assets.push(Asset {
                name: name.to_string(),
                os: os.into(),
                arch: arch.into(),
                kind: kind.into(),
                size,
                sha256,
                blake3,
            });
        }
        let m = Manifest {
            format: FORMAT.into(),
            product: "antenna".into(),
            version: version.into(),
            channel: "preview".into(),
            created: "2026-10-03T12:00:00Z".into(),
            commit: "0123456789ab".into(),
            assets,
            models: Vec::new(),
        };
        let bytes = m.to_bytes();
        let mp = dir.join(manifest::manifest_name(version));
        fs::write(&mp, &bytes).unwrap();
        let s = SignatureFile::new(sig::sign(&bytes, &test_signing_key()));
        fs::write(dir.join(manifest::signature_name(version)), s.to_bytes()).unwrap();
        mp
    }

    const LINUX: Platform = Platform {
        os: "linux",
        arch: "x86_64",
        kind: "cli",
    };
    const MAC: Platform = Platform {
        os: "macos",
        arch: "arm64",
        kind: "app",
    };

    fn two_assets(d: &Path) -> PathBuf {
        release_dir(
            d,
            "0.1.0-preview.3",
            &[
                ("antenna-0.1.0-preview.3-linux-x86_64.tar.gz", b"linux bits"),
                ("Antenna-0.1.0-preview.3-macos-arm64.dmg", b"mac bits"),
            ],
        )
    }

    #[test]
    fn folder_files_and_explicit_asset() {
        let d = tempfile::tempdir().unwrap();
        let mp = two_assets(d.path());
        let keys = KeySet::test_only();
        // A folder.
        let loc = locate(&[d.path().to_path_buf()]).unwrap();
        assert_eq!(loc.manifest, mp);
        let rel = open_release(&loc, &keys).unwrap();
        assert_eq!(rel.version.to_string(), "0.1.0-preview.3");
        let (a, p) = find_asset(&rel, &loc, &LINUX).unwrap();
        assert_eq!(a.name, "antenna-0.1.0-preview.3-linux-x86_64.tar.gz");
        assert_eq!(p, d.path().join(&a.name));
        // The manifest alone: signature and asset next to it.
        let loc = locate(std::slice::from_ref(&mp)).unwrap();
        assert_eq!(
            find_asset(&open_release(&loc, &keys).unwrap(), &loc, &MAC)
                .unwrap()
                .0
                .os,
            "macos"
        );
        // An asset under another name (as a received file might be called) is matched by hash.
        let renamed = d.path().join("received (1).dmg");
        fs::copy(
            d.path().join("Antenna-0.1.0-preview.3-macos-arm64.dmg"),
            &renamed,
        )
        .unwrap();
        let loc = locate(&[mp.clone(), renamed.clone()]).unwrap();
        let rel = open_release(&loc, &keys).unwrap();
        assert_eq!(find_asset(&rel, &loc, &MAC).unwrap().1, renamed);
        // The same file for the Linux installation is the wrong platform.
        assert_eq!(
            find_asset(&rel, &loc, &LINUX).unwrap_err().code,
            code::WRONG_PLATFORM
        );
    }

    #[test]
    fn tampered_or_missing_asset() {
        let d = tempfile::tempdir().unwrap();
        let mp = two_assets(d.path());
        let keys = KeySet::test_only();
        let loc = locate(std::slice::from_ref(&mp)).unwrap();
        let rel = open_release(&loc, &keys).unwrap();
        fs::write(
            d.path().join("antenna-0.1.0-preview.3-linux-x86_64.tar.gz"),
            b"linux bitz",
        )
        .unwrap();
        assert_eq!(
            find_asset(&rel, &loc, &LINUX).unwrap_err().code,
            code::HASH_MISMATCH
        );
        fs::remove_file(d.path().join("Antenna-0.1.0-preview.3-macos-arm64.dmg")).unwrap();
        assert_eq!(
            find_asset(&rel, &loc, &MAC).unwrap_err().code,
            code::ASSET_MISSING
        );
        // A stranger file given explicitly.
        let other = d.path().join("other.dmg");
        fs::write(&other, b"something else").unwrap();
        let loc = locate(&[mp, other]).unwrap();
        assert_eq!(
            find_asset(&rel, &loc, &MAC).unwrap_err().code,
            code::HASH_MISMATCH
        );
    }

    #[test]
    fn tampered_manifest_or_signature() {
        let d = tempfile::tempdir().unwrap();
        let mp = two_assets(d.path());
        let keys = KeySet::test_only();
        let loc = locate(std::slice::from_ref(&mp)).unwrap();
        // The manifest points at another file: the signature no longer matches.
        let t = fs::read_to_string(&mp)
            .unwrap()
            .replacen("\"size\": 10", "\"size\": 11", 1);
        fs::write(&mp, t).unwrap();
        assert_eq!(
            open_release(&loc, &keys).unwrap_err().code,
            code::BAD_SIGNATURE
        );
        // No signature at all.
        let d2 = tempfile::tempdir().unwrap();
        let mp2 = two_assets(d2.path());
        fs::remove_file(d2.path().join("antenna-0.1.0-preview.3-manifest.json.sig")).unwrap();
        let loc = locate(&[mp2]).unwrap();
        assert_eq!(
            open_release(&loc, &keys).unwrap_err().code,
            code::BAD_SIGNATURE
        );
        // No pinned key: refused before anything else.
        let d3 = tempfile::tempdir().unwrap();
        let loc = locate(&[two_assets(d3.path())]).unwrap();
        assert_eq!(
            open_release(&loc, &KeySet::default()).unwrap_err().code,
            code::NO_RELEASE_KEY
        );
    }

    #[test]
    fn version_policy() {
        let v = |s: &str| s.parse::<Version>().unwrap();
        assert!(check_newer(&v("0.1.0-preview.2"), &v("0.1.0-preview.3"), false).is_ok());
        assert_eq!(
            check_newer(&v("0.1.0-preview.3"), &v("0.1.0-preview.2"), false)
                .unwrap_err()
                .code,
            code::NOT_NEWER
        );
        assert_eq!(
            check_newer(&v("0.1.0-preview.3"), &v("0.1.0-preview.3"), false)
                .unwrap_err()
                .code,
            code::NOT_NEWER
        );
        assert!(check_newer(&v("0.1.0-preview.3"), &v("0.1.0-preview.3"), true).is_ok());
        assert_eq!(
            check_newer(&v("0.1.0-preview.3"), &v("0.1.0-preview.2"), true)
                .unwrap_err()
                .code,
            code::NOT_NEWER
        );
    }

    #[test]
    fn locate_errors() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(
            locate(&[d.path().to_path_buf()]).unwrap_err().code,
            code::BAD_REQUEST
        );
        release_dir(
            d.path(),
            "0.1.0-preview.3",
            &[("antenna-0.1.0-preview.3-linux-x86_64.tar.gz", b"x")],
        );
        release_dir(
            d.path(),
            "0.1.0-preview.4",
            &[("antenna-0.1.0-preview.4-linux-x86_64.tar.gz", b"y")],
        );
        // Several releases in one folder: the newest.
        let loc = locate(&[d.path().to_path_buf()]).unwrap();
        assert!(
            loc.manifest
                .ends_with("antenna-0.1.0-preview.4-manifest.json"),
            "{loc:?}"
        );
        let f = d.path().join("antenna-0.1.0-preview.3-linux-x86_64.tar.gz");
        assert_eq!(
            locate(std::slice::from_ref(&f)).unwrap_err().code,
            code::BAD_REQUEST
        );
        assert_eq!(
            locate(&[d.path().join("nope.json")]).unwrap_err().code,
            code::BAD_REQUEST
        );
        assert_eq!(locate(&[]).unwrap_err().code, code::BAD_REQUEST);
    }

    #[test]
    fn staging_rechecks_the_copy() {
        let d = tempfile::tempdir().unwrap();
        let mp = two_assets(d.path());
        let loc = locate(&[mp]).unwrap();
        let rel = open_release(&loc, &KeySet::test_only()).unwrap();
        let (a, p) = find_asset(&rel, &loc, &LINUX).unwrap();
        let stage = tempfile::tempdir().unwrap();
        let copy = stage_asset(&p, &a, stage.path()).unwrap();
        assert_eq!(fs::read(&copy).unwrap(), b"linux bits");
        // Changed between the check and the install: refused, nothing left behind.
        fs::write(&p, b"linux bitz").unwrap();
        assert_eq!(
            stage_asset(&p, &a, stage.path()).unwrap_err().code,
            code::HASH_MISMATCH
        );
        assert!(!copy.exists());
        fs::write(&p, b"linux bits and more").unwrap();
        assert_eq!(
            stage_asset(&p, &a, stage.path()).unwrap_err().code,
            code::HASH_MISMATCH
        );
    }
}
