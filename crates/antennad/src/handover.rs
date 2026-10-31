// SPDX-License-Identifier: AGPL-3.0-only
//! The daemon replaces itself after an automatic update (D-103, R2; `docs/UPDATES.md` §8).
//!
//! The old image has shut down as on SIGTERM; it writes the root key and the installer's PID into a pipe, marks only
//! the read end inheritable and `execve`s the new `antennad` at the same path (the same PID, so launchd and systemd
//! keep tracking it), passing the descriptor's number in `--handover-fd`. The key is wiped from the old image's memory
//! before the `exec` and never touches the disk. The new image makes itself non-dumpable first (`harden` in `main`),
//! takes the pipe (`antenna_sys::fds::take_inherited_pipe`: refused unless it is a pipe), reads exactly the expected
//! bytes, closes it, and opens the database with the key: a wrong key does not open it, and the daemon starts locked,
//! as after any restart.
//!
//! Windows has no `execve`: the handover there is a new process with an inherited pipe, which needs its own review
//! (D-134, WP-29); until then the daemon starts locked and never replaces itself.

#[cfg(unix)]
use std::{
    io::{Read, Write},
    os::{fd::AsRawFd, unix::process::CommandExt},
    time::{Duration, Instant},
};
use std::{path::PathBuf, process::ExitCode};

#[cfg(unix)]
use antenna_core::autoupdate::HANDOVER_LEN;
use antenna_core::autoupdate::Handover;

/// This process, as read at its start: what to `exec` again and with which arguments.
#[derive(Debug, Clone)]
pub(crate) struct Me {
    /// The canonical executable (before an update moves anything).
    pub(crate) exe: Option<PathBuf>,
    /// The arguments after the program name, without a handover's own `--handover-fd`.
    pub(crate) args: Vec<String>,
    /// The working folder (relative arguments like `--data-dir data` stay valid).
    pub(crate) cwd: Option<PathBuf>,
}

impl Me {
    pub(crate) fn now() -> Self {
        Self {
            exe: std::env::current_exe().and_then(std::fs::canonicalize).ok(),
            args: without_handover(std::env::args().skip(1)),
            cwd: std::env::current_dir().ok(),
        }
    }
}

/// The arguments without a handover's own `--handover-fd <n>`: a later start (by hand after a failure, or the next
/// update) must not name a descriptor that no longer exists.
fn without_handover(args: impl Iterator<Item = String>) -> Vec<String> {
    let mut out = Vec::new();
    let mut skip = false;
    for a in args {
        if skip {
            skip = false;
            continue;
        }
        if a == "--handover-fd" {
            skip = true;
            continue;
        }
        if a.starts_with("--handover-fd=") {
            continue;
        }
        out.push(a);
    }
    out
}

/// The version this daemon reports and compares releases against. Debug builds only: `ANTENNA_UPDATE_CURRENT_VERSION`
/// pretends to be another one (the update tests, like the CLI's).
pub(crate) fn version() -> String {
    #[cfg(debug_assertions)]
    if let Ok(v) = std::env::var("ANTENNA_UPDATE_CURRENT_VERSION")
        && !v.is_empty()
    {
        return v;
    }
    env!("CARGO_PKG_VERSION").to_string()
}

