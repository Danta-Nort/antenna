// SPDX-License-Identifier: AGPL-3.0-only
//! Inherited descriptors (D-P-8, D-F-24, D-61): an `antennad` started by a parent that left open fds without CLOEXEC
//! (the Flutter desktop app, `flutter_tester`: fd 9; a script; a CI runner) would pass them on to each of its
//! children, including the antenna-files file check worker, and the worker, lacking isolation, rightly refuses to run
//! (`extra_fds > 0`).
//!
//! - [`cloexec_inherited_fds`] is for the daemon's `main`: it marks all of the process's descriptors > 2 CLOEXEC (the
//!   process itself keeps them, since one may be somebody's socket, but they no longer reach child processes).
//! - [`no_inherited_fds_in_child`] is for the place where the worker is started: the same, but **only in the child**,
//!   between `fork` and `exec`. It protects anyone who starts the worker (tests, embedding `antenna-files`) and does
//!   not change the caller's descriptors.

use std::io;

/// How the descriptors were marked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloexecMethod {
    /// Linux ≥ 5.11: a single system call `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)`.
    CloseRange,
    /// Walking the open descriptors (`/proc/self/fd` on Linux, `/dev/fd` on macOS) and `fcntl(F_SETFD)` on each.
    Listed,
}

/// Marks all open descriptors numbered > 2 CLOEXEC (stdin, stdout and stderr stay as they are).
///
/// Call it first thing in `main` (before the process's own code opens something without CLOEXEC that it wants to pass
/// to a child; `antennad` has no such code: std and tokio open everything with CLOEXEC).
pub fn cloexec_inherited_fds() -> io::Result<CloexecMethod> {
    #[cfg(target_os = "linux")]
    if close_range_cloexec().is_ok() {
        return Ok(CloexecMethod::CloseRange);
    }
    // Fallback: an old kernel (ENOSYS), a container's seccomp filter (EPERM), macOS.
    cloexec_listed()
}

/// The child process `cmd` gets only its own stdin, stdout and stderr: between `fork` and `exec` all descriptors > 2
/// are marked CLOEXEC, only in the child; nothing changes in the calling process.
///
/// After `fork` the child may only make async-signal-safe calls: on Linux a single `close_range(3, ~0,
/// CLOSE_RANGE_CLOEXEC)`; if the kernel does not provide it (older than 5.11, a container's seccomp), and on macOS,
/// `fcntl(F_SETFD)` on every number up to the descriptor limit computed beforehand in the parent ([`fd_scan_limit`]).
/// The pipe through which std reports an `exec` error to the parent is itself CLOEXEC, so launch errors are still
/// visible.
pub fn no_inherited_fds_in_child(cmd: &mut std::process::Command) {
    child_hook(cmd, true);
}

#[allow(
    unsafe_code,
    reason = "a pre_exec hook: runs in the child between fork and exec (D-61)"
)]
fn child_hook(cmd: &mut std::process::Command, try_close_range: bool) {
    use std::os::unix::process::CommandExt;
    let limit = fd_scan_limit();
    // SAFETY: the closure runs in the child between `fork` and `exec`. It makes only async-signal-safe system calls
    // (`close_range`, `fcntl`) on integers, with no memory allocation, no locks and no access to the parent's state;
    // `limit` is a copy of a number computed in the parent. Errors are an `io::Error` from `errno`, without allocation.
    unsafe {
        cmd.pre_exec(move || cloexec_from_3(limit, try_close_range));
    }
}

/// Up to which number to scan descriptors in the fallback: the soft `RLIMIT_NOFILE` limit (a descriptor above it cannot
/// be opened), at most 65,536, since the scan runs on every worker launch.
#[allow(unsafe_code, reason = "FFI: getrlimit")]
pub fn fd_scan_limit() -> i32 {
    let mut r = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `getrlimit` writes only into the passed struct, which lives until the end of the call.
    let ok = unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut r) } == 0;
    if !ok || r.rlim_cur == libc::RLIM_INFINITY {
        return 65_536;
    }
    r.rlim_cur.min(65_536) as i32
}

/// Body of `pre_exec`: all descriptors 3… become CLOEXEC (async-signal-safe).
fn cloexec_from_3(limit: i32, try_close_range: bool) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    if try_close_range && close_range_cloexec().is_ok() {
        return Ok(());
    }
    #[cfg(not(target_os = "linux"))]
    let _ = try_close_range;
    for fd in 3..limit {
        set_cloexec(fd)?;
    }
    Ok(())
}

