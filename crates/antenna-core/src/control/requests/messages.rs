// SPDX-License-Identifier: AGPL-3.0-only
//! Messages: sending, the inbox, history (CONTROL §7), read marks, topics (CONTROL §20), the audit log, streams in
//! progress (CONTROL §15).

use std::time::Duration;

use antenna_proto::control::{ChatRef, Reply, Request};

use super::{Answer, b, session};
use crate::addressing::AddrReq;
use crate::error::Error;
use crate::node::Node;

/// `send`.
pub(crate) async fn send(node: &Node, req: Request) -> Answer {
    let Request::Send {
        contact,
        text,
        wait_ms,
        approval_id,
        to,
        to_agent,
        topic,
        topic_id,
        urgent,
    } = req
    else {
        return Err(Error::internal("not a send").body());
    };
    Ok(Reply::Sent(
        session(node)
            .await?
            .owner_send(
                &contact,
                &text,
                Duration::from_millis(wait_ms.min(60_000)),
                approval_id.as_deref(),
                &AddrReq::new(to, to_agent, topic, topic_id),
                urgent,
            )
            .await
            .map_err(b)?,
    ))
}

/// `inbox`.
pub(crate) async fn inbox(
    node: &Node,
    wait: bool,
    timeout_ms: Option<u64>,
    contact: Option<String>,
) -> Answer {
    Ok(Reply::Inbox(
        session(node)
            .await?
            .inbox(
                wait,
                timeout_ms.map(Duration::from_millis),
                contact.as_deref(),
            )
            .await
            .map_err(b)?,
    ))
}

/// `history` (with `chat`, v7: one chat of the link, CONTROL §26).
pub(crate) async fn history(
    node: &Node,
    contact: String,
    before: Option<i64>,
    limit: Option<u32>,
    chat: Option<ChatRef>,
) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    let chat = chat.map(|c| chat_key(c.agent)).transpose().map_err(b)?;
    Ok(Reply::History(
        s.history_of(&row, 0, before, limit, chat.as_deref())
            .map_err(b)?,
    ))
}

/// `mark_read` (with `chat`, v7: only that chat up to `up_to_seq`).
pub(crate) async fn mark_read(
    node: &Node,
    contact: String,
    up_to_seq: i64,
    ids: Option<Vec<String>>,
    chat: Option<ChatRef>,
) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    let chat = chat.map(|c| chat_key(c.agent)).transpose().map_err(b)?;
    Ok(Reply::Contacts(
        s.mark_read(
            &row,
            up_to_seq,
            ids.as_deref().unwrap_or_default(),
            chat.as_deref(),
        )
        .await
        .map_err(b)?,
    ))
}

/// A chat named in a request → its key in the store (`""` for the person chat); an agent name follows the rule of
/// agent names (PROTOCOL §21).
fn chat_key(agent: Option<String>) -> crate::error::Result<String> {
    match agent {
        None => Ok(String::new()),
        Some(a) if antenna_proto::AgentAnnounce::valid_name(&a) => Ok(a),
        Some(_) => Err(Error::bad_request(
            "chat: the agent name is 1–64 characters of [A-Za-z0-9._-]",
        )),
    }
}

/// `topics`.
pub(crate) async fn topics(node: &Node, contact: String) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    Ok(Reply::Topics {
        contact: row.label.clone(),
        link_id: row.link_id.to_hex(),
        topics: s.topics(&row).map_err(b)?,
    })
}

/// `log`: the link's audit log.
pub(crate) async fn log(node: &Node, contact: String, limit: Option<u32>) -> Answer {
    let s = session(node).await?;
    let row = s.find_link(&contact).map_err(b)?;
    Ok(Reply::Log {
        contact: row.label.clone(),
        entries: s.log(&row, limit).map_err(b)?,
    })
}

/// `streams`.
pub(crate) async fn streams(node: &Node) -> Answer {
    Ok(Reply::Streams {
        streams: session(node).await?.streams(),
    })
}
