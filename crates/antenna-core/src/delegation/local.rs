// SPDX-License-Identifier: AGPL-3.0-only
//! The session's side of approver agents (PG-57): the owner's commands, the check of an answer against the scope and
//! the level-5 circle, an answer of this computer's approver, the requests offered to approvers, and what the owner's
//! card says. Answers from another own computer arrive through `node::own_devices::delegated` and end in the same
//! [`Session::decide_delegated`].

use std::sync::{Arc, PoisonError};

use antenna_proto::{
    LinkId,
    control::{
        ANSWER_APPROVED, ANSWER_DENIED, ANSWER_REFUSED, AnswerReply, ApprovalAnswer, ApprovalInfo,
        ApproverInfo, ApproverNarrow, ApproverRemove, ApproverSet, ApproversReply, ApprovesFor,
        DecidedBy, DelegateNote, DelegatedAnswer, DelegatedRequest, REASON_MAX_CHARS, ToAnswerFact,
        ToAnswerReply, code, kinds_ok, within,
    },
};

use super::{Approver, Delegation, rules};
use crate::{
    agents::AgentCtx,
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
    now_ms,
    store::{AgentRow, Db},
};

/// How many delegated answers the owner's list shows.
const LIST_ANSWERS: usize = 200;

/// The links an agent's session read, with the level each had when it read them.
fn read_links(row: &AgentRow) -> Vec<(LinkId, u8)> {
    row.taint
        .iter()
        .filter_map(|t| {
            let v = data_encoding::HEXLOWER.decode(t.link.as_bytes()).ok()?;
            Some((LinkId(<[u8; 32]>::try_from(v).ok()?), t.level))
        })
        .collect()
}

fn link_of(hex: Option<&str>) -> Option<LinkId> {
    let v = data_encoding::HEXLOWER.decode(hex?.as_bytes()).ok()?;
    Some(LinkId(<[u8; 32]>::try_from(v).ok()?))
}

/// What the request allowed, as the card says it, without the message text.
fn summary(info: &ApprovalInfo) -> String {
    let g = &info.grants;
    [&g.send, &g.write, &g.read, &g.commands]
        .into_iter()
        .find(|s| !s.is_empty() && s.as_str() != "none")
        .cloned()
        .unwrap_or_else(|| info.action.clone())
}

/// A reason from an approver: its own text, one line, 1–500 characters.
pub(crate) fn checked_reason(reason: &str) -> Result<String> {
    let r: String = reason
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let r = r.trim().to_string();
    if r.is_empty() || r.chars().count() > REASON_MAX_CHARS {
        return Err(Error::bad_request(format!(
            "reason: 1–{REASON_MAX_CHARS} characters, for the owner"
        )));
    }
    Ok(r)
}

/// Why agent `row` cannot be an approver: the daemon decides what a link's wake agent, a team's worker and a
/// local-model agent do, and none of them has the approver's tools.
fn not_an_approver(db: &Db, row: &AgentRow) -> Result<Option<String>> {
    let name = &row.name;
    if db.wake_rules()?.iter().any(|(_, id, _, _)| *id == row.id) {
        return Ok(Some(format!(
            "agent {name} replies on wake with a fixed prompt: it cannot answer approvals"
        )));
    }
    if crate::teams::is_worker(db, row.id) {
        return Ok(Some(format!(
            "agent {name} is a team's worker: its team decides what it does"
        )));
    }
    if crate::local::is_local_agent(db, row.id) {
        return Ok(Some(format!(
            "agent {name} runs on a local model without the approver's tools"
        )));
    }
    Ok(None)
}

