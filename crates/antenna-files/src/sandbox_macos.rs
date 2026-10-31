// SPDX-License-Identifier: AGPL-3.0-only
//! Isolation of the check worker on macOS (SPEC §10 step 3, §13 "sandbox-exec"; DECISIONS D-P-12, PORTABILITY M-15).
//!
//! As on Linux (`sandbox_linux`), the worker isolates **itself** before reading the first byte of the untrusted file,
//! and the daemon hands over the content only after confirmation:
//! 1. Seatbelt (`sandbox_init`, profile [`crate::seatbelt::worker_profile`]): everything is denied except reading
//!    system libraries and its own binary: no owner files, no writes, no network, no starting programs, no signals to
//!    others.
//! 2. rlimits: core 0, file writes 0 bytes, CPU, at most 32 descriptors. macOS does not limit memory
//!    (`RLIMIT_DATA`/`RLIMIT_AS`) for `mmap`; the memory limit is enforced by a watchdog in the daemon from the
//!    worker's memory footprint (`sandbox.rs`, `antenna_sys::darwin::phys_footprint`).
//! 3. A probe from inside: after applying, listing `/` fails (`EPERM`); otherwise isolation is not confirmed.
//!
//! Seatbelt does not forbid threads (it has no system call filter like seccomp); that is not a sandbox escape: the
//! thread lives in the same process under the same rules.

use std::path::{Path, PathBuf};

/// What could be enabled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Applied {
    /// Seatbelt is applied and verified from inside.
    pub seatbelt: bool,
    /// rlimits are set.
    pub rlimits: bool,
    /// Extra open descriptors (other than 0, 1, 2) at the time of isolation.
    pub extra_fds: u32,
}

/// Worker resource limits.
#[derive(Debug, Clone, Copy)]
pub struct ResourceLimits {
    /// Memory, bytes (on macOS for information only: the daemon's watchdog enforces it).
    pub mem_bytes: u64,
    /// CPU time, s.
    pub cpu_secs: u64,
}

fn count_extra_fds() -> u32 {
    let Ok(rd) = std::fs::read_dir("/dev/fd") else {
        return 0;
    };
    // read_dir itself holds one descriptor; it is not counted.
    let n = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()))
        .filter(|fd| *fd > 2)
        .count() as u32;
    n.saturating_sub(1)
}

fn set(r: rustix::process::Resource, cur: u64, max: u64) -> Result<(), String> {
    rustix::process::setrlimit(
        r,
        rustix::process::Rlimit {
            current: Some(cur),
            maximum: Some(max),
        },
    )
    .map_err(|e| format!("setrlimit {r:?}: {e}"))
}

/// A probe from inside: listing the file system root is denied under the worker profile.
fn confirm() -> Result<(), String> {
    match std::fs::read_dir("/") {
        Ok(_) => Err("Seatbelt is not enforced: the worker can still list /".into()),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => Ok(()),
        Err(e) => Err(format!("Seatbelt self-check: unexpected error {e}")),
    }
}

/// Isolates the current process. Call before reading untrusted data; there is no way back.
pub fn apply(lim: &ResourceLimits) -> Result<Applied, String> {
    use rustix::process::Resource;
    let extra_fds = count_extra_fds();
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    let profile = crate::seatbelt::worker_profile(&exe)?;
    // The profile first (libsandbox compiles it in this process, with no limits on files and descriptors yet), then
    // rlimits: the sandbox does not restrict `setrlimit`, and they cannot be lifted from inside (hard limit = soft).
    antenna_sys::seatbelt::apply(&profile).map_err(|e| format!("Seatbelt: {e}"))?;
    set(Resource::Core, 0, 0)?;
    set(Resource::Fsize, 0, 0)?;
    set(Resource::Nofile, 32, 32)?;
    set(Resource::Cpu, lim.cpu_secs, lim.cpu_secs + 1)?;
    data_limit(lim);
    confirm()?;
    Ok(Applied {
        seatbelt: true,
        rlimits: true,
        extra_fds,
    })
}

/// Isolation of the external antivirus before `exec` (`av-exec`): rlimits and Seatbelt: read and execute only system
/// paths and `ro`, write only to `rw`, no network, signals only within its own sandbox.
pub fn apply_exec(
    lim: &ResourceLimits,
    ro: &[PathBuf],
    rw: &Path,
    program: &Path,
) -> Result<(), String> {
    use rustix::process::Resource;
    let profile = crate::seatbelt::av_exec_profile(ro, rw, program)?;
    antenna_sys::seatbelt::apply(&profile).map_err(|e| format!("Seatbelt: {e}"))?;
    set(Resource::Core, 0, 0)?;
    set(Resource::Cpu, lim.cpu_secs, lim.cpu_secs + 1)?;
    data_limit(lim);
    Ok(())
}

/// `RLIMIT_DATA` is best effort on macOS: it does not hold `mmap` memory (the daemon's watchdog enforces the memory
/// limit), and macOS 26 refuses it with `EINVAL`. A refusal must not turn off the rest of the isolation.
fn data_limit(lim: &ResourceLimits) {
    let _ = set(
        rustix::process::Resource::Data,
        lim.mem_bytes,
        lim.mem_bytes,
    );
}
