// SPDX-License-Identifier: AGPL-3.0-only
//! The automatic install's loop (D-103): triggers (release files from a level-5 contact, the daily check of the update
//! URL), the wait until agents are idle, and the install itself through the `antenna` next to the daemon.

use std::{
    path::Path,
    process::Stdio,
    sync::{Arc, PoisonError, atomic::Ordering},
    time::Duration,
};

use antenna_proto::control::{FileInfo, UpdateAutoEvent, UpdateRecord};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use super::{
    Attempt, META_ATTEMPT, META_LAST_CHECK, META_STAGED, Staged,
    release::{self, Found},
};
use antenna_files::quarantine::State as FileState;

use crate::{node::Session, now_ms, store::LinkRow};

/// How long the installer may take until the files are in place (copying and checking a large disk image).
const INSTALL_TIMEOUT: Duration = Duration::from_secs(15 * 60);

/// The loop of an open session: looks at the staged release every [`super::AutoConfig::tick`], or at once when woken
/// (a release was staged, the owner said "now", the setting changed). Ends with the session.
pub(crate) async fn auto_loop(w: std::sync::Weak<Session>) {
    let mut first = true;
    loop {
        let Some(s) = w.upgrade() else { return };
        let wait = if first {
            s.cfg.update.tick.min(Duration::from_secs(5))
        } else {
            s.cfg.update.tick
        };
        first = false;
        tokio::select! {
            _ = tokio::time::sleep(wait) => {}
            _ = s.auto.wake.notified() => {}
            _ = s.closed_wait() => return,
        }
        if s.is_closed() {
            return;
        }
        // The daily check runs whatever the setting (D-137): with it off, a newer release is only staged and offered
        // in the window, and installs when the owner says so ("Install now", with the password).
        s.url_check_if_due().await;
        if s.auto_enabled() || s.auto_now_asked() {
            s.maybe_install().await;
        }
    }
}

impl Session {
    /// A file from a level-5 contact was accepted by the daemon (D-99): if it is part of a release and the setting is
    /// on, look at the link folder it went to. Files the owner or an agent accepts, and files from lower levels, never
    /// come here.
    pub(crate) fn auto_on_own_file(self: &Arc<Self>, row: &LinkRow, info: &FileInfo) {
        let name = info.saved_as.as_deref().unwrap_or(&info.name);
        if !release::release_file_name(name) || !self.auto_enabled() {
            return;
        }
        let Some(folder) = info
            .saved_path
            .as_deref()
            .and_then(|p| Path::new(p).parent())
            .map(Path::to_path_buf)
        else {
            return;
        };
        let me = self.clone();
        let (label, link) = (row.label.clone(), row.link_id.to_hex());
        tokio::spawn(async move {
            let _one = me.auto.verifying.lock().await;
            let cfg = me.cfg.update.clone();
            let found = tokio::task::spawn_blocking(move || release::find_in(&folder, &cfg)).await;
            if let Ok(found) = found {
                me.auto_found(found, "link", Some(label), Some(link)).await;
            }
        });
    }

