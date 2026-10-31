// SPDX-License-Identifier: AGPL-3.0-only
//! Installing a verified update, rolling back, recovering after an interruption (`docs/UPDATES.md` §6).
//!
//! The same shape on both systems:
//! 1. a private staging folder next to what is replaced (same file system), locked against a second update;
//! 2. the verified asset is copied there and checked again ([`crate::package::stage_asset`]); the new version is
//!    unpacked and checked (macOS: the app's code signature, `Info.plist`, the bundled binaries' `--version`; Linux:
//!    the binaries' `--version`) — until here nothing installed was touched;
//! 3. the journal is written, the daemon is stopped (and on macOS the window is closed);
//! 4. the swap: an atomic exchange of directory entries (`renameat2(RENAME_EXCHANGE)` on Linux, `renamex_np
//!    (RENAME_SWAP)` on macOS, both through `rustix`), the old one is kept as `.previous`;
//! 5. the daemon is started the way it is normally started and must answer with the new version; otherwise the old
//!    version is swapped back and started again.
//!
//! Every step is logged ([`Log`]). After a restart the daemon's keys are locked, as after a reboot.
//!
//! Windows has no installer yet (D-134, WP-29, phase W4): [`Target::detect`] reports it as unsupported, and the steps
//! that touch an installation (the staging lock, the swap, the journal) refuse there.

pub mod journal;
pub mod sys;
pub mod target;

mod bindir;
mod handover;
mod macos;

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    cell::RefCell,
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::Duration,
};

use serde::{Deserialize, Serialize};

pub use sys::{Out, RealSys, Sig, Sys};
pub use target::Target;

use crate::{Error, Result, code, package::Release};

/// Name of the staging folder next to the installation.
pub const STAGE_DIR: &str = ".antenna-update";
/// LaunchAgent label of the daemon (the window's `launchAgentLabel`).
pub const LAUNCH_AGENT_LABEL: &str = "io.github.danta-nort.antenna.daemon";
/// Bundle ID of the app.
pub const BUNDLE_ID: &str = "io.github.danta-nort.antenna";
/// The systemd user unit `install.sh` writes.
pub const SYSTEMD_UNIT: &str = "antennad.service";
/// How long a restarted daemon has to answer with the new version.
pub const START_TIMEOUT: Duration = Duration::from_secs(30);

/// The update log: every line goes to the log file (0600) and, when asked, to stderr.
#[derive(Debug, Default)]
pub struct Log {
    path: Option<PathBuf>,
    echo: bool,
    lines: RefCell<Vec<String>>,
}

impl Log {
    /// A log into `path` (created with its folders), echoing to stderr when `echo`.
    pub fn new(path: Option<PathBuf>, echo: bool) -> Self {
        Self {
            path,
            echo,
            lines: RefCell::new(Vec::new()),
        }
    }

    /// Logs one step.
    pub fn step(&self, msg: impl AsRef<str>) {
        let msg = msg.as_ref();
        if self.echo {
            // Not `eprintln!`: it panics when stderr is gone (the window that started the update has quit).
            let _ = writeln!(std::io::stderr(), "==> {msg}");
        }
        if let Some(p) = &self.path {
            if let Some(d) = p.parent() {
                let _ = fs::create_dir_all(d);
            }
            let mut o = fs::OpenOptions::new();
            o.create(true).append(true);
            // Windows: the file inherits its folder's DACL; owner-only data folders come in W1 (D-134, WP-4).
            #[cfg(unix)]
            o.mode(0o600);
            if let Ok(mut f) = o.open(p) {
                let _ = writeln!(f, "{} {msg}", crate::utc_now());
            }
        }
        self.lines.borrow_mut().push(msg.to_string());
    }

    /// The log file.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Lines logged by this process (tests).
    pub fn lines(&self) -> Vec<String> {
        self.lines.borrow().clone()
    }
}

/// Where the update log lives: next to the daemon log the window writes (D-55).
pub fn default_log_path(home: &Path, os: &str, xdg_state: Option<&Path>) -> PathBuf {
    if os == "macos" {
        return home.join("Library/Logs/Antenna/update.log");
    }
    match xdg_state.filter(|p| p.is_absolute()) {
        Some(s) => s.join("antenna/update.log"),
        None => home.join(".local/state/antenna/update.log"),
    }
}

/// What the daemon said when the owner authorized the update (the control command `update_authorize`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunningDaemon {
    /// Its PID.
    pub pid: u32,
    /// Its executable, as it sees it.
    pub exe: Option<PathBuf>,
    /// `antennad <version> (<commit>)`.
    pub version: String,
    /// Its arguments after the program name (an automatic install: to start it again by hand after a failure).
    pub args: Vec<String>,
    /// Its working folder (the same).
    pub cwd: Option<PathBuf>,
}

