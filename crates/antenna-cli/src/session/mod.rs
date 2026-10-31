// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna session` (D-108, PG-22, experimental): an agent CLI session (Claude Code, Codex) that runs inside tmux on
//! a server, or on any computer without the window, and is woken by Antenna the way the window's Code mode wakes its
//! terminals (D-UI-23, D-UI-25): the agent CLI's own hooks for the state, built-in lines only, never into a permission
//! dialog or over a person's draft, at most one line per 30 s, a per-agent switch, a log.
//!
//! - `start <agent> [--dir <folder>] [--cli claude|codex] [--resume] [-- <the CLI's own arguments>]`: a tmux session on
//!   Antenna's private socket (`<data-dir>/sessions/tmux.sock`) runs `antenna session run`, which starts the CLI with
//!   the agent's token file in its environment (never the token itself, never on a command line), the Antenna MCP
//!   server and the session-only hooks on its command line, and watches it;
//! - `list`, `attach <agent>` (the owner's terminal joins the session; Ctrl-b d leaves it running), `stop <agent>`,
//!   `wake <agent> on|off`.
//!
//! It is not a daemon command: the daemon sees an ordinary agent (its MCP host bound to the token, D-28), and the
//! waker reads the agent's own facts through `agent_watch` (CONTROL §23), as the window does after an update. It is
//! part of the owner CLI only: with an agent token there is no `session` command, and a process inside an agent's
//! tree cannot start one (the daemon says so at hello: `forced`).

// The scripts are also what `antenna hook-signal` is checked against (`hook_signal.rs`, T11).
pub(crate) mod hooks;
mod keys;
mod lines;
mod pane;
pub(crate) mod reap;
mod screen;
mod tmux;
mod waker;

use std::{
    io::IsTerminal,
    path::{Path, PathBuf},
    process::ExitCode,
    time::{Duration, Instant},
};

use clap::{Args, Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::client::{Auth, CliResult, Conn, EXIT_FAIL, EXIT_NOPERM, EXIT_USAGE, Fail};
use crate::output::{clean, print_json};
use crate::{Cli, print_fail};

pub(crate) use hooks::HookDir;
use tmux::{Tmux, find_program, find_tmux, session_name};
use waker::Cli as AgentCli;

/// `antenna session …`.
#[derive(Debug, Subcommand)]
pub(crate) enum SessionCommand {
    /// Start an agent CLI session in tmux, woken by Antenna when the agent has something to read (experimental).
    Start(StartArgs),
    /// The sessions Antenna started on this computer: running or not, the CLI's state, the wake switch, the last line.
    List,
    /// Attach this terminal to an agent's session (detach with Ctrl-b d; the session keeps running).
    Attach {
        /// Agent name.
        agent: String,
    },
    /// Stop an agent's session (the CLI gets SIGHUP, as when its terminal closes).
    Stop {
        /// Agent name.
        agent: String,
    },
    /// Turn the wake of an agent's session on or off (on by default; no password: it never widens what the agent
    /// can do).
    Wake {
        /// Agent name.
        agent: String,
        /// `on` / `off`.
        #[arg(value_parser = ["on", "off"])]
        state: String,
    },
    /// The process tmux runs in the session's pane: starts the CLI and wakes it (started by `session start`).
    #[command(hide = true)]
    Run {
        /// Agent name.
        agent: String,
        /// The sessions folder.
        #[arg(long)]
        root: PathBuf,
    },
}

/// Which agent CLI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub(crate) enum CliKind {
    /// Claude Code.
    Claude,
    /// Codex.
    Codex,
}

/// `antenna session start`.
#[derive(Debug, Args)]
pub(crate) struct StartArgs {
    /// Agent name: an agent with a token file (`antenna agent add <name> --local-level N --token-file`).
    agent: String,
    /// The folder the CLI works in (default: this one).
    #[arg(long)]
    dir: Option<PathBuf>,
    /// Which CLI runs.
    #[arg(long, value_enum, default_value = "claude")]
    cli: CliKind,
    /// The CLI's program (default: `claude` or `codex` from PATH and the usual install folders).
    #[arg(long)]
    program: Option<PathBuf>,
    /// The agent's token file (default: `<data-dir>/agents/<agent>.token`, written by the daemon).
    #[arg(long)]
    token_file: Option<PathBuf>,
    /// Continue the CLI's last session for this agent (`claude --resume <id>`, `codex resume <id>`), as recorded by
    /// its hooks.
    #[arg(long)]
    resume: bool,
    /// Start with the wake off (`antenna session wake <agent> on` turns it on).
    #[arg(long)]
    no_wake: bool,
    /// Attach this terminal right away.
    #[arg(long)]
    attach: bool,
    /// The tmux program (default: `tmux` from PATH).
    #[arg(long)]
    tmux: Option<PathBuf>,
    /// The CLI's own arguments, after `--`.
    #[arg(last = true)]
    args: Vec<String>,
}

