// SPDX-License-Identifier: AGPL-3.0-only
//! What holds a received file for its owner, and what is only a label (maintainer decision D-130, amending SPEC
//! §10–§11): at trust levels 3–5 the check's heuristics never hold a file.
//!
//! The check (D-F-9) finds two kinds of things. **Facts** about what the file does when opened: it is a native
//! program, an installer or a disk image, an archive holding one, a known signature (the antivirus hook, EICAR, the
//! owner's own YARA rules), or the check could not run. **Heuristics** about what it might be: markup or a script in a
//! file (`active_content`, `polyglot_html`), a secret pattern, an unknown type, a structure the previews cannot
//! read. At levels 3–5 heuristics are labels on the card and in the agent's `inbox.files`, and the file is accepted
//! the normal way for its level (the daemon saves it at level 5, an agent or the owner accepts it at 3–4). Facts hold
//! it for the owner, who keeps it anyway with the password, as a browser keeps a dangerous download. At levels 3–4,
//! archives that could not be opened whole or have a dangerous structure are held too. Levels 1–2 are unchanged.
//!
//! Inputs are the check report and the file name; nothing here reads the file (the content was looked at in the
//! check sandbox, and the daemon's own look at its magic numbers is [`guard_class`]).

use antenna_proto::files::fate;

use crate::detect::Kind;
use crate::report::{CheckReport, ContentClass, Finding, Severity, Verdict};

/// The allowlist category of native executables (level 5 only).
pub const EXECUTABLES: &str = "executables";
/// The allowlist category of disk images, installers and packages (level 5 only).
pub const INSTALLERS: &str = "installers";

/// The first level at which heuristics are labels (D-130).
pub const LABELS_FROM: u8 = 3;
/// The level of the owner's own computers (D-99).
const OWN: u8 = 5;

/// A contact's file allowlist (D-130), in effect only while the contact is at level 5: what of the held list the
/// owner lets through from that computer.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Allow {
    /// Native executables.
    pub executables: bool,
    /// Disk images, installers and packages.
    pub installers: bool,
    /// Extensions, lowercase, without the dot: a program or an installer of this extension.
    pub extensions: Vec<String>,
}

impl Allow {
    /// From stored entries (`executables`, `installers`, `.ext`); anything else is ignored.
    pub fn from_entries<S: AsRef<str>>(entries: &[S]) -> Self {
        let mut a = Allow::default();
        for e in entries {
            match e.as_ref() {
                EXECUTABLES => a.executables = true,
                INSTALLERS => a.installers = true,
                x => {
                    if let Some(ext) = x.strip_prefix('.')
                        && !ext.is_empty()
                        && !a.extensions.iter().any(|y| y == ext)
                    {
                        a.extensions.push(ext.to_string());
                    }
                }
            }
        }
        a
    }

    fn extension(&self, name: &str) -> bool {
        let ext = ext_of(name);
        !ext.is_empty() && self.extensions.contains(&ext)
    }
}

/// Why a file is held for its owner: a value of [`fate::HELD_WHY`] with the rules that matched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hold {
    /// The reason ([`fate`]).
    pub why: &'static str,
    /// The finding codes that made it (never empty).
    pub rules: Vec<String>,
}

impl Hold {
    fn new(why: &'static str, rules: Vec<String>, fallback: &str) -> Self {
        let rules = if rules.is_empty() {
            vec![fallback.to_string()]
        } else {
            rules
        };
        Hold { why, rules }
    }

    /// What the owner reads (English, without the file's name or content), the way a browser warns about a download.
    pub fn message(&self) -> String {
        let what = match self.why {
            fate::THREAT => "a known threat signature or a dangerous archive structure",
            fate::EXECUTABLE => {
                "a program (or an archive that holds one): it can run code on this computer"
            }
            fate::INSTALLER => {
                "an installer or disk image (or an archive that holds one): opening it can install software"
            }
            fate::UNINSPECTED => "an archive Antenna could not look inside",
            fate::CHECK_FAILED => "Antenna could not check this file",
            _ => "it waits for the owner",
        };
        format!(
            "{what} ({}); the owner can keep it anyway",
            self.rules.join(", ")
        )
    }
}

fn ext_of(name: &str) -> String {
    name.rsplit('/')
        .next()
        .and_then(|n| n.rsplit_once('.'))
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default()
}

/// Signatures: what a signature database, not a heuristic, says (the antivirus hook, EICAR, the owner's own YARA
/// rules in their namespace).
fn is_signature(f: &Finding) -> bool {
    f.severity == Severity::Threat
        && (f.code == "eicar"
            || f.code == "yara:eicar_test_file"
            || f.code.starts_with("av:")
            || f.code == "class_mismatch"
            || (f.code.starts_with("yara:") && f.code.matches(':').count() >= 2))
}