/// Asks the daemon for its version over the control socket.
pub trait Probe {
    /// `antennad <version> (<commit>)` if a daemon answers now.
    fn daemon_version(&self) -> Option<String>;

    /// The version line and the key state (`locked`, `unlocked`, …) if a daemon answers now.
    fn daemon_state(&self) -> Option<(String, String)> {
        self.daemon_version().map(|v| (v, String::new()))
    }
}

/// How the daemon of this installation is kept running.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Keeper {
    /// The systemd user unit from `install.sh`.
    Systemd {
        /// Unit file.
        unit: PathBuf,
        /// It was running.
        active: bool,
    },
    /// The window's LaunchAgent (macOS).
    LaunchAgent {
        /// Label.
        label: String,
        /// The plist.
        plist: PathBuf,
    },
    /// Started by hand or by the Linux window: the installer does not know how to start it again.
    Manual {
        /// PID.
        pid: u32,
    },
    /// A daemon runs, but from another installation: not touched.
    Elsewhere {
        /// PID.
        pid: u32,
        /// Its executable.
        exe: Option<PathBuf>,
    },
    /// No daemon runs.
    NotRunning,
    /// An automatic install (D-103, R2): the daemon that started this installer keeps running while the files are
    /// swapped, then replaces itself with the new binary (`execve`, the same PID). After a failure the old version is
    /// started again the way `base` keeps it, or with the daemon's own arguments when it was started by hand.
    Handover {
        /// The daemon's PID (the same before and after its `exec`).
        pid: u32,
        /// How the daemon is kept running otherwise (systemd, the LaunchAgent, by hand).
        base: Box<Keeper>,
        /// The daemon's executable (the installation's `antennad`).
        exe: PathBuf,
        /// Its arguments (after the program name), to start it again by hand.
        #[serde(default)]
        args: Vec<String>,
        /// Its working folder (relative arguments, like a hand-started `--data-dir data`).
        #[serde(default)]
        cwd: Option<PathBuf>,
    },
}

impl Keeper {
    /// For JSON: `systemd`, `launch_agent`, `manual`, `elsewhere`, `none`, `handover`.
    pub fn how(&self) -> &'static str {
        match self {
            Keeper::Systemd { .. } => "systemd",
            Keeper::LaunchAgent { .. } => "launch_agent",
            Keeper::Manual { .. } => "manual",
            Keeper::Elsewhere { .. } => "elsewhere",
            Keeper::NotRunning => "none",
            Keeper::Handover { .. } => "handover",
        }
    }
}

/// The daemon side of an automatic install (D-103): told when the files are in place, and what came up.
pub trait Handoff {
    /// The new version is installed: the daemon replaces itself with it now.
    fn swapped(&self) -> Result<()>;
    /// The new daemon answers with the new version; `unlocked` says whether the keys came across.
    fn came_up(&self, unlocked: bool);
}

/// The environment the installer looks at.
#[derive(Debug, Clone)]
pub struct Env {
    /// `$HOME`.
    pub home: PathBuf,
    /// The user's uid (`launchctl … gui/<uid>`).
    pub uid: u32,
    /// `$XDG_CONFIG_HOME`, if set.
    pub xdg_config: Option<PathBuf>,
}

/// What the daemon did after the swap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaemonOutcome {
    /// It was started again and answered with the new version.
    pub restarted: bool,
    /// [`Keeper::how`].
    pub how: &'static str,
    /// What the owner has to do, if anything.
    pub note: Option<String>,
}

/// Result of an install or a rollback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    /// `install` or `rollback`.
    pub action: &'static str,
    /// Version line before.
    pub from: String,
    /// Version line after.
    pub to: String,
    /// Where the replaced version is kept.
    pub previous: Option<PathBuf>,
    /// The daemon.
    pub daemon: DaemonOutcome,
    /// macOS: whether the window was opened again (`None`: it was not running).
    pub app_relaunched: Option<bool>,
    /// The restarted daemon has its keys locked.
    pub keys_locked: bool,
}

/// What the new binaries must print for `--version`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Expect {
    /// Version.
    pub version: String,
    /// Commit.
    pub commit: String,
}

impl Expect {
    /// From a verified release.
    pub fn of(rel: &Release) -> Self {
        Self {
            version: rel.manifest.version.clone(),
            commit: rel.manifest.commit.clone(),
        }
    }

    /// From a `--version` line (`antenna 0.1.0-preview.2 (47cb9fa68c07)`).
    pub fn parse(line: &str) -> Option<Self> {
        let (_name, rest) = line.trim().split_once(' ')?;
        let (v, c) = rest.split_once(" (")?;
        Some(Self {
            version: v.to_string(),
            commit: c.strip_suffix(')')?.to_string(),
        })
    }

