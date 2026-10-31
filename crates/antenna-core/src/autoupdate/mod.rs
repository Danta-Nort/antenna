// SPDX-License-Identifier: AGPL-3.0-only
//! Signed updates that install by themselves when the owner turned that on for this computer (D-103, experimental,
//! off by default; `docs/CONTROL.md` §23, `docs/UPDATES.md` §8).
//!
//! - **The setting** is an owner command with the password both ways, kept in the encrypted database; nothing a contact
//!   sends can change it, and agents do not have the command (SPEC §9).
//! - **Triggers**: release files the daemon itself accepted from a level-5 contact (D-99) that complete a release in
//!   that link's folder, and the daily check of the update URL. Nothing else is remote: no downgrade, rollback, other
//!   URL or key, setting or unlock (`release`).
//! - **Verification** is `antenna update`'s own (the `antenna-update` crate: pinned keys, strictly newer, this
//!   installation's file and its hashes); the release is copied into `<data-dir>/updates/<version>/` and checked again.
//! - **When**: after [`AutoConfig::quiet`] without agent activity (`run`).
//! - **Installing**: the `antenna` next to the daemon, started as its child (`antenna update --handover`), swaps the
//!   files; then the daemon replaces itself with the new `antennad` (`execve`, the same PID) and hands the root key over
//!   an inherited pipe ([`Handover`], done by `antennad`). If the new version fails, the installer puts the old one back
//!   and it comes up locked. A version that failed here is never tried again by itself.
//!
//! Everything is recorded: the update log of the installer, the history kept here (`update_auto_status`), the
//! `update_auto` event, and an `update_install` entry in the audit log of the link that delivered the release.

mod release;
mod run;

use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex as StdMutex, PoisonError,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use antenna_proto::{
    LinkId,
    control::{StagedUpdate, UpdateAutoEvent, UpdateAutoInfo, UpdateRecord, UpdatedInfo, code},
};
use serde::{Deserialize, Serialize};
use tokio::sync::Notify;
use zeroize::Zeroizing;

use crate::{
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
    now_ms,
};

/// The setting (`on` when the owner turned it on).
pub(crate) const META_ENABLED: &str = "update_auto";
const META_STAGED: &str = "update_auto_staged";
const META_ATTEMPT: &str = "update_auto_attempt";
const META_FAILED: &str = "update_auto_failed";
const META_HISTORY: &str = "update_auto_history";
const META_LAST_CHECK: &str = "update_auto_last_check";
/// How many records the history keeps.
const HISTORY_MAX: usize = 20;
/// How many failed versions are remembered.
const FAILED_MAX: usize = 50;
/// Staged releases live here, under the data directory (0700 like it).
pub(crate) const UPDATES_DIR: &str = "updates";

/// Timings and facts about this daemon process for automatic installs.
#[derive(Debug, Clone)]
pub struct AutoConfig {
    /// How long agents must have been idle before an install (D-103: 10 minutes). A test flag can only shorten it.
    pub quiet: Duration,
    /// How long the owner's window is warned before an install (5 minutes).
    pub notice: Duration,
    /// How far "Later" moves an install (1 hour).
    pub postpone: Duration,
    /// How often the update URL is checked (once a day, Sparkle's default).
    pub check_every: Duration,
    /// How often the daemon looks whether a staged release can be installed.
    pub tick: Duration,
    /// The daemon's own executable, canonical, read when it started (it is exec'd again after the swap).
    pub exe: Option<PathBuf>,
    /// Its arguments after the program name.
    pub args: Vec<String>,
    /// Its working folder.
    pub cwd: Option<PathBuf>,
    /// The version this daemon runs (`0.1.0-preview.8`), which a release must be newer than.
    pub version: String,
}

impl Default for AutoConfig {
    fn default() -> Self {
        Self {
            quiet: Duration::from_secs(10 * 60),
            notice: Duration::from_secs(5 * 60),
            postpone: Duration::from_secs(60 * 60),
            check_every: Duration::from_secs(24 * 60 * 60),
            tick: Duration::from_secs(30),
            exe: None,
            args: Vec::new(),
            cwd: None,
            version: env!("CARGO_PKG_VERSION").into(),
        }
    }
}

