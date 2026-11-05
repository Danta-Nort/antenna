// SPDX-License-Identifier: AGPL-3.0-only
//! Agents that answer other agents' approval requests on the owner's own computers (PG-57, `docs/CONTROL.md` §31,
//! D-127; experimental). The rule: an agent may approve another agent's request when everything is at
//! level 5, the owner's own computers (D-99).
//!
//! - The owner names an **approver**: an agent of this computer, or an agent of an own computer (a contact at level
//!   5) by the name and key it announced on that link (PROTOCOL §21). The scope says whose requests (this computer's
//!   agents) and which kinds ([`antenna_proto::control::DELEGABLE_KINDS`]). Setting or widening it takes the password
//!   or an owner proof; narrowing or removing it does not (D-84).
//! - **The daemon that holds the request decides** (SPEC §9), at the moment of the answer: the scope, not the
//!   approver's own request, not an approver's request (no chains), and the level-5 circle ([`rules`]): the request's
//!   contact and target, every link the asking agent's session read, the approver's own session and, for an approver
//!   on another computer, that computer's link, all at level 5 now and unchanged since the request was made.
//!   Anything else stays with the person, who is told why on the card.
//! - An approved request is carried out by the daemon as after the owner's approval (D-100), and the asking agent
//!   gets the same `approval_resolved`, naming the approver. Every answer is in the link's audit log with the
//!   approver as the actor, and in the list of delegated answers the owner reads (`approvers`).
//! - An approver on another computer answers through that computer's daemon, which signs with the agent's key in the
//!   link over this computer's one-time challenge for that request (`node::own_devices::delegated`). It is never the
//!   owner proof of D-102/D-106.

mod local;
pub(crate) mod remote;
pub mod rules;

pub(crate) use local::checked_reason;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Mutex as StdMutex, PoisonError};

use antenna_proto::{
    LinkId,
    control::{DelegatedAnswer, ToAnswerFact, code},
};
use rusqlite::{OptionalExtension, params};

use crate::{
    crypto,
    error::{Error, Result},
    store::Db,
};

/// How many delegated answers are kept for the owner's list.
const KEEP_ANSWERS: i64 = 500;
/// At most this many challenges outstanding per link for approver agents' answers.
const CHALLENGES_PER_LINK: usize = 16;
/// After this many unverifiable answers in a row from one computer, its approver agents' answers pause.
const FAILS_MAX: u32 = 3;
/// How long they pause (doubling with every further failure, at most eight times this).
const PAUSE_MS: u64 = 60_000;

/// Who answers in the owner's place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Approver {
    /// An agent of this computer.
    Local(i64),
    /// An agent of an own computer: the link, the name it announced there, its key there when the owner named it.
    Remote {
        /// The own computer's link.
        link: LinkId,
        /// The agent's name on that link.
        name: String,
        /// Its Ed25519 key in that link.
        key: [u8; 32],
    },
}

/// One delegation, as stored.
#[derive(Debug, Clone)]
pub(crate) struct Delegation {
    /// The approver.
    pub(crate) approver: Approver,
    /// Whose requests: agent IDs of this computer; `None`: all.
    pub(crate) agents: Option<Vec<i64>>,
    /// Which kinds; `None`: all.
    pub(crate) kinds: Option<Vec<String>>,
    /// When the owner set it.
    pub(crate) created_ms: u64,
}

/// What the session keeps in memory for delegated answers.
#[derive(Default)]
pub(crate) struct DelegationState {
    /// When each link's level last changed in this daemon's life: a request made before that is the person's.
    pub(crate) trust_changed: StdMutex<HashMap<LinkId, u64>>,
    /// Requests waiting for an approver, not yet given to it in `wait`/`inbox`: agent ID → facts.
    pub(crate) facts: StdMutex<HashMap<i64, Vec<ToAnswerFact>>>,
    /// Requests of other own computers already offered to an approver here: (link, request, agent).
    pub(crate) offered: StdMutex<HashSet<(LinkId, String, i64)>>,
    /// Challenges this computer issued for approver agents' answers, and failures in a row, per link.
    pub(crate) challenges: StdMutex<Challenges>,
}

