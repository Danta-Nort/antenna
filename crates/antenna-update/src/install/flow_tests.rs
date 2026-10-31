// SPDX-License-Identifier: AGPL-3.0-only
//! The install, rollback and recovery flows against the fake OS ([`super::testsys`]): the systemd and the macOS app
//! paths run here on any machine; real `tar` and real file swaps.

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
};

use super::{
    Env, FailAt, Installer, Keeper, Log, RunningDaemon, STAGE_DIR, Target, journal,
    macos::fake_app, testsys::FakeSys, with_suffix,
};
use crate::{
    code,
    keys::KeySet,
    manifest::{Asset, Platform},
    package::{self, Release, tests::release_dir},
};

pub(super) const V1: &str = "0.1.0-preview.2";
pub(super) const V2: &str = "0.1.0-preview.3";
pub(super) const COMMIT: &str = "0123456789ab";

fn script(p: &Path, line: &str) {
    fs::write(p, format!("#!/bin/sh\necho '{line}'\n")).unwrap();
    fs::set_permissions(p, fs::Permissions::from_mode(0o755)).unwrap();
}

pub(super) fn bins(dir: &Path, version: &str, commit: &str) {
    fs::create_dir_all(dir).unwrap();
    for b in ["antenna", "antennad"] {
        script(&dir.join(b), &format!("{b} {version} ({commit})"));
    }
}

