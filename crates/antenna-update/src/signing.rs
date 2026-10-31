// SPDX-License-Identifier: AGPL-3.0-only
//! The release side (`antenna-release`): the release key file, building a manifest from the release files, signing.
//!
//! The secret key file holds the 32-byte Ed25519 seed (RFC 8032 private key) from the OS CSPRNG, base64, after a
//! format line. It is created with mode 0600 and never overwritten; it is refused when other users can read it.
//! Windows refuses key files until their DACL can be set and checked (D-134, WP-4).

use std::{
    fs,
    path::{Path, PathBuf},
};
#[cfg(unix)]
use std::{
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
};

use data_encoding::BASE64;
use ed25519_dalek::SigningKey;
use rand::{TryRngCore, rngs::OsRng};
use zeroize::Zeroizing;

use crate::{
    Error, Result, code,
    manifest::{self, Asset, Manifest},
};

/// First line of a secret key file.
pub const SECRET_FORMAT: &str = "antenna-release-secret-key/1";

/// A new release key from the OS CSPRNG.
pub fn generate() -> SigningKey {
    let mut seed = Zeroizing::new([0u8; 32]);
    OsRng
        .try_fill_bytes(seed.as_mut())
        .expect("OS RNG must be available");
    SigningKey::from_bytes(&seed)
}

/// Writes a new secret key file (0600; its folder is created 0700). Never overwrites.
#[cfg(unix)]
pub fn write_secret(path: &Path, key: &SigningKey) -> Result<()> {
    if let Some(d) = path.parent().filter(|d| !d.as_os_str().is_empty())
        && !d.exists()
    {
        fs::create_dir_all(d).map_err(|e| Error::io(d.display(), e))?;
        fs::set_permissions(d, fs::Permissions::from_mode(0o700))
            .map_err(|e| Error::io(d.display(), e))?;
    }
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| Error::io(path.display(), e))?;
    let text = Zeroizing::new(format!(
        "{SECRET_FORMAT}\n{}\n",
        BASE64.encode(key.as_bytes())
    ));
    f.write_all(text.as_bytes())
        .and_then(|_| f.sync_all())
        .map_err(|e| Error::io(path.display(), e))
}

/// Windows: refused, nothing is created. Owner-only access there is a DACL, set and read back from W1 on (D-134,
/// WP-4); until then a release key is never written where other users might read it.
#[cfg(windows)]
pub fn write_secret(path: &Path, _key: &SigningKey) -> Result<()> {
    Err(not_on_windows(path))
}

/// Refuses a key file that group or others can read.
#[cfg(unix)]
fn check_private(path: &Path, m: &fs::Metadata) -> Result<()> {
    if m.permissions().mode() & 0o077 != 0 {
        return Err(Error::new(
            code::IO,
            format!(
                "{} can be read by other users: chmod 600 it",
                path.display()
            ),
        ));
    }
    Ok(())
}

/// Windows: who can read a file is its DACL, and reading one back comes in W1 (D-134, WP-4). A key file that cannot be
/// shown to be private is refused.
#[cfg(windows)]
fn check_private(path: &Path, _m: &fs::Metadata) -> Result<()> {
    Err(not_on_windows(path))
}

#[cfg(windows)]
fn not_on_windows(path: &Path) -> Error {
    Error::new(
        code::IO,
        format!(
            "{}: release key files are not supported on Windows yet: keep the release key on Linux or macOS",
            path.display()
        ),
    )
}

/// Reads a secret key file; refuses one that group or others can read.
pub fn read_secret(path: &Path) -> Result<SigningKey> {
    let m = fs::metadata(path).map_err(|e| Error::io(path.display(), e))?;
    check_private(path, &m)?;
    let text = Zeroizing::new(fs::read_to_string(path).map_err(|e| Error::io(path.display(), e))?);
    let mut lines = text.lines();
    if lines.next() != Some(SECRET_FORMAT) {
        return Err(Error::new(
            code::IO,
            format!("{} is not an {SECRET_FORMAT} file", path.display()),
        ));
    }
    let seed = Zeroizing::new(
        BASE64
            .decode(lines.next().unwrap_or("").trim().as_bytes())
            .map_err(|e| Error::new(code::IO, format!("{}: {e}", path.display())))?,
    );
    let seed: Zeroizing<[u8; 32]> = Zeroizing::new(
        seed.as_slice()
            .try_into()
            .map_err(|_| Error::new(code::IO, format!("{}: a key is 32 bytes", path.display())))?,
    );
    Ok(SigningKey::from_bytes(&seed))
}

/// Whether a release file is not an asset (checksums, the manifest and its signature).
pub fn is_not_asset(name: &str) -> bool {
    name == "SHA256SUMS.txt"
        || name.ends_with(".sha256")
        || name.ends_with("-manifest.json")
        || name.ends_with(".sig")
}

