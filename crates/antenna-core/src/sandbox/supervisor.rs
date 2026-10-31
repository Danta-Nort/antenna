// SPDX-License-Identifier: AGPL-3.0-only
//! The agent supervisor (`antennad --antenna-wake-exec`) and its stage 2 (`antennad --antenna-wake-exec exec`).
//!
//! **Supervisor** (PID 1 of its own pidns in bwrap, a subreaper without bwrap): reads the spec from stdin, sets up the
//! bridge `127.0.0.1:port` ⇄ the proxy unix socket, starts stage 2 in its own process group, reaps all descendants
//! (`wait(-1)`). stdin is the lifeline: EOF → SIGKILL to the whole agent tree, exit. When the agent ends, the remaining
//! descendants (double fork, `setsid`) get SIGKILL, and it exits with the agent's code. The supervisor itself is not
//! restricted by Landlock (it needs the proxy socket and `/proc`), but the agent cannot reach it: ptrace and
//! `/proc/<pid>/mem` are closed by the agent's Landlock domain and `PR_SET_DUMPABLE=0`; signals by PID 1 of the pidns
//! (bwrap) or by seccomp + the Landlock scope (ABI ≥ 6).
//!
//! **Stage 2** is a separate process so that the restrictions apply only to the agent: rlimits, `PR_SET_PDEATHSIG`,
//! dropping capabilities, Landlock, seccomp, and then `exec` of the agent program (stdin is `/dev/null`, or for a
//! resident agent the pipe the supervisor feeds from the lifeline).

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
use super::{EXIT_SANDBOX_FAILED, NOTE_PREFIX};

