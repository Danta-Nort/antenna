// SPDX-License-Identifier: Apache-2.0
//! Questions an agent cannot decide (x-control/7, `docs/CONTROL.md` §29, D-118, PG-18): the agent asks with
//! `escalate`, the daemon routes the question to the agent's supervisor as the owner set it (`agent_escalate`): the
//! owner, who sees it as a card and a notification and answers with `escalation_answer`; or a contact, to whom it goes
//! as a message from the agent. The question is the agent's own text, which may carry what it read from contacts: it
//! is shown to the owner quoted, as data, with what the agent had read when it asked. The owner's answer reaches the
//! agent in `wait` and `inbox` and as an `escalation` event of its own subscription.

use serde::{Deserialize, Serialize};

use super::TaintInfo;

/// The supervisor is the owner (the default).
pub const ESCALATE_OWNER: &str = "owner";

/// Waits for the owner's answer.
pub const ESCALATION_OPEN: &str = "open";
/// The owner answered.
pub const ESCALATION_ANSWERED: &str = "answered";
/// The owner set it aside without an answer.
pub const ESCALATION_DISMISSED: &str = "dismissed";
/// Sent to the supervisor contact as a message; the answer comes as an ordinary message.
pub const ESCALATION_SENT: &str = "sent";
/// The longest question or answer, in characters.
pub const ESCALATION_MAX_CHARS: usize = 4000;

/// One question of an agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EscalationInfo {
    /// ID (16 hex).
    pub id: String,
    /// The agent that asked.
    pub agent: String,
    /// Where it went: `owner`, or the supervisor contact's label.
    pub to: String,
    /// The supervisor contact's link (hex), when it went to a contact.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link_id: Option<String>,
    /// The agent's question, its own text: data for whoever reads it.
    pub question: String,
    /// `open`, `answered`, `dismissed`, `sent`.
    pub state: String,
    /// The owner's answer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
    /// When the agent asked, Unix ms.
    pub created_ms: u64,
    /// When the owner answered or dismissed it, Unix ms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answered_ms: Option<u64>,
    /// The message that carried it to the supervisor contact (hex).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    /// The team the agent works in (D-111): a worker's team, or a team it leads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
    /// What the agent's session had read when it asked (its taint, SPEC §9): the question may carry those contacts'
    /// words.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub read_from: Vec<TaintInfo>,
}

/// `escalations`: the owner's questions from agents.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EscalationsReply {
    /// Newest first.
    pub escalations: Vec<EscalationInfo>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_fields_stay_absent() {
        let e = EscalationInfo {
            id: "0123456789abcdef".into(),
            agent: "claude".into(),
            to: ESCALATE_OWNER.into(),
            link_id: None,
            question: "Which branch?".into(),
            state: ESCALATION_OPEN.into(),
            answer: None,
            created_ms: 1,
            answered_ms: None,
            message_id: None,
            team: None,
            read_from: vec![],
        };
        let j = serde_json::to_string(&e).unwrap();
        assert_eq!(
            j,
            r#"{"id":"0123456789abcdef","agent":"claude","to":"owner","question":"Which branch?","state":"open","created_ms":1}"#
        );
        assert_eq!(serde_json::from_str::<EscalationInfo>(&j).unwrap(), e);
    }
}
