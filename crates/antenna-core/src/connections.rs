// SPDX-License-Identifier: AGPL-3.0-only
//! Connections between agents (`docs/CONTROL.md` §30, the agent map, D-123; experimental).
//!
//! A connection is the owner's line between one of this computer's agents and a counterpart on another computer: a
//! contact's agent, an own computer's agent, or a contact's person. It sets two things that the daemon already
//! enforces elsewhere and nothing new about permissions:
//! - the agent's **default counterpart**: where its `send` goes when it names no contact (and, on that link, when it
//!   has read nothing there yet). The policy checks every such message exactly like any other (SPEC §9);
//! - optionally the contact's place in the agent's **task authority** (D-88), the existing `tasks_from` list.
//!
//! The other side of a line to an own computer is that computer's decision: this node asks over their level-5 link
//! (`docs/PROTOCOL.md` §24, `connect`), and that node makes an **approval request** for its owner, who approves it
//! there or from another own device (D-106). No owner command becomes remote: the asking node can only cause a request
//! that changes nothing until approved. A contact that is not an own computer is never asked.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, PoisonError};

use antenna_proto::{
    LinkId,
    control::{
        AgentConnect, AgentConnected, AgentDisconnect, AgentTraffic, Counterpart, Grants,
        OtherSide, Reply, TrafficPair, code, other_side,
    },
    device::{ConnectAsk, DeviceMsg, DeviceReply},
};
use rusqlite::{OptionalExtension, params};

use crate::{
    approvals::Continuation,
    error::{Error, Result},
    node::Session,
    now_ms, policy,
    store::{AgentRow, Db, LinkRow},
};

/// Connection requests from one own computer that may wait for the owner here at once.
const MAX_PENDING_PER_LINK: usize = 8;
/// How long to wait for a connection to an own computer whose features are not known yet.
const CONNECT_WAIT: std::time::Duration = std::time::Duration::from_secs(5);
/// Traffic pairs in one `agent_traffic` reply.
const MAX_PAIRS: usize = 500;
/// The action of an approval request for the other side of a connection, and of one that removes it.
pub(crate) const ACTION_CONNECT: &str = "connect_agent";
/// See [`ACTION_CONNECT`].
pub(crate) const ACTION_DISCONNECT: &str = "disconnect_agent";
/// The reason such a request carries.
const REASON: &str = "agent_connect";

/// An agent's default counterpart as stored: the link, and the contact's agent (`None`: the contact's person).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CounterpartRow {
    pub(crate) link: LinkId,
    pub(crate) agent: Option<String>,
}

/// The counterpart of agent `agent_id`, if it has one.
pub(crate) fn counterpart(db: &Db, agent_id: i64) -> Result<Option<CounterpartRow>> {
    let row = db
        .conn()
        .query_row(
            "SELECT link_id, agent FROM agent_counterparts WHERE agent_id = ?1",
            params![agent_id],
            |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Option<String>>(1)?)),
        )
        .optional()?;
    row.map(|(l, agent)| {
        Ok(CounterpartRow {
            link: LinkId(
                <[u8; 32]>::try_from(l)
                    .map_err(|_| Error::internal("db: counterpart link is not 32 bytes"))?,
            ),
            agent,
        })
    })
    .transpose()
}

fn set_counterpart(db: &Db, agent_id: i64, cp: Option<&CounterpartRow>) -> Result<()> {
    // An agent has one default counterpart: one on a link replaces one on this computer (D-132)
    if cp.is_some() {
        crate::local_routes::clear_local_counterpart(db, agent_id)?;
    }
    match cp {
        Some(c) => db.conn().execute(
            "INSERT INTO agent_counterparts(agent_id, link_id, agent, created_ms) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(agent_id) DO UPDATE SET link_id = excluded.link_id, agent = excluded.agent,
               created_ms = excluded.created_ms",
            params![agent_id, &c.link.0[..], c.agent, now_ms() as i64],
        )?,
        None => db.conn().execute(
            "DELETE FROM agent_counterparts WHERE agent_id = ?1",
            params![agent_id],
        )?,
    };
    Ok(())
}

