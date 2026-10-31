// SPDX-License-Identifier: AGPL-3.0-only
//! The data folder on Windows (D-134 WP-4, D-135): made for the user alone, or, when it exists, checked before the
//! daemon reads or writes anything in it; then locked (`data_lock`), so one data folder has one daemon. Nothing is
//! fixed silently: a finding stops the start and names what is wrong.
//!
//! - Made: owned by the user, with a protected DACL of one entry (the user, full control, inherited by everything
//!   inside), set in the same call that makes the folder, so it never exists with the parent's entries. Everything the
//!   daemon makes under it inherits that entry (`owner_only`).
//! - Checked, after Win32-OpenSSH's rule for its key files and stricter: the folder is a real folder (not a junction or
//!   a link); its owner is the user; its DACL is protected and every entry is set on the folder itself (none
//!   inherited); every entry allows or denies, and every allowing entry is the user's, SYSTEM's or the
//!   Administrators'. The last two are logged: they can read any file anyway. Deny entries only take rights away.
//!   Each finding names the SID and the rights.
//! - Locked, by `data_lock` (shared with unix): `antennad.lock` in the folder, locked for the daemon's life. The pipe's
//!   name follows the folder (`antenna_proto::local::control_pipe_name`), but `ANTENNA_SOCKET` can name another pipe,
//!   and the lock still keeps a second daemon out of the folder.

use std::{
    fmt, io,
    path::{Path, PathBuf},
};

use antenna_sys::windows::security::{
    AceKind, DirFacts, SecurityDescriptor, Sid, create_dir, current_user, dir_facts,
};

/// `INHERITED_ACE`: the entry came from a parent.
const INHERITED_ACE: u8 = 0x10;

/// What is wrong with an existing data folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Finding {
    /// A file, not a folder.
    NotAFolder,
    /// A junction or a symbolic link (not followed).
    ReparsePoint,
    /// Owned by someone else (or by nobody).
    Owner(Option<Sid>),
    /// A NULL DACL: everyone may do everything.
    NullDacl,
    /// The DACL takes the parent's entries.
    NotProtected,
    /// An entry inherited from a parent.
    Inherited {
        /// Its trustee.
        sid: Option<Sid>,
        /// Its rights.
        mask: u32,
    },
    /// An entry that neither allows nor denies (object, callback, …), by type.
    OtherEntry(u8),
    /// An entry that gives someone else rights.
    Allowed {
        /// Its trustee.
        sid: Sid,
        /// Its rights.
        mask: u32,
    },
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Finding::NotAFolder => write!(f, "it is a file, not a folder"),
            Finding::ReparsePoint => write!(
                f,
                "it is a junction or a link, which antennad does not follow"
            ),
            Finding::Owner(Some(sid)) => write!(f, "its owner is {}, not you", named(sid)),
            Finding::Owner(None) => write!(f, "it has no owner"),
            Finding::NullDacl => write!(
                f,
                "it has no access list at all, so everyone has every right"
            ),
            Finding::NotProtected => write!(
                f,
                "its access list takes the entries of the folder above it"
            ),
            Finding::Inherited {
                sid: Some(sid),
                mask,
            } => write!(
                f,
                "an entry for {} with {} comes from the folder above it",
                named(sid),
                rights(*mask)
            ),
            Finding::Inherited { sid: None, .. } => {
                write!(f, "an entry comes from the folder above it")
            }
            Finding::OtherEntry(t) => write!(f, "an entry of type {t} that antennad does not read"),
            Finding::Allowed { sid, mask } => {
                write!(f, "{} has {}", named(sid), rights(*mask))
            }
        }
    }
}

/// Why the daemon does not start on this data folder.
#[derive(Debug)]
pub enum Refusal {
    /// The folder could not be made or read.
    Io(PathBuf, io::Error),
    /// It exists and is not the user's alone.
    Weak(PathBuf, Vec<Finding>),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::Io(dir, e) => write!(f, "the data folder {}: {e}", dir.display()),
            Refusal::Weak(dir, findings) => {
                write!(
                    f,
                    "the data folder {} is not yours alone, so antennad does not start and changes nothing:",
                    dir.display()
                )?;
                for x in findings {
                    write!(f, "\n  - {x}")?;
                }
                write!(
                    f,
                    "\nGive the folder your own protected access list (you, and SYSTEM and Administrators if you \
                     wish; nothing inherited), then start antennad again: see docs/TROUBLESHOOTING.md, \"The data \
                     folder is not yours alone\"."
                )
            }
        }
    }
}

