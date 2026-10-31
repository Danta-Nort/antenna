// SPDX-License-Identifier: AGPL-3.0-only
//! The automatic install's restart (D-103, R2) against the fake OS: the daemon keeps running while the files are
//! swapped, replaces itself (same PID) and must answer as the new version; a new binary that exits or never answers
//! brings the old version back, started the way it is kept, locked. Real files and real `tar`, as in `flow_tests`.

use std::{cell::Cell, path::PathBuf};

use super::{
    Handoff, Keeper, RunningDaemon, Target,
    flow_tests::{
        COMMIT, Fixture, V1, V2, bins, guarded, line, linux_release, mac_release, version,
    },
    journal,
    testsys::FakeSys,
    with_suffix,
};
use crate::code;

/// The daemon side for a test: on `swapped` the fake daemon "executes" the binary now at its path.
struct FakeDaemon {
    sys: FakeSys,
    path: PathBuf,
    /// The new daemon finds the key in its pipe.
    keys: bool,
    swapped: Cell<u32>,
    came_up: Cell<Option<bool>>,
}

impl FakeDaemon {
    fn new(sys: &FakeSys, path: PathBuf) -> Self {
        Self {
            sys: sys.clone(),
            path,
            keys: true,
            swapped: Cell::new(0),
            came_up: Cell::new(None),
        }
    }
}

impl Handoff for FakeDaemon {
    fn swapped(&self) -> crate::Result<()> {
        self.swapped.set(self.swapped.get() + 1);
        self.sys.exec_daemon(&self.path, self.keys);
        Ok(())
    }

    fn came_up(&self, unlocked: bool) {
        self.came_up.set(Some(unlocked));
    }
}

/// `~/.local/bin` with v1 and a daemon started by hand from it (no systemd unit), which is the installer's parent.
fn bindir_by_hand(f: &Fixture) -> (PathBuf, Option<RunningDaemon>) {
    let bin = f.home.join(".local/bin");
    bins(&bin, V1, COMMIT);
    f.sys.start_daemon(&bin.join("antennad"));
    let pid = f.sys.0.borrow().daemon_pid;
    f.sys.0.borrow_mut().parent = pid;
    (bin.clone(), f.running(&bin.join("antennad")))
}

#[test]
fn handover_by_hand_keeps_the_pid_and_comes_up_unlocked() {
    guarded(
        "handover_by_hand_keeps_the_pid_and_comes_up_unlocked",
        || {
            let f = Fixture::new();
            let (bin, running) = bindir_by_hand(&f);
            let pid = running.as_ref().unwrap().pid;
            let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
            let d = FakeDaemon::new(&f.sys, bin.join("antennad"));
            let mut inst = f.installer(Target::BinDir { dir: bin.clone() }, running, None);
            inst.handoff = Some(&d);
            let k = inst.keeper();
            assert!(
                matches!(&k, Keeper::Handover { pid: p, base, args, .. }
                if *p == pid && matches!(**base, Keeper::Manual { .. }) && args == &["--relay", "n0"]),
                "{k:?}"
            );
            let plan = inst.plan_install(&rel).join("\n");
            assert!(plan.contains("replaces itself"), "{plan}");

            let out = inst.install(&rel, &asset, &path).unwrap();
            assert_eq!(out.daemon.how, "handover");
            assert_eq!(d.swapped.get(), 1, "told once");
            assert_eq!(d.came_up.get(), Some(true));
            assert_eq!(version(&bin.join("antennad")), line("antennad", V2));
            assert_eq!(version(&bin.join("antenna")), line("antenna", V2));
            let w = f.sys.0.borrow();
            assert_eq!(w.daemon_pid, Some(pid), "the same PID");
            assert_eq!(w.daemon.as_deref(), Some(line("antennad", V2).as_str()));
            // Never stopped or started: the daemon replaced itself.
            assert!(
                !w.calls
                    .iter()
                    .any(|c| c.starts_with("kill ") || c.starts_with("spawn ")),
                "{:?}",
                w.calls
            );
            assert!(w.calls.iter().any(|c| c.starts_with("exec ")));
        },
    );
}

#[test]
fn a_new_daemon_that_comes_up_locked_is_kept_and_reported() {
    guarded(
        "a_new_daemon_that_comes_up_locked_is_kept_and_reported",
        || {
            let f = Fixture::new();
            let (bin, running) = bindir_by_hand(&f);
            let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
            let mut d = FakeDaemon::new(&f.sys, bin.join("antennad"));
            d.keys = false;
            let mut inst = f.installer(Target::BinDir { dir: bin.clone() }, running, None);
            inst.handoff = Some(&d);
            inst.install(&rel, &asset, &path).unwrap();
            assert_eq!(d.came_up.get(), Some(false));
            assert_eq!(version(&bin.join("antennad")), line("antennad", V2));
        },
    );
}