/// Why agent `row` cannot have connections: the daemon decides where a link's wake agent, a team's worker and a
/// local-model agent write.
pub(crate) fn not_connectable(db: &Db, row: &AgentRow) -> Result<Option<String>> {
    let name = &row.name;
    if db.wake_rules()?.iter().any(|(_, id, _, _)| *id == row.id) {
        return Ok(Some(format!(
            "agent {name} replies on wake: it answers whoever wrote, so it has no default counterpart"
        )));
    }
    if crate::teams::is_worker(db, row.id) {
        return Ok(Some(format!(
            "agent {name} is a team's worker: its team decides whom it works with"
        )));
    }
    if crate::local::is_local_agent(db, row.id) {
        return Ok(Some(format!(
            "agent {name} runs on a local model: it answers whoever wrote; set whose tasks it takes in Agents"
        )));
    }
    Ok(None)
}

/// The task authority of `row` with `link` added (`on`) or removed: the explicit list it becomes, or `None` when
/// nothing changes. From the default (the links at level 5 in its scope, D-88) the list is that set with the change.
fn tasks_with(
    row: &AgentRow,
    names: &HashMap<LinkId, (String, u8)>,
    link: &LinkId,
    on: bool,
) -> Option<Vec<LinkId>> {
    let now = crate::agents::task_links(row, names, false);
    if now.contains(link) == on {
        return None;
    }
    let mut v: Vec<LinkId> = now.into_iter().filter(|l| l != link).collect();
    if on {
        v.push(*link);
    }
    v.sort_by_key(|l| l.0);
    Some(v)
}

/// What a connection ask changes for agent `row` on `link`: the new counterpart (outer `None`: unchanged) and the new
/// task list (`None`: unchanged).
type Change = (Option<Option<CounterpartRow>>, Option<Vec<LinkId>>);

fn change_for(
    row: &AgentRow,
    current: Option<&CounterpartRow>,
    names: &HashMap<LinkId, (String, u8)>,
    link: &LinkId,
    ask: &ConnectAsk,
) -> Change {
    let cp = match &ask.peer_agent {
        Some(a) => {
            let want = CounterpartRow {
                link: *link,
                agent: Some(a.clone()),
            };
            (current != Some(&want)).then_some(Some(want))
        }
        // Disconnect: only a counterpart on this link is the sender's to clear
        None => current.is_some_and(|c| c.link == *link).then_some(None),
    };
    let tasks = ask.tasks.and_then(|on| tasks_with(row, names, link, on));
    (cp, tasks)
}

