// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna connect`: an agent CLI session on this computer (a server in a terminal, a session in tmux) becomes its own
//! agent, the easy way (D-113). Each session gets its own agent with its own token file and reads only what is
//! addressed to it by name (D-91: `everyone` off), so at the contact's side each session is its own chat, and no
//! session reads another's. The owner's own CLI still reads everything: that is the owner, not a session.
//!
//! Claude Code: the Antenna MCP server is added for this project folder only with Claude Code's own command
//! (`claude mcp add --scope local`), after the owner saw the exact command; Antenna writes nothing into another
//! program's files itself (D-85). Codex keeps its MCP servers in one global file, so for a session of its own the
//! command line with the server is printed instead.
//!
//! The folder can be set up in the same step, from what the owner chooses (`--instructions`, `--git-name` with
//! `--git-email`, `--allow`; `setup.rs`): shown with the commands, done after the same yes.

use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use antenna_proto::control::{AgentInfo, AgentRequest, Reply, Request};
use clap::Args;

use crate::client::{CliResult, EXIT_FAIL, EXIT_USAGE, Fail, call_owner, socket_path};
use crate::{Cli, Pw};

/// `antenna connect`.
#[derive(Debug, Args)]
pub(crate) struct ConnectArgs {
    /// The agent CLI.
    #[arg(value_parser = ["claude-code", "codex"])]
    app: String,
    /// The agent's name, as your contacts see it and as its chat is called there (`antenna-dev`): one per session.
    #[arg(long)]
    agent: String,
    /// Links the agent sees (comma-separated contact labels); all by default.
    #[arg(long, value_delimiter = ',')]
    links: Option<Vec<String>>,
    /// Which local data the agent sees outside the daemon, as in `antenna agent add` (5: a coding agent in your own
    /// projects).
    #[arg(long, default_value_t = 5, value_parser = clap::value_parser!(u8).range(0..=5))]
    local_level: u8,
    /// The project folder whose Claude Code sessions are this agent (the current folder by default).
    #[arg(long)]
    dir: Option<PathBuf>,
    /// Only show what to run; change nothing in the agent CLI's settings.
    #[arg(long, conflicts_with = "yes")]
    print: bool,
    /// Run Claude Code's command without asking.
    #[arg(long, short = 'y')]
    yes: bool,
    /// Say hello to this contact as the agent, so that its chat appears there at once (a contact learns an agent
    /// when the agent first writes).
    #[arg(long, value_name = "CONTACT")]
    hello: Option<String>,
    /// What to set up in the folder, once, with the same yes.
    #[command(flatten)]
    setup: crate::setup::SetupArgs,
    #[command(flatten)]
    pw: Pw,
}

/// The agent, ready: its token file and whether it was made now.
struct Ready {
    token_file: String,
    created: bool,
    new_token: bool,
}

/// Runs `antenna connect`.
pub(crate) fn run(cli: &Cli, a: &ConnectArgs, rt: &tokio::runtime::Runtime) -> ExitCode {
    let mut r = rt.block_on(connect(cli, a));
    // No owner session in this terminal: the password once, as for any owner command (like `sudo`)
    if let Err(f) = &r
        && f.code == "login_required"
        && std::io::stdin().is_terminal()
    {
        r = match crate::login_from_terminal(rt, cli) {
            Ok(()) => rt.block_on(connect(cli, a)),
            Err(e) => Err(e),
        };
    }
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(f) => crate::print_fail(&f, cli.json, "connect"),
    }
}