/// Facts kept per approver until its next `wait`/`inbox` (the oldest go first).
const MAX_FACTS: usize = 64;

impl DelegationState {
    /// A request waits for agent `agent_id`'s answer.
    pub(crate) fn push_fact(&self, agent_id: i64, fact: ToAnswerFact) {
        let mut g = self.facts.lock().unwrap_or_else(PoisonError::into_inner);
        let q = g.entry(agent_id).or_default();
        if q.iter().any(|f| f.id == fact.id && f.device == fact.device) {
            return;
        }
        if q.len() >= MAX_FACTS {
            q.remove(0);
        }
        q.push(fact);
    }

    /// Whether facts wait for agent `agent_id`.
    pub(crate) fn has_facts(&self, agent_id: i64) -> bool {
        self.facts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&agent_id)
            .is_some_and(|q| !q.is_empty())
    }

    /// The facts for agent `agent_id`; taking them marks them given.
    pub(crate) fn take_facts(&self, agent_id: i64) -> Vec<ToAnswerFact> {
        self.facts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&agent_id)
            .unwrap_or_default()
    }

    /// A link's level changed now.
    pub(crate) fn note_trust_change(&self, link: LinkId, now: u64) {
        self.trust_changed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(link, now);
    }

    /// When a link's level last changed.
    pub(crate) fn changed_ms(&self, link: &LinkId) -> Option<u64> {
        self.trust_changed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(link)
            .copied()
    }
}

/// Challenges for approver agents' answers from other own computers: each one is for one request on one link, used
/// once, fresh for a short time. Apart from the owner-proof challenges of D-114, so neither path takes the other's.
#[derive(Debug, Default)]
pub(crate) struct Challenges {
    issued: HashMap<LinkId, VecDeque<([u8; 32], String, u64)>>,
    fails: HashMap<LinkId, (u32, u64)>,
}

impl Challenges {
    /// A new challenge for an answer to request `id` that comes over `link`.
    pub(crate) fn issue(
        &mut self,
        link: LinkId,
        id: &str,
        now: u64,
        ttl_ms: u64,
    ) -> ([u8; 32], u64) {
        let q = self.issued.entry(link).or_default();
        q.retain(|(_, _, exp)| *exp > now);
        while q.len() >= CHALLENGES_PER_LINK {
            q.pop_front();
        }
        let nonce = crypto::random::<32>();
        let exp = now.saturating_add(ttl_ms);
        q.push_back((nonce, id.to_string(), exp));
        (nonce, exp)
    }

    /// Takes the challenge an answer names: once, whatever follows; only on the link and for the request it was
    /// issued for, only while fresh.
    pub(crate) fn take(
        &mut self,
        link: &LinkId,
        nonce: &[u8; 32],
        id: &str,
        now: u64,
    ) -> Result<()> {
        let bad = |why: &str| {
            Error::new(
                code::CHALLENGE_INVALID,
                format!("the challenge {why}: ask that computer for a new one"),
            )
        };
        let q = self
            .issued
            .get_mut(link)
            .ok_or_else(|| bad("was not issued to this computer"))?;
        let i = q
            .iter()
            .position(|(n, _, _)| crypto::ct_eq(n, nonce))
            .ok_or_else(|| bad("is unknown or already used"))?;
        let (_, for_id, exp) = q.remove(i).ok_or_else(|| bad("is unknown"))?;
        if for_id != id {
            return Err(bad("was issued for another request"));
        }
        if exp <= now {
            return Err(bad("expired"));
        }
        Ok(())
    }

    /// Refused while that computer's approver answers pause after unverifiable ones.
    pub(crate) fn check_pause(&self, link: &LinkId, now: u64) -> Result<()> {
        match self.fails.get(link) {
            Some((_, until)) if now < *until => Err(Error::new(
                code::RATE_LIMITED,
                format!(
                    "too many answers from that computer could not be verified; try again in {} s",
                    (until - now).div_ceil(1000)
                ),
            )),
            _ => Ok(()),
        }
    }

