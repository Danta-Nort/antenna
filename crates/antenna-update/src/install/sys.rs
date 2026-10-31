// SPDX-License-Identifier: AGPL-3.0-only
//! The operating system as the installer sees it: running programs, signals, waiting. A trait, so that the macOS
//! installation (`hdiutil`, `ditto`, `codesign`, `launchctl`…) and the systemd one can be exercised on any machine
//! with a fake that records the calls and simulates the tools.
//!
//! On Windows only running a program and waiting work; signals, liveness, detached starts and the parent check refuse
//! or answer conservatively until the Windows installer (D-134, WP-13, WP-29).

use std::{
    ffi::{OsStr, OsString},
    io,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

/// Output of a program.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Out {
    /// Exit status 0.
    pub ok: bool,
    /// Standard output.
    pub stdout: String,
    /// Standard error.
    pub stderr: String,
}

impl Out {
    /// A short description for a log line or an error.
    pub fn describe(&self) -> String {
        let e = self.stderr.trim();
        let o = self.stdout.trim();
        let s = if e.is_empty() { o } else { e };
        s.chars().take(400).collect()
    }
}

/// Signals the installer sends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sig {
    /// SIGTERM.
    Term,
    /// SIGKILL.
    Kill,
}

/// What the installer needs from the OS.
pub trait Sys {
    /// Runs a program (no shell), waits, collects its output.
    fn run(&self, prog: &OsStr, args: &[OsString]) -> io::Result<Out>;
    /// Sends a signal to a process.
    fn kill(&self, pid: u32, sig: Sig) -> io::Result<()>;
    /// Whether a process exists.
    fn alive(&self, pid: u32) -> bool;
    /// Waits.
    fn sleep(&self, d: Duration);
    /// Starts a program in its own process group and does not wait for it (after a failed automatic update the old
    /// daemon is started again this way, D-103); stdin is `/dev/null`, stdout and stderr go where this process's stderr
    /// goes. Returns its PID.
    fn spawn_detached(
        &self,
        prog: &OsStr,
        args: &[OsString],
        cwd: Option<&Path>,
    ) -> io::Result<u32>;
    /// The executable of a running process, as the OS reports it (`None` if it cannot be read).
    fn exe_of(&self, pid: u32) -> Option<PathBuf>;
    /// Whether `pid` is this process's parent (the daemon that started an automatic install).
    fn is_parent(&self, pid: u32) -> bool;
}

/// Builds an argument list.
pub fn args<I, S>(a: I) -> Vec<OsString>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    a.into_iter().map(|s| s.as_ref().to_os_string()).collect()
}

/// The real OS.
#[derive(Debug, Clone, Copy, Default)]
pub struct RealSys;

impl Sys for RealSys {
    fn run(&self, prog: &OsStr, args: &[OsString]) -> io::Result<Out> {
        let o = Command::new(prog)
            .args(args)
            .stdin(Stdio::null())
            .output()?;
        Ok(Out {
            ok: o.status.success(),
            stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
        })
    }

    #[cfg(unix)]
    fn kill(&self, pid: u32, sig: Sig) -> io::Result<()> {
        let pid = i32::try_from(pid)
            .ok()
            .and_then(rustix::process::Pid::from_raw)
            .ok_or_else(|| io::Error::other("bad pid"))?;
        let s = match sig {
            Sig::Term => rustix::process::Signal::TERM,
            Sig::Kill => rustix::process::Signal::KILL,
        };
        rustix::process::kill_process(pid, s).map_err(io::Error::from)
    }

    /// Windows: a process is signalled through a handle opened after checking its creation time (WP-14), not ported.
    #[cfg(windows)]
    fn kill(&self, _pid: u32, _sig: Sig) -> io::Result<()> {
        Err(not_ported("signalling a process"))
    }

    #[cfg(unix)]
    fn alive(&self, pid: u32) -> bool {
        i32::try_from(pid)
            .ok()
            .and_then(rustix::process::Pid::from_raw)
            .is_some_and(|p| rustix::process::test_kill_process(p).is_ok())
    }

    /// Windows: not checked yet, so every process counts as running. Fail closed: nothing is swapped under a daemon
    /// that might still run, and [`terminate`] reports that it did not stop.
    #[cfg(windows)]
    fn alive(&self, _pid: u32) -> bool {
        true
    }

    fn sleep(&self, d: Duration) {
        std::thread::sleep(d)
    }

    #[cfg(unix)]
    fn spawn_detached(
        &self,
        prog: &OsStr,
        args: &[OsString],
        cwd: Option<&Path>,
    ) -> io::Result<u32> {
        use std::os::unix::process::CommandExt;
        let err = || -> io::Result<Stdio> {
            use std::os::fd::AsFd;
            Ok(Stdio::from(io::stderr().as_fd().try_clone_to_owned()?))
        };
        let mut c = Command::new(prog);
        c.args(args)
            .stdin(Stdio::null())
            .stdout(err()?)
            .stderr(err()?)
            .process_group(0);
        if let Some(d) = cwd {
            c.current_dir(d);
        }
        Ok(c.spawn()?.id())
    }

    /// Windows: starting the old daemon detached belongs to the Windows installer (WP-29), not ported.
    #[cfg(windows)]
    fn spawn_detached(
        &self,
        _prog: &OsStr,
        _args: &[OsString],
        _cwd: Option<&Path>,
    ) -> io::Result<u32> {
        Err(not_ported("starting a detached process"))
    }

    #[cfg(unix)]
    fn exe_of(&self, pid: u32) -> Option<PathBuf> {
        if cfg!(target_os = "linux") {
            return std::fs::read_link(format!("/proc/{pid}/exe")).ok();
        }
        let o = Command::new("ps")
            .args(["-o", "comm=", "-p", &pid.to_string()])
            .stdin(Stdio::null())
            .output()
            .ok()?;
        let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
        (o.status.success() && !s.is_empty()).then(|| PathBuf::from(s))
    }

    /// Windows: unknown until process information is ported (WP-7), so no process is taken for this installation's.
    #[cfg(windows)]
    fn exe_of(&self, _pid: u32) -> Option<PathBuf> {
        None
    }

    #[cfg(unix)]
    fn is_parent(&self, pid: u32) -> bool {
        rustix::process::getppid().is_some_and(|p| p.as_raw_nonzero().get() as u32 == pid)
    }

    /// Windows: not checked yet (WP-7), so never the parent: an automatic install is refused.
    #[cfg(windows)]
    fn is_parent(&self, _pid: u32) -> bool {
        false
    }
}

#[cfg(windows)]
fn not_ported(what: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::Unsupported,
        format!("{what} is not implemented on Windows yet"),
    )
}

/// Sends SIGTERM and waits up to `wait` for the process to exit, then SIGKILL. Returns whether it is gone.
pub fn terminate(sys: &dyn Sys, pid: u32, wait: Duration) -> bool {
    if !sys.alive(pid) {
        return true;
    }
    let _ = sys.kill(pid, Sig::Term);
    let step = Duration::from_millis(100);
    let mut waited = Duration::ZERO;
    while waited < wait {
        if !sys.alive(pid) {
            return true;
        }
        sys.sleep(step);
        waited += step;
    }
    let _ = sys.kill(pid, Sig::Kill);
    sys.sleep(step);
    !sys.alive(pid)
}