/// The daemon has swapped its files and must now replace itself (`antennad` does the `execve`).
pub struct Handover {
    /// The root key for the new image (wiped on drop).
    pub root: Zeroizing<[u8; 32]>,
    /// The installer's PID: it is still this process's child after the `exec`, so the new image reaps it.
    pub installer: u32,
}

/// Size of what goes through the handover pipe (format 1): `0x01 ‖ root key (32 bytes) ‖ installer PID (4 bytes, big
/// endian)`. The pipe is between two images of the same installation, the old one writing; a newer daemon keeps
/// reading format 1.
pub const HANDOVER_LEN: usize = 37;

impl Handover {
    /// The bytes for the pipe (wiped on drop).
    pub fn to_bytes(&self) -> Zeroizing<[u8; HANDOVER_LEN]> {
        let mut b = Zeroizing::new([0u8; HANDOVER_LEN]);
        b[0] = 1;
        b[1..33].copy_from_slice(&self.root[..]);
        b[33..].copy_from_slice(&self.installer.to_be_bytes());
        b
    }

    /// Parses what the pipe held: exactly [`HANDOVER_LEN`] bytes of format 1, or nothing.
    pub fn from_bytes(b: &[u8]) -> Option<Self> {
        if b.len() != HANDOVER_LEN || b[0] != 1 {
            return None;
        }
        let mut root = Zeroizing::new([0u8; 32]);
        root.copy_from_slice(&b[1..33]);
        let installer = u32::from_be_bytes(b[33..].try_into().ok()?);
        Some(Self { root, installer })
    }
}

/// Node-level state of automatic installs: it outlives a session (lock/unlock).
#[derive(Default)]
pub(crate) struct NodeAuto {
    /// The root key, kept only while the setting is on and the keys are unlocked (D-103 R2).
    root: StdMutex<Option<Zeroizing<[u8; 32]>>>,
    /// The install reached the point where the daemon replaces itself.
    handover: StdMutex<Option<Handover>>,
    handover_ready: Notify,
    /// This process came up from an automatic update.
    pub(crate) updated: StdMutex<Option<UpdatedInfo>>,
    /// This process got its key through the handover pipe.
    pub(crate) came_by_handover: AtomicBool,
    /// Owner sessions a window holds now (`login {hold}`): an install is announced to them first.
    pub(crate) windows: std::sync::atomic::AtomicUsize,
}

impl NodeAuto {
    pub(crate) fn keep_root(&self, root: Option<Zeroizing<[u8; 32]>>) {
        *self.root.lock().unwrap_or_else(PoisonError::into_inner) = root;
    }

    pub(crate) fn root_kept(&self) -> bool {
        self.root
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_some()
    }

    /// Takes the kept key for the handover and tells `antennad` to replace the process.
    fn request_handover(&self, installer: u32) -> Result<()> {
        let root = self
            .root
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
            .ok_or_else(|| Error::new(code::LOCKED, "the keys are not kept for the update"))?;
        *self.handover.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(Handover { root, installer });
        self.handover_ready.notify_one();
        Ok(())
    }

    /// Waits until an install asks the daemon to replace itself.
    pub(crate) async fn wait_handover(&self) -> Handover {
        loop {
            let taken = self
                .handover
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            if let Some(h) = taken {
                return h;
            }
            self.handover_ready.notified().await;
        }
    }
}

/// Session-level state: the staged release and the running install.
#[derive(Default)]
pub(crate) struct SessionAuto {
    pub(crate) state: StdMutex<Live>,
    /// An install runs (the installer child is alive): one at a time.
    pub(crate) installing: AtomicBool,
    /// A verification runs: release files that arrive together are looked at one after another.
    pub(crate) verifying: tokio::sync::Mutex<()>,
    /// `update_auto_now`, or something new to look at.
    pub(crate) wake: Notify,
}

/// What the loop knows between ticks (in memory; the staged release is also in the database).
#[derive(Debug, Default)]
pub(crate) struct Live {
    /// `soon`: the owner's window was told; installs at this time.
    pub(crate) notice_at: Option<u64>,
    /// "Later": not before this time.
    pub(crate) not_before: Option<u64>,
    /// "Install now" was asked: skip the idle wait and the notice.
    pub(crate) now: bool,
    /// When something that counts as activity besides agent calls (a wake or resident turn, a file being received, an
    /// approved request being carried out) was last seen.
    pub(crate) last_busy_ms: u64,
}

