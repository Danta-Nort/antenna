// SPDX-License-Identifier: AGPL-3.0-only
//! Agent wake (SPEC §11, D-67…D-71) and resident sessions (D-93).

use std::path::Path;

use antenna_proto::control::{
    ClientMsg, Event, Reply, Request, SecretEnv, SecretString, ServerMsg,
};

use super::Owner;
use crate::client::{Auth, CliResult, Conn, EXIT_FAIL, EXIT_USAGE, Fail, explain_forced};
use crate::output;
use crate::{
    WakeSayArgs, WakeSessionArgs, WakeSetArgs, absolute_path, owner_pw, parse_duration,
    read_line_stdin, read_password,
};

/// `antenna wake set`.
pub(super) async fn set(o: &Owner, a: &WakeSetArgs) -> CliResult<Reply> {
    let argv = match (&a.cmd, a.argv.is_empty()) {
        (Some(c), true) => split_command(c)?,
        (None, false) => a.argv.clone(),
        _ => {
            return Err(Fail::new(
                EXIT_USAGE,
                "bad_request",
                "give the agent command either with --cmd \"…\" or after `--`",
            ));
        }
    };
    // With --password-stdin the password is the first line, before the secrets' values (as always)
    let password = if a.pw.password_stdin {
        Some(owner_pw(&a.pw)?)
    } else {
        None
    };
    let mut secrets = Vec::new();
    for name in &a.secret_env {
        let v = if a.pw.password_stdin {
            read_line_stdin()?
        } else {
            read_password(&format!("Value of {name} (not shown): "))?
        };
        secrets.push(SecretEnv {
            name: name.clone(),
            value: SecretString(v.to_string()),
        });
    }
    let timeout_secs = Some(parse_duration(&a.timeout)?.as_secs().max(1));
    let idle_stop_secs = match &a.idle_stop {
        Some(d) => Some(parse_duration_or_zero(d)?),
        None => None,
    };
    let compact_idle_secs = match &a.compact_idle {
        Some(d) => Some(parse_duration_or_zero(d)?),
        None => None,
    };
    let project = a.project.as_deref().map(absolute_path).transpose()?;
    let tool_paths = a
        .tool_paths
        .iter()
        .map(|p| absolute_path(p))
        .collect::<CliResult<Vec<_>>>()?;
    let set = |password: String| Request::WakeSet {
        secret_env: secrets.clone(),
        contact: a.contact.clone(),
        argv: argv.clone(),
        agent: a.agent.clone(),
        timeout_secs,
        allow_hosts: a.allow_hosts.clone(),
        home_files: if a.no_home_files {
            Some(vec![])
        } else if a.home_files.is_empty() {
            None
        } else {
            Some(a.home_files.clone())
        },
        max_runs_per_hour: a.max_per_hour,
        resident: a.resident,
        idle_stop_secs,
        compact_idle_secs,
        compact_above_tokens: a.compact_above,
        project: project.clone(),
        tool_paths: tool_paths.clone(),
        env: a.env.clone(),
        password,
    };
    match password {
        Some(p) => o.call(set(p)).await,
        None => o.call_pw(&a.pw, set).await,
    }
}

/// `antenna wake say`.
pub(super) async fn say(o: &Owner, a: &WakeSayArgs) -> CliResult<Reply> {
    let text = match a.text.as_deref() {
        None | Some("-") => {
            let mut t = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut t)
                .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("stdin: {e}")))?;
            t
        }
        Some(t) => t.to_string(),
    };
    say_dialog(
        &o.path,
        Request::WakeSay {
            contact: a.contact.clone(),
            text,
            to_contact: a.to_contact,
            interrupt: a.interrupt,
            timeout_ms: Some(parse_duration(&a.timeout)?.as_millis() as u64),
        },
        o.json,
    )
    .await
}

/// `antenna wake session`.
pub(super) async fn session(o: &Owner, a: &WakeSessionArgs) -> CliResult<Reply> {
    let session = |password: Option<String>| Request::WakeSession {
        contact: a.contact.clone(),
        action: a.action.clone(),
        password,
    };
    if a.action == "reset" {
        o.call_pw(&a.pw, |p| session(Some(p))).await
    } else {
        o.call(session(None)).await
    }
}

/// `antenna wake off`.
pub(super) async fn off(o: &Owner, contact: &str) -> CliResult<Reply> {
    o.call(Request::WakeOff {
        contact: contact.to_string(),
    })
    .await
}

/// One-line command → arguments: quotes and `\` as in a shell, no expansion (no shell is started).
pub(crate) fn split_command(s: &str) -> CliResult<Vec<String>> {
    let bad = |m: &str| Fail::new(EXIT_USAGE, "bad_request", format!("--cmd: {m}"));
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                in_word = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some(x) => cur.push(x),
                        None => return Err(bad("unterminated single quote")),
                    }
                }
            }
            '"' => {
                in_word = true;
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some('\\') => match chars.next() {
                            Some(x @ ('"' | '\\' | '$' | '`')) => cur.push(x),
                            Some(x) => {
                                cur.push('\\');
                                cur.push(x);
                            }
                            None => return Err(bad("unterminated double quote")),
                        },
                        Some(x) => cur.push(x),
                        None => return Err(bad("unterminated double quote")),
                    }
                }
            }
            '\\' => {
                in_word = true;
                match chars.next() {
                    Some(x) => cur.push(x),
                    None => return Err(bad("trailing backslash")),
                }
            }
            c if c.is_whitespace() => {
                if in_word {
                    out.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            c => {
                in_word = true;
                cur.push(c);
            }
        }
    }
    if in_word {
        out.push(cur);
    }
    if out.is_empty() {
        return Err(bad("empty command"));
    }
    Ok(out)
}

/// `0` (off) or a duration, in seconds.
fn parse_duration_or_zero(s: &str) -> CliResult<u64> {
    if s.trim() == "0" {
        return Ok(0);
    }
    Ok(parse_duration(s)?.as_secs().max(1))
}

/// `antenna wake say`: the owner's turn in a resident session; the reply is printed as it streams.
async fn say_dialog(path: &Path, req: Request, json: bool) -> CliResult<Reply> {
    use std::io::Write as _;
    let mut c = Conn::open(path, &Auth::Owner).await?;
    c.send(&ClientMsg::Req(req)).await?;
    loop {
        match c.recv().await? {
            ServerMsg::Event(e @ Event::ResidentDelta { .. }) => {
                if json {
                    output::print_json(&e);
                } else if let Event::ResidentDelta {
                    delta, activity, ..
                } = &e
                {
                    let mut out = std::io::stdout();
                    let _ = write!(out, "{}", output::clean_text(delta));
                    let _ = out.flush();
                    if let Some(a) = activity {
                        eprintln!("[{}]", output::clean(a));
                    }
                }
            }
            ServerMsg::Ok(r) => return Ok(r),
            ServerMsg::Err(e) => return Err(explain_forced(&c.hello, Fail::from_daemon(e))),
            _ => {}
        }
    }
}