#[test]
fn a_new_binary_that_exits_brings_the_old_version_back_locked() {
    guarded(
        "a_new_binary_that_exits_brings_the_old_version_back_locked",
        || {
            let f = Fixture::new();
            let (bin, running) = bindir_by_hand(&f);
            let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
            f.sys.0.borrow_mut().exec_fails = true;
            let d = FakeDaemon::new(&f.sys, bin.join("antennad"));
            let mut inst = f.installer(Target::BinDir { dir: bin.clone() }, running, None);
            inst.handoff = Some(&d);
            let e = inst.install(&rel, &asset, &path).unwrap_err();
            assert_eq!(e.code, code::INSTALL_FAILED);
            assert!(
                e.message.contains("exited") && e.message.contains("restored"),
                "{e}"
            );
            assert_eq!(version(&bin.join("antennad")), line("antennad", V1));
            assert_eq!(version(&bin.join("antenna")), line("antenna", V1));
            let w = f.sys.0.borrow();
            // Started again by hand, with its own arguments, from the old binary: it answers as V1 (locked, as any start).
            assert!(
                w.calls
                    .iter()
                    .any(|c| c.starts_with("spawn ") && c.contains("antennad --relay n0")),
                "{:?}",
                w.calls
            );
            assert_eq!(w.daemon.as_deref(), Some(line("antennad", V1).as_str()));
            assert_eq!(w.daemon_state, "locked");
            assert!(!bin.join(super::STAGE_DIR).join(journal::FILE).exists());
        },
    );
}

#[test]
fn a_new_daemon_that_never_answers_is_stopped_and_the_old_one_started() {
    guarded(
        "a_new_daemon_that_never_answers_is_stopped_and_the_old_one_started",
        || {
            let f = Fixture::new();
            let (bin, running) = bindir_by_hand(&f);
            let pid = running.as_ref().unwrap().pid;
            let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
            // The new binary runs but answers as something else (hung on the old version line, say).
            let d = FakeDaemon::new(&f.sys, f.root.join("elsewhere/antennad"));
            bins(&f.root.join("elsewhere"), "9.9.9", COMMIT);
            let mut inst = f.installer(Target::BinDir { dir: bin.clone() }, running, None);
            inst.handoff = Some(&d);
            let e = inst.install(&rel, &asset, &path).unwrap_err();
            assert!(e.message.contains("did not answer"), "{e}");
            let w = f.sys.0.borrow();
            assert!(
                w.calls.iter().any(|c| c == &format!("kill Term {pid}")),
                "{:?}",
                w.calls
            );
            assert_eq!(w.daemon.as_deref(), Some(line("antennad", V1).as_str()));
        },
    );
}

#[test]
fn under_systemd_the_old_version_is_restarted_by_the_unit() {
    guarded(
        "under_systemd_the_old_version_is_restarted_by_the_unit",
        || {
            let f = Fixture::new();
            let bin = f.bindir_with_systemd();
            let running = f.running(&bin.join("antennad"));
            f.sys.0.borrow_mut().parent = running.as_ref().map(|r| r.pid);
            let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
            f.sys.0.borrow_mut().exec_fails = true;
            let d = FakeDaemon::new(&f.sys, bin.join("antennad"));
            let mut inst = f.installer(Target::BinDir { dir: bin.clone() }, running, None);
            inst.handoff = Some(&d);
            assert!(
                matches!(inst.keeper(), Keeper::Handover { ref base, .. } if matches!(**base, Keeper::Systemd { .. }))
            );
            inst.install(&rel, &asset, &path).unwrap_err();
            let sc = f.sys.calls_of("systemctl");
            assert!(sc.iter().any(|c| c.contains(" restart ")), "{sc:?}");
            assert!(
                !sc.iter().any(|c| c.contains(" stop ")),
                "not stopped before the swap: {sc:?}"
            );
            assert_eq!(
                f.sys.0.borrow().daemon.as_deref(),
                Some(line("antennad", V1).as_str())
            );
        },
    );
}