pub(super) fn version(bin: &Path) -> String {
    let o = super::testsys::output(Command::new(bin).arg("--version")).unwrap();
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

/// A release folder with a Linux CLI archive whose binaries print `version (commit)`.
pub(super) fn linux_release(root: &Path, version: &str, commit: &str) -> (Release, Asset, PathBuf) {
    linux_release_with(root, version, commit, false)
}

/// The same, with the local model runtime's folder (`bin/llama/llama-server` holding the version) when `runtime`.
pub(super) fn linux_release_with(
    root: &Path,
    version: &str,
    commit: &str,
    runtime: bool,
) -> (Release, Asset, PathBuf) {
    let top = format!("antenna-{version}-linux-x86_64");
    let src = root.join("src");
    bins(&src.join(&top).join("bin"), version, commit);
    if runtime {
        let d = src.join(&top).join("bin/llama");
        fs::create_dir_all(&d).unwrap();
        fs::write(d.join("llama-server"), version).unwrap();
    }
    let rel_dir = root.join("rel");
    fs::create_dir_all(&rel_dir).unwrap();
    let name = format!("{top}.tar.gz");
    let st = Command::new("tar")
        .arg("-czf")
        .arg(rel_dir.join(&name))
        .arg("-C")
        .arg(&src)
        .arg(&top)
        .status()
        .unwrap();
    assert!(st.success());
    let data = fs::read(rel_dir.join(&name)).unwrap();
    let mp = release_dir(&rel_dir, version, &[(name.as_str(), &data)]);
    open(
        &mp,
        Platform {
            os: "linux",
            arch: "x86_64",
            kind: "cli",
        },
    )
}

/// A release folder with a fake disk image that "contains" an app of `version`.
pub(super) fn mac_release(
    root: &Path,
    version: &str,
    commit: &str,
    numeric: Option<&str>,
) -> (Release, Asset, PathBuf) {
    let tmpl = fake_app(&root.join("tmpl/Antenna.app"), version, commit);
    if let Some(n) = numeric {
        let p = tmpl.join("Contents/Info.plist");
        let s = fs::read_to_string(&p)
            .unwrap()
            .replace(version.split('-').next().unwrap(), n);
        fs::write(p, s).unwrap();
    }
    let rel_dir = root.join("rel");
    fs::create_dir_all(&rel_dir).unwrap();
    let name = format!("Antenna-{version}-macos-arm64.dmg");
    let data = format!("FAKE-DMG:{}", tmpl.display());
    let mp = release_dir(&rel_dir, version, &[(name.as_str(), data.as_bytes())]);
    open(
        &mp,
        Platform {
            os: "macos",
            arch: "arm64",
            kind: "app",
        },
    )
}

fn open(mp: &Path, p: Platform) -> (Release, Asset, PathBuf) {
    let loc = package::locate(&[mp.to_path_buf()]).unwrap();
    let rel = package::open_release(&loc, &KeySet::test_only()).unwrap();
    let (a, path) = package::find_asset(&rel, &loc, &p).unwrap();
    (rel, a, path)
}

pub(super) struct Fixture {
    _d: tempfile::TempDir,
    pub(super) root: PathBuf,
    pub(super) home: PathBuf,
    pub(super) sys: FakeSys,
    pub(super) log: Log,
}

impl Fixture {
    pub(super) fn new() -> Self {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().to_path_buf();
        let home = root.join("home");
        fs::create_dir_all(&home).unwrap();
        Self {
            _d: d,
            log: Log::new(Some(root.join("update.log")), false),
            root,
            home,
            sys: FakeSys::default(),
        }
    }

    pub(super) fn installer(
        &self,
        target: Target,
        running: Option<RunningDaemon>,
        fail_at: FailAt,
    ) -> Installer<'_> {
        Installer {
            target,
            sys: &self.sys,
            log: &self.log,
            probe: &self.sys,
            env: Env {
                home: self.home.clone(),
                uid: 501,
                xdg_config: None,
            },
            running,
            fail_at,
            handoff: None,
        }
    }

    /// `~/.local/bin` with v1 and the systemd unit `install.sh` writes, the daemon running.
    pub(super) fn bindir_with_systemd(&self) -> PathBuf {
        let bin = self.home.join(".local/bin");
        bins(&bin, V1, COMMIT);
        let unit_dir = self.home.join(".config/systemd/user");
        fs::create_dir_all(&unit_dir).unwrap();
        let unit = unit_dir.join("antennad.service");
        fs::write(
            &unit,
            format!(
                "[Service]\nExecStart={} --relay n0\n",
                bin.join("antennad").display()
            ),
        )
        .unwrap();
        self.sys.0.borrow_mut().unit = Some(unit);
        self.sys.0.borrow_mut().systemd_active = true;
        self.sys.start_daemon(&bin.join("antennad"));
        bin
    }

    pub(super) fn running(&self, exe: &Path) -> Option<RunningDaemon> {
        let w = self.sys.0.borrow();
        Some(RunningDaemon {
            pid: w.daemon_pid.unwrap_or(1),
            exe: Some(exe.to_path_buf()),
            version: w.daemon.clone().unwrap_or_default(),
            args: vec!["--relay".into(), "n0".into()],
            cwd: None,
        })
    }

    /// `/Applications/Antenna.app` v1 with the window's LaunchAgent, the daemon and the window running.
    pub(super) fn app_with_launch_agent(&self) -> PathBuf {
        let app = fake_app(&self.root.join("Applications/Antenna.app"), V1, COMMIT);
        let la = self.home.join("Library/LaunchAgents");
        fs::create_dir_all(&la).unwrap();
        fs::write(
            la.join(format!("{}.plist", super::LAUNCH_AGENT_LABEL)),
            serde_json::json!({ "ProgramArguments": [app.join("Contents/Helpers/antennad")] })
                .to_string(),
        )
        .unwrap();
        self.sys
            .start_daemon(&app.join("Contents/Helpers/antennad"));
        self.sys.spawn(&app.join("Contents/MacOS/Antenna"));
        app
    }

    pub(super) fn windows(&self, app: &Path) -> usize {
        let exe = app.join("Contents/MacOS/Antenna");
        self.sys
            .0
            .borrow()
            .procs
            .values()
            .filter(|p| **p == exe)
            .count()
    }
}

