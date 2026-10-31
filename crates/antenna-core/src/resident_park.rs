// SPDX-License-Identifier: AGPL-3.0-only
//! Resident transcripts at rest (PG-24, D-121): while a resident agent (D-93) sleeps, its session's files are not on
//! disk in plain text. The agent CLI keeps its transcript and the agent its notes in the session's HOME and working
//! folder (`<data>/wake/resident/<link>/home`, `work`); both hold what the contact wrote. When the process ends (the
//! idle stop, a crash, `antenna lock`, the daemon stopping) the daemon **parks** them: it reads every file into one
//! record of the node's database, which SQLCipher encrypts like the rest of the history, and deletes the files. The
//! next start **unparks** them before the agent CLI resumes the session. No new cryptography: the database's own.
//!
//! - Symbolic links are kept as links and never followed, so an agent cannot make the daemon read a file outside its
//!   folders into the record; files with more than one hard link are left out for the same reason.
//! - A session over [`MAX_PARK_BYTES`] is not parked: the files stay where they are and the owner is told (the
//!   `resident` event and the log), rather than the daemon holding it all in memory.
//! - A daemon that died with a process running leaves the files in plain text; the next unlock parks them
//!   ([`Session::resident_park_leftovers`]).

use std::path::{Component, Path, PathBuf};
use std::sync::PoisonError;

use antenna_proto::LinkId;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::node::Session;

/// The largest session the daemon parks, in bytes of file content.
pub(crate) const MAX_PARK_BYTES: u64 = 64 * 1024 * 1024;

/// The folders of a session that are parked; `tmp` is only removed.
const PARKED: [&str; 2] = ["home", "work"];

/// The record's format.
const PARK_VERSION: u8 = 1;

#[derive(Serialize, Deserialize)]
struct ParkRecord {
    v: u8,
    entries: Vec<Entry>,
}

/// One directory, file or symbolic link, by its path under the session's folder (`home/…`, `work/…`).
#[derive(Serialize, Deserialize)]
struct Entry {
    path: String,
    kind: Kind,
    mode: u32,
    #[serde(with = "serde_bytes", default)]
    data: Vec<u8>,
}

#[derive(Serialize, Deserialize, PartialEq, Eq, Debug)]
enum Kind {
    Dir,
    File,
    /// The link's target, as it was written (never resolved).
    Link(String),
}

/// What parking did.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Parked {
    /// Nothing on disk to park.
    Nothing,
    /// Parked: files and bytes.
    Done(u64, u64),
    /// Too large to park: the files stay on disk.
    TooLarge(u64),
}

/// A path under the session's folder as stored: relative, `/`-separated, only normal components.
#[cfg_attr(
    windows,
    allow(
        dead_code,
        reason = "the unix park uses it; the path rules are tested on every OS"
    )
)]
fn rel_of(base: &Path, p: &Path) -> Option<String> {
    let r = p.strip_prefix(base).ok()?;
    let mut parts = Vec::new();
    for c in r.components() {
        match c {
            Component::Normal(s) => parts.push(s.to_str()?.to_string()),
            _ => return None,
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

/// The stored path back under `base`, refusing anything that would leave it.
#[cfg_attr(
    windows,
    allow(
        dead_code,
        reason = "the unix unpark uses it; the path rules are tested on every OS"
    )
)]
fn path_in(base: &Path, rel: &str) -> Option<PathBuf> {
    let mut out = base.to_path_buf();
    let mut any = false;
    for part in rel.split('/') {
        if part.is_empty() || part == "." || part == ".." || part.contains('\0') {
            return None;
        }
        out.push(part);
        any = true;
    }
    let top = rel.split('/').next()?;
    (any && PARKED.contains(&top)).then_some(out)
}

/// Every entry under `dir`, depth first, without following symbolic links.
#[cfg(unix)]
fn walk(base: &Path, dir: &Path, out: &mut Vec<Entry>, bytes: &mut u64) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let mut items: Vec<_> = std::fs::read_dir(dir)?.flatten().collect();
    items.sort_by_key(std::fs::DirEntry::file_name);
    for item in items {
        let p = item.path();
        let Some(rel) = rel_of(base, &p) else {
            continue;
        };
        let meta = std::fs::symlink_metadata(&p)?;
        let mode = meta.permissions().mode() & 0o777;
        let ft = meta.file_type();
        if ft.is_symlink() {
            let target = std::fs::read_link(&p)?;
            if let Some(t) = target.to_str() {
                out.push(Entry {
                    path: rel,
                    kind: Kind::Link(t.to_string()),
                    mode,
                    data: Vec::new(),
                });
            }
        } else if ft.is_dir() {
            out.push(Entry {
                path: rel,
                kind: Kind::Dir,
                mode,
                data: Vec::new(),
            });
            walk(base, &p, out, bytes)?;
        } else if ft.is_file() && meta.nlink() == 1 {
            *bytes += meta.len();
            if *bytes > MAX_PARK_BYTES {
                return Ok(());
            }
            out.push(Entry {
                path: rel,
                kind: Kind::File,
                mode,
                data: std::fs::read(&p)?,
            });
        }
        // Sockets, pipes, devices and hard-linked files are not kept
    }
    Ok(())
}

