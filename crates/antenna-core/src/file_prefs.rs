// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's file settings per contact (D-130, `docs/CONTROL.md` §14.4–§14.5): the allowlist of file kinds and the
//! save folders of own computers and their agents. Both are owner commands, absent for agents (SPEC §9); widening
//! takes the password, narrowing an owner session (D-84).

use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError};

use antenna_files::kinds::Allow;
use antenna_proto::{
    LinkId,
    control::{FILE_ALLOW_MAX, FileAllowInfo, FileSaveDir, FileSaveDirs, file_allow_entry},
};
use rusqlite::params;

use crate::{
    error::{Error, Result},
    node::Session,
    now_ms,
    policy::OWN_COMPUTER,
    store::LinkRow,
};

/// Categories first (in their fixed order), then extensions, alphabetically.
fn ordered(mut v: Vec<String>) -> Vec<String> {
    let rank = |e: &str| {
        antenna_proto::control::FILE_ALLOW_CATEGORIES
            .iter()
            .position(|c| *c == e)
            .unwrap_or(usize::MAX)
    };
    v.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));
    v.dedup();
    v
}

/// Hidden or system folders a contact's files are never written into, below the home folder: agent memory and
/// instructions, keys, shell profiles, application state (D-99's protected paths).
fn protected_under_home(rel: &Path) -> bool {
    let Some(first) = rel.components().next() else {
        return true;
    };
    let first = first.as_os_str().to_string_lossy();
    first.starts_with('.') || matches!(first.as_ref(), "Library" | "Applications" | "System")
}

impl Session {
    /// The allowlist entries of a link, ordered.
    pub(crate) fn file_allow_entries(&self, link: &LinkId) -> Vec<String> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let rows = db
            .conn()
            .prepare("SELECT entry FROM file_allow WHERE link_id = ?1")
            .and_then(|mut s| {
                s.query_map(params![link.0.to_vec()], |r| r.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()
            })
            .unwrap_or_default();
        ordered(rows)
    }

    /// The allowlist of a link, as the file rules read it.
    pub(crate) fn file_allow(&self, link: &LinkId) -> Allow {
        Allow::from_entries(&self.file_allow_entries(link))
    }

    fn allow_info(&self, row: &LinkRow) -> FileAllowInfo {
        FileAllowInfo {
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            entries: self.file_allow_entries(&row.link_id),
        }
    }

