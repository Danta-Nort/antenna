// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna session run`: the process tmux runs in a session's pane. It is the pane's session leader, like the
//! window's bash wrapper in Code mode (`agent_launch.dart`), and forks the agent CLI, so the CLI, not a session
//! leader, becomes the MCP host the daemon binds the token to (D-28). It is also the CLI's parent, which is what
//! `agent_watch` asks of the process that reads the agent's facts (CONTROL §23). It writes nothing into the pane while
//! the CLI runs (the screen is the CLI's); its log is `<root>/<agent>/wake.log`.
//!
//! The CLI inherits only the pane's terminal: tmux closes every other descriptor before it starts the pane, and Rust
//! and tokio open theirs close-on-exec. Its environment is the kept list (`tmux::ENV_KEEP`), the terminal's variables,
//! the token file's path and the daemon's socket; never the token itself, which stays in the file (D-86).

use std::{
    ffi::OsString,
    io::Write,
    path::{Path, PathBuf},
    process::ExitCode,
    time::{Duration, Instant},
};

use antenna_proto::control::{ClientMsg, Event, Request, ServerMsg};
use serde_json::json;
use tokio::sync::mpsc;

use super::{
    Spec,
    hooks::{CODEX_HOOKS_VAR, HookDir, HookEvent, claude_settings, codex_hook_overrides},
    now_ms,
    tmux::{Tmux, kept_env},
    waker::{Action, Cli, Fact, LogEntry, Timing, Waker},
};
use crate::client::{Auth, CliResult, Conn, Fail};

/// What `session list` shows for the last event the CLI reported.
pub(crate) fn state_word(e: HookEvent) -> &'static str {
    match e {
        HookEvent::Start
        | HookEvent::Stop
        | HookEvent::NotifyIdle
        | HookEvent::TurnComplete
        | HookEvent::Interrupt => "idle",
        HookEvent::Prompt | HookEvent::Tool | HookEvent::ToolDone | HookEvent::Continued => {
            "working"
        }
        HookEvent::Permission | HookEvent::NotifyPermission => "dialog",
        HookEvent::End => "ended",
    }
}

/// Enter goes this long after the text, as a keypress of its own: Claude Code reads text and a carriage return that
/// arrive together as a paste and inserts a line break instead of sending (D-UI-23 item 7).
const ENTER_AFTER: Duration = Duration::from_millis(300);

/// How often the waker looks at the hooks, the facts and, while something waits, the pane.
const POLL: Duration = Duration::from_millis(250);

/// The Antenna MCP server for Claude Code's `--mcp-config` (this one process only). No token: `antenna mcp` reads
/// the token file's path from the environment Claude Code passes on to it.
fn claude_mcp_config(antenna: &Path) -> String {
    json!({"mcpServers": {"antenna": {"type": "stdio", "command": antenna, "args": ["mcp"]}}})
        .to_string()
}

/// The CLI's arguments: the Antenna MCP server and the session-only hooks first (Claude Code), or Codex's `-c`
/// overrides with its `notify` program, then the owner's own arguments, then the session to continue.
pub(crate) fn cli_args(spec: &Spec, cli: Cli, hooks: &HookDir) -> Vec<String> {
    let mut a = Vec::new();
    match cli {
        Cli::Claude => {
            a.extend([
                "--mcp-config".into(),
                claude_mcp_config(&spec.antenna),
                "--strict-mcp-config".into(),
                "--settings".into(),
                claude_settings(&spec.antenna, hooks).to_string(),
            ]);
            if let Some(id) = &spec.resume {
                a.extend(["--resume".into(), id.clone()]);
            }
            a.extend(spec.args.iter().cloned());
        }
        Cli::Codex => {
            let antenna =
                serde_json::to_string(&spec.antenna.to_string_lossy()).unwrap_or_default();
            let notify = serde_json::to_string(&hooks.notify_argv()).unwrap_or_default();
            for o in [
                format!("mcp_servers.antenna.command={antenna}"),
                r#"mcp_servers.antenna.args=["mcp"]"#.into(),
                "mcp_servers.antenna.env={}".into(),
                r#"mcp_servers.antenna.env_vars=["ANTENNA_AGENT_TOKEN_FILE", "ANTENNA_SOCKET"]"#
                    .into(),
                format!("notify={notify}"),
            ] {
                a.extend(["-c".into(), o]);
            }
            // The state hooks (Codex 0.160 and later): Codex asks the owner to trust them once, at the first start
            a.extend(codex_hook_overrides());
            a.extend(spec.args.iter().cloned());
            if let Some(id) = &spec.resume {
                a.extend(["resume".into(), id.clone()]);
            }
        }
    }
    a
}

