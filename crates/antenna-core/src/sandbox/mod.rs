// SPDX-License-Identifier: AGPL-3.0-only
//! The agent sandbox for wake: SPEC §11 "Wake", "Two sandboxes", §13 "Sandbox", §9 "Taint outlives the session". The
//! daemon starts an agent (`claude -p`, `codex exec`, any script) only here: the file system is only what
//! [`SandboxSpec`] lists, the network is only a bridge to the daemon's CONNECT proxy ([`start_proxy`]), which lets
//! traffic through to the model provider only; the environment is only [`SandboxSpec::env`]; no inherited daemon
//! descriptors (D-61).
//!
//! # Layout
//! ```text
//! antennad ──stdin: spec + lifeline───────────────▶ [bwrap …] ─▶ antennad --antenna-wake-exec  (supervisor)
//!                                                                   │  bridge 127.0.0.1:port ⇄ proxy unix socket
//!                                                                   └▶ antennad --antenna-wake-exec exec  (stage 2)
//!                                                                        rlimits, capabilities, Landlock, seccomp
//!                                                                        └─ exec ▶ agent (stdin = /dev/null, or
//!                                                                           the lifeline's bytes after `go` for a
//!                                                                           resident agent)
//! ```
//! - **Bwrap** ([`SandboxKind::Bwrap`], the main mode on Linux): own namespaces (user, pid, net, ipc, uts, cgroup), the
//!   root is a tmpfs holding only what was selected: system directories and a list from `/etc` (not all of it: root
//!   reads `/etc/shadow` and `/etc/ssl/private` even without capabilities), `/proc`, its own `/dev`, its own `/tmp`,
//!   the spec's paths. The network is an empty netns (loopback only): the only way out is the supervisor's bridge to
//!   the proxy. The supervisor is PID 1 of its pidns (`--as-pid-1`): the agent can neither kill nor stop it, and when
//!   PID 1 exits the kernel kills the whole tree. On top of that, the same Landlock and seccomp as in Landlock mode
//!   (defense in depth: the spec says "bubblewrap + Landlock").
//! - **Landlock** ([`SandboxKind::Landlock`], when there is no bwrap or it cannot set up namespaces, i.e. no
//!   unprivileged userns): the supervisor starts directly with `PR_SET_CHILD_SUBREAPER`; the agent gets Landlock (file
//!   system; TCP connect only to the bridge port, no bind), seccomp (UDP and other socket families, `io_uring`, signals
//!   to the supervisor/daemon and `kill(-1)` get `EPERM`), and dropped capabilities. Not closed (stated in
//!   [`Support::detail`]): unix sockets of the same user, abstract unix sockets and signals to other processes of the
//!   same uid (before ABI 6), the process list in `/proc`.
//!
//! - **Seatbelt** ([`SandboxKind::Seatbelt`], macOS, D-P-13): the supervisor starts directly (outside the sandbox: the
//!   proxy bridge, the lifeline); stage 2 applies the `sandbox_init` profile (`seatbelt.rs`) to itself and `exec`s the
//!   agent, so all descendants inherit the profile. File system: reads of system paths and the spec's paths, writes
//!   only to its own run directories and `rw` (without nested read-only paths); network only `localhost:<bridge port>`
//!   and the spec's unix sockets; signals and process information only within its own sandbox; Mach only user
//!   information and TLS. Orphans (there is no pidns and no subreaper) are found by the sandbox itself
//!   (`sandbox_check`) and killed. What is not closed is listed in [`Support::detail`].
//!
//! The "lifeline" is the supervisor's stdin: the daemon keeps it open; on EOF (the daemon closed it in
//! [`Running::stop`] or died) the supervisor kills the whole agent tree and exits. For a resident agent
//! ([`SandboxSpec::agent_stdin`]) the lifeline also carries the agent's input: after the start gate the supervisor
//! copies it to the agent's stdin pipe, so the daemon stays the only writer and EOF still means "kill". The supervisor's exit code is the
//! agent's (signal → 128 + N); [`EXIT_SANDBOX_FAILED`] means the sandbox did not come up (details in an
//! `antenna-sandbox: error: …` line on stderr).
//!
//! There is no `unsafe` here (D-P-1): CLOEXEC of descriptors in the child is `antenna_sys::fds`, the rest is rustix,
//! landlock, seccompiler.

use std::{path::PathBuf, time::Duration};

use serde::{Deserialize, Serialize};