    /// The line `name` prints.
    pub fn line(&self, name: &str) -> String {
        format!("{name} {} ({})", self.version, self.commit)
    }
}

/// Debug builds only: fail at a named point (`ANTENNA_UPDATE_FAIL_AT=<point>[:abort]`), to test that an interrupted
/// update leaves the old version working. `abort` exits the process on the spot, like a crash.
pub type FailAt = Option<(String, bool)>;

/// Swaps two directory entries atomically. Falls back to three renames where the file system cannot exchange (the
/// journal covers the gap).
#[cfg(unix)]
pub fn exchange(a: &Path, b: &Path) -> Result<()> {
    use rustix::fs::{CWD, RenameFlags, renameat_with};
    match renameat_with(CWD, a, CWD, b, RenameFlags::EXCHANGE) {
        Ok(()) => Ok(()),
        Err(e)
            if e == rustix::io::Errno::INVAL
                || e == rustix::io::Errno::NOTSUP
                || e == rustix::io::Errno::NOSYS =>
        {
            let mut tmp = b.as_os_str().to_owned();
            tmp.push(".swap");
            let tmp = PathBuf::from(tmp);
            fs::rename(b, &tmp).map_err(|e| Error::io(b.display(), e))?;
            fs::rename(a, b).map_err(|e| Error::io(a.display(), e))?;
            fs::rename(&tmp, a).map_err(|e| Error::io(tmp.display(), e))
        }
        Err(e) => Err(Error::io(
            format!("swap {} and {}", a.display(), b.display()),
            e,
        )),
    }
}

/// Windows: refused, nothing is moved. The swap there (renames under the journal, a running `.exe` cannot be replaced)
/// is the Windows installer's (D-134, WP-29, phase W4).
#[cfg(windows)]
pub fn exchange(a: &Path, b: &Path) -> Result<()> {
    Err(Error::new(
        code::UNSUPPORTED_INSTALL,
        format!(
            "swap {} and {}: antenna update cannot replace files on Windows yet",
            a.display(),
            b.display()
        ),
    ))
}

/// Makes the staging folder private (0700) and takes its lock (`flock` on a 0600 file); another update holding it is
/// [`code::UPDATE_IN_PROGRESS`].
#[cfg(unix)]
fn lock_stage(dir: &Path) -> Result<fs::File> {
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
        .map_err(|e| Error::io(dir.display(), e))?;
    let lock_path = dir.join("lock");
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(&lock_path)
        .map_err(|e| Error::io(lock_path.display(), e))?;
    if rustix::fs::flock(&lock, rustix::fs::FlockOperation::NonBlockingLockExclusive).is_err() {
        return Err(Error::new(
            code::UPDATE_IN_PROGRESS,
            format!("another antenna update is running ({})", dir.display()),
        ));
    }
    Ok(lock)
}

/// Windows: refused. The staging folder's DACL and its lock are the Windows installer's (D-134, WP-4, WP-29).
#[cfg(windows)]
fn lock_stage(dir: &Path) -> Result<fs::File> {
    Err(Error::new(
        code::UNSUPPORTED_INSTALL,
        format!(
            "{}: antenna update cannot install on Windows yet",
            dir.display()
        ),
    ))
}

