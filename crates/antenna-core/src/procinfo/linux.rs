// SPDX-License-Identifier: AGPL-3.0-only
//! Linux: processes from `/proc` (no `unsafe`); the start time is field 22 of `/proc/<pid>/stat` (ticks since boot).

use super::{ProcStat, parse_stat};

/// Process information: `/proc/<pid>/stat`.
pub(super) fn stat(pid: i32) -> Option<ProcStat> {
    if pid <= 0 {
        return None;
    }
    let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    parse_stat(&s)
}

/// The chain up to PID 1 by `/proc/<pid>/stat`, link by link.
pub(super) fn ancestry(pid: i32) -> Option<Vec<ProcStat>> {
    let mut out = Vec::new();
    let mut p = pid;
    for _ in 0..4096 {
        let s = stat(p)?;
        let next = s.ppid;
        out.push(s);
        if next == 0 {
            return Some(out);
        }
        p = next;
    }
    None
}

/// `/proc/sys/kernel/random/boot_id`.
pub(super) fn boot_id() -> Option<String> {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .ok()
        .map(|s| s.trim().to_string())
}

/// Every live process of the daemon's uid in `/proc` (zombies, state `Z`, left out: they have exited already); a
/// process that exits while it is read is skipped.
pub(super) fn all_mine() -> Vec<ProcStat> {
    use std::os::unix::fs::MetadataExt;
    let uid = rustix::process::geteuid().as_raw();
    let Ok(rd) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    rd.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<i32>().ok())
        .filter(|pid| std::fs::metadata(format!("/proc/{pid}")).is_ok_and(|m| m.uid() == uid))
        .filter_map(|pid| {
            let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            let state = s.get(s.rfind(')')? + 2..)?.bytes().next()?;
            (state != b'Z' && state != b'X').then_some(())?;
            parse_stat(&s)
        })
        .collect()
}
