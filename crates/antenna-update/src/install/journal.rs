// SPDX-License-Identifier: AGPL-3.0-only
//! The install journal: written before anything installed is touched, removed when the update is done. If the process
//! dies in the middle (power loss, a kill), the next `antenna update` finds the journal and puts the old version back.
//!
//! What is "the old version" is decided by file identity (device and inode), not by names: a swap moves directory
//! entries, the inode of the old binary or the old app bundle stays the same wherever it ends up. The journal records,
//! for every replaced path, the identity of what was there and the places it can have moved to.

use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

use crate::{Error, Result, code};

/// File name of the journal inside the staging folder.
pub const FILE: &str = "journal.json";

/// One replaced path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    /// The installed path (`…/bin/antennad`, `…/Antenna.app`).
    pub path: PathBuf,
    /// Device of what was installed before.
    pub dev: u64,
    /// Inode of what was installed before.
    pub ino: u64,
    /// Where the old one can be during and after the swap.
    pub candidates: Vec<PathBuf>,
}

/// The journal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Journal {
    /// `install` or `rollback`.
    pub action: String,
    /// When it started.
    pub started: String,
    /// Version line before.
    pub from: String,
    /// Version line after.
    pub to: String,
    /// How to start the daemon again after a recovery.
    pub keeper: super::Keeper,
    /// The app to open again after a recovery (macOS, if the window was running).
    #[serde(default)]
    pub relaunch: Option<PathBuf>,
    /// Replaced paths.
    pub items: Vec<Item>,
}

/// Device and inode of a path (not following a final symlink).
#[cfg(unix)]
pub fn ident(p: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    fs::symlink_metadata(p).ok().map(|m| (m.dev(), m.ino()))
}

/// Windows: the volume serial number and file index need `GetFileInformationByHandle` (std's accessors are unstable),
/// which comes with the Windows installer (D-134, WP-29, phase W4). Until then no path has an identity: [`item`]
/// refuses and [`restore`] finds nothing to restore from, so nothing is swapped on a guess.
#[cfg(windows)]
pub fn ident(_p: &Path) -> Option<(u64, u64)> {
    None
}

/// An item for a path that exists now.
pub fn item(path: &Path, candidates: Vec<PathBuf>) -> Result<Item> {
    if cfg!(windows) {
        return Err(Error::new(
            code::UNSUPPORTED_INSTALL,
            format!(
                "{}: antenna update cannot replace files on Windows yet",
                path.display()
            ),
        ));
    }
    let (dev, ino) = ident(path).ok_or_else(|| {
        Error::new(
            code::INSTALL_FAILED,
            format!("{} is missing: nothing to replace", path.display()),
        )
    })?;
    Ok(Item {
        path: path.to_path_buf(),
        dev,
        ino,
        candidates,
    })
}

fn sync_dir(dir: &Path) {
    if let Ok(d) = fs::File::open(dir) {
        let _ = d.sync_all();
    }
}

/// Writes the journal durably (temporary file, fsync, rename, fsync of the folder).
pub fn write(dir: &Path, j: &Journal) -> Result<()> {
    let tmp = dir.join(format!("{FILE}.tmp"));
    let dst = dir.join(FILE);
    let bytes = serde_json::to_vec_pretty(j).expect("a journal serializes");
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp)
        .map_err(|e| Error::io(tmp.display(), e))?;
    f.write_all(&bytes)
        .and_then(|_| f.sync_all())
        .map_err(|e| Error::io(tmp.display(), e))?;
    fs::rename(&tmp, &dst).map_err(|e| Error::io(dst.display(), e))?;
    sync_dir(dir);
    Ok(())
}

/// Reads the journal, if there is one.
pub fn read(dir: &Path) -> Result<Option<Journal>> {
    let p = dir.join(FILE);
    match fs::read(&p) {
        Ok(b) => serde_json::from_slice(&b)
            .map(Some)
            .map_err(|e| Error::io(p.display(), format!("unreadable journal: {e}"))),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(Error::io(p.display(), e)),
    }
}