/// The record of one session (`<root>/<agent>/spec.json`), written by `start`, read by `run` and `list`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Spec {
    /// Agent name.
    pub agent: String,
    /// `claude` or `codex`.
    pub cli: String,
    /// The CLI's program, absolute.
    pub program: PathBuf,
    /// The CLI's own arguments.
    pub args: Vec<String>,
    /// The folder it works in.
    pub dir: PathBuf,
    /// The agent's token file.
    pub token_file: PathBuf,
    /// The daemon's control socket.
    pub socket: PathBuf,
    /// This `antenna`.
    pub antenna: PathBuf,
    /// The tmux program.
    pub tmux: PathBuf,
    /// The tmux session name.
    pub session: String,
    /// The CLI session to continue.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<String>,
    /// When it was started, Unix ms.
    pub started_ms: u64,
}

pub(crate) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The folder of the node's sessions: `<data-dir>/sessions` (the data directory from `--data-dir`, else the folder of
/// `--socket`, else the default one).
fn root_of(cli: &Cli) -> PathBuf {
    let data = cli
        .data_dir
        .clone()
        .or_else(|| {
            cli.socket
                .as_ref()
                .and_then(|s| s.parent().map(Path::to_path_buf))
        })
        .unwrap_or_else(antenna_proto::local::default_data_dir);
    data.join("sessions")
}

/// `name` is an agent name (`[A-Za-z0-9._-]{1,64}`, CONTROL §4): it becomes a folder name and a tmux session name.
fn check_agent(name: &str) -> CliResult<()> {
    let ok = !name.is_empty()
        && name.len() <= 64
        && name != "."
        && name != ".."
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    if ok {
        Ok(())
    } else {
        Err(Fail::new(
            EXIT_USAGE,
            "bad_request",
            "agent name: 1–64 characters of [A-Za-z0-9._-]",
        ))
    }
}

fn private_dir(p: &Path) -> CliResult<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(p)
        .and_then(|()| std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700)))
        .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("io: {}: {e}", p.display())))
}

/// Antenna's tmux server for this node (the socket path must fit `sun_path`).
fn tmux_of(root: &Path, explicit: Option<&Path>) -> CliResult<Tmux> {
    let bin = find_tmux(explicit).ok_or_else(|| {
        Fail::new(
            EXIT_FAIL,
            "tmux_missing",
            "tmux is not installed on this computer: install it with the system's package manager (for example \
             `sudo apt install tmux`, `sudo dnf install tmux`, `brew install tmux`), then start the session again",
        )
    })?;
    let socket = root.join("tmux.sock");
    let max = if cfg!(target_os = "linux") { 107 } else { 103 };
    if socket.as_os_str().len() > max {
        return Err(Fail::new(
            EXIT_FAIL,
            "bad_request",
            format!(
                "the sessions socket {} is longer than this OS allows ({max} bytes): use a shorter --data-dir",
                socket.display()
            ),
        ));
    }
    Ok(Tmux {
        bin,
        socket,
        conf: root.join("tmux.conf"),
    })
}

/// Runs one `antenna session` command.
pub(crate) fn run(cli: &Cli, cmd: &SessionCommand) -> ExitCode {
    if let SessionCommand::Run { agent, root } = cmd {
        return pane::run(root, agent);
    }
    if let SessionCommand::Attach { agent } = cmd {
        let r = attach(cli, agent);
        return match r {
            Ok(()) => ExitCode::SUCCESS,
            Err(f) => print_fail(&f, cli.json, "session attach"),
        };
    }
    let (name, r) = match cmd {
        SessionCommand::Start(a) => ("session start", start(cli, a)),
        SessionCommand::List => ("session list", list(cli)),
        SessionCommand::Stop { agent } => ("session stop", stop(cli, agent)),
        SessionCommand::Wake { agent, state } => ("session wake", wake(cli, agent, state == "on")),
        SessionCommand::Attach { .. } | SessionCommand::Run { .. } => unreachable!("handled above"),
    };
    match r {
        Ok((v, text)) => {
            if cli.json {
                print_json(&v);
            } else {
                println!("{text}");
            }
            if let SessionCommand::Start(a) = cmd
                && a.attach
                && std::io::stdin().is_terminal()
            {
                return match attach(cli, &a.agent) {
                    Ok(()) => ExitCode::SUCCESS,
                    Err(f) => print_fail(&f, cli.json, "session attach"),
                };
            }
            ExitCode::SUCCESS
        }
        Err(f) => print_fail(&f, cli.json, name),
    }
}

