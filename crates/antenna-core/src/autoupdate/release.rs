// SPDX-License-Identifier: AGPL-3.0-only
//! Finding, verifying and staging a release for an automatic install (D-103). Blocking file work: callers run it in
//! `spawn_blocking`.
//!
//! The verification is `antenna update --from`'s own, from the `antenna-update` crate, in the same order
//! (`docs/UPDATES.md` §5.1): the signature with the release keys pinned in this daemon, the manifest, a version strictly
//! newer than the running one, this installation's file with its size, SHA-256 and BLAKE3. The release is then copied
//! into `<data-dir>/updates/<version>/` (0700) and the copy is checked again: what is installed later no longer depends
//! on a link folder that agents and other programs can write to.

use std::{
    fs,
    path::{Path, PathBuf},
};

use antenna_update::{
    self as up, Version,
    install::Target,
    keys::KeySet,
    manifest::{self, Asset, Manifest, Platform},
    package, sig,
};

use super::{AutoConfig, UPDATES_DIR};

/// What a folder or a download turned out to be.
#[derive(Debug)]
#[cfg_attr(
    windows,
    expect(
        clippy::large_enum_variant,
        reason = "a PathBuf is 32 bytes on Windows (24 on unix), which takes `Release` just past the lint's limit; one \
                  value per release found"
    )
)]
pub(crate) enum Found {
    /// A verified release, newer than this daemon, with this installation's file.
    Release(Verified),
    /// Not a complete release yet (the signature or this installation's file has not arrived): nothing to say.
    Incomplete,
    /// The version that runs now: ignored without a record (re-sent files, D-103 item "already installed").
    Installed(String),
    /// Refused: `(version if known, "<code>: <reason>")`.
    Refused(Option<String>, String),
}

/// A verified release.
#[derive(Debug, Clone)]
pub(crate) struct Verified {
    pub(crate) version: String,
    pub(crate) manifest: PathBuf,
    pub(crate) sig: PathBuf,
    pub(crate) asset: Asset,
    pub(crate) asset_path: PathBuf,
}

fn refused(version: Option<&str>, e: &up::Error) -> Found {
    Found::Refused(
        version.map(str::to_string),
        format!("{}: {}", e.code, e.message),
    )
}

/// The installation this daemon belongs to (the `antenna` next to it decides, as for `antenna update`).
pub(crate) fn target(cfg: &AutoConfig) -> up::Result<(Target, PathBuf)> {
    let unsupported = |m: String| up::Error::new(up::code::UNSUPPORTED_INSTALL, m);
    let exe = cfg
        .exe
        .as_ref()
        .ok_or_else(|| unsupported("the daemon cannot tell where it is installed".into()))?;
    let cli = exe
        .parent()
        .map(|d| d.join("antenna"))
        .ok_or_else(|| unsupported("the daemon cannot tell where it is installed".into()))?;
    let cli = fs::canonicalize(&cli).map_err(|_| {
        unsupported(format!(
            "there is no antenna next to {}: the installer is missing",
            exe.display()
        ))
    })?;
    let t = Target::detect(&cli, std::env::consts::OS, &|p: &Path| p.is_file());
    if let Target::Unsupported { reason, .. } = &t {
        return Err(unsupported(reason.clone()));
    }
    Ok((t, cli))
}

fn platform(cfg: &AutoConfig) -> up::Result<Platform> {
    let (t, _) = target(cfg)?;
    t.platform()
        .ok_or_else(|| up::Error::new(up::code::UNSUPPORTED_INSTALL, "unsupported installation"))
}

fn current(cfg: &AutoConfig) -> up::Result<Version> {
    cfg.version.parse().map_err(|e| {
        up::Error::new(
            up::code::BAD_MANIFEST,
            format!("this daemon's version: {e}"),
        )
    })
}