fn cloexec_listed() -> io::Result<CloexecMethod> {
    for fd in open_fds()? {
        if fd > 2 {
            set_cloexec(fd)?;
        }
    }
    Ok(CloexecMethod::Listed)
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code, reason = "FFI: the close_range syscall")]
fn close_range_cloexec() -> io::Result<()> {
    // SAFETY: `close_range` with `CLOSE_RANGE_CLOEXEC` closes nothing and does not touch process memory; it only sets
    // the flag on descriptors 3…~0; the arguments are integers. Through `syscall` rather than `libc::close_range`: that
    // wrapper exists only in glibc ≥ 2.34.
    let r = unsafe {
        libc::syscall(
            libc::SYS_close_range,
            3 as libc::c_uint,
            libc::c_uint::MAX,
            libc::CLOSE_RANGE_CLOEXEC,
        )
    };
    if r == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Numbers of the process's open descriptors (from the OS descriptor directory; the directory itself, open while it is
/// read, may also end up in the list: it is already CLOEXEC and closed by the end, so `F_SETFD` on it returns `EBADF`,
/// which is not an error).
fn open_fds() -> io::Result<Vec<i32>> {
    let dir = if cfg!(target_os = "linux") {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir)? {
        if let Some(n) = e?.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) {
            out.push(n);
        }
    }
    Ok(out)
}

#[allow(unsafe_code, reason = "FFI: fcntl")]
fn set_cloexec(fd: i32) -> io::Result<()> {
    // SAFETY: `fcntl(F_GETFD/F_SETFD)` on an integer does not touch memory and is async-signal-safe; the descriptor may
    // already be gone (`EBADF`). The flag is only added: at the start of `main` (no one in the process owns the
    // descriptors yet) or in the child between `fork` and `exec` (where they would all be closed by `exec` anyway,
    // except those that must not reach the program).
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        let e = io::Error::last_os_error();
        return if e.raw_os_error() == Some(libc::EBADF) {
            Ok(())
        } else {
            Err(e)
        };
    }
    if flags & libc::FD_CLOEXEC != 0 {
        return Ok(());
    }
    // SAFETY: as above.
    let r = unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) };
    if r < 0 {
        let e = io::Error::last_os_error();
        if e.raw_os_error() != Some(libc::EBADF) {
            return Err(e);
        }
    }
    Ok(())
}

/// Takes ownership of a pipe this process inherited across `execve` under a number it was told on its command line
/// (the handover of an automatic update, D-103: the old `antennad` leaves exactly one read end open across the `exec`).
///
/// Refused, without taking anything: a number below 3, a descriptor that is not open, one that is not a pipe, and any
/// second call in the same process (an inherited descriptor has one owner). The descriptor comes back CLOEXEC.
pub fn take_inherited_pipe(fd: i32) -> io::Result<std::os::fd::OwnedFd> {
    use std::sync::atomic::{AtomicBool, Ordering};
    static TAKEN: AtomicBool = AtomicBool::new(false);
    if fd < 3 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not an inherited descriptor (0, 1 and 2 are stdio)",
        ));
    }
    if TAKEN.swap(true, Ordering::SeqCst) {
        return Err(io::Error::other("the inherited pipe was already taken"));
    }
    if !is_open_fifo(fd)? {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the inherited descriptor is not a pipe",
        ));
    }
    set_cloexec(fd)?;
    Ok(owned(fd))
}

#[allow(unsafe_code, reason = "FFI: fstat on an inherited descriptor")]
fn is_open_fifo(fd: i32) -> io::Result<bool> {
    // SAFETY: `fstat` writes only into the zeroed struct that lives until the end of the call; the argument is an
    // integer, and a closed descriptor is `EBADF`, not undefined behavior.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: as above.
    if unsafe { libc::fstat(fd, &mut st) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(st.st_mode & libc::S_IFMT == libc::S_IFIFO)
}

#[allow(
    unsafe_code,
    reason = "taking ownership of an inherited descriptor (OwnedFd::from_raw_fd)"
)]
fn owned(fd: i32) -> std::os::fd::OwnedFd {
    use std::os::fd::FromRawFd;
    // SAFETY: `fd` is open (checked by `fstat` just before) and nothing in this process owns it: it was inherited
    // across `execve` and is named only on the command line, which `take_inherited_pipe` reads once (the `TAKEN` flag),
    // first thing in `main`, before the process opens anything of its own.
    unsafe { std::os::fd::OwnedFd::from_raw_fd(fd) }
}

#[cfg(test)]
mod tests {
    use std::process::{Command, Stdio};

    use super::*;

    /// The handover pipe (D-103): stdio and a regular file are refused, a pipe is taken once and comes back CLOEXEC.
    #[test]
    fn an_inherited_pipe_is_taken_once_and_nothing_else() {
        use std::io::{Read, Write};
        use std::os::fd::{AsRawFd, IntoRawFd};
        assert!(take_inherited_pipe(0).is_err());
        assert!(take_inherited_pipe(2).is_err());
        let file = std::fs::File::open("/dev/null").unwrap();
        assert!(is_open_fifo(file.as_raw_fd()).is_ok_and(|p| !p));
        let (r, mut w) = std::io::pipe().unwrap();
        w.write_all(b"key").unwrap();
        drop(w);
        let raw = r.into_raw_fd();
        let fd = take_inherited_pipe(raw).unwrap();
        let mut f = std::fs::File::from(fd);
        let mut s = String::new();
        f.read_to_string(&mut s).unwrap();
        assert_eq!(s, "key");
        // A second take in the same process is refused even for another pipe.
        let (r2, _w2) = std::io::pipe().unwrap();
        assert!(take_inherited_pipe(r2.as_raw_fd()).is_err());
    }

