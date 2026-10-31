// SPDX-License-Identifier: AGPL-3.0-only
//! The node: keys, the owner session (CONTROL §3, §4), the local network (CONTROL §18) and updates (CONTROL §19).

use std::sync::PoisonError;

use antenna_proto::control::Reply;
use zeroize::Zeroizing;

use super::{Answer, b, session};
use crate::control::{OwnerCtx, open_tty_session};
use crate::error::Error;
use crate::node::Node;

/// `init`: the device root key; a terminal gets an owner session, as after a correct password.
pub(crate) async fn init(node: &Node, ctx: &OwnerCtx, password: String) -> Answer {
    node.init(Zeroizing::new(password)).await.map_err(b)?;
    open_tty_session(node, ctx.chain.as_deref());
    Ok(Reply::Done {
        state: node.state_name().await.into(),
    })
}

/// `unlock`: with the password (a terminal also gets an owner session, as after any correct password), or (v7) with an
/// owner key's unlock slot, which opens the keys and nothing more.
pub(crate) async fn unlock(
    node: &Node,
    ctx: &OwnerCtx,
    password: String,
    key_id: Option<String>,
    slot_key: Option<String>,
) -> Answer {
    let password = Zeroizing::new(password);
    match (key_id, slot_key) {
        (None, None) => {
            node.unlock(password).await.map_err(b)?;
            open_tty_session(node, ctx.chain.as_deref());
        }
        (Some(key_id), Some(slot_key)) if password.is_empty() => {
            let k = crate::owner_keys::parse_slot_key(&slot_key).map_err(b)?;
            node.unlock_slot(key_id, k).await.map_err(b)?;
        }
        _ => {
            return Err(Error::bad_request(
                "unlock takes the password, or key_id and slot_key with an empty password",
            )
            .body());
        }
    }
    Ok(Reply::Done {
        state: node.state_name().await.into(),
    })
}

/// `logout`: closes this terminal's (or this connection's) owner session.
pub(crate) fn logout(node: &Node, ctx: &OwnerCtx) -> Answer {
    let closed = node
        .owner_sessions
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .close(ctx.chain.as_deref(), ctx.token.as_deref());
    Ok(Reply::Done {
        state: if closed {
            "owner session closed".into()
        } else {
            "no owner session".into()
        },
    })
}

/// `lock`.
pub(crate) async fn lock(node: &Node) -> Answer {
    node.lock().await.map_err(b)?;
    Ok(Reply::Done {
        state: node.state_name().await.into(),
    })
}

/// `lan_set` (turning it on: the password was checked in `owner`).
pub(crate) async fn lan_set(node: &Node, enabled: bool) -> Answer {
    Ok(Reply::Lan(
        session(node).await?.lan_set(enabled).map_err(b)?,
    ))
}

/// `lan_status`.
pub(crate) async fn lan_status(node: &Node) -> Answer {
    Ok(Reply::Lan(session(node).await?.lan_status()))
}

/// `update_auto_set` (D-103): the password was checked in `owner`, both ways. Turning it on keeps the root key for the
/// update's restart; turning it off drops it.
pub(crate) async fn update_auto_set(node: &Node, enabled: bool, password: String) -> Answer {
    let s = session(node).await?;
    let password = Zeroizing::new(password);
    if enabled {
        s.auto_supported().map_err(b)?;
        node.keep_root_with_password(&password).await.map_err(b)?;
    }
    Ok(Reply::UpdateAuto(s.update_auto_set(enabled).map_err(b)?))
}

/// `update_auto_status`.
pub(crate) async fn update_auto_status(node: &Node) -> Answer {
    Ok(Reply::UpdateAuto(session(node).await?.update_auto_info()))
}

/// `update_auto_now`. With the password (checked in `owner`, D-137) the daemon opens the root key for this one restart,
/// as turning the setting on does; without it the keys must already be kept (the setting is on).
pub(crate) async fn update_auto_now(node: &Node, password: Option<String>) -> Answer {
    let s = session(node).await?;
    if let Some(password) = password.map(Zeroizing::new) {
        // Something to install first: the key is never kept for nothing.
        s.auto_staged_or_busy().map_err(b)?;
        s.auto_supported().map_err(b)?;
        node.keep_root_with_password(&password).await.map_err(b)?;
    }
    Ok(Reply::UpdateAuto(s.update_auto_now().map_err(b)?))
}

/// `update_auto_later`.
pub(crate) async fn update_auto_later(node: &Node) -> Answer {
    Ok(Reply::UpdateAuto(
        session(node).await?.update_auto_later().map_err(b)?,
    ))
}

/// `update_authorize` (D-82).
pub(crate) fn update_authorize(node: &Node, action: String, version: Option<String>) -> Answer {
    // The owner check (password or session) already ran in `owner`; the update itself is done by the CLI, which
    // needs to know whether this daemon belongs to the installation it replaces (D-82).
    if !matches!(action.as_str(), "install" | "rollback") {
        return Err(Error::bad_request("action is install or rollback").body());
    }
    tracing::info!(
        "the owner authorized antenna update: {action}{}",
        version.map(|v| format!(" to {v}")).unwrap_or_default()
    );
    Ok(Reply::UpdateAuthorized(
        antenna_proto::control::UpdateAuthorized {
            daemon: node.daemon_version().to_string(),
            pid: std::process::id(),
            exe: std::env::current_exe()
                .ok()
                .map(|p| p.to_string_lossy().into_owned()),
        },
    ))
}
