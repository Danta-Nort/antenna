// SPDX-License-Identifier: AGPL-3.0-only
//! macOS (XNU kernel): processes, the peer over a unix socket, debugger denial (PORTABILITY M-3…M-7, M-9, M-10).
//!
//! What and why (details in docs/PORTABILITY.md §2, DECISIONS D-P-1…D-P-3):
//! - [`short_info`] (`proc_pidinfo(PROC_PIDT_SHORTBSDINFO)`): parent, name, uid, flags. According to the XNU sources
//!   (`proc_info.c`) this flavor, like [`uniq_info`] and [`exe_path`], does **not** require the same uid: the process
//!   chain passes through root processes (`login` in Terminal.app, `launchd`). Test `other_uid_processes_are_readable`.
//! - [`uniq_info`] (`PROC_PIDUNIQIDENTIFIERINFO`): `p_uniqueid` (64 bits, not repeated until reboot; it replaces the
//!   start time from `/proc` as protection against PID reuse), the parent's `p_puniqueid`, `p_idversion`.
//! - [`bsd_info`] (`PROC_PIDTBSDINFO`): the controlling terminal (`e_tdev`) and session flags; only for processes of
//!   the same uid (otherwise `EPERM`), so it is used for the socket client itself (it has the same uid as the daemon).
//! - [`peer_audit_token`] (`getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`): PID and `pidversion` of the process at the other
//!   end of the socket; `pidversion` is checked against [`uniq_info`] of the same PID, which closes the PID-reuse
//!   window (on Linux a remainder of it stays, D-41).
//! - [`deny_debugger_attach`] (`ptrace(PT_DENY_ATTACH)`).
//!
//! Structures and constants missing from `libc 0.2.189` are declared here after `<sys/proc_info.h>` and
//! `<bsm/audit.h>`; the size of each is checked against the kernel's answer (a mismatch is an error, not silently
//! wrong fields).

use std::{
    ffi::OsString,
    io,
    mem::{MaybeUninit, size_of},
    os::{
        fd::{AsRawFd, BorrowedFd},
        unix::ffi::OsStringExt,
    },
    path::PathBuf,
};

use libc::{c_int, c_void};

/// `PROC_PIDUNIQIDENTIFIERINFO` (`<sys/proc_info.h>`; missing from `libc`).
const PROC_PIDUNIQIDENTIFIERINFO: c_int = 17;

/// Flag in `pbsi_flags` / `pbi_flags`: the process is traced (`ptrace`, a debugger). Under BSD ptrace XNU reparents the
/// process to the tracer, so the parent chain is then not the one at launch.
pub const PROC_FLAG_TRACED: u32 = 0x2;
/// Flag in `pbi_flags` (only [`bsd_info`]): the process is a session leader.
pub const PROC_FLAG_SLEADER: u32 = 0x20;
/// Flag in `pbi_flags` (only [`bsd_info`]): the process's session has a controlling terminal.
pub const PROC_FLAG_CTTY: u32 = 0x40;
/// Flag in `pbsi_flags` / `pbi_flags`: the process has a controlling terminal (`P_CONTROLT`).
pub const PROC_FLAG_CONTROLT: u32 = 0x80;

/// `NODEV` for `e_tdev` (`(dev_t)-1` in 32 bits): no terminal.
const NODEV: u32 = u32::MAX;

/// `struct proc_uniqidentifierinfo` (`<sys/proc_info.h>`), 56 bytes.
#[repr(C)]
#[derive(Clone, Copy)]
struct ProcUniqIdentifierInfo {
    p_uuid: [u8; 16],
    p_uniqueid: u64,
    p_puniqueid: u64,
    p_idversion: i32,
    p_orig_ppidversion: i32,
    p_reserve3: u64,
    p_reserve4: u64,
}

const _: () = assert!(size_of::<ProcUniqIdentifierInfo>() == 56);
const _: () = assert!(size_of::<libc::proc_bsdshortinfo>() == 64);
const _: () = assert!(size_of::<libc::proc_bsdinfo>() == 136);

/// Structures that `proc_pidinfo` fills in.
///
/// # Safety
/// Implement only for `#[repr(C)]` structures of integers and integer arrays: for them zero bytes are a valid value,
/// and so are any bytes from the kernel.
#[allow(
    unsafe_code,
    reason = "an unsafe marker trait: an implementor promises the flavor's exact struct layout"
)]
unsafe trait PidInfo: Copy {
    /// Flavor for `proc_pidinfo`.
    const FLAVOR: c_int;
}

