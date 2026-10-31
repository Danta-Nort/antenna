// SPDX-License-Identifier: Apache-2.0
//! Chats per agent (x-control/7, `docs/CONTROL.md` §26, D-113): a link's messages fall into chats by the counterpart
//! on the contact's side, the person or one of the contact's agents. The daemon derives the chats from the stored
//! messages (the address is already in the signed message, PROTOCOL §23); what the owner sets for a chat (a local
//! name, archive, notifications) is kept on this node only and never sent.

use serde::{Deserialize, Serialize};

use super::HistoryItem;

/// Notifications for every new incoming message of the chat (the default for the person chat).
pub const NOTIFY_ALL: &str = "all";
/// Notifications only for what asks for the owner: messages addressed to the owner in person (not to one of the
/// owner's agents, not to everyone) and approval requests. The default for a chat with an agent.
pub const NOTIFY_ASKS: &str = "asks";
/// No notifications for messages of the chat (approval requests still notify: they wait for the owner's decision).
pub const NOTIFY_OFF: &str = "off";
/// In `chat_set` only: forget the owner's choice and go back to the default of the chat's kind.
pub const NOTIFY_DEFAULT: &str = "default";

/// Which chat of a link: the person chat (`{}`: the contact in person, and messages to everyone) or the chat with one
/// of the contact's agents (`{"agent": "<name as the contact announced it>"}`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChatRef {
    /// The contact's agent; absent for the person chat.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

impl ChatRef {
    /// The person chat.
    pub fn person() -> ChatRef {
        ChatRef { agent: None }
    }

    /// The chat with the contact's agent `name`.
    pub fn agent(name: impl Into<String>) -> ChatRef {
        ChatRef {
            agent: Some(name.into()),
        }
    }
}

/// One chat of a link (`chats`, `chat_set`, the `chat` event).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatInfo {
    /// Contact label.
    pub contact: String,
    /// Link ID (hex).
    pub link_id: String,
    /// The contact's agent this chat is with; absent for the person chat.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// The owner's local name for the chat ("Payments API"); never sent to anyone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Notifications: `all`, `asks` or `off`, the owner's choice or the default of the chat's kind.
    pub notify: String,
    /// [`ChatInfo::notify`] is the owner's choice, not the default.
    #[serde(default, skip_serializing_if = "super::is_false")]
    pub notify_set: bool,
    /// Archived: the owner archived it and nothing was written in it since (a new message brings it back).
    #[serde(default, skip_serializing_if = "super::is_false")]
    pub archived: bool,
    /// When the owner archived it (Unix ms), also once a newer message brought it back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_ms: Option<u64>,
    /// Messages in the chat (text, files, file requests; receipts are not counted).
    pub count: u64,
    /// Incoming text messages the owner has not read.
    pub unread: u64,
    /// `seq` of the latest message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seq: Option<i64>,
    /// When the latest message was received or written here, Unix ms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_ms: Option<u64>,
    /// The latest message, as in `history`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<HistoryItem>,
    /// The owner created the chat or changed one of its settings: it is listed even before its first message.
    #[serde(default, skip_serializing_if = "super::is_false")]
    pub saved: bool,
}

/// `chats` (v7): the chats of every link, or of one; per link the person chat first, then the chats with the
/// contact's agents, the most recent first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatsReply {
    /// Chats.
    pub chats: Vec<ChatInfo>,
}