async fn connect(cli: &Cli, a: &ConnectArgs) -> CliResult<()> {
    // Windows (D-135): the agent, its token file and Claude Code's own `mcp add` work as here; only the folder setup
    // waits for its Windows paths (phase W2), and `setup::plan` refuses it before anything is done.
    let path = socket_path(&cli.socket, &cli.data_dir);
    let ready = agent(&path, a).await?;
    let antenna = std::env::current_exe()
        .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("where is this antenna: {e}")))?;
    let antenna = antenna.to_string_lossy().to_string();
    let dir = match &a.dir {
        Some(d) => d.clone(),
        None => std::env::current_dir()
            .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("current folder: {e}")))?,
    };
    let steps = commands(&a.app, &antenna, &ready.token_file);
    let plan = if a.setup.any() {
        Some(crate::setup::plan(&a.agent, &a.app, Some(&dir), &a.setup)?)
    } else {
        None
    };
    let mut ran = false;
    let mut set_up = false;
    if a.app == "claude-code"
        && !a.print
        && (a.yes || ask_to_run(cli, a, &ready, &dir, &steps, plan.as_ref())?)
    {
        run_steps(&steps, &dir)?;
        ran = true;
        if let Some(p) = &plan {
            crate::setup::apply(p)?;
            set_up = true;
        }
    } else if a.app == "codex"
        && !a.print
        && let Some(p) = &plan
        && crate::setup::confirm(p, cli.json, a.yes, false)?
    {
        crate::setup::apply(p)?;
        set_up = true;
    }
    // The hello is the agent's message like any other: the daemon's policy applies (a contact below the agent's local
    // level asks the owner first, no write down). Held for approval is not a failure of the connection itself.
    let hello_state = match &a.hello {
        None => None,
        Some(contact) => match hello(&path, &ready.token_file, contact, &a.agent).await {
            Ok(()) => Some("sent".to_string()),
            Err(f) if f.code == "approval_required" => {
                let id = f
                    .approval
                    .as_ref()
                    .map(|x| x.id.clone())
                    .unwrap_or_default();
                if !cli.json {
                    eprintln!(
                        "The hello to {contact} waits for your approval (`antenna approve {id}`): its chat appears there once it is sent."
                    );
                }
                Some("approval_required".to_string())
            }
            Err(f) => return Err(f),
        },
    };
    if cli.json {
        crate::output::print_json(&serde_json::json!({
            "agent": a.agent,
            "app": a.app,
            "token_file": ready.token_file,
            "created": ready.created,
            "new_token": ready.new_token,
            "everyone": false,
            "dir": dir,
            "commands": steps,
            "ran": ran,
            "hello": hello_state,
            "setup": plan.as_ref().map(crate::setup::to_json),
            "set_up": set_up,
        }));
        return Ok(());
    }
    if !ran {
        report(a, &ready, &dir, &steps);
    }
    if let Some(p) = &plan {
        if set_up {
            println!("Done: {} is set up.", p.dir.display());
        } else if !p.steps.is_empty() {
            print!("{}", crate::setup::show(p));
            println!("The folder was not set up: run it in a terminal to confirm, or add --yes.");
        }
    }
    if ran {
        println!(
            "Done: Claude Code sessions in {} are the agent {} now (start or restart `claude` there).",
            dir.display(),
            a.agent
        );
    }
    Ok(())
}

/// The agent with its token file: made now (`everyone` off), the existing one with its token file as it is, or an
/// existing one without a file with a new token written to one (its old token stops working).
async fn agent(path: &Path, a: &ConnectArgs) -> CliResult<Ready> {
    let agents = match call_owner(path, Request::AgentList {}).await?.1 {
        Reply::Agents { agents } => agents,
        other => return Err(unexpected(&other)),
    };
    match agents.iter().find(|x| x.name == a.agent) {
        Some(AgentInfo {
            local_model: Some(_),
            ..
        }) => Err(Fail::new(
            EXIT_USAGE,
            "bad_request",
            format!(
                "{} is a local agent: the daemon runs it itself; choose another name",
                a.agent
            ),
        )),
        Some(x) => match &x.session.token_file {
            Some(f) => Ok(Ready {
                token_file: f.clone(),
                created: false,
                new_token: false,
            }),
            None => {
                let r = crate::owner::touch::call_pw(path, &a.pw, |password| Request::AgentToken {
                    name: a.agent.clone(),
                    password,
                    token_file: true,
                })
                .await?;
                Ok(Ready {
                    token_file: token_file_of(&r)?,
                    created: false,
                    new_token: true,
                })
            }
        },
        None => {
            let r = crate::owner::touch::call_pw(path, &a.pw, |password| Request::AgentAdd {
                name: a.agent.clone(),
                links: a.links.clone(),
                local_level: a.local_level,
                // A session reads only what is addressed to it by name: the privacy between sessions (D-91)
                everyone: false,
                password,
                token_file: true,
            })
            .await?;
            Ok(Ready {
                token_file: token_file_of(&r)?,
                created: true,
                new_token: true,
            })
        }
    }
}

