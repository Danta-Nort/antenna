// SPDX-License-Identifier: AGPL-3.0-only
//! Approver agents across own computers (`docs/PROTOCOL.md` §24, PG-57; experimental), both sides.
//!
//! - **The computer that holds a request** names, in its status to an own computer (only one whose node announced
//!   `agent-approve/0`), that computer's agents its owner made approvers and which pending requests each may answer
//!   now. It issues a one-time challenge for one request on that link, and checks an answer: the delegation (the link,
//!   the name, the key the owner named), the key still announced and not revoked (PROTOCOL §21), the Ed25519
//!   signature by that key over `"antenna/agent-decision/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(text)`, the other computer's
//!   word that its agent's session is clean, then the same scope and circle as for an approver here. Anything that
//!   does not verify is refused and counts towards a pause, as for owner proofs (D-114).
//! - **The approver's computer** shows its agent the requests offered to it, and carries its answer: it checks its
//!   own level of the link and the agent's scope, asks for the challenge, signs the exact text with the agent's key in
//!   the link (the agent never sees the key), and says honestly whether the agent's session read anything below level
//!   5 there (`clean`), so that a tainted approver's answer reaches the asking computer and its owner is told why.
//!
//! Nothing here is the owner proof: another key, another algorithm, another label, another message, another pool of
//! challenges. No new cryptography: `ed25519-dalek` as for every message of the link (`history::sign`/`verify`).

use std::sync::{Arc, PoisonError};

use antenna_proto::{
    LinkId,
    control::{AnswerReply, ApprovalAnswer, DecidedBy, DelegatedRequest, ToAnswerFact, code, why},
    device::{
        self, AgentDecision, AgentDecisionText, DeviceApproval, DeviceMsg, DeviceReply,
        DeviceStatus, StatusApprover,
    },
};
use data_encoding::HEXLOWER;

use crate::{
    agentid,
    delegation::{self, Approver, rules},
    error::{Error, Result},
    history,
    node::Session,
    now_ms,
    store::AgentRow,
};

/// The rules' view of a request another own computer shows: the facts of its status, all at that computer.
fn view(a: &DeviceApproval, device: &str) -> DelegatedRequest {
    DelegatedRequest {
        id: a.id.clone(),
        device: Some(device.to_string()),
        action: a.action.clone(),
        requester: a.requester.clone(),
        contact: a.contact.clone(),
        contact_trust: a.contact_trust,
        target: a.target.clone(),
        reasons: a.reasons.clone(),
        quote: a.quote.clone(),
        quote_withheld: a.quote_withheld,
        fingerprint: a.fingerprint.clone(),
        created_ms: a.created_ms,
        expires_ms: a.expires_ms,
    }
}

/// Why `row`'s session would not count as an approver's: it read a contact below level 5 (then or now).
fn tainted(
    row: &AgentRow,
    level: impl Fn(&LinkId) -> Option<u8>,
    name: impl Fn(&LinkId) -> String,
) -> Option<String> {
    let by = rules::Answerer {
        local: Some(row.id),
        device: None,
        read: row
            .taint
            .iter()
            .filter_map(|t| {
                let v = HEXLOWER.decode(t.link.as_bytes()).ok()?;
                Some((LinkId(<[u8; 32]>::try_from(v).ok()?), t.level))
            })
            .collect(),
    };
    by.read
        .iter()
        .find(|(l, at)| *at < rules::CIRCLE || level(l) != Some(rules::CIRCLE))
        .map(|(l, at)| {
            format!(
                "your session read data of {} (level {}): your answers do not count until the owner starts a clean \
                 session for you",
                name(l),
                level(l).unwrap_or(*at).min(*at)
            )
        })
}

