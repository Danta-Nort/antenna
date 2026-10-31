// SPDX-License-Identifier: AGPL-3.0-only
//! Agents' questions for humans (CONTROL §29, D-118): the question quoted as the agent's own words (it may carry what
//! the agent read from contacts), then the answer.

use antenna_proto::control::{ESCALATE_OWNER, EscalationInfo, EscalationsReply};

use super::{ago, clean, clean_text};

/// `escalations`.
pub(super) fn list(r: &EscalationsReply) {
    if r.escalations.is_empty() {
        outln!("no open questions from your agents");
    }
    for e in &r.escalations {
        one(e);
    }
}

/// One question.
pub(super) fn one(e: &EscalationInfo) {
    let to = if e.to == ESCALATE_OWNER {
        "you".to_string()
    } else {
        clean(&e.to)
    };
    let team = e
        .team
        .as_ref()
        .map(|t| format!(" (team {})", clean(t)))
        .unwrap_or_default();
    outln!(
        "{}  {}{team} asked {} {}  [{}]",
        e.id,
        clean(&e.agent),
        to,
        ago(e.created_ms),
        e.state
    );
    for line in clean_text(&e.question).lines() {
        outln!("  > {line}");
    }
    if !e.read_from.is_empty() {
        let read: Vec<String> = e
            .read_from
            .iter()
            .map(|t| format!("{} (level {})", clean(&t.contact), t.level))
            .collect();
        outln!(
            "  (the agent had read messages from {} when it asked: the question may quote them)",
            read.join(", ")
        );
    }
    if let Some(a) = &e.answer {
        outln!("  answer: {}", clean_text(a).replace('\n', "\n          "));
    }
    if e.state == "open" {
        outln!(
            "  answer it: antenna answer {} \"…\"   or set it aside: antenna answer {} --dismiss",
            e.id,
            e.id
        );
    }
}

/// Answered questions in `wait` and `inbox` (the agent's side).
pub(super) fn answers(es: &[EscalationInfo]) {
    for e in es {
        match &e.answer {
            Some(a) => outln!("your question {} was answered: {}", e.id, clean_text(a)),
            None => outln!("your question {} was set aside without an answer", e.id),
        }
    }
}