/// The agent's first message to `contact`, to the person: the announcement of the agent goes before it (PROTOCOL
/// §21), so the contact's window shows the agent's chat at once. A fixed line: nothing of the owner's goes into it.
async fn hello(path: &Path, token_file: &str, contact: &str, agent: &str) -> CliResult<()> {
    let token = crate::read_token_file(Path::new(token_file))?;
    crate::client::call_agent(
        path,
        &crate::client::Auth::Agent {
            token,
            bind_parent: false,
        },
        AgentRequest::Send {
            contact: contact.to_string(),
            text: format!("{agent} is connected: write to it in this chat."),
            wait_ms: 2000,
            approval_id: None,
            to: Some("person".into()),
            to_agent: None,
            topic: Some(String::new()),
            topic_id: None,
            local: None,
        },
    )
    .await
    .map(|_| ())
}

fn token_file_of(r: &Reply) -> CliResult<String> {
    match r {
        Reply::AgentAdded {
            token_file: Some(f),
            ..
        } => Ok(f.clone()),
        other => Err(unexpected(other)),
    }
}

fn unexpected(r: &Reply) -> Fail {
    Fail::new(
        EXIT_FAIL,
        "protocol",
        format!("unexpected reply: {:?}", std::mem::discriminant(r)),
    )
}

/// What sets up the agent CLI: for Claude Code, its own commands for this folder (the old entry removed first, so a
/// second run replaces it); for Codex, the command line of a session.
fn commands(app: &str, antenna: &str, token_file: &str) -> Vec<Vec<String>> {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    match app {
        "codex" => vec![s(&[
            "codex",
            "-c",
            &format!(
                "mcp_servers.antenna.command={}",
                serde_json::Value::from(antenna)
            ),
            "-c",
            &format!(
                "mcp_servers.antenna.args={}",
                serde_json::json!(["mcp", "--token-file", token_file])
            ),
        ])],
        _ => vec![
            s(&["claude", "mcp", "remove", "--scope", "local", "antenna"]),
            s(&[
                "claude",
                "mcp",
                "add",
                "--scope",
                "local",
                "antenna",
                "--",
                antenna,
                "mcp",
                "--token-file",
                token_file,
            ]),
        ],
    }
}