/// A staged release, as kept in the database.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Staged {
    pub(crate) version: String,
    pub(crate) source: String,
    #[serde(default)]
    pub(crate) contact: Option<String>,
    /// The delivering link (hex), for its audit log.
    #[serde(default)]
    pub(crate) link: Option<String>,
    pub(crate) staged_ms: u64,
    /// `<data-dir>/updates/<version>`.
    pub(crate) dir: PathBuf,
}

/// An install that started: the new daemon (or the old one, after a failure) reads it when it opens the database.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Attempt {
    pub(crate) version: String,
    pub(crate) from: String,
    pub(crate) source: String,
    #[serde(default)]
    pub(crate) contact: Option<String>,
    #[serde(default)]
    pub(crate) link: Option<String>,
    pub(crate) started_ms: u64,
}

fn link_of(hex: Option<&str>) -> Option<LinkId> {
    let b = data_encoding::HEXLOWER.decode(hex?.as_bytes()).ok()?;
    Some(LinkId(<[u8; 32]>::try_from(b.as_slice()).ok()?))
}

impl Session {
    fn meta_json<T: serde::de::DeserializeOwned>(&self, key: &str) -> Option<T> {
        let v = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .meta_get(key)
            .ok()
            .flatten()?;
        if v.is_empty() {
            return None;
        }
        serde_json::from_str(&v).ok()
    }

    fn meta_put<T: Serialize>(&self, key: &str, v: Option<&T>) {
        let s = v
            .and_then(|v| serde_json::to_string(v).ok())
            .unwrap_or_default();
        let r = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .meta_set(key, &s);
        if let Err(e) = r {
            tracing::warn!("update: cannot record {key}: {e}");
        }
    }

    /// The owner turned "Install signed updates by itself" on for this computer.
    pub(crate) fn auto_enabled(&self) -> bool {
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .meta_get(META_ENABLED)
            .ok()
            .flatten()
            .as_deref()
            == Some("on")
    }

    pub(crate) fn auto_staged(&self) -> Option<Staged> {
        self.meta_json(META_STAGED)
    }

    fn auto_failed(&self) -> Vec<String> {
        self.meta_json(META_FAILED).unwrap_or_default()
    }

    fn auto_history(&self) -> Vec<UpdateRecord> {
        self.meta_json(META_HISTORY).unwrap_or_default()
    }

    /// Records an install, failure or refusal: the history, the event, and the delivering link's audit log. A refusal
    /// of the same version for the same reason within a day is not recorded again (re-sent files).
    fn auto_record(&self, rec: UpdateRecord, link: Option<&str>) {
        let mut h = self.auto_history();
        if rec.result == "refused"
            && h.iter().any(|r| {
                r.result == "refused"
                    && r.version == rec.version
                    && r.reason == rec.reason
                    && rec.at_ms.saturating_sub(r.at_ms) < 24 * 3_600_000
            })
        {
            tracing::info!(
                "update {}: refused again ({}), already recorded",
                rec.version,
                rec.reason.as_deref().unwrap_or("")
            );
            return;
        }
        tracing::info!(
            "update {}: {}{}",
            rec.version,
            rec.result,
            rec.reason
                .as_deref()
                .map(|r| format!(" ({r})"))
                .unwrap_or_default()
        );
        if let Some(l) = link_of(link) {
            let reason = match (&rec.from, &rec.reason) {
                (Some(f), None) => format!("{f} → {}", rec.version),
                (_, Some(r)) => format!("{}: {r}", rec.version),
                _ => rec.version.clone(),
            };
            self.receipt(
                &l,
                "daemon",
                "update_install",
                &rec.result,
                &reason,
                None,
                None,
            );
        }
        if rec.result != "installed" {
            self.auto_event(UpdateAutoEvent {
                state: rec.result.clone(),
                version: rec.version.clone(),
                source: rec.source.clone(),
                contact: rec.contact.clone(),
                at_ms: None,
                reason: rec.reason.clone(),
            });
        }
        h.insert(0, rec);
        h.truncate(HISTORY_MAX);
        self.meta_put(META_HISTORY, Some(&h));
    }

    fn auto_mark_failed(&self, version: &str) {
        let mut f = self.auto_failed();
        if !f.iter().any(|v| v == version) {
            f.push(version.to_string());
        }
        let n = f.len().saturating_sub(FAILED_MAX);
        f.drain(..n);
        self.meta_put(META_FAILED, Some(&f));
    }