#[test]
fn the_app_under_the_launch_agent_hands_over_and_reopens_the_window() {
    guarded(
        "the_app_under_the_launch_agent_hands_over_and_reopens_the_window",
        || {
            let f = Fixture::new();
            let app = f.app_with_launch_agent();
            let helper = app.join("Contents/Helpers/antennad");
            let running = f.running(&helper);
            let pid = running.as_ref().unwrap().pid;
            f.sys.0.borrow_mut().parent = Some(pid);
            let (rel, asset, path) = mac_release(&f.root, V2, COMMIT, None);
            let d = FakeDaemon::new(&f.sys, helper.clone());
            let mut inst = f.installer(Target::MacosApp { app: app.clone() }, running, None);
            inst.handoff = Some(&d);
            assert!(
                matches!(inst.keeper(), Keeper::Handover { ref base, .. } if matches!(**base, Keeper::LaunchAgent { .. }))
            );
            let out = inst.install(&rel, &asset, &path).unwrap();
            assert_eq!(out.app_relaunched, Some(true));
            assert_eq!(d.came_up.get(), Some(true));
            assert_eq!(
                f.sys.0.borrow().daemon_pid,
                Some(pid),
                "launchd keeps tracking the same PID"
            );
            assert!(
                f.sys.calls_of("launchctl").is_empty(),
                "no bootout, no bootstrap"
            );
            assert_eq!(f.windows(&app), 1, "the window is open again");
            assert_eq!(version(&helper), line("antennad", V2));
            assert!(with_suffix(&app, ".previous").is_dir());

            // The next one fails: the old app comes back and launchd starts it again (kickstart -k).
            let f = Fixture::new();
            let app = f.app_with_launch_agent();
            let helper = app.join("Contents/Helpers/antennad");
            f.sys.0.borrow_mut().plist = Some(f.home.join(format!(
                "Library/LaunchAgents/{}.plist",
                super::LAUNCH_AGENT_LABEL
            )));
            let running = f.running(&helper);
            f.sys.0.borrow_mut().parent = running.as_ref().map(|r| r.pid);
            f.sys.0.borrow_mut().exec_fails = true;
            let (rel, asset, path) = mac_release(&f.root, V2, COMMIT, None);
            let d = FakeDaemon::new(&f.sys, helper.clone());
            let mut inst = f.installer(Target::MacosApp { app: app.clone() }, running, None);
            inst.handoff = Some(&d);
            inst.install(&rel, &asset, &path).unwrap_err();
            assert!(
                f.sys
                    .calls_of("launchctl")
                    .iter()
                    .any(|c| c.contains("kickstart -k"))
            );
            assert_eq!(version(&helper), line("antennad", V1));
            assert_eq!(
                f.sys.0.borrow().daemon.as_deref(),
                Some(line("antennad", V1).as_str())
            );
            assert_eq!(
                f.windows(&app),
                1,
                "the window is open again on the old version"
            );
        },
    );
}

#[test]
fn recovery_later_never_signals_a_pid_that_is_not_the_daemon() {
    guarded(
        "recovery_later_never_signals_a_pid_that_is_not_the_daemon",
        || {
            let f = Fixture::new();
            let (bin, running) = bindir_by_hand(&f);
            let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
            let d = FakeDaemon::new(&f.sys, bin.join("antennad"));
            // The first attempt fails right after the swap and is undone (the daemon, its parent, is stopped).
            let mut inst = f.installer(
                Target::BinDir { dir: bin.clone() },
                running,
                Some(("swapped".into(), false)),
            );
            inst.handoff = Some(&d);
            let _ = inst.install(&rel, &asset, &path);
            // Later (another `antenna update`, not the daemon's child), the PID runs another program now.
            let pid = f.sys.0.borrow().daemon_pid.unwrap();
            f.sys.0.borrow_mut().parent = None;
            f.sys
                .0
                .borrow_mut()
                .procs
                .insert(pid, PathBuf::from("/usr/bin/some-other-program"));
            let k = Keeper::Handover {
                pid,
                base: Box::new(Keeper::Manual { pid }),
                exe: bin.join("antennad"),
                args: vec![],
                cwd: None,
            };
            f.sys.0.borrow_mut().calls.clear();
            let later = f.installer(Target::BinDir { dir: bin.clone() }, None, None);
            later.start(&k, None).unwrap();
            let w = f.sys.0.borrow();
            assert!(
                !w.calls.iter().any(|c| c.starts_with("kill ")),
                "a PID that runs another program is never signalled: {:?}",
                w.calls
            );
            assert!(w.procs.contains_key(&pid));
        },
    );
}