/// An archive's structure is dangerous to unpack: a bomb, paths out of the folder, links, devices, a directory that
/// cannot be read.
fn is_archive_structure(f: &Finding) -> bool {
    f.severity == Severity::Threat
        && (f.code.starts_with("archive_")
            && !matches!(
                f.code.as_str(),
                "archive_member_executable"
                    | "archive_member_installer"
                    | "archive_member_unopened"
            ))
}

/// Findings that record an archive not opened whole.
const UNINSPECTED_CODES: &[&str] = &[
    "archive_encrypted",
    "nested_archive",
    "archive_not_inspected",
    "archive_too_large_to_inspect",
    "archive_too_large_to_measure",
    "archive_inner_type",
    "archive_member_unopened",
    "secrets_partial",
];

fn codes<'a>(fs: impl Iterator<Item = &'a Finding>) -> Vec<String> {
    let mut v: Vec<String> = Vec::new();
    for f in fs {
        if !v.contains(&f.code) {
            v.push(f.code.clone());
        }
    }
    v
}

fn rules_of(r: &CheckReport, top: &[&str]) -> Vec<String> {
    codes(r.findings.iter().filter(|f| top.contains(&f.code.as_str())))
}

/// The class, with a disk image hidden behind another format's start (`polyglot_dmg_trailer`: macOS mounts it by
/// its trailer) counted as an installer.
fn class_of(r: &CheckReport) -> Option<ContentClass> {
    if r.findings.iter().any(|f| f.code == "polyglot_dmg_trailer") {
        return Some(ContentClass::Installer);
    }
    r.class
}

/// Whether the rules hold this file for the owner at `level` (D-130): `None` at levels 1–2 (their rules are the
/// verdict's, unchanged) and for a file the rules let through. The owner's allowlist entries for a contact at level
/// 5 lift the hold of a program or an installer, never a signature or a failed check.
pub fn hold(r: &CheckReport, name: &str, level: u8, allow: &Allow) -> Option<Hold> {
    if level < LABELS_FROM {
        return None;
    }
    if r.verdict == Verdict::Failed {
        return Some(Hold::new(
            fate::CHECK_FAILED,
            codes(r.findings.iter().filter(|f| f.severity == Severity::Threat)),
            "check_failed",
        ));
    }
    let signatures = codes(r.findings.iter().filter(|f| is_signature(f)));
    if !signatures.is_empty() {
        return Some(Hold::new(fate::THREAT, signatures, "threat"));
    }
    // The owner turned an antivirus on and it gave no answer: what it would have said is not known
    if r.findings.iter().any(|f| f.code == "av_failed") {
        return Some(Hold::new(
            fate::CHECK_FAILED,
            vec!["av_failed".into()],
            "av_failed",
        ));
    }
    let own = level >= OWN;
    let by_ext = own && allow.extension(name);
    match class_of(r) {
        Some(ContentClass::Executable) if !(own && allow.executables) && !by_ext => {
            return Some(Hold::new(
                fate::EXECUTABLE,
                rules_of(
                    r,
                    &[
                        "executable",
                        "archive_member_executable",
                        "disguised_executable",
                    ],
                ),
                "executable",
            ));
        }
        Some(ContentClass::Installer) if !(own && allow.installers) && !by_ext => {
            return Some(Hold::new(
                fate::INSTALLER,
                rules_of(
                    r,
                    &[
                        "disk_image",
                        "installer_package",
                        "archive_member_installer",
                        "polyglot_dmg_trailer",
                    ],
                ),
                "installer_package",
            ));
        }
        _ => {}
    }
    if !own {
        let structure = codes(r.findings.iter().filter(|f| is_archive_structure(f)));
        if !structure.is_empty() {
            return Some(Hold::new(fate::THREAT, structure, "archive_malformed"));
        }
        if r.uninspected {
            return Some(Hold::new(
                fate::UNINSPECTED,
                rules_of(r, UNINSPECTED_CODES),
                "archive_member_unopened",
            ));
        }
    }
    None
}

/// The heuristic findings that did not hold the file (D-130): what the card and the agent's `inbox.files` show as
/// labels. At levels 1–2 none: the verdict decides there.
pub fn labels(r: &CheckReport, name: &str, level: u8, allow: &Allow) -> Vec<String> {
    if level < LABELS_FROM {
        return vec![];
    }
    let held = hold(r, name, level, allow)
        .map(|h| h.rules)
        .unwrap_or_default();
    codes(
        r.findings
            .iter()
            .filter(|f| f.severity != Severity::Info && !held.contains(&f.code)),
    )
}

