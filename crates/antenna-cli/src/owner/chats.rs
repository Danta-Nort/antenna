// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna chats` (CONTROL §26, D-113): the chats of each contact, the person chat and one per agent of the contact,
//! and the owner's local settings of a chat (a name, archive, notifications). The settings stay on this computer.

use antenna_proto::control::{Reply, Request};
use clap::{Args, Subcommand};

use super::Owner;
use crate::client::CliResult;

/// `antenna chats`.
#[derive(Debug, Args)]
pub(crate) struct ChatsArgs {
    #[command(subcommand)]
    cmd: Option<ChatsCommand>,
    /// Only this contact's chats.
    #[arg(long)]
    contact: Option<String>,
}

#[derive(Debug, Subcommand)]
enum ChatsCommand {
    /// Start the chat with an agent of the contact that announced itself or already wrote.
    New {
        /// Contact.
        contact: String,
        /// The contact's agent, by the name it announced.
        agent: String,
    },
    /// Name a chat for yourself ("Payments API"); the name is never sent. `""` removes it.
    Rename {
        /// Contact.
        contact: String,
        /// The chat with this agent of the contact; without it, the person chat.
        #[arg(long)]
        agent: Option<String>,
        /// The name (1–64 characters).
        name: String,
    },
    /// Hide a chat with an agent until something new is written in it; its history stays.
    Archive {
        /// Contact.
        contact: String,
        /// The contact's agent.
        agent: String,
    },
    /// Bring an archived chat back to the list.
    Unarchive {
        /// Contact.
        contact: String,
        /// The contact's agent.
        agent: String,
    },
    /// Notifications of a chat: `all` messages, `asks` (only messages addressed to you and approval requests),
    /// `off`, or `default` (all for the person chat, asks for a chat with an agent).
    Notify {
        /// Contact.
        contact: String,
        /// The chat with this agent of the contact; without it, the person chat.
        #[arg(long)]
        agent: Option<String>,
        /// The setting.
        #[arg(value_parser = ["all", "asks", "off", "default"])]
        value: String,
    },
}

/// `chat_set` for one chat: `agent` absent is the person chat; each setting `None` stays as it is.
fn set(
    contact: &str,
    agent: Option<&String>,
    name: Option<&String>,
    notify: Option<&String>,
    archived: Option<bool>,
) -> Request {
    Request::ChatSet {
        contact: contact.to_string(),
        agent: agent.cloned(),
        name: name.cloned(),
        notify: notify.cloned(),
        archived,
    }
}

/// `antenna chats …`.
pub(crate) async fn run(o: &Owner, a: &ChatsArgs) -> CliResult<Reply> {
    let req = match &a.cmd {
        None => Request::Chats {
            contact: a.contact.clone(),
        },
        Some(ChatsCommand::New { contact, agent }) => set(contact, Some(agent), None, None, None),
        Some(ChatsCommand::Rename {
            contact,
            agent,
            name,
        }) => set(contact, agent.as_ref(), Some(name), None, None),
        Some(ChatsCommand::Archive { contact, agent }) => {
            set(contact, Some(agent), None, None, Some(true))
        }
        Some(ChatsCommand::Unarchive { contact, agent }) => {
            set(contact, Some(agent), None, None, Some(false))
        }
        Some(ChatsCommand::Notify {
            contact,
            agent,
            value,
        }) => set(contact, agent.as_ref(), None, Some(value), None),
    };
    o.call(req).await
}