/// The UTF-8 locale of the pane, or `C.UTF-8`.
fn utf8_lang() -> OsString {
    for k in ["LC_ALL", "LC_CTYPE", "LANG"] {
        if let Some(v) = std::env::var_os(k)
            && v.to_string_lossy()
                .to_uppercase()
                .replace('-', "")
                .contains("UTF8")
        {
            return v;
        }
    }
    "C.UTF-8".into()
}

/// The CLI's environment (see the module comment).
pub(crate) fn cli_env(spec: &Spec, hooks: &Path) -> Vec<(OsString, OsString)> {
    let mut env: Vec<(OsString, OsString)> = kept_env(std::env::vars_os())
        .into_iter()
        .filter(|(k, _)| k != "PATH" && k != "LANG")
        .collect();
    for k in ["TERM", "COLORTERM", "TMUX", "TMUX_PANE"] {
        if let Some(v) = std::env::var_os(k) {
            env.push((k.into(), v));
        }
    }
    let mut path: Vec<PathBuf> = spec
        .program
        .parent()
        .map(Path::to_path_buf)
        .into_iter()
        .collect();
    path.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    path.extend(["/usr/bin", "/bin"].map(PathBuf::from));
    let mut seen = std::collections::BTreeSet::new();
    path.retain(|p| p.is_absolute() && seen.insert(p.clone()));
    env.push((
        "PATH".into(),
        std::env::join_paths(path).unwrap_or_default(),
    ));
    env.push(("LANG".into(), utf8_lang()));
    env.push((
        "ANTENNA_AGENT_TOKEN_FILE".into(),
        spec.token_file.clone().into_os_string(),
    ));
    env.push((
        "ANTENNA_SOCKET".into(),
        spec.socket.clone().into_os_string(),
    ));
    // Codex's hooks find their folder through this variable (`codex_hook_overrides`)
    env.push((CODEX_HOOKS_VAR.into(), hooks.as_os_str().to_os_string()));
    env
}

/// Append one line to the session's log (who, why and when; never a message's text). The log keeps its last 256 KiB.
fn log_line(dir: &Path, agent: &str, e: &LogEntry) {
    let p = dir.join("wake.log");
    if std::fs::metadata(&p).is_ok_and(|m| m.len() > 256 * 1024) {
        let _ = std::fs::rename(&p, dir.join("wake.log.1"));
    }
    let line = json!({
        "at_ms": now_ms(), "agent": agent, "kind": e.kind.word(), "contact": e.contact, "continued": e.continued,
    });
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&p)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Record how the session ended (for `session start` and `session list`).
fn record_exit(dir: &Path, code: Option<i32>, error: Option<String>) {
    let v = json!({"code": code, "error": error, "at_ms": now_ms()});
    let _ = std::fs::write(dir.join("exit"), v.to_string());
}

/// One `agent_watch` subscription: facts into `tx` until the daemon ends it.
async fn watch_once(
    socket: &Path,
    agent: &str,
    tx: &mpsc::UnboundedSender<Fact>,
    dir: &Path,
) -> CliResult<()> {
    let mut c = Conn::open(socket, &Auth::Owner).await?;
    c.send(&ClientMsg::Req(Request::AgentWatch {
        agent: agent.to_string(),
    }))
    .await?;
    loop {
        let f = match c.recv().await? {
            ServerMsg::Event(Event::Subscribed { .. }) => {
                let _ = std::fs::write(dir.join("watch"), "watching");
                continue;
            }
            // The owner's urgent message, as the daemon honoured it (PG-58): interrupt, then the urgent line
            ServerMsg::Event(Event::MessageFact {
                contact,
                id,
                urgent: true,
                ..
            }) => Fact::Urgent { contact, id },
            ServerMsg::Event(Event::MessageFact { contact, .. }) => Fact::Message(contact),
            ServerMsg::Event(Event::Approval { approval }) if approval.state == "approved" => {
                Fact::Approved(approval.id)
            }
            ServerMsg::Event(Event::ApprovalResolved(r))
                if matches!(r.state.as_str(), "completed" | "approved") =>
            {
                Fact::Approved(r.id)
            }
            // The owner answered or set aside one of the agent's questions (D-118)
            ServerMsg::Event(Event::Escalation(e)) => Fact::Answered(e.id),
            // A request this agent may answer as an approver (PG-57)
            ServerMsg::Event(Event::ApprovalToAnswer(f)) => Fact::ToAnswer(f.id),
            ServerMsg::Err(e) => return Err(Fail::from_daemon(e)),
            ServerMsg::Ok(_) => return Ok(()),
            _ => continue,
        };
        if tx.send(f).is_err() {
            return Ok(());
        }
    }
}