/// The newest release in a folder (a link folder that received release files), verified for this installation.
pub(crate) fn find_in(folder: &Path, cfg: &AutoConfig) -> Found {
    let loc = match package::locate(&[folder.to_path_buf()]) {
        Ok(l) => l,
        Err(_) => return Found::Incomplete,
    };
    // A manifest whose signature or file is still on its way: wait for them, it is not a refusal.
    if !loc.sig.is_file() {
        return Found::Incomplete;
    }
    let named = loc
        .manifest
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(|n| n.strip_prefix("antenna-")?.strip_suffix("-manifest.json"))
        .map(str::to_string);
    let rel = match package::open_release(&loc, &KeySet::pinned()) {
        Ok(r) => r,
        Err(e) => return refused(named.as_deref(), &e),
    };
    let v = rel.manifest.version.clone();
    let cur = match current(cfg) {
        Ok(c) => c,
        Err(e) => return refused(Some(&v), &e),
    };
    if rel.version == cur {
        return Found::Installed(v);
    }
    if let Err(e) = package::check_newer(&cur, &rel.version, false) {
        return refused(Some(&v), &e);
    }
    let p = match platform(cfg) {
        Ok(p) => p,
        Err(e) => return refused(Some(&v), &e),
    };
    match package::find_asset(&rel, &loc, &p) {
        Ok((asset, asset_path)) => Found::Release(Verified {
            version: v,
            manifest: loc.manifest,
            sig: loc.sig,
            asset,
            asset_path,
        }),
        Err(e) if e.code == up::code::ASSET_MISSING => Found::Incomplete,
        Err(e) => refused(Some(&v), &e),
    }
}

/// The daily check (D-103): the manifest and its signature from the update URL; when they verify and announce a newer
/// release, this installation's file into `dest` (a fresh folder), then the same check as for received files.
pub(crate) fn fetch_into(url: &str, dest: &Path, cfg: &AutoConfig) -> Found {
    let bytes = match up::fetch::https(url, manifest::MAX_BYTES as u64, None) {
        Ok(b) => b,
        Err(e) => return refused(None, &e),
    };
    let sig_bytes = match up::fetch::https(&format!("{url}.sig"), sig::MAX_BYTES as u64, None) {
        Ok(b) => b,
        Err(e) => return refused(None, &e),
    };
    if let Err(e) = sig::verify(&bytes, &sig_bytes, &KeySet::pinned()) {
        return refused(None, &e);
    }
    let (m, version): (Manifest, Version) = match Manifest::parse(&bytes) {
        Ok(x) => x,
        Err(e) => return refused(None, &e),
    };
    match current(cfg) {
        Ok(cur) if version == cur => return Found::Installed(m.version),
        Ok(cur) if version < cur => {
            // An older release on the update URL is normal (the URL may lag): nothing to record.
            tracing::info!("update URL: {} is not newer than {cur}", m.version);
            return Found::Installed(m.version);
        }
        Ok(_) => {}
        Err(e) => return refused(Some(&m.version), &e),
    }
    let asset = match platform(cfg).and_then(|p| m.asset_for(&p).cloned()) {
        Ok(a) => a,
        Err(e) => return refused(Some(&m.version), &e),
    };
    let write = |name: String, b: &[u8]| {
        fs::write(dest.join(name), b).map_err(|e| up::Error::io(dest.display(), e))
    };
    let r = fs::create_dir_all(dest)
        .map_err(|e| up::Error::io(dest.display(), e))
        .and_then(|()| write(manifest::manifest_name(&m.version), &bytes))
        .and_then(|()| write(manifest::signature_name(&m.version), &sig_bytes))
        .and_then(|_| {
            up::fetch::https(
                &up::fetch::sibling(url, &asset.name),
                asset.size,
                Some(&dest.join(&asset.name)),
            )
        });
    if let Err(e) = r {
        return refused(Some(&m.version), &e);
    }
    find_in(dest, cfg)
}

