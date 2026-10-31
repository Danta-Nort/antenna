// SPDX-License-Identifier: AGPL-3.0-only
//! Local model workers (D-111 item 5, D-104): a local agent of this computer, run by the pool in its own sandbox
//! without network, in a conversation of its own for the team (`team:<name>`). Local agents have no tools yet
//! (D-104), so their turn carries the task's text (the lead's words, with the taint the task carries) and their reply
//! is the result, recorded by the daemon as a text-only submission. Roles follow the model's class (§3.3): no local
//! class codes in this release.

use std::sync::{Arc, PoisonError};

use antenna_proto::control::{LocalTurn, task_state as st};

use super::{Task, TeamRow, db, watch::Output};
use crate::{local::LocalOut, node::Session};

/// The longest turn text a local model gets for a task.
const MAX_TURN: usize = 32 * 1024;

/// The turn of a local worker: the task's title, brief and the latest review comments, labelled as the lead's.
pub(super) fn local_turn_text(team: &str, t: &Task) -> String {
    let mut s = format!(
        "[Antenna] Task {} of the team {team}, from your team's lead (round {}): {}\n\n{}",
        t.id,
        t.round,
        super::one_line(&t.title, 200),
        t.brief
    );
    if t.state == st::RETURNED
        && let Some(r) = t.reviews.last()
    {
        s.push_str(&format!(
            "\n\n[Antenna] Your previous result came back with these comments from {}:\n{}",
            r.by, r.comments
        ));
    }
    s.push_str("\n\n[Antenna] Reply with your result only.");
    super::text_of(&s, MAX_TURN)
}

impl Session {
    /// Run a local worker's turn for its task and record the reply as the task's result.
    pub(super) fn local_worker_turn(self: &Arc<Self>, agent_id: i64, task: String, _hint: String) {
        let s = self.clone();
        tokio::spawn(async move {
            let Some(m) = s.team_member(agent_id) else {
                return;
            };
            let Ok(team) = s.load_team(m.team_id) else {
                return;
            };
            let Ok(t) = s.own_task(&team, &m, &task) else {
                return;
            };
            if !matches!(t.state.as_str(), st::ASSIGNED | st::WORKING | st::RETURNED) {
                return;
            }
            let rx = match s.local_team_say(agent_id, &team.name, local_turn_text(&team.name, &t)) {
                Ok(rx) => rx,
                Err(e) => {
                    s.team_daemon_block(
                        &team,
                        &task,
                        &format!("the local model could not start: {}", e.message),
                    )
                    .await;
                    return;
                }
            };
            // The owner watches it as any worker's turn: the pool streams its text here already.
            let n = m.spec.turns.saturating_add(1);
            s.teams
                .output
                .start(agent_id, &team.name, &m.name, Some(&task), n);
            let done = wait_done(&s.teams.output, agent_id, rx).await;
            s.teams.output.end(agent_id, end_of(done.as_ref()));
            s.count_local_turn(agent_id, done.as_ref());
            match done {
                Some(turn) if turn.outcome == "done" && !turn.text.trim().is_empty() => {
                    let tokens = turn
                        .usage
                        .as_ref()
                        .map_or(0, |u| u.prompt_tokens + u.output_tokens);
                    s.team_task_tokens(&team, &task, tokens).await;
                    if let Err(e) = s.task_text_result(&team, &m, &task, &turn.text).await {
                        tracing::info!("team {}: local result of {task}: {}", team.name, e.message);
                    }
                }
                Some(turn) => {
                    let why = format!(
                        "the local model's turn ended {}{}",
                        turn.outcome,
                        if turn.detail.is_empty() {
                            String::new()
                        } else {
                            format!(": {}", turn.detail)
                        }
                    );
                    s.team_daemon_block(&team, &task, &why).await;
                }
                None => {
                    s.team_daemon_block(&team, &task, "the local model's session ended")
                        .await;
                }
            }
        });
    }

    /// A local worker's state for its team conversation.
    pub(super) fn local_team_state(&self, agent_id: i64, team_id: i64) -> Option<&'static str> {
        let team = db::team(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team_id,
        )
        .ok()?;
        self.local_team_conversation(agent_id, &team.name, false)
    }

    /// Stop a local worker's process for its team.
    pub(super) fn local_team_stop(&self, agent_id: i64, team: &TeamRow) {
        let _ = self.local_team_conversation(agent_id, &team.name, true);
    }

    /// A local worker's turn ended: its counters, as a cloud worker's.
    fn count_local_turn(&self, agent_id: i64, turn: Option<&LocalTurn>) {
        let Some(mut m) = self.team_member(agent_id) else {
            return;
        };
        m.spec.turns = m.spec.turns.saturating_add(1);
        if let Some(u) = turn.and_then(|t| t.usage.as_ref()) {
            m.spec.input_tokens = m.spec.input_tokens.saturating_add(u.prompt_tokens);
            m.spec.output_tokens = m.spec.output_tokens.saturating_add(u.output_tokens);
        }
        let _ = self.save_member(&m);
    }
}

/// How a local turn ended, for the owner's watch.
fn end_of(turn: Option<&LocalTurn>) -> &'static str {
    match turn.map(|t| t.outcome.as_str()) {
        Some("done") => "done",
        Some("interrupted") => "interrupted",
        _ => "failed",
    }
}

/// The end of a local turn; its text and activity on the way go to the owner's watch.
async fn wait_done(
    out: &Output,
    agent_id: i64,
    mut rx: tokio::sync::mpsc::UnboundedReceiver<LocalOut>,
) -> Option<LocalTurn> {
    while let Some(o) = rx.recv().await {
        match o {
            LocalOut::Delta {
                delta, activity, ..
            } => {
                if let Some(a) = activity {
                    out.activity(agent_id, &a);
                }
                out.text(agent_id, &delta);
            }
            LocalOut::Done(t) => return Some(t),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_local_turn_carries_the_task_labelled_as_the_leads() {
        let mut t = Task {
            id: "0123456789abcdef".into(),
            title: "Summarize the changelog".into(),
            brief: "Three bullet points.".into(),
            check: vec![],
            assignee: Some(1),
            state: st::ASSIGNED.into(),
            created_by: "lead".into(),
            carried: vec![],
            round: 1,
            notes: String::new(),
            reviews: vec![],
            report: None,
            result: None,
            result_carried: vec![],
            result_text: None,
            check_run: None,
            applied: None,
            tokens: 0,
            auto_returns: 0,
            reminded_round: 0,
            base: None,
            created_ms: 0,
            updated_ms: 0,
        };
        let s = local_turn_text("web", &t);
        assert!(
            s.starts_with("[Antenna] Task 0123456789abcdef of the team web, from your team's lead")
        );
        assert!(s.contains("Three bullet points.") && s.ends_with("Reply with your result only."));
        t.state = st::RETURNED.into();
        t.reviews.push(antenna_proto::control::TaskReviewInfo {
            by: "web-lead".into(),
            verdict: "changes".into(),
            comments: "Shorter.".into(),
            at_ms: 0,
        });
        assert!(local_turn_text("web", &t).contains("comments from web-lead:\nShorter."));
    }
}