/// The data folder, ready: made now or found sound.
#[derive(Debug)]
pub struct Prepared {
    /// Made by this call.
    pub created: bool,
    /// Entries that are accepted but worth a line in the log (SYSTEM, Administrators).
    pub notes: Vec<String>,
}

/// Makes the data folder for the user alone, or checks the one that exists. Its parents, if missing, are made as
/// ordinary folders (they hold nothing of ours).
pub fn prepare(dir: &Path) -> Result<Prepared, Refusal> {
    let io = |e| Refusal::Io(dir.to_path_buf(), e);
    let me = current_user().map_err(io)?;
    let created = match make(dir, &me) {
        Ok(()) => true,
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => false,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            if let Some(parent) = dir.parent().filter(|p| !p.as_os_str().is_empty()) {
                std::fs::create_dir_all(parent).map_err(io)?;
            }
            match make(dir, &me) {
                Ok(()) => true,
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => false,
                Err(e) => return Err(io(e)),
            }
        }
        Err(e) => return Err(io(e)),
    };
    // A folder made just now is read back too: what was asked for is what holds.
    let (findings, notes) = check(&me, &dir_facts(dir).map_err(io)?);
    if findings.is_empty() {
        Ok(Prepared { created, notes })
    } else {
        Err(Refusal::Weak(dir.to_path_buf(), findings))
    }
}

/// The descriptor of a new data folder: owned by the user, the user alone, inherited by everything inside.
fn make(dir: &Path, me: &Sid) -> io::Result<()> {
    create_dir(
        dir,
        &SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;OICI;FA;;;{me})"))?,
    )
}

/// The rule: what is wrong with a folder found on disk, and which accepted entries to log.
pub fn check(me: &Sid, facts: &DirFacts) -> (Vec<Finding>, Vec<String>) {
    let mut findings = Vec::new();
    let mut notes = Vec::new();
    if !facts.directory {
        findings.push(Finding::NotAFolder);
    }
    if facts.reparse_point {
        findings.push(Finding::ReparsePoint);
    }
    if facts.security.owner.as_ref() != Some(me) {
        findings.push(Finding::Owner(facts.security.owner.clone()));
    }
    let Some(dacl) = &facts.security.dacl else {
        findings.push(Finding::NullDacl);
        return (findings, notes);
    };
    if !dacl.protected {
        findings.push(Finding::NotProtected);
    }
    let (system, admins) = (Sid::local_system(), Sid::administrators());
    for ace in &dacl.aces {
        if ace.flags & INHERITED_ACE != 0 {
            findings.push(Finding::Inherited {
                sid: ace.sid.clone(),
                mask: ace.mask,
            });
            continue;
        }
        match (ace.kind, &ace.sid) {
            (AceKind::Deny, _) => {}
            (AceKind::Allow, Some(sid)) if sid == me => {}
            (AceKind::Allow, Some(sid)) if *sid == system || *sid == admins => {
                notes.push(format!("{} has {}", named(sid), rights(ace.mask)));
            }
            (AceKind::Allow, Some(sid)) => findings.push(Finding::Allowed {
                sid: sid.clone(),
                mask: ace.mask,
            }),
            (AceKind::Allow, None) => findings.push(Finding::OtherEntry(0)),
            (AceKind::Other(t), _) => findings.push(Finding::OtherEntry(t)),
        }
    }
    (findings, notes)
}

/// A SID with the name of a well-known one, for messages.
fn named(sid: &Sid) -> String {
    let name = match sid.to_string().as_str() {
        "S-1-1-0" => "Everyone",
        "S-1-3-0" => "CREATOR OWNER",
        "S-1-5-4" => "INTERACTIVE",
        "S-1-5-7" => "ANONYMOUS LOGON",
        "S-1-5-11" => "Authenticated Users",
        "S-1-5-18" => "SYSTEM",
        "S-1-5-32-544" => "Administrators",
        "S-1-5-32-545" => "Users",
        "S-1-5-32-546" => "Guests",
        "S-1-15-2-1" => "ALL APPLICATION PACKAGES",
        s => return s.to_string(),
    };
    format!("{sid} ({name})")
}