    pub(crate) fn auto_event(&self, e: UpdateAutoEvent) {
        let _ = self.events.send(NodeEvent::UpdateAuto(Box::new(e)));
    }

    /// `update_auto_status`.
    pub fn update_auto_info(&self) -> UpdateAutoInfo {
        let (supported, unsupported_reason) = match release::target(&self.cfg.update) {
            Ok(_) => (true, None),
            Err(e) => (false, Some(e.message)),
        };
        let enabled = self.auto_enabled();
        // The database first, then the loop's state (the lock order: DB → everything else).
        let staged = self.auto_staged();
        let live = self
            .auto
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let staged = staged.map(|s| {
            let installing = self.auto.installing.load(Ordering::SeqCst);
            StagedUpdate {
                version: s.version,
                source: s.source,
                contact: s.contact,
                staged_ms: s.staged_ms,
                state: if installing {
                    "installing"
                } else if live.notice_at.is_some() {
                    "soon"
                } else {
                    "waiting"
                }
                .into(),
                at_ms: live.notice_at.or(live.not_before),
            }
        });
        drop(live);
        let history = self.auto_history();
        UpdateAutoInfo {
            enabled,
            supported,
            unsupported_reason,
            // Kept by the setting, or for one install the owner started with the password (D-137).
            keys_kept: self.node_auto.root_kept(),
            url: antenna_update::fetch::update_url(None, &antenna_update::fetch::config_dir()),
            last_check_ms: self.meta_json(META_LAST_CHECK),
            staged,
            last: history.first().cloned(),
            failed: self.auto_failed(),
            history,
        }
    }

    /// `update_auto_set` (the password was checked by the caller; for "on" the caller also kept the root key).
    pub fn update_auto_set(&self, enabled: bool) -> Result<UpdateAutoInfo> {
        if enabled && let Err(e) = release::target(&self.cfg.update) {
            return Err(Error::new(code::UNSUPPORTED_INSTALL, e.message));
        }
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .meta_set(META_ENABLED, if enabled { "on" } else { "off" })?;
        if !enabled {
            self.node_auto.keep_root(None);
            // An "Install now" that waited for the kept keys does not start without them.
            self.auto
                .state
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .now = false;
        }
        tracing::info!(
            "the owner turned updates that install by themselves {}",
            if enabled { "on" } else { "off" }
        );
        self.auto.wake.notify_one();
        Ok(self.update_auto_info())
    }

    /// `update_auto_now`: also with the setting off, for a release the daily check staged (D-137). The new version must
    /// come up unlocked, so the keys have to be kept for the restart: by the setting, or by the password just given.
    pub fn update_auto_now(&self) -> Result<UpdateAutoInfo> {
        self.auto_staged_or_busy()?;
        if !self.node_auto.root_kept() {
            return Err(Error::new(
                code::PASSWORD_REQUIRED,
                "the owner password is needed: the keys are kept for the restart only with it",
            ));
        }
        self.auto
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .now = true;
        self.auto.wake.notify_one();
        Ok(self.update_auto_info())
    }

    /// `update_auto_later`.
    pub fn update_auto_later(&self) -> Result<UpdateAutoInfo> {
        let s = self.auto_staged_or_busy()?;
        let at = now_ms().saturating_add(self.cfg.update.postpone.as_millis() as u64);
        {
            let mut live = self
                .auto
                .state
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            live.not_before = Some(at);
            live.notice_at = None;
            live.now = false;
        }
        self.auto_event(UpdateAutoEvent {
            state: "postponed".into(),
            version: s.version,
            source: s.source,
            contact: s.contact,
            at_ms: Some(at),
            reason: None,
        });
        Ok(self.update_auto_info())
    }

    /// The staged release, unless an install runs already (`not_found` when nothing is staged).
    pub(crate) fn auto_staged_or_busy(&self) -> Result<Staged> {
        if self.auto.installing.load(Ordering::SeqCst) {
            return Err(Error::new(
                code::UPDATE_IN_PROGRESS,
                "the update is being installed now",
            ));
        }
        self.auto_staged()
            .ok_or_else(|| Error::new(code::NOT_FOUND, "no update waits to be installed"))
    }