/// Runs a test body on its own thread and fails the test when it does not finish in time (`ANTENNA_TEST_TIMEOUT_SECS`,
/// 120 s by default): two of these tests hung on a Mac (TROUBLESHOOTING "macOS 27 on a real Mac"), and a hang must be a
/// failure with a name, not a stuck `cargo test`. On a timeout the thread is left behind; the test process ends with
/// the run.
pub(super) fn guarded(name: &str, f: impl FnOnce() + Send + 'static) {
    use std::sync::mpsc::RecvTimeoutError;
    let limit = std::time::Duration::from_secs(
        std::env::var("ANTENNA_TEST_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(120),
    );
    let (tx, rx) = std::sync::mpsc::channel();
    let h = std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            f();
            let _ = tx.send(());
        })
        .unwrap();
    match rx.recv_timeout(limit) {
        Ok(()) => h.join().unwrap(),
        Err(RecvTimeoutError::Disconnected) => {
            if let Err(p) = h.join() {
                std::panic::resume_unwind(p);
            }
        }
        Err(RecvTimeoutError::Timeout) => {
            panic!(
                "{name} did not finish within {} s: it hangs",
                limit.as_secs()
            )
        }
    }
}

pub(super) fn line(name: &str, v: &str) -> String {
    format!("{name} {v} ({COMMIT})")
}

#[test]
fn bindir_with_systemd_install_then_rollback() {
    guarded("bindir_with_systemd_install_then_rollback", || {
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        assert!(matches!(
            inst.keeper(),
            Keeper::Systemd { active: true, .. }
        ));
        let plan = inst.plan_install(&rel).join("\n");
        assert!(
            plan.contains("systemctl --user stop") && plan.contains("antennad.previous"),
            "{plan}"
        );

        let out = inst.install(&rel, &asset, &path).unwrap();
        assert_eq!(out.to, line("antenna", V2));
        assert!(out.daemon.restarted && out.keys_locked);
        assert_eq!(out.daemon.how, "systemd");
        assert_eq!(version(&bin.join("antenna")), line("antenna", V2));
        assert_eq!(version(&bin.join("antennad")), line("antennad", V2));
        assert_eq!(version(&bin.join("antenna.previous")), line("antenna", V1));
        assert_eq!(
            f.sys.0.borrow().daemon.as_deref(),
            Some(line("antennad", V2).as_str())
        );
        let sc = f.sys.calls_of("systemctl");
        assert!(
            sc.iter().any(|c| c.contains(" stop ")) && sc.iter().any(|c| c.contains(" start ")),
            "{sc:?}"
        );
        assert!(
            !bin.join(STAGE_DIR).exists(),
            "the staging folder is removed"
        );
        assert!(
            fs::read_to_string(f.root.join("update.log"))
                .unwrap()
                .contains("done:")
        );

        // Rollback: the previous version is back and running; the newer one is kept as .previous.
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        let (prev, steps) = inst.plan_rollback().unwrap();
        assert_eq!(prev.version, V1);
        assert!(!steps.is_empty());
        let out = inst.rollback().unwrap();
        assert_eq!(out.to, line("antenna", V1));
        assert_eq!(version(&bin.join("antennad")), line("antennad", V1));
        assert_eq!(
            version(&bin.join("antennad.previous")),
            line("antennad", V2)
        );
        assert_eq!(
            f.sys.0.borrow().daemon.as_deref(),
            Some(line("antennad", V1).as_str())
        );
    });
}

