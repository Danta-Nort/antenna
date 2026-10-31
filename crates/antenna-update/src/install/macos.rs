// SPDX-License-Identifier: AGPL-3.0-only
//! The macOS app bundle: the `.dmg` is mounted read-only, `Antenna.app` is copied next to the installed one and
//! checked (code signature, `Info.plist`, the bundled binaries' `--version`), the window is closed and the daemon
//! stopped, the bundles are swapped atomically (the old one becomes `Antenna.app.previous`), the daemon is started
//! again through the window's LaunchAgent and the window is opened again if it was running.
//!
//! Every tool is called through [`super::Sys`], so this code runs in the unit tests on any OS against a fake that
//! simulates `hdiutil`, `ditto`, `codesign`, `plutil`, `launchctl`, `ps` and `open`; what only a Mac can show is in
//! `packaging/macos/check-update.sh`.

use std::{ffi::OsString, fs, path::Path, time::Duration};

use super::{BUNDLE_ID, Expect, Installer, Keeper, Outcome, journal, sys, with_suffix};
use crate::{Error, Result, code, manifest::Asset, package};

fn os(s: impl Into<OsString>) -> OsString {
    s.into()
}

impl Installer<'_> {
    /// A value from an app's `Info.plist` (`plutil -extract <key> raw`, which reads XML and binary plists).
    fn plist_value(&self, app: &Path, key: &str) -> Result<String> {
        let plist = app.join("Contents/Info.plist");
        let o = self.run(
            "plutil",
            &[
                os("-extract"),
                os(key),
                os("raw"),
                os("-o"),
                os("-"),
                plist.as_os_str().to_os_string(),
            ],
        )?;
        if !o.ok {
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!("{}: no {key} ({})", plist.display(), o.describe()),
            ));
        }
        Ok(o.stdout.trim().to_string())
    }

    /// PIDs of running windows of this app (by the path of their executable, from `ps`).
    pub(crate) fn app_processes(&self, app: &Path) -> Vec<u32> {
        let exe_name = self
            .plist_value(app, "CFBundleExecutable")
            .unwrap_or_else(|_| "Antenna".into());
        let exe = app.join("Contents/MacOS").join(&exe_name);
        let canon = fs::canonicalize(&exe).unwrap_or_else(|_| exe.clone());
        let Ok(o) = self
            .sys
            .run("ps".as_ref(), &sys::args(["-axo", "pid=,comm="]))
        else {
            return vec![];
        };
        o.stdout
            .lines()
            .filter_map(|l| {
                let l = l.trim_start();
                let (pid, comm) = l.split_once(' ')?;
                let comm = Path::new(comm.trim());
                let hit = comm == exe
                    || comm == canon
                    || fs::canonicalize(comm).is_ok_and(|c| c == canon);
                hit.then(|| pid.parse().ok()).flatten()
            })
            .filter(|p| *p != std::process::id())
            .collect()
    }

    fn quit_windows(&self, pids: &[u32]) {
        for pid in pids {
            self.log
                .step(format!("closing the Antenna window (pid {pid})"));
            if !sys::terminate(self.sys, *pid, Duration::from_secs(10)) {
                self.log
                    .step(format!("the window (pid {pid}) did not exit"));
            }
        }
    }

    pub(crate) fn plan_app(&self, app: &Path, rel: &package::Release) -> Vec<String> {
        let k = self.keeper();
        let base = app.parent().unwrap_or(Path::new("/"));
        let windows = !self.app_processes(app).is_empty();
        let mut s = vec![
            format!(
                "copy the disk image into {} and check it against the manifest again",
                base.join(super::STAGE_DIR).display()
            ),
            "mount it read-only and copy Antenna.app next to the installed one".into(),
            format!(
                "check the copy: codesign --verify --deep --strict, bundle {BUNDLE_ID}, version {} in Info.plist, \
                 and the bundled antenna and antennad report {} ({})",
                rel.version.numeric(),
                rel.manifest.version,
                rel.manifest.commit
            ),
        ];
        if windows {
            s.push("close the Antenna window".into());
        }
        s.push(self.stop_line(&k));
        s.push(format!(
            "swap {0} with the new copy; keep the old one as {0}.previous",
            app.display()
        ));
        match &k {
            Keeper::LaunchAgent { .. } => s.push(format!(
                "start the daemon again (launchctl bootstrap) and check that it reports {}; if not, swap the old app back",
                rel.manifest.version
            )),
            Keeper::Elsewhere { .. } => s.push("the running daemon belongs to another installation: not touched".into()),
            Keeper::Handover { .. } => s.push(format!(
                "wait until the daemon answers as {}, unlocked; if it does not, swap the old app back and start it (locked)",
                rel.manifest.version
            )),
            _ => {}
        }
        if windows {
            s.push("open Antenna again".into());
        }
        if !matches!(k, Keeper::Handover { .. }) {
            s.push("after the restart the keys are locked, as after a reboot: enter your password to unlock".into());
        }
        s.into_iter().filter(|l| !l.is_empty()).collect()
    }

    /// Copies the app out of the disk image (mounted read-only) into `dst`.
    fn copy_from_dmg(&self, dmg: &Path, mnt: &Path, dst: &Path) -> Result<()> {
        fs::create_dir(mnt).map_err(|e| Error::io(mnt.display(), e))?;
        self.log.step("mounting the disk image read-only");
        let o = self.run(
            "hdiutil",
            &[
                os("attach"),
                os("-readonly"),
                os("-nobrowse"),
                os("-noautoopen"),
                os("-mountpoint"),
                mnt.as_os_str().to_os_string(),
                dmg.as_os_str().to_os_string(),
            ],
        )?;
        if !o.ok {
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!("hdiutil attach: {}", o.describe()),
            ));
        }
        let src = mnt.join("Antenna.app");
        let copied = if src.is_dir() {
            self.log
                .step(format!("copying Antenna.app to {}", dst.display()));
            // `--noqtn`: the copy does not inherit a quarantine flag; the disk image was verified against the signed
            // manifest instead.
            self.run(
                "ditto",
                &[
                    os("--noqtn"),
                    src.as_os_str().to_os_string(),
                    dst.as_os_str().to_os_string(),
                ],
            )
            .and_then(|o| {
                if o.ok {
                    Ok(())
                } else {
                    Err(Error::new(
                        code::INSTALL_FAILED,
                        format!("ditto: {}", o.describe()),
                    ))
                }
            })
        } else {
            Err(Error::new(
                code::INSTALL_FAILED,
                "the disk image has no Antenna.app",
            ))
        };
        let d = self.run("hdiutil", &[os("detach"), mnt.as_os_str().to_os_string()]);
        if !d.as_ref().is_ok_and(|o| o.ok) {
            let _ = self.run(
                "hdiutil",
                &[os("detach"), os("-force"), mnt.as_os_str().to_os_string()],
            );
        }
        copied
    }

    /// Checks a copied app before it is installed.
    fn check_app(&self, app: &Path, rel: &package::Release, want: &Expect) -> Result<()> {
        let o = self.run(
            "codesign",
            &[
                os("--verify"),
                os("--deep"),
                os("--strict"),
                app.as_os_str().to_os_string(),
            ],
        )?;
        if !o.ok {
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!("the app's code signature does not verify: {}", o.describe()),
            ));
        }
        self.log.step("codesign --verify --deep --strict: ok");
        let id = self.plist_value(app, "CFBundleIdentifier")?;
        if id != BUNDLE_ID {
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!("bundle identifier {id:?}, expected {BUNDLE_ID}"),
            ));
        }
        let short = self.plist_value(app, "CFBundleShortVersionString")?;
        if short != rel.version.numeric() {
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!(
                    "Info.plist version {short}, the manifest says {}",
                    rel.version.numeric()
                ),
            ));
        }
        self.log.step(format!("Info.plist: {id} {short}"));
        for b in ["antenna", "antennad"] {
            self.expect_version(&app.join("Contents/Helpers").join(b), b, want)?;
        }
        Ok(())
    }

    pub(crate) fn install_app(
        &self,
        app: &Path,
        rel: &package::Release,
        asset: &Asset,
        asset_path: &Path,
    ) -> Result<Outcome> {
        let want = Expect::of(rel);
        let from = self
            .version_of(&app.join("Contents/Helpers/antenna"))
            .map(|e| e.line("Antenna"))
            .unwrap_or_else(|| "the installed version".into());
        let to = want.line("Antenna");
        let (stage, recovered) = self.open_stage()?;
        if let Some(r) = recovered {
            self.log.step(r);
        }
        self.log
            .step(format!("update {from} → {to} ({})", app.display()));
        let staged = stage.dir.join("Antenna.app");
        let prepared = (|| {
            let dmg = package::stage_asset(asset_path, asset, &stage.dir)?;
            self.log.step(format!(
                "copied and checked {} ({} bytes)",
                asset.name, asset.size
            ));
            self.checkpoint("staged")?;
            self.copy_from_dmg(&dmg, &stage.dir.join("mnt"), &staged)?;
            self.check_app(&staged, rel, &want)
        })();
        if let Err(e) = prepared {
            self.log.step(format!("not installed: {}", e.message));
            stage.finish();
            return Err(e);
        }

        let keeper = self.keeper();
        let windows = self.app_processes(app);
        let previous = with_suffix(app, ".previous");
        let j = journal::Journal {
            action: "install".into(),
            started: crate::utc_now(),
            from: from.clone(),
            to: to.clone(),
            keeper: keeper.clone(),
            relaunch: (!windows.is_empty()).then(|| app.to_path_buf()),
            items: vec![journal::item(
                app,
                vec![staged.clone(), previous.clone(), with_suffix(app, ".swap")],
            )?],
        };
        journal::write(&stage.dir, &j)?;
        let swapped = (|| {
            // The window first: it would start the daemon again on its own.
            self.quit_windows(&windows);
            self.stop(&keeper)?;
            self.checkpoint("stopped")?;
            super::exchange(&staged, app)?;
            self.log
                .step(format!("installed {to} at {}", app.display()));
            self.checkpoint("swap1")?;
            if previous.exists() {
                let old = stage.dir.join("old-previous");
                fs::rename(&previous, &old).map_err(|e| Error::io(previous.display(), e))?;
            }
            fs::rename(&staged, &previous).map_err(|e| Error::io(previous.display(), e))?;
            self.log
                .step(format!("kept {from} as {}", previous.display()));
            self.checkpoint("swapped")?;
            let restarted = self.start(&keeper, Some(&want))?;
            self.checkpoint("started")?;
            Ok(restarted)
        })();
        let restarted = match swapped {
            Ok(r) => r,
            Err(e) => {
                let err = self.undo(&j, &stage.dir, &e);
                stage.finish();
                return Err(err);
            }
        };
        journal::remove(&stage.dir);
        stage.finish();
        let relaunched = (!windows.is_empty()).then(|| self.relaunch(app));
        let daemon = self.daemon_outcome(&keeper, restarted, relaunched == Some(true));
        self.log.step(format!(
            "done: {to}{}{}",
            if matches!(keeper, Keeper::Handover { .. }) {
                ""
            } else {
                "; the daemon's keys are locked until you enter your password"
            },
            daemon
                .note
                .as_deref()
                .map(|n| format!("; {n}"))
                .unwrap_or_default()
        ));
        Ok(Outcome {
            action: "install",
            from,
            to,
            previous: Some(previous),
            keys_locked: restarted || relaunched == Some(true),
            daemon,
            app_relaunched: relaunched,
        })
    }

    pub(crate) fn rollback_app(&self, app: &Path) -> Result<Outcome> {
        let (stage, recovered) = self.open_stage()?;
        if let Some(r) = recovered {
            self.log.step(r);
        }
        let Some((previous, prev)) = self.previous() else {
            stage.finish();
            return Err(Error::new(
                code::ROLLBACK_UNAVAILABLE,
                format!(
                    "no {} to roll back to",
                    with_suffix(app, ".previous").display()
                ),
            ));
        };
        let from = self
            .version_of(&app.join("Contents/Helpers/antenna"))
            .map(|e| e.line("Antenna"))
            .unwrap_or_else(|| "the installed version".into());
        let to = prev.line("Antenna");
        self.log
            .step(format!("roll back {from} → {to} ({})", app.display()));
        let keeper = self.keeper();
        let windows = self.app_processes(app);
        let j = journal::Journal {
            action: "rollback".into(),
            started: crate::utc_now(),
            from: from.clone(),
            to: to.clone(),
            keeper: keeper.clone(),
            relaunch: (!windows.is_empty()).then(|| app.to_path_buf()),
            items: vec![journal::item(
                app,
                vec![previous.clone(), with_suffix(app, ".swap")],
            )?],
        };
        journal::write(&stage.dir, &j)?;
        let r = (|| {
            self.quit_windows(&windows);
            self.stop(&keeper)?;
            super::exchange(&previous, app)?;
            self.log.step(format!("restored {to} at {}", app.display()));
            self.checkpoint("swapped")?;
            self.start(&keeper, Some(&prev))
        })();
        let restarted = match r {
            Ok(r) => r,
            Err(e) => {
                let err = self.undo(&j, &stage.dir, &e);
                stage.finish();
                return Err(err);
            }
        };
        journal::remove(&stage.dir);
        stage.finish();
        let relaunched = (!windows.is_empty()).then(|| self.relaunch(app));
        let daemon = self.daemon_outcome(&keeper, restarted, relaunched == Some(true));
        self.log.step(format!(
            "done: rolled back to {to}; {from} is kept as {}",
            previous.display()
        ));
        Ok(Outcome {
            action: "rollback",
            from,
            to,
            previous: Some(previous),
            keys_locked: restarted || relaunched == Some(true),
            daemon,
            app_relaunched: relaunched,
        })
    }
}

/// Paths of a fake app, for tests on any unix (its binaries are shell scripts).
#[cfg(all(test, unix))]
pub(crate) fn fake_app(at: &Path, version: &str, commit: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let numeric = version.split('-').next().unwrap();
    fs::create_dir_all(at.join("Contents/Helpers")).unwrap();
    fs::create_dir_all(at.join("Contents/MacOS")).unwrap();
    // The fake plutil reads this JSON; the real one reads XML or binary plists.
    fs::write(
        at.join("Contents/Info.plist"),
        format!(
            r#"{{"CFBundleIdentifier":"{BUNDLE_ID}","CFBundleShortVersionString":"{numeric}","CFBundleExecutable":"Antenna"}}"#
        ),
    )
    .unwrap();
    for b in ["antenna", "antennad"] {
        let p = at.join("Contents/Helpers").join(b);
        fs::write(&p, format!("#!/bin/sh\necho '{b} {version} ({commit})'\n")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
    }
    fs::write(at.join("Contents/MacOS/Antenna"), b"window").unwrap();
    at.to_path_buf()
}