impl Session {
    /// The default counterpart of agent `row` as the owner and the agent see it (`None` when its link is gone).
    pub(crate) fn counterpart_view(&self, row: &AgentRow) -> Option<Counterpart> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let cp = counterpart(&db, row.id).ok().flatten()?;
        let link = db.link(&cp.link).ok()?;
        Some(Counterpart {
            contact: link.label,
            agent: cp.agent,
            local: false,
        })
    }

    /// The counterpart an agent's `send` without a contact goes to: its link row and its agent.
    pub(crate) fn counterpart_target(&self, agent: &AgentRow) -> Result<(LinkRow, Option<String>)> {
        let cp = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            counterpart(&db, agent.id)?
        };
        let cp = cp.ok_or_else(|| {
            Error::bad_request(
                "contact is required: this agent has no default counterpart (the owner sets one on the agent map)",
            )
        })?;
        let row = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&cp.link)
            .map_err(|_| {
                Error::new(
                    code::NOT_FOUND,
                    "the default counterpart's contact no longer exists",
                )
            })?;
        Ok((row, cp.agent))
    }

    /// For the status to an own computer on `link` (PROTOCOL §24, `agent-connect/0`): per agent of this computer, the
    /// recipient's agent it is connected to there (`""`: the recipient's person) and whether it takes the recipient's
    /// messages as tasks. A counterpart on another link is not told.
    pub(crate) fn connection_facts(
        &self,
        link: &LinkId,
    ) -> HashMap<String, (Option<String>, bool)> {
        let Ok(names) = self.link_names() else {
            return HashMap::new();
        };
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let Ok(rows) = db.agents() else {
            return HashMap::new();
        };
        let wake: HashSet<i64> = db
            .wake_rules()
            .map(|r| r.into_iter().map(|(_, id, _, _)| id).collect())
            .unwrap_or_default();
        rows.iter()
            .map(|r| {
                let cp = counterpart(&db, r.id)
                    .ok()
                    .flatten()
                    .filter(|c| c.link == *link)
                    .map(|c| c.agent.unwrap_or_default());
                let tasks =
                    crate::agents::task_links(r, &names, wake.contains(&r.id)).contains(link);
                (r.name.clone(), (cp, tasks))
            })
            .collect()
    }

    /// Checks of the owner's connect and disconnect: the agent and the contact in its scope.
    fn connect_parts(&self, name: &str, contact: &str) -> Result<(AgentRow, LinkRow)> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let row = db.agent_by_name(name)?;
        if let Some(why) = not_connectable(&db, &row)? {
            return Err(Error::new(code::DENIED, why));
        }
        let link = db.find_link(contact)?;
        if row
            .links
            .as_ref()
            .is_some_and(|s| !s.contains(&link.link_id))
        {
            return Err(Error::bad_request(format!(
                "{contact:?} is not among the links of agent {name}: it cannot write there"
            )));
        }
        Ok((row, link))
    }

    /// `agent_connect` (the caller has checked the password): this side now, the other side asked of an own computer.
    pub async fn agent_connect(self: &Arc<Self>, req: &AgentConnect) -> Result<AgentConnected> {
        if let Some(peer) = &req.local {
            return self.agent_connect_local(req, peer);
        }
        let (row, link) = self.connect_parts(&req.name, &req.contact)?;
        if let Some(a) = &req.agent {
            crate::agents::valid_name(a)?;
            let known = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                crate::chats::known_agent(db.conn(), &link.link_id, a)?
            };
            if !known && !self.device_lists_agent(&link.link_id, a) {
                return Err(Error::new(
                    code::NOT_FOUND,
                    format!(
                        "no agent named {a} at {}: it has not announced itself on this link",
                        link.label
                    ),
                ));
            }
        }
        let names = self.link_names()?;
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            set_counterpart(
                &db,
                row.id,
                Some(&CounterpartRow {
                    link: link.link_id,
                    agent: req.agent.clone(),
                }),
            )?;
            if let Some(v) = req
                .tasks
                .and_then(|on| tasks_with(&row, &names, &link.link_id, on))
            {
                db.agent_set_tasks(row.id, Some(&v))?;
            }
        }
        let shown = req.agent.as_deref().unwrap_or("the person");
        tracing::info!(
            "agent {}: default counterpart {shown} at {}",
            row.name,
            link.label
        );
        self.receipt(
            &link.link_id,
            "owner",
            "agent_connect",
            "set",
            &format!(
                "{} → {shown}{}",
                row.name,
                match req.tasks {
                    Some(true) => ", takes tasks",
                    Some(false) => ", no tasks",
                    None => "",
                }
            ),
            None,
            None,
        );
        self.emit_agent(&row.name, "connection");
        let other = match &req.agent {
            None => side(other_side::PERSON),
            Some(_) if !req.ask => side(other_side::NOT_ASKED),
            Some(peer) => {
                let ask = ConnectAsk {
                    agent: peer.clone(),
                    peer_agent: Some(self.agent_public_name(&row.name, &link.link_id)),
                    tasks: req.peer_tasks,
                };
                self.ask_other_side(&link, ask).await
            }
        };
        Ok(AgentConnected {
            agent: self.agent_info_by_name(&row.name)?,
            other_side: other,
        })
    }

    /// `agent_disconnect` (an owner session: it only takes away).
    pub async fn agent_disconnect(
        self: &Arc<Self>,
        req: &AgentDisconnect,
    ) -> Result<AgentConnected> {
        if let Some(peer) = &req.local {
            if req.contact.is_some() || req.agent.is_some() {
                return Err(Error::bad_request(
                    "local names an agent of this computer: no contact and no agent with it",
                ));
            }
            return self.agent_disconnect_local(&req.name, peer);
        }
        let (current, local) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let row = db.agent_by_name(&req.name)?;
            let local = crate::local_routes::local_counterpart(&db, row.id)?
                .and_then(|id| db.agent(id).ok())
                .map(|a| a.name);
            (counterpart(&db, row.id)?, local)
        };
        // The agent's own counterpart is an agent of this computer: that route
        if req.contact.is_none()
            && let Some(peer) = local
        {
            return self.agent_disconnect_local(&req.name, &peer);
        }
        // The line named, or the agent's own counterpart
        let (link, peer) = match &req.contact {
            Some(c) => (self.find_link(c)?, req.agent.clone()),
            None => {
                let cp = current.clone().ok_or_else(|| {
                    Error::bad_request(format!("agent {} has no default counterpart", req.name))
                })?;
                let link = self
                    .db
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .link(&cp.link)?;
                (link, cp.agent)
            }
        };
        let row = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db.agent_by_name(&req.name)?
        };
        let names = self.link_names()?;
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let mine = CounterpartRow {
                link: link.link_id,
                agent: peer.clone(),
            };
            if current.as_ref() == Some(&mine) {
                set_counterpart(&db, row.id, None)?;
            }
            if req.tasks == Some(false)
                && let Some(v) = tasks_with(&row, &names, &link.link_id, false)
            {
                db.agent_set_tasks(row.id, Some(&v))?;
            }
        }
        let shown = peer.as_deref().unwrap_or("the person");
        tracing::info!(
            "agent {}: disconnected from {shown} at {}",
            row.name,
            link.label
        );
        self.receipt(
            &link.link_id,
            "owner",
            "agent_disconnect",
            "set",
            &format!("{} ↛ {shown}", row.name),
            None,
            None,
        );
        self.emit_agent(&row.name, "connection");
        let other = match &peer {
            None => side(other_side::PERSON),
            Some(_) if !req.ask => side(other_side::NOT_ASKED),
            Some(p) => {
                let ask = ConnectAsk {
                    agent: p.clone(),
                    peer_agent: None,
                    tasks: req.peer_tasks.filter(|t| !t),
                };
                self.ask_other_side(&link, ask).await
            }
        };
        Ok(AgentConnected {
            agent: self.agent_info_by_name(&row.name)?,
            other_side: other,
        })
    }

    /// Ask the computer on `link` for the other side: only an own computer (level 5 here) whose node announced
    /// `agent-connect/0`; a contact is never asked (its side is its owner's decision).
    async fn ask_other_side(self: &Arc<Self>, link: &LinkRow, ask: ConnectAsk) -> OtherSide {
        if link.trust != 5 {
            return side(other_side::CONTACT_DECIDES);
        }
        let Ok(rt) = self.rt(&link.link_id) else {
            return unreachable_side("the link is not running");
        };
        // A link whose features are not known yet learns them on its first connection
        if !rt.shared.peer_features_known() {
            match tokio::time::timeout(CONNECT_WAIT, rt.shared.connect_raw()).await {
                Ok(Ok(_)) => {}
                Ok(Err(e)) => return unreachable_side(&e.message),
                Err(_) => return unreachable_side("no answer"),
            }
        }
        if !rt.shared.peer_supports_agent_connect() {
            return side(other_side::UNSUPPORTED);
        }
        match rt.shared.device_send(&DeviceMsg::Connect(ask)).await {
            Ok(Some(DeviceReply::ConnectAsked { id, state })) if state == "pending" => OtherSide {
                state: other_side::REQUESTED.into(),
                id: Some(id),
                message: None,
                code: None,
            },
            Ok(Some(DeviceReply::ConnectAsked { .. })) => side(other_side::UNCHANGED),
            Ok(_) => refused_side(code::INTERNAL, "an unexpected answer"),
            Err(e) if matches!(e.code, code::NETWORK | code::TIMEOUT) => {
                unreachable_side(&e.message)
            }
            Err(e) => refused_side(e.code, refused_words(e.code)),
        }
    }

    /// A `connect` of an own computer (`docs/PROTOCOL.md` §24): checked, then an approval request for the owner here
    /// (nothing changes before it is approved), or `unchanged`.
    pub(crate) fn connect_ask_in(&self, link: LinkId, ask: &ConnectAsk) -> Result<DeviceReply> {
        if self.link_trust(&link) != 5 {
            return Err(Error::new("level", "not at level 5"));
        }
        ask.check()
            .map_err(|f| Error::bad_request(format!("connect: {f}")))?;
        let names = self.link_names()?;
        let (row, label, current) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let row = db
                .agent_by_name(&ask.agent)
                .map_err(|_| Error::new(code::NOT_FOUND, "no such agent"))?;
            if not_connectable(&db, &row)?.is_some() {
                return Err(Error::new(code::DENIED, "that agent cannot be connected"));
            }
            if row.links.as_ref().is_some_and(|s| !s.contains(&link)) {
                return Err(Error::bad_request(
                    "that agent's links do not include the asking computer",
                ));
            }
            let label = db.link(&link)?.label;
            let current = counterpart(&db, row.id)?;
            (row, label, current)
        };
        let (cp, tasks) = change_for(&row, current.as_ref(), &names, &link, ask);
        if cp.is_none() && tasks.is_none() {
            return Ok(DeviceReply::ConnectAsked {
                id: String::new(),
                state: "unchanged".into(),
            });
        }
        let pending = self
            .continuations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .filter(|c| matches!(c, Continuation::Connect { link: l, .. } if *l == link))
            .count();
        if pending >= MAX_PENDING_PER_LINK {
            return Err(Error::new(
                code::RATE_LIMITED,
                "too many connection requests from that computer are waiting",
            ));
        }
        let mut salt = 0;
        let mut r = self.gate(
            connect_approval(&link, &label, &row.name, ask, salt),
            None,
            &link,
            &label,
        );
        // The same ask was approved and carried out earlier, and the state went back since (the owner changed it
        // here): a new request, not the old one's result
        if matches!(&r, Err(e) if e.code == code::APPROVAL_USED) {
            salt = now_ms();
            r = self.gate(
                connect_approval(&link, &label, &row.name, ask, salt),
                None,
                &link,
                &label,
            );
        }
        self.keep_for_approval(&r, || Continuation::Connect {
            link,
            agent_id: row.id,
            ask: ask.clone(),
            salt,
        });
        match r {
            Err(Error {
                code: code::APPROVAL_REQUIRED,
                approval: Some(info),
                ..
            }) => Ok(DeviceReply::ConnectAsked {
                id: info.id,
                state: "pending".into(),
            }),
            Err(e) => Err(e),
            // A request with a reason always needs the owner; an approval of exactly this one was used already
            Ok(_) => Err(Error::new(code::APPROVAL_USED, "already carried out")),
        }
    }

    /// The owner approved the other side of a connection (D-100): checked again, the approval used up (an approved
    /// request is carried out once), then applied.
    pub(crate) fn connect_apply(
        &self,
        approval_id: &str,
        link: &LinkId,
        agent_id: i64,
        ask: &ConnectAsk,
        salt: u64,
    ) -> Result<Reply> {
        if self.link_trust(link) != 5 {
            return Err(Error::new(
                code::FORBIDDEN,
                "that computer is no longer at ∞ (trust level 5) here",
            ));
        }
        let names = self.link_names()?;
        let (agent, label) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            (db.agent(agent_id)?.name, db.link(link)?.label)
        };
        self.gate(
            connect_approval(link, &label, &agent, ask, salt),
            Some(approval_id),
            link,
            &label,
        )?;
        let name = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let row = db.agent(agent_id)?;
            if row.links.as_ref().is_some_and(|s| !s.contains(link)) {
                return Err(Error::bad_request(
                    "the agent's links no longer include that computer",
                ));
            }
            let current = counterpart(&db, row.id)?;
            let (cp, tasks) = change_for(&row, current.as_ref(), &names, link, ask);
            if let Some(cp) = cp {
                set_counterpart(&db, row.id, cp.as_ref())?;
            }
            if let Some(v) = tasks {
                db.agent_set_tasks(row.id, Some(&v))?;
            }
            row.name
        };
        tracing::info!("agent {name}: connection from an own computer applied");
        self.emit_agent(&name, "connection");
        Ok(Reply::Agents {
            agents: vec![self.agent_info_by_name(&name)?],
        })
    }

    /// `agent_traffic`: who talked to whom in the last `days` days, from the stored display columns.
    pub fn agent_traffic(&self, days: Option<u32>) -> Result<AgentTraffic> {
        let days = u64::from(days.unwrap_or(30).clamp(1, 365));
        let since = now_ms().saturating_sub(days * 86_400_000);
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let labels: HashMap<LinkId, String> = db
            .links()?
            .into_iter()
            .map(|r| (r.link_id, r.label))
            .collect();
        // The public name `wake` of a link's wake agent maps back to the agent's own name
        let wake: HashMap<LinkId, String> = db
            .wake_rules()?
            .into_iter()
            .filter_map(|(l, id, _, _)| db.agent(id).ok().map(|a| (l, a.name)))
            .collect();
        let mut st = db.conn().prepare(
            "SELECT link_id, direction, coalesce(agent, ''), coalesce(to_kind, ''), coalesce(to_agent, ''),
                    max(received_ms), count(*)
             FROM messages WHERE kind = 'text' AND received_ms >= ?1
             GROUP BY link_id, direction, agent, to_kind, to_agent",
        )?;
        let rows = st.query_map(params![since as i64], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, i64>(5)?,
                r.get::<_, i64>(6)?,
            ))
        })?;
        let mut pairs: HashMap<(String, LinkId, String), TrafficPair> = HashMap::new();
        for r in rows {
            let (link, dir, agent, to_kind, to_agent, last, n) = r?;
            let Ok(link) = <[u8; 32]>::try_from(link).map(LinkId) else {
                continue;
            };
            let Some(contact) = labels.get(&link) else {
                continue;
            };
            if to_kind == "everyone" {
                continue;
            }
            let addressed = if to_kind == "agent" {
                to_agent
            } else {
                String::new()
            };
            let (ours, theirs, out) = if dir == "out" {
                (agent, addressed, true)
            } else {
                (addressed, agent, false)
            };
            let ours = match wake.get(&link) {
                Some(w) if ours == "wake" => w.clone(),
                _ => ours,
            };
            let p = pairs
                .entry((ours.clone(), link, theirs.clone()))
                .or_insert_with(|| TrafficPair {
                    agent: ours,
                    contact: contact.clone(),
                    peer_agent: theirs,
                    last_ms: 0,
                    sent: 0,
                    received: 0,
                    local: false,
                });
            p.last_ms = p.last_ms.max(last.max(0) as u64);
            let n = n.max(0) as u64;
            if out {
                p.sent += n;
            } else {
                p.received += n;
            }
        }
        drop(st);
        drop(db);
        let mut pairs: Vec<TrafficPair> = pairs.into_values().collect();
        pairs.extend(self.local_traffic(since)?);
        pairs.sort_by(|a, b| {
            b.last_ms
                .cmp(&a.last_ms)
                .then_with(|| a.agent.cmp(&b.agent))
                .then_with(|| a.contact.cmp(&b.contact))
                .then_with(|| a.peer_agent.cmp(&b.peer_agent))
        });
        pairs.truncate(MAX_PAIRS);
        Ok(AgentTraffic {
            since_ms: since,
            pairs,
        })
    }
}