/// The daemon must answer, and this process must not be inside an agent's process tree: an agent cannot start a
/// session for itself or another agent (the daemon gives such a process the agent role at hello, D-28).
fn check_owner_side(socket: &Path) -> CliResult<()> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("runtime: {e}")))?;
    let hello = rt.block_on(async { Conn::open(socket, &Auth::Owner).await.map(|c| c.hello) })?;
    if hello.forced {
        return Err(Fail::new(
            EXIT_NOPERM,
            "forbidden",
            format!(
                "this process runs inside the process tree of agent {:?}: an agent cannot start agent sessions; run \
                 antenna session start from a separate terminal",
                hello.agent.as_deref().unwrap_or("?")
            ),
        ));
    }
    Ok(())
}

/// The CLI's program: `--program`, else `claude`/`codex` in PATH or the usual install folders.
fn find_cli(kind: CliKind, explicit: Option<&Path>) -> CliResult<PathBuf> {
    if let Some(p) = explicit {
        let abs = std::fs::canonicalize(p)
            .map_err(|e| Fail::new(EXIT_FAIL, "not_found", format!("{}: {e}", p.display())))?;
        return Ok(abs);
    }
    let name = match kind {
        CliKind::Claude => "claude",
        CliKind::Codex => "codex",
    };
    let home = std::env::var("HOME").unwrap_or_default();
    let extra = [
        format!("{home}/.local/bin"),
        format!("{home}/.claude/local"),
        format!("{home}/.npm-global/bin"),
        "/opt/homebrew/bin".into(),
        "/usr/local/bin".into(),
    ];
    let extra: Vec<&str> = extra.iter().map(String::as_str).collect();
    find_program(name, &extra).ok_or_else(|| {
        Fail::new(
            EXIT_FAIL,
            "not_found",
            format!("{name} is not installed or not on PATH: install it (the vendor's guide), or give --program <path>"),
        )
    })
}