/// Builds the manifest of a release from its files (folders are listed, one level).
pub fn build_manifest(
    version: &str,
    channel: &str,
    commit: &str,
    created: &str,
    inputs: &[PathBuf],
) -> Result<Manifest> {
    let mut files = Vec::new();
    for p in inputs {
        if p.is_dir() {
            for e in fs::read_dir(p)
                .map_err(|e| Error::io(p.display(), e))?
                .flatten()
            {
                if e.file_type().is_ok_and(|t| t.is_file()) {
                    files.push(e.path());
                }
            }
        } else {
            files.push(p.clone());
        }
    }
    files.sort();
    let mut assets: Vec<Asset> = Vec::new();
    for f in files {
        let name = f
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if is_not_asset(&name) {
            continue;
        }
        let Some((os, arch, kind)) = manifest::classify_name(&name, version) else {
            return Err(Error::new(
                code::BAD_MANIFEST,
                format!(
                    "{name} is not a release file of {version} (unknown name: rename it or leave it out)"
                ),
            ));
        };
        let (size, sha256, blake3) = manifest::hash_file(&f)?;
        assets.push(Asset {
            name,
            os: os.into(),
            arch: arch.into(),
            kind: kind.into(),
            size,
            sha256,
            blake3,
        });
    }
    let m = Manifest {
        format: manifest::FORMAT.into(),
        product: manifest::PRODUCT.into(),
        version: version.into(),
        channel: channel.into(),
        created: created.into(),
        commit: commit.into(),
        assets,
        models: Vec::new(),
    };
    m.validate()?;
    Ok(m)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{keys::KeySet, sig};

    // Unix modes; Windows refuses key files (`key_files_are_refused_on_windows`).
    #[cfg(unix)]
    #[test]
    fn key_file_round_trip_and_permissions() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("keys/release-key");
        let k = generate();
        write_secret(&p, &k).unwrap();
        assert_eq!(
            fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(p.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(read_secret(&p).unwrap().to_bytes(), k.to_bytes());
        // Never overwritten.
        assert!(write_secret(&p, &generate()).is_err());
        assert_eq!(read_secret(&p).unwrap().to_bytes(), k.to_bytes());
        // Refused when others can read it.
        fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_secret(&p).is_err());
        // Two keys differ.
        assert_ne!(generate().to_bytes(), generate().to_bytes());
    }

    #[cfg(windows)]
    #[test]
    fn key_files_are_refused_on_windows() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("keys/release-key");
        assert_eq!(write_secret(&p, &generate()).unwrap_err().code, code::IO);
        assert!(!p.parent().unwrap().exists());
        // A well-formed key file is refused too: its DACL cannot be checked yet.
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(
            &p,
            format!("{SECRET_FORMAT}\n{}\n", BASE64.encode(&[7u8; 32])),
        )
        .unwrap();
        assert_eq!(read_secret(&p).unwrap_err().code, code::IO);
        assert_ne!(generate().to_bytes(), generate().to_bytes());
    }

    #[test]
    fn manifest_from_release_files_then_sign_and_verify() {
        let d = tempfile::tempdir().unwrap();
        let v = "0.1.0-preview.3";
        for (n, b) in [
            (format!("Antenna-{v}-macos-arm64.dmg"), &b"dmg"[..]),
            (format!("antenna-{v}-macos-arm64-cli.tar.gz"), b"mac cli"),
            (format!("antenna-{v}-linux-x86_64.tar.gz"), b"linux cli"),
            (
                format!("antenna-desktop-{v}-linux-x86_64.tar.gz"),
                b"linux app",
            ),
            ("SHA256SUMS.txt".into(), b"sums"),
            (format!("Antenna-{v}-macos-arm64.dmg.sha256"), b"sum"),
        ] {
            fs::write(d.path().join(n), b).unwrap();
        }
        let m = build_manifest(
            v,
            "preview",
            "0123456789ab",
            "2026-10-03T12:00:00Z",
            &[d.path().to_path_buf()],
        )
        .unwrap();
        assert_eq!(m.assets.len(), 4);
        let bytes = m.to_bytes();
        let key = generate();
        let s = sig::SignatureFile::new(sig::sign(&bytes, &key));
        assert!(sig::verify(&bytes, &s.to_bytes(), &KeySet::of(&[key.verifying_key()])).is_ok());
        // A stray file is an error, not silently left out.
        fs::write(d.path().join("notes.md"), b"x").unwrap();
        assert!(
            build_manifest(
                v,
                "preview",
                "0123456789ab",
                "2026-10-03T12:00:00Z",
                &[d.path().to_path_buf()]
            )
            .is_err()
        );
    }
}
