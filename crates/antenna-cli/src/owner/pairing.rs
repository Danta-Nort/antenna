// SPDX-License-Identifier: AGPL-3.0-only
//! Pairing: invites, joining, and the invites the daemon holds (Q-7).

use std::io::IsTerminal;
use std::path::Path;

use antenna_proto::control::{ClientMsg, Event, Input, Reply, Request, ServerMsg};

use super::Owner;
use crate::client::{Auth, CliResult, Conn, EXIT_USAGE, Fail, explain_forced};
use crate::output::{self, SasView};
use crate::{
    InviteArgs, JoinArgs, PairingArgs, PairingConfirmArgs, Pw, ask, confirm_level_5,
    not_implemented, owner_pw, parse_duration,
};

/// `antenna invite`.
pub(super) async fn invite(o: &Owner, a: &InviteArgs) -> CliResult<Reply> {
    if a.code {
        return Err(not_implemented(
            "invite --code",
            "short PAKE codes are planned for v0.3 (TZ §17)",
        ));
    }
    let ttl = parse_duration(&a.ttl)?;
    confirm_level_5(a.trust, a.yes, &a.pw)?;
    let build = |password: String| Request::Invite {
        trust: a.trust,
        ttl_secs: ttl.as_secs().max(1),
        label: a.label.clone(),
        auto_confirm: a.confirm,
        follow: !a.detach,
        password,
    };
    let first = match super::touch::prove(&o.path, &a.pw, &build(String::new())).await? {
        Some(line) => First::Line(line),
        None => First::Req(Box::new(build(owner_pw(&a.pw)?))),
    };
    pairing_dialog(&o.path, first, o.json, a.sas).await
}

/// `antenna join`.
pub(super) async fn join(o: &Owner, a: &JoinArgs) -> CliResult<Reply> {
    // A link in any form (https://antenna.contact/#…, antenna://pair#…, x://pair#…) is parsed by the daemon;
    // a short code to read out (PAKE) comes in v0.3.
    if !(a.link_or_code.contains("://") || a.link_or_code.contains('#')) {
        return Err(not_implemented(
            "join <code>",
            "short PAKE codes are planned for v0.3; use the invite link (https://antenna.contact/#…)",
        ));
    }
    confirm_level_5(a.trust, a.yes, &a.pw)?;
    let connect_timeout_ms = parse_duration(&a.connect_timeout)?.as_millis() as u64;
    let build = |password: String| Request::Join {
        link: a.link_or_code.clone(),
        trust: a.trust,
        label: a.label.clone(),
        sas_code: a.sas_code.clone(),
        connect_timeout_ms,
        password,
    };
    let first = match super::touch::prove(&o.path, &a.pw, &build(String::new())).await? {
        Some(line) => First::Line(line),
        None => First::Req(Box::new(build(owner_pw(&a.pw)?))),
    };
    pairing_dialog(&o.path, first, o.json, SasView::Digits).await
}

/// `antenna pairing [list]`.
pub(super) async fn list(o: &Owner, p: &PairingArgs) -> CliResult<Reply> {
    let timeout_ms = match &p.timeout {
        Some(t) => Some(parse_duration(t)?.as_millis() as u64),
        None => None,
    };
    let pairings = |password: Option<String>| Request::Pairings {
        wait: p.wait,
        timeout_ms,
        password,
    };
    if p.reveal {
        let pw = Pw {
            password_stdin: p.password_stdin,
            touch_id: false,
        };
        o.call_pw(&pw, |x| pairings(Some(x))).await
    } else {
        o.call(pairings(None)).await
    }
}

/// `antenna pairing confirm`.
pub(super) async fn confirm(o: &Owner, a: &PairingConfirmArgs) -> CliResult<Reply> {
    let (id, pw) = (&a.id, &a.pw);
    // Once the other person's node reported the correct code, this command is the owner's assent and needs no code
    // (D-95). The daemon still asks for the code (`code_required`) when another invite showed a code at the same time:
    // a spoken "match" does not name the invite then (PROTOCOL §15, F-4). The CLI never fills the code in itself.
    let code = a
        .code
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(str::to_string);
    let r = o
        .call_pw(pw, |password| Request::PairingConfirm {
            id: id.clone(),
            code: code.clone(),
            password,
        })
        .await;
    match r {
        Err(f) if f.code == "code_required" && code.is_none() => {
            if !std::io::stdin().is_terminal() || pw.password_stdin {
                return Err(Fail::new(
                    f.exit,
                    "code_required",
                    format!("{}; pass --code with the code you read out", f.message),
                ));
            }
            eprintln!("{}.", f.message);
            let c = ask(
                "Type the code you read out and the other person confirmed (6 digits or the animals): ",
                o.json,
            )
            .await?;
            let c = c.trim().to_string();
            if c.is_empty() {
                return Err(Fail::new(EXIT_USAGE, "bad_request", "no code entered"));
            }
            o.call_pw(pw, |password| Request::PairingConfirm {
                id: id.clone(),
                code: Some(c.clone()),
                password,
            })
            .await
        }
        r => r,
    }
}