/// Entry point of the hidden mode `antennad --antenna-wake-exec`: call it on the first line of `main` when `argv[1]` is
/// [`super::SUPERVISOR_ARG`], and exit with the returned code. The code is the agent's (signal → 128 + N) or
/// [`EXIT_SANDBOX_FAILED`]. On macOS, the supervisor and stage 2 run under Seatbelt (`super::macos`, D-P-13).
pub fn supervisor_main() -> i32 {
    #[cfg(target_os = "linux")]
    {
        imp::main()
    }
    #[cfg(target_os = "macos")]
    {
        super::macos::supervisor_main()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        eprintln!("{NOTE_PREFIX} error: the agent sandbox exists only on Linux and macOS");
        EXIT_SANDBOX_FAILED
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use std::{
        collections::BTreeMap,
        convert::Infallible,
        io::{BufRead, Read, Write},
        os::unix::process::CommandExt,
        path::PathBuf,
        process::{Command, Stdio},
        sync::Mutex,
    };

    use rustix::process::{Pid, Signal, WaitOptions, getpid};
    use serde::{Deserialize, Serialize};

    use super::super::{
        EXIT_SANDBOX_FAILED, NOTE_PREFIX, SUPERVISOR_ARG, SandboxKind, SandboxSpec,
        common::{
            agent_env, lifeline, program_paths, read_line_json, read_line_json_unbuffered, rlimits,
            set_rlimit, start_bridge,
        },
        linux::{DEV_FILES, ETC_ALLOW, LaunchMsg, SYSTEM_DIRS, kill_descendants},
    };

    /// Supervisor → stage 2 (a JSON line on its stdin).
    #[derive(Debug, Serialize, Deserialize)]
    struct ExecPlan {
        spec: SandboxSpec,
        /// The agent's final environment.
        env: Vec<(String, String)>,
        /// Bridge port (TCP connect only to it).
        proxy_port: Option<u16>,
        /// The supervisor's PID (as stage 2 sees it), to check `getppid`.
        supervisor_pid: i32,
        /// Who the agent may not signal (seccomp): the supervisor, the daemon.
        guard_pids: Vec<i32>,
        /// Whose process groups as well.
        guard_pgids: Vec<i32>,
    }

    pub(super) fn main() -> i32 {
        let stage2 = std::env::args_os().nth(2).is_some_and(|a| a == "exec");
        let r = if stage2 {
            exec_stage().map(|never| match never {})
        } else {
            supervise()
        };
        match r {
            Ok(code) => code,
            Err(e) => {
                eprintln!("{NOTE_PREFIX} error: {e}");
                EXIT_SANDBOX_FAILED
            }
        }
    }

    fn raw(p: Pid) -> i32 {
        p.as_raw_nonzero().get()
    }

    // Supervisor.

    fn supervise() -> Result<i32, String> {
        use rustix::process::{DumpableBehavior, set_dumpable_behavior};
        // An agent with the same uid cannot read the supervisor's memory or attach a debugger to it.
        let _ = set_dumpable_behavior(DumpableBehavior::NotDumpable);
        set_rlimit(rustix::process::Resource::Core, 0)?;
        let msg: LaunchMsg = read_line_json()?;
        let spec = msg.spec;
        if spec.start_gate {
            // The daemon binds the agent to the sandbox root and enables the run token before the agent's first
            // instruction.
            let mut line = String::new();
            std::io::stdin()
                .lock()
                .take(16)
                .read_line(&mut line)
                .map_err(|e| format!("start gate: {e}"))?;
            if line.trim_end() != "go" {
                return Err("start gate: the daemon did not allow the start".into());
            }
        }
        let me = getpid();
        if spec.kind == SandboxKind::Seatbelt {
            return Err("kind=seatbelt exists only on macOS".into());
        }
        if spec.kind == SandboxKind::Bwrap && raw(me) != 1 {
            // bwrap mode relies on the pidns (`--as-pid-1`): without it, Landlock there is only best effort.
            return Err(
                "kind=bwrap, but the supervisor is not PID 1 of its own PID namespace".into(),
            );
        }
        if raw(me) != 1 {
            // Without our own pidns, the agent's orphans (double fork) come to us, not to init.
            rustix::process::set_child_subreaper(Some(me))
                .map_err(|e| format!("PR_SET_CHILD_SUBREAPER: {e}"))?;
        }
        let port = match &spec.proxy {
            Some(b) => Some(start_bridge(b)?),
            None => None,
        };
        let env = agent_env(&spec, port);
        let (guard_pids, guard_pgids) = if spec.kind == SandboxKind::Landlock {
            // The daemon and the supervisor live in the same PID namespace as the agent.
            let mut pids = vec![raw(me)];
            let mut pgids = vec![raw(rustix::process::getpgrp())];
            if let Some(pp) = rustix::process::getppid() {
                pids.push(raw(pp));
                if let Ok(g) = rustix::process::getpgid(Some(pp)) {
                    pgids.push(raw(g));
                }
            }
            (pids, pgids)
        } else {
            // bwrap: the supervisor is PID 1 (signals from inside the pidns do not reach it), the daemon is not
            // visible.
            (Vec::new(), Vec::new())
        };
        let plan = ExecPlan {
            spec,
            env,
            proxy_port: port,
            supervisor_pid: raw(me),
            guard_pids,
            guard_pgids,
        };
        let mut cmd = Command::new("/proc/self/exe");
        cmd.arg(SUPERVISOR_ARG)
            .arg("exec")
            .env_clear()
            .current_dir("/")
            .stdin(Stdio::piped())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            // Its own group: the agent's `kill(0, …)` does not hit the supervisor.
            .process_group(0);
        antenna_sys::fds::no_inherited_fds_in_child(&mut cmd);
        let agent_stdin = plan.spec.agent_stdin;
        let mut child = cmd.spawn().map_err(|e| format!("spawn stage 2: {e}"))?;
        let agent = child.id() as i32;
        let mut w = child.stdin.take().ok_or("stage 2 stdin")?;
        {
            let mut line = serde_json::to_vec(&plan).map_err(|e| format!("encode plan: {e}"))?;
            line.push(b'\n');
            if let Err(e) = w.write_all(&line) {
                eprintln!("{NOTE_PREFIX} error: stage 2: {e}");
            }
        }
        // A resident agent keeps this pipe as its stdin (stage 2 read only its plan line from it); otherwise it is
        // closed here and the agent gets `/dev/null`.
        let agent_input = agent_stdin.then_some(w);
        // `child` is not awaited through std: the `wait(-1)` loop below reaps all descendants.
        drop(child);
        std::thread::Builder::new()
            .name("lifeline".into())
            .spawn(move || {
                lifeline(agent_input);
                // The daemon closed the lifeline or died.
                finish(128 + 9)
            })
            .map_err(|e| format!("lifeline thread: {e}"))?;
        let code = loop {
            match rustix::process::wait(WaitOptions::empty()) {
                Ok(Some((pid, st))) if raw(pid) == agent => {
                    break if let Some(c) = st.exit_status() {
                        c
                    } else if let Some(s) = st.terminating_signal() {
                        128 + s
                    } else {
                        EXIT_SANDBOX_FAILED
                    };
                }
                Ok(_) => continue,
                Err(rustix::io::Errno::INTR) => continue,
                Err(e) => {
                    eprintln!("{NOTE_PREFIX} error: wait: {e}");
                    break EXIT_SANDBOX_FAILED;
                }
            }
        };
        finish(code)
    }

    /// Remove the whole agent tree and exit (once: a second call waits until the first one ends the process).
    fn finish(code: i32) -> ! {
        static ONCE: Mutex<()> = Mutex::new(());
        let g = ONCE.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::forget(g);
        let me = getpid();
        // PID 1 of its own pidns: when it exits the kernel kills everyone (SIGKILL), even those that escaped the group
        // and the session.
        if raw(me) != 1 {
            kill_descendants(raw(me));
        }
        std::process::exit(code)
    }

    // Stage 2.

    fn exec_stage() -> Result<Infallible, String> {
        let plan: ExecPlan = read_line_json_unbuffered()?;
        // If the supervisor dies, so does the agent (kept across exec).
        rustix::process::set_parent_process_death_signal(Some(Signal::KILL))
            .map_err(|e| format!("PR_SET_PDEATHSIG: {e}"))?;
        if rustix::process::getppid().map(raw) != Some(plan.supervisor_pid) {
            return Err("supervisor is gone".into());
        }
        let spec = &plan.spec;
        rlimits(spec)?;
        drop_capabilities()?;
        let ll = landlock(&plan)?;
        let sc = match seccomp(&plan) {
            Ok(()) => "on".to_string(),
            Err(e) if spec.kind == SandboxKind::Bwrap => format!("off({e})"),
            Err(e) => return Err(e),
        };
        if spec.listen.is_some() {
            // The local model runtime (D-96 §3.4): prove from the inside that it can reach nothing, before it runs.
            no_network_probe()?;
        }
        let net = match (plan.proxy_port, &spec.listen) {
            (Some(p), _) => format!("proxy:127.0.0.1:{p}"),
            (None, Some(_)) => "listen-only".into(),
            (None, None) => "none".into(),
        };
        let kind = spec.kind.as_str();
        eprintln!("{NOTE_PREFIX} kind={kind} {ll} seccomp={sc} caps=none net={net}");
        let prog = &spec.argv[0];
        let err = Command::new(prog)
            .args(&spec.argv[1..])
            .env_clear()
            .envs(plan.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&spec.cwd)
            .stdin(if spec.agent_stdin {
                Stdio::inherit()
            } else {
                Stdio::null()
            })
            .exec();
        let code = if err.kind() == std::io::ErrorKind::NotFound {
            127
        } else {
            126
        };
        eprintln!("{NOTE_PREFIX} error: exec {prog}: {err}");
        std::process::exit(code)
    }

    /// A program that only listens must not get a network socket or reach a unix socket: `socket(AF_INET)` and
    /// `connect` to a unix path both have to fail with `EPERM` (seccomp), not with "refused" or "no such file", which
    /// would mean the call went through. Any other answer refuses the start.
    fn no_network_probe() -> Result<(), String> {
        use std::io::ErrorKind;
        match std::net::TcpStream::connect(("127.0.0.1", 9)) {
            Err(e) if e.kind() == ErrorKind::PermissionDenied => {}
            other => {
                return Err(format!(
                    "the runtime's sandbox lets it open a TCP socket ({other:?}); it is not started"
                ));
            }
        }
        match std::os::unix::net::UnixStream::connect("/antenna-probe/none.sock") {
            Err(e) if e.kind() == ErrorKind::PermissionDenied => Ok(()),
            other => Err(format!(
                "the runtime's sandbox lets it connect to a unix socket ({other:?}); it is not started"
            )),
        }
    }

    /// No capabilities at all, neither now nor after `exec` (the bounding set is cleared if we have `CAP_SETPCAP`; with
    /// `no_new_privs`, which Landlock/seccomp set, `exec` grants no more than there was, that is, nothing).
    fn drop_capabilities() -> Result<(), String> {
        use rustix::thread::{
            CapabilitySet, CapabilitySets, capabilities, clear_ambient_capability_set,
            remove_capability_from_bounding_set, set_capabilities,
        };
        for i in 0..64u32 {
            match remove_capability_from_bounding_set(CapabilitySet::from_bits_retain(1u64 << i)) {
                Ok(()) => {}
                // Past the kernel's last capability.
                Err(rustix::io::Errno::INVAL) => break,
                // No CAP_SETPCAP (a regular user): the set grants nothing under no_new_privs anyway.
                Err(_) => {}
            }
        }
        let _ = clear_ambient_capability_set();
        set_capabilities(
            None,
            CapabilitySets {
                effective: CapabilitySet::empty(),
                permitted: CapabilitySet::empty(),
                inheritable: CapabilitySet::empty(),
            },
        )
        .map_err(|e| format!("capset: {e}"))?;
        let now = capabilities(None).map_err(|e| format!("capget: {e}"))?;
        if !now.effective.is_empty() || !now.permitted.is_empty() {
            return Err("capabilities are still present".into());
        }
        Ok(())
    }

    /// Landlock for the agent. In Landlock mode it is mandatory (ABI ≥ 4, rules in effect), otherwise refuse; in bwrap
    /// it is defense in depth, best effort. Returns a line for the note.
    fn landlock(plan: &ExecPlan) -> Result<String, String> {
        use landlock::{
            ABI, Access, AccessFs, AccessNet, BitFlags, CompatLevel, Compatible, LandlockStatus,
            NetPort, Ruleset, RulesetAttr, RulesetCreatedAttr, RulesetStatus, Scope,
            path_beneath_rules,
        };
        let spec = &plan.spec;
        let abi = ABI::V6;
        let mut ro: Vec<PathBuf> = SYSTEM_DIRS
            .iter()
            .chain(ETC_ALLOW)
            .map(PathBuf::from)
            .collect();
        ro.push("/proc".into());
        ro.extend(spec.ro.iter().cloned());
        ro.extend(program_paths(spec));
        ro.extend(spec.ro_binds.iter().map(|(s, d)| match spec.kind {
            // bwrap: the file is mounted at the destination; Landlock: the destination is a symlink, the source needs
            // the permission.
            SandboxKind::Bwrap => d.clone(),
            SandboxKind::Landlock | SandboxKind::Seatbelt => s.clone(),
        }));
        let mut rw: Vec<PathBuf> = [&spec.cwd, &spec.home, &spec.tmp]
            .into_iter()
            .chain(&spec.rw)
            .cloned()
            .collect();
        if spec.kind == SandboxKind::Bwrap {
            // The sandbox's own tmpfs mounts.
            rw.push("/tmp".into());
            rw.push("/dev/shm".into());
        }
        let dev: BitFlags<AccessFs> = AccessFs::ReadFile | AccessFs::WriteFile | AccessFs::IoctlDev;
        let exists = |p: &PathBuf| p.exists();
        let fail = |e: landlock::RulesetError| format!("landlock: {e}");
        let mut rs = Ruleset::default()
            .set_compatibility(CompatLevel::BestEffort)
            .handle_access(AccessFs::from_all(abi))
            .map_err(fail)?
            .handle_access(AccessNet::BindTcp | AccessNet::ConnectTcp)
            .map_err(fail)?
            .scope(Scope::AbstractUnixSocket | Scope::Signal)
            .map_err(fail)?
            .create()
            .map_err(fail)?
            .add_rules(path_beneath_rules(
                ro.iter().filter(|p| exists(p)),
                AccessFs::from_read(abi),
            ))
            .map_err(fail)?
            .add_rules(path_beneath_rules(
                rw.iter().filter(|p| exists(p)),
                AccessFs::from_all(abi),
            ))
            .map_err(fail)?
            .add_rules(path_beneath_rules(
                DEV_FILES
                    .iter()
                    .filter(|p| std::path::Path::new(p).exists()),
                dev,
            ))
            .map_err(fail)?;
        if let Some(port) = plan.proxy_port {
            rs = rs
                .add_rule(NetPort::new(port, AccessNet::ConnectTcp))
                .map_err(fail)?;
        }
        let st = rs.restrict_self().map_err(fail)?;
        let eff = match st.landlock {
            LandlockStatus::Available { effective_abi, .. } => effective_abi as i32,
            _ => 0,
        };
        let state = match st.ruleset {
            RulesetStatus::FullyEnforced => "full",
            RulesetStatus::PartiallyEnforced => "partial",
            RulesetStatus::NotEnforced => "none",
        };
        if spec.kind == SandboxKind::Landlock
            && (eff < 4 || st.ruleset == RulesetStatus::NotEnforced)
        {
            return Err(format!(
                "Landlock is not enforced (state {state}, ABI {eff}); the agent is not started"
            ));
        }
        Ok(format!("landlock={state} abi={eff}"))
    }

    fn seccomp(plan: &ExecPlan) -> Result<(), String> {
        use seccompiler::{
            BpfProgram, SeccompAction, SeccompCmpArgLen as Len, SeccompCmpOp as Op,
            SeccompCondition as Cond, SeccompFilter, SeccompRule, TargetArch,
        };
        let arch = if cfg!(target_arch = "x86_64") {
            TargetArch::x86_64
        } else if cfg!(target_arch = "aarch64") {
            TargetArch::aarch64
        } else {
            return Err("seccomp: unsupported architecture".into());
        };
        let c = |arg: u8, op: Op, v: u64| {
            Cond::new(arg, Len::Dword, op, v).map_err(|e| format!("seccomp: {e}"))
        };
        let r = |v: Vec<Cond>| SeccompRule::new(v).map_err(|e| format!("seccomp: {e}"));
        let as_u32 = |x: i32| x as u32 as u64;
        let (af_unix, af_inet, af_inet6, af_netlink) = (
            libc::AF_UNIX as u64,
            libc::AF_INET as u64,
            libc::AF_INET6 as u64,
            libc::AF_NETLINK as u64,
        );
        let mut rules: BTreeMap<i64, Vec<SeccompRule>> = BTreeMap::new();
        if plan.spec.listen.is_some() {
            // The local model runtime only listens (D-96 §3.4): a unix stream socket is all it may create, and it
            // connects to nothing, which also closes the same-user unix sockets Landlock leaves open (the daemon
            // socket among them, D-71 limits).
            let unix_type = |t: i32| -> Result<SeccompRule, String> {
                r(vec![
                    c(0, Op::Eq, af_unix)?,
                    c(1, Op::MaskedEq(0xf), t as u64)?,
                ])
            };
            rules.insert(
                libc::SYS_socket,
                vec![
                    r(vec![c(0, Op::Ne, af_unix)?])?,
                    unix_type(libc::SOCK_DGRAM)?,
                    unix_type(libc::SOCK_SEQPACKET)?,
                ],
            );
            rules.insert(libc::SYS_connect, vec![]);
        }
        // Sockets: unix yes; TCP yes (Landlock controls the ports); netlink only ROUTE (getifaddrs);
        // the rest (UDP and DNS around the proxy, raw, packet, SCTP, MPTCP, vsock, …) get EPERM.
        let mut sock = vec![r(vec![
            c(0, Op::Ne, af_unix)?,
            c(0, Op::Ne, af_inet)?,
            c(0, Op::Ne, af_inet6)?,
            c(0, Op::Ne, af_netlink)?,
        ])?];
        for d in [af_inet, af_inet6] {
            for t in [
                libc::SOCK_DGRAM,
                libc::SOCK_RAW,
                libc::SOCK_RDM,
                libc::SOCK_SEQPACKET,
                libc::SOCK_DCCP,
                10, // SOCK_PACKET (obsolete, deprecated in libc)
            ] {
                sock.push(r(vec![
                    c(0, Op::Eq, d)?,
                    c(1, Op::MaskedEq(0xf), t as u64)?,
                ])?);
            }
            sock.push(r(vec![
                c(0, Op::Eq, d)?,
                c(2, Op::Ne, 0)?,
                c(2, Op::Ne, libc::IPPROTO_TCP as u64)?,
            ])?);
        }
        sock.push(r(vec![
            c(0, Op::Eq, af_netlink)?,
            c(2, Op::Ne, libc::NETLINK_ROUTE as u64)?,
        ])?);
        rules.entry(libc::SYS_socket).or_insert(sock);
        // io_uring creates sockets around the `socket` filter.
        rules.insert(libc::SYS_io_uring_setup, vec![]);
        // Signals: `kill(-1)` (all processes of the uid), the supervisor and the daemon, their groups; tkill (tid
        // without tgid) is denied; a pidfd for a thread (PIDFD_THREAD = O_EXCL) is denied.
        let mut kill = vec![r(vec![c(0, Op::Eq, as_u32(-1))?])?];
        let mut by_pid = Vec::new();
        for p in &plan.guard_pids {
            kill.push(r(vec![c(0, Op::Eq, as_u32(*p))?])?);
            by_pid.push(r(vec![c(0, Op::Eq, as_u32(*p))?])?);
        }
        for g in &plan.guard_pgids {
            kill.push(r(vec![c(0, Op::Eq, as_u32(-*g))?])?);
        }
        rules.insert(libc::SYS_kill, kill);
        rules.insert(libc::SYS_tkill, vec![]);
        if !by_pid.is_empty() {
            for s in [
                libc::SYS_tgkill,
                libc::SYS_rt_sigqueueinfo,
                libc::SYS_rt_tgsigqueueinfo,
            ] {
                rules.insert(s, by_pid.clone());
            }
        }
        let mut pidfd = by_pid;
        pidfd.push(r(vec![c(
            1,
            Op::MaskedEq(libc::O_EXCL as u64),
            libc::O_EXCL as u64,
        )?])?);
        rules.insert(libc::SYS_pidfd_open, pidfd);
        let f = SeccompFilter::new(
            rules,
            SeccompAction::Allow,
            SeccompAction::Errno(libc::EPERM as u32),
            arch,
        )
        .map_err(|e| format!("seccomp: {e}"))?;
        let f: BpfProgram = f.try_into().map_err(|e| format!("seccomp: {e:?}"))?;
        #[cfg(target_arch = "x86_64")]
        seccompiler::apply_filter(&x32_guard()).map_err(|e| format!("seccomp: {e}"))?;
        seccompiler::apply_filter(&f).map_err(|e| format!("seccomp: {e}"))?;
        Ok(())
    }

    /// x32 syscall numbers (the `__X32_SYSCALL_BIT` bit) are not seen by a filter on the number: `socket` and signals
    /// would get through them. Kill the process (like the file worker, antenna-files `x32_guard`).
    #[cfg(target_arch = "x86_64")]
    fn x32_guard() -> seccompiler::BpfProgram {
        use seccompiler::sock_filter;
        const BPF_LD_W_ABS: u16 = 0x20;
        const BPF_JSET_K: u16 = 0x45;
        const BPF_RET_K: u16 = 0x06;
        const RET_KILL_PROCESS: u32 = 0x8000_0000;
        const RET_ALLOW: u32 = 0x7fff_0000;
        vec![
            sock_filter {
                code: BPF_LD_W_ABS,
                jt: 0,
                jf: 0,
                k: 0,
            },
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
}