/// The approval request for the other side of a connection, made by this node for its owner from what the own
/// computer on `link` (here `label`) asked: the text is the daemon's own, from checked names.
fn connect_approval(
    link: &LinkId,
    label: &str,
    agent: &str,
    ask: &ConnectAsk,
    salt: u64,
) -> policy::NewApproval {
    let requester_id = format!("device:{}", &link.to_hex()[..16]);
    let (action, quote) = match &ask.peer_agent {
        Some(peer) => (
            ACTION_CONNECT,
            format!(
                "Connect {agent} with {peer} on {label}: messages from {agent} without an address go to {peer}.{}",
                match ask.tasks {
                    Some(true) => format!(" Messages from {label} become tasks for {agent}."),
                    Some(false) =>
                        format!(" Messages from {label} are data for {agent}, not tasks."),
                    None => String::new(),
                }
            ),
        ),
        None => (
            ACTION_DISCONNECT,
            format!(
                "Disconnect {agent} from {label}: its messages without an address no longer go there.{}",
                if ask.tasks == Some(false) {
                    format!(" Messages from {label} are data for {agent}, not tasks.")
                } else {
                    String::new()
                }
            ),
        ),
    };
    let payload =
        serde_json::to_vec(&(agent, &ask.peer_agent, ask.tasks, salt)).unwrap_or_default();
    policy::NewApproval {
        requester_id: requester_id.clone(),
        requester: label.into(),
        contact: *link,
        contact_label: label.into(),
        contact_trust: 5,
        action: action.into(),
        target: None,
        target_link: None,
        reasons: vec![REASON.into()],
        grants: Grants {
            read: "none".into(),
            write: "none".into(),
            commands: if ask.tasks == Some(true) {
                format!("{agent} takes messages from {label} as tasks")
            } else {
                "none".into()
            },
            send: match &ask.peer_agent {
                Some(peer) => {
                    format!("{agent}'s messages without an address go to {peer} on {label}")
                }
                None => "none".into(),
            },
        },
        quote,
        request_hash: policy::request_hash(&requester_id, action, Some(link), &payload),
        completes: true,
    }
}