/// `path` with `suffix` appended (`antennad` → `antennad.previous`).
pub fn with_suffix(p: &Path, suffix: &str) -> PathBuf {
    let mut s = p.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

fn same_file(a: &Path, b: &Path) -> bool {
    let strip = |p: &Path| -> PathBuf {
        // A daemon whose binary was swapped away still reports the path its inode has now.
        let s = p.to_string_lossy();
        let s = s.strip_suffix(" (deleted)").unwrap_or(&s);
        let s = s.strip_suffix(".previous").unwrap_or(s);
        PathBuf::from(s)
    };
    let (a, b) = (strip(a), strip(b));
    if a == b {
        return true;
    }
    match (fs::canonicalize(&a), fs::canonicalize(&b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

/// The locked staging folder.
pub(crate) struct Stage {
    pub(crate) dir: PathBuf,
    _lock: fs::File,
}

impl Stage {
    pub(crate) fn finish(self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// The installer for one installation.
pub struct Installer<'a> {
    /// What is updated.
    pub target: Target,
    /// The OS.
    pub sys: &'a dyn Sys,
    /// The log.
    pub log: &'a Log,
    /// The daemon's socket.
    pub probe: &'a dyn Probe,
    /// Environment.
    pub env: Env,
    /// The daemon that authorized the update, if one answered.
    pub running: Option<RunningDaemon>,
    /// Debug builds: failure injection.
    pub fail_at: FailAt,
    /// An automatic install started by the daemon itself (D-103): the daemon replaces itself instead of being stopped
    /// and started.
    pub handoff: Option<&'a dyn Handoff>,
}

impl Installer<'_> {
    /// Fails here if asked to (debug builds).
    pub(crate) fn checkpoint(&self, name: &str) -> Result<()> {
        if let Some((at, abort)) = &self.fail_at
            && at == name
        {
            self.log.step(format!("test: failure injected at {name}"));
            if *abort {
                std::process::exit(99);
            }
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!("failure injected at {name}"),
            ));
        }
        Ok(())
    }

    fn base(&self) -> Result<PathBuf> {
        self.target.base().ok_or_else(|| {
            Error::new(
                code::UNSUPPORTED_INSTALL,
                match &self.target {
                    Target::Unsupported { reason, .. } => reason.clone(),
                    _ => "unsupported installation".into(),
                },
            )
        })
    }

    /// Locks the staging folder (creating it, 0700) and recovers an interrupted update first.
    pub(crate) fn open_stage(&self) -> Result<(Stage, Option<String>)> {
        let dir = self.base()?.join(STAGE_DIR);
        match fs::symlink_metadata(&dir) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => {}
            Ok(_) => {
                return Err(Error::new(
                    code::INSTALL_FAILED,
                    format!("{} exists and is not a folder", dir.display()),
                ));
            }
            Err(_) => {
                fs::create_dir(&dir).map_err(|e| Error::io(dir.display(), e))?;
            }
        }
        let lock = lock_stage(&dir)?;
        let recovered = self.recover_locked(&dir)?;
        // Leftovers of an earlier run (not the lock): removed.
        if let Ok(rd) = fs::read_dir(&dir) {
            for e in rd.flatten() {
                if e.file_name() != "lock" {
                    let p = e.path();
                    let _ = if p.is_dir() && !p.is_symlink() {
                        fs::remove_dir_all(&p)
                    } else {
                        fs::remove_file(&p)
                    };
                }
            }
        }
        Ok((Stage { dir, _lock: lock }, recovered))
    }

    /// If an earlier update was interrupted, restores the old version and starts the daemon again.
    fn recover_locked(&self, stage: &Path) -> Result<Option<String>> {
        let Some(j) = journal::read(stage)? else {
            return Ok(None);
        };
        self.log.step(format!(
            "an earlier {} ({} → {}, started {}) was interrupted: restoring {}",
            j.action, j.from, j.to, j.started, j.from
        ));
        for line in journal::restore(&j)? {
            self.log.step(line);
        }
        journal::remove(stage);
        let note = match self.start(&j.keeper, None) {
            Ok(_) => None,
            Err(e) => Some(e.message),
        };
        if let Some(app) = &j.relaunch {
            self.relaunch(app);
        }
        let msg = format!(
            "an interrupted {} was undone: {} is installed again{}",
            j.action,
            j.from,
            note.map(|n| format!(" ({n})")).unwrap_or_default()
        );
        self.log.step(&msg);
        Ok(Some(msg))
    }

    /// Recovers an interrupted update, if there is one (any `antenna update` call starts with this).
    pub fn recover(&self) -> Result<Option<String>> {
        let Ok(base) = self.base() else {
            return Ok(None);
        };
        if journal::read(&base.join(STAGE_DIR))
            .ok()
            .flatten()
            .is_none()
        {
            return Ok(None);
        }
        let (stage, recovered) = self.open_stage()?;
        stage.finish();
        Ok(recovered)
    }

    /// Whether a journal of an interrupted update exists (status).
    pub fn interrupted(&self) -> bool {
        self.base()
            .ok()
            .and_then(|b| journal::read(&b.join(STAGE_DIR)).ok().flatten())
            .is_some()
    }

    /// Runs a program; an error if it cannot start.
    pub(crate) fn run(
        &self,
        prog: impl AsRef<std::ffi::OsStr>,
        args: &[std::ffi::OsString],
    ) -> Result<Out> {
        let prog = prog.as_ref();
        self.sys
            .run(prog, args)
            .map_err(|e| Error::io(format!("cannot run {}", prog.to_string_lossy()), e))
    }

    /// Checks what a new binary says for `--version`.
    pub(crate) fn expect_version(&self, bin: &Path, name: &str, want: &Expect) -> Result<()> {
        let o = self.run(bin, &sys::args(["--version"]))?;
        let got = o.stdout.trim().to_string();
        if !o.ok || got != want.line(name) {
            return Err(Error::new(
                code::INSTALL_FAILED,
                format!(
                    "{} reports {:?}, the manifest says {:?}: not installed",
                    bin.display(),
                    got,
                    want.line(name)
                ),
            ));
        }
        self.log.step(format!("{} --version: {got}", bin.display()));
        Ok(())
    }

    /// The `--version` line of an installed binary, if it runs.
    pub fn version_of(&self, bin: &Path) -> Option<Expect> {
        if !bin.is_file() {
            return None;
        }
        let o = self
            .sys
            .run(bin.as_os_str(), &sys::args(["--version"]))
            .ok()?;
        o.ok.then(|| Expect::parse(&o.stdout)).flatten()
    }

    /// The daemon binary of this installation.
    pub fn daemon_path(&self) -> Option<PathBuf> {
        match &self.target {
            Target::BinDir { dir } => Some(dir.join("antennad")),
            Target::MacosApp { app } => Some(app.join("Contents/Helpers/antennad")),
            Target::Unsupported { .. } => None,
        }
    }

    /// How the daemon of this installation is kept running. In an automatic install the daemon that started the
    /// installer replaces itself ([`Keeper::Handover`]) when it is this installation's daemon.
    pub fn keeper(&self) -> Keeper {
        let base = match (self.keeper_base(), &self.running) {
            // A unit file that is not running: this daemon was started some other way.
            (Keeper::Systemd { active: false, .. }, Some(r))
                if r.exe
                    .as_deref()
                    .zip(self.daemon_path())
                    .is_some_and(|(e, o)| same_file(e, &o)) =>
            {
                Keeper::Manual { pid: r.pid }
            }
            (b, _) => b,
        };
        match (&self.handoff, &self.running, &base) {
            (
                Some(_),
                Some(r),
                Keeper::Systemd { active: true, .. }
                | Keeper::LaunchAgent { .. }
                | Keeper::Manual { .. },
            ) => Keeper::Handover {
                pid: r.pid,
                exe: self.daemon_path().unwrap_or_default(),
                args: r.args.clone(),
                cwd: r.cwd.clone(),
                base: Box::new(base),
            },
            _ => base,
        }
    }

    fn keeper_base(&self) -> Keeper {
        let Some(ours) = self.daemon_path() else {
            return Keeper::NotRunning;
        };
        if let Some(k) = match &self.target {
            Target::BinDir { .. } => self.systemd_keeper(&ours),
            Target::MacosApp { .. } => self.launch_agent_keeper(&ours),
            Target::Unsupported { .. } => None,
        } {
            return k;
        }
        match &self.running {
            Some(r) if r.exe.as_deref().is_some_and(|e| same_file(e, &ours)) => {
                Keeper::Manual { pid: r.pid }
            }
            Some(r) => Keeper::Elsewhere {
                pid: r.pid,
                exe: r.exe.clone(),
            },
            None => Keeper::NotRunning,
        }
    }

    fn systemd_keeper(&self, ours: &Path) -> Option<Keeper> {
        let cfg = self
            .env
            .xdg_config
            .clone()
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| self.env.home.join(".config"));
        let unit = cfg.join("systemd/user").join(SYSTEMD_UNIT);
        let text = fs::read_to_string(&unit).ok()?;
        let exec = text
            .lines()
            .find_map(|l| l.trim().strip_prefix("ExecStart="))?;
        let bin = exec.split_whitespace().next()?;
        if !same_file(Path::new(bin), ours) {
            return None;
        }
        let active = self
            .sys
            .run(
                "systemctl".as_ref(),
                &sys::args(["--user", "is-active", SYSTEMD_UNIT]),
            )
            .is_ok_and(|o| o.stdout.trim() == "active");
        Some(Keeper::Systemd { unit, active })
    }

    fn launch_agent_keeper(&self, ours: &Path) -> Option<Keeper> {
        let plist = self
            .env
            .home
            .join("Library/LaunchAgents")
            .join(format!("{LAUNCH_AGENT_LABEL}.plist"));
        if !plist.is_file() {
            return None;
        }
        let o = self
            .sys
            .run(
                "plutil".as_ref(),
                &sys::args([
                    "-extract".as_ref(),
                    "ProgramArguments.0".as_ref(),
                    "raw".as_ref(),
                    "-o".as_ref(),
                    "-".as_ref(),
                    plist.as_os_str(),
                ]),
            )
            .ok()?;
        (o.ok && same_file(Path::new(o.stdout.trim()), ours)).then(|| Keeper::LaunchAgent {
            label: LAUNCH_AGENT_LABEL.into(),
            plist,
        })
    }

    /// Stops the daemon for the swap. A daemon of another installation, or one started by hand on Linux, is left
    /// alone (the caller says so).
    pub(crate) fn stop(&self, k: &Keeper) -> Result<()> {
        match k {
            Keeper::Systemd { active: true, .. } => {
                self.log.step(format!(
                    "stopping the daemon: systemctl --user stop {SYSTEMD_UNIT}"
                ));
                let o = self.run("systemctl", &sys::args(["--user", "stop", SYSTEMD_UNIT]))?;
                if !o.ok {
                    return Err(Error::new(
                        code::INSTALL_FAILED,
                        format!("systemctl --user stop {SYSTEMD_UNIT}: {}", o.describe()),
                    ));
                }
            }
            Keeper::LaunchAgent { label, .. } => {
                let t = format!("gui/{}/{label}", self.env.uid);
                self.log
                    .step(format!("stopping the daemon: launchctl bootout {t}"));
                // "Not loaded" is fine: the daemon is not running then.
                let o = self.run("launchctl", &sys::args(["bootout", t.as_str()]))?;
                if !o.ok {
                    self.log
                        .step(format!("launchctl bootout: {}", o.describe()));
                }
                if let Some(r) = &self.running {
                    sys::terminate(self.sys, r.pid, Duration::from_secs(10));
                }
            }
            Keeper::Manual { pid } if matches!(self.target, Target::MacosApp { .. }) => {
                // On macOS the daemon's binary is inside the bundle being replaced.
                self.log.step(format!(
                    "stopping the daemon (pid {pid}, started outside launchd)"
                ));
                if !sys::terminate(self.sys, *pid, Duration::from_secs(10)) {
                    return Err(Error::new(
                        code::INSTALL_FAILED,
                        format!("antennad (pid {pid}) does not stop"),
                    ));
                }
            }
            Keeper::Handover { pid, .. } => self.log.step(format!(
                "the daemon (pid {pid}) keeps running while the files are swapped; then it replaces itself"
            )),
            _ => {}
        }
        Ok(())
    }

    /// Starts the daemon after the swap and waits for it to answer with `expect` (when given). Returns whether it was
    /// started by us.
    pub(crate) fn start(&self, k: &Keeper, expect: Option<&Expect>) -> Result<bool> {
        match k {
            Keeper::Handover { .. } => return self.start_handover(k, expect),
            Keeper::Systemd { .. } => {
                self.log.step(format!(
                    "starting the daemon: systemctl --user start {SYSTEMD_UNIT}"
                ));
                let o = self.run("systemctl", &sys::args(["--user", "start", SYSTEMD_UNIT]))?;
                if !o.ok {
                    return Err(Error::new(
                        code::INSTALL_FAILED,
                        format!("systemctl --user start {SYSTEMD_UNIT}: {}", o.describe()),
                    ));
                }
            }
            Keeper::LaunchAgent { label, plist } => {
                let uid = format!("gui/{}", self.env.uid);
                self.log.step(format!(
                    "starting the daemon: launchctl bootstrap {uid} {}",
                    plist.display()
                ));
                let mut o = self.run(
                    "launchctl",
                    &[
                        "bootstrap".into(),
                        uid.clone().into(),
                        plist.as_os_str().to_os_string(),
                    ],
                )?;
                if !o.ok {
                    let t = format!("{uid}/{label}");
                    self.log.step(format!(
                        "launchctl bootstrap: {}; kickstart -k {t}",
                        o.describe()
                    ));
                    o = self.run("launchctl", &sys::args(["kickstart", "-k", t.as_str()]))?;
                }
                if !o.ok {
                    return Err(Error::new(
                        code::INSTALL_FAILED,
                        format!("launchctl: {}", o.describe()),
                    ));
                }
            }
            _ => return Ok(false),
        }
        if let Some(want) = expect {
            self.wait_for_daemon(want)?;
        }
        Ok(true)
    }

    fn wait_for_daemon(&self, want: &Expect) -> Result<()> {
        let line = want.line("antennad");
        let step = Duration::from_millis(200);
        let mut waited = Duration::ZERO;
        let mut last = None;
        while waited < START_TIMEOUT {
            last = self.probe.daemon_version();
            if last.as_deref() == Some(line.as_str()) {
                self.log.step(format!("the daemon answers: {line}"));
                return Ok(());
            }
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

    /// Opens the app again (macOS).
    pub(crate) fn relaunch(&self, app: &Path) -> bool {
        self.log.step(format!("opening {}", app.display()));
        match self.run("open", &sys::args([app.as_os_str()])) {
            Ok(o) if o.ok => true,
            Ok(o) => {
                self.log.step(format!("open: {}", o.describe()));
                false
            }
            Err(e) => {
                self.log.step(e.message);
                false
            }
        }
    }

    /// The plan, as lines for the owner.
    pub fn plan_install(&self, rel: &Release) -> Vec<String> {
        match &self.target {
            Target::MacosApp { app } => self.plan_app(app, rel),
            Target::BinDir { dir } => self.plan_bindir(dir, rel),
            Target::Unsupported { reason, .. } => vec![format!("cannot install: {reason}")],
        }
    }

    /// Installs a verified release from the verified asset.
    pub fn install(
        &self,
        rel: &Release,
        asset: &crate::manifest::Asset,
        asset_path: &Path,
    ) -> Result<Outcome> {
        match &self.target {
            Target::MacosApp { app } => self.install_app(app, rel, asset, asset_path),
            Target::BinDir { dir } => self.install_bindir(dir, rel, asset, asset_path),
            Target::Unsupported { reason, .. } => {
                Err(Error::new(code::UNSUPPORTED_INSTALL, reason.clone()))
            }
        }
    }

    /// Where the previous version is kept and what it reports.
    pub fn previous(&self) -> Option<(PathBuf, Expect)> {
        match &self.target {
            Target::MacosApp { app } => {
                let p = with_suffix(app, ".previous");
                let v = self.version_of(&p.join("Contents/Helpers/antenna"))?;
                Some((p, v))
            }
            Target::BinDir { dir } => {
                let a = self.version_of(&dir.join("antenna.previous"))?;
                let d = self.version_of(&dir.join("antennad.previous"))?;
                (a == d).then(|| (dir.clone(), a))
            }
            Target::Unsupported { .. } => None,
        }
    }

    /// The plan of a rollback.
    pub fn plan_rollback(&self) -> Result<(Expect, Vec<String>)> {
        let (p, v) = self.previous().ok_or_else(|| {
            Error::new(
                code::ROLLBACK_UNAVAILABLE,
                "there is no previous version to roll back to (it is kept after an update)",
            )
        })?;
        let k = self.keeper();
        let mut steps = Vec::new();
        match &self.target {
            Target::MacosApp { app } => {
                if !self.app_processes(app).is_empty() {
                    steps.push("close the Antenna window".into());
                }
                steps.push(self.stop_line(&k));
                steps.push(format!("swap {} and {}", app.display(), p.display()));
            }
            _ => {
                steps.push(self.stop_line(&k));
                steps.push(format!(
                    "swap antenna and antennad in {} with their .previous copies",
                    p.display()
                ));
            }
        }
        steps.push(format!(
            "start the daemon again and check that it is {}",
            v.line("antennad")
        ));
        Ok((v, steps.into_iter().filter(|s| !s.is_empty()).collect()))
    }

    pub(crate) fn stop_line(&self, k: &Keeper) -> String {
        match k {
            Keeper::Systemd { active: true, .. } => {
                format!("stop the daemon (systemctl --user stop {SYSTEMD_UNIT})")
            }
            Keeper::Systemd { .. } => String::new(),
            Keeper::LaunchAgent { .. } => "stop the daemon (launchctl bootout)".into(),
            Keeper::Manual { pid } if matches!(self.target, Target::MacosApp { .. }) => {
                format!("stop the daemon (pid {pid})")
            }
            Keeper::Manual { pid } => format!(
                "leave the running daemon (pid {pid}) alone: it was started by hand, restart it yourself afterwards"
            ),
            Keeper::Elsewhere { pid, .. } => {
                format!("leave the daemon (pid {pid}) alone: it belongs to another installation")
            }
            Keeper::Handover { pid, .. } => format!(
                "keep the daemon (pid {pid}) running; after the swap it replaces itself with the new version (the same \
                 PID) and hands its keys over"
            ),
            // Before the owner authorized (a dry run) the installer does not know whose daemon answers.
            Keeper::NotRunning if self.probe.daemon_version().is_some() => {
                "a daemon is running: if it was started by hand it is not stopped, restart it yourself afterwards".into()
            }
            Keeper::NotRunning => String::new(),
        }
    }

    /// Rolls back to the `.previous` version.
    pub fn rollback(&self) -> Result<Outcome> {
        match &self.target {
            Target::MacosApp { app } => self.rollback_app(app),
            Target::BinDir { dir } => self.rollback_bindir(dir),
            Target::Unsupported { reason, .. } => {
                Err(Error::new(code::UNSUPPORTED_INSTALL, reason.clone()))
            }
        }
    }

    /// After a failure past the point of no return: the old version back, the daemon started again.
    pub(crate) fn undo(&self, j: &journal::Journal, stage: &Path, why: &Error) -> Error {
        self.log
            .step(format!("failed: {}; restoring {}", why.message, j.from));
        let restored = journal::restore(j);
        let msg = match restored {
            Ok(lines) => {
                for l in lines {
                    self.log.step(l);
                }
                journal::remove(stage);
                let started = self.start(&j.keeper, None);
                if let Some(app) = &j.relaunch {
                    self.relaunch(app);
                }
                match started {
                    Ok(_) => format!("{}; the old version ({}) was restored", why.message, j.from),
                    Err(e) => format!(
                        "{}; the old version ({}) was restored, but its daemon did not start: {}",
                        why.message, j.from, e.message
                    ),
                }
            }
            Err(e) => format!(
                "{}; restoring the old version also failed: {} (the journal is kept: run antenna update again to retry)",
                why.message, e.message
            ),
        };
        self.log.step(&msg);
        Error::new(code::INSTALL_FAILED, msg)
    }

    /// The outcome for the daemon after the swap.
    pub(crate) fn daemon_outcome(
        &self,
        k: &Keeper,
        restarted: bool,
        app_relaunch: bool,
    ) -> DaemonOutcome {
        let note = match k {
            Keeper::Manual { pid } if matches!(self.target, Target::BinDir { .. }) => {
                Some(format!(
                    "antennad (pid {pid}) was started by hand and still runs the old version: stop it and start antennad \
                 again"
                ))
            }
            Keeper::Manual { .. } | Keeper::NotRunning if app_relaunch => None,
            Keeper::Manual { .. } => Some("open Antenna to start the daemon".into()),
            Keeper::Elsewhere { pid, exe } => Some(format!(
                "the running daemon (pid {pid}, {}) belongs to another installation and was not touched",
                exe.as_deref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default()
            )),
            _ => None,
        };
        DaemonOutcome {
            restarted,
            how: k.how(),
            note,
        }
    }
}

// The flows run shell-script binaries, `tar` and real swaps: unix-only until the Windows installer (WP-29).
#[cfg(all(test, unix))]
pub(crate) mod testsys;

#[cfg(all(test, unix))]
mod flow_tests;

#[cfg(all(test, unix))]
mod handover_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_lines() {
        let e = Expect::parse("antenna 0.1.0-preview.2 (47cb9fa68c07)\n").unwrap();
        assert_eq!(e.version, "0.1.0-preview.2");
        assert_eq!(e.commit, "47cb9fa68c07");
        assert_eq!(
            e.line("antennad"),
            "antennad 0.1.0-preview.2 (47cb9fa68c07)"
        );
        assert!(Expect::parse("antenna").is_none());
        assert!(Expect::parse("antenna 1.0.0").is_none());
    }

    #[test]
    fn log_paths() {
        let h = Path::new("/home/a");
        assert_eq!(
            default_log_path(h, "macos", None),
            Path::new("/home/a/Library/Logs/Antenna/update.log")
        );
        assert_eq!(
            default_log_path(h, "linux", None),
            Path::new("/home/a/.local/state/antenna/update.log")
        );
        // An absolute path (on Windows that takes a drive).
        let s = Path::new(if cfg!(windows) { "C:/s" } else { "/s" });
        assert_eq!(
            default_log_path(h, "linux", Some(s)),
            s.join("antenna/update.log")
        );
        assert_eq!(
            default_log_path(h, "linux", Some(Path::new("rel"))),
            Path::new("/home/a/.local/state/antenna/update.log")
        );
    }

    #[test]
    fn log_file_is_private() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("logs/update.log");
        let l = Log::new(Some(p.clone()), false);
        l.step("one");
        l.step("two");
        let text = fs::read_to_string(&p).unwrap();
        assert!(text.lines().count() == 2 && text.contains("Z one"));
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(&p).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(l.lines(), vec!["one", "two"]);
    }

    // The atomic exchange is renameat2/renamex_np; Windows refuses (`exchange_is_refused_on_windows`).
    #[cfg(unix)]
    #[test]
    fn exchange_swaps_files_and_folders() {
        let d = tempfile::tempdir().unwrap();
        let (a, b) = (d.path().join("a"), d.path().join("b"));
        fs::write(&a, b"A").unwrap();
        fs::create_dir(&b).unwrap();
        exchange(&a, &b).unwrap();
        assert!(a.is_dir() && fs::read(&b).unwrap() == b"A");
        assert!(exchange(&a, &d.path().join("missing")).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn exchange_is_refused_on_windows() {
        let d = tempfile::tempdir().unwrap();
        let (a, b) = (d.path().join("a"), d.path().join("b"));
        fs::write(&a, b"A").unwrap();
        fs::write(&b, b"B").unwrap();
        assert_eq!(
            exchange(&a, &b).unwrap_err().code,
            code::UNSUPPORTED_INSTALL
        );
        assert!(fs::read(&a).unwrap() == b"A" && fs::read(&b).unwrap() == b"B");
        assert_eq!(
            lock_stage(d.path()).unwrap_err().code,
            code::UNSUPPORTED_INSTALL
        );
    }

    #[test]
    fn same_file_sees_through_swaps() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("antennad");
        fs::write(&a, b"x").unwrap();
        assert!(same_file(&a, &a));
        assert!(same_file(&with_suffix(&a, ".previous"), &a));
        assert!(same_file(
            Path::new(&format!("{} (deleted)", a.display())),
            &a
        ));
        assert!(!same_file(&d.path().join("other"), &a));
    }
}
