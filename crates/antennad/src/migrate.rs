// SPDX-License-Identifier: AGPL-3.0-only
//! Migration from the `x` preview build (from before the rename to Antenna on 2026-10-02, DECISIONS D-56): the data
//! directory `~/.local/share/x` → `~/.local/share/antenna`, the database file `x.db` → `antenna.db`, the link folders
//! `~/X/links` → `~/Antenna/links`. Once, at daemon startup, before anything in the directory is opened.
//!
//! Each step is a `rename(2)` within one parent directory: atomic, without copying; a retry after a failure continues
//! from where it stopped. The data directory is not moved out from under a running old daemon: if its socket answers,
//! `antennad` does not start and says what to do.

use std::path::{Path, PathBuf};

use antenna_core::store::{FILE_NAME, LEGACY_FILE_NAME};
use antenna_proto::local::LEGACY_SOCKET_NAME;

/// What a migration step did.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// There is no old one (or the new one is already in place and the old one is absent): nothing to do.
    Nothing,
    /// Moved.
    Moved {
        /// From.
        from: PathBuf,
        /// To.
        to: PathBuf,
    },
    /// Both the old and the new exist: the new one is used, the old one is left alone (the owner decides).
    BothExist {
        /// The old one.
        old: PathBuf,
    },
}

fn exists(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok()
}

fn is_real_dir(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok_and(|m| m.is_dir())
}

/// Flushes the directory's renames to disk (otherwise after a power loss the directory could "come back").
fn sync_dir(p: &Path) {
    if let Ok(f) = std::fs::File::open(p) {
        let _ = f.sync_all();
    }
}

/// Default data directory: if the new one is absent and the old one exists, rename the old one to the new one.
/// Refuses if the old daemon is still running (its socket `xd.sock` accepts connections).
pub fn data_dir(new: &Path, old: &Path) -> Result<Outcome, String> {
    if exists(new) {
        return Ok(if is_real_dir(old) {
            Outcome::BothExist {
                old: old.to_path_buf(),
            }
        } else {
            Outcome::Nothing
        });
    }
    if !is_real_dir(old) {
        return Ok(Outcome::Nothing);
    }
    let old_socket = old.join(LEGACY_SOCKET_NAME);
    #[cfg(unix)]
    let running = std::os::unix::net::UnixStream::connect(&old_socket).is_ok();
    // The preview build `x` ran only on Linux and macOS: on Windows no daemon of it can be running.
    #[cfg(windows)]
    let running = false;
    if running {
        return Err(format!(
            "the daemon of the preview build `x` is still running with data in {} (socket {}); stop it first \
             (macOS: opening the Antenna window does it; Linux: systemctl --user disable --now xd), then start \
             antennad again — it moves the data to {} once",
            old.display(),
            old_socket.display(),
            new.display()
        ));
    }
    std::fs::rename(old, new).map_err(|e| {
        format!(
            "cannot move the data of the preview build from {} to {}: {e}",
            old.display(),
            new.display()
        )
    })?;
    if let Some(parent) = new.parent() {
        sync_dir(parent);
    }
    // After a crash the old daemon's socket may have been left as a file; it is no longer needed.
    let _ = std::fs::remove_file(new.join(LEGACY_SOCKET_NAME));
    Ok(Outcome::Moved {
        from: old.to_path_buf(),
        to: new.to_path_buf(),
    })
}

/// Database file of the preview build (`x.db` with `-wal`, `-shm`, `-journal`) → [`FILE_NAME`]. The sidecar files go
/// first, then the file itself: an interrupted migration is completed on the next start, and the database is never
/// opened without its WAL.
pub fn db_file(dir: &Path) -> Result<Outcome, String> {
    let old = dir.join(LEGACY_FILE_NAME);
    let new = dir.join(FILE_NAME);
    if !exists(&old) {
        return Ok(Outcome::Nothing);
    }
    if exists(&new) {
        return Ok(Outcome::BothExist { old });
    }
    for suffix in ["-wal", "-shm", "-journal"] {
        let from = dir.join(format!("{LEGACY_FILE_NAME}{suffix}"));
        if !exists(&from) {
            continue;
        }
        let to = dir.join(format!("{FILE_NAME}{suffix}"));
        if exists(&to) {
            return Err(format!(
                "both {} and {} exist: move one of them away by hand",
                from.display(),
                to.display()
            ));
        }
        std::fs::rename(&from, &to)
            .map_err(|e| format!("cannot rename {}: {e}", from.display()))?;
    }
    std::fs::rename(&old, &new).map_err(|e| format!("cannot rename {}: {e}", old.display()))?;
    sync_dir(dir);
    Ok(Outcome::Moved { from: old, to: new })
}

