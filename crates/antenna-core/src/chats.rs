// SPDX-License-Identifier: AGPL-3.0-only
//! Chats per agent (CONTROL §26, D-113). A link is between two nodes, but the owner talks to different counterparts on
//! the other side: the person and each of the contact's agents. A link's messages fall into chats by that counterpart:
//! an incoming message by its author (the contact's agent it came through, the person otherwise), an outgoing one by its
//! addressee (the contact's agent for `to: "agent"`, the person otherwise, messages to everyone and unaddressed ones
//! included); receipts belong to the person chat. This is the rule the window used for its threads (D-UI-18), now in
//! the daemon so that the list, a chat's pages and its unread count are the daemon's facts.
//!
//! The chats are derived state: they are read from the display columns of the stored messages, never the source of
//! truth for anything an agent may read (D-91 reads the address from the signed `core`). What the owner sets for a
//! chat (a local name, notifications, archive) is kept in `chats` on this node only and never sent.

use std::collections::{BTreeSet, HashMap};
use std::sync::PoisonError;

use antenna_proto::{
    AgentAnnounce, LinkId,
    control::{ChatInfo, NOTIFY_ALL, NOTIFY_ASKS, NOTIFY_DEFAULT, NOTIFY_OFF},
};
use rusqlite::{Connection, params};

use crate::error::{Error, Result};
use crate::events::NodeEvent;
use crate::node::Session;
use crate::store::{Db, HistoryFilter, LinkRow};

/// The chat of a message row `m` as an SQL expression: the contact's agent, `''` for the person chat.
pub(crate) const CHAT_OF: &str = "(CASE WHEN m.kind = 'receipt' THEN '' \
     WHEN m.direction = 'in' THEN coalesce(m.agent, '') \
     WHEN m.to_kind = 'agent' THEN coalesce(m.to_agent, '') ELSE '' END)";

/// The rows that are messages of a chat (counted, shown as its latest): text, files and file requests.
pub(crate) const MESSAGE_KINDS: &str = "m.kind IN ('text', 'file', 'request')";

/// The longest local name, in characters.
const MAX_NAME: usize = 64;

/// What `chat_set` changes; `None` leaves a setting as it is.
#[derive(Debug, Clone, Default)]
pub struct ChatSettings {
    /// Local name; `""` removes it.
    pub name: Option<String>,
    /// `all`, `asks`, `off`, `default`.
    pub notify: Option<String>,
    /// Archive or bring back.
    pub archived: Option<bool>,
}

/// What the messages say about one chat.
#[derive(Debug, Clone, Copy, Default)]
struct Stats {
    count: u64,
    unread: u64,
    last_seq: i64,
    last_ms: u64,
}

/// What the owner set for one chat.
#[derive(Debug, Clone, Default)]
struct Saved {
    name: Option<String>,
    notify: Option<String>,
    archived_ms: Option<u64>,
}