/// Windows: resident agents need the agent sandbox there (D-134, WP-20, phase W3), so no session has files to park;
/// refused.
#[cfg(windows)]
fn walk(_base: &Path, _dir: &Path, _out: &mut Vec<Entry>, _bytes: &mut u64) -> Result<()> {
    Err(not_on_windows())
}

#[cfg(windows)]
fn not_on_windows() -> Error {
    Error::new(
        antenna_proto::control::code::NOT_IMPLEMENTED,
        "resident agents are not available on Windows yet",
    )
}

impl Session {
    /// Park link `link`'s resident session: its files into the database, then off the disk. Call only while no
    /// process of the session runs.
    pub(crate) fn resident_park(&self, link: &LinkId) -> Result<Parked> {
        let dir = self.resident_dir(link);
        let mut entries = Vec::new();
        let mut bytes = 0u64;
        for top in PARKED {
            let d = dir.join(top);
            if std::fs::symlink_metadata(&d).is_ok_and(|m| m.is_dir()) {
                entries.push(Entry {
                    path: top.to_string(),
                    kind: Kind::Dir,
                    mode: 0o700,
                    data: Vec::new(),
                });
                walk(&dir, &d, &mut entries, &mut bytes)?;
            }
        }
        if bytes > MAX_PARK_BYTES {
            return Ok(Parked::TooLarge(bytes));
        }
        let files = entries.iter().filter(|e| e.kind == Kind::File).count() as u64;
        if entries.iter().all(|e| e.kind == Kind::Dir) {
            // Empty folders: nothing worth a record; the folders go
            self.resident_remove_files(link);
            return Ok(Parked::Nothing);
        }
        let blob = antenna_proto::to_cbor(&ParkRecord {
            v: PARK_VERSION,
            entries,
        })?;
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db.conn().execute(
                "INSERT INTO resident_park(link_id, data, files, bytes, parked_ms) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(link_id) DO UPDATE SET data = excluded.data, files = excluded.files,
                 bytes = excluded.bytes, parked_ms = excluded.parked_ms",
                params![
                    &link.0[..],
                    blob,
                    files as i64,
                    bytes as i64,
                    crate::now_ms() as i64
                ],
            )?;
        }
        // Only after the record is committed
        self.resident_remove_files(link);
        Ok(Parked::Done(files, bytes))
    }

    /// Restore a parked session before its process starts; the record goes once the files are back.
    #[cfg(unix)]
    pub(crate) fn resident_unpark(&self, link: &LinkId) -> Result<()> {
        use std::os::unix::fs::PermissionsExt;
        let blob: Option<Vec<u8>> = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db.conn()
                .query_row(
                    "SELECT data FROM resident_park WHERE link_id = ?1",
                    params![&link.0[..]],
                    |r| r.get(0),
                )
                .optional()?
        };
        let Some(blob) = blob else {
            return Ok(());
        };
        let parked: ParkRecord = antenna_proto::from_cbor(&blob)?;
        if parked.v != PARK_VERSION {
            return Err(Error::internal("parked session: unknown format"));
        }
        let dir = self.resident_dir(link);
        std::fs::create_dir_all(&dir)?;
        for e in &parked.entries {
            let p = path_in(&dir, &e.path)
                .ok_or_else(|| Error::internal("parked session: a path outside its folders"))?;
            match &e.kind {
                Kind::Dir => {
                    std::fs::create_dir_all(&p)?;
                    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(e.mode | 0o700))?;
                }
                Kind::File => {
                    if let Some(parent) = p.parent() {
                        std::fs::create_dir_all(parent)?;
                    }
                    // A plain file the daemon creates anew: whatever stands there (a link left by a crash) goes first
                    let _ = std::fs::remove_file(&p);
                    std::fs::write(&p, &e.data)?;
                    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(e.mode))?;
                }
                Kind::Link(target) => {
                    let _ = std::fs::remove_file(&p);
                    std::os::unix::fs::symlink(target, &p)?;
                }
            }
        }
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db.conn().execute(
            "DELETE FROM resident_park WHERE link_id = ?1",
            params![&link.0[..]],
        )?;
        Ok(())
    }

    /// Windows: refused (no resident session runs there yet, WP-20); a record parked elsewhere stays in the database.
    #[cfg(windows)]
    pub(crate) fn resident_unpark(&self, _link: &LinkId) -> Result<()> {
        Err(not_on_windows())
    }

    /// The session's record goes with the session (a reset, wake off).
    pub(crate) fn resident_park_forget(&self, link: &LinkId) {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = db.conn().execute(
            "DELETE FROM resident_park WHERE link_id = ?1",
            params![&link.0[..]],
        );
    }

    /// Whether link `link` has a parked session (for tests and the session view).
    pub(crate) fn resident_parked(&self, link: &LinkId) -> bool {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db.conn()
            .query_row(
                "SELECT 1 FROM resident_park WHERE link_id = ?1",
                params![&link.0[..]],
                |_| Ok(()),
            )
            .optional()
            .ok()
            .flatten()
            .is_some()
    }

    fn resident_remove_files(&self, link: &LinkId) {
        let dir = self.resident_dir(link);
        for top in PARKED.iter().chain(["tmp"].iter()) {
            let _ = std::fs::remove_dir_all(dir.join(top));
        }
    }

    /// After an unlock: sessions a dead daemon left on disk are parked now (no resident process runs yet).
    pub(crate) fn resident_park_leftovers(&self) {
        let base = self.cfg.data_dir.join("wake").join("resident");
        let Ok(dirs) = std::fs::read_dir(&base) else {
            return;
        };
        let links = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()
            .unwrap_or_default();
        for d in dirs.flatten() {
            let name = d.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            let Some(row) = links.iter().find(|r| r.link_id.to_hex().starts_with(name)) else {
                continue;
            };
            if !PARKED.iter().any(|t| d.path().join(t).exists()) {
                continue;
            }
            match self.resident_park(&row.link_id) {
                Ok(Parked::TooLarge(b)) => tracing::warn!(
                    "resident session of {}: {b} bytes, over the limit to keep it encrypted; its files stay on disk",
                    &row.link_id.to_hex()[..8]
                ),
                Ok(_) => {}
                Err(e) => tracing::warn!(
                    "resident session of {}: cannot park it: {}",
                    &row.link_id.to_hex()[..8],
                    e.message
                ),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_paths_stay_inside_the_session_folders() {
        let base = Path::new("/data/wake/resident/abcd");
        assert_eq!(
            path_in(base, "home/.claude/projects/x.jsonl"),
            Some(base.join("home/.claude/projects/x.jsonl"))
        );
        assert_eq!(
            path_in(base, "work/notes.md"),
            Some(base.join("work/notes.md"))
        );
        for bad in [
            "",
            "home/../../keystore.cbor",
            "/etc/passwd",
            "tmp/x",
            "home//x",
            "home/./x",
            "proxy.sock",
        ] {
            assert_eq!(path_in(base, bad), None, "{bad}");
        }
        assert_eq!(
            rel_of(base, &base.join("home/a/b")),
            Some("home/a/b".to_string())
        );
        assert_eq!(rel_of(base, Path::new("/elsewhere")), None);
    }

    // Unix symlinks and link counts; Windows has no resident sessions yet (WP-20).
    #[cfg(unix)]
    #[test]
    fn walking_keeps_links_as_links_and_skips_hard_links() {
        let t = tempfile::tempdir().unwrap();
        let base = t.path();
        let home = base.join("home");
        std::fs::create_dir_all(home.join("sub")).unwrap();
        std::fs::write(home.join("sub/t.jsonl"), b"transcript").unwrap();
        let secret = base.join("secret");
        std::fs::write(&secret, b"KEYSTORE").unwrap();
        std::os::unix::fs::symlink(&secret, home.join("ln")).unwrap();
        std::fs::hard_link(&secret, home.join("hard")).unwrap();
        let mut out = Vec::new();
        let mut bytes = 0;
        walk(base, &home, &mut out, &mut bytes).unwrap();
        let paths: Vec<&str> = out.iter().map(|e| e.path.as_str()).collect();
        assert_eq!(paths, ["home/ln", "home/sub", "home/sub/t.jsonl"]);
        assert_eq!(
            out[0].kind,
            Kind::Link(secret.to_str().unwrap().to_string())
        );
        assert!(
            out.iter().all(|e| e.data != b"KEYSTORE"),
            "a link is never followed"
        );
        assert_eq!(bytes, 10);
    }
}