    /// Records whether an answer from `link` verified.
    pub(crate) fn record(&mut self, link: LinkId, ok: bool, now: u64) {
        if ok {
            self.fails.remove(&link);
            return;
        }
        let e = self.fails.entry(link).or_insert((0, 0));
        e.0 += 1;
        if e.0 >= FAILS_MAX {
            e.1 = now.saturating_add(PAUSE_MS << (e.0 - FAILS_MAX).min(3));
        }
    }
}

fn json_ids(v: &Option<Vec<i64>>) -> Option<String> {
    v.as_ref()
        .map(|a| serde_json::to_string(a).unwrap_or_else(|_| "[]".into()))
}

fn json_kinds(v: &Option<Vec<String>>) -> Option<String> {
    v.as_ref()
        .map(|a| serde_json::to_string(a).unwrap_or_else(|_| "[]".into()))
}

type Row = (
    Option<i64>,
    Option<Vec<u8>>,
    Option<String>,
    Option<Vec<u8>>,
    Option<String>,
    Option<String>,
    i64,
);

fn delegation((agent, link, name, key, agents, kinds, created): Row) -> Result<Delegation> {
    let approver = match (agent, link, name, key) {
        (Some(id), None, _, _) => Approver::Local(id),
        (None, Some(l), Some(name), Some(k)) => Approver::Remote {
            link: LinkId(
                l.try_into()
                    .map_err(|_| Error::internal("db: approver link is not 32 bytes"))?,
            ),
            name,
            key: k
                .try_into()
                .map_err(|_| Error::internal("db: approver key is not 32 bytes"))?,
        },
        _ => return Err(Error::internal("db: an approver row names nobody")),
    };
    let parse = |s: Option<String>, what: &str| -> Result<Option<serde_json::Value>> {
        s.map(|s| {
            serde_json::from_str(&s)
                .map_err(|e| Error::internal(format!("db: approver {what}: {e}")))
        })
        .transpose()
    };
    Ok(Delegation {
        approver,
        agents: parse(agents, "agents")?
            .map(serde_json::from_value)
            .transpose()
            .map_err(|e| Error::internal(format!("db: approver agents: {e}")))?,
        kinds: parse(kinds, "kinds")?
            .map(serde_json::from_value)
            .transpose()
            .map_err(|e| Error::internal(format!("db: approver kinds: {e}")))?,
        created_ms: u64::try_from(created).unwrap_or(0),
    })
}

/// Every delegation.
pub(crate) fn load(db: &Db) -> Result<Vec<Delegation>> {
    let mut st = db.conn().prepare(
        "SELECT agent_id, link_id, peer_agent, peer_key, agents, kinds, created_ms FROM approvers ORDER BY id",
    )?;
    let rows = st
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<Row>>>()?;
    rows.into_iter().map(delegation).collect()
}

/// The delegation of `approver` (a remote one by link and name; its key is compared by the caller).
pub(crate) fn find(db: &Db, approver: &Approver) -> Result<Option<Delegation>> {
    Ok(load(db)?
        .into_iter()
        .find(|d| match (&d.approver, approver) {
            (Approver::Local(a), Approver::Local(b)) => a == b,
            (
                Approver::Remote { link, name, .. },
                Approver::Remote {
                    link: l2, name: n2, ..
                },
            ) => link == l2 && name == n2,
            _ => false,
        }))
}

/// Sets (or replaces the scope of) `d`.
pub(crate) fn save(db: &Db, d: &Delegation) -> Result<()> {
    remove(db, &d.approver)?;
    let (agent, link, name, key) = match &d.approver {
        Approver::Local(id) => (Some(*id), None, None, None),
        Approver::Remote { link, name, key } => (
            None,
            Some(link.0.to_vec()),
            Some(name.clone()),
            Some(key.to_vec()),
        ),
    };
    db.conn().execute(
        "INSERT INTO approvers(agent_id, link_id, peer_agent, peer_key, agents, kinds, created_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            agent,
            link,
            name,
            key,
            json_ids(&d.agents),
            json_kinds(&d.kinds),
            d.created_ms as i64
        ],
    )?;
    Ok(())
}