/// Reads what the old image left in the inherited pipe. Called right after `harden`, before the runtime and before the
/// process opens anything of its own.
#[cfg(unix)]
pub(crate) fn take(fd: i32) -> std::io::Result<Handover> {
    let pipe = antenna_sys::fds::take_inherited_pipe(fd)?;
    // The old image closed the write end before its `exec`, so the bytes are there and the end follows; a descriptor
    // somebody else passed must not hang the start: non-blocking, at most 5 s.
    rustix::io::ioctl_fionbio(&pipe, true).map_err(std::io::Error::from)?;
    let mut f = std::fs::File::from(pipe);
    let mut buf = zeroize::Zeroizing::new([0u8; HANDOVER_LEN + 1]);
    let mut n = 0;
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        match f.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => {
                n += k;
                if n > HANDOVER_LEN {
                    return Err(std::io::Error::other("the handover pipe holds too much"));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < until => {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    drop(f);
    Handover::from_bytes(&buf[..n])
        .ok_or_else(|| std::io::Error::other("the handover pipe does not hold a handover"))
}

/// Windows: refused (WP-29): the daemon starts locked.
#[cfg(windows)]
pub(crate) fn take(_fd: i32) -> std::io::Result<Handover> {
    Err(not_on_windows())
}

/// The installer is still this process's child after the `exec` (it waits for the new version): reap it when it ends.
#[cfg(unix)]
pub(crate) fn reap(pid: u32) {
    let Some(p) = i32::try_from(pid)
        .ok()
        .and_then(rustix::process::Pid::from_raw)
    else {
        return;
    };
    std::thread::spawn(move || {
        let _ = rustix::process::waitpid(Some(p), rustix::process::WaitOptions::empty());
    });
}

/// Windows: no handover is ever taken there ([`take`] refuses), so there is no installer child to reap.
#[cfg(windows)]
pub(crate) fn reap(_pid: u32) {}

/// Replaces this process with the new binary at the same path, handing the key over. Returns only if the `exec`
/// failed: the process then exits, and the installer, seeing it gone, puts the old version back.
#[cfg(unix)]
pub(crate) fn exec(me: &Me, h: Handover) -> ExitCode {
    let Some(exe) = me.exe.clone() else {
        eprintln!("antennad: automatic update: the daemon's own path is unknown; exiting");
        return ExitCode::FAILURE;
    };
    let mut cmd = std::process::Command::new(&exe);
    cmd.args(&me.args);
    if let Some(d) = &me.cwd {
        cmd.current_dir(d);
    }
    // Debug builds only: the negative control of the handover tests (the new daemon must then come up locked).
    #[cfg(debug_assertions)]
    let drop_key = std::env::var("ANTENNA_HANDOVER_TEST_DROP_KEY").as_deref() == Ok("1");
    #[cfg(not(debug_assertions))]
    let drop_key = false;
    // Both ends are CLOEXEC; only the read end is made inheritable, just before the `exec`.
    let mut keep = None;
    if !drop_key {
        match handover_pipe(&h) {
            Ok(r) => {
                cmd.arg("--handover-fd").arg(r.as_raw_fd().to_string());
                keep = Some(r);
            }
            Err(e) => eprintln!(
                "antennad: automatic update: no handover pipe ({e}); the new version starts locked"
            ),
        }
    }
    // The key leaves this image's memory before the `exec` (which runs no destructors).
    drop(h);
    let e = cmd.exec();
    drop(keep);
    eprintln!(
        "antennad: automatic update: cannot execute {}: {e}",
        exe.display()
    );
    ExitCode::FAILURE
}

/// Windows: refused (WP-29); the key is wiped with `h` and the process exits. (Automatic installs answer
/// `unsupported_install` there, so the daemon never asks for this.)
#[cfg(windows)]
pub(crate) fn exec(_me: &Me, h: Handover) -> ExitCode {
    drop(h);
    eprintln!("antennad: automatic update: {}; exiting", not_on_windows());
    ExitCode::FAILURE
}

#[cfg(windows)]
fn not_on_windows() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "the handover of an automatic update is not available on Windows yet",
    )
}

#[cfg(unix)]
fn handover_pipe(h: &Handover) -> std::io::Result<std::io::PipeReader> {
    let (r, mut w) = std::io::pipe()?;
    {
        let bytes = h.to_bytes();
        w.write_all(&bytes[..])?;
    }
    drop(w);
    rustix::io::fcntl_setfd(&r, rustix::io::FdFlags::empty()).map_err(std::io::Error::from)?;
    Ok(r)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_handover_descriptor_is_not_passed_on() {
        let a = |v: &[&str]| super::without_handover(v.iter().map(|s| s.to_string()));
        assert_eq!(
            a(&["--data-dir", "data", "--handover-fd", "5", "--relay", "n0"]),
            ["--data-dir", "data", "--relay", "n0"]
        );
        assert_eq!(
            a(&["--handover-fd=7", "--links-dir", "l"]),
            ["--links-dir", "l"]
        );
        assert_eq!(a(&["--data-dir", "d"]), ["--data-dir", "d"]);
    }
}
