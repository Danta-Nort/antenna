// SPDX-License-Identifier: AGPL-3.0-only
//! "Escalate to" (CONTROL §29, D-118, PG-18): an agent asks its supervisor a question it cannot decide itself.
//!
//! The owner sets per agent where its questions go (`agent_escalate`, with the password, as `agent_tasks`): the owner
//! (the default), or a contact within the agent's links. A question to the owner is stored here (the node's encrypted
//! database) and shown to the owner as a card and a notification (the owner's `escalation` event); the owner answers
//! or sets it aside, and the answer reaches the agent in `wait`, `inbox`, `escalation_get` and its own `escalation`
//! event. A question to a contact is a message from the agent to that contact in person, sent through `send`, so the
//! same policy applies (the level limit, cross-link flow, no write-down, the secret scanner, approvals); the answer
//! comes back as an ordinary message. A team's worker (D-111) asks the owner: it sees no contacts, and questions
//! about its task go to its lead with `task_report`; a lead's questions go where the owner set them, like any agent's.
//! The card names the team.
//!
//! The question is the agent's text: it may carry words of contacts whose data the agent read. It is data for the owner
//! (shown quoted, with what the agent had read when it asked), never something the daemon acts on. The owner's answer
//! is the owner's word to the agent, like a `wake_say` turn: an owner session is enough to give it.

use std::sync::PoisonError;
use std::time::Duration;

use antenna_proto::LinkId;
use antenna_proto::control::{
    ESCALATE_OWNER, ESCALATION_ANSWERED, ESCALATION_DISMISSED, ESCALATION_MAX_CHARS,
    ESCALATION_OPEN, ESCALATION_SENT, EscalationInfo, TaintInfo, code,
};
use rusqlite::{OptionalExtension, params};

use crate::addressing::AddrReq;
use crate::agents::AgentCtx;
use crate::error::{Error, Result};
use crate::events::NodeEvent;
use crate::node::Session;
use crate::store::AgentRow;

/// The longest the agent's `escalate` waits for the owner's answer.
const MAX_WAIT: Duration = Duration::from_secs(10 * 60);

/// How many answered questions `escalations {all}` lists.
const LIST_ALL: i64 = 200;

/// A question or an answer: 1–4000 characters, no NUL.
fn checked_text(s: &str, what: &str) -> Result<String> {
    let t = s.trim();
    let n = t.chars().count();
    if n == 0 || n > ESCALATION_MAX_CHARS || t.contains('\0') {
        return Err(Error::bad_request(format!(
            "{what}: 1–{ESCALATION_MAX_CHARS} characters"
        )));
    }
    Ok(t.to_string())
}

/// The team (D-111) is read when the question is listed: a worker's team, else a team the agent leads.
const COLUMNS: &str = "e.id, a.name, e.link_id, e.question, e.read_from, e.state, e.answer, e.created_ms, \
     e.answered_ms, e.message_id, COALESCE((SELECT t.name FROM team_members m JOIN teams t ON t.id = m.team_id \
     WHERE m.agent_id = e.agent_id), (SELECT t.name FROM teams t WHERE t.lead_id = e.agent_id ORDER BY t.id LIMIT 1))";

fn row_info(
    r: &rusqlite::Row<'_>,
    labels: &dyn Fn(&LinkId) -> Option<String>,
) -> rusqlite::Result<EscalationInfo> {
    let link: Option<Vec<u8>> = r.get(2)?;
    let link = link.and_then(|b| <[u8; 32]>::try_from(b).ok()).map(LinkId);
    let read_from: String = r.get(4)?;
    Ok(EscalationInfo {
        id: r.get(0)?,
        agent: r.get(1)?,
        to: match &link {
            Some(l) => labels(l).unwrap_or_else(|| l.to_hex()[..8].to_string()),
            None => ESCALATE_OWNER.into(),
        },
        link_id: link.map(|l| l.to_hex()),
        question: r.get(3)?,
        state: r.get(5)?,
        answer: r.get(6)?,
        created_ms: r.get::<_, i64>(7)? as u64,
        answered_ms: r.get::<_, Option<i64>>(8)?.map(|v| v as u64),
        message_id: r.get(9)?,
        team: r.get(10)?,
        read_from: serde_json::from_str::<Vec<TaintInfo>>(&read_from).unwrap_or_default(),
    })
}

impl Session {
    fn link_label(&self, l: &LinkId) -> Option<String> {
        self.link_names().ok()?.get(l).map(|(n, _)| n.clone())
    }

