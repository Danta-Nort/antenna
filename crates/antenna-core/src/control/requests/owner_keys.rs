// SPDX-License-Identifier: AGPL-3.0-only
//! Owner keys (CONTROL §22, v7, D-102): the challenge, enrolling, listing, removing. The proof of a request is checked
//! in `control::auth` before any handler runs.

use antenna_proto::control::Reply;
use zeroize::Zeroizing;

use super::{Answer, b};
use crate::control::{OwnerCtx, auth};
use crate::node::Node;
use crate::owner_keys;

/// `owner_challenge`: for the client process that asks (and its session token); `enroll`: for `owner_key_add`.
pub(crate) async fn challenge(node: &Node, ctx: &OwnerCtx, enroll: bool) -> Answer {
    let bind = auth::bind(ctx).map_err(b)?;
    Ok(Reply::OwnerChallenge(
        node.owner_challenge(bind, enroll).await.map_err(b)?,
    ))
}

/// `owner_key_add` (the password and the new key's proof were checked in `authorize`).
pub(crate) async fn add(
    node: &Node,
    public_key: String,
    label: String,
    unlock: bool,
    password: String,
) -> Answer {
    let public = owner_keys::parse_public(&public_key).map_err(b)?;
    let added = node
        .owner_key_add(public, &label, unlock, Zeroizing::new(password))
        .await
        .map_err(b)?;
    Ok(Reply::OwnerKeyAdded(added))
}

/// `owner_key_list`.
pub(crate) async fn list(node: &Node) -> Answer {
    Ok(Reply::OwnerKeys(node.owner_key_list().await.map_err(b)?))
}

/// `owner_key_remove`: no password, no session (D-84).
pub(crate) async fn remove(node: &Node, key_id: String) -> Answer {
    node.owner_key_remove(&key_id).await.map_err(b)?;
    Ok(Reply::Done {
        state: "removed".into(),
    })
}