/// Per chat of the link: its messages, its incoming text the owner has not read (as `unread_count` counts them), the
/// latest `seq` and when it was received or written here.
fn stats(conn: &Connection, link: &LinkId) -> Result<HashMap<String, Stats>> {
    let mut st = conn.prepare(&format!(
        "SELECT {CHAT_OF} AS chat, count(*),
                sum(CASE WHEN m.direction = 'in' AND m.read = 0 AND m.kind = 'text' AND m.origin = 'live'
                         THEN 1 ELSE 0 END),
                max(m.seq), max(m.received_ms)
         FROM messages m WHERE m.link_id = ?1 AND {MESSAGE_KINDS} GROUP BY chat"
    ))?;
    let rows = st.query_map(params![&link.0[..]], |r| {
        Ok((
            r.get::<_, String>(0)?,
            Stats {
                count: r.get::<_, i64>(1)?.max(0) as u64,
                unread: r.get::<_, i64>(2)?.max(0) as u64,
                last_seq: r.get(3)?,
                last_ms: r.get::<_, i64>(4)?.max(0) as u64,
            },
        ))
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// The owner's settings of the link's chats.
fn saved(conn: &Connection, link: &LinkId) -> Result<HashMap<String, Saved>> {
    let mut st =
        conn.prepare("SELECT agent, name, notify, archived_ms FROM chats WHERE link_id = ?1")?;
    let rows = st.query_map(params![&link.0[..]], |r| {
        Ok((
            r.get::<_, String>(0)?,
            Saved {
                name: r.get(1)?,
                notify: r.get(2)?,
                archived_ms: r.get::<_, Option<i64>>(3)?.map(|v| v.max(0) as u64),
            },
        ))
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// The contact's agent `name` is known on the link: it announced itself (PROTOCOL §21) or there are messages in its
/// chat.
pub(crate) fn known_agent(conn: &Connection, link: &LinkId, name: &str) -> Result<bool> {
    Ok(conn.query_row(
        &format!(
            "SELECT EXISTS(SELECT 1 FROM link_agents WHERE link_id = ?1 AND side = 'peer' AND name = ?2)
                 OR EXISTS(SELECT 1 FROM messages m WHERE m.link_id = ?1 AND {MESSAGE_KINDS} AND {CHAT_OF} = ?2)"
        ),
        params![&link.0[..], name],
        |r| r.get(0),
    )?)
}

/// `mark_read` with `chat`: the chat's incoming messages up to and including `up_to_seq` are read by the owner; the
/// link's other chats keep theirs.
pub(crate) fn mark_read(
    conn: &Connection,
    link: &LinkId,
    chat: &str,
    up_to_seq: i64,
) -> Result<u64> {
    Ok(conn.execute(
        &format!(
            "UPDATE messages SET read = 1 WHERE seq IN (
               SELECT m.seq FROM messages m WHERE m.link_id = ?1 AND m.direction = 'in' AND m.read = 0
                 AND m.seq <= ?2 AND {CHAT_OF} = ?3)"
        ),
        params![&link.0[..], up_to_seq, chat],
    )? as u64)
}

/// The notifications of a chat when the owner chose nothing: every message of the person, what asks for the owner
/// from an agent (an agent's chat is mostly work between agents).
fn default_notify(agent: Option<&str>) -> &'static str {
    if agent.is_some() {
        NOTIFY_ASKS
    } else {
        NOTIFY_ALL
    }
}

/// The link's chats: the person chat first, then the chats with the contact's agents that wrote, were written to or
/// were set up by the owner, the most recent first.
fn chats_of(db: &Db, row: &LinkRow) -> Result<Vec<ChatInfo>> {
    let conn = db.conn();
    let stats = stats(conn, &row.link_id)?;
    let saved = saved(conn, &row.link_id)?;
    let keys: BTreeSet<&str> = std::iter::once("")
        .chain(stats.keys().map(String::as_str))
        .chain(saved.keys().map(String::as_str))
        .collect();
    let mut out = Vec::with_capacity(keys.len());
    for key in keys {
        let st = stats.get(key).copied().unwrap_or_default();
        let set = saved.get(key);
        let agent = (!key.is_empty()).then(|| key.to_string());
        let last = if st.count > 0 {
            let filter = HistoryFilter {
                chat: Some(key),
                messages_only: true,
            };
            db.history_in(&row.link_id, 0, None, 1, &filter)?
                .0
                .pop()
                .map(crate::node::history_item)
        } else {
            None
        };
        let archived_ms = set.and_then(|s| s.archived_ms);
        out.push(ChatInfo {
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            name: set.and_then(|s| s.name.clone()),
            notify: set
                .and_then(|s| s.notify.clone())
                .unwrap_or_else(|| default_notify(agent.as_deref()).into()),
            notify_set: set.is_some_and(|s| s.notify.is_some()),
            // A message newer than the archiving brings the chat back (it stays archived only while nothing new comes)
            archived: archived_ms.is_some_and(|a| st.count == 0 || st.last_ms <= a),
            archived_ms,
            count: st.count,
            unread: st.unread,
            last_seq: (st.count > 0).then_some(st.last_seq),
            last_ms: (st.count > 0).then_some(st.last_ms),
            last,
            saved: set.is_some(),
            agent,
        });
    }
    out.sort_by(|a, b| {
        a.agent
            .is_some()
            .cmp(&b.agent.is_some())
            .then(b.last_seq.cmp(&a.last_seq))
            .then(a.agent.cmp(&b.agent))
    });
    Ok(out)
}

/// A local name as the owner typed it: trimmed, `""` to remove it.
fn clean_name(name: &str) -> Result<Option<String>> {
    let name = name.trim();
    if name.is_empty() {
        return Ok(None);
    }
    if name.chars().count() > MAX_NAME || name.chars().any(char::is_control) {
        return Err(Error::bad_request(
            "chat_set: a name is 1–64 characters without control characters",
        ));
    }
    Ok(Some(name.to_string()))
}

impl Session {
    /// `chats`: every link's chats, or one contact's.
    pub fn chats(&self, contact: Option<&str>) -> Result<Vec<ChatInfo>> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let rows = match contact {
            Some(c) => vec![db.find_link(c)?],
            None => db.links()?,
        };
        let mut out = Vec::new();
        for row in &rows {
            out.extend(chats_of(&db, row)?);
        }
        Ok(out)
    }

    /// `chat_set`: the owner's local settings of one chat; with no setting given, the chat with a known agent of the
    /// contact is created (listed before its first message). Tells the owner's subscriptions (`chat`).
    pub fn chat_set(
        &self,
        contact: &str,
        agent: Option<&str>,
        set: &ChatSettings,
    ) -> Result<ChatInfo> {
        let name = set.name.as_deref().map(clean_name).transpose()?;
        let notify = match set.notify.as_deref() {
            None => None,
            Some(NOTIFY_DEFAULT) => Some(None),
            Some(v @ (NOTIFY_ALL | NOTIFY_ASKS | NOTIFY_OFF)) => Some(Some(v)),
            Some(_) => {
                return Err(Error::bad_request(
                    "chat_set: notify is all, asks, off or default",
                ));
            }
        };
        if let Some(a) = agent
            && !AgentAnnounce::valid_name(a)
        {
            return Err(Error::bad_request(
                "chat_set: the agent name is 1–64 characters of [A-Za-z0-9._-]",
            ));
        }
        if agent.is_none() && set.archived == Some(true) {
            return Err(Error::bad_request(
                "chat_set: the person chat is the contact itself and is not archived (archive a chat with an agent)",
            ));
        }
        let key = agent.unwrap_or("");
        let info = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let row = db.find_link(contact)?;
            let conn = db.conn();
            if !key.is_empty() && !known_agent(conn, &row.link_id, key)? {
                return Err(Error::new(
                    antenna_proto::control::code::NOT_FOUND,
                    format!(
                        "{} has no agent {key} that announced itself or wrote; its chat appears when it does",
                        row.label
                    ),
                ));
            }
            conn.execute(
                "INSERT INTO chats(link_id, agent, created_ms) VALUES (?1, ?2, ?3)
                 ON CONFLICT(link_id, agent) DO NOTHING",
                params![&row.link_id.0[..], key, crate::now_ms() as i64],
            )?;
            if let Some(name) = &name {
                conn.execute(
                    "UPDATE chats SET name = ?3 WHERE link_id = ?1 AND agent = ?2",
                    params![&row.link_id.0[..], key, name],
                )?;
            }
            if let Some(notify) = notify {
                conn.execute(
                    "UPDATE chats SET notify = ?3 WHERE link_id = ?1 AND agent = ?2",
                    params![&row.link_id.0[..], key, notify],
                )?;
            }
            if let Some(archived) = set.archived {
                conn.execute(
                    "UPDATE chats SET archived_ms = ?3 WHERE link_id = ?1 AND agent = ?2",
                    params![
                        &row.link_id.0[..],
                        key,
                        archived.then(|| crate::now_ms() as i64)
                    ],
                )?;
            }
            chats_of(&db, &row)?
                .into_iter()
                .find(|c| c.agent.as_deref().unwrap_or("") == key)
                .ok_or_else(|| Error::internal("chat_set: the chat is not listed after saving"))?
        };
        let _ = self.events.send(NodeEvent::Chat(Box::new(info.clone())));
        Ok(info)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_trimmed_bounded_and_without_control_characters() {
        assert_eq!(
            clean_name("  Payments API ").unwrap().as_deref(),
            Some("Payments API")
        );
        assert_eq!(clean_name("   ").unwrap(), None);
        assert_eq!(
            clean_name(&"é".repeat(64))
                .unwrap()
                .map(|n| n.chars().count()),
            Some(64)
        );
        assert!(clean_name(&"a".repeat(65)).is_err());
        assert!(clean_name("one\ntwo").is_err());
        assert!(clean_name("bell\u{7}").is_err());
    }

    #[test]
    fn defaults_follow_the_kind_of_chat() {
        assert_eq!(default_notify(None), NOTIFY_ALL);
        assert_eq!(default_notify(Some("lead")), NOTIFY_ASKS);
    }
}