fn updates_root(data_dir: &Path) -> PathBuf {
    data_dir.join(UPDATES_DIR)
}

fn private_dir(p: &Path) -> std::io::Result<()> {
    fs::create_dir_all(p)?;
    crate::owner_only::owner_only_dir(p)
}

/// A fresh folder under `<data-dir>/updates/` for a download or a copy.
pub(crate) fn fresh_dir(data_dir: &Path, name: &str) -> std::io::Result<PathBuf> {
    let root = updates_root(data_dir);
    private_dir(&root)?;
    let d = root.join(name);
    let _ = fs::remove_dir_all(&d);
    private_dir(&d)?;
    Ok(d)
}

/// Copies a verified release into `<data-dir>/updates/<version>/` and checks the copy again (the asset by its size and
/// both hashes, the manifest by its signature): what is installed later is this copy.
pub(crate) fn stage(v: &Verified, data_dir: &Path, cfg: &AutoConfig) -> up::Result<PathBuf> {
    let part = fresh_dir(data_dir, &format!("{}.part", v.version))
        .map_err(|e| up::Error::io("updates folder", e))?;
    let copy = |src: &Path| -> up::Result<()> {
        let name = src
            .file_name()
            .ok_or_else(|| up::Error::new(up::code::BAD_REQUEST, "a release file has no name"))?;
        if src != part.join(name) {
            fs::copy(src, part.join(name)).map_err(|e| up::Error::io(src.display(), e))?;
        }
        Ok(())
    };
    copy(&v.manifest)?;
    copy(&v.sig)?;
    let dst = part.join(&v.asset.name);
    if v.asset_path != dst {
        fs::copy(&v.asset_path, &dst).map_err(|e| up::Error::io(v.asset_path.display(), e))?;
    }
    let (size, sha, b3) = manifest::hash_file(&dst)?;
    if size != v.asset.size || sha != v.asset.sha256 || b3 != v.asset.blake3 {
        let _ = fs::remove_dir_all(&part);
        return Err(up::Error::new(
            up::code::HASH_MISMATCH,
            format!("{} changed while it was copied", v.asset.name),
        ));
    }
    let Found::Release(again) = find_in(&part, cfg) else {
        let _ = fs::remove_dir_all(&part);
        return Err(up::Error::new(
            up::code::BAD_SIGNATURE,
            "the staged copy did not verify",
        ));
    };
    let fin = updates_root(data_dir).join(&again.version);
    let _ = fs::remove_dir_all(&fin);
    fs::rename(&part, &fin).map_err(|e| up::Error::io(fin.display(), e))?;
    Ok(fin)
}

/// Removes a staged folder (only below `<data-dir>/updates/`).
pub(crate) fn remove_stage(data_dir: &Path, dir: &Path) {
    if dir.starts_with(updates_root(data_dir)) {
        let _ = fs::remove_dir_all(dir);
    }
}

/// Whether a received file's name looks like part of a release (the trigger only looks at those).
pub(crate) fn release_file_name(name: &str) -> bool {
    let named = name.starts_with("antenna-") || name.starts_with("Antenna-");
    named
        && (name.ends_with("-manifest.json")
            || name.ends_with("-manifest.json.sig")
            || name.ends_with(".tar.gz")
            || name.ends_with(".dmg"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_release_names_wake_the_trigger() {
        for n in [
            "antenna-0.1.0-preview.8-manifest.json",
            "antenna-0.1.0-preview.8-manifest.json.sig",
            "Antenna-0.1.0-preview.8-macos-arm64.dmg",
            "antenna-0.1.0-preview.8-linux-x86_64.tar.gz",
        ] {
            assert!(release_file_name(n), "{n}");
        }
        for n in [
            "report.pdf",
            "SHA256SUMS.txt",
            "antenna.txt",
            "x-antenna-1.dmg",
        ] {
            assert!(!release_file_name(n), "{n}");
        }
    }
}