    /// What a trigger found: stage a new release, record a refusal, or ignore what is installed or staged already.
    async fn auto_found(
        self: &Arc<Self>,
        found: Found,
        source: &str,
        contact: Option<String>,
        link: Option<String>,
    ) {
        let rec = |version: String, reason: String| UpdateRecord {
            version,
            result: "refused".into(),
            reason: Some(reason),
            source: source.into(),
            contact: contact.clone(),
            from: None,
            unlocked: None,
            at_ms: now_ms(),
        };
        let v = match found {
            Found::Incomplete => return,
            Found::Installed(v) => {
                tracing::info!("update {v} from {source}: already installed, ignored");
                return;
            }
            Found::Refused(v, reason) => {
                self.auto_record(
                    rec(v.unwrap_or_else(|| "?".into()), reason),
                    link.as_deref(),
                );
                return;
            }
            Found::Release(v) => v,
        };
        if self.auto_failed().contains(&v.version) {
            tracing::info!(
                "update {} from {source}: it failed here before and is not tried again by itself",
                v.version
            );
            return;
        }
        if let Some(st) = self.auto_staged() {
            let newer = st
                .version
                .parse::<antenna_update::Version>()
                .ok()
                .zip(v.version.parse::<antenna_update::Version>().ok())
                .is_some_and(|(a, b)| a >= b);
            if newer {
                tracing::info!(
                    "update {} from {source}: {} is staged already, ignored",
                    v.version,
                    st.version
                );
                return;
            }
        }
        let (data, cfg) = (self.cfg.data_dir.clone(), self.cfg.update.clone());
        let staged = tokio::task::spawn_blocking(move || {
            let r = release::stage(&v, &data, &cfg);
            (v, r)
        })
        .await;
        let Ok((v, r)) = staged else { return };
        match r {
            Ok(dir) => {
                if let Some(old) = self.auto_staged()
                    && old.dir != dir
                {
                    release::remove_stage(&self.cfg.data_dir, &old.dir);
                }
                let st = Staged {
                    version: v.version.clone(),
                    source: source.into(),
                    contact: contact.clone(),
                    link,
                    staged_ms: now_ms(),
                    dir,
                };
                self.meta_put(META_STAGED, Some(&st));
                {
                    let mut live = self
                        .auto
                        .state
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    live.notice_at = None;
                    live.not_before = None;
                    live.now = false;
                }
                // A key kept for an "Install now" of the release this one replaces is not kept for this one (D-137).
                if !self.auto_enabled() {
                    self.node_auto.keep_root(None);
                }
                tracing::info!("update {} from {source}: verified and staged", v.version);
                self.auto_event(UpdateAutoEvent {
                    state: "staged".into(),
                    version: v.version,
                    source: source.into(),
                    contact,
                    at_ms: None,
                    reason: None,
                });
                self.auto.wake.notify_one();
            }
            Err(e) => self.auto_record(
                rec(v.version, format!("{}: {}", e.code, e.message)),
                link.as_deref(),
            ),
        }
    }

    /// The owner asked for "Install now" and it has not started yet.
    fn auto_now_asked(&self) -> bool {
        self.auto
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .now
    }

    /// The daily check of the update URL, when one is configured, this installation can replace itself, and a day has
    /// passed since the last one. A package or a development build never downloads a release it cannot install.
    async fn url_check_if_due(self: &Arc<Self>) {
        let Some(url) =
            antenna_update::fetch::update_url(None, &antenna_update::fetch::config_dir())
        else {
            return;
        };
        if release::target(&self.cfg.update).is_err() {
            return;
        }
        let last: u64 = self.meta_json(META_LAST_CHECK).unwrap_or(0);
        let now = now_ms();
        if now.saturating_sub(last) < self.cfg.update.check_every.as_millis() as u64 {
            return;
        }
        self.meta_put(META_LAST_CHECK, Some(&now));
        let _one = self.auto.verifying.lock().await;
        let (data, cfg) = (self.cfg.data_dir.clone(), self.cfg.update.clone());
        let r = tokio::task::spawn_blocking(move || {
            let dir = release::fresh_dir(&data, "download")
                .map_err(|e| antenna_update::Error::io("updates folder", e))?;
            let found = release::fetch_into(&url, &dir, &cfg);
            Ok::<_, antenna_update::Error>((found, dir))
        })
        .await;
        match r {
            Ok(Ok((found, dir))) => {
                self.auto_found(found, "url", None, None).await;
                release::remove_stage(&self.cfg.data_dir, &dir);
            }
            Ok(Err(e)) => tracing::warn!("update URL check: {e}"),
            Err(e) => tracing::warn!("update URL check: {e}"),
        }
    }