fn start(cli: &Cli, a: &StartArgs) -> CliResult<(Value, String)> {
    check_agent(&a.agent)?;
    let root = root_of(cli);
    let socket = crate::client::socket_path(&cli.socket, &cli.data_dir);
    check_owner_side(&socket)?;
    let socket = std::path::absolute(&socket).unwrap_or(socket);
    let token_file = a.token_file.clone().unwrap_or_else(|| {
        root.parent()
            .unwrap_or(&root)
            .join("agents")
            .join(format!("{}.token", a.agent))
    });
    // The token file must be one the CLI accepts (owned by this user, 0600, a token in it); the token stays in it.
    crate::read_token_file(&token_file).map_err(|mut f| {
        if !token_file.exists() {
            f.message = format!(
                "agent {:?} has no token file at {}: the owner writes it with `antenna agent add {} --local-level N \
                 --token-file` or `antenna agent token {} --token-file`",
                a.agent,
                token_file.display(),
                a.agent,
                a.agent
            );
        }
        f
    })?;
    let program = find_cli(a.cli, a.program.as_deref())?;
    let dir = match &a.dir {
        Some(d) => d.clone(),
        None => std::env::current_dir()
            .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("io: {e}")))?,
    };
    let dir = std::fs::canonicalize(&dir)
        .ok()
        .filter(|d| d.is_dir())
        .ok_or_else(|| {
            Fail::new(
                EXIT_FAIL,
                "not_found",
                format!("no such folder: {}", dir.display()),
            )
        })?;
    private_dir(&root)?;
    let tmux = tmux_of(&root, a.tmux.as_deref())?;
    std::fs::write(&tmux.conf, tmux::TMUX_CONF).map_err(|e| {
        Fail::new(
            EXIT_FAIL,
            "internal",
            format!("io: {}: {e}", tmux.conf.display()),
        )
    })?;
    let name = session_name(&a.agent);
    if tmux.has_session(&name) {
        return Err(Fail::new(
            EXIT_FAIL,
            "already_running",
            format!(
                "a session for agent {:?} is already running: antenna session attach {}",
                a.agent, a.agent
            ),
        ));
    }
    let adir = root.join(&a.agent);
    let hooks = HookDir::prepare(&adir).map_err(|e| {
        Fail::new(
            EXIT_FAIL,
            "internal",
            format!("io: {}: {e}", adir.display()),
        )
    })?;
    let resume = if a.resume {
        Some(hooks.session_id().ok_or_else(|| {
            Fail::new(
                EXIT_FAIL,
                "not_found",
                format!(
                    "no earlier session of agent {:?} is recorded here to resume",
                    a.agent
                ),
            )
        })?)
    } else {
        None
    };
    let _ = std::fs::remove_file(adir.join("exit"));
    let off = adir.join("wake-off");
    if a.no_wake {
        let _ = std::fs::write(&off, b"");
    }
    let antenna = std::env::current_exe()
        .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("io: {e}")))?;
    let spec = Spec {
        agent: a.agent.clone(),
        cli: match a.cli {
            CliKind::Claude => AgentCli::Claude.word().into(),
            CliKind::Codex => AgentCli::Codex.word().into(),
        },
        program,
        args: a.args.clone(),
        dir: dir.clone(),
        token_file: std::path::absolute(&token_file).unwrap_or(token_file),
        socket,
        antenna: antenna.clone(),
        tmux: tmux.bin.clone(),
        session: name.clone(),
        resume,
        started_ms: now_ms(),
    };
    let text = serde_json::to_string_pretty(&spec)
        .map_err(|e| Fail::new(EXIT_FAIL, "internal", e.to_string()))?;
    std::fs::write(adir.join("spec.json"), text)
        .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("io: {e}")))?;
    let argv = [
        antenna.into_os_string(),
        "session".into(),
        "run".into(),
        a.agent.clone().into(),
        "--root".into(),
        root.clone().into_os_string(),
    ];
    let pane = tmux.new_session(&name, &dir, &argv, &[]).map_err(|e| {
        Fail::new(
            EXIT_FAIL,
            "tmux_failed",
            format!("tmux could not start the session: {e}"),
        )
    })?;
    // The pane's process writes `exit` when the CLI could not start or ended at once: say why here.
    let t = Instant::now();
    while t.elapsed() < Duration::from_millis(1500) {
        if let Ok(s) = std::fs::read_to_string(adir.join("exit")) {
            let v: Value = serde_json::from_str(&s).unwrap_or_default();
            return Err(Fail::new(
                EXIT_FAIL,
                "start_failed",
                format!(
                    "the session ended right away: {}",
                    v["error"]
                        .as_str()
                        .map(clean)
                        .unwrap_or_else(|| format!("exit code {}", v["code"]))
                ),
            ));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let wake = !off.exists();
    let v = json!({
        "agent": a.agent, "session": name, "pane": pane, "cli": spec.cli, "dir": dir,
        "wake": wake, "resumed": spec.resume.is_some(), "socket": tmux.socket,
    });
    let text = format!(
        "Started {} for agent {:?} in tmux session {name} ({}).\nAttach: antenna session attach {}   (leave it \
         running: Ctrl-b d)\nWake on new messages: {} (antenna session wake {} {}; experimental)",
        spec.cli,
        a.agent,
        dir.display(),
        a.agent,
        if wake { "on" } else { "off" },
        a.agent,
        if wake { "off" } else { "on" },
    );
    Ok((v, text))
}

fn read_spec(adir: &Path) -> Option<Spec> {
    serde_json::from_str(&std::fs::read_to_string(adir.join("spec.json")).ok()?).ok()
}

fn list(cli: &Cli) -> CliResult<(Value, String)> {
    let root = root_of(cli);
    let mut rows = Vec::new();
    let mut text = String::new();
    let tmux = tmux_of(&root, None).ok();
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)
        .map(|r| {
            r.flatten()
                .map(|e| e.path())
                .filter(|p| p.join("spec.json").is_file())
                .collect()
        })
        .unwrap_or_default();
    dirs.sort();
    for d in dirs {
        let Some(spec) = read_spec(&d) else { continue };
        let running = tmux.as_ref().is_some_and(|t| t.has_session(&spec.session));
        let status: Value = std::fs::read_to_string(d.join("status"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let state = if !running {
            "stopped".to_string()
        } else if let Some(s) = status["state"].as_str() {
            s.to_string()
        } else {
            HookDir::last_event(&d)
                .map(pane::state_word)
                .unwrap_or("unknown")
                .to_string()
        };
        let unavailable = running && status["unavailable"].as_bool() == Some(true);
        let watch = std::fs::read_to_string(d.join("watch")).unwrap_or_default();
        let wake = !d.join("wake-off").exists();
        let last = std::fs::read_to_string(d.join("wake.log"))
            .ok()
            .and_then(|s| {
                s.lines()
                    .last()
                    .and_then(|l| serde_json::from_str::<Value>(l).ok())
            });
        let exit: Option<Value> = std::fs::read_to_string(d.join("exit"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok());
        text.push_str(&format!(
            "{}  {}  {}  {}  wake {}{}{}\n",
            spec.agent,
            spec.cli,
            if running { "running" } else { "stopped" },
            state,
            if wake { "on" } else { "off" },
            if unavailable {
                " (unavailable for this CLI version: nothing is typed)"
            } else {
                ""
            },
            last.as_ref()
                .map(|l| format!(
                    "  last line: {}{} {}",
                    l["kind"].as_str().unwrap_or("?"),
                    l["contact"]
                        .as_str()
                        .map(|c| format!(" from {}", clean(c)))
                        .unwrap_or_default(),
                    crate::output::ago(l["at_ms"].as_u64().unwrap_or(0))
                ))
                .unwrap_or_default()
        ));
        rows.push(json!({
            "agent": spec.agent, "cli": spec.cli, "session": spec.session, "dir": spec.dir,
            "running": running, "state": state, "wake": wake, "started_ms": spec.started_ms,
            "unavailable": unavailable, "watch": watch.trim(),
            "last_line": last, "exit": exit,
        }));
    }
    if rows.is_empty() {
        text = "No agent sessions on this computer (antenna session start <agent>).".into();
    }
    Ok((json!({ "sessions": rows }), text.trim_end().to_string()))
}

fn agent_dir(cli: &Cli, agent: &str) -> CliResult<(PathBuf, Spec)> {
    check_agent(agent)?;
    let d = root_of(cli).join(agent);
    let spec = read_spec(&d).ok_or_else(|| {
        Fail::new(
            EXIT_FAIL,
            "not_found",
            format!("no session of agent {agent:?} on this computer"),
        )
    })?;
    Ok((d, spec))
}

fn attach(cli: &Cli, agent: &str) -> CliResult<()> {
    let (d, spec) = agent_dir(cli, agent)?;
    let tmux = tmux_of(d.parent().unwrap_or(&d), Some(&spec.tmux))?;
    if !tmux.has_session(&spec.session) {
        return Err(Fail::new(
            EXIT_FAIL,
            "not_found",
            format!("the session of agent {agent:?} is not running"),
        ));
    }
    if !std::io::stdin().is_terminal() {
        return Err(Fail::new(
            EXIT_USAGE,
            "bad_request",
            "attach needs a terminal",
        ));
    }
    let e = tmux.attach(&spec.session);
    Err(Fail::new(
        EXIT_FAIL,
        "tmux_failed",
        format!("tmux attach: {e}"),
    ))
}

fn stop(cli: &Cli, agent: &str) -> CliResult<(Value, String)> {
    let (d, spec) = agent_dir(cli, agent)?;
    let tmux = tmux_of(d.parent().unwrap_or(&d), Some(&spec.tmux))?;
    let was = tmux.has_session(&spec.session) && tmux.kill_session(&spec.session);
    // The pane's process stops the CLI (SIGHUP, then SIGKILL after 3 s) and records its end.
    let t = Instant::now();
    while was && t.elapsed() < Duration::from_secs(5) && !d.join("exit").exists() {
        std::thread::sleep(Duration::from_millis(100));
    }
    let text = if was {
        format!("Stopped the session of agent {agent:?}.")
    } else {
        format!("The session of agent {agent:?} was not running.")
    };
    Ok((json!({"agent": agent, "stopped": was}), text))
}

fn wake(cli: &Cli, agent: &str, on: bool) -> CliResult<(Value, String)> {
    let (d, _) = agent_dir(cli, agent)?;
    let off = d.join("wake-off");
    let r = if on {
        std::fs::remove_file(&off).or_else(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                Ok(())
            } else {
                Err(e)
            }
        })
    } else {
        std::fs::write(&off, b"")
    };
    r.map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("io: {e}")))?;
    Ok((
        json!({"agent": agent, "wake": on}),
        format!(
            "Wake on new messages for agent {agent:?}: {}.",
            if on { "on" } else { "off" }
        ),
    ))
}