#[allow(
    unsafe_code,
    reason = "the struct matches the flavor in <sys/proc_info.h>"
)]
// SAFETY: `proc_bsdshortinfo` is `#[repr(C)]`, only `u32` and `[c_char; 16]`.
unsafe impl PidInfo for libc::proc_bsdshortinfo {
    const FLAVOR: c_int = libc::PROC_PIDT_SHORTBSDINFO;
}

#[allow(
    unsafe_code,
    reason = "the struct matches the flavor in <sys/proc_info.h>"
)]
// SAFETY: `proc_bsdinfo` is `#[repr(C)]`, only `u32`/`i32`/`u64` and `c_char` arrays.
unsafe impl PidInfo for libc::proc_bsdinfo {
    const FLAVOR: c_int = libc::PROC_PIDTBSDINFO;
}

#[allow(
    unsafe_code,
    reason = "the struct matches the flavor in <sys/proc_info.h>"
)]
// SAFETY: `ProcUniqIdentifierInfo` is `#[repr(C)]`, only integers and `[u8; 16]`.
unsafe impl PidInfo for ProcUniqIdentifierInfo {
    const FLAVOR: c_int = PROC_PIDUNIQIDENTIFIERINFO;
}

/// `proc_pidinfo(pid, T::FLAVOR, 0, &mut T, sizeof T)`; an answer shorter or longer than the structure is an error.
#[allow(unsafe_code, reason = "FFI: proc_pidinfo")]
fn pidinfo<T: PidInfo>(pid: i32) -> io::Result<T> {
    if pid < 0 {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let size = c_int::try_from(size_of::<T>()).map_err(|_| io::ErrorKind::InvalidInput)?;
    let mut buf = MaybeUninit::<T>::zeroed();
    // SAFETY: `buf` is a buffer of exactly `size` bytes that lives until the end of the call; `proc_pidinfo` writes at
    // most `buffersize` bytes and does not keep the pointer. `arg` is not used for these flavors (0).
    let n =
        unsafe { libc::proc_pidinfo(pid, T::FLAVOR, 0, buf.as_mut_ptr().cast::<c_void>(), size) };
    if n <= 0 {
        // libproc: 0 on error, the cause is in errno.
        let e = io::Error::last_os_error();
        return Err(if e.raw_os_error() == Some(0) {
            io::Error::from(io::ErrorKind::NotFound)
        } else {
            e
        });
    }
    if n != size {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "proc_pidinfo flavor {}: kernel returned {n} bytes, expected {size}",
                T::FLAVOR
            ),
        ));
    }
    // SAFETY: `T: PidInfo` is a structure of integers for which any bytes are valid; the buffer was zeroed and the
    // kernel wrote all `size` bytes.
    Ok(unsafe { buf.assume_init() })
}

fn comm(raw: &[libc::c_char]) -> String {
    let bytes: Vec<u8> = raw
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Brief process information (`PROC_PIDT_SHORTBSDINFO`, readable for a process of any uid).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShortInfo {
    /// PID.
    pub pid: i32,
    /// Parent PID (0 for `launchd`).
    pub ppid: i32,
    /// Process group.
    pub pgid: i32,
    /// Effective uid.
    pub uid: u32,
    /// `PROC_FLAG_*` flags (of these, [`PROC_FLAG_TRACED`] and [`PROC_FLAG_CONTROLT`] are present here).
    pub flags: u32,
    /// Executable name (up to 15 characters, like `comm` on Linux).
    pub comm: String,
}

/// Brief information about process `pid`.
pub fn short_info(pid: i32) -> io::Result<ShortInfo> {
    let s: libc::proc_bsdshortinfo = pidinfo(pid)?;
    Ok(ShortInfo {
        pid: s.pbsi_pid as i32,
        ppid: s.pbsi_ppid as i32,
        pgid: s.pbsi_pgid as i32,
        uid: s.pbsi_uid,
        flags: s.pbsi_flags,
        comm: comm(&s.pbsi_comm),
    })
}

/// Identifiers of a process incarnation (`PROC_PIDUNIQIDENTIFIERINFO`, readable for a process of any uid).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UniqInfo {
    /// `p_uniqueid`: a 64-bit process number, not repeated until reboot.
    pub unique_id: u64,
    /// `p_puniqueid`: the parent's `p_uniqueid`.
    pub parent_unique_id: u64,
    /// `p_idversion`: the PID version (the same as `pidversion` in the audit token).
    pub id_version: i32,
}

