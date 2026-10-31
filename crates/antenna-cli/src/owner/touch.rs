// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's confirmation of one command in the terminal (D-131): one touch when the window turned Touch ID on for
//! this daemon on this Mac (`crate::touch_id`), the password otherwise and whenever the touch does not go through.
//! The daemon checks the proof (SPEC §9); a failure is never "allowed", it asks for the password. `--password-stdin`
//! never touches Touch ID: scripts keep the password.

use std::io::IsTerminal;
use std::path::Path;

use antenna_proto::control::{OwnerProof, Reply, Request};

use crate::client::{CliResult, EXIT_FAIL, Fail, call_owner, call_owner_line};
use crate::touch_id::{TouchId, reason_for};
use crate::{Pw, owner_pw};

/// A daemon refusal that sends the owner to the password, and the line that says why.
pub(crate) fn touch_refused(f: &Fail) -> Option<&'static str> {
    match f.code.as_str() {
        "password_required" => Some(
            "Antenna asks for your password this time (every 14 days, and after three failed Touch ID attempts).",
        ),
        "owner_key_unknown" | "owner_key_refused" => {
            Some("This Mac's Touch ID key is not enrolled with this daemon: use your password.")
        }
        "proof_invalid" | "challenge_invalid" => {
            Some("The Touch ID proof was refused: use your password.")
        }
        _ => None,
    }
}

/// Touch ID applies to this command: not a script (`--password-stdin`), a terminal or `--touch-id`, a command the
/// daemon takes a proof for, and Touch ID turned on here.
fn touch_for(path: &Path, pw: &Pw, req: &Request) -> Option<TouchId> {
    if pw.password_stdin || !(pw.touch_id || std::io::stdin().is_terminal()) || !req.accepts_proof()
    {
        return None;
    }
    let t = TouchId::find(path);
    if t.is_none() && pw.touch_id {
        eprintln!("Touch ID is not on for this daemon on this computer: use your password.");
    }
    t
}

/// [req] (its password fields empty) with a proof, as the line to send: the challenge first, so a daemon that wants
/// the password says so before any Touch ID sheet, then one touch. `None`: use the password (Touch ID does not apply,
/// or the touch did not go through; the reason is printed).
pub(crate) async fn prove(path: &Path, pw: &Pw, req: &Request) -> CliResult<Option<String>> {
    let Some(t) = touch_for(path, pw, req) else {
        return Ok(None);
    };
    let nonce = match call_owner(path, Request::OwnerChallenge { enroll: false }).await {
        Ok((_, Reply::OwnerChallenge(c))) => c.nonce,
        Ok(_) => {
            return Err(Fail::new(
                EXIT_FAIL,
                "protocol",
                "unexpected reply to owner_challenge",
            ));
        }
        Err(f) => match touch_refused(&f) {
            Some(why) => {
                eprintln!("{why}");
                return Ok(None);
            }
            None => return Err(f),
        },
    };
    let text = serde_json::to_string(req)
        .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("request: {e}")))?;
    let reason = reason_for(&crate::this_command_words());
    let sig = match t
        .start()
        .and_then(|mut h| h.sign(&nonce, &text, &reason, false))
    {
        Ok(s) => s,
        Err(e) => {
            if let Some(n) = e.note() {
                eprintln!("{n}");
            }
            return Ok(None);
        }
    };
    let proof = OwnerProof {
        key_id: t.key_id.clone(),
        nonce,
        sig,
    };
    let proof = serde_json::to_string(&proof)
        .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("proof: {e}")))?;
    Ok(Some(format!(r#"{{"req":{text},"proof":{proof}}}"#)))
}

/// One owner command that takes the password: one touch first when Touch ID applies, otherwise (or when the touch, or
/// the daemon's check of it, does not go through) the password as before. [build] makes the request with the password
/// it is given (`""` for the proof).
pub(crate) async fn call_pw(
    path: &Path,
    pw: &Pw,
    build: impl Fn(String) -> Request,
) -> CliResult<Reply> {
    if let Some(line) = prove(path, pw, &build(String::new())).await? {
        match call_owner_line(path, &line).await {
            Err(f) => match touch_refused(&f) {
                Some(why) => eprintln!("{why}"),
                None => return Err(f),
            },
            Ok((_, r)) => return Ok(r),
        }
    }
    call_owner(path, build(owner_pw(pw)?)).await.map(|(_, r)| r)
}

/// `antenna unlock` in a terminal with an unlock slot sealed here: one touch opens the slot's key, the daemon opens
/// the keys with it (CONTROL §22.4). `None`: unlock with the password (the reason is printed).
pub(crate) async fn unlock(path: &Path, pw: &Pw) -> CliResult<Option<Reply>> {
    if pw.password_stdin || !(pw.touch_id || std::io::stdin().is_terminal()) {
        return Ok(None);
    }
    let Some(t) = TouchId::find(path).filter(|t| t.unlock) else {
        return Ok(None);
    };
    let reason = reason_for(&crate::this_command_words());
    let slot = match t.start().and_then(|mut h| h.open_slot(&reason)) {
        Ok(s) => s,
        Err(e) => {
            if let Some(n) = e.note() {
                eprintln!("{n}");
            }
            return Ok(None);
        }
    };
    let r = call_owner(
        path,
        Request::Unlock {
            password: String::new(),
            key_id: Some(t.key_id.clone()),
            slot_key: Some(slot.to_string()),
        },
    )
    .await;
    match r {
        Ok((_, r)) => Ok(Some(r)),
        Err(f) if f.code == "slot_invalid" => {
            eprintln!("Touch ID could not unlock the keys: use your password.");
            Ok(None)
        }
        Err(f) => match touch_refused(&f) {
            Some(why) => {
                eprintln!("{why}");
                Ok(None)
            }
            None => Err(f),
        },
    }
}