#[cfg(unix)]
mod common;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
mod proxy;
#[cfg(unix)]
mod seatbelt;
mod supervisor;

#[cfg(unix)]
pub(crate) use proxy::private_tmp_dir;
pub use proxy::{ProxyConfig, ProxyHandle, ProxyStats, start_proxy};
pub use supervisor::supervisor_main;

/// Hidden mode of `antennad`: `antennad --antenna-wake-exec` is the agent supervisor (the spec is one JSON line on
/// stdin). It is checked on the first line of `main`, before clap and tokio: `std::process::exit(supervisor_main())`.
pub const SUPERVISOR_ARG: &str = "--antenna-wake-exec";

/// Prefix of the sandbox's own lines in the agent's stderr: one line about what is enabled (`antenna-sandbox:
/// kind=bwrap landlock=partial abi=4 seccomp=on net=proxy:127.0.0.1:3128`), and errors (`antenna-sandbox: error: …`).
pub const NOTE_PREFIX: &str = "antenna-sandbox:";

/// Supervisor exit code when the sandbox did not come up and the agent was not started (as with `env`/`timeout`).
pub const EXIT_SANDBOX_FAILED: i32 = 125;

/// Isolation mechanism.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SandboxKind {
    /// bubblewrap (namespaces) + Landlock + seccomp.
    Bwrap,
    /// Landlock only (ABI ≥ 4) + seccomp, no namespaces.
    Landlock,
    /// macOS: Seatbelt (`sandbox_init`) + rlimits, a supervisor with a lifeline (D-P-13).
    Seatbelt,
}

impl SandboxKind {
    /// Name for the log, `wake list` and the sandbox note.
    pub fn as_str(self) -> &'static str {
        match self {
            SandboxKind::Bwrap => "bwrap",
            SandboxKind::Landlock => "landlock",
            SandboxKind::Seatbelt => "seatbelt",
        }
    }
}

/// What to run and how.
///
/// All paths are absolute, without `..`. Missing `cwd`, `home`, `tmp`, `rw` directories are created (0700); missing
/// `ro`, `ro_binds` (source) and `sockets` paths are skipped.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SandboxSpec {
    /// `argv[0]` is the ABSOLUTE path of the agent program (visible in the sandbox itself: the file and its real path
    /// behind a symlink).
    pub argv: Vec<String>,
    /// The agent's entire environment; nothing else is inherited. Missing `HOME`, `TMPDIR`, `PATH` are set to `home`,
    /// `tmp`, `/usr/local/bin:/usr/bin:/bin`. With `proxy` the supervisor sets (on top) `HTTPS_PROXY`, `HTTP_PROXY`,
    /// `https_proxy`, `http_proxy`, `ALL_PROXY`, `all_proxy` = `http://127.0.0.1:<bridge port>`.
    pub env: Vec<(String, String)>,
    /// The agent's working folder (writable).
    pub cwd: PathBuf,
    /// The agent's HOME (writable; the daemon creates a separate one for every run).
    pub home: PathBuf,
    /// TMPDIR (writable).
    pub tmp: PathBuf,
    /// Extra writable directories (e.g. `shared/` of the link folder).
    pub rw: Vec<PathBuf>,
    /// Extra read-only paths (the agent program's directory, the `antenna` binary's directory, the link folder).
    pub ro: Vec<PathBuf>,
    /// (source, destination) read-only, e.g. the owner's `~/.claude/.credentials.json` →
    /// `<home>/.claude/.credentials.json`. In Landlock mode the destination is a symlink to the source (writes get
    /// `EACCES`).
    pub ro_binds: Vec<(PathBuf, PathBuf)>,
    /// unix sockets the agent must reach (the daemon control socket).
    pub sockets: Vec<PathBuf>,
    /// Bridge to the daemon's CONNECT proxy.
    pub proxy: Option<ProxyBridge>,
    /// The agent's resource limits.
    #[serde(default)]
    pub limits: Limits,
    /// Mechanism (the daemon chooses it with [`probe`]).
    pub kind: SandboxKind,
    /// Wait for a `go` line from the daemon on the lifeline before starting the agent ([`Running::go`]): the daemon
    /// gets time to bind the agent to the sandbox root (D-28) and make the run token valid before the agent's first
    /// instruction. EOF instead of `go` means the agent is not started.
    #[serde(default)]
    pub start_gate: bool,
    /// Resident agents: the agent's stdin is a pipe fed from the lifeline. After the start gate, every byte the daemon
    /// writes with [`Running::agent_input`] reaches the agent's stdin unchanged (Claude Code's stream-json input).
    /// `false`: the agent's stdin is `/dev/null`.
    #[serde(default)]
    pub agent_stdin: bool,
    /// The local model runtime (D-96 §3.4, D-104): the program only listens, on this one unix socket in a writable
    /// folder, and makes no outgoing connection at all. Linux: seccomp refuses `connect` and every socket but a unix
    /// stream socket, and stage 2 proves both from the inside before the `exec`; macOS: the profile allows binding
    /// this path and nothing else on the network. Requires `proxy: None`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listen: Option<PathBuf>,
    /// macOS: the Metal rules the runtime needs for the GPU (the GPU's IOKit user client and Metal's compiler
    /// service), unverified until checked on a Mac; ignored on Linux (CPU only).
    #[serde(default, skip_serializing_if = "is_false")]
    pub gpu: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// Bridge from the sandbox to the daemon proxy: the supervisor listens on `127.0.0.1:port` and passes every connection