impl Session {
    /// The own computers whose last status names an agent of this computer called `name` an approver, with the scope
    /// their owner set (only links at level 5 here).
    pub(crate) fn devices_naming_approver(&self, name: &str) -> Vec<(LinkId, StatusApprover)> {
        let latest = self
            .devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter_map(|(link, (s, _))| {
                s.approvers
                    .iter()
                    .find(|a| a.agent == name)
                    .map(|a| (*link, a.clone()))
            })
            .collect::<Vec<_>>();
        latest
            .into_iter()
            .filter(|(l, _)| self.link_trust(l) == rules::CIRCLE)
            .collect()
    }

    /// The requests own computers offer agent `row` (approvers there), and why its answers would not count now.
    pub(crate) fn device_requests_for(
        &self,
        row: &AgentRow,
    ) -> (Vec<(LinkId, DelegatedRequest)>, Option<String>) {
        let names = self.link_names().unwrap_or_default();
        let mut out = Vec::new();
        let links: Vec<LinkId> = self
            .devices_naming_approver(&row.name)
            .into_iter()
            .map(|(l, _)| l)
            .filter(|l| row.links.as_ref().is_none_or(|s| s.contains(l)))
            .collect();
        if links.is_empty() {
            return (out, None);
        }
        let latest = self
            .devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        for l in links {
            let Some((status, _)) = latest.get(&l) else {
                continue;
            };
            let label = names
                .get(&l)
                .map_or_else(|| l.to_hex()[..8].to_string(), |(n, _)| n.clone());
            for a in status
                .approvals
                .iter()
                .filter(|a| a.approvers.iter().any(|n| n == &row.name))
            {
                out.push((l, view(a, &label)));
            }
        }
        let blocked = tainted(
            row,
            |l| names.get(l).map(|(_, t)| *t),
            |l| {
                names
                    .get(l)
                    .map_or_else(|| l.to_hex()[..8].to_string(), |(n, _)| n.clone())
            },
        );
        (out, blocked)
    }