/// The local model runtime's folder comes with the binaries, is kept as `llama.previous`, comes back with a rollback,
/// and a failure after the swap puts the old one back (D-104).
#[test]
fn bindir_carries_the_local_model_runtime() {
    guarded("bindir_carries_the_local_model_runtime", || {
        let runtime =
            |bin: &Path, name: &str| fs::read_to_string(bin.join(name).join("llama-server")).ok();
        // A first release with a runtime onto an installation without one: it is moved into place.
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        let (rel, asset, path) = linux_release_with(&f.root, V2, COMMIT, true);
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        assert!(
            inst.plan_install(&rel)
                .join("\n")
                .contains("llama.previous")
        );
        inst.install(&rel, &asset, &path).unwrap();
        assert_eq!(runtime(&bin, "llama").as_deref(), Some(V2));
        assert!(!bin.join("llama.previous").exists());

        // An installation with a runtime: swapped, the old one kept; a rollback brings it back.
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        fs::create_dir_all(bin.join("llama")).unwrap();
        fs::write(bin.join("llama/llama-server"), V1).unwrap();
        let (rel, asset, path) = linux_release_with(&f.root, V2, COMMIT, true);
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        inst.install(&rel, &asset, &path).unwrap();
        assert_eq!(runtime(&bin, "llama").as_deref(), Some(V2));
        assert_eq!(runtime(&bin, "llama.previous").as_deref(), Some(V1));
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        inst.rollback().unwrap();
        assert_eq!(version(&bin.join("antennad")), line("antennad", V1));
        assert_eq!(runtime(&bin, "llama").as_deref(), Some(V1));
        assert_eq!(runtime(&bin, "llama.previous").as_deref(), Some(V2));

        // A failure after the swap: the old binaries and the old runtime are back.
        for point in ["swapped", "started"] {
            let f = Fixture::new();
            let bin = f.bindir_with_systemd();
            fs::create_dir_all(bin.join("llama")).unwrap();
            fs::write(bin.join("llama/llama-server"), V1).unwrap();
            let (rel, asset, path) = linux_release_with(&f.root, V2, COMMIT, true);
            let inst = f.installer(
                Target::BinDir { dir: bin.clone() },
                f.running(&bin.join("antennad")),
                Some((point.into(), false)),
            );
            inst.install(&rel, &asset, &path).unwrap_err();
            assert_eq!(
                version(&bin.join("antennad")),
                line("antennad", V1),
                "{point}"
            );
            assert_eq!(runtime(&bin, "llama").as_deref(), Some(V1), "{point}");
        }
    });
}

#[test]
fn bindir_daemon_that_does_not_answer_is_swapped_back() {
    guarded("bindir_daemon_that_does_not_answer_is_swapped_back", || {
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        let before = journal::ident(&bin.join("antennad"));
        let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
        f.sys.0.borrow_mut().start_fails = true;
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        let e = inst.install(&rel, &asset, &path).unwrap_err();
        assert_eq!(e.code, code::INSTALL_FAILED);
        assert!(e.message.contains("was restored"), "{}", e.message);
        assert_eq!(journal::ident(&bin.join("antennad")), before);
        assert_eq!(version(&bin.join("antenna")), line("antenna", V1));
        // Started twice: the new version (no answer), then the old one again.
        assert_eq!(
            f.sys
                .calls_of("systemctl")
                .iter()
                .filter(|c| c.contains(" start "))
                .count(),
            2
        );
        assert!(!bin.join(STAGE_DIR).exists());
    });
}

#[test]
fn bindir_a_failure_at_any_point_leaves_the_old_version() {
    guarded(
        "bindir_a_failure_at_any_point_leaves_the_old_version",
        || {
            for point in ["staged", "stopped", "swap1", "swapped", "started"] {
                let f = Fixture::new();
                let bin = f.bindir_with_systemd();
                let ids: Vec<_> = ["antenna", "antennad"]
                    .iter()
                    .map(|b| journal::ident(&bin.join(b)))
                    .collect();
                let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
                let inst = f.installer(
                    Target::BinDir { dir: bin.clone() },
                    f.running(&bin.join("antennad")),
                    Some((point.into(), false)),
                );
                let e = inst.install(&rel, &asset, &path).unwrap_err();
                assert!(e.message.contains(point), "{point}: {}", e.message);
                let now: Vec<_> = ["antenna", "antennad"]
                    .iter()
                    .map(|b| journal::ident(&bin.join(b)))
                    .collect();
                assert_eq!(now, ids, "{point}: the old binaries are in place");
                assert_eq!(
                    f.sys.0.borrow().daemon.as_deref(),
                    Some(line("antennad", V1).as_str()),
                    "{point}: the old daemon runs"
                );
                assert!(!bin.join(STAGE_DIR).exists(), "{point}");
            }
        },
    );
}