/// The verdict that decides who may accept the file (D-130). Levels 1–2: the check's own. Levels 3–5: a file the
/// rules hold needs the owner's keep-anyway (`--force` with the password, like a threat); everything else is clean
/// for accepting, its heuristics are labels.
pub fn effective_verdict(r: &CheckReport, name: &str, level: u8, allow: &Allow) -> Verdict {
    if level < LABELS_FROM {
        return r.verdict;
    }
    match hold(r, name, level, allow) {
        Some(h) if h.why == fate::CHECK_FAILED => Verdict::Failed,
        Some(_) => Verdict::Threat,
        None => Verdict::Clean,
    }
}

/// Whether the content is code and markup, which carries the label "Code: Antenna does not run it".
pub fn is_code(r: &CheckReport) -> bool {
    r.class == Some(ContentClass::Code)
}

/// The daemon's own look at the first and last bytes it handed to the check worker (D-130): magic numbers only, no
/// parser. A parser bug inside the sandbox can make the worker's answer lie, never more; a native executable or an
/// installer called anything else, and text that is not text, are overruled here: the class becomes what the bytes
/// say and a `class_mismatch` signature marks the report. The members of an archive cannot be seen this way: there
/// the worker's answer stands, as its verdict always has.
pub fn guard_class(r: &mut CheckReport, head: &[u8], tail: &[u8], name: &str) {
    let Some(claimed) = r.class else { return };
    let kind = crate::detect::refine_by_tail(crate::detect::sniff(head), tail);
    let truth = if kind.is_native_executable() {
        Some(ContentClass::Executable)
    } else if kind == Kind::Dmg || crate::detect::installer_format(head, kind, name).is_some() {
        Some(ContentClass::Installer)
    } else {
        None
    };
    let text_ok = kind.is_text() || kind == Kind::Empty || kind.is_container();
    let lie = match truth {
        Some(t) => claimed != t,
        None => claimed.is_text() && !text_ok,
    };
    if lie {
        r.class = Some(truth.unwrap_or(ContentClass::Other));
        r.push(Finding::new(
            "class_mismatch",
            Severity::Threat,
            format!(
                "the check called the content {} but its first bytes are {}",
                claimed.as_str(),
                kind.mime()
            ),
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(kind: Kind, class: ContentClass, findings: &[(&str, Severity)]) -> CheckReport {
        let findings: Vec<Finding> = findings
            .iter()
            .map(|(c, s)| Finding::new(*c, *s, "x"))
            .collect();
        CheckReport {
            verdict: CheckReport::verdict_of(&findings),
            kind,
            mime: kind.mime().into(),
            findings,
            scanned_bytes: 1,
            engines: vec![],
            sandbox: String::new(),
            class: Some(class),
            uninspected: false,
        }
    }

    fn none() -> Allow {
        Allow::default()
    }

    /// The field reports (2026-10-06): a stored ZIP of HTML pages (`polyglot_html`), the same pages as `.txt`
    /// (`active_content`), a text with a secret-like line. At levels 3 and 5 they are labels, clean for accepting;
    /// at level 2 the verdict decides as before.
    #[test]
    fn heuristics_are_labels_from_level_3() {
        let zip = report(
            Kind::Zip,
            ContentClass::Code,
            &[
                ("polyglot_html", Severity::Threat),
                ("archive", Severity::Info),
            ],
        );
        let txt = report(
            Kind::Html,
            ContentClass::Code,
            &[("active_content", Severity::Warn)],
        );
        let key = report(
            Kind::Text,
            ContentClass::Text,
            &[("secret:api_key", Severity::Warn)],
        );
        let odd = report(
            Kind::Unknown,
            ContentClass::Other,
            &[("unknown_type", Severity::Warn)],
        );
        for level in [3, 4, 5] {
            for (r, name) in [
                (&zip, "p.zip"),
                (&txt, "panel-1.txt"),
                (&key, "notes.txt"),
                (&odd, "a.bin"),
            ] {
                assert_eq!(hold(r, name, level, &none()), None, "{name} at {level}");
                assert_eq!(effective_verdict(r, name, level, &none()), Verdict::Clean);
            }
        }
        assert_eq!(labels(&zip, "p.zip", 3, &none()), ["polyglot_html"]);
        assert_eq!(labels(&key, "notes.txt", 5, &none()), ["secret:api_key"]);
        assert_eq!(
            effective_verdict(&zip, "p.zip", 2, &none()),
            Verdict::Threat
        );
        assert_eq!(
            effective_verdict(&txt, "a.txt", 2, &none()),
            Verdict::Suspicious
        );
        assert!(labels(&zip, "p.zip", 2, &none()).is_empty());
        assert!(is_code(&zip));
    }

    #[test]
    fn what_runs_and_signatures_are_held_at_every_level_from_3() {
        let elf = report(
            Kind::Elf,
            ContentClass::Executable,
            &[("executable", Severity::Warn)],
        );
        let macho = report(
            Kind::MachO,
            ContentClass::Executable,
            &[("executable", Severity::Warn)],
        );
        let zip_elf = report(
            Kind::Zip,
            ContentClass::Executable,
            &[("archive_member_executable", Severity::Info)],
        );
        let dmg = report(
            Kind::Dmg,
            ContentClass::Installer,
            &[("disk_image", Severity::Warn)],
        );
        let av = report(
            Kind::Text,
            ContentClass::Text,
            &[("av:clamscan", Severity::Threat)],
        );
        let eicar = report(
            Kind::Text,
            ContentClass::Text,
            &[("eicar", Severity::Threat)],
        );
        let mut failed = report(
            Kind::Text,
            ContentClass::Text,
            &[("sandbox_unavailable", Severity::Threat)],
        );
        failed.verdict = Verdict::Failed;
        for level in [3, 4, 5] {
            for (r, why) in [
                (&elf, fate::EXECUTABLE),
                (&macho, fate::EXECUTABLE),
                (&zip_elf, fate::EXECUTABLE),
                (&dmg, fate::INSTALLER),
                (&av, fate::THREAT),
                (&eicar, fate::THREAT),
                (&failed, fate::CHECK_FAILED),
            ] {
                let h = hold(r, "f", level, &none()).unwrap();
                assert_eq!(h.why, why, "{:?} at {level}", r.kind);
                assert!(!h.rules.is_empty());
                assert_ne!(effective_verdict(r, "f", level, &none()), Verdict::Clean);
            }
        }
        assert_eq!(
            hold(&elf, "antennad", 3, &none()).unwrap().rules,
            ["executable"]
        );
        // A disk image hidden behind a PNG's start is an installer
        let png_dmg = report(
            Kind::Png,
            ContentClass::Other,
            &[("polyglot_dmg_trailer", Severity::Threat)],
        );
        assert_eq!(
            hold(&png_dmg, "a.png", 5, &none()).unwrap().why,
            fate::INSTALLER
        );
        // Level 2 is unchanged: the verdict decides (the owner accepts a suspicious program as before)
        assert_eq!(hold(&elf, "f", 2, &none()), None);
        assert_eq!(
            effective_verdict(&elf, "f", 2, &none()),
            Verdict::Suspicious
        );
    }

    #[test]
    fn archives_not_opened_whole_are_held_only_below_level_5() {
        let mut enc = report(
            Kind::Zip,
            ContentClass::Code,
            &[("archive_encrypted", Severity::Warn)],
        );
        enc.uninspected = true;
        let slip = report(
            Kind::Zip,
            ContentClass::Text,
            &[("archive_path_traversal", Severity::Threat)],
        );
        for level in [3, 4] {
            let h = hold(&enc, "a.zip", level, &none()).unwrap();
            assert_eq!(
                (h.why, h.rules.clone()),
                (fate::UNINSPECTED, vec!["archive_encrypted".into()])
            );
            assert_eq!(
                hold(&slip, "a.zip", level, &none()).unwrap().why,
                fate::THREAT
            );
        }
        assert_eq!(hold(&enc, "a.zip", 5, &none()), None);
        assert_eq!(hold(&slip, "a.zip", 5, &none()), None);
        assert_eq!(labels(&enc, "a.zip", 5, &none()), ["archive_encrypted"]);
    }

    #[test]
    fn the_allowlist_lifts_programs_and_installers_only_at_level_5() {
        let elf = report(
            Kind::Elf,
            ContentClass::Executable,
            &[("executable", Severity::Warn)],
        );
        let dmg = report(
            Kind::Dmg,
            ContentClass::Installer,
            &[("disk_image", Severity::Warn)],
        );
        let a = Allow::from_entries(&["executables", ".dmg"]);
        assert_eq!(hold(&elf, "antennad", 5, &a), None);
        assert_eq!(hold(&dmg, "x.dmg", 5, &a), None);
        assert_eq!(labels(&elf, "antennad", 5, &a), ["executable"]);
        for level in [3, 4] {
            assert!(hold(&elf, "antennad", level, &a).is_some());
            assert!(hold(&dmg, "x.dmg", level, &a).is_some());
        }
        let eicar = report(
            Kind::Dmg,
            ContentClass::Installer,
            &[("eicar", Severity::Threat)],
        );
        assert_eq!(hold(&eicar, "x.dmg", 5, &a).unwrap().why, fate::THREAT);
    }
}
