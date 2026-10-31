// SPDX-License-Identifier: AGPL-3.0-only
//! Contacts and links (CONTROL §9) and their history and integrity (CONTROL §12).

use antenna_proto::control::Reply;

use super::{Answer, b, session};
use crate::node::Node;

/// `contacts`.
pub(crate) async fn contacts(node: &Node) -> Answer {
    Ok(Reply::Contacts(
        session(node).await?.contacts().await.map_err(b)?,
    ))
}

/// `trust` (the password was checked in `owner`).
pub(crate) async fn trust(node: &Node, contact: String, level: u8) -> Answer {
    Ok(Reply::Contacts(
        session(node)
            .await?
            .set_trust(&contact, level)
            .await
            .map_err(b)?,
    ))
}

/// `rename`: the label is the owner's own.
pub(crate) async fn rename(node: &Node, contact: String, label: String) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    Ok(Reply::Contacts(s.rename(&row, &label).await.map_err(b)?))
}

/// `revoke`.
pub(crate) async fn revoke(node: &Node, contact: String, delete_history: bool) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    s.revoke(&row, delete_history).await.map_err(b)?;
    Ok(Reply::Revoked {
        contact: row.label.clone(),
        link_id: row.link_id.to_hex(),
        history_deleted: delete_history,
    })
}

/// `history_status`.
pub(crate) async fn history_status(node: &Node, contact: String) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    Ok(Reply::HistoryStatus(s.history_status(&row).map_err(b)?))
}

/// `verify`.
pub(crate) async fn verify(node: &Node, contact: String, accept: bool, repair: bool) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    Ok(Reply::HistoryStatus(
        s.verify(&row, accept, repair).await.map_err(b)?,
    ))
}

/// `rekey`.
pub(crate) async fn rekey(node: &Node, contact: String, code: Option<String>) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    let (contact, state, code) = s.rekey(&row, code.as_deref()).await.map_err(b)?;
    Ok(Reply::Rekey {
        contact,
        state: state.into(),
        code_emoji: code.as_deref().and_then(antenna_proto::sas::to_emoji),
        code,
    })
}