/// Identifiers of the incarnation of process `pid`.
pub fn uniq_info(pid: i32) -> io::Result<UniqInfo> {
    let u: ProcUniqIdentifierInfo = pidinfo(pid)?;
    let _ = (u.p_uuid, u.p_orig_ppidversion, u.p_reserve3, u.p_reserve4);
    Ok(UniqInfo {
        unique_id: u.p_uniqueid,
        parent_unique_id: u.p_puniqueid,
        id_version: u.p_idversion,
    })
}

/// Full BSD information (`PROC_PIDTBSDINFO`), only what the daemon needs. The kernel refuses for a process of another
/// uid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BsdInfo {
    /// Effective uid.
    pub uid: u32,
    /// `PROC_FLAG_*` flags, including [`PROC_FLAG_SLEADER`] and [`PROC_FLAG_CTTY`].
    pub flags: u32,
    /// Controlling terminal (`e_tdev`); `None` means no terminal.
    pub tdev: Option<u32>,
    /// Start time: seconds and microseconds since the epoch.
    pub start: (u64, u64),
}

/// Full BSD information about process `pid` (of the same uid).
pub fn bsd_info(pid: i32) -> io::Result<BsdInfo> {
    let b: libc::proc_bsdinfo = pidinfo(pid)?;
    Ok(BsdInfo {
        uid: b.pbi_uid,
        flags: b.pbi_flags,
        tdev: (b.e_tdev != NODEV).then_some(b.e_tdev),
        start: (b.pbi_start_tvsec, b.pbi_start_tvusec),
    })
}

/// Path of the process's executable (`proc_pidpath`).
#[allow(unsafe_code, reason = "FFI: proc_pidpath")]
pub fn exe_path(pid: i32) -> io::Result<PathBuf> {
    if pid < 0 {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let len = u32::try_from(buf.len()).map_err(|_| io::ErrorKind::InvalidInput)?;
    // SAFETY: `buf` is a buffer of `len` bytes that lives until the end of the call; `proc_pidpath` writes at most
    // `len` bytes.
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast::<c_void>(), len) };
    if n <= 0 {
        return Err(io::Error::last_os_error());
    }
    buf.truncate(n as usize);
    if let Some(end) = buf.iter().position(|&b| b == 0) {
        buf.truncate(end);
    }
    Ok(PathBuf::from(OsString::from_vec(buf)))
}

/// Audit token of the process at the other end of a unix socket (`<bsm/audit.h>`: `audit_token_t`, 8 × u32).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuditToken {
    /// `val[5]`: PID.
    pub pid: i32,
    /// `val[7]`: PID version (`p_idversion`).
    pub pid_version: i32,
    /// `val[1]`: effective uid.
    pub euid: u32,
    /// All eight words.
    pub raw: [u32; 8],
}

/// Audit token of the peer over a unix socket (`getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`).
#[allow(unsafe_code, reason = "FFI: getsockopt(LOCAL_PEERTOKEN)")]
pub fn peer_audit_token(fd: BorrowedFd<'_>) -> io::Result<AuditToken> {
    let mut raw = [0u32; 8];
    let mut len = libc::socklen_t::try_from(size_of::<[u32; 8]>())
        .map_err(|_| io::ErrorKind::InvalidInput)?;
    // SAFETY: `fd` is an open descriptor for the duration of the borrow; `raw` is a buffer of `len` bytes that lives
    // until the end of the call; the kernel writes at most `len` bytes and returns the written length in `len`.
    let r = unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERTOKEN,
            raw.as_mut_ptr().cast::<c_void>(),
            &mut len,
        )
    };
    if r != 0 {
        return Err(io::Error::last_os_error());
    }
    if len as usize != size_of::<[u32; 8]>() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("LOCAL_PEERTOKEN: {len} bytes, expected 32"),
        ));
    }
    Ok(AuditToken {
        pid: raw[5] as i32,
        pid_version: raw[7] as i32,
        euid: raw[1],
        raw,
    })
}

