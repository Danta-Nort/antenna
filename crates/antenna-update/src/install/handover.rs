// SPDX-License-Identifier: AGPL-3.0-only
//! The restart of an automatic install (D-103, R2, `docs/UPDATES.md` §8): the daemon that started this installer keeps
//! running while the files are swapped, then replaces itself with the new `antennad` (`execve`, the same PID) and hands
//! the root key to it over an inherited pipe; the installer only tells it when ([`super::Handoff::swapped`]) and waits
//! for the new version to answer. If it does not, the old version is swapped back ([`Installer::undo`]) and started
//! again here, the way it is kept: it comes up locked, as after any restart.
//!
//! The PID of the daemon is not trusted blindly when it has to be stopped: only the installer's own parent (the daemon
//! that started it) or a process running this installation's `antennad` is signalled, never whatever got that PID.

use std::{ffi::OsString, path::Path, time::Duration};

use super::{Expect, Installer, Keeper, START_TIMEOUT, SYSTEMD_UNIT, same_file, sys};
use crate::{Error, Result, code};

impl Installer<'_> {
    /// [`Installer::start`] for [`Keeper::Handover`]: with `expect`, the forward step (the daemon replaces itself and
    /// must answer as the new version); without it (after the old files were put back), the old version is started.
    pub(crate) fn start_handover(&self, k: &Keeper, expect: Option<&Expect>) -> Result<bool> {
        let Keeper::Handover {
            pid,
            base,
            exe,
            args,
            cwd,
        } = k
        else {
            return Ok(false);
        };
        match expect {
            Some(want) => self.hand_over(*pid, want),
            None => self.restart_old(*pid, base, exe, args, cwd.as_deref()),
        }
    }

    fn hand_over(&self, pid: u32, want: &Expect) -> Result<bool> {
        let Some(h) = self.handoff else {
            return Err(Error::new(
                code::INSTALL_FAILED,
                "no daemon to hand over to (only the daemon starts an automatic install)",
            ));
        };
        let line = want.line("antennad");
        self.log.step(format!(
            "the daemon (pid {pid}) replaces itself with {line} and hands its keys over"
        ));
        h.swapped()?;
        let step = Duration::from_millis(200);
        let mut waited = Duration::ZERO;
        let mut last = None;
        while waited < START_TIMEOUT {
            if !self.sys.alive(pid) {
                return Err(Error::new(
                    code::INSTALL_FAILED,
                    format!("the new daemon (pid {pid}) exited"),
                ));
            }
            let now = self.probe.daemon_state();
            if let Some((v, state)) = &now
                && *v == line
            {
                let unlocked = state == "unlocked";
                self.log.step(format!(
                    "the daemon answers: {line}, {}",
                    if unlocked {
                        "unlocked: the keys came across"
                    } else {
                        "locked: the keys did not come across"
                    }
                ));
                h.came_up(unlocked);
                return Ok(true);
            }
            last = now.map(|(v, s)| format!("{v}, {s}"));
            self.sys.sleep(step);
            waited += step;
        }
        Err(Error::new(
            code::INSTALL_FAILED,
            format!(
                "the daemon did not answer as {line} within {} s (last answer: {})",
                START_TIMEOUT.as_secs(),
                last.as_deref().unwrap_or("none")
            ),
        ))
    }

    /// The old files are back: the old version is started again (it comes up locked).
    fn restart_old(
        &self,
        pid: u32,
        base: &Keeper,
        exe: &Path,
        args: &[String],
        cwd: Option<&Path>,
    ) -> Result<bool> {
        // The process may still run the new version (hung, or answering wrongly). It is stopped only when it is
        // certainly the daemon: this installer's parent, or a process of this installation's `antennad`.
        let ours = self.sys.alive(pid)
            && (self.sys.is_parent(pid)
                || self.sys.exe_of(pid).is_some_and(|e| same_file(&e, exe)));
        match base {
            Keeper::Systemd { .. } => {
                // `restart` stops what the unit runs now (the new version, if alive) and starts the old one.
                self.log.step(format!(
                    "starting the old version: systemctl --user restart {SYSTEMD_UNIT}"
                ));
                let o = self.run("systemctl", &sys::args(["--user", "restart", SYSTEMD_UNIT]))?;
                if !o.ok {
                    return Err(Error::new(
                        code::INSTALL_FAILED,
                        format!("systemctl --user restart {SYSTEMD_UNIT}: {}", o.describe()),
                    ));
                }
            }
            Keeper::LaunchAgent { label, plist } => {
                let t = format!("gui/{}/{label}", self.env.uid);
                self.log.step(format!(
                    "starting the old version: launchctl kickstart -k {t}"
                ));
                let o = self.run("launchctl", &sys::args(["kickstart", "-k", t.as_str()]))?;
                if !o.ok {
                    self.log.step(format!(
                        "launchctl kickstart: {}; bootstrap {}",
                        o.describe(),
                        plist.display()
                    ));
                    let uid = format!("gui/{}", self.env.uid);
                    let o = self.run(
                        "launchctl",
                        &[
                            "bootstrap".into(),
                            uid.into(),
                            plist.as_os_str().to_os_string(),
                        ],
                    )?;
                    if !o.ok {
                        return Err(Error::new(
                            code::INSTALL_FAILED,
                            format!("launchctl: {}", o.describe()),
                        ));
                    }
                }
            }
            _ => {
                if ours {
                    self.log
                        .step(format!("stopping the new daemon (pid {pid})"));
                    if !sys::terminate(self.sys, pid, Duration::from_secs(10)) {
                        return Err(Error::new(
                            code::INSTALL_FAILED,
                            format!("antennad (pid {pid}) does not stop"),
                        ));
                    }
                } else if self.sys.alive(pid) {
                    self.log.step(format!(
                        "pid {pid} is not this installation's daemon any more: left alone"
                    ));
                }
                self.log.step(format!(
                    "starting the old version: {} {}",
                    exe.display(),
                    args.join(" ")
                ));
                let a: Vec<OsString> = args.iter().map(OsString::from).collect();
                let new = self
                    .sys
                    .spawn_detached(exe.as_os_str(), &a, cwd)
                    .map_err(|e| Error::io(format!("cannot start {}", exe.display()), e))?;
                self.log
                    .step(format!("the old daemon runs again (pid {new}), locked"));
            }
        }
        Ok(true)
    }
}