/// to `unix`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProxyBridge {
    /// unix socket of the daemon proxy ([`start_proxy`]).
    pub unix: PathBuf,
    /// `127.0.0.1` port inside the sandbox. `0` means a free port (in Landlock mode the host network is shared, as
    /// intended).
    pub port: u16,
}

/// The agent's resource limits (rlimits; `0` means unchanged). Core dumps are always 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limits {
    /// Open descriptors (`RLIMIT_NOFILE`, at least 16).
    pub nofile: u64,
    /// File size, bytes (`RLIMIT_FSIZE`).
    pub fsize_bytes: u64,
    /// CPU time per process, seconds (`RLIMIT_CPU`; the hard limit is 5 s higher).
    pub cpu_secs: u64,
    /// Private writable memory, bytes (`RLIMIT_DATA`: on Linux it counts the heap and anonymous mappings, not a file
    /// mapped read-only, so it caps a model runtime's cache and buffers but not the model it maps). `0`: unchanged.
    /// Linux only (macOS does not enforce it; the daemon's memory watchdog is the guard there, D-P-12).
    #[serde(default)]
    pub data_bytes: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            nofile: 4096,
            fsize_bytes: 4 << 30,
            cpu_secs: 3600,
            data_bytes: 0,
        }
    }
}

/// What this machine supports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Support {
    /// The best available mechanism; `None` means the agent must not be started (fail closed).
    pub kind: Option<SandboxKind>,
    /// A trusted bwrap (system path, owned by root, not writable by group/others) that actually sets up namespaces.
    pub bwrap: Option<PathBuf>,
    /// The kernel's Landlock ABI (0: none).
    pub landlock_abi: i32,
    /// For humans: what was found, why something was refused, what is closed and what is not.
    pub detail: String,
}

/// Checks which sandbox is available. The result is cached per process; the first call starts bwrap for a functional
/// probe (up to ~1 s), so call it at daemon startup or from `spawn_blocking`.
///
/// bwrap is looked up ONLY in system paths (`/usr/bin/bwrap`, `/usr/local/bin/bwrap`, `/bin/bwrap`), not in `PATH`
/// (an agent with the same uid could plant its own); the file and its directory are owned by root and not writable by
/// group/others. macOS uses Seatbelt (D-P-13). Other OSes get `kind: None`.
pub fn probe() -> Support {
    #[cfg(target_os = "linux")]
    {
        linux::probe().support.clone()
    }
    #[cfg(target_os = "macos")]
    {
        macos::probe()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        Support {
            kind: None,
            bwrap: None,
            landlock_abi: 0,
            detail: "the agent sandbox exists only on Linux (bubblewrap/Landlock) and macOS (Seatbelt); agents \
                     are not started on wake"
                .into(),
        }
    }
}

/// A running agent.
pub struct Running {
    /// The daemon's direct child: bwrap or the supervisor (its own process group, `kill_on_drop`).
    pub child: tokio::process::Child,
    /// PID of [`Running::child`]; the daemon registers it as the agent anchor (the agent's process tree grows from it).
    pub pid: u32,
    /// The agent's stdout (the caller takes it with `.take()`).
    pub stdout: Option<tokio::process::ChildStdout>,
    /// The agent's stderr and the [`NOTE_PREFIX`] lines.
    pub stderr: Option<tokio::process::ChildStderr>,
    /// Lifeline: the supervisor runs while it is open.
    lifeline: Option<tokio::process::ChildStdin>,
    /// macOS: how to find this run's sandbox processes once the supervisor is gone (orphans under launchd).
    #[cfg(target_os = "macos")]
    sweep: Option<macos::Sweep>,
}

