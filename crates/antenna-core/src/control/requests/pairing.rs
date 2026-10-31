// SPDX-License-Identifier: AGPL-3.0-only
//! The invites the daemon holds (CONTROL §6, Q-7); `invite` and `join` themselves are dialogs in `control.rs`.

use std::time::Duration;

use antenna_proto::control::Reply;

use super::{Answer, b, session};
use crate::node::Node;

/// `pairings`.
pub(crate) async fn pairings(
    node: &Node,
    wait: bool,
    timeout_ms: Option<u64>,
    password: Option<String>,
) -> Answer {
    // The link (a secret) and the SAS code: only with the owner password; the password has already been
    // checked by the common check of password commands (`owner_password`)
    let reveal = password.is_some();
    Ok(Reply::Pairings {
        invites: session(node)
            .await?
            .pairings(wait, timeout_ms.map(Duration::from_millis), reveal)
            .await
            .map_err(b)?,
    })
}

/// `pairing_confirm`: the owner's code against this invite's code (F-4), or no code once the joiner entered it and no
/// other invite showed a code meanwhile (D-95; otherwise `code_required`).
pub(crate) async fn pairing_confirm(node: &Node, id: String, code: Option<String>) -> Answer {
    let outcome = session(node)
        .await?
        .pairing_decide(&id, true, code.as_deref())
        .await
        .map_err(b)?;
    outcome.map(Reply::Linked)
}

/// `pairing_cancel`.
pub(crate) async fn pairing_cancel(node: &Node, id: String) -> Answer {
    let s = session(node).await?;
    let e = s.invite(&id).map_err(b)?;
    let _ = s.pairing_decide(&id, false, None).await.map_err(b)?;
    Ok(Reply::Pairings {
        invites: vec![e.info()],
    })
}