fn side(state: &str) -> OtherSide {
    OtherSide {
        state: state.into(),
        id: None,
        message: None,
        code: None,
    }
}

fn unreachable_side(why: &str) -> OtherSide {
    OtherSide {
        state: other_side::UNREACHABLE.into(),
        id: None,
        message: Some(format!(
            "that computer could not be reached now ({why}): this side is set"
        )),
        code: None,
    }
}

fn refused_side(c: &str, why: &str) -> OtherSide {
    OtherSide {
        state: other_side::REFUSED.into(),
        id: None,
        message: Some(why.into()),
        code: Some(c.into()),
    }
}

/// What the other computer's refusal code means for a connection.
fn refused_words(c: &str) -> &'static str {
    match c {
        code::NOT_FOUND => "that computer has no agent of that name",
        code::BAD_REQUEST => "that agent's links on that computer do not include this one",
        code::DENIED => {
            "that agent cannot be connected there (it replies on wake, works for a team or runs on a local model)"
        }
        code::RATE_LIMITED => {
            "too many connection requests from this computer are already waiting there"
        }
        code::FORBIDDEN => "that computer does not have this one at ∞ (trust level 5)",
        _ => "that computer refused",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(tasks_from: Option<Vec<LinkId>>, links: Option<Vec<LinkId>>) -> AgentRow {
        AgentRow {
            id: 1,
            name: "volna".into(),
            links,
            local_level: 0,
            created_ms: 0,
            start_seq: 0,
            session_started_ms: 0,
            anchor: None,
            taint: Vec::new(),
            declared: Vec::new(),
            everyone: false,
            tasks_from,
        }
    }

    fn names() -> HashMap<LinkId, (String, u8)> {
        [
            (LinkId([1; 32]), ("mini".to_string(), 5)),
            (LinkId([2; 32]), ("bob".to_string(), 3)),
            (LinkId([3; 32]), ("server".to_string(), 5)),
        ]
        .into_iter()
        .collect()
    }

    #[test]
    fn task_authority_from_the_default_becomes_the_explicit_list() {
        let (mini, bob, server) = (LinkId([1; 32]), LinkId([2; 32]), LinkId([3; 32]));
        // The default already takes tasks from the own computers: nothing to change
        assert_eq!(tasks_with(&row(None, None), &names(), &mini, true), None);
        // A contact at 3 added: the level-5 links stay, as an explicit list
        assert_eq!(
            tasks_with(&row(None, None), &names(), &bob, true),
            Some(vec![mini, bob, server])
        );
        // Removing an own computer from the default: the others stay
        assert_eq!(
            tasks_with(&row(None, None), &names(), &mini, false),
            Some(vec![server])
        );
        // Outside the agent's scope nothing is taken by default
        assert_eq!(
            tasks_with(&row(None, Some(vec![bob])), &names(), &bob, true),
            Some(vec![bob])
        );
        // An explicit empty list (nobody): adding one gives exactly it
        assert_eq!(
            tasks_with(&row(Some(vec![]), None), &names(), &mini, true),
            Some(vec![mini])
        );
        assert_eq!(
            tasks_with(&row(Some(vec![]), None), &names(), &mini, false),
            None
        );
    }

    #[test]
    fn a_connect_ask_changes_only_what_differs() {
        let link = LinkId([1; 32]);
        let other = LinkId([3; 32]);
        let r = row(None, None);
        let ask = |peer: Option<&str>, tasks| ConnectAsk {
            agent: "session-2".into(),
            peer_agent: peer.map(Into::into),
            tasks,
        };
        let to_volna = CounterpartRow {
            link,
            agent: Some("volna".into()),
        };
        // New: the counterpart; tasks from an own computer are already the default
        assert_eq!(
            change_for(&r, None, &names(), &link, &ask(Some("volna"), Some(true))),
            (Some(Some(to_volna.clone())), None)
        );
        // Already so: nothing
        assert_eq!(
            change_for(
                &r,
                Some(&to_volna),
                &names(),
                &link,
                &ask(Some("volna"), None)
            ),
            (None, None)
        );
        // Disconnect clears only a counterpart on the asking link
        assert_eq!(
            change_for(&r, Some(&to_volna), &names(), &link, &ask(None, None)),
            (Some(None), None)
        );
        let elsewhere = CounterpartRow {
            link: other,
            agent: Some("lead".into()),
        };
        assert_eq!(
            change_for(&r, Some(&elsewhere), &names(), &link, &ask(None, None)),
            (None, None),
            "the asking computer cannot clear a counterpart on another link"
        );
        // Tasks off from the default
        assert_eq!(
            change_for(
                &r,
                Some(&to_volna),
                &names(),
                &link,
                &ask(None, Some(false))
            ),
            (Some(None), Some(vec![other]))
        );
    }

    #[test]
    fn the_approval_text_is_built_here_and_binds_the_ask() {
        let link = LinkId([1; 32]);
        let a = connect_approval(
            &link,
            "macbook",
            "session-2",
            &ConnectAsk {
                agent: "session-2".into(),
                peer_agent: Some("volna".into()),
                tasks: Some(true),
            },
            0,
        );
        assert_eq!(a.action, ACTION_CONNECT);
        assert_eq!(a.reasons, vec![REASON.to_string()]);
        assert!(a.completes && a.contact_trust == 5);
        assert!(a.requester_id.starts_with("device:"));
        assert_eq!(
            a.quote,
            "Connect session-2 with volna on macbook: messages from session-2 without an address go to volna. \
             Messages from macbook become tasks for session-2."
        );
        let b = connect_approval(
            &link,
            "macbook",
            "session-2",
            &ConnectAsk {
                agent: "session-2".into(),
                peer_agent: Some("volna".into()),
                tasks: None,
            },
            0,
        );
        assert_ne!(
            a.request_hash, b.request_hash,
            "the approval binds the exact change"
        );
        let d = connect_approval(
            &link,
            "macbook",
            "session-2",
            &ConnectAsk {
                agent: "session-2".into(),
                peer_agent: None,
                tasks: None,
            },
            0,
        );
        assert_eq!(d.action, ACTION_DISCONNECT);
    }
}