/// Starts the agent in the `spec.kind` sandbox. `supervisor_exe` is the absolute path of `antennad` (which is also the
/// supervisor: `antennad --antenna-wake-exec`). stdin/stdout/stderr are pipes; the spec is written as a line to stdin,
/// and stdin stays open as the lifeline.
///
/// Errors: `sandbox_unavailable` (no mechanism, bwrap did not start), `not_found` (no `argv[0]` or `supervisor_exe`),
/// `bad_request` (paths not absolute, etc.).
pub async fn launch(
    spec: &SandboxSpec,
    supervisor_exe: &std::path::Path,
) -> crate::error::Result<Running> {
    #[cfg(target_os = "linux")]
    {
        linux::launch(spec, supervisor_exe).await
    }
    #[cfg(target_os = "macos")]
    {
        macos::launch(spec, supervisor_exe).await
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = (spec, supervisor_exe);
        Err(crate::error::Error::new(
            antenna_proto::control::code::SANDBOX_UNAVAILABLE,
            probe().detail,
        ))
    }
}

/// A finished process's exit code, or `128 + n` for one a signal `n` ended (the shell's convention). Windows has no
/// signals: the code is always there.
pub(crate) fn exit_code(s: &std::process::ExitStatus) -> Option<i32> {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        s.code().or_else(|| s.signal().map(|n| 128 + n))
    }
    #[cfg(windows)]
    {
        s.code()
    }
}

impl Running {
    /// Allow the agent to start (with [`SandboxSpec::start_gate`]): a `go` line on the lifeline.
    pub async fn go(&mut self) -> crate::error::Result<()> {
        use tokio::io::AsyncWriteExt;
        let Some(l) = self.lifeline.as_mut() else {
            return Err(crate::error::Error::internal("sandbox: lifeline closed"));
        };
        l.write_all(b"go\n")
            .await
            .and(l.flush().await)
            .map_err(|e| crate::error::Error::internal(format!("sandbox: go: {e}")))
    }

    /// Stop: close the lifeline → the supervisor kills the whole agent tree and exits; if it has not exited within
    /// `grace`, SIGKILL all descendants of [`Running::pid`] and its process group. Returns when the direct child has
    /// exited.
    pub async fn stop(&mut self, grace: Duration) {
        self.lifeline.take();
        if tokio::time::timeout(grace, self.child.wait()).await.is_ok() {
            return;
        }
        self.kill_now();
        let _ = self.child.wait().await;
    }

    /// Write to the agent's stdin through the lifeline (only with [`SandboxSpec::agent_stdin`], after [`Running::go`]).
    pub async fn agent_input(&mut self, bytes: &[u8]) -> crate::error::Result<()> {
        use tokio::io::AsyncWriteExt;
        let Some(l) = self.lifeline.as_mut() else {
            return Err(crate::error::Error::internal("sandbox: lifeline closed"));
        };
        l.write_all(bytes)
            .await
            .and(l.flush().await)
            .map_err(|e| crate::error::Error::internal(format!("sandbox: agent input: {e}")))
    }

    /// Wait for the direct child to exit (the agent's code, [`EXIT_SANDBOX_FAILED`] or 128 + signal). The lifeline
    /// stays open until [`Running::stop`] or `drop`.
    pub async fn wait(&mut self) -> std::io::Result<std::process::ExitStatus> {
        self.child.wait().await
    }

    /// SIGKILL all descendants and the group of the direct child (it is not reaped yet, so its PID is not reused).
    fn kill_now(&mut self) {
        if let Ok(None) = self.child.try_wait() {
            #[cfg(target_os = "linux")]
            linux::kill_tree(self.pid);
            #[cfg(target_os = "macos")]
            macos::kill_tree(self.pid, self.sweep.as_ref());
            let _ = self.child.start_kill();
        }
    }
}

impl Drop for Running {
    /// The daemon abandoned the agent (without `stop`): the lifeline closes and the whole tree gets SIGKILL (in
    /// Landlock mode the supervisor would not have time to reap the descendants itself after `kill_on_drop`).
    fn drop(&mut self) {
        self.lifeline.take();
        self.kill_now();
    }
}