/// Default link folders: `~/X/links` → `~/Antenna/links`; an empty `~/X` is removed afterwards. If this fails (for
/// example, `~/X` is on another partition), the result is `Err`: the daemon then works with the old folder and nothing
/// is lost.
pub fn links_dir(new: &Path, old: &Path) -> Result<Outcome, String> {
    if exists(new) {
        return Ok(if is_real_dir(old) {
            Outcome::BothExist {
                old: old.to_path_buf(),
            }
        } else {
            Outcome::Nothing
        });
    }
    if !is_real_dir(old) {
        return Ok(Outcome::Nothing);
    }
    if let Some(parent) = new.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    std::fs::rename(old, new).map_err(|e| {
        format!(
            "cannot move the link folders from {} to {}: {e}",
            old.display(),
            new.display()
        )
    })?;
    if let Some(parent) = new.parent() {
        sync_dir(parent);
    }
    if let Some(old_parent) = old.parent() {
        // `~/X` only if it is empty (it may hold the owner's other files).
        let _ = std::fs::remove_dir(old_parent);
    }
    Ok(Outcome::Moved {
        from: old.to_path_buf(),
        to: new.to_path_buf(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_dir_moves_once_and_keeps_contents() {
        let t = tempfile::tempdir().unwrap();
        let (old, new) = (t.path().join("x"), t.path().join("antenna"));
        std::fs::create_dir(&old).unwrap();
        std::fs::write(old.join("keystore.cbor"), b"k").unwrap();
        std::fs::write(old.join(LEGACY_SOCKET_NAME), b"").unwrap(); // A socket left over after a crash.
        assert_eq!(
            data_dir(&new, &old).unwrap(),
            Outcome::Moved {
                from: old.clone(),
                to: new.clone()
            }
        );
        assert!(!old.exists());
        assert_eq!(std::fs::read(new.join("keystore.cbor")).unwrap(), b"k");
        assert!(!new.join(LEGACY_SOCKET_NAME).exists());
        // Second start: nothing.
        assert_eq!(data_dir(&new, &old).unwrap(), Outcome::Nothing);
    }

    // A unix socket: the preview build ran only on Linux and macOS.
    #[cfg(unix)]
    #[test]
    fn data_dir_is_not_moved_from_under_a_running_daemon() {
        let t = tempfile::tempdir().unwrap();
        let (old, new) = (t.path().join("x"), t.path().join("antenna"));
        std::fs::create_dir(&old).unwrap();
        let _listener =
            std::os::unix::net::UnixListener::bind(old.join(LEGACY_SOCKET_NAME)).unwrap();
        let e = data_dir(&new, &old).unwrap_err();
        assert!(e.contains("still running"), "{e}");
        assert!(old.exists() && !new.exists());
    }

    #[test]
    fn both_dirs_exist_new_wins() {
        let t = tempfile::tempdir().unwrap();
        let (old, new) = (t.path().join("x"), t.path().join("antenna"));
        std::fs::create_dir(&old).unwrap();
        std::fs::create_dir(&new).unwrap();
        assert_eq!(
            data_dir(&new, &old).unwrap(),
            Outcome::BothExist { old: old.clone() }
        );
        assert!(old.exists() && new.exists());
        // No old one at all.
        let t2 = tempfile::tempdir().unwrap();
        assert_eq!(
            data_dir(&t2.path().join("a"), &t2.path().join("x")).unwrap(),
            Outcome::Nothing
        );
    }

    #[test]
    fn db_file_with_sidecars_and_interrupted_run() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path();
        std::fs::write(d.join("x.db"), b"db").unwrap();
        std::fs::write(d.join("x.db-wal"), b"wal").unwrap();
        // An interrupted earlier migration: `-shm` has already been renamed, the rest has not.
        std::fs::write(d.join(format!("{FILE_NAME}-shm")), b"shm").unwrap();
        assert!(matches!(db_file(d).unwrap(), Outcome::Moved { .. }));
        assert_eq!(std::fs::read(d.join(FILE_NAME)).unwrap(), b"db");
        assert_eq!(
            std::fs::read(d.join(format!("{FILE_NAME}-wal"))).unwrap(),
            b"wal"
        );
        assert_eq!(
            std::fs::read(d.join(format!("{FILE_NAME}-shm"))).unwrap(),
            b"shm"
        );
        assert!(!d.join("x.db").exists() && !d.join("x.db-wal").exists());
        assert_eq!(db_file(d).unwrap(), Outcome::Nothing);
    }

    #[test]
    fn db_file_conflicts_are_not_resolved_silently() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path();
        std::fs::write(d.join("x.db"), b"old").unwrap();
        std::fs::write(d.join("x.db-wal"), b"old wal").unwrap();
        std::fs::write(d.join(format!("{FILE_NAME}-wal")), b"other wal").unwrap();
        assert!(db_file(d).unwrap_err().contains("both"));
        assert_eq!(std::fs::read(d.join("x.db")).unwrap(), b"old");
        // Both databases: the new one is primary, the old one stays.
        std::fs::write(d.join(FILE_NAME), b"new").unwrap();
        assert!(matches!(db_file(d).unwrap(), Outcome::BothExist { .. }));
        assert_eq!(std::fs::read(d.join(FILE_NAME)).unwrap(), b"new");
    }

    #[test]
    fn links_move_and_empty_parent_is_removed() {
        let t = tempfile::tempdir().unwrap();
        let home = t.path();
        let (old, new) = (home.join("X/links"), home.join("Antenna/links"));
        std::fs::create_dir_all(old.join("alice/shared")).unwrap();
        std::fs::write(old.join("alice/shared/note.txt"), b"n").unwrap();
        assert!(matches!(
            links_dir(&new, &old).unwrap(),
            Outcome::Moved { .. }
        ));
        assert_eq!(
            std::fs::read(new.join("alice/shared/note.txt")).unwrap(),
            b"n"
        );
        assert!(!home.join("X").exists(), "empty ~/X is removed");
        // ~/X holds something of its own, so ~/X stays.
        let t = tempfile::tempdir().unwrap();
        let home = t.path();
        let (old, new) = (home.join("X/links"), home.join("Antenna/links"));
        std::fs::create_dir_all(&old).unwrap();
        std::fs::write(home.join("X/mine.txt"), b"m").unwrap();
        assert!(matches!(
            links_dir(&new, &old).unwrap(),
            Outcome::Moved { .. }
        ));
        assert!(home.join("X/mine.txt").exists() && new.exists());
    }
}
