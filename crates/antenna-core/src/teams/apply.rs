// SPDX-License-Identifier: AGPL-3.0-only
//! Applying a team's results (D-111): an accepted task into the integration branch, the integration branch into the
//! project's branch (the owner's approval unless the template says the lead may), and the lead's request for it.

use std::sync::PoisonError;

use antenna_proto::control::{ApplyRequest, code};

use super::{Actor, Task, TeamRow, db, git, rules, tasks::task_state_err};
use crate::{
    error::{Error, Result},
    node::Session,
    now_ms,
};

impl Session {
    /// Merge an accepted result into the integration branch (the lead's `apply_result`, the owner's `task_apply`).
    pub(super) async fn task_apply_as(&self, team: &TeamRow, by: &Actor, id: &str) -> Result<Task> {
        Self::require_active(team)?;
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let mut t = self.load_task(team, id)?;
        let next = rules::next_state(&t.state, rules::Op::Apply).map_err(task_state_err)?;
        let result = t
            .result
            .clone()
            .ok_or_else(|| task_state_err("the task has no result".into()))?;
        let detail;
        if git::is_oid(&result.commit) {
            let repo = git::Repo::new(&team.git_dir);
            let merged = repo
                .merge_into(
                    &team.integration,
                    &result.commit,
                    &format!("Merge task {}: {}\n", t.id, t.title),
                )
                .await?;
            detail = format!("{} {}", merged.how, &merged.commit[..12]);
            t.applied = Some(merged.commit);
            repo.delete_branch(&result.branch).await?;
        } else {
            // A text-only result (a local model's): accepted text, nothing to merge.
            detail = "a text result: nothing to merge".into();
        }
        t.state = next.into();
        self.save_task(&mut t)?;
        self.log_task(team, by, "apply_result", &t, "done", &detail);
        self.tell(team, &t, "applied", true);
        Ok(t)
    }

    /// Merge the integration branch into the project's branch (the owner's `team_apply`; the lead's `apply_result
    /// {target}` when the template says `apply: lead`). With `seen`, only if the integration branch is still at the
    /// commit the approver saw. A branch checked out in a working folder moves there as `git merge --ff-only` would
    /// move it, so the owner's local changes stay or the apply refuses.
    pub(super) async fn team_apply_as(
        &self,
        team: &TeamRow,
        by: &Actor,
        seen: Option<&str>,
    ) -> Result<TeamRow> {
        Self::require_active(team)?;
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let repo = git::Repo::new(&team.git_dir);
        let tip = repo
            .branch_tip(&team.integration)
            .await?
            .ok_or_else(|| Error::new(code::NOT_FOUND, "the integration branch is gone"))?;
        if let Some(s) = seen
            && !tip.starts_with(&s.to_ascii_lowercase())
        {
            return Err(Error::new(
                code::APPROVAL_MISMATCH,
                format!(
                    "the integration branch moved to {} since {s}: review it again",
                    &tip[..12]
                ),
            ));
        }
        let target_tip = repo
            .branch_tip(&team.target)
            .await?
            .ok_or_else(|| Error::new(code::NOT_FOUND, format!("no branch {}", team.target)))?;
        let merged = repo
            .merge_commit(
                &target_tip,
                &tip,
                &format!("Merge the team {} ({})\n", team.name, team.integration),
            )
            .await?;
        if merged.commit != target_tip {
            match repo.checked_out_at(&team.target).await? {
                Some(tree) => repo.fast_forward_in(&tree, &merged.commit).await?,
                None => {
                    repo.set_branch(&team.target, &merged.commit, Some(&target_tip))
                        .await?
                }
            }
        }
        let mut team = self.load_team(team.id)?;
        let had_request = team.apply_request.take().is_some();
        db::team_save(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            &team,
        )?;
        self.team_log(
            team.id,
            &db::Entry {
                actor: by.name(),
                action: "team_apply",
                task: None,
                decision: "done",
                detail: &format!(
                    "{} {} into {}",
                    merged.how,
                    &merged.commit[..12],
                    team.target
                ),
            },
        );
        self.team_event(&team.name, "changed", None, by.name());
        if had_request && let Some(lead) = team.lead_id {
            let fact_task = Task {
                id: String::new(),
                state: "applied".into(),
                ..placeholder_task()
            };
            self.team_fact(lead, &team.name, &fact_task, "apply_approved", None);
        }
        Ok(team)
    }

    /// The lead asks the owner to apply the integration branch: the request waits in `team_show` (and as a `team`
    /// event) until the owner applies it with `team_apply`.
    pub(super) async fn team_apply_request(
        &self,
        team: &TeamRow,
        by: &Actor,
    ) -> Result<ApplyRequest> {
        Self::require_active(team)?;
        let tip = git::Repo::new(&team.git_dir)
            .branch_tip(&team.integration)
            .await?
            .ok_or_else(|| Error::new(code::NOT_FOUND, "the integration branch is gone"))?;
        let req = ApplyRequest {
            by: by.name().into(),
            commit: tip,
            at_ms: now_ms(),
        };
        let mut team = self.load_team(team.id)?;
        team.apply_request = Some(req.clone());
        db::team_save(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            &team,
        )?;
        self.team_log(
            team.id,
            &db::Entry {
                actor: by.name(),
                action: "apply_result",
                task: None,
                decision: "approval_required",
                detail: &format!("{} into {}", &req.commit[..12], team.target),
            },
        );
        self.team_event(&team.name, "apply_request", None, by.name());
        Ok(req)
    }
}

/// A task record with nothing in it, for facts about the team rather than a task.
fn placeholder_task() -> Task {
    Task {
        id: String::new(),
        title: String::new(),
        brief: String::new(),
        check: Vec::new(),
        assignee: None,
        state: String::new(),
        created_by: String::new(),
        carried: Vec::new(),
        round: 0,
        notes: String::new(),
        reviews: Vec::new(),
        report: None,
        result: None,
        result_carried: Vec::new(),
        result_text: None,
        check_run: None,
        applied: None,
        tokens: 0,
        auto_returns: 0,
        reminded_round: 0,
        base: None,
        created_ms: 0,
        updated_ms: 0,
    }
}