    /// After the database opened: what became of an install that started before (the new version records it as
    /// installed; the old one, back after a failure, as failed and never tried again by itself).
    pub(crate) fn auto_after_open(&self) {
        let Some(a) = self.meta_json::<Attempt>(META_ATTEMPT) else {
            return;
        };
        let me = &self.cfg.update.version;
        let unlocked = self.node_auto.came_by_handover.load(Ordering::SeqCst);
        if a.version == *me {
            *self
                .node_auto
                .updated
                .lock()
                .unwrap_or_else(PoisonError::into_inner) = Some(UpdatedInfo {
                from: a.from.clone(),
                to: a.version.clone(),
                at_ms: now_ms(),
                unlocked,
            });
            self.auto_record(
                UpdateRecord {
                    version: a.version.clone(),
                    result: "installed".into(),
                    reason: None,
                    source: a.source.clone(),
                    contact: a.contact.clone(),
                    from: Some(a.from.clone()),
                    unlocked: Some(unlocked),
                    at_ms: now_ms(),
                },
                a.link.as_deref(),
            );
        } else {
            self.auto_mark_failed(&a.version);
            self.auto_record(
                UpdateRecord {
                    version: a.version.clone(),
                    result: "failed".into(),
                    reason: Some(format!(
                        "{}: the new version did not come up; {me} runs again (the installer's log has the details)",
                        antenna_update::code::INSTALL_FAILED
                    )),
                    source: a.source.clone(),
                    contact: a.contact.clone(),
                    from: Some(a.from.clone()),
                    unlocked: None,
                    at_ms: now_ms(),
                },
                a.link.as_deref(),
            );
        }
        self.meta_put::<Attempt>(META_ATTEMPT, None);
        if self.auto_staged().is_some_and(|s| s.version == a.version) {
            self.auto_unstage();
        }
    }

    /// Forgets the staged release and removes its folder. With the setting off the root key was kept only for this
    /// release ("Install now" with the password, D-137): it goes too.
    fn auto_unstage(&self) {
        if let Some(s) = self.auto_staged() {
            release::remove_stage(&self.cfg.data_dir, &s.dir);
        }
        if !self.auto_enabled() {
            self.node_auto.keep_root(None);
        }
        self.meta_put::<Staged>(META_STAGED, None);
        let mut live = self
            .auto
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        live.notice_at = None;
        live.not_before = None;
        live.now = false;
    }
}

/// A window that holds an owner session, counted while the guard lives (an install is announced to it first).
pub(crate) struct WindowGuard(Arc<NodeAuto>);

impl Drop for WindowGuard {
    fn drop(&mut self) {
        self.0
            .windows
            .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

impl crate::node::Node {
    /// Counts a window's held owner session while the returned guard lives.
    pub(crate) fn auto_window(&self) -> WindowGuard {
        self.auto
            .windows
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        WindowGuard(self.auto.clone())
    }
}

impl Session {
    /// Whether this installation can replace itself (`unsupported_install` with the reason otherwise).
    pub fn auto_supported(&self) -> Result<()> {
        release::target(&self.cfg.update)
            .map(|_| ())
            .map_err(|e| Error::new(code::UNSUPPORTED_INSTALL, e.message))
    }
}

/// Starts the automatic-install loop of a session that just opened.
pub(crate) fn start(s: &Arc<Session>) {
    s.auto_after_open();
    tokio::spawn(run::auto_loop(Arc::downgrade(s)));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_handover_bytes_are_exactly_format_1() {
        let h = Handover {
            root: Zeroizing::new([7u8; 32]),
            installer: 0x0102_0304,
        };
        let b = h.to_bytes();
        assert_eq!(b.len(), HANDOVER_LEN);
        assert_eq!(b[0], 1);
        assert_eq!(&b[33..], &[1, 2, 3, 4]);
        let back = Handover::from_bytes(&b[..]).unwrap();
        assert_eq!(*back.root, [7u8; 32]);
        assert_eq!(back.installer, 0x0102_0304);
        // Anything else is no handover: shorter, longer, another format.
        assert!(Handover::from_bytes(&b[..HANDOVER_LEN - 1]).is_none());
        let mut long = b.to_vec();
        long.push(0);
        assert!(Handover::from_bytes(&long).is_none());
        let mut other = b.to_vec();
        other[0] = 2;
        assert!(Handover::from_bytes(&other).is_none());
        assert!(Handover::from_bytes(&[]).is_none());
    }
}
