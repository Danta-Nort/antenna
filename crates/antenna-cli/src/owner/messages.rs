// SPDX-License-Identifier: AGPL-3.0-only
//! Messages: sending, the inbox, history, the audit log, topics.

use antenna_proto::control::{ChatRef, Reply, Request};

use super::Owner;
use crate::client::{Auth, CliResult};
use crate::{
    HistoryArgs, InboxArgs, LogArgs, OwnerSendArgs, parse_duration, send_stream, send_text,
};

/// `antenna send` (with `--stream`: stdin as a streaming message; `--urgent`: interrupt the agent now, PG-58).
pub(super) async fn send(o: &Owner, a: &OwnerSendArgs) -> CliResult<Reply> {
    let s = &a.base;
    if s.stream {
        return send_stream(
            &o.path,
            &Auth::Owner,
            &s.contact,
            parse_duration(&s.wait)?.as_millis() as u64,
            s.addr(),
            o.json,
        )
        .await;
    }
    let (to, to_agent, topic, topic_id) = s.addr();
    o.call(Request::Send {
        contact: s.contact.clone(),
        text: send_text(s)?,
        wait_ms: parse_duration(&s.wait)?.as_millis() as u64,
        approval_id: s.approval.clone(),
        to,
        to_agent,
        topic,
        topic_id,
        urgent: a.urgent,
    })
    .await
}

/// `antenna topics`.
pub(super) async fn topics(o: &Owner, contact: &str) -> CliResult<Reply> {
    o.call(Request::Topics {
        contact: contact.to_string(),
    })
    .await
}

/// `antenna inbox`.
pub(super) async fn inbox(o: &Owner, i: &InboxArgs) -> CliResult<Reply> {
    let timeout_ms = match &i.timeout {
        Some(t) => Some(parse_duration(t)?.as_millis() as u64),
        None => None,
    };
    o.call(Request::Inbox {
        wait: i.wait,
        timeout_ms,
        contact: i.contact.clone(),
    })
    .await
}

/// `antenna log`.
pub(super) async fn log(o: &Owner, l: &LogArgs) -> CliResult<Reply> {
    o.call(Request::Log {
        contact: l.contact.clone(),
        limit: l.limit,
    })
    .await
}

/// `antenna history`.
pub(super) async fn history(o: &Owner, h: &HistoryArgs) -> CliResult<Reply> {
    let chat = match (&h.chat, h.person) {
        (Some(agent), _) => Some(ChatRef::agent(agent.clone())),
        (None, true) => Some(ChatRef::person()),
        (None, false) => None,
    };
    o.call(Request::History {
        contact: h.contact.clone(),
        before: h.before,
        limit: h.limit,
        chat,
    })
    .await
}
