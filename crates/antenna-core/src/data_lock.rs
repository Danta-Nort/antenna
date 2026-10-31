// SPDX-License-Identifier: AGPL-3.0-only
//! One data folder, one daemon: `antennad.lock` in the data folder, locked for the daemon's life (D-134 WP-4, D-135 on
//! Windows; the same rule on unix).
//!
//! The socket (or pipe) is no guard: `--socket` and `ANTENNA_SOCKET` name another one, and two daemons would then
//! share one database, one keystore and one set of ratchet states. The lock is on the folder, whatever the socket is
//! called.
//!
//! - `File::try_lock` is `flock(2)` on unix and `LockFileEx` on Windows. The system drops the lock when the file is
//!   closed, by exit or by crash, so a file left behind never blocks anyone; the file's contents are never read or
//!   written.
//! - Unix: created `0600` like everything else the daemon makes (`owner_only`). Windows: opened with a share mode that
//!   lets no one delete or rename the file while it is held; its access list is the folder's, inherited.
//! - A lock that cannot be taken for another reason (a filesystem without lock support, say) is a refusal that names
//!   the system's error: a check that could not be made is a "no".
//! - Not inherited: Rust opens files close-on-exec, so no child of the daemon (the file check worker, a wake agent, an
//!   installer) keeps a dead daemon's lock alive; the daemon that replaces itself by `execve` after an automatic
//!   update (D-103) gives the lock up with the exec and takes it again as the new image.

use std::{
    fmt,
    fs::{File, OpenOptions, TryLockError},
    io,
    path::{Path, PathBuf},
};

use crate::owner_only::OwnerOnly;

/// `FILE_SHARE_READ | FILE_SHARE_WRITE`: the lock file is never deleted or renamed while it is open.
#[cfg(windows)]
const SHARE_READ_WRITE: u32 = 0x1 | 0x2;

/// The lock file in the data folder.
pub const LOCK_NAME: &str = "antennad.lock";

/// Why the daemon does not start on this data folder.
#[derive(Debug)]
pub enum Refusal {
    /// The lock file could not be opened or locked.
    Io(PathBuf, io::Error),
    /// Another daemon holds its lock.
    Locked(PathBuf),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Io(path, e) => write!(f, "the data folder {}: {e}", path.display()),
            Refusal::Locked(dir) => write!(
                f,
                "another antennad is using the data folder {} (it holds {LOCK_NAME}): stop it first, or give this one \
                 another --data-dir",
                dir.display()
            ),
        }
    }
}

/// Locks the data folder for this daemon's life: the lock goes when the returned file is closed, by exit or crash.
pub fn lock(dir: &Path) -> Result<File, Refusal> {
    let path = dir.join(LOCK_NAME);
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .owner_only();
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(SHARE_READ_WRITE);
    }
    let file = options
        .open(&path)
        .map_err(|e| Refusal::Io(path.clone(), e))?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => Err(Refusal::Locked(dir.to_path_buf())),
        Err(TryLockError::Error(e)) => Err(Refusal::Io(path, e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One daemon per folder: a second lock fails while the first is held, names the folder and the file, and works
    /// once the first is closed. A file left behind by a crash does not block: the lock is the system's, not the
    /// file's.
    #[test]
    fn the_lock_keeps_a_second_daemon_out() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("Antenna");
        std::fs::create_dir(&dir).unwrap();
        let first = lock(&dir).unwrap();
        let e = lock(&dir).unwrap_err();
        assert!(matches!(e, Refusal::Locked(_)), "{e}");
        assert_eq!(
            e.to_string(),
            format!(
                "another antennad is using the data folder {} (it holds antennad.lock): stop it first, or give this \
                 one another --data-dir",
                dir.display()
            )
        );
        #[cfg(windows)]
        assert!(
            std::fs::remove_file(dir.join(LOCK_NAME)).is_err(),
            "the lock file cannot be removed while held"
        );
        drop(first);
        drop(lock(&dir).unwrap());
        assert!(dir.join(LOCK_NAME).is_file(), "left behind, not blocking");
        let _again = lock(&dir).unwrap();
    }

    /// Unix: the lock file is made `0600`. (The daemon also runs under `umask 077`; a test process usually does not,
    /// so this one fails if the file is opened without `owner_only`.)
    #[cfg(unix)]
    #[test]
    fn the_lock_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let _held = lock(tmp.path()).unwrap();
        let mode = std::fs::metadata(tmp.path().join(LOCK_NAME))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "{mode:o}");
    }

    /// A folder that is not there is an I/O refusal naming the lock file, not a panic and not a "held".
    #[test]
    fn a_missing_folder_is_an_io_refusal() {
        let tmp = tempfile::tempdir().unwrap();
        let e = lock(&tmp.path().join("nothing")).unwrap_err();
        assert!(matches!(e, Refusal::Io(..)), "{e}");
        assert!(e.to_string().contains(LOCK_NAME), "{e}");
    }
}
