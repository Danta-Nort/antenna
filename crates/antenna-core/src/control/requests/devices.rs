// SPDX-License-Identifier: AGPL-3.0-only
//! My devices (CONTROL §27, D-106; experimental): the owner's other computers, approvals answered from here, a lost
//! computer, lending this one to teams. Every password was checked in `authorize` before these run.

use antenna_proto::control::Reply;

use super::{Answer, b, session};
use crate::node::Node;

/// `devices`.
pub(crate) async fn list(node: &Node) -> Answer {
    Ok(Reply::Devices(
        session(node).await?.devices_list().map_err(b)?,
    ))
}

/// `device_challenge`.
pub(crate) async fn challenge(node: &Node, contact: String) -> Answer {
    Ok(Reply::DeviceChallenge(
        session(node)
            .await?
            .device_challenge(&contact)
            .await
            .map_err(b)?,
    ))
}

/// `device_approve`: a proof made in the window, passed on unchanged.
pub(crate) async fn approve(
    node: &Node,
    contact: String,
    request: String,
    nonce: String,
    key_id: String,
    sig: String,
) -> Answer {
    Ok(Reply::DeviceDecided(
        session(node)
            .await?
            .device_approve(&contact, request, &nonce, key_id, &sig)
            .await
            .map_err(b)?,
    ))
}

/// `device_decide`: approve with the password typed here (checked), or deny.
pub(crate) async fn decide(
    node: &Node,
    contact: String,
    id: String,
    decision: String,
    fingerprint: Option<String>,
) -> Answer {
    Ok(Reply::DeviceDecided(
        session(node)
            .await?
            .device_decide(&contact, &id, &decision, fingerprint.as_deref())
            .await
            .map_err(b)?,
    ))
}

/// `device_keys_confirm` (the password was checked).
pub(crate) async fn keys_confirm(node: &Node, contact: String, key_ids: Vec<String>) -> Answer {
    Ok(Reply::Devices(
        session(node)
            .await?
            .device_keys_confirm(&contact, &key_ids)
            .map_err(b)?,
    ))
}

/// `device_keys_remove`: no password (D-84).
pub(crate) async fn keys_remove(node: &Node, contact: String, key_ids: Vec<String>) -> Answer {
    Ok(Reply::Devices(
        session(node)
            .await?
            .device_keys_remove(&contact, &key_ids)
            .map_err(b)?,
    ))
}

/// `device_lend_set` (on: the password was checked).
pub(crate) async fn lend_set(node: &Node, enabled: bool) -> Answer {
    Ok(Reply::Devices(
        session(node).await?.device_lend_set(enabled).map_err(b)?,
    ))
}

/// `device_revoke` (the password was checked).
pub(crate) async fn revoke(node: &Node, contact: String, delete_history: bool) -> Answer {
    let row = session(node)
        .await?
        .device_revoke(&contact, delete_history)
        .await
        .map_err(b)?;
    Ok(Reply::Revoked {
        contact: row.label.clone(),
        link_id: row.link_id.to_hex(),
        history_deleted: delete_history,
    })
}

/// `device_lost_dismiss`.
pub(crate) async fn lost_dismiss(node: &Node, contact: String) -> Answer {
    Ok(Reply::Devices(
        session(node)
            .await?
            .device_lost_dismiss(&contact)
            .map_err(b)?,
    ))
}