/// Tell the daemon this pane's process leads the agent's terminal session (`agent_terminal`, CONTROL §33), so the
/// owner's stop switch sweeps the session whole (PG-58). Said again at every new watch: the daemon keeps it in memory.
async fn say_terminal(socket: &Path, agent: &str) {
    let Ok(mut c) = Conn::open(socket, &Auth::Owner).await else {
        return;
    };
    let _ = c
        .send(&ClientMsg::Req(Request::AgentTerminal(
            antenna_proto::control::AgentTerminal {
                agent: agent.to_string(),
                pid: std::process::id() as i32,
            },
        )))
        .await;
    let _ = c.recv().await;
}

/// The agent's facts for as long as the session runs: until the CLI's MCP server binds the token the daemon answers
/// `not_found` or `forbidden`; after a lock, `locked`; the subscription is opened again each time.
async fn watch(socket: PathBuf, agent: String, tx: mpsc::UnboundedSender<Fact>, dir: PathBuf) {
    loop {
        say_terminal(&socket, &agent).await;
        let r = watch_once(&socket, &agent, &tx, &dir).await;
        if tx.is_closed() {
            return;
        }
        let why = match r {
            Ok(()) => "closed".to_string(),
            Err(f) => f.code,
        };
        // What stopped the watch, for `session list` (`not_found`/`forbidden` until the CLI's MCP server binds the
        // token, `locked` while the keys are locked).
        let _ = std::fs::write(dir.join("watch"), &why);
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

/// The waker: hooks, facts and the pane in, lines out.
async fn wake_loop(
    spec: &Spec,
    cli: Cli,
    mut hooks: HookDir,
    pane: String,
    tmux: Tmux,
) -> std::convert::Infallible {
    let dir = hooks.dir().to_path_buf();
    let (tx, mut rx) = mpsc::unbounded_channel();
    // Ends with the runtime, when the CLI has exited.
    tokio::spawn(watch(
        spec.socket.clone(),
        spec.agent.clone(),
        tx,
        dir.clone(),
    ));
    let mut w = Waker::new(cli, Timing::default(), Instant::now());
    let mut tick = tokio::time::interval(POLL);
    let mut shown = String::new();
    loop {
        tick.tick().await;
        let now = Instant::now();
        let on = !dir.join("wake-off").exists();
        if on != w.on && w.set_on(on) {
            hooks.withdraw_continue();
        }
        for e in hooks.read_events() {
            if let Some(entry) = w.on_hook(e, now) {
                log_line(&dir, &spec.agent, &entry);
            }
        }
        while let Ok(f) = rx.try_recv() {
            w.on_fact(f);
        }
        let screen = if w.pending() {
            tmux.screen(&pane).await
        } else {
            None
        };
        let unavailable = screen.as_ref().is_some_and(|(s, _)| w.unavailable(now, s));
        let status = json!({
            "state": w.tracker.state.word(), "pending": w.pending(), "wake": w.on, "unavailable": unavailable,
            "hold": w.hold.map(|h| h.word()),
        })
        .to_string();
        if status != shown {
            let _ = std::fs::write(dir.join("status"), &status);
            shown = status;
        }
        let Some((screen, key_s)) = screen else {
            continue;
        };
        match w.decide(now, Some(&screen), key_s, now_ms() / 1000) {
            Action::None => {}
            Action::Offer(line) => {
                if !hooks.offer_continue(&line.stop_continuation()) {
                    w.offer_failed();
                }
            }
            Action::Interrupt(key) => {
                // An interrupted turn ends without its Stop hook: a line left there would be taken by the next turn's
                // end instead, so it is taken back; the urgent line is typed at the prompt
                if w.offered() {
                    hooks.withdraw_continue();
                }
                if tmux.send_key(&pane, key).await {
                    let entry = w.interrupted(Instant::now());
                    log_line(&dir, &spec.agent, &entry);
                } else {
                    w.offer_failed();
                }
            }
            Action::Type(line) => {
                // A line left for the Stop hook is taken back first; if the hook already took it, the turn goes on
                // by itself (its `continued` event follows).
                if w.offered() && !hooks.withdraw_continue() {
                    continue;
                }
                if tmux.send_text(&pane, line.text()).await {
                    tokio::time::sleep(ENTER_AFTER).await;
                    let entered = tmux.send_enter(&pane).await;
                    let entry = w.typed(Instant::now());
                    if entered {
                        log_line(&dir, &spec.agent, &entry);
                    }
                } else {
                    // tmux refused (the pane is gone): the next look decides again
                    w.offer_failed();
                }
            }
        }
    }
}

/// The pane's process. Exits with the CLI's exit code.
pub(crate) fn run(root: &Path, agent: &str) -> ExitCode {
    let dir_buf = root.join(agent);
    let dir: &Path = &dir_buf;
    let fail = |why: String| {
        // The pane is still ours here: say it there too, then let `session start` read it.
        record_exit(dir, None, Some(why.clone()));
        eprintln!("antenna session: {why}");
        std::thread::sleep(Duration::from_secs(2));
        ExitCode::from(1)
    };
    let Some(spec) = std::fs::read_to_string(dir.join("spec.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<Spec>(&s).ok())
    else {
        return fail(format!("no session record at {}", dir.display()));
    };
    let Some(cli) = Cli::parse(&spec.cli) else {
        return fail(format!("unknown CLI {:?}", spec.cli));
    };
    let Ok(pane) = std::env::var("TMUX_PANE") else {
        return fail("not inside a tmux pane".into());
    };
    let hooks = HookDir::open(dir);
    let args = cli_args(&spec, cli, &hooks);
    let env = cli_env(&spec, dir);
    let tmux = Tmux {
        bin: spec.tmux.clone(),
        socket: root.join("tmux.sock"),
        conf: root.join("tmux.conf"),
    };
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => return fail(format!("runtime: {e}")),
    };
    rt.block_on(async move {
        // On Linux the CLI runs under a child subreaper (PG-58, `reap.rs`), so what it starts and orphans stays in this
        // process's tree for the owner's stop switch; macOS has none, the CLI is started directly
        let mut cmd = if cfg!(target_os = "linux") {
            let mut c = tokio::process::Command::new(&spec.antenna);
            c.arg(super::reap::MODE).arg(&spec.program);
            c
        } else {
            tokio::process::Command::new(&spec.program)
        };
        let mut child = match cmd
            .args(&args)
            .env_clear()
            .envs(env)
            .current_dir(&spec.dir)
            .spawn()
        {
            Ok(c) => c,
            Err(e) => return fail(format!("cannot start {}: {e}", spec.program.display())),
        };
        use tokio::signal::unix::{SignalKind, signal};
        let (Ok(mut hup), Ok(mut term), Ok(mut int), Ok(mut quit)) = (
            signal(SignalKind::hangup()),
            signal(SignalKind::terminate()),
            signal(SignalKind::interrupt()),
            signal(SignalKind::quit()),
        ) else {
            let _ = child.start_kill();
            return fail("cannot handle signals".into());
        };
        let pid = child.id();
        let waker = wake_loop(&spec, cli, hooks, pane, tmux);
        tokio::pin!(waker);
        let status = loop {
            tokio::select! {
                s = child.wait() => break s.ok(),
                n = &mut waker => match n {},
                // The terminal is the CLI's: Ctrl-C and Ctrl-\ are its keys, not a reason for the pane to go.
                _ = int.recv() => {}
                _ = quit.recv() => {}
                _ = hup.recv() => break stop_child(&mut child, pid).await,
                _ = term.recv() => break stop_child(&mut child, pid).await,
            }
        };
        let _ = HookDir::open(dir).withdraw_continue();
        let code = status.and_then(|s| {
            use std::os::unix::process::ExitStatusExt;
            s.code().or_else(|| s.signal().map(|n| 128 + n))
        });
        record_exit(dir, code, None);
        ExitCode::from(code.unwrap_or(1).clamp(0, 255) as u8)
    })
}

/// The session is closing: the CLI gets SIGHUP (as when its terminal closes), then SIGKILL after 3 s.
async fn stop_child(
    child: &mut tokio::process::Child,
    pid: Option<u32>,
) -> Option<std::process::ExitStatus> {
    if let Some(p) = pid.and_then(|p| rustix::process::Pid::from_raw(p as i32)) {
        let _ = rustix::process::kill_process(p, rustix::process::Signal::HUP);
    }
    match tokio::time::timeout(Duration::from_secs(3), child.wait()).await {
        Ok(s) => s.ok(),
        Err(_) => {
            let _ = child.start_kill();
            child.wait().await.ok()
        }
    }
}
