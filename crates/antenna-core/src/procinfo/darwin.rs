// SPDX-License-Identifier: AGPL-3.0-only
//! macOS: processes through `proc_pidinfo` (the `antenna-sys` crate, where all the `unsafe` lives).

use std::path::Path;

use antenna_sys::darwin as sys;

use super::ProcStat;

/// Process information together with what is needed to check the chain.
#[derive(Debug, Clone)]
pub struct DarwinStat {
    /// Common information (`start` = `p_uniqueid`).
    pub stat: ProcStat,
    /// `p_puniqueid`: the parent's `p_uniqueid` at the time of `fork`.
    pub parent_unique_id: u64,
    /// `p_idversion`: the PID version (checked against the audit token).
    pub id_version: i32,
    /// `PROC_FLAG_*` flags of the short info.
    pub flags: u32,
    /// Effective uid.
    pub uid: u32,
}

fn euid() -> u32 {
    rustix::process::geteuid().as_raw()
}

/// Process information: `UNIQIDENTIFIERINFO` → `SHORTBSDINFO` (+ the terminal for our own uid) →
/// `UNIQIDENTIFIERINFO` again. A different `p_uniqueid` before and after means the process changed in the middle of
/// reading → `None`. The session comes from `getsid` (if it cannot be read, 0, "unknown": such a process never
/// becomes an anchor).
pub fn stat(pid: i32) -> Option<DarwinStat> {
    if pid <= 0 {
        return None;
    }
    let u1 = sys::uniq_info(pid).ok()?;
    let s = sys::short_info(pid).ok()?;
    // The kernel returns the terminal (e_tdev) only for our own uid; other processes (login, launchd) do not need
    // it.
    let tty = if s.uid == euid() {
        sys::bsd_info(pid)
            .ok()
            .and_then(|b| b.tdev)
            .map_or(0, |d| d as i32)
    } else {
        0
    };
    let u2 = sys::uniq_info(pid).ok()?;
    if u1 != u2 || s.pid != pid {
        return None;
    }
    let sid = rustix::process::Pid::from_raw(pid)
        .and_then(|p| rustix::process::getsid(Some(p)).ok())
        .map_or(0, |p| p.as_raw_nonzero().get());
    Some(DarwinStat {
        stat: ProcStat {
            pid,
            comm: s.comm,
            ppid: s.ppid,
            sid,
            tty,
            start: u1.unique_id,
        },
        parent_unique_id: u1.parent_unique_id,
        id_version: u1.id_version,
        flags: s.flags,
        uid: s.uid,
    })
}

/// The chain up to PID 1 (M-4): for every link with a parent > 1, `p_puniqueid` equals the `p_uniqueid` of the
/// parent read (otherwise the parent died and its PID is taken by another process → `None`); a link under a
/// debugger (`PROC_FLAG_TRACED`: XNU reparents a traced process to the debugger) → `None`. An orphan under launchd
/// (parent 1) is not checked: whether XNU updates `p_puniqueid` on reparenting is still to be verified (PORTABILITY
/// M-4).
pub fn ancestry(pid: i32) -> Option<Vec<ProcStat>> {
    let mut out = Vec::new();
    let mut p = pid;
    let mut expect: Option<u64> = None;
    for _ in 0..4096 {
        let d = stat(p)?;
        if d.flags & sys::PROC_FLAG_TRACED != 0 || expect.is_some_and(|e| e != d.stat.start) {
            return None;
        }
        let next = d.stat.ppid;
        expect = (next > 1).then_some(d.parent_unique_id);
        out.push(d.stat);
        if next == 0 {
            return Some(out);
        }
        p = next;
    }
    None
}

/// The socket client's chain by the audit token: the PID from the token, its `pidversion` = `p_idversion` of the
/// process read.
pub fn peer_ancestry(sock: std::os::fd::BorrowedFd<'_>) -> Option<Vec<ProcStat>> {
    let t = sys::peer_audit_token(sock).ok()?;
    let me = stat(t.pid)?;
    if me.id_version != t.pid_version {
        return None;
    }
    let chain = ancestry(t.pid)?;
    (chain.first()?.start == me.stat.start).then_some(chain)
}

/// The main executable of an app: `/…/<name>.app/Contents/MacOS/<file>`.
pub fn is_app_main_executable(path: &Path) -> bool {
    fn name(p: Option<&Path>) -> Option<&str> {
        p.and_then(Path::file_name).and_then(|n| n.to_str())
    }
    let macos = path.parent();
    let contents = macos.and_then(Path::parent);
    let app = contents.and_then(Path::parent);
    path.is_absolute()
        && name(macos) == Some("MacOS")
        && name(contents) == Some("Contents")
        && name(app).is_some_and(|n| n.len() > 4 && n.ends_with(".app"))
}

/// GUI host (D-P-3): a session leader qualifies as an anchor only if it is the main process of an app
/// (`.app/Contents/MacOS/…`), was started by launchd (parent 1), has no controlling terminal (neither the
/// `CONTROLT`/`CTTY` flags nor `e_tdev`) and has the same uid as the daemon. Terminal shells, `login`, `tmux`,
/// `sshd` are not an `.app` or have a terminal; anything that could not be read does not qualify.
pub fn gui_host(s: &ProcStat) -> bool {
    let same = || sys::uniq_info(s.pid).is_ok_and(|u| u.unique_id == s.start);
    if s.ppid != 1 || !same() {
        return false;
    }
    let Ok(b) = sys::bsd_info(s.pid) else {
        return false;
    };
    let Ok(path) = sys::exe_path(s.pid) else {
        return false;
    };
    same()
        && b.uid == euid()
        && b.flags & (sys::PROC_FLAG_CONTROLT | sys::PROC_FLAG_CTTY) == 0
        && b.tdev.is_none()
        && is_app_main_executable(&path)
}

/// Every live process of the daemon's uid (`proc_listallpids`); a process that exits while it is read is skipped.
pub(super) fn all_mine() -> Vec<ProcStat> {
    let uid = euid();
    sys::all_pids()
        .unwrap_or_default()
        .into_iter()
        .filter_map(stat)
        .filter(|d| d.uid == uid)
        .map(|d| d.stat)
        .collect()
}