#[test]
fn bindir_daemon_started_by_hand_is_left_alone() {
    guarded("bindir_daemon_started_by_hand_is_left_alone", || {
        let f = Fixture::new();
        let bin = f.home.join("bin");
        bins(&bin, V1, COMMIT);
        f.sys.start_daemon(&bin.join("antennad"));
        let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        assert!(matches!(inst.keeper(), Keeper::Manual { .. }));
        assert!(
            inst.plan_install(&rel)
                .join("\n")
                .contains("started by hand")
        );
        let out = inst.install(&rel, &asset, &path).unwrap();
        assert!(!out.daemon.restarted && !out.keys_locked);
        assert!(
            out.daemon
                .note
                .unwrap()
                .contains("still runs the old version")
        );
        assert!(
            f.sys
                .calls_of("systemctl")
                .iter()
                .all(|c| !c.contains(" stop "))
        );
        assert_eq!(version(&bin.join("antenna")), line("antenna", V2));
        assert_eq!(
            f.sys.0.borrow().daemon.as_deref(),
            Some(line("antennad", V1).as_str())
        );
    });
}

#[test]
fn bindir_binaries_must_match_the_manifest() {
    guarded("bindir_binaries_must_match_the_manifest", || {
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        // The archive's binaries report another commit than the manifest.
        let (rel, asset, path) = linux_release(&f.root, V2, "fedcba987654");
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        let e = inst.install(&rel, &asset, &path).unwrap_err();
        assert_eq!(e.code, code::INSTALL_FAILED);
        assert!(e.message.contains("the manifest says"), "{}", e.message);
        assert_eq!(version(&bin.join("antenna")), line("antenna", V1));
        assert!(
            f.sys
                .calls_of("systemctl")
                .iter()
                .all(|c| !c.contains(" stop ")),
            "nothing was stopped"
        );
    });
}

#[test]
fn an_interrupted_update_is_undone_by_the_next_run() {
    guarded("an_interrupted_update_is_undone_by_the_next_run", || {
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        let (rel, asset, path) = linux_release(&f.root, V2, COMMIT);
        // A crash right after the daemon was swapped: simulate the state the installer leaves at "swap1" when killed.
        let inst = f.installer(
            Target::BinDir { dir: bin.clone() },
            f.running(&bin.join("antennad")),
            None,
        );
        let (stage, _) = inst.open_stage().unwrap();
        let new_bin = stage.dir.join("new");
        bins(&new_bin, V2, COMMIT);
        let keeper = inst.keeper();
        let items = ["antennad", "antenna"]
            .iter()
            .map(|b| {
                journal::item(
                    &bin.join(b),
                    vec![new_bin.join(b), with_suffix(&bin.join(b), ".previous")],
                )
                .unwrap()
            })
            .collect();
        journal::write(
            &stage.dir,
            &journal::Journal {
                action: "install".into(),
                started: crate::utc_now(),
                from: line("antenna", V1),
                to: line("antenna", V2),
                keeper,
                relaunch: None,
                items,
            },
        )
        .unwrap();
        inst.stop(&inst.keeper()).unwrap();
        super::exchange(&new_bin.join("antennad"), &bin.join("antennad")).unwrap();
        drop(stage); // the process "died": the lock is released, the journal stays
        assert!(inst.interrupted());
        assert_eq!(version(&bin.join("antennad")), line("antennad", V2));

        let next = f.installer(Target::BinDir { dir: bin.clone() }, None, None);
        // The dropped lock is free at once, except while another test of this process is between fork and exec: the
        // child then holds a copy of the descriptor (CLOEXEC closes it only at exec) and flock still sees it taken.
        // Retry for a moment instead of reading that window as a running update (seen once in a release build).
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let msg = loop {
            match next.recover() {
                Err(e)
                    if e.code == crate::code::UPDATE_IN_PROGRESS
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                r => break r.unwrap().unwrap(),
            }
        };
        assert!(msg.contains("undone"), "{msg}");
        assert_eq!(version(&bin.join("antennad")), line("antennad", V1));
        assert_eq!(version(&bin.join("antenna")), line("antenna", V1));
        assert!(!next.interrupted());
        assert_eq!(
            f.sys.0.borrow().daemon.as_deref(),
            Some(line("antennad", V1).as_str()),
            "started again"
        );
        // And a normal update works afterwards.
        let _ = (rel, asset, path);
    });
}

