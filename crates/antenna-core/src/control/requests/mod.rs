// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's one-reply requests (CONTROL §4): one handler per command, grouped like the sections of
//! `docs/CONTROL.md`; `execute_owner` in `control.rs` dispatches with one call per command. The checks every owner
//! request passes first (the session, the password) and the dialogs (invite, join, login, `send_stream`, `wake_say`,
//! subscribe) stay in `control.rs`.

pub(super) mod agents;
pub(super) mod approvals;
pub(super) mod chats;
pub(super) mod devices;
pub(super) mod files;
pub(super) mod links;
pub(super) mod local;
pub(super) mod messages;
pub(super) mod node;
pub(super) mod owner_keys;
pub(super) mod pairing;
pub(super) mod pictures;
pub(super) mod stop;
pub(super) mod teams;
pub(super) mod wake;

use std::sync::Arc;

use antenna_proto::control::{ErrorBody, Reply};

use crate::{
    error::Error,
    node::{Node, Session},
};

/// A handler's answer: the reply, or the error body the client gets.
pub(super) type Answer = std::result::Result<Reply, ErrorBody>;

/// A core error as the client gets it.
fn b(e: Error) -> ErrorBody {
    e.body()
}

/// The open session, or the error the client gets (locked, not created).
async fn session(node: &Node) -> std::result::Result<Arc<Session>, ErrorBody> {
    node.session().await.map_err(|e| e.body())
}
