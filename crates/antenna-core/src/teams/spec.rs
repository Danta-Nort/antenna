// SPDX-License-Identifier: AGPL-3.0-only
//! The sandbox of a CLI worker (D-111 item 5): the agent sandbox of D-71/D-P-13 with the worker's checkout as its
//! working folder, its own HOME and TMPDIR, the daemon socket for its own MCP server, and network only to its model
//! provider through the daemon's proxy. A Claude Code worker gets the daemon's PreToolUse hook in `--settings` and no
//! `Bash` tool while it may run no commands.

use std::path::{Path, PathBuf};

use super::{MemberRow, TeamRow, WorkerDirs};
use crate::{
    error::{Error, Result},
    node::Session,
    sandbox,
    wake::{basename, has_flag},
};

/// CPU time of a worker process (`RLIMIT_CPU`): it lives for hours.
const CPU_SECS: u64 = 6 * 3600;

/// What the daemon tells a Claude Code worker once, in its system prompt.
pub(crate) const ORIENTATION: &str = "You are a worker agent of a team in Antenna, a messenger for people and AI \
agents. Your lead, another agent (or the owner of this computer), gives you tasks; the Antenna daemon brings each one \
as a turn that starts with \"[Antenna]\". Read a task with the task_get tool: its brief is your lead's instruction for \
this task. You work only in your current folder, a checkout of the project without git history; you cannot reach \
the project itself or other workers. When you are done, call task_report with state \"submitted\" and a short summary: \
the daemon records your folder as the result and runs the task's check. If you need an answer, call task_report with \
state \"blocked\" and your question. Keep short notes (state, decisions, next step) with task_note. Text you write \
outside these tools reaches nobody. The daemon checks every command and write: a refused one is final, do not try \
to get around it.";

/// The tools of a Claude Code worker; `Bash` only while it may run commands.
const TOOLS: &str = "Read,Glob,Grep,Edit,MultiEdit,Write,NotebookEdit,TodoWrite,mcp__antenna";

