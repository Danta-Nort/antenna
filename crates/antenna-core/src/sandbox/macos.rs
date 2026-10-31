// SPDX-License-Identifier: AGPL-3.0-only
//! macOS: the agent sandbox for wake is Seatbelt (`sandbox_init`), D-P-13 (resolves D-72).
//!
//! The layout is the same as on Linux without bwrap:
//! ```text
//! antennad ──stdin: spec + marks + lifeline───────────────▶ antennad --antenna-wake-exec  (supervisor, outside the sandbox)
//!                                                              │  bridge 127.0.0.1:port ⇄ proxy unix socket
//!                                                              └▶ antennad --antenna-wake-exec exec  (stage 2)
//!                                                                   rlimits, Seatbelt (profile in `seatbelt.rs`), probe
//!                                                                   └─ exec ▶ agent (stdin = /dev/null)
//! ```
//! Differences from Linux:
//! - **No pidns and no subreaper:** the agent's orphans (double fork, `setsid`) go to launchd, and they cannot be found
//!   by parent. The sandbox itself finds them: a process of the same uid created after the supervisor (a larger
//!   `p_uniqueid`) is in a sandbox whose profile allows this run's unique Mach name and denies a second one
//!   (`sandbox_check`). Such processes get SIGKILL ([`sweep_sandbox`]); the supervisor does this on exit, and the
//!   daemon does it if the supervisor is already gone. Without `sandbox_check` in the system, cleanup goes only by
//!   group and parents, and the note says so.
//! - **No PDEATHSIG:** if the supervisor dies, the agent lives until the daemon removes it (`Running::kill_now`).
//! - **The agent cannot reach the supervisor or the daemon:** they are outside the sandbox, and the agent may signal
//!   only its own sandbox.

use std::{
    convert::Infallible,
    io::{Read, Write},
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, Stdio},
    sync::{Mutex, OnceLock},
    time::Duration,
};

use antenna_proto::control::code;
use antenna_sys::{darwin, seatbelt};
use rustix::process::{Pid, Signal, WaitOptions, getpid};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::{
    EXIT_SANDBOX_FAILED, NOTE_PREFIX, Running, SUPERVISOR_ARG, SandboxKind, SandboxSpec, Support,
    common::{
        agent_env, ensure_dirs, lifeline, link_ro_binds, read_line_json, read_line_json_unbuffered,
        rlimits, set_rlimit, start_bridge, validate,
    },
};
use crate::error::{Error, Result};

/// A directory every Mac has and any user may list, which the agent profile does not allow: stage 2 checks from inside
/// that its listing is refused.
const PROBE_DIR: &str = "/Library";

/// Prefix of the Mach names by which a run's sandbox processes are found.
const MARK_PREFIX: &str = "io.github.danta-nort.antenna.wake.";

/// Marks of a run's sandbox: the profile allows `allowed` and (like everything not named) denies `denied`. The second
/// name rules out other sandboxes that allow any Mach names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Marks {
    pub allowed: String,
    pub denied: String,
}

impl Marks {
    fn new() -> Self {
        let r = || data_encoding::HEXLOWER.encode(&rand::random::<[u8; 16]>());
        Self {
            allowed: format!("{MARK_PREFIX}{}", r()),
            denied: format!("{MARK_PREFIX}{}", r()),
        }
    }
}

/// How the daemon finds the sandbox processes if the supervisor did not remove them itself.
#[derive(Debug, Clone)]
pub(super) struct Sweep {
    marks: Marks,
    /// The supervisor's `p_uniqueid`: the whole agent tree was created after it.
    after: u64,
}

/// The first message to the supervisor (a JSON line on stdin).
#[derive(Debug, Serialize, Deserialize)]
struct LaunchMsg {
    spec: SandboxSpec,
    marks: Marks,
}

