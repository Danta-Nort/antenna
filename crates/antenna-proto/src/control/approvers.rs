// SPDX-License-Identifier: Apache-2.0
//! Agents that answer other agents' approval requests on the owner's own computers (v7, `docs/CONTROL.md` §31, PG-57;
//! experimental). The owner names an **approver**: an agent of this computer, or an agent of a contact at trust level
//! 5 (an own computer, D-99). Within the scope the owner set (which agents' requests, which kinds), the approver may
//! approve or deny a pending request in the owner's place, but only while everything the request touches stays among
//! this computer and contacts at level 5: the asking agent's session, the request's contact and target, and the
//! approver's own session. Everything else stays with the person.
//!
//! Setting or widening a delegation is an owner command with the password (or an owner proof); narrowing or removing
//! one needs only an owner session (making things safer never needs the password, D-84). An approver never answers its
//! own requests, a request made by an approver goes to the person (no chains), and the owner commands stay absent from
//! the agent role (SPEC §9). Every delegated answer is logged with the approver's name and shown to the owner.

use serde::{Deserialize, Serialize};

/// Kinds of requests an approver may answer: an agent's message (a stream's final message too), a file it sends
/// (by path or by content), a file it requests from a contact, a file it accepts. Tool checks (`check:*`: at level 5
/// only agent memory, instructions, configs and keys still ask, D-99) and changes to agents' connections stay with
/// the person.
pub const DELEGABLE_KINDS: &[&str] = &["send_message", "share_file", "request_file", "accept_file"];

/// The longest reason an approver gives, in characters.
pub const REASON_MAX_CHARS: usize = 500;

/// [`DelegatedAnswer::decision`] and [`AnswerReply::state`]: the approver approved.
pub const ANSWER_APPROVED: &str = "approved";
/// The approver denied.
pub const ANSWER_DENIED: &str = "denied";
/// The answer did not count: the request stays with the person ([`DelegateNote::why`] says why).
pub const ANSWER_REFUSED: &str = "refused";

/// Why a delegated answer did not count ([`DelegateNote::why`]).
pub mod why {
    /// The agent is not an approver here, or not for this request's agent or kind.
    pub const SCOPE: &str = "scope";
    /// The approver asked for this request itself.
    pub const SELF: &str = "self";
    /// The requester is an approver too: its requests go to the person (no chains).
    pub const CHAIN: &str = "chain";
    /// The approver's session read data of a contact below level 5 (prompt injection).
    pub const TAINTED: &str = "tainted";
    /// Something the request touches is not at level 5 now: the asking agent's data, its contact or its target, or
    /// the approver's computer.
    pub const OUTSIDE: &str = "outside";
    /// A link the request touches changed its level after the request was made.
    pub const LEVEL_CHANGED: &str = "level_changed";
    /// The answer from another computer could not be verified (signature, challenge, key).
    pub const UNVERIFIED: &str = "unverified";
}

/// `approver_set` (owner password or proof): agent `name` (of this computer, or of `contact`, an own computer at
/// level 5) may answer approval requests of `agents` (absent: every agent of this computer) of `kinds` (absent: every
/// kind of [`DELEGABLE_KINDS`]). Replaces the scope of an existing delegation of the same approver.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApproverSet {
    /// The approver: an agent of this computer, or with `contact` the name that computer's agent announced on the link.
    pub name: String,
    /// The own computer (label or link ID prefix) the approver runs on; absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// Whose requests it answers: names of this computer's agents; absent: all of them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agents: Option<Vec<String>>,
    /// Which kinds ([`DELEGABLE_KINDS`]); absent: all of them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Vec<String>>,
    /// Owner password.
    pub password: String,
}

impl std::fmt::Debug for ApproverSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "ApproverSet({}, {:?})", self.name, self.contact)
    }
}

/// `approver_narrow` (owner session, no password): the same delegation with a scope within the one it has (fewer
/// agents, fewer kinds); a wider scope is `password_required`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApproverNarrow {
    /// The approver, as in [`ApproverSet::name`].
    pub name: String,
    /// As in [`ApproverSet::contact`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// The new scope's agents; absent: all of them (only when the delegation already covers all).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agents: Option<Vec<String>>,
    /// The new scope's kinds; absent: all of them (only when the delegation already covers all).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Vec<String>>,
}