impl Session {
    /// Every delegation (an unreadable table is no delegation: fail closed).
    pub(crate) fn delegations(&self) -> Vec<Delegation> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        super::load(&db).unwrap_or_else(|e| {
            tracing::warn!("approvers: {e}");
            Vec::new()
        })
    }

    /// Whether an agent of this computer is an approver: here, or for an own computer that named it.
    pub(crate) fn is_approver(&self, agent_id: i64) -> bool {
        let (local, name) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            (
                super::is_local_approver(&db, agent_id),
                db.agent(agent_id).map(|r| r.name).ok(),
            )
        };
        local
            || name.is_some_and(|n| {
                self.devices_naming_approver(&n)
                    .iter()
                    .any(|(link, _)| self.agent_in_scope_of(agent_id, link))
            })
    }

    /// Whether agent `agent_id` has `link` in its scope.
    pub(crate) fn agent_in_scope_of(&self, agent_id: i64, link: &LinkId) -> bool {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        db.agent(agent_id)
            .is_ok_and(|r| r.links.as_ref().is_none_or(|l| l.contains(link)))
    }

    /// Request `info` as the rules see it.
    fn rules_request(&self, info: &ApprovalInfo) -> Option<rules::Request<'static>> {
        let requester_id = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .requester_of(&info.id)?;
        let requester = requester_id
            .strip_prefix("agent:")
            .and_then(|s| s.parse::<i64>().ok());
        let requester_read = match requester {
            Some(id) => {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                db.agent(id).map(|r| read_links(&r)).unwrap_or_default()
            }
            None => Vec::new(),
        };
        let action: &'static str = antenna_proto::control::DELEGABLE_KINDS
            .iter()
            .find(|k| **k == info.action)
            .copied()
            .unwrap_or("other");
        Some(rules::Request {
            requester,
            action,
            contact: (link_of(info.link_id.as_deref())?, info.contact_trust),
            target: link_of(info.target_link_id.as_deref()),
            created_ms: info.created_ms,
            requester_read,
        })
    }

    /// Checks an answer of `approver` (who reads as `by`) to `info` against its delegation, the scope and the circle,
    /// now. The delegation it answers under, or why it does not count.
    pub(crate) fn delegate_check(
        &self,
        approver: &Approver,
        by: &rules::Answerer,
        info: &ApprovalInfo,
    ) -> std::result::Result<Delegation, rules::Refusal> {
        let refusal = |why: &'static str, message: &str| rules::Refusal {
            why,
            message: message.into(),
        };
        let d = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::find(&db, approver).ok().flatten()
        };
        let Some(d) = d else {
            return Err(refusal(
                antenna_proto::control::why::SCOPE,
                "the owner has not named this agent an approver",
            ));
        };
        if let (Approver::Remote { key, .. }, Approver::Remote { key: named, .. }) =
            (approver, &d.approver)
            && key != named
        {
            return Err(refusal(
                antenna_proto::control::why::UNVERIFIED,
                "the agent's key on that link changed since the owner named it: the owner names it again",
            ));
        }
        // The key the owner named must still be announced on that link and not revoked (PROTOCOL §21): an agent
        // removed there and made again under the same name is another agent
        if let Approver::Remote { link, name, key } = &d.approver
            && !self.remote_key_active(link, name, key)
        {
            return Err(refusal(
                antenna_proto::control::why::UNVERIFIED,
                "the agent the owner named was removed on that computer (its key is revoked): the owner names it \
                 again",
            ));
        }
        let Some(req) = self.rules_request(info) else {
            return Err(refusal(
                antenna_proto::control::why::SCOPE,
                "only the owner answers this request",
            ));
        };
        let scope = rules::Scope {
            agents: d.agents.as_deref(),
            kinds: d.kinds.as_deref(),
        };
        rules::in_scope(&req, by, &scope, |id| self.is_approver(id))?;
        let names = self.link_names().unwrap_or_default();
        rules::in_circle(
            &req,
            by,
            |l| names.get(l).map(|(_, t)| *t),
            |l| self.delegation.changed_ms(l),
            |l| {
                names
                    .get(l)
                    .map_or_else(|| l.to_hex()[..8].to_string(), |(n, _)| n.clone())
            },
        )?;
        Ok(d)
    }

    /// Whether own computer `link` still announces `key` for its agent `name`, unrevoked.
    pub(crate) fn remote_key_active(&self, link: &LinkId, name: &str, key: &[u8; 32]) -> bool {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        crate::agentid::all(db.conn(), link).is_ok_and(|keys| {
            keys.into_iter()
                .any(|k| !k.mine && k.key == *key && k.name == name && k.revoked_n.is_none())
        })
    }

    /// This computer's agent `row` as an answerer.
    fn local_answerer(row: &AgentRow) -> rules::Answerer {
        rules::Answerer {
            local: Some(row.id),
            device: None,
            read: read_links(row),
        }
    }

    /// The approvers that may answer `info` now, for the owner's card: `volna`, `volna@Mac mini`.
    pub(crate) fn with_answerers(&self, mut info: ApprovalInfo) -> ApprovalInfo {
        let delegations = self.delegations();
        if delegations.is_empty() {
            return info;
        }
        let names = self.link_names().unwrap_or_default();
        for d in delegations {
            let (by, label) = match &d.approver {
                Approver::Local(id) => {
                    let row = {
                        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                        db.agent(*id).ok()
                    };
                    let Some(row) = row else { continue };
                    (Self::local_answerer(&row), row.name)
                }
                Approver::Remote { link, name, .. } => (
                    rules::Answerer {
                        local: None,
                        device: Some(*link),
                        read: Vec::new(),
                    },
                    format!(
                        "{name}@{}",
                        names.get(link).map_or("?", |(n, _)| n.as_str())
                    ),
                ),
            };
            if self.delegate_check(&d.approver, &by, &info).is_ok() {
                info.answerable_by.push(label);
            }
        }
        info
    }

    /// A new request: every approver of this computer that may answer it hears of it (facts only); approvers on
    /// other own computers learn of it from this computer's status.
    pub(crate) fn offer_to_approvers(&self, info: &ApprovalInfo) {
        for d in self.delegations() {
            let Approver::Local(id) = d.approver else {
                continue;
            };
            let row = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                db.agent(id).ok()
            };
            let Some(row) = row else { continue };
            if self
                .delegate_check(&d.approver, &Self::local_answerer(&row), info)
                .is_ok()
            {
                self.offer_fact(
                    id,
                    ToAnswerFact {
                        id: info.id.clone(),
                        device: None,
                        action: info.action.clone(),
                        requester: info.requester.clone(),
                        expires_ms: info.expires_ms,
                    },
                );
            }
        }
    }

    /// A request waits for agent `agent_id`: its `wait`/`inbox` and its own subscription hear of it.
    pub(crate) fn offer_fact(&self, agent_id: i64, fact: ToAnswerFact) {
        self.delegation.push_fact(agent_id, fact.clone());
        self.inbox.send_modify(|v| *v += 1);
        let _ = self.events.send(NodeEvent::ToAnswer {
            agent_id,
            fact: Box::new(fact),
        });
    }

    /// What agent `row` may answer, for its `session` (and the MCP instructions).
    pub(crate) fn approves_for(&self, row: &AgentRow) -> Vec<ApprovesFor> {
        let mut out = Vec::new();
        let local = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::find(&db, &Approver::Local(row.id)).ok().flatten()
        };
        if let Some(d) = local {
            out.push(ApprovesFor {
                device: None,
                agents: self.agent_names(d.agents.as_deref()),
                kinds: d.kinds,
            });
        }
        let names = self.link_names().unwrap_or_default();
        for (link, sa) in self.devices_naming_approver(&row.name) {
            if !row.links.as_ref().is_none_or(|l| l.contains(&link)) {
                continue;
            }
            out.push(ApprovesFor {
                device: names.get(&link).map(|(n, _)| n.clone()),
                agents: sa.agents,
                kinds: sa.kinds,
            });
        }
        out
    }

    fn agent_names(&self, ids: Option<&[i64]>) -> Option<Vec<String>> {
        let ids = ids?;
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        Some(
            ids.iter()
                .filter_map(|id| db.agent(*id).ok().map(|r| r.name))
                .collect(),
        )
    }

    /// A link's level changed (`trust`): requests made before now are the person's; a computer that is no longer at
    /// ∞ loses every delegation to its agents, and raising it back does not restore them.
    pub(crate) fn delegation_trust_changed(&self, link: &LinkId, old: u8, new: u8) {
        if old == new {
            return;
        }
        self.delegation.note_trust_change(*link, now_ms());
        if new < rules::CIRCLE {
            let removed = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                super::remove_link(&db, link).unwrap_or(0)
            };
            if removed > 0 {
                tracing::info!(
                    "link {}: below ∞ now: {removed} approver(s) of that computer removed",
                    &link.to_hex()[..8]
                );
                self.device_event(link, "approvers");
            }
        }
    }

    // The owner

    /// Resolves the owner's naming of an approver: a local agent, or an own computer's agent by its announced key.
    fn approver_of(&self, name: &str, contact: Option<&str>) -> Result<(Approver, String)> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        match contact {
            None => {
                let row = db.agent_by_name(name)?;
                if let Some(why) = not_an_approver(&db, &row)? {
                    return Err(Error::new(code::DENIED, why));
                }
                Ok((Approver::Local(row.id), row.name))
            }
            Some(c) => {
                let link = db.find_link(c)?;
                if link.trust != rules::CIRCLE {
                    return Err(Error::new(
                        code::FORBIDDEN,
                        format!(
                            "{} is not at ∞ (level 5): only an agent of an own computer can be an approver",
                            link.label
                        ),
                    ));
                }
                if name == "wake" {
                    return Err(Error::new(
                        code::DENIED,
                        "a link's wake agent replies with a fixed prompt: it cannot answer approvals",
                    ));
                }
                let key = crate::agentid::all(db.conn(), &link.link_id)?
                    .into_iter()
                    .filter(|k| !k.mine && k.name == name && k.revoked_n.is_none())
                    .max_by_key(|k| k.announced_n)
                    .ok_or_else(|| {
                        Error::new(
                            code::NOT_FOUND,
                            format!(
                                "{} has not announced an agent named {name} on this link: an agent becomes known \
                                 here with its first message to this computer",
                                link.label
                            ),
                        )
                    })?;
                drop(db);
                let supports = self
                    .rt(&link.link_id)
                    .map(|rt| rt.shared.peer_supports_agent_approve())
                    .unwrap_or(false);
                if !supports {
                    return Err(Error::bad_request(format!(
                        "{}'s Antenna does not know approver agents yet (or has not connected since this one \
                         started): update it",
                        link.label
                    )));
                }
                Ok((
                    Approver::Remote {
                        link: link.link_id,
                        name: name.into(),
                        key: key.key,
                    },
                    format!("{name}@{}", link.label),
                ))
            }
        }
    }

    /// The agents of a scope by name → IDs; the approver itself is never in it.
    fn scope_ids(&self, names: Option<&[String]>, approver: &Approver) -> Result<Option<Vec<i64>>> {
        let Some(names) = names else {
            return Ok(None);
        };
        if names.is_empty() || names.len() > 64 {
            return Err(Error::bad_request("agents: 1–64 names, or none for all"));
        }
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let mut ids = Vec::new();
        for n in names {
            let row = db.agent_by_name(n)?;
            if *approver == Approver::Local(row.id) {
                return Err(Error::bad_request(
                    "an approver never answers its own requests: leave it out of its scope",
                ));
            }
            if !ids.contains(&row.id) {
                ids.push(row.id);
            }
        }
        Ok(Some(ids))
    }

    fn checked_kinds(kinds: Option<&[String]>) -> Result<Option<Vec<String>>> {
        match kinds {
            None => Ok(None),
            Some(k) if kinds_ok(k) => Ok(Some(k.to_vec())),
            Some(_) => Err(Error::bad_request(format!(
                "kinds: some of {}, each once",
                antenna_proto::control::DELEGABLE_KINDS.join(", ")
            ))),
        }
    }

    /// `approver_set` (the caller checked the password or the proof).
    pub fn approver_set(&self, a: &ApproverSet) -> Result<ApproversReply> {
        let (approver, label) = self.approver_of(&a.name, a.contact.as_deref())?;
        let agents = self.scope_ids(a.agents.as_deref(), &approver)?;
        let kinds = Self::checked_kinds(a.kinds.as_deref())?;
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::save(
                &db,
                &Delegation {
                    approver: approver.clone(),
                    agents,
                    kinds,
                    created_ms: now_ms(),
                },
            )?;
        }
        self.approver_changed(&approver, &label, "set");
        self.approvers_view()
    }

    /// `approver_narrow` (an owner session): the new scope must lie within the one it has.
    pub fn approver_narrow(&self, a: &ApproverNarrow) -> Result<ApproversReply> {
        let (approver, label) = self.approver_of(&a.name, a.contact.as_deref())?;
        let current = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::find(&db, &approver)?
        }
        .ok_or_else(|| Error::new(code::NOT_FOUND, format!("{label} is not an approver")))?;
        let agents = self.scope_ids(a.agents.as_deref(), &approver)?;
        let kinds = Self::checked_kinds(a.kinds.as_deref())?;
        let ids = |v: &Option<Vec<i64>>| v.as_ref().map(|x| x.iter().map(i64::to_string).collect());
        if !within(&ids(&agents), &ids(&current.agents)) || !within(&kinds, &current.kinds) {
            return Err(Error::new(
                code::PASSWORD_REQUIRED,
                "this widens what the approver answers: set it with the password (approver_set)",
            ));
        }
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::save(
                &db,
                &Delegation {
                    agents,
                    kinds,
                    ..current
                },
            )?;
        }
        self.approver_changed(&approver, &label, "narrowed");
        self.approvers_view()
    }

    /// `approver_remove` (an owner session).
    pub fn approver_remove(&self, a: &ApproverRemove) -> Result<ApproversReply> {
        let approver = match self.approver_of(&a.name, a.contact.as_deref()) {
            Ok((ap, _)) => ap,
            // A remote approver whose key or computer changed is still removed by its name
            Err(_) if a.contact.is_some() => {
                let link = self.find_link(a.contact.as_deref().unwrap_or_default())?;
                Approver::Remote {
                    link: link.link_id,
                    name: a.name.clone(),
                    key: [0; 32],
                }
            }
            Err(e) => return Err(e),
        };
        let removed = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::remove(&db, &approver)?
        };
        if !removed {
            return Err(Error::new(
                code::NOT_FOUND,
                format!("{} is not an approver", a.name),
            ));
        }
        self.approver_changed(&approver, &a.name, "removed");
        self.approvers_view()
    }

    fn approver_changed(&self, approver: &Approver, label: &str, what: &str) {
        let (link, name) = match approver {
            Approver::Local(_) => (None, label.to_string()),
            Approver::Remote { link, name, .. } => (Some(*link), name.clone()),
        };
        tracing::info!("approvers: {label} {what}");
        if let Some(l) = link {
            self.receipt(&l, "owner", "approver", what, &name, None, None);
            self.device_event(&l, "approvers");
        } else {
            self.emit_agent(&name, "approver");
        }
    }

    /// `approvers`: the delegations and the latest answers.
    pub fn approvers_view(&self) -> Result<ApproversReply> {
        let names = self.link_names()?;
        let delegations = self.delegations();
        let mut approvers = Vec::new();
        for d in delegations {
            let (agent, contact, link_id, key_id, stale) = match &d.approver {
                Approver::Local(id) => {
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    let Ok(row) = db.agent(*id) else { continue };
                    (row.name, None, None, None, false)
                }
                Approver::Remote { link, name, key } => (
                    name.clone(),
                    names.get(link).map(|(n, _)| n.clone()),
                    Some(link.to_hex()),
                    Some(data_encoding::HEXLOWER.encode(&crate::crypto::sha256(&[key])[..8])),
                    !self.remote_key_active(link, name, key),
                ),
            };
            approvers.push(ApproverInfo {
                agent,
                contact,
                link_id,
                agents: self.agent_names(d.agents.as_deref()),
                kinds: d.kinds,
                key_id,
                stale,
                created_ms: d.created_ms,
            });
        }
        let answers = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::answers(&db, LIST_ANSWERS)?
        };
        Ok(ApproversReply { approvers, answers })
    }

    // The agent

    /// `approvals_to_answer`: the requests this agent may answer now, here and on own computers that named it.
    /// Reading them taints its session with the links they touch (all at level 5).
    pub fn agent_to_answer(&self, ctx: &AgentCtx) -> Result<ToAnswerReply> {
        let row = self.agent_row(ctx)?;
        let by = Self::local_answerer(&row);
        let mut requests = Vec::new();
        let mut touched: Vec<LinkId> = Vec::new();
        let mut blocked = None;
        let local = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            super::find(&db, &Approver::Local(row.id))?
        };
        if local.is_some() {
            let (all, _) = self.approvals_list(true);
            for info in all.into_iter().filter(|i| i.state == "pending") {
                match self.delegate_check(&Approver::Local(row.id), &by, &info) {
                    Ok(_) => {
                        if let Some(r) = self.rules_request(&info) {
                            touched.push(r.contact.0);
                            touched.extend(r.target);
                            touched.extend(r.requester_read.iter().map(|(l, _)| *l));
                        }
                        requests.push(Self::delegated_view(&info, None));
                    }
                    Err(r) if r.why == antenna_proto::control::why::TAINTED => {
                        blocked = Some(r.message);
                    }
                    Err(_) => {}
                }
            }
        }
        let (remote, remote_blocked) = self.device_requests_for(&row);
        if blocked.is_none() {
            blocked = remote_blocked;
        }
        for (link, r) in remote {
            touched.push(link);
            requests.push(r);
        }
        requests.sort_by_key(|r| std::cmp::Reverse(r.created_ms));
        touched.sort_by_key(|l| l.0);
        touched.dedup();
        let names = self.link_names()?;
        for l in touched {
            if let Some((_, t)) = names.get(&l) {
                self.taint_link(ctx.id, &l, *t)?;
            }
        }
        Ok(ToAnswerReply { requests, blocked })
    }

    /// A request as an approver reads it: the card's facts, the quote cut and withheld when it holds a secret.
    pub(crate) fn delegated_view(info: &ApprovalInfo, device: Option<String>) -> DelegatedRequest {
        let withheld = !crate::policy::scan_secrets(&info.quote).is_empty();
        DelegatedRequest {
            id: info.id.clone(),
            device,
            action: info.action.clone(),
            requester: info.requester.clone(),
            contact: info.contact.clone(),
            contact_trust: info.contact_trust,
            target: info.target.clone(),
            reasons: info.reasons.clone(),
            quote: if withheld {
                String::new()
            } else {
                antenna_proto::device::cut(&info.quote, antenna_proto::device::MAX_QUOTE)
            },
            quote_withheld: withheld,
            fingerprint: info.fingerprint.clone(),
            created_ms: info.created_ms,
            expires_ms: info.expires_ms,
        }
    }

    /// `approval_answer`: an answer of this computer's agent, to a request here or (with `device`) on an own computer
    /// that named it.
    pub async fn agent_approval_answer(
        self: &Arc<Self>,
        ctx: &AgentCtx,
        a: &ApprovalAnswer,
    ) -> Result<AnswerReply> {
        let reason = checked_reason(&a.reason)?;
        let approve = match a.decision.as_str() {
            "approve" => true,
            "deny" => false,
            _ => return Err(Error::bad_request("decision: approve or deny")),
        };
        let row = self.agent_row(ctx)?;
        if let Some(device) = &a.device {
            return self
                .agent_answer_remote(&row, device, a, approve, &reason)
                .await;
        }
        let info = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&a.id, now_ms())
            .filter(|i| i.state == "pending")
            .ok_or_else(|| {
                Error::new(
                    code::NOT_FOUND,
                    format!("no pending approval request {:?} here", a.id),
                )
            })?;
        let by = Self::local_answerer(&row);
        if let Err(r) = self.delegate_check(&Approver::Local(row.id), &by, &info) {
            self.refuse_delegated(&info, &row.name, None, &r);
            return Err(Error::new(
                code::FORBIDDEN,
                format!(
                    "{} The request waits for the owner, who is told why.",
                    r.message
                ),
            ));
        }
        let decided = DecidedBy {
            agent: row.name.clone(),
            device: None,
            reason,
            at_ms: now_ms(),
        };
        self.decide_delegated(&info, approve, &a.fingerprint, decided)
    }

    /// Carries out a checked delegated answer: approve (the daemon then carries the request out, D-100) or deny, with
    /// the fingerprint the approver read; records it for the owner's list.
    pub(crate) fn decide_delegated(
        self: &Arc<Self>,
        info: &ApprovalInfo,
        approve: bool,
        fingerprint: &str,
        by: DecidedBy,
    ) -> Result<AnswerReply> {
        let actor = match &by.device {
            Some(d) => format!("{}@{d}", by.agent),
            None => by.agent.clone(),
        };
        let done = if approve {
            self.approve_by_agent(&info.id, fingerprint, by.clone(), &actor)?
        } else {
            self.deny_by_agent(&info.id, fingerprint, by.clone(), &actor)?
        };
        let decision = if approve {
            ANSWER_APPROVED
        } else {
            ANSWER_DENIED
        };
        self.record_answer(
            &done,
            &by.agent,
            by.device.clone(),
            decision,
            &by.reason,
            None,
        );
        tracing::info!(
            "approval {}: {decision} by the approver {actor} ({} of {})",
            info.id,
            info.action,
            info.requester
        );
        Ok(AnswerReply {
            id: info.id.clone(),
            state: decision.into(),
            message: if approve {
                format!(
                    "Approved in the owner's place: Antenna carries out request {} and tells {}. The owner sees your \
                     answer and your reason.",
                    info.id, info.requester
                )
            } else {
                format!(
                    "Denied in the owner's place: {} is told. The owner sees your answer and your reason.",
                    info.requester
                )
            },
        })
    }

    /// An agent's answer to pending request `info` did not count: the card says why, the owner's list keeps it, and
    /// the audit log of the request's contact records it.
    pub(crate) fn refuse_delegated(
        &self,
        info: &ApprovalInfo,
        agent: &str,
        device: Option<String>,
        r: &rules::Refusal,
    ) {
        let note = DelegateNote {
            agent: agent.into(),
            device: device.clone(),
            why: r.why.into(),
            message: r.message.clone(),
            at_ms: now_ms(),
        };
        self.approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .note_refused(&info.id, note);
        self.emit_approval(&info.id);
        self.record_answer(
            info,
            agent,
            device.clone(),
            ANSWER_REFUSED,
            &r.message,
            Some(r.why),
        );
        let actor = match &device {
            Some(d) => format!("{agent}@{d}"),
            None => agent.to_string(),
        };
        if let Ok(row) = self.find_link(&info.contact) {
            self.receipt(
                &row.link_id,
                &actor,
                &info.action,
                "agent_answer_refused",
                r.why,
                None,
                Some(&info.id),
            );
        }
        tracing::info!(
            "approval {}: the answer of {actor} did not count: {}",
            info.id,
            r.why
        );
    }

    fn record_answer(
        &self,
        info: &ApprovalInfo,
        agent: &str,
        device: Option<String>,
        decision: &str,
        reason: &str,
        why: Option<&str>,
    ) {
        let a = DelegatedAnswer {
            approval_id: info.id.clone(),
            action: info.action.clone(),
            requester: info.requester.clone(),
            contact: info.contact.clone(),
            target: info.target.clone(),
            approver: agent.into(),
            device,
            decision: decision.into(),
            reason: reason.into(),
            summary: summary(info),
            at_ms: now_ms(),
            why: why.map(str::to_string),
        };
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(e) = super::record(&db, &a) {
            tracing::warn!("approvers: the answer was not recorded: {e}");
        }
    }

    /// The facts of requests waiting for agent `agent_id`'s answer since its last `wait`/`inbox`.
    pub(crate) fn has_to_answer(&self, agent_id: i64) -> bool {
        self.delegation.has_facts(agent_id)
    }

    /// Takes them.
    pub(crate) fn take_to_answer(&self, agent_id: i64) -> Vec<ToAnswerFact> {
        self.delegation.take_facts(agent_id)
    }
}