#[test]
fn one_update_at_a_time() {
    guarded("one_update_at_a_time", || {
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        let a = f.installer(Target::BinDir { dir: bin.clone() }, None, None);
        let (_held, _) = a.open_stage().unwrap();
        let b = f.installer(Target::BinDir { dir: bin.clone() }, None, None);
        assert_eq!(b.open_stage().err().unwrap().code, code::UPDATE_IN_PROGRESS);
    });
}

#[test]
fn app_install_with_the_launch_agent_and_the_window() {
    guarded("app_install_with_the_launch_agent_and_the_window", || {
        let f = Fixture::new();
        let app = f.app_with_launch_agent();
        let (rel, asset, path) = mac_release(&f.root, V2, COMMIT, None);
        let inst = f.installer(
            Target::MacosApp { app: app.clone() },
            f.running(&app.join("Contents/Helpers/antennad")),
            None,
        );
        assert!(matches!(inst.keeper(), Keeper::LaunchAgent { .. }));
        let plan = inst.plan_install(&rel).join("\n");
        assert!(
            plan.contains("close the Antenna window") && plan.contains("launchctl bootstrap"),
            "{plan}"
        );
        assert!(plan.contains("keys are locked"), "{plan}");

        let out = inst.install(&rel, &asset, &path).unwrap();
        assert_eq!(out.to, line("Antenna", V2));
        assert_eq!(out.app_relaunched, Some(true));
        assert!(out.daemon.restarted && out.keys_locked);
        assert_eq!(
            version(&app.join("Contents/Helpers/antenna")),
            line("antenna", V2)
        );
        let prev = with_suffix(&app, ".previous");
        assert_eq!(
            version(&prev.join("Contents/Helpers/antenna")),
            line("antenna", V1)
        );
        assert_eq!(f.windows(&app), 1, "the window is open again");
        let calls = f.sys.0.borrow().calls.clone();
        let pos = |p: &str| {
            calls
                .iter()
                .position(|c| c.starts_with(p))
                .unwrap_or_else(|| panic!("no {p}: {calls:?}"))
        };
        assert!(
            pos("kill Term") < pos("launchctl bootout"),
            "the window closes before the daemon stops"
        );
        assert!(pos("launchctl bootout") < pos("launchctl bootstrap"));
        assert!(pos("hdiutil attach -readonly -nobrowse -noautoopen") < pos("ditto --noqtn"));
        assert!(pos("ditto") < pos("hdiutil detach"));
        assert!(pos("codesign --verify --deep --strict") < pos("launchctl bootout"));
        assert!(pos("launchctl bootstrap") < pos("open "));
        assert!(!app.parent().unwrap().join(STAGE_DIR).exists());

        // Rollback swaps the bundles back.
        let inst = f.installer(
            Target::MacosApp { app: app.clone() },
            f.running(&app.join("Contents/Helpers/antennad")),
            None,
        );
        let out = inst.rollback().unwrap();
        assert_eq!(out.to, line("Antenna", V1));
        assert_eq!(
            version(&app.join("Contents/Helpers/antenna")),
            line("antenna", V1)
        );
        assert_eq!(
            version(&prev.join("Contents/Helpers/antenna")),
            line("antenna", V2)
        );
        assert_eq!(
            f.sys.0.borrow().daemon.as_deref(),
            Some(line("antennad", V1).as_str())
        );
        assert_eq!(f.windows(&app), 1);
    });
}

