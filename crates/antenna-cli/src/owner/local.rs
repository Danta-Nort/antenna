// SPDX-License-Identifier: AGPL-3.0-only
//! Local models and local agents (CONTROL §24, D-104): `antenna local …` for a node without the window.

use std::time::{Duration, Instant};

use antenna_proto::control::{ClientMsg, Event, Reply, Request, ServerMsg};

use super::Owner;
use crate::client::{Auth, CliResult, Conn, EXIT_FAIL, Fail, explain_forced};
use crate::output;
use crate::{LocalAddArgs, LocalInstallArgs, LocalSayArgs, parse_duration};

/// `antenna local install`: start the download (or the check of `--from-file`); with `--wait`, follow it to the end.
pub(super) async fn install(o: &Owner, a: &LocalInstallArgs) -> CliResult<Reply> {
    let from_file = match &a.from_file {
        Some(p) => Some(
            std::path::absolute(p)
                .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("{}: {e}", p.display())))?
                .to_string_lossy()
                .into_owned(),
        ),
        None => None,
    };
    let r = o
        .call(Request::ModelInstall {
            model: a.model.clone(),
            from_file,
        })
        .await?;
    if !a.wait {
        return Ok(r);
    }
    let limit = Instant::now() + parse_duration(&a.timeout)?;
    let mut last = String::new();
    loop {
        let Reply::LocalModels(all) = o.call(Request::LocalModels {}).await? else {
            return Err(Fail::new(EXIT_FAIL, "internal", "unexpected reply"));
        };
        let Some(m) = all.models.into_iter().find(|m| m.id == a.model) else {
            return Err(Fail::new(
                EXIT_FAIL,
                "not_found",
                "the model left the catalog",
            ));
        };
        match m.state.as_str() {
            "ready" => return Ok(Reply::LocalModel(m)),
            "failed" => {
                return Err(Fail::new(
                    EXIT_FAIL,
                    m.error_code.as_deref().unwrap_or("internal"),
                    m.error.unwrap_or_default(),
                ));
            }
            "available" => {
                return Err(Fail::new(EXIT_FAIL, "internal", "the download stopped"));
            }
            s => {
                let line = format!(
                    "{s} {:.1} of {:.1} GB",
                    m.done_bytes as f64 / 1e9,
                    m.size_bytes as f64 / 1e9
                );
                if !o.json && line != last {
                    eprintln!("{line}");
                    last = line;
                }
            }
        }
        if Instant::now() > limit {
            return Err(Fail::new(
                EXIT_FAIL,
                "timeout",
                "the download goes on (antenna local models)",
            ));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// `antenna local add`.
pub(super) async fn add(o: &Owner, a: &LocalAddArgs) -> CliResult<Reply> {
    o.call_pw(&a.pw, |password| Request::LocalAgentAdd {
        name: a.name.clone(),
        model: a.model.clone(),
        password,
    })
    .await
}

/// `antenna local say`: the owner's turn; the reply is printed as it streams.
pub(super) async fn say(o: &Owner, a: &LocalSayArgs) -> CliResult<Reply> {
    use std::io::Write as _;
    let text = match a.text.as_deref() {
        None | Some("-") => {
            let mut t = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut t)
                .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("stdin: {e}")))?;
            t
        }
        Some(t) => t.to_string(),
    };
    let mut c = Conn::open(&o.path, &Auth::Owner).await?;
    c.send(&ClientMsg::Req(Request::LocalSay {
        agent: a.agent.clone(),
        text,
        interrupt: a.interrupt,
        timeout_ms: Some(parse_duration(&a.timeout)?.as_millis() as u64),
    }))
    .await?;
    loop {
        match c.recv().await? {
            ServerMsg::Event(e @ Event::LocalDelta { .. }) => {
                if o.json {
                    output::print_json(&e);
                } else if let Event::LocalDelta {
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
