// SPDX-License-Identifier: AGPL-3.0-only
//! Isolation of the check worker on Linux (SPEC §10 step 3 "a separate process without network and without access to
//! keys", §13 "Sandbox").
//!
//! The worker isolates **itself** before reading the first byte of the untrusted file (like Chromium renderers and
//! `codex-linux-sandbox`): it needs neither root, nor system packages, nor bubblewrap.
//! 1. rlimits: core 0, file writes 0 bytes, CPU, memory (`RLIMIT_DATA`: wasmtime reserves `PROT_NONE` address space,
//!    which is not counted), at most 32 descriptors; `PR_SET_DUMPABLE=0`.
//! 2. Landlock (the `landlock` crate; no rules = no file system access at all; TCP bind/connect; socket and signal
//!    scoping where the kernel supports it): it can neither read keys/DB nor write a file.
//! 3. seccomp-bpf (the `seccompiler` crate), two filters:
//!    - kill the process: `execve*`, sockets and network, `ptrace`, `process_vm_*`, `fork`/`clone*` (the worker is
//!      single-threaded);
//!    - allow only what is needed, everything else gets `EPERM`: `read` only from fd 0, `write` only to 1 and 2,
//!      `mmap` only anonymous and without `PROT_EXEC`, `mprotect` without `PROT_EXEC`, memory, signals, time,
//!      `getrandom`, exit. Even if a foreign descriptor got into the process, there is nothing to read it with.
//!
//! The network is closed by seccomp (`socket` kills the process) regardless of the Landlock version; the file system
//! is closed by Landlock (ABI ≥ 1).

use std::collections::BTreeMap;

use seccompiler::{
    BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter,
    SeccompRule, TargetArch,
};

/// What could be enabled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Applied {
    /// `full` | `partial` | `none`.
    pub landlock: String,
    /// Effective Landlock ABI version (0 means none).
    pub landlock_abi: u8,
    /// seccomp is enabled.
    pub seccomp: bool,
    /// rlimits are set.
    pub rlimits: bool,
    /// Extra open descriptors (other than 0, 1, 2) at the time of isolation.
    pub extra_fds: u32,
}

/// Worker resource limits.
#[derive(Debug, Clone, Copy)]
pub struct ResourceLimits {
    /// Memory (data), bytes.
    pub mem_bytes: u64,
    /// CPU time, s.
    pub cpu_secs: u64,
}