/// An access mask in hex, with its usual name when it has one.
fn rights(mask: u32) -> String {
    let name = match mask {
        0x001f_01ff => "full control",
        0x0013_01bf => "modify",
        0x0012_00a9 => "read and execute",
        0x0012_0089 => "read",
        0x0010_0116 => "write",
        0x1000_0000 => "generic all",
        0x8000_0000 => "generic read",
        0x4000_0000 => "generic write",
        _ => return format!("rights {mask:#010x}"),
    };
    format!("rights {mask:#010x} ({name})")
}

#[cfg(test)]
mod tests {
    use antenna_sys::windows::security::{Ace, Dacl, ObjectSecurity};

    use super::*;

    fn me() -> Sid {
        Sid::parse("S-1-5-21-1-2-3-1001").unwrap()
    }

    fn allow(sid: &Sid, flags: u8, mask: u32) -> Ace {
        Ace {
            kind: AceKind::Allow,
            flags,
            mask,
            sid: Some(sid.clone()),
        }
    }

    fn folder(owner: Option<Sid>, protected: bool, aces: Vec<Ace>) -> DirFacts {
        DirFacts {
            directory: true,
            reparse_point: false,
            security: ObjectSecurity {
                owner,
                dacl: Some(Dacl { protected, aces }),
            },
        }
    }

    /// The folder `prepare` makes passes; SYSTEM and Administrators pass with a note; a deny entry for anyone passes.
    #[test]
    fn the_users_own_folder_passes() {
        let me = me();
        let own = folder(Some(me.clone()), true, vec![allow(&me, 0x3, 0x001f_01ff)]);
        assert_eq!(check(&me, &own), (vec![], vec![]));
        let deny_everyone = Ace {
            kind: AceKind::Deny,
            flags: 0x3,
            mask: 0x001f_01ff,
            sid: Some(Sid::parse("S-1-1-0").unwrap()),
        };
        let with_admins = folder(
            Some(me.clone()),
            true,
            vec![
                deny_everyone,
                allow(&me, 0x3, 0x001f_01ff),
                allow(&Sid::local_system(), 0x3, 0x001f_01ff),
                allow(&Sid::administrators(), 0x3, 0x001f_01ff),
            ],
        );
        let (findings, notes) = check(&me, &with_admins);
        assert_eq!(findings, vec![]);
        assert_eq!(
            notes,
            vec![
                "S-1-5-18 (SYSTEM) has rights 0x001f01ff (full control)".to_string(),
                "S-1-5-32-544 (Administrators) has rights 0x001f01ff (full control)".to_string(),
            ]
        );
    }

    /// Each weakness on its own is found, and named with its SID and rights.
    #[test]
    fn each_weakness_is_named() {
        let me = me();
        let other = Sid::parse("S-1-5-21-1-2-3-1002").unwrap();
        let users = Sid::parse("S-1-5-32-545").unwrap();
        let own = || allow(&me, 0x3, 0x001f_01ff);
        let cases: Vec<(DirFacts, Finding, &str)> = vec![
            (
                folder(
                    Some(me.clone()),
                    true,
                    vec![own(), allow(&users, 0x3, 0x0012_00a9)],
                ),
                Finding::Allowed {
                    sid: users.clone(),
                    mask: 0x0012_00a9,
                },
                "S-1-5-32-545 (Users) has rights 0x001200a9 (read and execute)",
            ),
            (
                folder(
                    Some(me.clone()),
                    true,
                    vec![own(), allow(&other, 0x0, 0x0012_0089)],
                ),
                Finding::Allowed {
                    sid: other.clone(),
                    mask: 0x0012_0089,
                },
                "S-1-5-21-1-2-3-1002 has rights 0x00120089 (read)",
            ),
            (
                folder(Some(me.clone()), true, vec![allow(&me, 0x13, 0x001f_01ff)]),
                Finding::Inherited {
                    sid: Some(me.clone()),
                    mask: 0x001f_01ff,
                },
                "an entry for S-1-5-21-1-2-3-1001 with rights 0x001f01ff (full control) comes from the folder above it",
            ),
            (
                folder(Some(me.clone()), false, vec![own()]),
                Finding::NotProtected,
                "takes the entries of the folder above it",
            ),
            (
                folder(Some(Sid::administrators()), true, vec![own()]),
                Finding::Owner(Some(Sid::administrators())),
                "its owner is S-1-5-32-544 (Administrators), not you",
            ),
            (
                folder(
                    Some(me.clone()),
                    true,
                    vec![
                        own(),
                        Ace {
                            kind: AceKind::Other(9),
                            flags: 0,
                            mask: 0,
                            sid: None,
                        },
                    ],
                ),
                Finding::OtherEntry(9),
                "an entry of type 9",
            ),
        ];
        for (facts, want, text) in cases {
            let (findings, _) = check(&me, &facts);
            assert_eq!(findings, vec![want.clone()], "{facts:?}");
            assert!(want.to_string().contains(text), "{want}");
        }
        let mut null = folder(Some(me.clone()), true, vec![]);
        null.security.dacl = None;
        assert_eq!(check(&me, &null).0, vec![Finding::NullDacl]);
        let mut link = folder(Some(me.clone()), true, vec![own()]);
        link.reparse_point = true;
        assert_eq!(check(&me, &link).0, vec![Finding::ReparsePoint]);
        let mut file = folder(Some(me.clone()), true, vec![own()]);
        file.directory = false;
        assert_eq!(check(&me, &file).0, vec![Finding::NotAFolder]);
    }

