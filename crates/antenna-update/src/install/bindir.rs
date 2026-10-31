// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna` and `antennad` in one directory: the `install.sh` layout on Linux (`~/.local/bin` and the systemd user unit
//! `antennad.service`), and the unpacked macOS CLI archive. Next to them, when the archive has it, the folder of the
//! local model runtime (`llama/`, D-104): swapped as a whole with the binaries and kept as `llama.previous`.

use std::{
    fs,
    path::{Path, PathBuf},
};

use super::{Expect, Installer, Keeper, Outcome, journal, sys, with_suffix};
use crate::{Error, Result, code, manifest::Asset, package};

/// The binaries, in the order they are swapped: the daemon first, the CLI that runs the update last.
const BINS: [&str; 2] = ["antennad", "antenna"];
/// The local model runtime's folder next to the binaries (`llama/llama-server`, its libraries and chat templates).
/// The daemon finds it there; it is part of the signed archive, so it is replaced with the binaries (D-104).
const RUNTIME_DIR: &str = "llama";

/// A real folder (not a link to one).
fn is_folder(p: &Path) -> bool {
    fs::symlink_metadata(p).is_ok_and(|m| m.is_dir())
}

impl Installer<'_> {
    pub(crate) fn plan_bindir(&self, dir: &Path, rel: &package::Release) -> Vec<String> {
        let k = self.keeper();
        let v = &rel.manifest.version;
        let mut s = vec![
            format!("copy the archive into {} and check it against the manifest again", dir.join(super::STAGE_DIR).display()),
            "unpack it and check that bin/antenna and bin/antennad report the version and commit of the manifest".into(),
        ];
        s.push(self.stop_line(&k));
        s.push(format!(
            "swap {0}/antennad and {0}/antenna with the new ones; keep the old ones as antennad.previous and antenna.previous",
            dir.display()
        ));
        s.push(format!(
            "when the archive has the local model runtime, swap the folder {}/{RUNTIME_DIR} the same way ({RUNTIME_DIR}.previous)",
            dir.display()
        ));
        match &k {
            Keeper::Systemd { active: true, .. } => s.push(format!(
                "start the daemon again (systemctl --user start {}) and check that it reports {v}; if not, swap the old version back",
                super::SYSTEMD_UNIT
            )),
            Keeper::Systemd { active: false, .. } => s.push("the systemd service is not running: it is not started".into()),
            Keeper::Handover { .. } => s.push(format!(
                "wait until the daemon answers as {v}, unlocked; if it does not, swap the old version back and start it (locked)"
            )),
            _ => {}
        }
        s.into_iter().filter(|l| !l.is_empty()).collect()
    }

    pub(crate) fn install_bindir(
        &self,
        dir: &Path,
        rel: &package::Release,
        asset: &Asset,
        asset_path: &Path,
    ) -> Result<Outcome> {
        let want = Expect::of(rel);
        let from = self
            .version_of(&dir.join("antenna"))
            .map(|e| e.line("antenna"))
            .unwrap_or_else(|| "the installed version".into());
        let to = want.line("antenna");
        let (stage, recovered) = self.open_stage()?;
        if let Some(r) = recovered {
            self.log.step(r);
        }
        self.log
            .step(format!("update {from} → {to} in {}", dir.display()));
        let prepared = (|| {
            let tgz = package::stage_asset(asset_path, asset, &stage.dir)?;
            self.log.step(format!(
                "copied and checked {} ({} bytes)",
                asset.name, asset.size
            ));
            self.checkpoint("staged")?;
            let x = stage.dir.join("unpacked");
            fs::create_dir(&x).map_err(|e| Error::io(x.display(), e))?;
            let o = self.run(
                "tar",
                &sys::args([
                    "-xzf".as_ref(),
                    tgz.as_os_str(),
                    "-C".as_ref(),
                    x.as_os_str(),
                    "--no-same-owner".as_ref(),
                ]),
            )?;
            if !o.ok {
                return Err(Error::new(
                    code::INSTALL_FAILED,
                    format!("unpacking {}: {}", asset.name, o.describe()),
                ));
            }
            let tops: Vec<PathBuf> = fs::read_dir(&x)
                .map_err(|e| Error::io(x.display(), e))?
                .flatten()
                .map(|e| e.path())
                .collect();
            let [top] = tops.as_slice() else {
                return Err(Error::new(
                    code::INSTALL_FAILED,
                    "the archive must have exactly one top folder",
                ));
            };
            let bin = top.join("bin");
            for b in BINS {
                let p = bin.join(b);
                if !p.is_file() || p.is_symlink() {
                    return Err(Error::new(
                        code::INSTALL_FAILED,
                        format!("the archive has no bin/{b}"),
                    ));
                }
                self.expect_version(&p, b, &want)?;
            }
            Ok(bin)
        })();
        let bin = match prepared {
            Ok(b) => b,
            Err(e) => {
                self.log.step(format!("not installed: {}", e.message));
                stage.finish();
                return Err(e);
            }
        };

        let keeper = self.keeper();
        let mut items = BINS
            .iter()
            .map(|b| {
                let path = dir.join(b);
                journal::item(
                    &path,
                    vec![
                        bin.join(b),
                        with_suffix(&path, ".previous"),
                        with_suffix(&path, ".swap"),
                    ],
                )
            })
            .collect::<Result<Vec<_>>>()?;
        let runtime = bin.join(RUNTIME_DIR);
        let has_runtime = is_folder(&runtime);
        let installed_runtime = dir.join(RUNTIME_DIR);
        if has_runtime && is_folder(&installed_runtime) {
            items.push(journal::item(
                &installed_runtime,
                vec![
                    runtime.clone(),
                    with_suffix(&installed_runtime, ".previous"),
                    with_suffix(&installed_runtime, ".swap"),
                ],
            )?);
        }
        let j = journal::Journal {
            action: "install".into(),
            started: crate::utc_now(),
            from: from.clone(),
            to: to.clone(),
            keeper: keeper.clone(),
            relaunch: None,
            items,
        };
        journal::write(&stage.dir, &j)?;

        let swapped = (|| {
            self.stop(&keeper)?;
            self.checkpoint("stopped")?;
            for (i, b) in BINS.iter().enumerate() {
                super::exchange(&bin.join(b), &dir.join(b))?;
                self.log
                    .step(format!("installed {}", dir.join(b).display()));
                if i == 0 {
                    self.checkpoint("swap1")?;
                }
            }
            if has_runtime {
                if is_folder(&installed_runtime) {
                    super::exchange(&runtime, &installed_runtime)?;
                } else {
                    // The first release with a runtime: nothing to keep (an undo leaves it; an older daemon either
                    // does not look for it or runs the same runtime).
                    fs::rename(&runtime, &installed_runtime)
                        .map_err(|e| Error::io(installed_runtime.display(), e))?;
                }
                self.log
                    .step(format!("installed {}", installed_runtime.display()));
            }
            for b in BINS {
                let prev = with_suffix(&dir.join(b), ".previous");
                fs::rename(bin.join(b), &prev).map_err(|e| Error::io(prev.display(), e))?;
            }
            if is_folder(&runtime) {
                let prev = with_suffix(&installed_runtime, ".previous");
                if is_folder(&prev) {
                    fs::remove_dir_all(&prev).map_err(|e| Error::io(prev.display(), e))?;
                }
                fs::rename(&runtime, &prev).map_err(|e| Error::io(prev.display(), e))?;
            }
            self.log.step(format!(
                "kept the old version as antennad.previous and antenna.previous in {}",
                dir.display()
            ));
            self.checkpoint("swapped")?;
            let restarted = match &keeper {
                Keeper::Systemd { active: true, .. } | Keeper::Handover { .. } => {
                    self.start(&keeper, Some(&want))?
                }
                _ => false,
            };
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
        let daemon = self.daemon_outcome(&keeper, restarted, false);
        self.log.step(format!(
            "done: {to}{}",
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
            previous: Some(with_suffix(&dir.join("antenna"), ".previous")),
            keys_locked: restarted,
            daemon,
            app_relaunched: None,
        })
    }

    pub(crate) fn rollback_bindir(&self, dir: &Path) -> Result<Outcome> {
        let (stage, recovered) = self.open_stage()?;
        if let Some(r) = recovered {
            self.log.step(r);
        }
        let Some((_, prev)) = self.previous() else {
            stage.finish();
            return Err(Error::new(
                code::ROLLBACK_UNAVAILABLE,
                format!(
                    "no antenna.previous and antennad.previous of one version in {}",
                    dir.display()
                ),
            ));
        };
        let from = self
            .version_of(&dir.join("antenna"))
            .map(|e| e.line("antenna"))
            .unwrap_or_else(|| "the installed version".into());
        let to = prev.line("antenna");
        self.log
            .step(format!("roll back {from} → {to} in {}", dir.display()));
        let keeper = self.keeper();
        let mut items = BINS
            .iter()
            .map(|b| {
                let path = dir.join(b);
                journal::item(
                    &path,
                    vec![with_suffix(&path, ".previous"), with_suffix(&path, ".swap")],
                )
            })
            .collect::<Result<Vec<_>>>()?;
        let runtime = dir.join(RUNTIME_DIR);
        let runtime_prev = with_suffix(&runtime, ".previous");
        // The previous version's runtime, if it had one: it comes back with its binaries.
        let swap_runtime = is_folder(&runtime_prev) && is_folder(&runtime);
        if swap_runtime {
            items.push(journal::item(
                &runtime,
                vec![runtime_prev.clone(), with_suffix(&runtime, ".swap")],
            )?);
        }
        let j = journal::Journal {
            action: "rollback".into(),
            started: crate::utc_now(),
            from: from.clone(),
            to: to.clone(),
            keeper: keeper.clone(),
            relaunch: None,
            items,
        };
        journal::write(&stage.dir, &j)?;
        let r = (|| {
            self.stop(&keeper)?;
            for b in BINS {
                let p = dir.join(b);
                super::exchange(&with_suffix(&p, ".previous"), &p)?;
                self.log.step(format!("restored {} ({to})", p.display()));
            }
            if swap_runtime {
                super::exchange(&runtime_prev, &runtime)?;
                self.log
                    .step(format!("restored {} ({to})", runtime.display()));
            }
            self.checkpoint("swapped")?;
            // A rollback is often needed because the new daemon does not start: the service is started even if it was
            // not running.
            match &keeper {
                Keeper::Systemd { .. } => self.start(&keeper, Some(&prev)),
                _ => Ok(false),
            }
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
        let daemon = self.daemon_outcome(&keeper, restarted, false);
        self.log.step(format!(
            "done: rolled back to {to}; {from} is kept as .previous"
        ));
        Ok(Outcome {
            action: "rollback",
            from,
            to,
            previous: Some(with_suffix(&dir.join("antenna"), ".previous")),
            keys_locked: restarted,
            daemon,
            app_relaunched: None,
        })
    }
}