fn count_extra_fds() -> u32 {
    let Ok(rd) = std::fs::read_dir("/proc/self/fd") else {
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

fn rlimits(lim: &ResourceLimits) -> Result<(), String> {
    use rustix::process::{Resource, Rlimit, setrlimit};
    let set = |r: Resource, cur: u64, max: u64| {
        setrlimit(
            r,
            Rlimit {
                current: Some(cur),
                maximum: Some(max),
            },
        )
        .map_err(|e| format!("setrlimit {r:?}: {e}"))
    };
    set(Resource::Core, 0, 0)?;
    set(Resource::Fsize, 0, 0)?;
    set(Resource::Nofile, 32, 32)?;
    set(Resource::Cpu, lim.cpu_secs, lim.cpu_secs + 1)?;
    set(Resource::Data, lim.mem_bytes, lim.mem_bytes)?;
    rustix::process::set_dumpable_behavior(rustix::process::DumpableBehavior::NotDumpable)
        .map_err(|e| format!("PR_SET_DUMPABLE: {e}"))?;
    Ok(())
}

fn landlock() -> Result<(String, u8), String> {
    use landlock::{
        ABI, Access, AccessFs, AccessNet, CompatLevel, Compatible, LandlockStatus, Ruleset,
        RulesetAttr, RulesetStatus, Scope,
    };
    let abi = ABI::V6;
    let status = Ruleset::default()
        .set_compatibility(CompatLevel::BestEffort)
        .handle_access(AccessFs::from_all(abi))
        .map_err(|e| format!("landlock fs: {e}"))?
        .handle_access(AccessNet::BindTcp | AccessNet::ConnectTcp)
        .map_err(|e| format!("landlock net: {e}"))?
        .scope(Scope::AbstractUnixSocket | Scope::Signal)
        .map_err(|e| format!("landlock scope: {e}"))?
        .create()
        .map_err(|e| format!("landlock create: {e}"))?
        .restrict_self()
        .map_err(|e| format!("landlock restrict: {e}"))?;
    let abi = match status.landlock {
        LandlockStatus::Available { effective_abi, .. } => effective_abi as u8,
        _ => 0,
    };
    let s = match status.ruleset {
        RulesetStatus::FullyEnforced => "full",
        RulesetStatus::PartiallyEnforced => "partial",
        RulesetStatus::NotEnforced => "none",
    };
    Ok((s.to_string(), abi))
}

/// Mapping type mask (`MAP_SHARED`/`MAP_PRIVATE`/`MAP_SHARED_VALIDATE`).
const MAP_TYPE: u64 = 0x0f;

fn arch() -> Result<TargetArch, String> {
    if cfg!(target_arch = "x86_64") {
        Ok(TargetArch::x86_64)
    } else if cfg!(target_arch = "aarch64") {
        Ok(TargetArch::aarch64)
    } else {
        Err("seccomp: unsupported architecture".into())
    }
}

fn cond(arg: u8, op: SeccompCmpOp, v: u64) -> Result<SeccompCondition, String> {
    SeccompCondition::new(arg, SeccompCmpArgLen::Qword, op, v)
        .map_err(|e| format!("seccomp condition: {e}"))
}

fn rule(c: Vec<SeccompCondition>) -> Result<SeccompRule, String> {
    SeccompRule::new(c).map_err(|e| format!("seccomp rule: {e}"))
}

/// System calls that kill the process.
fn kill_list() -> Vec<i64> {
    let mut v = vec![
        libc::SYS_execve,
        libc::SYS_execveat,
        libc::SYS_socket,
        libc::SYS_socketpair,
        libc::SYS_connect,
        libc::SYS_bind,
        libc::SYS_listen,
        libc::SYS_accept,
        libc::SYS_accept4,
        libc::SYS_sendto,
        libc::SYS_sendmsg,
        libc::SYS_sendmmsg,
        libc::SYS_recvfrom,
        libc::SYS_recvmsg,
        libc::SYS_recvmmsg,
        libc::SYS_ptrace,
        libc::SYS_process_vm_readv,
        libc::SYS_process_vm_writev,
        libc::SYS_clone,
        libc::SYS_clone3,
        libc::SYS_unshare,
        libc::SYS_setns,
        libc::SYS_mount,
        libc::SYS_keyctl,
        libc::SYS_add_key,
        libc::SYS_request_key,
        libc::SYS_bpf,
        libc::SYS_perf_event_open,
        libc::SYS_io_uring_setup,
    ];
    #[cfg(target_arch = "x86_64")]
    v.extend([libc::SYS_fork, libc::SYS_vfork]);
    v
}

fn seccomp() -> Result<(), String> {
    let arch = arch()?;
    // 1. Kill.
    let kill: BTreeMap<i64, Vec<SeccompRule>> =
        kill_list().into_iter().map(|s| (s, vec![])).collect();
    let kill = SeccompFilter::new(kill, SeccompAction::Allow, SeccompAction::KillProcess, arch)
        .map_err(|e| format!("seccomp kill filter: {e}"))?;
    // 2. Allow only what is needed.
    let prot_exec = libc::PROT_EXEC as u64;
    let map_anon = libc::MAP_ANONYMOUS as u64;
    let no_exec = || cond(2, SeccompCmpOp::MaskedEq(prot_exec), 0);
    let mut allow: BTreeMap<i64, Vec<SeccompRule>> = BTreeMap::new();
    allow.insert(
        libc::SYS_read,
        vec![rule(vec![cond(0, SeccompCmpOp::Eq, 0)?])?],
    );
    allow.insert(
        libc::SYS_write,
        vec![
            rule(vec![cond(0, SeccompCmpOp::Eq, 1)?])?,
            rule(vec![cond(0, SeccompCmpOp::Eq, 2)?])?,
        ],
    );
    allow.insert(
        libc::SYS_mmap,
        // Only private anonymous memory: MAP_SHARED|MAP_ANONYMOUS is not counted in RLIMIT_DATA.
        vec![rule(vec![
            cond(3, SeccompCmpOp::MaskedEq(map_anon), map_anon)?,
            cond(
                3,
                SeccompCmpOp::MaskedEq(MAP_TYPE),
                libc::MAP_PRIVATE as u64,
            )?,
            no_exec()?,
        ])?],
    );
    allow.insert(libc::SYS_mprotect, vec![rule(vec![no_exec()?])?]);
    // abort() on panic/out of memory sends SIGABRT to itself: only to its own process.
    let pid = std::process::id() as u64;
    allow.insert(
        libc::SYS_tgkill,
        vec![rule(vec![cond(0, SeccompCmpOp::Eq, pid)?])?],
    );
    for s in [
        libc::SYS_munmap,
        libc::SYS_mremap,
        libc::SYS_madvise,
        libc::SYS_brk,
        libc::SYS_futex,
        libc::SYS_rt_sigaction,
        libc::SYS_rt_sigprocmask,
        libc::SYS_rt_sigreturn,
        libc::SYS_sigaltstack,
        libc::SYS_getrandom,
        libc::SYS_clock_gettime,
        libc::SYS_clock_getres,
        libc::SYS_gettimeofday,
        libc::SYS_sched_yield,
        libc::SYS_sched_getaffinity,
        libc::SYS_gettid,
        libc::SYS_getpid,
        libc::SYS_close,
        libc::SYS_exit,
        libc::SYS_exit_group,
    ] {
        allow.insert(s, vec![]);
    }
    let allow = SeccompFilter::new(
        allow,
        SeccompAction::Errno(libc::EPERM as u32),
        SeccompAction::Allow,
        arch,
    )
    .map_err(|e| format!("seccomp allow filter: {e}"))?;
    let kill: BpfProgram = kill
        .try_into()
        .map_err(|e| format!("seccomp compile: {e}"))?;
    let allow: BpfProgram = allow
        .try_into()
        .map_err(|e| format!("seccomp compile: {e}"))?;
    seccompiler::apply_filter(&kill).map_err(|e| format!("seccomp apply: {e}"))?;
    seccompiler::apply_filter(&allow).map_err(|e| format!("seccomp apply: {e}"))?;
    Ok(())
}

/// Isolates the current process. Call before reading untrusted data; there is no way back.
pub fn apply(lim: &ResourceLimits) -> Result<Applied, String> {
    apply_layers(lim, true)
}

/// The same, with a choice of the seccomp layer (`false` means only rlimits + Landlock: for a self-test that Landlock
/// holds the file system on its own). The production worker always calls [`apply`].
pub fn apply_layers(lim: &ResourceLimits, with_seccomp: bool) -> Result<Applied, String> {
    let extra_fds = count_extra_fds();
    rlimits(lim)?;
    let (landlock, landlock_abi) = landlock()?;
    if with_seccomp {
        seccomp()?;
    }
    Ok(Applied {
        landlock,
        landlock_abi,
        seccomp: with_seccomp,
        rlimits: true,
        extra_fds,
    })
}

/// System calls that kill the external antivirus ([`apply_exec`]): network, signals to other processes and everything
/// that escapes isolation; it needs `execve`/`clone` (starting the program itself, its threads). `socket`/`socketpair`
/// are handled separately with `EPERM` (NSS goes to userdb over AF_UNIX on `getpwuid`; killing broke ordinary
/// programs).
fn exec_kill_list() -> Vec<i64> {
    vec![
        libc::SYS_connect,
        libc::SYS_bind,
        libc::SYS_listen,
        libc::SYS_accept,
        libc::SYS_accept4,
        libc::SYS_sendto,
        libc::SYS_sendmsg,
        libc::SYS_sendmmsg,
        libc::SYS_recvfrom,
        libc::SYS_recvmsg,
        libc::SYS_recvmmsg,
        libc::SYS_ptrace,
        libc::SYS_process_vm_readv,
        libc::SYS_process_vm_writev,
        libc::SYS_unshare,
        libc::SYS_setns,
        libc::SYS_mount,
        libc::SYS_keyctl,
        libc::SYS_add_key,
        libc::SYS_request_key,
        libc::SYS_bpf,
        libc::SYS_perf_event_open,
        libc::SYS_io_uring_setup,
        libc::SYS_tkill,
        libc::SYS_pidfd_send_signal,
        libc::SYS_pidfd_getfd,
    ]
}

/// Kill on x32 system call numbers (the `__X32_SYSCALL_BIT` bit): filters by number do not see them, and on kernels
/// with x32 enabled, network calls would get past the deny list through them. Four BPF instructions, no argument
/// conditions.
#[cfg(target_arch = "x86_64")]
fn x32_guard() -> BpfProgram {
    use seccompiler::sock_filter;
    const BPF_LD_W_ABS: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
    const BPF_JSET_K: u16 = 0x45; // BPF_JMP | BPF_JSET | BPF_K
    const BPF_RET_K: u16 = 0x06; // BPF_RET | BPF_K
    const RET_KILL_PROCESS: u32 = 0x8000_0000;
    const RET_ALLOW: u32 = 0x7fff_0000;
    vec![
        sock_filter {
            code: BPF_LD_W_ABS,
            jt: 0,
            jf: 0,
            k: 0,
        }, // seccomp_data.nr
        sock_filter {
            code: BPF_JSET_K,
            jt: 0,
            jf: 1,
            k: 0x4000_0000,
        },
        sock_filter {
            code: BPF_RET_K,
            jt: 0,
            jf: 0,
            k: RET_KILL_PROCESS,
        },
        sock_filter {
            code: BPF_RET_K,
            jt: 0,
            jf: 0,
            k: RET_ALLOW,
        },
    ]
}

/// Isolation for the external antivirus program before `exec`: rlimits, Landlock (read and execute only `ro`, write
/// only `rw`, TCP closed), seccomp kills on network and isolation escape. There is no worker memory of our own here:
/// the process is replaced by the antivirus right away.
pub fn apply_exec(
    lim: &ResourceLimits,
    ro: &[std::path::PathBuf],
    rw: &std::path::Path,
) -> Result<(), String> {
    use landlock::{
        ABI, Access, AccessFs, AccessNet, CompatLevel, Compatible, Ruleset, RulesetAttr,
        RulesetCreatedAttr, RulesetStatus, path_beneath_rules,
    };
    use rustix::process::{Resource, Rlimit, setrlimit};
    let set = |r: Resource, cur: u64, max: u64| {
        setrlimit(
            r,
            Rlimit {
                current: Some(cur),
                maximum: Some(max),
            },
        )
        .map_err(|e| format!("setrlimit {r:?}: {e}"))
    };
    set(Resource::Core, 0, 0)?;
    set(Resource::Cpu, lim.cpu_secs, lim.cpu_secs + 1)?;
    set(Resource::Data, lim.mem_bytes, lim.mem_bytes)?;
    rustix::process::set_dumpable_behavior(rustix::process::DumpableBehavior::NotDumpable)
        .map_err(|e| format!("PR_SET_DUMPABLE: {e}"))?;
    let abi = ABI::V6;
    let ro: Vec<&std::path::PathBuf> = ro.iter().filter(|p| p.exists()).collect();
    let status = Ruleset::default()
        .set_compatibility(CompatLevel::BestEffort)
        .handle_access(AccessFs::from_all(abi))
        .map_err(|e| format!("landlock fs: {e}"))?
        .handle_access(AccessNet::BindTcp | AccessNet::ConnectTcp)
        .map_err(|e| format!("landlock net: {e}"))?
        .create()
        .map_err(|e| format!("landlock create: {e}"))?
        .add_rules(path_beneath_rules(ro, AccessFs::from_read(abi)))
        .map_err(|e| format!("landlock ro: {e}"))?
        .add_rules(path_beneath_rules([rw], AccessFs::from_all(abi)))
        .map_err(|e| format!("landlock rw: {e}"))?
        // /dev/null: programs redirect output there; the device file gets read and write only.
        .add_rules(path_beneath_rules(
            ["/dev/null"]
                .iter()
                .filter(|p| std::path::Path::new(p).exists()),
            AccessFs::ReadFile | AccessFs::WriteFile,
        ))
        .map_err(|e| format!("landlock /dev/null: {e}"))?
        .restrict_self()
        .map_err(|e| format!("landlock restrict: {e}"))?;
    if status.ruleset == RulesetStatus::NotEnforced {
        return Err("landlock is not enforced".into());
    }
    let arch = arch()?;
    let pid = std::process::id() as u64;
    // Kill: the list above + signals not to itself (`kill`/`tgkill`/`rt_sigqueueinfo` with another pid, groups, -1).
    let mut kill: BTreeMap<i64, Vec<SeccompRule>> =
        exec_kill_list().into_iter().map(|s| (s, vec![])).collect();
    for s in [
        libc::SYS_kill,
        libc::SYS_tgkill,
        libc::SYS_rt_sigqueueinfo,
        libc::SYS_rt_tgsigqueueinfo,
    ] {
        kill.insert(s, vec![rule(vec![cond(0, SeccompCmpOp::Ne, pid)?])?]);
    }
    let kill = SeccompFilter::new(kill, SeccompAction::Allow, SeccompAction::KillProcess, arch)
        .map_err(|e| format!("seccomp kill filter: {e}"))?;
    let kill: BpfProgram = kill
        .try_into()
        .map_err(|e| format!("seccomp compile: {e}"))?;
    // Sockets: refused, not killed.
    let deny: BTreeMap<i64, Vec<SeccompRule>> = [libc::SYS_socket, libc::SYS_socketpair]
        .into_iter()
        .map(|s| (s, vec![]))
        .collect();
    let deny = SeccompFilter::new(
        deny,
        SeccompAction::Allow,
        SeccompAction::Errno(libc::EPERM as u32),
        arch,
    )
    .map_err(|e| format!("seccomp deny filter: {e}"))?;
    let deny: BpfProgram = deny
        .try_into()
        .map_err(|e| format!("seccomp compile: {e}"))?;
    #[cfg(target_arch = "x86_64")]
    seccompiler::apply_filter(&x32_guard()).map_err(|e| format!("seccomp apply: {e}"))?;
    seccompiler::apply_filter(&kill).map_err(|e| format!("seccomp apply: {e}"))?;
    seccompiler::apply_filter(&deny).map_err(|e| format!("seccomp apply: {e}"))?;
    Ok(())
}