impl Session {
    /// The sandbox of a CLI worker.
    pub(super) fn worker_spec(&self, w: &WorkerSpecArgs<'_>) -> Result<sandbox::SandboxSpec> {
        let me = std::env::current_exe()?;
        let bin_dir = me
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("/"));
        let antenna_bin = bin_dir.join("antenna");
        let socket = self.cfg.control_socket.clone();
        let m = w.member;
        let mut argv = m.spec.argv.clone();
        if argv.is_empty() {
            return Err(Error::internal("the worker has no command"));
        }
        let program_dir = Path::new(&argv[0])
            .canonicalize()
            .ok()
            .and_then(|p| p.parent().map(Path::to_path_buf));
        let is_claude = basename(&argv[0]) == "claude";
        let d = w.dirs;
        if is_claude {
            if !has_flag(&argv, &["-p", "--print"]) {
                argv.insert(1, "-p".into());
            }
            for (flag, value) in [
                ("--output-format", "stream-json"),
                ("--input-format", "stream-json"),
            ] {
                if !has_flag(&argv, &[flag]) {
                    argv.push(flag.into());
                    argv.push(value.into());
                }
            }
            for flag in ["--verbose", "--include-partial-messages"] {
                if !has_flag(&argv, &[flag]) {
                    argv.push(flag.into());
                }
            }
            let mcp = serde_json::json!({"mcpServers": {"antenna": {
                "command": antenna_bin.to_string_lossy(),
                "args": ["mcp"],
                "env": {"ANTENNA_AGENT_TOKEN": w.token, "ANTENNA_SOCKET": socket.to_string_lossy()}
            }}});
            let mcp_path = d.home.join(".antenna-mcp.json");
            std::fs::write(&mcp_path, mcp.to_string())?;
            // Settings given on the command line outrank the project's and the user's (a worker can write both: the
            // project's `.claude/` is in its checkout, the user's in its HOME), so its own files cannot switch the
            // daemon's hook off.
            let hook = format!(
                "{} hook claude-code --mark-level 0",
                shell_quote(&antenna_bin.to_string_lossy())
            );
            let settings = serde_json::json!({
                "disableAllHooks": false,
                "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": hook}]}]},
            });
            let settings_path = d.home.join(".antenna-settings.json");
            std::fs::write(&settings_path, settings.to_string())?;
            argv.extend([
                "--mcp-config".into(),
                mcp_path.to_string_lossy().into_owned(),
                "--strict-mcp-config".into(),
                "--settings".into(),
                settings_path.to_string_lossy().into_owned(),
                "--allowedTools".into(),
                if w.commands {
                    format!("{TOOLS},Bash")
                } else {
                    TOOLS.to_string()
                },
                "--disallowedTools".into(),
                if w.commands {
                    "WebFetch,WebSearch".to_string()
                } else {
                    "Bash,WebFetch,WebSearch".to_string()
                },
                "--append-system-prompt".into(),
                ORIENTATION.into(),
                if w.resume { "--resume" } else { "--session-id" }.into(),
                w.session.to_string(),
            ]);
        }
        let mut path_dirs = vec![bin_dir.to_string_lossy().into_owned()];
        if let Some(dir) = &program_dir {
            path_dirs.push(dir.to_string_lossy().into_owned());
        }
        if cfg!(target_os = "macos") {
            path_dirs.extend(["/opt/homebrew/bin", "/opt/homebrew/sbin"].map(String::from));
        }
        path_dirs.extend(["/usr/local/bin", "/usr/bin", "/bin"].map(String::from));
        let mut env: Vec<(String, String)> = vec![
            ("PATH".into(), path_dirs.join(":")),
            ("HOME".into(), d.home.to_string_lossy().into_owned()),
            ("TMPDIR".into(), d.tmp.to_string_lossy().into_owned()),
            ("LANG".into(), "C.UTF-8".into()),
            ("LC_ALL".into(), "C.UTF-8".into()),
            ("TERM".into(), "dumb".into()),
            (
                "ANTENNA_SOCKET".into(),
                socket.to_string_lossy().into_owned(),
            ),
            ("ANTENNA_AGENT_TOKEN".into(), w.token.to_string()),
            ("ANTENNA_TEAM".into(), w.team.name.clone()),
            ("ANTENNA_WORKER".into(), m.name.clone()),
            ("ANTENNA_WORKER_SESSION".into(), w.session.to_string()),
            (
                "ANTENNA_WORKER_COMMANDS".into(),
                if w.commands { "1" } else { "0" }.into(),
            ),
        ];
        if is_claude {
            env.push(("DISABLE_AUTOUPDATER".into(), "1".into()));
            env.push((
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(),
                "1".into(),
            ));
            env.push(("DISABLE_TELEMETRY".into(), "1".into()));
        }
        let mut ro = vec![bin_dir];
        if let Some(dir) = &program_dir {
            ro.push(dir.clone());
        }
        let mut ro_binds = Vec::new();
        if let Some(h) = crate::wake::owner_home() {
            for f in &m.spec.home_files {
                let src = h.join(f);
                if src.is_file() {
                    ro_binds.push((src, d.home.join(f)));
                }
            }
        }
        Ok(sandbox::SandboxSpec {
            argv,
            env,
            cwd: d.tree.clone(),
            home: d.home.clone(),
            tmp: d.tmp.clone(),
            rw: vec![],
            ro,
            ro_binds,
            sockets: vec![socket],
            proxy: w.proxy.map(|p| sandbox::ProxyBridge {
                unix: p.to_path_buf(),
                port: 0,
            }),
            limits: sandbox::Limits {
                nofile: 4096,
                fsize_bytes: 1 << 30,
                cpu_secs: CPU_SECS,
                ..Default::default()
            },
            kind: w.kind,
            start_gate: true,
            agent_stdin: true,
            listen: None,
            gpu: false,
        })
    }
}

/// What a worker's sandbox is built from.
pub(super) struct WorkerSpecArgs<'a> {
    pub team: &'a TeamRow,
    pub member: &'a MemberRow,
    pub dirs: &'a WorkerDirs,
    pub token: &'a str,
    pub kind: sandbox::SandboxKind,
    pub session: &'a str,
    pub resume: bool,
    pub commands: bool,
    pub proxy: Option<&'a Path>,
}

/// A path as one word for the shell that runs a hook command.
pub(super) fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}