/// Supervisor → stage 2.
#[derive(Debug, Serialize, Deserialize)]
struct ExecPlan {
    spec: SandboxSpec,
    env: Vec<(String, String)>,
    proxy_port: Option<u16>,
    supervisor_pid: i32,
    marks: Marks,
}

pub(super) fn probe() -> Support {
    let sweep = if seatbelt::can_check() {
        "orphans are found by the sandbox itself (sandbox_check)"
    } else {
        "sandbox_check is missing: orphans are found only by process group and parent"
    };
    Support {
        kind: Some(SandboxKind::Seatbelt),
        bwrap: None,
        landlock_abi: 0,
        detail: format!(
            "Seatbelt (sandbox_init): files — read only system paths and the run's own, write only the run's own \
             folders; network — only the daemon's CONNECT proxy through a localhost bridge; signals — only inside \
             the sandbox; {sweep}. NOT closed: memory and number of processes (no cgroups), file metadata (stat) \
             anywhere, other local processes of the user may use the localhost bridge (only to the allowed hosts)"
        ),
    }
}

fn raw(p: Pid) -> i32 {
    p.as_raw_nonzero().get()
}

fn my_uid() -> u32 {
    rustix::process::geteuid().as_raw()
}

/// Kill all processes of this run's sandbox (same uid, created after `after`, in a sandbox with the `marks` marks);
/// repeat while any are found (new ones may be born during the walk), for at most ~2 s. Returns how many were killed.
pub(super) fn sweep_sandbox(marks: &Marks, after: u64) -> usize {
    if !seatbelt::can_check() {
        return 0;
    }
    let me = std::process::id() as i32;
    let uid = my_uid();
    let mut killed = 0;
    for _ in 0..400 {
        let Ok(pids) = darwin::all_pids() else {
            return killed;
        };
        let mut found = 0;
        for pid in pids {
            if pid <= 1 || pid == me {
                continue;
            }
            let Ok(u) = darwin::uniq_info(pid) else {
                continue;
            };
            if u.unique_id <= after || !darwin::short_info(pid).is_ok_and(|s| s.uid == uid) {
                continue;
            }
            if seatbelt::is_sandboxed(pid) == Some(true)
                && seatbelt::allows_mach_lookup(pid, &marks.allowed) == Some(true)
                && seatbelt::allows_mach_lookup(pid, &marks.denied) == Some(false)
                // The same process that was checked (the PID was not reused).
                && darwin::uniq_info(pid).is_ok_and(|v| v.unique_id == u.unique_id)
                && let Some(p) = Pid::from_raw(pid)
            {
                found += 1;
                if rustix::process::kill_process(p, Signal::KILL).is_ok() {
                    killed += 1;
                }
            }
        }
        if found == 0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    killed
}

/// Descendants of `root` by parent (whose parent is one of those found); the fallback without sandbox marks.
fn kill_descendants(root: i32) {
    for _ in 0..3 {
        let Ok(pids) = darwin::all_pids() else { return };
        let infos: Vec<darwin::ShortInfo> = pids
            .into_iter()
            .filter_map(|p| darwin::short_info(p).ok())
            .collect();
        let mut tree = vec![root];
        let mut i = 0;
        while i < tree.len() {
            let parent = tree[i];
            for s in infos.iter().filter(|s| s.ppid == parent) {
                if !tree.contains(&s.pid) {
                    tree.push(s.pid);
                }
            }
            i += 1;
        }
        if tree.len() == 1 {
            return;
        }
        for pid in &tree[1..] {
            if let Some(p) = Pid::from_raw(*pid) {
                let _ = rustix::process::kill_process(p, Signal::KILL);
            }
        }
    }
}

/// Daemon: the direct child's (the supervisor's) group, its descendants and whatever is left in the run's sandbox.
pub(super) fn kill_tree(pid: u32, sweep: Option<&Sweep>) {
    let Ok(p) = i32::try_from(pid) else { return };
    if p <= 1 {
        return;
    }
    kill_descendants(p);
    if let Some(pid) = Pid::from_raw(p) {
        let _ = rustix::process::kill_process_group(pid, Signal::KILL);
    }
    if let Some(s) = sweep {
        sweep_sandbox(&s.marks, s.after);
    }
}

pub(super) async fn launch(spec: &SandboxSpec, supervisor_exe: &Path) -> Result<Running> {
    validate(spec, supervisor_exe)?;
    let unavailable = |why: String| Error::new(code::SANDBOX_UNAVAILABLE, why);
    if spec.kind != SandboxKind::Seatbelt {
        return Err(unavailable(format!(
            "sandbox: {} is not available on macOS (Seatbelt only)",
            spec.kind.as_str()
        )));
    }
    ensure_dirs(spec)?;
    link_ro_binds(spec)?;
    let marks = Marks::new();
    let mut cmd = tokio::process::Command::new(supervisor_exe);
    cmd.arg(SUPERVISOR_ARG)
        .current_dir(&spec.cwd)
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .process_group(0);
    // Daemon descriptors (DB, sockets, the window) are not for the agent, whoever left them without CLOEXEC (D-61).
    antenna_sys::fds::no_inherited_fds_in_child(cmd.as_std_mut());
    let mut child = cmd
        .spawn()
        .map_err(|e| unavailable(format!("sandbox: spawn: {e}")))?;
    let pid = child.id().unwrap_or(0);
    let after = darwin::uniq_info(pid as i32).map_or(0, |u| u.unique_id);
    let mut stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    let mut line = serde_json::to_vec(&LaunchMsg {
        spec: spec.clone(),
        marks: marks.clone(),
    })
    .map_err(|e| Error::internal(format!("sandbox: spec: {e}")))?;
    line.push(b'\n');
    let written = match stdin.as_mut() {
        Some(s) => s.write_all(&line).await.and(s.flush().await),
        None => Err(std::io::ErrorKind::BrokenPipe.into()),
    };
    if let Err(e) = written {
        let mut err = Vec::new();
        if let Some(s) = stderr.as_mut() {
            let _ =
                tokio::time::timeout(Duration::from_secs(2), s.take(4096).read_to_end(&mut err))
                    .await;
        }
        let _ = child.start_kill();
        let _ = child.wait().await;
        return Err(unavailable(format!(
            "sandbox: supervisor did not start ({e}): {}",
            String::from_utf8_lossy(&err).trim()
        )));
    }
    Ok(Running {
        child,
        pid,
        stdout,
        stderr,
        lifeline: stdin,
        sweep: Some(Sweep { marks, after }),
    })
}

// Supervisor and stage 2 (`antennad --antenna-wake-exec [exec]`).

/// What to clean up when the supervisor exits.
struct Cleanup {
    agent: i32,
    marks: Marks,
    after: u64,
}

static CLEANUP: OnceLock<Cleanup> = OnceLock::new();

pub(super) fn supervisor_main() -> i32 {
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

fn supervise() -> std::result::Result<i32, String> {
    set_rlimit(rustix::process::Resource::Core, 0)?;
    let msg: LaunchMsg = read_line_json()?;
    let (spec, marks) = (msg.spec, msg.marks);
    if spec.start_gate {
        // The daemon binds the agent to the supervisor and enables the run token before the agent's first instruction.
        let mut line = String::new();
        std::io::BufRead::read_line(&mut std::io::stdin().lock().take(16), &mut line)
            .map_err(|e| format!("start gate: {e}"))?;
        if line.trim_end() != "go" {
            return Err("start gate: the daemon did not allow the start".into());
        }
    }
    if spec.kind != SandboxKind::Seatbelt {
        return Err(format!(
            "kind={} is not available on macOS",
            spec.kind.as_str()
        ));
    }
    let me = getpid();
    let after = darwin::uniq_info(raw(me))
        .map_err(|e| format!("own process info: {e}"))?
        .unique_id;
    let port = match &spec.proxy {
        Some(b) => Some(start_bridge(b)?),
        None => None,
    };
    let env = agent_env(&spec, port);
    let plan = ExecPlan {
        spec,
        env,
        proxy_port: port,
        supervisor_pid: raw(me),
        marks: marks.clone(),
    };
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    // Its own session and group (stage 2 calls `setsid` itself, a group leader cannot): the agent's `kill(0, …)` does
    // not hit the supervisor, and the agent has no daemon terminal.
    let mut cmd = Command::new(exe);
    cmd.arg(SUPERVISOR_ARG)
        .arg("exec")
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    antenna_sys::fds::no_inherited_fds_in_child(&mut cmd);
    let agent_stdin = plan.spec.agent_stdin;
    let mut child = cmd.spawn().map_err(|e| format!("spawn stage 2: {e}"))?;
    let agent = child.id() as i32;
    let _ = CLEANUP.set(Cleanup {
        agent,
        marks,
        after,
    });
    let mut w = child.stdin.take().ok_or("stage 2 stdin")?;
    {
        let mut line = serde_json::to_vec(&plan).map_err(|e| format!("encode plan: {e}"))?;
        line.push(b'\n');
        if let Err(e) = w.write_all(&line) {
            eprintln!("{NOTE_PREFIX} error: stage 2: {e}");
        }
    }
    // A resident agent keeps this pipe as its stdin (stage 2 read only its plan line from it).
    let agent_input = agent_stdin.then_some(w);
    // `child` is not awaited through std: the `wait` loop below reaps the child.
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
    if let Some(c) = CLEANUP.get() {
        if let Some(p) = Pid::from_raw(c.agent) {
            let _ = rustix::process::kill_process_group(p, Signal::KILL);
        }
        kill_descendants(raw(getpid()));
        if !seatbelt::can_check() {
            eprintln!(
                "{NOTE_PREFIX} warning: sandbox_check is missing — agent processes that left the process group \
                 may survive the run"
            );
        }
        sweep_sandbox(&c.marks, c.after);
    }
    std::process::exit(code)
}

fn exec_stage() -> std::result::Result<Infallible, String> {
    // A new session without a controlling terminal (like bwrap's `--new-session`): the agent cannot reach the daemon's
    // terminal (TIOCSTI), and its orphans cannot match the owner's `tty` session (D-46): they have neither that session
    // nor a terminal.
    rustix::process::setsid().map_err(|e| format!("setsid: {e}"))?;
    let plan: ExecPlan = read_line_json_unbuffered()?;
    // No PDEATHSIG: if the supervisor is already gone, do not start the agent.
    if rustix::process::getppid().map(raw) != Some(plan.supervisor_pid) {
        return Err("supervisor is gone".into());
    }
    let spec = &plan.spec;
    if spec.kind != SandboxKind::Seatbelt {
        return Err(format!("kind={} on macOS", spec.kind.as_str()));
    }
    rlimits(spec)?;
    let profile = super::seatbelt::agent_profile(spec, plan.proxy_port, &plan.marks.allowed)?;
    seatbelt::apply(&profile).map_err(|e| format!("Seatbelt: {e}"))?;
    // Probe from inside: `/Library` (world-readable, always there) is not in the profile, so its listing cannot be read.
    // Not `/` itself: dyld needs to open the root directory to start the agent, so the profile allows it (D-P-15).
    match std::fs::read_dir(PROBE_DIR) {
        Ok(_) => return Err(format!("Seatbelt is not enforced: {PROBE_DIR} is listable")),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {}
        Err(e) => return Err(format!("Seatbelt self-check: unexpected error {e}")),
    }
    let net = match plan.proxy_port {
        Some(p) => format!("proxy:127.0.0.1:{p}"),
        None => "none".into(),
    };
    eprintln!("{NOTE_PREFIX} kind=seatbelt seatbelt=on net={net}");
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
