// SPDX-License-Identifier: AGPL-3.0-only
//! The wire views of teams, workers and tasks (D-111, CONTROL §25): what the owner and the members read. Summaries
//! leave out every text a worker or a check wrote (reports, notes, check output); the full view has them, and the
//! callers that hand it to an agent apply the taint it carries.

use std::sync::PoisonError;

use antenna_proto::control::{TaskInfo, TaskReportInfo, TeamInfo, WorkerInfo};

use super::{MemberRow, Task, TeamRow, db, git, rules};
use crate::{error::Result, node::Session};

impl Session {
    /// The wire view of a task; `full` adds notes, reviews, the report and the check output.
    pub(super) fn task_info(&self, team: &TeamRow, t: &Task, full: bool) -> TaskInfo {
        let assignee = t.assignee.and_then(|id| self.agent_name(id));
        TaskInfo {
            id: t.id.clone(),
            team: team.name.clone(),
            title: t.title.clone(),
            brief: if full { t.brief.clone() } else { String::new() },
            check: t.check.clone(),
            assignee,
            state: t.state.clone(),
            created_by: t.created_by.clone(),
            ceiling: self.ceiling_of(&t.carried),
            round: t.round,
            notes: if full { t.notes.clone() } else { String::new() },
            reviews: if full { t.reviews.clone() } else { Vec::new() },
            report: if full {
                t.report.clone()
            } else {
                t.report.as_ref().map(|r| TaskReportInfo {
                    summary: String::new(),
                    ..r.clone()
                })
            },
            result: t.result.clone().map(|mut r| {
                r.ceiling = self.ceiling_of(&t.result_carried);
                r
            }),
            check_run: t.check_run.clone().map(|mut c| {
                if !full {
                    c.output.clear();
                }
                c
            }),
            applied: t.applied.clone(),
            tokens: t.tokens,
            created_ms: t.created_ms,
            updated_ms: t.updated_ms,
        }
    }

    /// The wire view of a worker.
    pub(super) fn worker_info(&self, team: &TeamRow, m: &MemberRow, tasks: &[Task]) -> WorkerInfo {
        let task = tasks
            .iter()
            .find(|t| t.assignee == Some(m.agent_id) && rules::holds_worker(&t.state))
            .map(|t| t.id.clone());
        let state = if m.state == "stopped" {
            "stopped".to_string()
        } else {
            self.worker_state(m)
        };
        WorkerInfo {
            name: m.name.clone(),
            team: team.name.clone(),
            role: m.role.clone(),
            kind: m.kind.clone(),
            model: m.spec.model.clone(),
            machine: "this computer".into(),
            state,
            task,
            spawned_by: m.spawned_by.clone(),
            ceiling: self.agent_ceiling(m.agent_id),
            turns: m.spec.turns,
            queued: self.worker_queued(m),
            input_tokens: m.spec.input_tokens,
            output_tokens: m.spec.output_tokens,
            detail: m.spec.detail.clone(),
            created_ms: m.created_ms,
        }
    }

    /// The wire view of a team; `tasks` adds the task summaries.
    pub(super) fn team_info(&self, team: &TeamRow, with_tasks: bool) -> Result<TeamInfo> {
        let (members, tasks) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            (db::members(&db, team.id)?, db::tasks(&db, team.id)?)
        };
        Ok(TeamInfo {
            name: team.name.clone(),
            project: team.project.to_string_lossy().into_owned(),
            target: team.target.clone(),
            integration: team.integration.clone(),
            integration_commit: None,
            lead: team.lead_id.and_then(|id| self.agent_name(id)),
            state: team.state.clone(),
            slots: team.cfg.slots.clone(),
            max_workers: team.cfg.max_workers,
            template: team.cfg.template.clone(),
            workers: members
                .iter()
                .map(|m| self.worker_info(team, m, &tasks))
                .collect(),
            tasks: if with_tasks {
                tasks
                    .iter()
                    .map(|t| self.task_info(team, t, false))
                    .collect()
            } else {
                Vec::new()
            },
            apply_request: team.apply_request.clone(),
            role: None,
            created_ms: team.created_ms,
        })
    }

    /// [`Self::team_info`] with the integration branch's commit.
    pub(super) async fn team_info_now(&self, team: &TeamRow, with_tasks: bool) -> Result<TeamInfo> {
        let mut info = self.team_info(team, with_tasks)?;
        info.integration_commit = git::Repo::new(&team.git_dir)
            .branch_tip(&team.integration)
            .await
            .ok()
            .flatten();
        Ok(info)
    }
}
