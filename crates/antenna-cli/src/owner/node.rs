// SPDX-License-Identifier: AGPL-3.0-only
//! The node itself: keys, the owner session, the local network.

use antenna_proto::control::{Reply, Request};

use super::Owner;
use crate::client::{CliResult, EXIT_NOT_IMPLEMENTED, Fail};
use crate::{KeyBackend, Pw, get_password};

/// `antenna init`.
pub(super) async fn init(o: &Owner, pw: &Pw, key_backend: KeyBackend) -> CliResult<Reply> {
    if !matches!(key_backend, KeyBackend::Password) {
        return Err(Fail::new(
            EXIT_NOT_IMPLEMENTED,
            "not_implemented",
            "only --key-backend password is implemented (systemd-creds and key file come later)",
        ));
    }
    let pw = get_password(pw.password_stdin, true, "Password: ")?;
    let reply = o
        .call(Request::Init {
            password: pw.to_string(),
        })
        .await?;
    // The person just typed the password twice: open the owner session in this terminal too, so the first `antenna
    // invite` or `antenna send` does not ask for `antenna login` a minute later. Best effort: where no session can be
    // opened (Windows, an odd parent), the owner commands still ask for the password themselves.
    if !cfg!(windows) {
        let _ = o
            .call(Request::Login {
                password: pw.to_string(),
                hold: false,
            })
            .await;
    }
    {
        use std::io::IsTerminal as _;
        if std::io::stderr().is_terminal() {
            eprintln!(
                "Next: `antenna invite` makes a one-time link for your other computer or a person \
                 (or `antenna join <link>` here); `antenna connect claude-code --agent <name>` connects an agent."
            );
        }
    }
    Ok(reply)
}

/// `antenna unlock`: one touch opens the unlock slot when Touch ID is on here (D-131), the password otherwise.
pub(super) async fn unlock(o: &Owner, pw: &Pw) -> CliResult<Reply> {
    if let Some(r) = super::touch::unlock(&o.path, pw).await? {
        return Ok(r);
    }
    let pw = get_password(pw.password_stdin, false, "Password: ")?;
    o.call(Request::Unlock {
        password: pw.to_string(),
        key_id: None,
        slot_key: None,
    })
    .await
}

/// `antenna login`: one touch when Touch ID is on here (D-131), the password otherwise.
pub(super) async fn login(o: &Owner, pw: &Pw) -> CliResult<Reply> {
    // Windows (WP-10): no terminal sessions to open there; each owner command asks for the password itself.
    if cfg!(windows) {
        return Err(crate::client::Fail::new(
            crate::client::EXIT_USAGE,
            "bad_request",
            "on Windows `antenna login` opens no session: a console can be joined by another process, so it names no \
             terminal. Each owner command that needs a session asks for the password itself; the window keeps its own \
             session",
        ));
    }
    o.call_pw(pw, |password| Request::Login {
        password,
        hold: false,
    })
    .await
}

/// `antenna lan on`.
pub(super) async fn lan_on(o: &Owner, pw: &Pw) -> CliResult<Reply> {
    o.call_pw(pw, |password| Request::LanSet {
        enabled: true,
        password: Some(password),
    })
    .await
}

/// `antenna lan off`.
pub(super) async fn lan_off(o: &Owner) -> CliResult<Reply> {
    o.call(Request::LanSet {
        enabled: false,
        password: None,
    })
    .await
}