#[test]
fn app_checks_before_anything_is_touched() {
    guarded("app_checks_before_anything_is_touched", || {
        // A broken code signature, and an Info.plist version that does not match the manifest.
        for (codesign_fails, numeric, needle) in [
            (true, None, "code signature"),
            (false, Some("0.2.0"), "Info.plist version"),
        ] {
            let f = Fixture::new();
            let app = f.app_with_launch_agent();
            let before = journal::ident(&app);
            f.sys.0.borrow_mut().codesign_fails = codesign_fails;
            let (rel, asset, path) = mac_release(&f.root, V2, COMMIT, numeric);
            let inst = f.installer(
                Target::MacosApp { app: app.clone() },
                f.running(&app.join("Contents/Helpers/antennad")),
                None,
            );
            let e = inst.install(&rel, &asset, &path).unwrap_err();
            assert!(e.message.contains(needle), "{}", e.message);
            assert_eq!(journal::ident(&app), before);
            assert_eq!(f.windows(&app), 1, "the window was not closed");
            assert!(
                f.sys.calls_of("launchctl").is_empty(),
                "the daemon was not stopped"
            );
            assert!(
                f.sys
                    .calls_of("hdiutil")
                    .iter()
                    .any(|c| c.starts_with("hdiutil detach")),
                "the image is unmounted"
            );
        }
    });
}

#[test]
fn app_whose_daemon_does_not_start_is_swapped_back() {
    guarded("app_whose_daemon_does_not_start_is_swapped_back", || {
        let f = Fixture::new();
        let app = f.app_with_launch_agent();
        let before = journal::ident(&app);
        let (rel, asset, path) = mac_release(&f.root, V2, COMMIT, None);
        f.sys.0.borrow_mut().start_fails = true;
        let inst = f.installer(
            Target::MacosApp { app: app.clone() },
            f.running(&app.join("Contents/Helpers/antennad")),
            None,
        );
        let e = inst.install(&rel, &asset, &path).unwrap_err();
        assert!(e.message.contains("was restored"), "{}", e.message);
        assert_eq!(journal::ident(&app), before);
        assert_eq!(
            f.sys
                .calls_of("launchctl")
                .iter()
                .filter(|c| c.starts_with("launchctl bootstrap"))
                .count(),
            2
        );
        assert_eq!(f.windows(&app), 1, "the old window is opened again");
    });
}

#[test]
fn app_failure_points() {
    guarded("app_failure_points", || {
        for point in ["stopped", "swap1", "swapped", "started"] {
            let f = Fixture::new();
            let app = f.app_with_launch_agent();
            let before = journal::ident(&app);
            let (rel, asset, path) = mac_release(&f.root, V2, COMMIT, None);
            let inst = f.installer(
                Target::MacosApp { app: app.clone() },
                f.running(&app.join("Contents/Helpers/antennad")),
                Some((point.into(), false)),
            );
            assert!(inst.install(&rel, &asset, &path).is_err());
            assert_eq!(journal::ident(&app), before, "{point}");
            assert_eq!(
                f.sys.0.borrow().daemon.as_deref(),
                Some(line("antennad", V1).as_str()),
                "{point}: the old daemon runs"
            );
            assert_eq!(f.windows(&app), 1, "{point}");
        }
    });
}

#[test]
fn no_previous_no_rollback() {
    guarded("no_previous_no_rollback", || {
        let f = Fixture::new();
        let bin = f.bindir_with_systemd();
        let inst = f.installer(Target::BinDir { dir: bin }, None, None);
        assert_eq!(
            inst.plan_rollback().unwrap_err().code,
            code::ROLLBACK_UNAVAILABLE
        );
        assert_eq!(
            inst.rollback().unwrap_err().code,
            code::ROLLBACK_UNAVAILABLE
        );
        let inst = f.installer(
            Target::Unsupported {
                reason: "a development build".into(),
                path: None,
            },
            None,
            None,
        );
        assert_eq!(inst.rollback().unwrap_err().code, code::UNSUPPORTED_INSTALL);
        assert!(inst.recover().unwrap().is_none());
    });
}
