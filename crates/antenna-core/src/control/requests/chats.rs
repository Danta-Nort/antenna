// SPDX-License-Identifier: AGPL-3.0-only
//! Chats per agent (CONTROL §26, D-113): the list and the owner's local settings of a chat.

use antenna_proto::control::{ChatsReply, Reply, Request};

use super::{Answer, b, session};
use crate::chats::ChatSettings;
use crate::error::Error;
use crate::node::Node;

/// `chats`.
pub(crate) async fn list(node: &Node, contact: Option<String>) -> Answer {
    let s = session(node).await?;
    s.chats(contact.as_deref())
        .map(|chats| Reply::Chats(ChatsReply { chats }))
        .map_err(b)
}

/// `chat_set`.
pub(crate) async fn set(node: &Node, req: Request) -> Answer {
    let Request::ChatSet {
        contact,
        agent,
        name,
        notify,
        archived,
    } = req
    else {
        return Err(Error::internal("not a chat_set").body());
    };
    let s = session(node).await?;
    s.chat_set(
        &contact,
        agent.as_deref(),
        &ChatSettings {
            name,
            notify,
            archived,
        },
    )
    .map(Reply::Chat)
    .map_err(b)
}
