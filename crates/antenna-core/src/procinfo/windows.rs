// SPDX-License-Identifier: AGPL-3.0-only
//! Windows: a process is read by PID alone so far (D-135): it is opened with the least access that reads it, and its
//! creation time is its start (100 ns units since 1601), which with the PID names one process (Windows does not give
//! the PID to another process while this one's object lives). It has no parent, session or terminal here (0), so no
//! terminal or parent owner session and no process binding follow from it.
//!
//! The rest comes with WP-7 (D-134, phase W1): a parent linked only when it was created earlier, the image name, and
//! the user's processes from a toolhelp snapshot filtered by the user SID. Until then those reads answer "unknown", and
//! the callers fail closed (the stop switch says it could not look, `agent_stop`).

use antenna_sys::windows::process::Process;

use super::ProcStat;

/// The process's PID and creation time; `None` if it cannot be opened (gone, or not readable by this user).
pub(super) fn stat(pid: i32) -> Option<ProcStat> {
    let p = Process::open(u32::try_from(pid).ok()?).ok()?;
    Some(ProcStat {
        pid,
        comm: String::new(),
        ppid: 0,
        sid: 0,
        tty: 0,
        start: p.creation_time().ok()?,
    })
}

/// Not read yet: unknown.
pub(super) fn ancestry(_pid: i32) -> Option<Vec<ProcStat>> {
    None
}

/// Not read yet: the binding is stored without it.
pub(super) fn boot_id() -> Option<String> {
    None
}

/// Not read yet: none.
pub(super) fn all_mine() -> Vec<ProcStat> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Our own process reads back the same each time, with a start before now; the control: PID 0 (the idle process)
    /// and a negative PID do not read.
    #[test]
    fn a_process_reads_by_pid_and_creation_time() {
        let pid = std::process::id() as i32;
        let me = stat(pid).unwrap();
        assert_eq!((me.pid, me.ppid, me.sid, me.tty), (pid, 0, 0, 0));
        assert!(me.start > 0 && me.start < antenna_sys::windows::process::now());
        assert_eq!(stat(pid), Some(me));
        assert!(stat(0).is_none());
        assert!(stat(-1).is_none());
    }
}