/// ID of the current OS boot (`sysctl kern.bootsessionuuid`, a UUID string): each boot has its own. It keeps the
/// binding of an agent to a process (PID + `p_uniqueid`) from surviving a reboot, after which numbering starts over
/// (D-P-9). The Linux counterpart is `/proc/sys/kernel/random/boot_id`.
#[allow(unsafe_code, reason = "FFI: sysctlbyname")]
pub fn boot_session_uuid() -> io::Result<String> {
    let name = c"kern.bootsessionuuid";
    let mut buf = [0u8; 64];
    let mut len: libc::size_t = buf.len();
    // SAFETY: `name` is a NUL-terminated C string; `buf` is a buffer of `len` bytes that lives until the end of the
    // call; the kernel writes at most `len` bytes and returns the length in `len`; no new value is set (`newp` = null,
    // `newlen` = 0).
    let r = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            buf.as_mut_ptr().cast::<c_void>(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if r != 0 {
        return Err(io::Error::last_os_error());
    }
    let s = &buf[..len.min(buf.len())];
    let s = s.split(|&b| b == 0).next().unwrap_or_default();
    let s = String::from_utf8_lossy(s).trim().to_string();
    if s.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "kern.bootsessionuuid is empty",
        ));
    }
    Ok(s)
}

/// The raw value of a read-only `sysctl` by name, at most 256 bytes (the hardware assessment of local models, D-96
/// §2.4: memory, CPU, its name; nothing that needs a permission).
#[allow(unsafe_code, reason = "FFI: sysctlbyname")]
fn sysctl_raw(name: &str) -> io::Result<Vec<u8>> {
    let name = std::ffi::CString::new(name)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in a sysctl name"))?;
    let mut buf = [0u8; 256];
    let mut len: libc::size_t = buf.len();
    // SAFETY: `name` is a NUL-terminated C string that lives until the end of the call; `buf` is a buffer of `len`
    // bytes that lives until the end of the call; the kernel writes at most `len` bytes and returns the length in
    // `len`; no new value is set (`newp` = null, `newlen` = 0).
    let r = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            buf.as_mut_ptr().cast::<c_void>(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if r != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(buf[..len.min(buf.len())].to_vec())
}

/// A numeric `sysctl` (`hw.memsize`, `hw.ncpu`, `kern.memorystatus_level`): a 4- or 8-byte integer in host order.
pub fn sysctl_u64(name: &str) -> io::Result<u64> {
    let b = sysctl_raw(name)?;
    match b.len() {
        4 => Ok(u64::from(u32::from_ne_bytes([b[0], b[1], b[2], b[3]]))),
        8 => Ok(u64::from_ne_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ])),
        n => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("sysctl {name}: {n} bytes, not a number"),
        )),
    }
}

/// A text `sysctl` (`machdep.cpu.brand_string`), up to its first NUL.
pub fn sysctl_string(name: &str) -> io::Result<String> {
    let b = sysctl_raw(name)?;
    let s = b.split(|&c| c == 0).next().unwrap_or_default();
    Ok(String::from_utf8_lossy(s).trim().to_string())
}

/// PIDs of all processes in the system (`proc_listallpids`), for finding the processes of an agent's sandbox after
/// a run ends (D-P-13: on macOS orphans are reparented to `launchd`, so they cannot be found by parent).
#[allow(unsafe_code, reason = "FFI: proc_listallpids")]
pub fn all_pids() -> io::Result<Vec<i32>> {
    // SAFETY: with a null buffer and size 0, libproc only returns the number of processes and writes nothing.
    let n = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if n <= 0 {
        return Err(io::Error::last_os_error());
    }
    // Headroom for processes born between the two calls.
    let mut buf = vec![0i32; n as usize + 256];
    let size =
        c_int::try_from(buf.len() * size_of::<i32>()).map_err(|_| io::ErrorKind::InvalidInput)?;
    // SAFETY: `buf` is a buffer of exactly `size` bytes that lives until the end of the call; the kernel writes at most
    // `size` bytes.
    let got = unsafe { libc::proc_listallpids(buf.as_mut_ptr().cast::<c_void>(), size) };
    if got <= 0 {
        return Err(io::Error::last_os_error());
    }
    buf.truncate((got as usize).min(buf.len()));
    buf.retain(|&p| p > 0);
    Ok(buf)
}