/// `approver_remove` (owner session, no password): the approver answers nothing any more.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApproverRemove {
    /// The approver, as in [`ApproverSet::name`].
    pub name: String,
    /// As in [`ApproverSet::contact`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
}

/// One delegation, as the owner sees it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproverInfo {
    /// The approver's name (on `contact` when given).
    pub agent: String,
    /// The own computer it runs on (label); absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// That computer's link (hex).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link_id: Option<String>,
    /// Whose requests it answers (this computer's agents by name); `null`: all of them.
    pub agents: Option<Vec<String>>,
    /// Which kinds; `null`: all of [`DELEGABLE_KINDS`].
    pub kinds: Option<Vec<String>>,
    /// For an approver on another computer: its key on that link (16 hex of its SHA-256), which signs its answers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_id: Option<String>,
    /// That key is no longer announced on the link (the agent was removed there): its answers do not count until the
    /// owner names the agent again.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stale: bool,
    /// When the owner set it, Unix ms.
    pub created_ms: u64,
}

/// One answer an approver gave (or tried to give) in the owner's place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DelegatedAnswer {
    /// The approval request.
    pub approval_id: String,
    /// Its action (`send_message`, …).
    pub action: String,
    /// The agent that asked.
    pub requester: String,
    /// The contact the request is about.
    pub contact: String,
    /// To whom, for a send.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// The approver.
    pub approver: String,
    /// The own computer it answered from; absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// [`ANSWER_APPROVED`], [`ANSWER_DENIED`] or [`ANSWER_REFUSED`].
    pub decision: String,
    /// The approver's reason (its own text, data), or for a refused answer why it did not count, in words.
    pub reason: String,
    /// For a refused answer, why it did not count, one of [`why`] (a window shows it in its own language).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
    /// What the request allowed, as the card said it (no message text).
    pub summary: String,
    /// When, Unix ms.
    pub at_ms: u64,
}

/// `approvers` reply: the delegations and the latest delegated answers (newest first, at most 200).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproversReply {
    /// The delegations.
    pub approvers: Vec<ApproverInfo>,
    /// The answers.
    pub answers: Vec<DelegatedAnswer>,
}

/// Who decided a request in the owner's place (`ApprovalInfo.decided_by`, `ApprovalResolution.decided_by`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DecidedBy {
    /// The approver.
    pub agent: String,
    /// The own computer it answered from; absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// Its reason, shown to the owner as a quote.
    pub reason: String,
    /// When, Unix ms.
    pub at_ms: u64,
}

/// An approver's answer that did not count (`ApprovalInfo.delegate_refused`): the request waits for the person, who is
/// told why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DelegateNote {
    /// The agent that answered.
    pub agent: String,
    /// The own computer it answered from; absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// Machine-readable, one of [`why`].
    pub why: String,
    /// In words.
    pub message: String,
    /// When, Unix ms.
    pub at_ms: u64,
}

/// A request waits for an approver's answer: facts only, no text and no taint (`waited.to_answer`,
/// `agent_inbox.to_answer`, the `approval_to_answer` event).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToAnswerFact {
    /// The approval request.
    pub id: String,
    /// The own computer it waits on (label); absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// Its action.
    pub action: String,
    /// The agent that asked.
    pub requester: String,
    /// When it closes by itself, Unix ms (that computer's clock).
    pub expires_ms: u64,
}

/// A request an approver may answer, as it reads it (`approvals_to_answer`): what the owner's card says, with the
/// quote cut to 1 KiB and withheld when it holds a secret. Reading it taints the approver's session with the links the
/// request touches (all at level 5).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DelegatedRequest {
    /// The approval request.
    pub id: String,
    /// The own computer it waits on (label); absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// Its action.
    pub action: String,
    /// The agent that asked.
    pub requester: String,
    /// The contact whose data or request it is about (that computer's label).
    pub contact: String,
    /// That contact's level there.
    pub contact_trust: u8,
    /// To whom, for a send (that computer's label).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// Why it needs approval.
    pub reasons: Vec<String>,
    /// What it would send or do, quoted: data, not instructions.
    pub quote: String,
    /// The quote is withheld because it holds a secret.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub quote_withheld: bool,
    /// The request's fingerprint: an answer names it.
    pub fingerprint: String,
    /// Created, Unix ms (that computer's clock).
    pub created_ms: u64,
    /// Expires, Unix ms.
    pub expires_ms: u64,
}