    /// On disk: `prepare` makes a folder that passes, with only our entry, and passes it again; the control: a folder
    /// made the ordinary way (inheriting from `%TEMP%`) is refused, naming the inherited entries, and left as it was.
    #[test]
    fn a_folder_made_here_passes_and_an_ordinary_one_does_not() {
        let me = current_user().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("a").join("Antenna");
        let made = prepare(&dir).unwrap();
        assert!(made.created && made.notes.is_empty(), "{made:?}");
        let facts = dir_facts(&dir).unwrap();
        assert_eq!(facts.security.owner.as_ref(), Some(&me));
        let dacl = facts.security.dacl.unwrap();
        assert!(dacl.protected);
        assert_eq!(dacl.aces, vec![allow(&me, 0x3, 0x001f_01ff)]);
        assert!(!prepare(&dir).unwrap().created);

        let plain = tmp.path().join("plain");
        std::fs::create_dir(&plain).unwrap();
        let before = dir_facts(&plain).unwrap().security;
        let e = prepare(&plain).unwrap_err();
        eprintln!("FACT an ordinary folder: {e}");
        let Refusal::Weak(_, findings) = &e else {
            panic!("{e}");
        };
        assert!(findings.contains(&Finding::NotProtected), "{e}");
        assert!(
            findings
                .iter()
                .any(|f| matches!(f, Finding::Inherited { sid: Some(s), .. } if *s == me)),
            "{e}"
        );
        assert!(e.to_string().contains(&me.to_string()), "{e}");
        assert_eq!(
            dir_facts(&plain).unwrap().security,
            before,
            "nothing is fixed silently"
        );
    }

    /// A file where the folder should be, and a junction to a sound folder, are refused.
    #[test]
    fn a_file_or_a_junction_is_not_the_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("file");
        std::fs::write(&file, b"x").unwrap();
        let e = prepare(&file).unwrap_err();
        assert!(
            matches!(&e, Refusal::Weak(_, f) if f.contains(&Finding::NotAFolder)),
            "{e}"
        );

        let target = tmp.path().join("target");
        prepare(&target).unwrap();
        let junction = tmp.path().join("junction");
        let ok = std::process::Command::new("cmd")
            .args(["/c", "mklink", "/J"])
            .arg(&junction)
            .arg(&target)
            .output()
            .unwrap();
        assert!(ok.status.success(), "{ok:?}");
        let e = prepare(&junction).unwrap_err();
        eprintln!("FACT a junction: {e}");
        assert!(
            matches!(&e, Refusal::Weak(_, f) if f.contains(&Finding::ReparsePoint)),
            "{e}"
        );
    }

    /// One daemon per folder, in a folder `prepare` made: the lock is taken in it, a second one is refused, and the
    /// lock file cannot be removed while held (`data_lock` holds the portable parts of this test).
    #[test]
    fn the_lock_keeps_a_second_daemon_out() {
        use crate::data_lock::{LOCK_NAME, Refusal, lock};

        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("Antenna");
        prepare(&dir).unwrap();
        let first = lock(&dir).unwrap();
        let e = lock(&dir).unwrap_err();
        assert!(matches!(e, Refusal::Locked(_)), "{e}");
        assert!(e.to_string().contains("another antennad"), "{e}");
        assert!(
            std::fs::remove_file(dir.join(LOCK_NAME)).is_err(),
            "the lock file cannot be removed while held"
        );
        drop(first);
        let _again = lock(&dir).unwrap();
    }
}