/// Removes the journal (the update is complete or was undone).
pub fn remove(dir: &Path) {
    let _ = fs::remove_file(dir.join(FILE));
    sync_dir(dir);
}

/// Puts back what was installed before, for every item. Returns what was done, one line per action.
pub fn restore(j: &Journal) -> Result<Vec<String>> {
    let mut done = Vec::new();
    for it in &j.items {
        let want = (it.dev, it.ino);
        if ident(&it.path) == Some(want) {
            continue;
        }
        let Some(from) = it.candidates.iter().find(|c| ident(c) == Some(want)) else {
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!(
                    "cannot restore {}: the original is in none of {}",
                    it.path.display(),
                    it.candidates
                        .iter()
                        .map(|c| c.display().to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            ));
        };
        if ident(&it.path).is_some() {
            super::exchange(from, &it.path)?;
            done.push(format!(
                "restored {} (swapped back from {})",
                it.path.display(),
                from.display()
            ));
        } else {
            fs::rename(from, &it.path).map_err(|e| Error::io(it.path.display(), e))?;
            done.push(format!(
                "restored {} (moved back from {})",
                it.path.display(),
                from.display()
            ));
        }
    }
    Ok(done)
}

#[cfg(test)]
mod tests {
    use super::*;

    // File identity and the swap are unix-only until WP-29 (`items_are_refused_on_windows`).
    #[cfg(unix)]
    #[test]
    fn restores_by_identity_wherever_the_original_went() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("antennad");
        let staged = d.path().join("staged");
        let prev = d.path().join("antennad.previous");
        fs::write(&a, b"old").unwrap();
        fs::write(&staged, b"new").unwrap();
        let j = Journal {
            action: "install".into(),
            started: crate::utc_now(),
            from: "antennad 1 (a)".into(),
            to: "antennad 2 (b)".into(),
            keeper: super::super::Keeper::NotRunning,
            relaunch: None,
            items: vec![item(&a, vec![staged.clone(), prev.clone()]).unwrap()],
        };
        write(d.path(), &j).unwrap();
        assert_eq!(read(d.path()).unwrap().unwrap(), j);
        // Nothing moved yet: nothing to do.
        assert!(restore(&j).unwrap().is_empty());
        // Swapped: the old one is at the staged path.
        super::super::exchange(&staged, &a).unwrap();
        assert_eq!(fs::read(&a).unwrap(), b"new");
        assert_eq!(restore(&j).unwrap().len(), 1);
        assert_eq!(fs::read(&a).unwrap(), b"old");
        // Swapped and the old one moved on to .previous.
        super::super::exchange(&staged, &a).unwrap();
        fs::rename(&staged, &prev).unwrap();
        restore(&j).unwrap();
        assert_eq!(fs::read(&a).unwrap(), b"old");
        assert_eq!(fs::read(&prev).unwrap(), b"new");
        // The installed path vanished and the original is elsewhere: moved back.
        fs::rename(&a, &staged).unwrap();
        restore(&j).unwrap();
        assert_eq!(fs::read(&a).unwrap(), b"old");
        // The original is somewhere the journal does not know: an error, not a guess. (Moved, not deleted: a deleted
        // file's inode number can be reused by the next file.)
        fs::rename(&a, d.path().join("elsewhere")).unwrap();
        fs::write(&a, b"other").unwrap();
        assert_eq!(restore(&j).unwrap_err().code, code::INSTALL_FAILED);
        remove(d.path());
        assert!(read(d.path()).unwrap().is_none());
    }

    #[cfg(windows)]
    #[test]
    fn items_are_refused_on_windows() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("antennad.exe");
        fs::write(&a, b"old").unwrap();
        assert_eq!(ident(&a), None);
        assert_eq!(
            item(&a, vec![]).unwrap_err().code,
            code::UNSUPPORTED_INSTALL
        );
    }
}