/// A command for a terminal: arguments with spaces or quotes go in single quotes.
fn shell_line(argv: &[String]) -> String {
    argv.iter()
        .map(|a| {
            if !a.is_empty()
                && a.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_./=:@,+".contains(c))
            {
                a.clone()
            } else {
                format!("'{}'", a.replace('\'', r"'\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn intro(a: &ConnectArgs, ready: &Ready) {
    let what = if ready.created {
        "created"
    } else if ready.new_token {
        "has a new token (the old one stopped working)"
    } else {
        "exists; its token file stays as it is"
    };
    println!(
        "Agent {}: {what}. Token file: {}",
        a.agent, ready.token_file
    );
    println!(
        "It reads only messages addressed to it by name: your contacts write to it in its own chat (\"<this computer> · {}\").",
        a.agent
    );
}

/// The steps for the owner to run, when they were not run here.
fn report(a: &ConnectArgs, ready: &Ready, dir: &Path, steps: &[Vec<String>]) {
    intro(a, ready);
    if a.app == "codex" {
        println!("Start each Codex session of this agent with:");
    } else {
        println!("In {}, run:", dir.display());
    }
    for s in steps {
        println!("  {}", shell_line(s));
    }
}

/// Shows the exact commands and asks; without a terminal nothing runs (the steps are printed instead).
fn ask_to_run(
    cli: &Cli,
    a: &ConnectArgs,
    ready: &Ready,
    dir: &Path,
    steps: &[Vec<String>],
    plan: Option<&crate::setup::Plan>,
) -> CliResult<bool> {
    if cli.json || !std::io::stdin().is_terminal() {
        return Ok(false);
    }
    intro(a, ready);
    println!(
        "Claude Code will add the Antenna server for {} only (its own setting, your files untouched):",
        dir.display()
    );
    for s in steps {
        println!("  {}", shell_line(s));
    }
    if let Some(p) = plan.filter(|p| !p.steps.is_empty()) {
        print!("{}", crate::setup::show(p));
    }
    print!("Run this now? [y/N] ");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| Fail::new(EXIT_FAIL, "io", e.to_string()))?;
    Ok(matches!(line.trim(), "y" | "Y" | "yes"))
}

/// Runs the steps in `dir`. The first (removing an older entry) may fail: there was none.
fn run_steps(steps: &[Vec<String>], dir: &Path) -> CliResult<()> {
    for (i, s) in steps.iter().enumerate() {
        let st = std::process::Command::new(&s[0])
            .args(&s[1..])
            .current_dir(dir)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            // A step before the last may fail by design ("No MCP server named antenna" on a first connect): its
            // complaint is noise for the person, so only the last step's errors reach the terminal.
            .stderr(if i + 1 < steps.len() {
                std::process::Stdio::null()
            } else {
                std::process::Stdio::inherit()
            })
            .status();
        match st {
            Ok(st) if st.success() || i + 1 < steps.len() => {}
            Ok(st) => {
                return Err(Fail::new(
                    EXIT_FAIL,
                    "connect_failed",
                    format!("`{}` ended with {st}", shell_line(s)),
                ));
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(Fail::new(
                    EXIT_FAIL,
                    "connect_failed",
                    format!(
                        "{} is not on PATH here; run the steps yourself: {}",
                        s[0],
                        steps
                            .iter()
                            .map(|x| shell_line(x))
                            .collect::<Vec<_>>()
                            .join(" && ")
                    ),
                ));
            }
            Err(e) => {
                return Err(Fail::new(
                    EXIT_FAIL,
                    "connect_failed",
                    format!("{}: {e}", s[0]),
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_code_gets_its_own_command_for_this_folder_only() {
        let c = commands(
            "claude-code",
            "/opt/antenna/bin/antenna",
            "/home/a/.local/share/antenna/agents/dev.token",
        );
        assert_eq!(c.len(), 2);
        assert_eq!(
            c[0],
            ["claude", "mcp", "remove", "--scope", "local", "antenna"]
        );
        assert_eq!(
            shell_line(&c[1]),
            "claude mcp add --scope local antenna -- /opt/antenna/bin/antenna mcp --token-file \
             /home/a/.local/share/antenna/agents/dev.token"
        );
    }

    #[test]
    fn codex_gets_a_session_command_line_with_the_token_file() {
        let c = commands("codex", "/opt/antenna/bin/antenna", "/tmp/x y/dev.token");
        assert_eq!(c.len(), 1);
        assert_eq!(
            c[0][2],
            r#"mcp_servers.antenna.command="/opt/antenna/bin/antenna""#
        );
        assert_eq!(
            c[0][4],
            r#"mcp_servers.antenna.args=["mcp","--token-file","/tmp/x y/dev.token"]"#
        );
        assert!(
            shell_line(&c[0]).contains(
                r#"'mcp_servers.antenna.args=["mcp","--token-file","/tmp/x y/dev.token"]'"#
            )
        );
    }

    #[test]
    fn shell_lines_quote_what_a_shell_would_split() {
        let v = |x: &[&str]| x.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            shell_line(&v(&["a", "b c", "it's", ""])),
            r#"a 'b c' 'it'\''s' ''"#
        );
    }
}