/// Removes the delegation of `approver`; whether there was one.
pub(crate) fn remove(db: &Db, approver: &Approver) -> Result<bool> {
    let n = match approver {
        Approver::Local(id) => db
            .conn()
            .execute("DELETE FROM approvers WHERE agent_id = ?1", params![id])?,
        Approver::Remote { link, name, .. } => db.conn().execute(
            "DELETE FROM approvers WHERE link_id = ?1 AND peer_agent = ?2",
            params![&link.0[..], name],
        )?,
    };
    Ok(n > 0)
}

/// Removes every delegation to agents of `link` (its level dropped below 5: raising it back does not restore them).
pub(crate) fn remove_link(db: &Db, link: &LinkId) -> Result<usize> {
    Ok(db.conn().execute(
        "DELETE FROM approvers WHERE link_id = ?1",
        params![&link.0[..]],
    )?)
}

/// Records an answer for the owner's list (the newest [`KEEP_ANSWERS`] are kept).
pub(crate) fn record(db: &Db, a: &DelegatedAnswer) -> Result<()> {
    db.conn().execute(
        "INSERT INTO delegated_answers(approval_id, action, requester, contact, target, approver, device, decision,
           reason, summary, at_ms, why)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            a.approval_id,
            a.action,
            a.requester,
            a.contact,
            a.target,
            a.approver,
            a.device,
            a.decision,
            a.reason,
            a.summary,
            a.at_ms as i64,
            a.why
        ],
    )?;
    db.conn().execute(
        "DELETE FROM delegated_answers WHERE seq <= (SELECT max(seq) FROM delegated_answers) - ?1",
        params![KEEP_ANSWERS],
    )?;
    Ok(())
}

/// The latest answers, newest first.
pub(crate) fn answers(db: &Db, limit: usize) -> Result<Vec<DelegatedAnswer>> {
    let mut st = db.conn().prepare(
        "SELECT approval_id, action, requester, contact, target, approver, device, decision, reason, summary, at_ms,
           why
         FROM delegated_answers ORDER BY seq DESC LIMIT ?1",
    )?;
    let rows = st
        .query_map(params![i64::try_from(limit).unwrap_or(200)], |r| {
            Ok(DelegatedAnswer {
                approval_id: r.get(0)?,
                action: r.get(1)?,
                requester: r.get(2)?,
                contact: r.get(3)?,
                target: r.get(4)?,
                approver: r.get(5)?,
                device: r.get(6)?,
                decision: r.get(7)?,
                reason: r.get(8)?,
                summary: r.get(9)?,
                at_ms: u64::try_from(r.get::<_, i64>(10)?).unwrap_or(0),
                why: r.get(11)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// Whether an approver row exists for local agent `id` (cheap: the chain check of every request).
pub(crate) fn is_local_approver(db: &Db, id: i64) -> bool {
    db.conn()
        .query_row(
            "SELECT 1 FROM approvers WHERE agent_id = ?1",
            params![id],
            |_| Ok(()),
        )
        .optional()
        .ok()
        .flatten()
        .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenges_are_per_request_once_and_fresh() {
        let mut c = Challenges::default();
        let l = LinkId([1; 32]);
        let other = LinkId([2; 32]);
        let (n, _) = c.issue(l, "k2", 1000, 60_000);
        assert_eq!(
            c.take(&other, &n, "k2", 1001).unwrap_err().code,
            code::CHALLENGE_INVALID,
            "another link"
        );
        let (n2, _) = c.issue(l, "k2", 1000, 60_000);
        assert!(c.take(&l, &n2, "k3", 1001).is_err(), "another request");
        assert!(
            c.take(&l, &n2, "k2", 1001).is_err(),
            "taken by the failed attempt"
        );
        assert!(c.take(&l, &n, "k2", 1001).is_ok());
        assert!(c.take(&l, &n, "k2", 1002).is_err(), "used once");
        let (n3, _) = c.issue(l, "k2", 1000, 10);
        assert!(c.take(&l, &n3, "k2", 2000).is_err(), "expired");
        for _ in 0..FAILS_MAX {
            c.record(l, false, 5000);
        }
        assert_eq!(
            c.check_pause(&l, 5001).unwrap_err().code,
            code::RATE_LIMITED
        );
        assert!(c.check_pause(&l, 5000 + PAUSE_MS).is_ok());
        c.record(l, true, 6000);
        assert!(c.check_pause(&l, 6001).is_ok());
    }
}
