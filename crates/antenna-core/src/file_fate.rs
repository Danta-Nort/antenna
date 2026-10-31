// SPDX-License-Identifier: AGPL-3.0-only
//! A received file's fate after its check (D-99, D-130), and a sent file's fate as its recipient tells it.
//!
//! Receiving (levels 3–5): the check's heuristics are labels; what the rules hold ([`antenna_files::kinds::hold`]: a
//! native program, an installer or a disk image, an archive holding one, a signature, a failed check, and at 3–4 an
//! archive not opened whole) waits for the owner's keep-anyway, like a browser's dangerous download. Everything else
//! is saved by the daemon at level 5 and waits for an accept at 3–4. A release the pinned keys sign is the signed
//! update flow (D-103): its files are saved. Levels 1–2 are unchanged. The sender's node is told, when it takes
//! `file-fate/0`: held (`check_file` / `held`) with the reason and the rules, or blocked (`reject_file` / `denied`
//! with the reason: the limits, a damaged file, a threat at levels 1–2), never a name, a path or content.
//!
//! Sending: the contact's receipts tell the agent that sent a file what became of it, in the same closed vocabulary.

use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError};

use antenna_files::{
    kinds::{self, Hold},
    quarantine::{Held, Item, State},
    report::{CheckReport, Verdict},
};
use antenna_proto::{LinkId, MessageId, control::FileInfo, files::fate};
use rusqlite::{OptionalExtension, params};

use crate::{node::Session, policy::OWN_COMPUTER, store::LinkRow};