/// `antenna pairing cancel`.
pub(super) async fn cancel(o: &Owner, id: &str, pw: &Pw) -> CliResult<Reply> {
    o.call_pw(pw, |password| Request::PairingCancel {
        id: id.to_string(),
        password,
    })
    .await
}

/// The request that opens a pairing dialog: with the password in it, or as the line with an owner proof (D-131).
enum First {
    Req(Box<Request>),
    Line(String),
}

/// `invite` and `join` follow the pairing on one connection: the daemon's events are printed, and its questions (the
/// code, the confirmation) are answered from the terminal.
async fn pairing_dialog(path: &Path, first: First, json: bool, view: SasView) -> CliResult<Reply> {
    let mut c = Conn::open(path, &Auth::Owner).await?;
    let hello = c.hello.clone();
    match first {
        First::Req(req) => c.send(&ClientMsg::Req(*req)).await?,
        First::Line(line) => c.send_line(&line).await?,
    }
    loop {
        match c.recv().await.map_err(|f| explain_forced(&hello, f))? {
            ServerMsg::Event(e) => {
                if json {
                    output::print_json(&e);
                } else {
                    output::human_event(&e, view);
                }
                if let Event::InputRejected { code, .. } = &e {
                    // Wrong code, or a code is needed after all: ask again (the invite is still alive).
                    let prompt = if code == "code_required" {
                        "Another invite showed a code at the same time, so type the code you read out and the other \
                         person confirmed, or `no` to reject: "
                    } else {
                        "That is not the code of this invite. Type the code again, or `no` to reject: "
                    };
                    let a = ask(prompt, json).await?;
                    c.send(&ClientMsg::Input(confirm_answer(&a))).await?;
                    continue;
                }
                if let Event::NeedInput {
                    what,
                    confirm_without_code,
                } = &e
                {
                    let input = match what.as_str() {
                        "confirm" => {
                            // The other person's node reported the correct code. When no other invite showed a code
                            // meanwhile, the owner's `yes` is the assent (D-95); otherwise the owner types the code they
                            // read out. The CLI never fills the code in (F-6: a "yes" in the wrong terminal would
                            // confirm someone else's invite); the daemon decides whether a "yes" alone is enough.
                            let prompt = if *confirm_without_code {
                                "When they tell you the codes match, type `yes` to create the link (or `no` to reject): "
                            } else {
                                "Type the code you read out and the other person confirmed (6 digits or the animals), \
                                 or `no` to reject: "
                            };
                            confirm_answer(&ask(prompt, json).await?)
                        }
                        "sas_code" => {
                            let code = ask(
                                "Enter the code the inviter reads to you (6 digits or the 6 animals): ",
                                json,
                            )
                            .await?;
                            Input::SasCode {
                                code: code.trim().to_string(),
                            }
                        }
                        _ => continue,
                    };
                    c.send(&ClientMsg::Input(input)).await?;
                }
            }
            ServerMsg::Ok(r) => return Ok(r),
            ServerMsg::Err(e) => return Err(explain_forced(&hello, Fail::from_daemon(e))),
            ServerMsg::HelloOk(_) => {}
        }
    }
}

/// The owner's answer to the confirmation question: `yes` (the daemon decides whether that is enough, D-95), `no` or
/// nothing (reject), or the code they read out (checked against this invite's code).
fn confirm_answer(a: &str) -> Input {
    let a = a.trim();
    if a.eq_ignore_ascii_case("yes") || a.eq_ignore_ascii_case("y") {
        Input::Confirm {
            yes: true,
            code: None,
        }
    } else if a.is_empty() || a.eq_ignore_ascii_case("no") {
        Input::Confirm {
            yes: false,
            code: None,
        }
    } else {
        Input::Confirm {
            yes: true,
            code: Some(a.to_string()),
        }
    }
}