    /// A child of this same test (`ANTENNA_SYS_FDS_CHILD` = `auto` | `listed`) with an inherited fd 9: before the call
    /// fd 9 is visible in `sh`, after it is not. The test runner itself is left alone.
    fn child(mode: &str) -> ! {
        let probe_with = |isolate: bool| {
            let mut c = Command::new("/bin/sh");
            c.args(["-c", "[ -e /dev/fd/9 ] && echo open || echo closed"]);
            if isolate {
                no_inherited_fds_in_child(&mut c);
            }
            let o = c.output().unwrap();
            String::from_utf8_lossy(&o.stdout).trim().to_string()
        };
        let probe = || probe_with(false);
        if mode == "child-only" || mode == "child-only-loop" {
            // Child only: the child does not have fd 9, while this process keeps it (the next ordinary child sees it);
            // an `exec` error still reaches the parent. `-loop` is the fallback (`fcntl` scan, as on macOS).
            let isolated = if mode == "child-only-loop" {
                let mut c = Command::new("/bin/sh");
                c.args(["-c", "[ -e /dev/fd/9 ] && echo open || echo closed"]);
                child_hook(&mut c, false);
                String::from_utf8_lossy(&c.output().unwrap().stdout)
                    .trim()
                    .to_string()
            } else {
                probe_with(true)
            };
            let plain = probe();
            let mut bad = Command::new("/nonexistent/antenna-sys-test");
            no_inherited_fds_in_child(&mut bad);
            let exec_err = bad.output().is_err();
            println!(
                "RESULT isolated={isolated} plain_after={plain} exec_error_reported={exec_err}"
            );
            std::process::exit(0);
        }
        let before = probe();
        let method = if mode == "listed" {
            cloexec_listed()
        } else {
            cloexec_inherited_fds()
        }
        .unwrap();
        let after = probe();
        println!("RESULT before={before} after={after} method={method:?}");
        std::process::exit(0);
    }

    fn run_child(test: &str, mode: &str) -> String {
        let me = std::env::current_exe().unwrap();
        let out = Command::new("/bin/sh")
            .arg("-c")
            .arg(r#"exec 9<"$0"; exec "$0" --exact "$1" --nocapture --test-threads=1"#)
            .arg(&me)
            .arg(test)
            .env("ANTENNA_SYS_FDS_CHILD", mode)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        format!(
            "{}\n{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    }

    /// The main path (Linux: `close_range`, macOS: walking `/dev/fd`).
    #[test]
    fn inherited_descriptor_is_not_passed_on() {
        if let Some(m) = std::env::var_os("ANTENNA_SYS_FDS_CHILD") {
            child(&m.to_string_lossy());
        }
        let out = run_child("fds::tests::inherited_descriptor_is_not_passed_on", "auto");
        assert!(out.contains("RESULT before=open after=closed"), "{out}");
        #[cfg(target_os = "linux")]
        assert!(out.contains("method=CloseRange"), "{out}");
    }

    /// Where the worker is started (D-61): the child does not get fd 9, the calling process keeps it.
    #[test]
    fn child_only_mode_keeps_the_parent_untouched() {
        if let Some(m) = std::env::var_os("ANTENNA_SYS_FDS_CHILD") {
            child(&m.to_string_lossy());
        }
        let out = run_child(
            "fds::tests::child_only_mode_keeps_the_parent_untouched",
            "child-only",
        );
        assert!(
            out.contains("RESULT isolated=closed plain_after=open exec_error_reported=true"),
            "{out}"
        );
        assert!(fd_scan_limit() >= 256);
        let out = run_child(
            "fds::tests::child_only_mode_keeps_the_parent_untouched",
            "child-only-loop",
        );
        assert!(
            out.contains("RESULT isolated=closed plain_after=open exec_error_reported=true"),
            "fallback: {out}"
        );
    }

    /// The fallback (walking the descriptor list), also on Linux, where `close_range` usually works.
    #[test]
    fn listed_fallback_is_not_passed_on() {
        if let Some(m) = std::env::var_os("ANTENNA_SYS_FDS_CHILD") {
            child(&m.to_string_lossy());
        }
        let out = run_child("fds::tests::listed_fallback_is_not_passed_on", "listed");
        assert!(
            out.contains("RESULT before=open after=closed method=Listed"),
            "{out}"
        );
    }
}