impl Session {
    /// The name the contact's agent signed the offer under (PROTOCOL §21), when an agent key signed it: a save folder
    /// set for that agent applies (D-130). An offer signed by the contact's link-root has none.
    pub(crate) fn offer_agent(&self, link: &LinkId, msg: Option<[u8; 32]>) -> Option<String> {
        let msg = msg?;
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db.conn()
            .query_row(
                "SELECT agent FROM messages WHERE link_id = ?1 AND id = ?2 AND direction = 'in'
                 AND agent_key IS NOT NULL",
                params![link.0.to_vec(), msg.to_vec()],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()
            .ok()
            .flatten()
            .flatten()
    }

    /// Where a received file is saved: at level 5 the save folder of the agent that signed the offer, the contact's,
    /// or `--project-dir`; `None` is the link folder (D-130).
    pub(crate) fn save_dir_of(&self, item: &Item, row: &LinkRow) -> Option<PathBuf> {
        let level = row.trust.min(item.level_at_offer);
        let agent = self.offer_agent(&row.link_id, item.message_id);
        self.save_dir_for(row, level, agent.as_deref())
    }

    /// The folder a level-5 file of this link goes to: its save folder, else the link's `shared/`.
    fn own_folder(&self, item: &Item, row: &LinkRow) -> Option<PathBuf> {
        if let Some(d) = self.save_dir_of(item, row) {
            return Some(d);
        }
        let f = self.files().ok()?;
        Some(f.cfg.links_dir.join(&item.folder).join("shared"))
    }

    /// The signed update flow (D-103) at level 5: a release manifest in the folder the file goes to, signed by a key
    /// pinned in this daemon, lists this file by name, size and SHA-256. Its disk image or archive is then the
    /// release, not an unknown program.
    fn signed_release_asset(&self, item: &Item, row: &LinkRow) -> bool {
        let Some(sha) = item.sha256 else {
            return false;
        };
        let Some(folder) = self.own_folder(item, row) else {
            return false;
        };
        signed_release_lists(&folder, &item.manifest.name, item.manifest.size, &sha)
    }

    /// After the check (D-99, D-130). Levels 3–5: a file the rules hold waits for the owner's keep-anyway, recorded
    /// with the reason for every list of it, and its sender is told it waits (`check_file` / `held`); any other file
    /// is saved by the daemon at level 5 and waits for an accept at 3–4, its heuristics as labels. Levels 1–2 as
    /// before: a threat is refused to the sender at once (the record is kept 7 days for the owner, Q-F-3).
    pub(crate) async fn after_check(
        self: &Arc<Self>,
        row: &LinkRow,
        item: &Item,
        report: &CheckReport,
    ) {
        let level = row.trust.min(item.level_at_offer);
        let allow = self.file_allow(&row.link_id);
        let refs: Vec<MessageId> = item.message_id.map(MessageId).into_iter().collect();
        if level < kinds::LABELS_FROM {
            if report.verdict == Verdict::Threat {
                let rules: Vec<String> = report
                    .findings
                    .iter()
                    .filter(|f| f.severity == antenna_files::report::Severity::Threat)
                    .map(|f| f.code.clone())
                    .collect();
                self.blocked(row, &refs, &rules);
            }
            return;
        }
        let mut release = false;
        let hold = kinds::hold(report, &item.manifest.name, level, &allow).filter(|h| {
            // A release the pinned keys sign is the update flow, not an unknown program (D-103)
            release = level >= OWN_COMPUTER
                && matches!(h.why, fate::EXECUTABLE | fate::INSTALLER)
                && self.signed_release_asset(item, row);
            !release
        });
        match hold {
            Some(h) => self.hold_for_owner(row, item, &h, &refs),
            None if level >= OWN_COMPUTER => {
                if let Some(info) = self.accept_own_as(item, row, release).await {
                    self.after_own_accept(row, &info).await;
                }
            }
            None => {}
        }
    }

    /// A file the rules hold (D-130): recorded with the reason and the rules for every list of it, and the sender told
    /// that it waits for the owner (never "declined"; a node without `file-fate/0` is told nothing until the owner
    /// decides, and keeps serving it meanwhile).
    fn hold_for_owner(&self, row: &LinkRow, item: &Item, h: &Hold, refs: &[MessageId]) {
        tracing::info!(
            "link {}: a received file is held for the owner: {} ({})",
            &row.link_id.to_hex()[..8],
            h.why,
            h.rules.join(", ")
        );
        self.receipt(
            &row.link_id,
            "owner",
            "check_file",
            "held",
            &format!("{} ({})", h.why, h.rules.join(", ")),
            refs.first(),
            None,
        );
        let held = Held {
            code: h.why.to_string(),
            message: h.message(),
            rules: h.rules.clone(),
        };
        if let Ok(f) = self.files()
            && f.q.set_held(&row.link_id.0, &item.id, Some(held)).is_ok()
            && let Ok(it) = f.q.get(&row.link_id.0, &item.id)
        {
            self.emit_file(&row.link_id, self.file_info(&it, &row.label));
        }
        self.dag_receipt_fate(&row.link_id, "check_file", "held", refs, h.why, &h.rules);
    }

    /// A threat at levels 1–2: `reject_file` / `denied`, with the reason and the rules to a node that takes them.
    fn blocked(&self, row: &LinkRow, refs: &[MessageId], rules: &[String]) {
        self.receipt(
            &row.link_id,
            "owner",
            "reject_file",
            "denied",
            "threat found by the check",
            refs.first(),
            None,
        );
        self.dag_receipt_fate(
            &row.link_id,
            "reject_file",
            "denied",
            refs,
            fate::THREAT,
            rules,
        );
    }

    /// A level-5 file the daemon could not save (D-128) is held with its accept's error: the sender is told it waits
    /// (`not_saved`, the error code as the rule).
    pub(crate) fn not_saved(&self, row: &LinkRow, item: &Item, code: &str) {
        let refs: Vec<MessageId> = item.message_id.map(MessageId).into_iter().collect();
        self.dag_receipt_fate(
            &row.link_id,
            "check_file",
            "held",
            &refs,
            fate::NOT_SAVED,
            &[code.to_string()],
        );
    }

    /// After the daemon saved a level-5 file: release files may start an automatic install (D-103), and a release
    /// manifest that arrived after its disk image or archive lets that file go too.
    async fn after_own_accept(self: &Arc<Self>, row: &LinkRow, info: &FileInfo) {
        self.auto_on_own_file(row, info);
        let name = info.saved_as.as_deref().unwrap_or(&info.name);
        if name.ends_with("-manifest.json") || name.ends_with("-manifest.json.sig") {
            self.reconsider_held(row).await;
        }
    }

    /// At level 5, the held files of a link are decided again (a release manifest arrived, the owner allowed a
    /// kind): those the rules let go now are saved.
    pub(crate) async fn reconsider_held(self: &Arc<Self>, row: &LinkRow) {
        let Ok(f) = self.files().cloned() else { return };
        let Ok(items) = f.q.items(&row.link_id.0) else {
            return;
        };
        let allow = self.file_allow(&row.link_id);
        for item in items {
            let held_by_rules = item.held.as_ref().is_some_and(|h| {
                matches!(
                    h.code.as_str(),
                    fate::EXECUTABLE | fate::INSTALLER | fate::UNINSPECTED
                )
            });
            if item.state != State::Checked || !held_by_rules {
                continue;
            }
            let Some(report) = item.report.as_ref() else {
                continue;
            };
            if row.trust.min(item.level_at_offer) < OWN_COMPUTER {
                continue;
            }
            let held = kinds::hold(report, &item.manifest.name, OWN_COMPUTER, &allow).is_some();
            let release = held && self.signed_release_asset(&item, row);
            if held && !release {
                continue;
            }
            if let Some(info) = self.accept_own_as(&item, row, release).await {
                self.auto_on_own_file(row, &info);
            }
        }
    }

    /// A contact's answer about our file names its fate (D-130): the agent that sent it is told `accepted`, `held`
    /// (it waits for the contact's owner), `rejected` (the contact's owner or agent) or `blocked` (the contact's
    /// node refused it), with the reason and the rules when the contact's node gives them. Only a hold keeps the file
    /// served: the contact may still accept it.
    pub(crate) fn fate_of_receipt(r: &antenna_proto::ReceiptBody) -> Option<(&'static str, bool)> {
        match (r.action.as_str(), r.decision.as_str()) {
            ("accept_file", _) => Some(("accepted", false)),
            ("check_file", "held") => Some(("held", true)),
            ("reject_file", "denied") => Some(("blocked", false)),
            ("reject_file", _) => Some(("rejected", false)),
            _ => None,
        }
    }
}

/// What a sender reads about a contact's reason (English, no file content).
pub(crate) fn fate_message(why: &str) -> &'static str {
    match why {
        fate::THREAT => "the contact's check found a threat",
        fate::EXECUTABLE => "a native executable: it waits for the contact's owner",
        fate::INSTALLER => "a disk image, installer or package: it waits for the contact's owner",
        fate::UNINSPECTED => {
            "an archive the contact's check could not open whole: it waits for the contact's owner"
        }
        fate::CHECK_FAILED => {
            "the contact's check could not finish: it waits for the contact's owner"
        }
        fate::REVIEW => "the contact's owner reviews it",
        fate::NOT_SAVED => {
            "the contact's computer could not save it by itself: it waits for the contact's owner"
        }
        fate::DAMAGED => "the content did not match its manifest",
        fate::LIMIT => "the contact's limits for files refused it",
        _ => "",
    }
}

/// A release manifest in `folder` (`antenna-*-manifest.json` with its `.sig`) signed by a pinned release key lists a
/// file of this name, size and SHA-256 (D-103's verification, `antenna-update`'s own).
fn signed_release_lists(folder: &Path, name: &str, size: u64, sha256: &[u8; 32]) -> bool {
    let Ok(rd) = std::fs::read_dir(folder) else {
        return false;
    };
    let sha = data_encoding::HEXLOWER.encode(sha256);
    let keys = antenna_update::keys::KeySet::pinned();
    rd.flatten().any(|e| {
        let p = e.path();
        let n = e.file_name().to_string_lossy().into_owned();
        if !(n.starts_with("antenna-") && n.ends_with("-manifest.json")) {
            return false;
        }
        let sig = p.with_file_name(format!("{n}.sig"));
        if !sig.is_file() {
            return false;
        }
        let loc = antenna_update::package::Located {
            manifest: p.clone(),
            sig,
            given: vec![],
            dir: folder.to_path_buf(),
        };
        antenna_update::package::open_release(&loc, &keys).is_ok_and(|rel| {
            rel.manifest
                .assets
                .iter()
                .any(|a| a.name == name && a.size == size && a.sha256 == sha)
        })
    })
}