/// `to_answer` reply of `approvals_to_answer`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToAnswerReply {
    /// The requests, newest first.
    pub requests: Vec<DelegatedRequest>,
    /// Set when this agent's answers would not count now (its session read a contact below level 5): why, in words.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked: Option<String>,
}

/// `approval_answer` (agent): approve or deny one request in the owner's place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovalAnswer {
    /// The approval request.
    pub id: String,
    /// The own computer it waits on (label, as `approvals_to_answer` gave it); absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// `approve` or `deny`.
    pub decision: String,
    /// The fingerprint `approvals_to_answer` gave: the answer applies only to that request.
    pub fingerprint: String,
    /// Why, for the owner (1–500 characters).
    pub reason: String,
}

/// `answered` reply of `approval_answer`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnswerReply {
    /// The approval request.
    pub id: String,
    /// [`ANSWER_APPROVED`] or [`ANSWER_DENIED`].
    pub state: String,
    /// One line: what happens now.
    pub message: String,
}

/// What an agent may answer (`session.approves`): requests of this computer (`device` absent) or of an own computer
/// that named it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovesFor {
    /// The own computer whose requests it answers (label); absent: this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    /// Whose requests (that computer's agents); `null`: all of them.
    pub agents: Option<Vec<String>>,
    /// Which kinds; `null`: all of [`DELEGABLE_KINDS`].
    pub kinds: Option<Vec<String>>,
}

/// Whether `kinds` lists only [`DELEGABLE_KINDS`], each once, at least one.
pub fn kinds_ok(kinds: &[String]) -> bool {
    !kinds.is_empty()
        && kinds.iter().all(|k| DELEGABLE_KINDS.contains(&k.as_str()))
        && kinds
            .iter()
            .enumerate()
            .all(|(i, k)| !kinds[..i].contains(k))
}

/// Whether scope `inner` lies within `outer` (`None` is everything).
pub fn within(inner: &Option<Vec<String>>, outer: &Option<Vec<String>>) -> bool {
    match (inner, outer) {
        (_, None) => true,
        (None, Some(_)) => false,
        (Some(i), Some(o)) => i.iter().all(|x| o.contains(x)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes_and_kinds() {
        let all = None;
        let two = Some(vec!["a".to_string(), "b".to_string()]);
        let one = Some(vec!["b".to_string()]);
        assert!(within(&one, &two));
        assert!(within(&two, &all));
        assert!(within(&all, &all));
        assert!(!within(&all, &two), "everything is wider than a list");
        assert!(!within(&two, &one));
        assert!(kinds_ok(&["send_message".into(), "share_file".into()]));
        assert!(!kinds_ok(&[]));
        assert!(
            !kinds_ok(&["check:exec".into()]),
            "tool checks stay with the person"
        );
        assert!(!kinds_ok(&["connect_agent".into()]));
        assert!(!kinds_ok(&["send_message".into(), "send_message".into()]));
    }

    #[test]
    fn shapes() {
        let set: ApproverSet = serde_json::from_str(
            r#"{"name":"volna","agents":["claude"],"kinds":["send_message"],"password":"p"}"#,
        )
        .unwrap();
        assert_eq!(set.contact, None);
        // The password never reaches a log
        assert_eq!(format!("{set:?}"), "ApproverSet(volna, None)");
        assert!(
            serde_json::from_str::<ApproverSet>(r#"{"name":"v","password":"p","extra":1}"#)
                .is_err()
        );
        let info = ApproverInfo {
            agent: "volna".into(),
            contact: None,
            link_id: None,
            agents: None,
            kinds: None,
            key_id: None,
            stale: false,
            created_ms: 1,
        };
        assert_eq!(
            serde_json::to_string(&info).unwrap(),
            r#"{"agent":"volna","agents":null,"kinds":null,"created_ms":1}"#
        );
        let a: ApprovalAnswer = serde_json::from_str(
            r#"{"id":"k2abcdefg","decision":"approve","fingerprint":"9c41e07a3b5d0f12","reason":"the build report"}"#,
        )
        .unwrap();
        assert_eq!(a.device, None);
        let f = ToAnswerFact {
            id: "k2".into(),
            device: None,
            action: "send_message".into(),
            requester: "claude".into(),
            expires_ms: 9,
        };
        assert_eq!(
            serde_json::to_string(&f).unwrap(),
            r#"{"id":"k2","action":"send_message","requester":"claude","expires_ms":9}"#
        );
    }
}