    /// The supervisor contact of agent `id` (`None`: the owner).
    pub(crate) fn escalate_link(&self, id: i64) -> Option<LinkId> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db.conn()
            .query_row(
                "SELECT link_id FROM agent_escalation WHERE agent_id = ?1",
                params![id],
                |r| r.get::<_, Vec<u8>>(0),
            )
            .optional()
            .ok()
            .flatten()
            .and_then(|b| <[u8; 32]>::try_from(b).ok())
            .map(LinkId)
    }

    /// `agent_escalate` (the owner, with the password): where agent `name`'s questions go; `None` is the owner.
    pub fn agent_escalate_to(
        &self,
        name: &str,
        to: Option<String>,
    ) -> Result<antenna_proto::control::AgentInfo> {
        let row: AgentRow = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let row = db.agent_by_name(name)?;
            // A team's worker sees no contacts: its questions go to the owner, who sees its team on the card.
            if to.is_some() && crate::teams::is_worker(&db, row.id) {
                return Err(Error::bad_request(format!(
                    "agent {name} is a team's worker: its questions go to you; set where its lead's questions go"
                )));
            }
            match &to {
                None => {
                    db.conn().execute(
                        "DELETE FROM agent_escalation WHERE agent_id = ?1",
                        params![row.id],
                    )?;
                }
                Some(c) => {
                    let l = db.find_link(c)?.link_id;
                    if row.links.as_ref().is_some_and(|s| !s.contains(&l)) {
                        return Err(Error::bad_request(format!(
                            "{c:?} is not among the links of agent {name}: its questions cannot go to a contact it \
                             does not see"
                        )));
                    }
                    db.conn().execute(
                        "INSERT INTO agent_escalation(agent_id, link_id) VALUES (?1, ?2)
                         ON CONFLICT(agent_id) DO UPDATE SET link_id = excluded.link_id",
                        params![row.id, &l.0[..]],
                    )?;
                }
            }
            db.agent(row.id)?
        };
        tracing::info!(
            "agent {name}: questions go to {}",
            if to.is_some() {
                "a contact"
            } else {
                "the owner"
            }
        );
        Ok(self.agent_info(&row, &self.link_names()?, &self.wake_agent_ids()))
    }

    fn escalation_by_id(&self, id: &str, agent: Option<i64>) -> Result<EscalationInfo> {
        let names = self.link_names()?;
        let labels = |l: &LinkId| names.get(l).map(|(n, _)| n.clone());
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let sql = format!(
            "SELECT {COLUMNS} FROM escalations e JOIN agents a ON a.id = e.agent_id WHERE e.id = ?1 AND (?2 IS NULL OR e.agent_id = ?2)"
        );
        db.conn()
            .query_row(&sql, params![id, agent], |r| row_info(r, &labels))
            .optional()?
            .ok_or_else(|| Error::new(code::NOT_FOUND, format!("no question {id:?}")))
    }

    /// `escalate` (the agent): the question goes to its supervisor. To the owner: stored, announced, and with `wait`
    /// the call waits for the answer. To a contact: sent as the agent's message to that contact in person, under the
    /// policy of `send` (an approval request comes back as `approval_required`, as for `send`).
    pub async fn agent_escalate(
        &self,
        ctx: &AgentCtx,
        question: &str,
        wait: Option<Duration>,
    ) -> Result<EscalationInfo> {
        let question = checked_text(question, "question")?;
        let agent = self.agent_row(ctx)?;
        let read_from = self.agent_session(ctx)?.tainted_by;
        let id = data_encoding::HEXLOWER.encode(&crate::crypto::random::<8>());
        let now = crate::now_ms();
        let worker = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            crate::teams::is_worker(&db, agent.id)
        };
        // A worker asks the owner, whatever is stored for its ID (D-111: it sees no contacts).
        let link = if worker {
            None
        } else {
            self.escalate_link(agent.id)
        };
        let mut state = ESCALATION_OPEN;
        let mut message_id = None;
        if let Some(l) = &link {
            let label = self
                .link_label(l)
                .ok_or_else(|| Error::new(code::NOT_FOUND, "the supervisor contact is gone"))?;
            let text = format!(
                "A question from {}, an agent of my owner, for you as its supervisor:\n\n{question}",
                agent.name
            );
            let sent = self
                .agent_send(
                    ctx,
                    &label,
                    &text,
                    Duration::ZERO,
                    None,
                    &AddrReq::new(Some("person".into()), None, None, None),
                )
                .await?;
            state = ESCALATION_SENT;
            message_id = Some(sent.id);
        }
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db.conn().execute(
                "INSERT INTO escalations(id, agent_id, link_id, question, read_from, state, created_ms, message_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    id,
                    agent.id,
                    link.as_ref().map(|l| l.0.to_vec()),
                    question,
                    serde_json::to_string(&read_from).unwrap_or_else(|_| "[]".into()),
                    state,
                    now as i64,
                    message_id
                ],
            )?;
        }
        let info = self.escalation_by_id(&id, Some(agent.id))?;
        tracing::info!("agent {}: asked {}", agent.name, info.to);
        let _ = self.events.send(NodeEvent::Escalation {
            agent_id: agent.id,
            info: Box::new(info.clone()),
        });
        let Some(wait) = wait.filter(|_| link.is_none()) else {
            return Ok(info);
        };
        let deadline = tokio::time::Instant::now() + wait.min(MAX_WAIT);
        let mut rx = self.inbox.subscribe();
        loop {
            rx.mark_unchanged();
            let now = self.escalation_by_id(&id, Some(agent.id))?;
            if now.state != ESCALATION_OPEN {
                self.mark_delivered(&id);
                return Ok(now);
            }
            if tokio::time::timeout_at(deadline, rx.changed())
                .await
                .is_err()
                || self.is_closed()
            {
                return Ok(now);
            }
        }
    }

    /// `escalation_get` (the agent): one of its own questions.
    pub fn agent_escalation_get(&self, ctx: &AgentCtx, id: &str) -> Result<EscalationInfo> {
        let info = self.escalation_by_id(id, Some(ctx.id))?;
        if info.state == ESCALATION_ANSWERED || info.state == ESCALATION_DISMISSED {
            self.mark_delivered(id);
        }
        Ok(info)
    }

    fn mark_delivered(&self, id: &str) {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = db.conn().execute(
            "UPDATE escalations SET delivered = 1 WHERE id = ?1",
            params![id],
        );
    }

    /// `escalations` (the owner): open questions first, newest first; with `all` also the decided ones.
    pub fn escalations(&self, all: bool) -> Result<Vec<EscalationInfo>> {
        let names = self.link_names()?;
        let labels = |l: &LinkId| names.get(l).map(|(n, _)| n.clone());
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let sql = format!(
            "SELECT {COLUMNS} FROM escalations e JOIN agents a ON a.id = e.agent_id
             WHERE ?1 OR e.state = 'open'
             ORDER BY (e.state = 'open') DESC, e.created_ms DESC LIMIT ?2"
        );
        let mut st = db.conn().prepare(&sql)?;
        let rows = st
            .query_map(params![all, LIST_ALL], |r| row_info(r, &labels))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// `escalation_answer` (the owner): answer an open question, or set it aside. The agent learns it in `wait`,
    /// `inbox`, `escalation_get` and its own `escalation` event.
    pub fn escalation_answer(
        &self,
        id: &str,
        answer: Option<String>,
        dismiss: bool,
    ) -> Result<EscalationInfo> {
        let (state, answer) = match (answer, dismiss) {
            (Some(a), false) => (ESCALATION_ANSWERED, Some(checked_text(&a, "answer")?)),
            (None, true) => (ESCALATION_DISMISSED, None),
            _ => return Err(Error::bad_request("give an answer or dismiss, not both")),
        };
        let agent_id: i64 = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let row: Option<(i64, String)> = db
                .conn()
                .query_row(
                    "SELECT agent_id, state FROM escalations WHERE id = ?1",
                    params![id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let (agent_id, now) =
                row.ok_or_else(|| Error::new(code::NOT_FOUND, format!("no question {id:?}")))?;
            if now != ESCALATION_OPEN {
                return Err(Error::new(
                    code::DENIED,
                    format!("this question is {now}: only an open question is answered"),
                ));
            }
            db.conn().execute(
                "UPDATE escalations SET state = ?2, answer = ?3, answered_ms = ?4 WHERE id = ?1 AND state = 'open'",
                params![id, state, answer, crate::now_ms() as i64],
            )?;
            agent_id
        };
        let info = self.escalation_by_id(id, None)?;
        // Wakes the agent waiting in `escalate`, `wait` or `inbox`
        self.inbox.send_modify(|v| *v += 1);
        let _ = self.events.send(NodeEvent::Escalation {
            agent_id,
            info: Box::new(info.clone()),
        });
        Ok(info)
    }

    /// The agent has decided questions it has not been given yet.
    pub(crate) fn has_escalation_answers(&self, agent_id: i64) -> bool {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db.conn()
            .query_row(
                "SELECT 1 FROM escalations WHERE agent_id = ?1 AND delivered = 0 AND state IN ('answered', 'dismissed')",
                params![agent_id],
                |_| Ok(()),
            )
            .optional()
            .ok()
            .flatten()
            .is_some()
    }

    /// The agent's decided questions it has not been given yet; taking them marks them given.
    pub(crate) fn take_escalation_answers(&self, agent_id: i64) -> Vec<EscalationInfo> {
        let Ok(names) = self.link_names() else {
            return Vec::new();
        };
        let labels = |l: &LinkId| names.get(l).map(|(n, _)| n.clone());
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let sql = format!(
            "SELECT {COLUMNS} FROM escalations e JOIN agents a ON a.id = e.agent_id
             WHERE e.agent_id = ?1 AND e.delivered = 0 AND e.state IN ('answered', 'dismissed') ORDER BY e.answered_ms"
        );
        let rows = db.conn().prepare(&sql).and_then(|mut st| {
            st.query_map(params![agent_id], |r| row_info(r, &labels))?
                .collect::<rusqlite::Result<Vec<_>>>()
        });
        let rows = rows.unwrap_or_default();
        for r in &rows {
            let _ = db.conn().execute(
                "UPDATE escalations SET delivered = 1 WHERE id = ?1",
                params![r.id],
            );
        }
        rows
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_limits() {
        assert!(checked_text("", "q").is_err());
        assert!(checked_text("   ", "q").is_err());
        assert!(checked_text("a\0b", "q").is_err());
        assert!(checked_text(&"x".repeat(ESCALATION_MAX_CHARS + 1), "q").is_err());
        assert_eq!(
            checked_text("  Which branch?\n", "q").unwrap(),
            "Which branch?"
        );
    }
}