/// Physical memory footprint of a process (`proc_pid_rusage(RUSAGE_INFO_V2).ri_phys_footprint`, "Memory" in Activity
/// Monitor, including compressed memory). On macOS `RLIMIT_DATA`/`RLIMIT_AS` do not limit `mmap` memory, so the memory
/// limit of the file check worker is enforced by a watchdog in the daemon using this number (D-P-12).
#[allow(unsafe_code, reason = "FFI: proc_pid_rusage")]
pub fn phys_footprint(pid: i32) -> io::Result<u64> {
    if pid <= 0 {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    }
    let mut info = MaybeUninit::<libc::rusage_info_v2>::zeroed();
    // SAFETY: the buffer is a `rusage_info_v2` structure for the flavor `RUSAGE_INFO_V2` (the API takes it as
    // `rusage_info_t *`) and lives until the end of the call; the kernel writes at most this structure.
    let r = unsafe {
        libc::proc_pid_rusage(
            pid,
            libc::RUSAGE_INFO_V2,
            info.as_mut_ptr().cast::<libc::rusage_info_t>(),
        )
    };
    if r != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the structure consists only of integers and a byte array; it was zeroed and filled by the kernel.
    Ok(unsafe { info.assume_init() }.ri_phys_footprint)
}

/// Denies attaching a debugger to the current process (`ptrace(PT_DENY_ATTACH)`, SPEC §13). If the process is already
/// traced, the kernel terminates it (`ENOTSUP`), so call it only in a release build. This does not block reading memory
/// through `task_for_pid`: that takes signing with the hardened runtime (PORTABILITY M-7).
#[allow(unsafe_code, reason = "FFI: ptrace(PT_DENY_ATTACH)")]
pub fn deny_debugger_attach() -> io::Result<()> {
    // SAFETY: for `PT_DENY_ATTACH` the kernel neither reads nor writes memory at `addr` (null) and ignores `data`;
    // pid 0 is the current process.
    let r = unsafe { libc::ptrace(libc::PT_DENY_ATTACH, 0, std::ptr::null_mut(), 0) };
    if r == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    //! Checks of the PORTABILITY assumptions marked "to verify" on real macOS (CI `release-macos.yml`, job `core`).
    //! Facts the logic does not depend on are printed (`--nocapture`), not asserted.

    use std::{
        io::{BufRead, BufReader},
        os::{fd::AsFd, unix::net::UnixStream},
        process::{Command, Stdio},
        time::{Duration, Instant},
    };

    use super::*;

    fn me() -> i32 {
        std::process::id() as i32
    }

    #[test]
    fn sysctl_reads_the_hardware() {
        let mem = sysctl_u64("hw.memsize").unwrap();
        assert!(mem >= 1 << 30, "{mem}");
        let ncpu = sysctl_u64("hw.ncpu").unwrap();
        assert!(ncpu >= 1);
        let level = sysctl_u64("kern.memorystatus_level").unwrap();
        assert!(level <= 100);
        let cpu = sysctl_string("machdep.cpu.brand_string").unwrap();
        println!("FACT sysctl memsize={mem} ncpu={ncpu} memorystatus_level={level} cpu={cpu:?}");
        assert!(sysctl_u64("no.such.sysctl").is_err());
    }

    #[allow(unsafe_code, reason = "FFI: geteuid")]
    fn euid() -> u32 {
        // SAFETY: `geteuid` takes no arguments and always succeeds.
        unsafe { libc::geteuid() }
    }

    #[allow(unsafe_code, reason = "FFI: getsid")]
    fn getsid(pid: i32) -> i32 {
        // SAFETY: `getsid` takes only an integer and does not touch the process's memory.
        unsafe { libc::getsid(pid) }
    }

    fn python() -> Option<&'static str> {
        [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        .into_iter()
        .find(|p| std::path::Path::new(p).exists())
    }

    /// Waits until the condition becomes true (the helper process has done `setsid` and the like).
    fn wait_until(what: &str, f: impl Fn() -> bool) {
        let t = Instant::now();
        while !f() {
            assert!(t.elapsed() < Duration::from_secs(10), "timeout: {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn own_process_info_matches_std() {
        let s = short_info(me()).unwrap();
        assert_eq!(s.pid, me());
        assert_eq!(s.ppid, std::os::unix::process::parent_id() as i32);
        assert_eq!(s.uid, euid());
        // MAXCOMLEN = 16: the name is truncated to 15 bytes plus NUL (to 16 if the kernel leaves no NUL).
        assert!(
            !s.comm.is_empty() && s.comm.len() <= 16,
            "comm {:?}",
            s.comm
        );
        assert_eq!(s.flags & PROC_FLAG_TRACED, 0, "the test is not traced");
        let u = uniq_info(me()).unwrap();
        assert_ne!(u.unique_id, 0);
        let p = uniq_info(s.ppid).unwrap();
        assert_eq!(
            u.parent_unique_id, p.unique_id,
            "p_puniqueid = parent's p_uniqueid"
        );
        let b = bsd_info(me()).unwrap();
        assert_eq!(b.uid, euid());
        assert!(b.start.0 > 1_600_000_000, "start time {:?}", b.start);
        let exe = exe_path(me()).unwrap();
        assert_eq!(
            exe.canonicalize().unwrap(),
            std::env::current_exe().unwrap().canonicalize().unwrap()
        );
    }

    /// The main assumption of M-3: `SHORTBSDINFO`, `UNIQIDENTIFIERINFO` and the path are readable for a root process
    /// (`launchd`) as an ordinary user, while `PROC_PIDTBSDINFO` is not (this is only printed).
    #[test]
    fn other_uid_processes_are_readable() {
        let s = short_info(1).unwrap();
        assert_eq!((s.pid, s.ppid, s.uid), (1, 0, 0));
        assert_eq!(s.comm, "launchd");
        let u = uniq_info(1).unwrap();
        assert_ne!(u.unique_id, 0);
        // The path is needed only for processes of one's own uid (GUI host, D-P-3); for launchd it is only printed.
        eprintln!(
            "FACT euid={} launchd unique_id={} id_version={} path={:?} bsd_info(1)={:?} getsid(1)={} getsid(parent)={}",
            euid(),
            u.unique_id,
            u.id_version,
            exe_path(1).map_err(|e| e.to_string()),
            bsd_info(1).map_err(|e| e.to_string()),
            getsid(1),
            getsid(std::os::unix::process::parent_id() as i32),
        );
        assert!(short_info(i32::MAX).is_err(), "no such process");
        assert!(short_info(-1).is_err());
    }

    /// Child: `p_puniqueid` = our `p_uniqueid`; after its death the same PID is a different process or absent.
    #[test]
    fn child_links_to_parent_and_dies() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let pid = child.id() as i32;
        let mine = uniq_info(me()).unwrap();
        let u = uniq_info(pid).unwrap();
        assert_eq!(u.parent_unique_id, mine.unique_id);
        assert!(u.unique_id > mine.unique_id, "unique ids grow");
        assert_eq!(short_info(pid).unwrap().ppid, me());
        child.kill().unwrap();
        child.wait().unwrap();
        match uniq_info(pid) {
            Err(_) => {}
            Ok(again) => assert_ne!(
                again.unique_id, u.unique_id,
                "pid reused by another process"
            ),
        }
    }

    /// D-P-9: the boot ID is readable, stable and looks like a UUID.
    #[test]
    fn boot_session_uuid_is_stable() {
        let a = boot_session_uuid().unwrap();
        assert_eq!(a, boot_session_uuid().unwrap());
        assert_eq!(a.len(), 36, "{a:?}");
        assert_eq!(a.matches('-').count(), 4, "{a:?}");
        eprintln!("FACT kern.bootsessionuuid = {a}");
    }

    /// M-10: the token of a socket pair within the process names us and our PID version.
    #[test]
    fn audit_token_of_socketpair_is_self() {
        let (a, _b) = UnixStream::pair().unwrap();
        let t = peer_audit_token(a.as_fd()).unwrap();
        assert_eq!(t.pid, me());
        assert_eq!(t.euid, euid());
        assert_eq!(t.pid_version, uniq_info(me()).unwrap().id_version);
    }

    /// M-10: the token of a connection from another process names that process.
    #[test]
    fn audit_token_names_the_connecting_process() {
        let dir = std::env::temp_dir().join(format!("antenna-sys-{}", me()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s");
        let _ = std::fs::remove_file(&path);
        let l = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let mut child = Command::new("/usr/bin/nc")
            .arg("-U")
            .arg(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        // No endless wait if nc does not connect.
        l.set_nonblocking(true).unwrap();
        let t = Instant::now();
        let s = loop {
            match l.accept() {
                Ok((s, _)) => break s,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    assert!(t.elapsed() < Duration::from_secs(10), "nc did not connect");
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(e) => panic!("accept: {e}"),
            }
        };
        let t = peer_audit_token(s.as_fd()).unwrap();
        let u = uniq_info(child.id() as i32).unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(t.pid, child.id() as i32);
        assert_eq!(t.pid_version, u.id_version);
    }

    /// M-5: a session leader without a terminal: the `SLEADER` flag, no `CONTROLT`, `e_tdev` = `NODEV`.
    #[test]
    fn session_leader_flags() {
        let Some(py) = python() else {
            eprintln!("SKIP: no python3");
            return;
        };
        let mut child = Command::new(py)
            .args(["-c", "import os,time; os.setsid(); time.sleep(30)"])
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        wait_until("setsid", || getsid(pid) == pid);
        let b = bsd_info(pid).unwrap();
        let s = short_info(pid).unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        assert_ne!(b.flags & PROC_FLAG_SLEADER, 0, "flags {:#x}", b.flags);
        assert_eq!(b.flags & PROC_FLAG_CONTROLT, 0, "flags {:#x}", b.flags);
        assert_eq!(s.flags & PROC_FLAG_CONTROLT, 0, "flags {:#x}", s.flags);
        assert_eq!(b.tdev, None);
    }

    /// M-9: a process with a controlling terminal (`script` provides a pty): `CONTROLT` in the brief info and `e_tdev`.
    #[test]
    fn controlling_terminal_is_seen() {
        let Some(py) = python() else {
            eprintln!("SKIP: no python3");
            return;
        };
        let mut child = Command::new("/usr/bin/script")
            .args([
                "-q",
                "/dev/null",
                py,
                "-c",
                "import os,sys,time; print(os.getpid(), flush=True); time.sleep(30)",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let pid: i32 = line
            .trim()
            .parse()
            .unwrap_or_else(|_| panic!("pid line {line:?}"));
        let s = short_info(pid).unwrap();
        let b = bsd_info(pid).unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        eprintln!(
            "FACT pty child: short flags {:#x}, bsd flags {:#x}, tdev {:?}",
            s.flags, b.flags, b.tdev
        );
        assert_ne!(s.flags & PROC_FLAG_CONTROLT, 0, "flags {:#x}", s.flags);
        assert!(b.tdev.is_some());
    }

    /// D-P-13: the process list contains us and `launchd`; a child is visible while alive.
    #[test]
    fn all_pids_lists_self_launchd_and_a_child() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let pids = all_pids().unwrap();
        let has_child = pids.contains(&(child.id() as i32));
        child.kill().unwrap();
        child.wait().unwrap();
        eprintln!("FACT all_pids: {} processes", pids.len());
        assert!(pids.contains(&me()) && pids.contains(&1) && has_child);
    }

    /// D-P-12: the footprint grows with the child's written memory (the worker memory limit watchdog relies on this
    /// number).
    #[test]
    fn phys_footprint_follows_touched_memory() {
        let me_now = phys_footprint(me()).unwrap();
        assert!(me_now > 0);
        let Some(py) = python() else {
            eprintln!("SKIP: no python3");
            return;
        };
        let mut child = Command::new(py)
            .args([
                "-c",
                // Filled bytes (not `bytearray(n)`: zero calloc pages do not count toward the footprint).
                "import sys; b = b'x' * (300 * 1024 * 1024); print('ok', flush=True); sys.stdin.read()",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let fp = phys_footprint(child.id() as i32).unwrap();
        drop(child.stdin.take());
        child.wait().unwrap();
        eprintln!("FACT phys_footprint: self {me_now} B, child with 300 MiB of bytes {fp} B");
        assert!(fp > 250 << 20, "footprint {fp}");
    }

    /// M-7: `PT_DENY_ATTACH` takes effect (in a child process; the test runner itself is left alone).
    #[test]
    fn deny_attach_in_child() {
        if std::env::var_os("ANTENNA_SYS_DENY_ATTACH_CHILD").is_some() {
            let r = deny_debugger_attach();
            std::process::exit(if r.is_ok() { 0 } else { 3 });
        }
        let st = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "darwin::tests::deny_attach_in_child",
                "--test-threads=1",
            ])
            .env("ANTENNA_SYS_DENY_ATTACH_CHILD", "1")
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(st.success(), "child: {st}");
    }
}