    /// A new status from own computer `link`: requests it offers to this computer's approvers for the first time are
    /// facts for them (`wait`, `inbox`, their subscription).
    pub(crate) fn offer_device_requests(&self, link: LinkId, status: &DeviceStatus) {
        let label = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&link)
            .map(|r| r.label)
            .unwrap_or_default();
        let current: std::collections::HashSet<String> =
            status.approvals.iter().map(|a| a.id.clone()).collect();
        // Forget what that computer no longer lists, so the set stays small
        self.delegation
            .offered
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|(l, id, _)| *l != link || current.contains(id));
        for a in &status.approvals {
            for name in &a.approvers {
                let row = {
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    db.agent_by_name(name).ok()
                };
                let Some(row) = row else { continue };
                if !row.links.as_ref().is_none_or(|s| s.contains(&link)) {
                    continue;
                }
                let new = self
                    .delegation
                    .offered
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert((link, a.id.clone(), row.id));
                if new {
                    self.offer_fact(
                        row.id,
                        ToAnswerFact {
                            id: a.id.clone(),
                            device: Some(label.clone()),
                            action: a.action.clone(),
                            requester: a.requester.clone(),
                            expires_ms: a.expires_ms,
                        },
                    );
                }
            }
        }
    }

    /// The approver fields of this computer's status to own computer `link` (its node has `agent-approve/0`): that
    /// computer's agents the owner made approvers here, and per pending request which of them may answer it now.
    pub(crate) fn status_approvers(&self, link: &LinkId, st: &mut DeviceStatus) {
        let remote: Vec<_> = self
            .delegations()
            .into_iter()
            .filter(|d| matches!(&d.approver, Approver::Remote { link: l, .. } if l == link))
            .collect();
        st.approvers = remote
            .iter()
            .take(device::MAX_APPROVERS)
            .filter_map(|d| {
                let Approver::Remote { name, .. } = &d.approver else {
                    return None;
                };
                let agents = d.agents.as_ref().map(|ids| {
                    let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                    ids.iter()
                        .filter_map(|id| db.agent(*id).ok().map(|r| r.name))
                        .take(device::MAX_AGENTS)
                        .collect()
                });
                Some(StatusApprover {
                    agent: name.clone(),
                    agents,
                    kinds: d.kinds.clone(),
                })
            })
            .collect();
        if remote.is_empty() {
            return;
        }
        for a in &mut st.approvals {
            let info = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&a.id, now_ms());
            let Some(info) = info else { continue };
            for d in &remote {
                let Approver::Remote { name, .. } = &d.approver else {
                    continue;
                };
                let by = rules::Answerer {
                    local: None,
                    device: Some(*link),
                    read: Vec::new(),
                };
                if a.approvers.len() < device::MAX_APPROVERS
                    && self.delegate_check(&d.approver, &by, &info).is_ok()
                {
                    a.approvers.push(name.clone());
                }
            }
        }
    }

    // The asking computer

    /// `agent_challenge` from own computer `link`: a nonce for one answer to request `id`, only when an agent of that
    /// computer is an approver here and the request is pending.
    pub(in crate::node) fn agent_challenge_in(
        &self,
        link: LinkId,
        id: &str,
    ) -> Result<DeviceReply> {
        if self.link_trust(&link) != rules::CIRCLE {
            return Err(Error::new("level", "not at level 5"));
        }
        let any = self
            .delegations()
            .iter()
            .any(|d| matches!(&d.approver, Approver::Remote { link: l, .. } if *l == link));
        if !any {
            return Err(Error::new(
                code::FORBIDDEN,
                "no agent of that computer is an approver here",
            ));
        }
        let pending = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id, now_ms())
            .is_some_and(|i| i.state == "pending");
        if !pending {
            return Err(Error::new(code::NOT_FOUND, "no such pending request"));
        }
        let ttl = u64::try_from(self.cfg.owner_challenge_ttl.as_millis()).unwrap_or(u64::MAX);
        let (nonce, expires_ms) = self
            .delegation
            .challenges
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .issue(link, id, now_ms(), ttl);
        Ok(DeviceReply::Challenge { nonce, expires_ms })
    }

    /// An answer from own computer `link` that names a pending request here but did not verify: the card says so,
    /// with the name the answer claims (it is not proven), and the owner's list keeps it.
    fn note_unverified(&self, link: LinkId, d: &AgentDecision, e: &Error) {
        let Ok(text) = AgentDecisionText::parse(&d.request) else {
            return;
        };
        if text.link != link.to_hex() {
            return;
        }
        let info = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&text.id, now_ms())
            .filter(|i| i.state == "pending");
        let Some(info) = info else { return };
        let label = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&link)
            .map(|r| r.label)
            .unwrap_or_default();
        self.refuse_delegated(
            &info,
            &text.agent,
            Some(label),
            &rules::Refusal {
                why: why::UNVERIFIED,
                message: format!(
                    "an answer that says it is from {} could not be verified ({}): the owner answers",
                    text.agent, e.code
                ),
            },
        );
    }

    /// An approver agent's answer from own computer `link` (`docs/PROTOCOL.md` §24): checked in this order, then
    /// decided as an answer of an approver here.
    pub(in crate::node) fn agent_decide_in(
        self: &Arc<Self>,
        link: LinkId,
        d: &AgentDecision,
    ) -> Result<DeviceReply> {
        if self.link_trust(&link) != rules::CIRCLE {
            return Err(Error::new("level", "not at level 5"));
        }
        let now = now_ms();
        self.delegation
            .challenges
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .check_pause(&link, now)?;
        let r = self.agent_decision_check(link, d, now);
        let ok = r.is_ok();
        let counts = match &r {
            Err(e) => matches!(
                e.code,
                code::PROOF_INVALID | code::CHALLENGE_INVALID | code::OWNER_KEY_UNKNOWN
            ),
            Ok(_) => false,
        };
        if ok || counts {
            self.delegation
                .challenges
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .record(link, ok, now);
        }
        if let Err(e) = &r {
            self.note_unverified(link, d, e);
        }
        let (text, key) = r?;
        let label = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&link)
            .map(|r| r.label)
            .unwrap_or_default();
        let info = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&text.id, now)
            .filter(|i| i.state == "pending")
            .ok_or_else(|| Error::new(code::NOT_FOUND, "no such pending request"))?;
        let approver = Approver::Remote {
            link,
            name: text.agent.clone(),
            key,
        };
        let by = rules::Answerer {
            local: None,
            device: Some(link),
            read: Vec::new(),
        };
        // The other computer says its agent read something below level 5 there: the person answers, and is told
        let check = if text.clean {
            self.delegate_check(&approver, &by, &info)
        } else {
            Err(rules::Refusal {
                why: why::TAINTED,
                message: format!(
                    "{}'s session on {label} read data of a contact below ∞ (level 5): an injected text could make \
                     it approve, so the owner answers",
                    text.agent
                ),
            })
        };
        if let Err(refusal) = check {
            self.refuse_delegated(&info, &text.agent, Some(label.clone()), &refusal);
            self.receipt(
                &link,
                &format!("{}@{label}", text.agent),
                "agent_decision",
                "refused",
                refusal.why,
                None,
                Some(&info.id),
            );
            return Err(Error::new(code::FORBIDDEN, refusal.message));
        }
        let reason = delegation::checked_reason(&text.reason)?;
        let answer = self.decide_delegated(
            &info,
            text.decision == "approve",
            &text.fingerprint,
            DecidedBy {
                agent: text.agent.clone(),
                device: Some(label.clone()),
                reason,
                at_ms: now,
            },
        )?;
        // On the approver's computer's link too: which request, which agent, which key
        self.receipt(
            &link,
            &format!("{}@{label}", text.agent),
            "agent_decision",
            &answer.state,
            &format!(
                "{} {} ({} for {}), key {}",
                answer.state,
                info.id,
                info.action,
                info.contact,
                &text.key[..16]
            ),
            None,
            Some(&info.id),
        );
        self.device_event(&link, "decided");
        Ok(DeviceReply::Decided {
            id: info.id,
            state: answer.state,
        })
    }

    /// The signed text, the challenge, the delegation and the key, the signature: the parts of an answer from
    /// another computer that only the cryptography decides (`delegation::remote::verify`). The text and the key on
    /// success.
    fn agent_decision_check(
        &self,
        link: LinkId,
        d: &AgentDecision,
        now: u64,
    ) -> Result<(AgentDecisionText, [u8; 32])> {
        let take = |n: &[u8; 32], id: &str| {
            self.delegation
                .challenges
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take(&link, n, id, now)
        };
        let named = |name: &str| {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let d = delegation::find(
                &db,
                &Approver::Remote {
                    link,
                    name: name.to_string(),
                    key: [0; 32],
                },
            )
            .ok()
            .flatten()?;
            match d.approver {
                Approver::Remote { key, .. } => Some(key),
                Approver::Local(_) => None,
            }
        };
        let active = |key: &[u8; 32], name: &str| self.remote_key_active(&link, name, key);
        delegation::remote::verify(
            &link,
            d,
            &delegation::remote::Known {
                take: &take,
                named: &named,
                active: &active,
            },
        )
    }

    // The approver's computer

    /// `approval_answer` with `device`: this computer's agent `row` answers a request own computer `device` offered
    /// it. That computer decides; this one signs for the agent and tells it the outcome.
    pub(crate) async fn agent_answer_remote(
        &self,
        row: &AgentRow,
        device_label: &str,
        a: &ApprovalAnswer,
        approve: bool,
        reason: &str,
    ) -> Result<AnswerReply> {
        let link_row = self.find_link(device_label)?;
        let link = link_row.link_id;
        if link_row.trust != rules::CIRCLE {
            return Err(Error::new(
                code::FORBIDDEN,
                format!("{} is not at ∞ (level 5) here", link_row.label),
            ));
        }
        if !row.links.as_ref().is_none_or(|s| s.contains(&link)) {
            return Err(Error::new(
                code::FORBIDDEN,
                format!("{} is not among your links", link_row.label),
            ));
        }
        let offered = self
            .devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&link)
            .is_some_and(|(s, _)| {
                s.approvals
                    .iter()
                    .any(|x| x.id == a.id && x.approvers.iter().any(|n| n == &row.name))
            });
        if !offered {
            return Err(Error::new(
                code::FORBIDDEN,
                format!(
                    "{} does not offer request {} to you (it may be decided, expired or out of your scope)",
                    link_row.label, a.id
                ),
            ));
        }
        let rt = self.rt(&link)?;
        if !rt.shared.peer_supports_agent_approve() {
            return Err(Error::new(
                code::UNKNOWN_COMMAND,
                format!(
                    "{}'s Antenna does not take approver agents' answers: update it",
                    link_row.label
                ),
            ));
        }
        let names = self.link_names()?;
        let clean = tainted(
            row,
            |l| names.get(l).map(|(_, t)| *t),
            |l| {
                names
                    .get(l)
                    .map_or_else(|| l.to_hex()[..8].to_string(), |(n, _)| n.clone())
            },
        )
        .is_none();
        let signing = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            agentid::own_signing(db.conn(), &link, &row.name)?
        };
        let Some(signing) = signing else {
            return Err(Error::new(
                code::FORBIDDEN,
                format!(
                    "you have no key on the link with {} yet: write one message there first",
                    link_row.label
                ),
            ));
        };
        let seed = signing
            .seed
            .ok_or_else(|| Error::internal("own agent key without its secret"))?;
        let nonce = match rt
            .shared
            .device_send(&DeviceMsg::AgentChallenge { id: a.id.clone() })
            .await?
        {
            Some(DeviceReply::Challenge { nonce, .. }) => nonce,
            other => return Err(Error::network(format!("agent challenge: {other:?}"))),
        };
        let text = AgentDecisionText {
            cmd: AgentDecisionText::CMD.into(),
            link: link.to_hex(),
            id: a.id.clone(),
            fingerprint: a.fingerprint.to_ascii_lowercase(),
            decision: if approve { "approve" } else { "deny" }.into(),
            agent: row.name.clone(),
            key: HEXLOWER.encode(&signing.key),
            reason: reason.to_string(),
            clean,
        }
        .to_text();
        let msg =
            device::agent_decision_message(&nonce, &crate::crypto::sha256(&[text.as_bytes()]));
        let sig = history::sign(&seed, &msg).to_vec();
        let r = rt
            .shared
            .device_send(&DeviceMsg::AgentDecide(AgentDecision {
                request: text,
                nonce,
                sig,
            }))
            .await;
        let (decision, out) = match r {
            Ok(Some(DeviceReply::Decided { id, state })) => (
                state.clone(),
                Ok(AnswerReply {
                    message: if state == "denied" {
                        format!(
                            "Denied in the owner's place on {}: the agent that asked is told. The owner sees your \
                             answer and your reason.",
                            link_row.label
                        )
                    } else {
                        format!(
                            "Approved in the owner's place on {}: Antenna there carries out request {id} and tells \
                             the agent that asked. The owner sees your answer and your reason.",
                            link_row.label
                        )
                    },
                    id,
                    state,
                }),
            ),
            Ok(other) => (
                "refused".to_string(),
                Err(Error::network(format!("agent decision: {other:?}"))),
            ),
            Err(e) => ("refused".to_string(), Err(e)),
        };
        // This computer's record: which of its agents answered what for that computer
        self.receipt(
            &link,
            &row.name,
            "agent_decision",
            &decision,
            &format!("{} {}", a.id, if approve { "approve" } else { "deny" }),
            None,
            Some(&a.id),
        );
        out
    }
}