    /// `file_allow` (the caller checked the password): adds entries to a contact's allowlist. `executables` and
    /// `installers` only for a contact at level 5; level 1 exchanges no files at all.
    pub async fn owner_file_allow(
        self: &Arc<Self>,
        contact: &str,
        entries: &[String],
    ) -> Result<FileAllowInfo> {
        let row = self.find_link(contact)?;
        if row.trust < OWN_COMPUTER {
            return Err(Error::bad_request(
                "the allowlist is for your own computers (∞, trust level 5): from anyone else programs and \
                 installers always wait for you, and other files are not held anyway from level 3",
            ));
        }
        if entries.is_empty() {
            return Err(Error::bad_request(
                "nothing to allow: give executables, installers or an extension such as .dmg",
            ));
        }
        let mut parsed = Vec::new();
        for e in entries {
            let Some(p) = file_allow_entry(e) else {
                return Err(Error::bad_request(format!(
                    "{:?} is not an allowlist entry: executables, installers, or an extension such as .dmg",
                    antenna_files::text::escape_visible(e, 40)
                )));
            };
            parsed.push(p);
        }
        let mut all = self.file_allow_entries(&row.link_id);
        all.extend(parsed.iter().cloned());
        if ordered(all).len() > FILE_ALLOW_MAX {
            return Err(Error::bad_request(format!(
                "at most {FILE_ALLOW_MAX} entries per contact"
            )));
        }
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            for p in &parsed {
                db.conn().execute(
                    "INSERT OR IGNORE INTO file_allow(link_id, entry, created_ms) VALUES (?1, ?2, ?3)",
                    params![row.link_id.0.to_vec(), p, now_ms() as i64],
                )?;
            }
        }
        self.receipt(
            &row.link_id,
            "owner",
            "file_allow",
            "allowed",
            &parsed.join(" "),
            None,
            None,
        );
        // At level 5 a file held only for a kind the owner allows now is saved at once
        if row.trust >= OWN_COMPUTER {
            self.reconsider_held(&row).await;
        }
        Ok(self.allow_info(&row))
    }

    /// `file_disallow` (an owner session): takes entries off; none given, all of them.
    pub async fn owner_file_disallow(
        &self,
        contact: &str,
        entries: &[String],
    ) -> Result<FileAllowInfo> {
        let row = self.find_link(contact)?;
        let parsed: Vec<String> = entries.iter().filter_map(|e| file_allow_entry(e)).collect();
        if parsed.len() != entries.len() {
            return Err(Error::bad_request(
                "an entry is executables, installers, or an extension such as .dmg",
            ));
        }
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            if parsed.is_empty() {
                db.conn().execute(
                    "DELETE FROM file_allow WHERE link_id = ?1",
                    params![row.link_id.0.to_vec()],
                )?;
            } else {
                for p in &parsed {
                    db.conn().execute(
                        "DELETE FROM file_allow WHERE link_id = ?1 AND entry = ?2",
                        params![row.link_id.0.to_vec(), p],
                    )?;
                }
            }
        }
        self.receipt(
            &row.link_id,
            "owner",
            "file_allow",
            "revoked",
            &if parsed.is_empty() {
                "all".to_string()
            } else {
                parsed.join(" ")
            },
            None,
            None,
        );
        Ok(self.allow_info(&row))
    }

    /// The save folders of a link: the contact's own first, then its agents' by name.
    pub(crate) fn save_dirs(&self, link: &LinkId) -> Vec<FileSaveDir> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let mut v: Vec<FileSaveDir> = db
            .conn()
            .prepare("SELECT agent, path FROM file_save_dirs WHERE link_id = ?1 ORDER BY agent")
            .and_then(|mut s| {
                s.query_map(params![link.0.to_vec()], |r| {
                    let agent: String = r.get(0)?;
                    Ok(FileSaveDir {
                        agent: (!agent.is_empty()).then_some(agent),
                        path: r.get(1)?,
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()
            })
            .unwrap_or_default();
        v.sort_by_key(|d| d.agent.is_some());
        v
    }

    /// Where a file from `row` is saved at level 5 (D-130): the folder of the agent that signed the offer, else the
    /// contact's, else the daemon's `--project-dir`; `None`: the link folder. Below level 5, always `None`.
    pub(crate) fn save_dir_for(
        &self,
        row: &LinkRow,
        level: u8,
        agent: Option<&str>,
    ) -> Option<PathBuf> {
        if level < OWN_COMPUTER {
            return None;
        }
        let dirs = self.save_dirs(&row.link_id);
        let pick = |a: Option<&str>| {
            dirs.iter()
                .find(|d| d.agent.as_deref() == a)
                .map(|d| PathBuf::from(&d.path))
        };
        agent
            .and_then(|a| pick(Some(a)))
            .or_else(|| pick(None))
            .or_else(|| self.files().ok().and_then(|f| f.cfg.project_dir.clone()))
    }

    /// A folder the owner names for a contact's files: an existing directory in the owner's home, symlinks resolved,
    /// not the home itself, not a hidden or system folder, not in Antenna's data or links folders.
    fn valid_save_dir(&self, path: &str) -> Result<PathBuf> {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .and_then(|h| std::fs::canonicalize(h).ok())
            .ok_or_else(|| Error::bad_request("this daemon has no home folder to save files in"))?;
        let raw = match path.strip_prefix("~/") {
            Some(rest) => home.join(rest),
            None => PathBuf::from(path),
        };
        if !raw.is_absolute() {
            return Err(Error::bad_request(
                "the folder must be an absolute path or start with ~/",
            ));
        }
        let real = std::fs::canonicalize(&raw)
            .map_err(|_| Error::bad_request("there is no such folder: create it first"))?;
        if !std::fs::metadata(&real).is_ok_and(|m| m.is_dir()) {
            return Err(Error::bad_request("this is not a folder"));
        }
        let rel = real
            .strip_prefix(&home)
            .map_err(|_| Error::bad_request("the folder must be inside your home folder"))?;
        if protected_under_home(rel) {
            return Err(Error::bad_request(
                "not the home folder itself, a hidden folder or a system folder: choose a folder such as \
                 ~/Desktop/Volna",
            ));
        }
        let inside = |base: &Path| std::fs::canonicalize(base).is_ok_and(|b| real.starts_with(&b));
        if inside(&self.cfg.data_dir) {
            return Err(Error::bad_request("not inside Antenna's data folder"));
        }
        if let Ok(f) = self.files()
            && (inside(&f.cfg.links_dir) || real.starts_with(&f.cfg.links_dir))
        {
            return Err(Error::bad_request(
                "not inside Antenna's link folders: those are the default already",
            ));
        }
        Ok(real)
    }

    /// `file_save_dir` (setting one: the caller checked the password): where files from an own computer, or from one
    /// of its agents, are saved.
    pub async fn owner_file_save_dir(
        &self,
        contact: &str,
        agent: Option<&str>,
        path: Option<&str>,
    ) -> Result<FileSaveDirs> {
        let row = self.find_link(contact)?;
        let agent = agent.map(str::trim).filter(|a| !a.is_empty());
        if let Some(a) = agent
            && !antenna_proto::AgentAnnounce::valid_name(a)
        {
            return Err(Error::bad_request(
                "an agent name is [A-Za-z0-9._-], 1 to 64 characters",
            ));
        }
        match path {
            Some(p) => {
                if row.trust < OWN_COMPUTER {
                    return Err(Error::bad_request(
                        "a save folder is for your own computer (∞, trust level 5): from anyone else files stay in \
                         the link folder, so that what an agent reads there is known as that contact's data",
                    ));
                }
                let real = self.valid_save_dir(p)?;
                let shown = real.to_string_lossy().into_owned();
                {
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    db.conn().execute(
                        "INSERT INTO file_save_dirs(link_id, agent, path, created_ms) VALUES (?1, ?2, ?3, ?4)
                         ON CONFLICT(link_id, agent) DO UPDATE SET path = excluded.path, created_ms = excluded.created_ms",
                        params![row.link_id.0.to_vec(), agent.unwrap_or(""), shown, now_ms() as i64],
                    )?;
                }
                self.receipt(
                    &row.link_id,
                    "owner",
                    "file_save_dir",
                    "allowed",
                    &format!("{} → {shown}", agent.unwrap_or("contact")),
                    None,
                    None,
                );
            }
            None => {
                {
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    db.conn().execute(
                        "DELETE FROM file_save_dirs WHERE link_id = ?1 AND agent = ?2",
                        params![row.link_id.0.to_vec(), agent.unwrap_or("")],
                    )?;
                }
                self.receipt(
                    &row.link_id,
                    "owner",
                    "file_save_dir",
                    "revoked",
                    agent.unwrap_or("contact"),
                    None,
                    None,
                );
            }
        }
        Ok(FileSaveDirs {
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            dirs: self.save_dirs(&row.link_id),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_are_ordered_and_hidden_folders_protected() {
        assert_eq!(
            ordered(vec![
                ".wasm".into(),
                "executables".into(),
                ".bin".into(),
                "installers".into(),
                "executables".into()
            ]),
            ["executables", "installers", ".bin", ".wasm"]
        );
        for p in [".ssh", ".claude/x", "Library/Preferences", ""] {
            assert!(protected_under_home(Path::new(p)), "{p}");
        }
        for p in ["Desktop/Volna", "work/antenna"] {
            assert!(!protected_under_home(Path::new(p)), "{p}");
        }
    }
}