    /// Something besides an agent's call that an install must not interrupt: a wake run or a resident turn, a file being
    /// downloaded or checked, an approved request the daemon is carrying out.
    fn auto_activity(&self) -> Option<&'static str> {
        if self.wake.any_running() || self.teams.any_busy() {
            return Some("an agent turn runs");
        }
        if self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .any_completing()
        {
            return Some("an approved request is being carried out");
        }
        if let Ok(f) = self.files() {
            for l in f.q.links() {
                if f.q.items(&l).is_ok_and(|items| {
                    items
                        .iter()
                        .any(|i| matches!(i.state, FileState::Offered | FileState::Downloaded))
                }) {
                    return Some("a file is being received");
                }
            }
        }
        None
    }

    /// Installs the staged release when the agents have been idle long enough (or the owner said "now").
    async fn maybe_install(self: &Arc<Self>) {
        if self.auto.installing.load(Ordering::SeqCst) {
            return;
        }
        let Some(st) = self.auto_staged() else { return };
        if !st.dir.is_dir() || self.auto_failed().contains(&st.version) {
            self.auto_unstage();
            return;
        }
        if !self.node_auto.root_kept() {
            tracing::debug!(
                "update {}: staged, but the keys are not kept for the restart: unlock again",
                st.version
            );
            return;
        }
        let now = now_ms();
        let quiet = self.cfg.update.quiet.as_millis() as u64;
        let last_agent = self
            .agent_seen
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .copied()
            .max()
            .unwrap_or(0);
        let busy = self.auto_activity();
        let window = self.node_auto.windows.load(Ordering::SeqCst) > 0;
        let go = {
            let mut live = self
                .auto
                .state
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if busy.is_some() {
                live.last_busy_ms = now;
            }
            if live.now {
                true
            } else if live.not_before.is_some_and(|t| now < t) {
                false
            } else if let Some(why) = busy {
                if live.notice_at.take().is_some() {
                    tracing::info!("update {}: {why}; waiting again", st.version);
                }
                false
            } else if now.saturating_sub(last_agent.max(live.last_busy_ms)) < quiet {
                false
            } else if let Some(at) = live.notice_at {
                now >= at
            } else if window {
                // The owner is at the window: say so first (D-103: a notice with "Later").
                let at = now.saturating_add(self.cfg.update.notice.as_millis() as u64);
                live.notice_at = Some(at);
                drop(live);
                self.auto_event(UpdateAutoEvent {
                    state: "soon".into(),
                    version: st.version.clone(),
                    source: st.source.clone(),
                    contact: st.contact.clone(),
                    at_ms: Some(at),
                    reason: None,
                });
                return;
            } else {
                true
            }
        };
        if go {
            self.auto_install(st).await;
        }
    }

    /// Runs the installer (the `antenna` next to the daemon) and, once it has swapped the files, hands the process over
    /// to the new binary.
    async fn auto_install(self: &Arc<Self>, st: Staged) {
        if self.auto.installing.swap(true, Ordering::SeqCst) {
            return;
        }
        let r = self.auto_run_installer(&st).await;
        match r {
            Ok(()) => {
                // The daemon is replacing itself: `installing` stays set until this process is gone.
                tracing::info!("update {}: the daemon replaces itself now", st.version);
            }
            Err(reason) => {
                self.auto_mark_failed(&st.version);
                self.meta_put::<Attempt>(META_ATTEMPT, None);
                self.auto_record(
                    UpdateRecord {
                        version: st.version.clone(),
                        result: "failed".into(),
                        reason: Some(reason),
                        source: st.source.clone(),
                        contact: st.contact.clone(),
                        from: Some(self.cfg.update.version.clone()),
                        unlocked: None,
                        at_ms: now_ms(),
                    },
                    st.link.as_deref(),
                );
                self.auto_unstage();
                self.auto.installing.store(false, Ordering::SeqCst);
            }
        }
    }

    async fn auto_run_installer(self: &Arc<Self>, st: &Staged) -> Result<(), String> {
        let cfg = &self.cfg.update;
        let (_, cli) = release::target(cfg).map_err(|e| format!("{}: {}", e.code, e.message))?;
        let exe = cfg
            .exe
            .clone()
            .ok_or_else(|| "unsupported_install: the daemon's executable is unknown".to_string())?;
        self.meta_put(
            META_ATTEMPT,
            Some(&Attempt {
                version: st.version.clone(),
                from: cfg.version.clone(),
                source: st.source.clone(),
                contact: st.contact.clone(),
                link: st.link.clone(),
                started_ms: now_ms(),
            }),
        );
        self.auto_event(UpdateAutoEvent {
            state: "installing".into(),
            version: st.version.clone(),
            source: st.source.clone(),
            contact: st.contact.clone(),
            at_ms: None,
            reason: None,
        });
        let mut cmd = installer_command(&cli)?;
        cmd.arg("--socket")
            .arg(&self.cfg.control_socket)
            .arg("--data-dir")
            .arg(&self.cfg.data_dir)
            .args(["update", "--from"])
            .arg(&st.dir)
            .args(["--yes", "--json", "--handover"])
            // The installer is the owner's CLI, never an agent's: whatever the daemon's environment holds.
            .env_remove("ANTENNA_AGENT_TOKEN")
            .env_remove("ANTENNA_AGENT_TOKEN_FILE")
            .env_remove("X_AGENT_TOKEN")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(false);
        // Its own process group: launchd kills the job's group when the daemon's process ends, and a failing new daemon
        // must not take the installer that brings the old one back with it. (Windows does not get here: `release::target`
        // refuses there, D-134, WP-29.)
        #[cfg(unix)]
        cmd.process_group(0);
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("install_failed: cannot start {}: {e}", cli.display()))?;
        let pid = child.id().unwrap_or(0);
        let plan = serde_json::json!({
            "pid": std::process::id(),
            "exe": exe,
            "version": self.cfg.daemon_version,
            "args": cfg.args,
            "cwd": cfg.cwd,
        });
        if let Some(mut stdin) = child.stdin.take() {
            let line = format!("{plan}\n");
            if let Err(e) = stdin.write_all(line.as_bytes()).await {
                return Err(format!(
                    "install_failed: the installer did not take its plan: {e}"
                ));
            }
            // The installer reads one line; the end of its stdin means nothing to it.
        }
        let Some(out) = child.stdout.take() else {
            return Err("install_failed: no output from the installer".into());
        };
        let mut lines = BufReader::new(out).lines();
        let mut last: Option<serde_json::Value> = None;
        let read = async {
            while let Ok(Some(l)) = lines.next_line().await {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(&l) else {
                    continue;
                };
                if v["step"] == "swapped" {
                    return true;
                }
                last = Some(v);
            }
            false
        };
        let swapped = match tokio::time::timeout(INSTALL_TIMEOUT, read).await {
            Ok(s) => s,
            Err(_) => {
                let _ = child.start_kill();
                return Err(format!(
                    "install_failed: the installer did not finish within {} minutes",
                    INSTALL_TIMEOUT.as_secs() / 60
                ));
            }
        };
        if swapped {
            // The files are swapped and the installer waits for the new version: nothing may stop the replacement now.
            // The child handle is dropped without a kill; after the `exec` the new image reaps it.
            return self
                .node_auto
                .request_handover(pid)
                .map_err(|e| format!("{}: {}", e.code, e.message));
        }
        let status = child.wait().await.ok();
        let reason = last
            .as_ref()
            .filter(|v| v["ok"] == false)
            .map(|v| {
                format!(
                    "{}: {}",
                    v["error"].as_str().unwrap_or("install_failed"),
                    v["message"].as_str().unwrap_or("")
                )
            })
            .unwrap_or_else(|| {
                format!(
                    "install_failed: the installer ended ({}) without installing",
                    status.map(|s| s.to_string()).unwrap_or_default()
                )
            });
        Err(reason)
    }
}

/// The installer's command. Under the systemd user unit of `install.sh` the installer runs in its own scope
/// (`systemd-run --user --scope`): the unit's processes are killed when its main process ends, and the installer must
/// outlive a new daemon that fails (it puts the old version back). Without `systemd-run` there, nothing is started.
fn installer_command(cli: &Path) -> Result<tokio::process::Command, String> {
    let under_unit = std::fs::read_to_string("/proc/self/cgroup")
        .is_ok_and(|c| c.lines().any(|l| l.ends_with("/antennad.service")));
    if !under_unit {
        return Ok(tokio::process::Command::new(cli));
    }
    let run = ["/usr/bin/systemd-run", "/bin/systemd-run"]
        .into_iter()
        .find(|p| Path::new(p).is_file())
        .ok_or_else(|| {
            "install_failed: the daemon runs as a systemd unit, but systemd-run is missing: install the update by hand"
                .to_string()
        })?;
    let mut c = tokio::process::Command::new(run);
    c.args(["--user", "--scope", "--quiet", "--collect", "--"])
        .arg(cli);
    Ok(c)
}
