// SPDX-License-Identifier: AGPL-3.0-only
//! The flows of a team that the owner and the lead share (D-111): spawning and stopping workers, writing, assigning,
//! reporting, checking, reviewing and applying tasks. The callers (`owner.rs`, `agent.rs`) decide who may call what;
//! here every flow keeps the rules that hold whoever calls: the state machine, the budget, the taint a task carries,
//! one change of a team at a time.

use std::sync::{Arc, PoisonError};

use antenna_proto::control::{
    CheckRun, TaskNew, TaskReportInfo, TaskResult, TaskReviewInfo, code, task_state as st,
};

use super::{
    Actor, Carried, MAX_BRIEF, MAX_OPEN_TASKS, MAX_REPORT, MAX_TITLE, MemberRow, Task, TeamRow,
    check, db, git, merge_carried, new_task_id, one_line, rules, text_of, worker,
};
use crate::{
    error::{Error, Result},
    node::Session,
    now_ms,
};

/// How the daemon's comments quote a failed check's output.
const CHECK_QUOTE: usize = 4 * 1024;

pub(super) fn task_state_err(e: String) -> Error {
    Error::new(code::TASK_STATE, e)
}

impl Session {
    pub(super) fn log_task(
        &self,
        team: &TeamRow,
        by: &Actor,
        action: &str,
        t: &Task,
        decision: &str,
        detail: &str,
    ) {
        self.team_log(
            team.id,
            &db::Entry {
                actor: by.name(),
                action,
                task: Some(&t.id),
                decision,
                detail,
            },
        );
        self.team_event(&team.name, "task", Some(t), by.name());
    }

    /// A fact for the team's lead (an agent) and, when given, for the task's worker.
    pub(super) fn tell(&self, team: &TeamRow, t: &Task, change: &str, worker_too: bool) {
        let assignee = t.assignee.and_then(|id| self.agent_name(id));
        if let Some(lead) = team.lead_id {
            self.team_fact(lead, &team.name, t, change, assignee.clone());
        }
        if worker_too && let Some(w) = t.assignee {
            self.team_fact(w, &team.name, t, change, assignee);
        }
    }

    pub(super) fn require_active(team: &TeamRow) -> Result<()> {
        if team.state != "active" {
            return Err(Error::new(
                code::FORBIDDEN,
                format!("the team {} is stopped", team.name),
            ));
        }
        Ok(())
    }

    /// Write a task. It carries the writer's taint: a worker that reads it is capped by it.
    pub(super) async fn task_create_as(
        self: &Arc<Self>,
        team: &TeamRow,
        by: &Actor,
        req: TaskNew,
    ) -> Result<Task> {
        Self::require_active(team)?;
        let title = one_line(&req.title, MAX_TITLE);
        if title.is_empty() {
            return Err(Error::bad_request("a task needs a title"));
        }
        if !req.check.is_empty() && !team.cfg.template.checks.contains(&req.check) {
            return Err(Error::bad_request(format!(
                "{:?} is not one of the team's check commands ({})",
                req.check.join(" "),
                team.cfg
                    .template
                    .checks
                    .iter()
                    .map(|c| format!("`{}`", c.join(" ")))
                    .collect::<Vec<_>>()
                    .join(", ")
            )));
        }
        let open = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db::tasks(&db, team.id)?
                .iter()
                .filter(|t| !rules::is_final(&t.state))
                .count()
        };
        if open >= MAX_OPEN_TASKS {
            return Err(Error::new(
                code::TOO_LARGE,
                format!("the team has {open} unfinished tasks; at most {MAX_OPEN_TASKS}"),
            ));
        }
        let carried: Vec<Carried> = match by {
            Actor::Agent { id, .. } => self.carried_now(*id)?,
            _ => Vec::new(),
        };
        let now = now_ms();
        let t = Task {
            id: new_task_id(),
            title,
            brief: text_of(&req.brief, MAX_BRIEF),
            check: req.check,
            assignee: None,
            state: st::OPEN.into(),
            created_by: by.name().into(),
            carried,
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
            created_ms: now,
            updated_ms: now,
        };
        db::task_insert(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
            &t,
        )?;
        let ceiling = self.ceiling_of(&t.carried);
        self.log_task(
            team,
            by,
            "task_create",
            &t,
            "done",
            &format!(
                "ceiling {}",
                ceiling.map_or("none".to_string(), |c| c.to_string())
            ),
        );
        match req.assignee {
            Some(w) => self.task_assign_as(team, by, &t.id, &w).await,
            None => Ok(t),
        }
    }

    /// Give a task to a worker: a fresh checkout for a new worker, the task's taint applied to the worker, and a
    /// turn that names the task.
    pub(super) async fn task_assign_as(
        self: &Arc<Self>,
        team: &TeamRow,
        by: &Actor,
        id: &str,
        worker_name: &str,
    ) -> Result<Task> {
        Self::require_active(team)?;
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let mut t = self.load_task(team, id)?;
        let members = self.load_members(team)?;
        let m = members
            .iter()
            .find(|m| m.name == worker_name && m.state != "stopped")
            .ok_or_else(|| {
                Error::new(
                    code::NOT_FOUND,
                    format!("no active worker {worker_name:?} in this team"),
                )
            })?;
        let tasks = db::tasks(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
        )?;
        if let Some(other) = tasks.iter().find(|o| {
            o.id != t.id && o.assignee == Some(m.agent_id) && rules::holds_worker(&o.state)
        }) {
            return Err(task_state_err(format!(
                "{worker_name} works on task {} ({}); a worker takes one task at a time",
                other.id, other.state
            )));
        }
        let next = rules::next_state(&t.state, rules::Op::Assign).map_err(task_state_err)?;
        let new_worker = t.assignee != Some(m.agent_id);
        if new_worker && let Some(prev) = t.assignee {
            self.worker_interrupt(prev);
        }
        if new_worker && m.kind != "local" {
            // A new worker starts from the task's result so far, or from the integration branch.
            let repo = git::Repo::new(&team.git_dir);
            let base = match t
                .result
                .as_ref()
                .map(|r| r.commit.clone())
                .filter(|c| git::is_oid(c))
            {
                Some(c) => c,
                None => repo.branch_tip(&team.integration).await?.ok_or_else(|| {
                    Error::new(
                        code::NOT_FOUND,
                        format!("the integration branch {} is gone", team.integration),
                    )
                })?,
            };
            let dirs = self.worker_dirs(team, m.agent_id);
            git::mkdir_private(&dirs.root)?;
            repo.checkout(&base, &dirs.tree, &dirs.index).await?;
            t.base = Some(base);
        } else if t.base.is_none() {
            t.base = git::Repo::new(&team.git_dir)
                .branch_tip(&team.integration)
                .await?;
        }
        t.assignee = Some(m.agent_id);
        t.state = next.into();
        t.round = t.round.saturating_add(1).max(1);
        t.auto_returns = 0;
        // The worker reads the task: its taint now.
        self.carry_into(m.agent_id, &t.carried)?;
        self.save_task(&mut t)?;
        self.log_task(team, by, "task_assign", &t, "done", worker_name);
        self.tell(team, &t, "assigned", true);
        self.worker_turn(
            m.agent_id,
            worker::assign_text(&team.name, &m.name, &t),
            Some(t.id.clone()),
        );
        Ok(t)
    }

    /// A worker's report on its own task. `submitted` records its folder as a commit on `team/<task>` and starts
    /// the task's check.
    pub(super) async fn task_report_as(
        self: &Arc<Self>,
        team: &TeamRow,
        m: &MemberRow,
        id: &str,
        state: &str,
        summary: &str,
    ) -> Result<Task> {
        Self::require_active(team)?;
        let op = match state {
            st::WORKING => rules::Op::Working,
            st::BLOCKED => rules::Op::Blocked,
            st::SUBMITTED => rules::Op::Submit,
            _ => {
                return Err(Error::bad_request(
                    "a report's state is working, blocked or submitted",
                ));
            }
        };
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let mut t = self.own_task(team, m, id)?;
        let next = rules::next_state(&t.state, op).map_err(task_state_err)?;
        let summary = text_of(summary, MAX_REPORT);
        if op == rules::Op::Submit && m.kind != "local" {
            let base = t
                .base
                .clone()
                .ok_or_else(|| Error::internal("the task has no base commit"))?;
            let dirs = self.worker_dirs(team, m.agent_id);
            let repo = git::Repo::new(&team.git_dir);
            let email = format!("{}@antenna.invalid", m.name);
            let snap = repo
                .snapshot(
                    &dirs.tree,
                    &dirs.index,
                    &base,
                    &format!(
                        "{}\n\nTask {} of the team {}, by {}.\n",
                        t.title, t.id, team.name, m.name
                    ),
                    &git::Author {
                        name: &m.name,
                        email: &email,
                    },
                )
                .await?;
            let branch = format!("team/{}", t.id);
            let old = repo.branch_tip(&branch).await?;
            repo.set_branch(&branch, &snap.commit, old.as_deref())
                .await?;
            t.result = Some(TaskResult {
                branch,
                base,
                commit: snap.commit,
                files: snap.files,
                insertions: snap.insertions,
                deletions: snap.deletions,
                ceiling: None,
                at_ms: now_ms(),
            });
            t.result_carried = self.carried_now(m.agent_id)?;
            t.check_run = None;
        }
        t.state = next.into();
        t.report = Some(TaskReportInfo {
            by: m.name.clone(),
            state: state.into(),
            summary,
            at_ms: now_ms(),
        });
        self.save_task(&mut t)?;
        let detail = t
            .result
            .as_ref()
            .filter(|_| op == rules::Op::Submit)
            .map(|r| {
                format!(
                    "{} ({} files, +{} -{})",
                    &r.commit[..12.min(r.commit.len())],
                    r.files,
                    r.insertions,
                    r.deletions
                )
            })
            .unwrap_or_default();
        self.log_task(
            team,
            &Actor::Agent {
                id: m.agent_id,
                name: m.name.clone(),
            },
            "task_report",
            &t,
            state,
            &detail,
        );
        if op != rules::Op::Working {
            self.tell(team, &t, state, false);
        }
        if op == rules::Op::Submit && !t.check.is_empty() && t.result_text.is_none() {
            let s = self.clone();
            let (team_id, task_id) = (team.id, t.id.clone());
            tokio::spawn(async move { s.auto_check(team_id, task_id).await });
        }
        Ok(t)
    }

    /// A local model's reply is its result (it has no tools yet, D-104): recorded as a text-only submission.
    pub(super) async fn task_text_result(
        self: &Arc<Self>,
        team: &TeamRow,
        m: &MemberRow,
        id: &str,
        text: &str,
    ) -> Result<Task> {
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let mut t = self.own_task(team, m, id)?;
        let next = rules::next_state(&t.state, rules::Op::Submit).map_err(task_state_err)?;
        let text = text_of(text, MAX_REPORT);
        t.result = Some(TaskResult {
            branch: String::new(),
            base: t.base.clone().unwrap_or_default(),
            commit: String::new(),
            files: 0,
            insertions: 0,
            deletions: 0,
            ceiling: None,
            at_ms: now_ms(),
        });
        t.result_text = Some(text.clone());
        t.result_carried = merge_carried(&t.carried, &self.carried_now(m.agent_id)?);
        t.state = next.into();
        t.report = Some(TaskReportInfo {
            by: m.name.clone(),
            state: st::SUBMITTED.into(),
            summary: text,
            at_ms: now_ms(),
        });
        self.save_task(&mut t)?;
        self.log_task(
            team,
            &Actor::Agent {
                id: m.agent_id,
                name: m.name.clone(),
            },
            "task_report",
            &t,
            st::SUBMITTED,
            "a text result of a local model",
        );
        self.tell(team, &t, st::SUBMITTED, false);
        Ok(t)
    }

    /// The worker's own task, or `not_found` (a worker learns nothing of other workers' tasks).
    pub(super) fn own_task(&self, team: &TeamRow, m: &MemberRow, id: &str) -> Result<Task> {
        match self.load_task(team, id) {
            Ok(t) if t.assignee == Some(m.agent_id) => Ok(t),
            _ => Err(Error::new(
                code::NOT_FOUND,
                format!("no task {id} assigned to you"),
            )),
        }
    }

    /// The check of a submitted result, by the daemon: a failure sends the task back to its worker with the output,
    /// up to the template's `check_retries` times; then the lead decides (§3.3 item 3).
    async fn auto_check(self: Arc<Self>, team_id: i64, task_id: String) {
        let Ok(team) = self.load_team(team_id) else {
            return;
        };
        let run = match self
            .run_check_as(&team, &Actor::Daemon, &task_id, None)
            .await
        {
            Ok(r) => r,
            Err(e) => {
                tracing::info!("team {}: check of {task_id}: {}", team.name, e.message);
                return;
            }
        };
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let Ok(mut t) = self.load_task(&team, &task_id) else {
            return;
        };
        if t.state != st::SUBMITTED
            || t.result.as_ref().map(|r| r.commit.as_str()) != run.commit.as_deref()
        {
            return;
        }
        let failed = matches!(run.outcome.as_str(), "failed" | "timeout");
        if failed && t.auto_returns < team.cfg.template.check_retries {
            let Ok(next) = rules::next_state(&t.state, rules::Op::CheckFailed) else {
                return;
            };
            t.state = next.into();
            t.auto_returns += 1;
            t.round = t.round.saturating_add(1);
            let mut quote = run.output.clone();
            if quote.len() > CHECK_QUOTE {
                let mut cut = quote.len() - CHECK_QUOTE;
                while !quote.is_char_boundary(cut) {
                    cut += 1;
                }
                quote = quote[cut..].to_string();
            }
            t.reviews.push(TaskReviewInfo {
                by: "daemon".into(),
                verdict: "changes".into(),
                comments: format!(
                    "The check `{}` {} (exit {}). Its output ends with:\n{quote}",
                    run.argv.join(" "),
                    run.outcome,
                    run.exit_code.map_or("none".into(), |c| c.to_string())
                ),
                at_ms: now_ms(),
            });
            if self.save_task(&mut t).is_err() {
                return;
            }
            self.log_task(
                &team,
                &Actor::Daemon,
                "task_review",
                &t,
                "changes",
                "the check failed",
            );
            self.tell(&team, &t, "returned", true);
            if let Some(w) = t.assignee {
                self.worker_turn(
                    w,
                    worker::return_text(&team.name, &t, "its check failed"),
                    Some(t.id.clone()),
                );
            }
        } else {
            self.tell(&team, &t, "checked", false);
        }
    }

    /// Run a task's check. A worker (`worker: Some`) checks its own folder; the lead, the owner and the daemon check
    /// the submitted result in a fresh checkout. Refused unless the command is the template's and nothing involved
    /// carries a ceiling below 4.
    pub(super) async fn run_check_as(
        &self,
        team: &TeamRow,
        by: &Actor,
        id: &str,
        worker: Option<&MemberRow>,
    ) -> Result<CheckRun> {
        Self::require_active(team)?;
        let t = match worker {
            Some(m) => self.own_task(team, m, id)?,
            None => self.load_task(team, id)?,
        };
        if t.check.is_empty() {
            return Err(Error::bad_request("the task has no check command"));
        }
        let caller = match by {
            Actor::Agent { id, .. } => self.agent_ceiling(*id),
            _ => None,
        };
        let result_ceiling = if worker.is_some() {
            None
        } else {
            self.ceiling_of(&t.result_carried)
        };
        let ceilings = [caller, self.ceiling_of(&t.carried), result_ceiling];
        if let Err(why) = rules::check_allowed(&team.cfg.template, &t.check, &ceilings) {
            self.log_task(team, by, "run_check", &t, "denied", &why);
            return Err(Error::new(
                code::DENIED,
                format!("the check does not run: {why}"),
            ));
        }
        let grant = rules::grant(&team.cfg.template, None, &rules::THIS_COMPUTER);
        let (tree, commit, dirs) = match worker {
            Some(m) => (
                self.worker_dirs(team, m.agent_id).tree,
                None,
                self.check_dirs(team, &format!("{}-w", t.id)),
            ),
            None => {
                let commit = t
                    .result
                    .as_ref()
                    .map(|r| r.commit.clone())
                    .filter(|c| git::is_oid(c))
                    .ok_or_else(|| {
                        task_state_err(format!(
                            "the task is {}: it has no submitted result to check",
                            t.state
                        ))
                    })?;
                let dirs = self.check_dirs(team, &t.id);
                git::mkdir_private(&dirs.root)?;
                git::Repo::new(&team.git_dir)
                    .checkout(&commit, &dirs.tree, &dirs.index)
                    .await?;
                (dirs.tree.clone(), Some(commit), dirs)
            }
        };
        git::mkdir_private(&dirs.root)?;
        let run = self
            .run_check_in(check::CheckReq {
                team,
                task: &t,
                tree,
                commit,
                by: by.name().into(),
                dirs,
                secs: grant.check_secs,
            })
            .await;
        // Recorded on the task (the lock is taken only now: a check can run for minutes).
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        if let Ok(mut fresh) = self.load_task(team, &t.id) {
            fresh.check_run = Some(run.clone());
            let _ = self.save_task(&mut fresh);
            self.log_task(
                team,
                by,
                "run_check",
                &fresh,
                &run.outcome,
                &format!(
                    "`{}` exit {} in {} ms{}",
                    run.argv.join(" "),
                    run.exit_code.map_or("none".into(), |c| c.to_string()),
                    run.duration_ms,
                    if run.blocked_hosts.is_empty() {
                        String::new()
                    } else {
                        format!("; proxy refused {}", run.blocked_hosts.join(", "))
                    }
                ),
            );
        }
        Ok(run)
    }

    /// The reviewer's decision (the lead's or the owner's `task_review`).
    pub(super) async fn task_review_as(
        self: &Arc<Self>,
        team: &TeamRow,
        by: &Actor,
        id: &str,
        verdict: &str,
        comments: &str,
        urgent: bool,
    ) -> Result<Task> {
        Self::require_active(team)?;
        let op = match (verdict, urgent) {
            ("accept", false) => rules::Op::Accept,
            ("changes", false) => rules::Op::Changes,
            // The owner's "interrupt the worker now" (PG-58); only the owner, checked by the callers
            ("changes", true) => rules::Op::Redirect,
            ("cancel", false) => rules::Op::Cancel,
            (_, true) => {
                return Err(Error::bad_request(
                    "urgent goes only with the verdict changes",
                ));
            }
            _ => {
                return Err(Error::bad_request(
                    "the verdict is accept, changes or cancel",
                ));
            }
        };
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let mut t = self.load_task(team, id)?;
        let was = t.state.clone();
        let next = rules::next_state(&t.state, op).map_err(task_state_err)?;
        t.state = next.into();
        t.reviews.push(TaskReviewInfo {
            by: by.name().into(),
            verdict: verdict.into(),
            comments: text_of(comments, MAX_REPORT),
            at_ms: now_ms(),
        });
        if matches!(op, rules::Op::Changes | rules::Op::Redirect) {
            t.round = t.round.saturating_add(1);
            t.auto_returns = 0;
        }
        self.save_task(&mut t)?;
        self.log_task(team, by, "task_review", &t, verdict, "");
        let change = match (op, was.as_str()) {
            (rules::Op::Changes, st::BLOCKED) => "answered",
            (rules::Op::Changes | rules::Op::Redirect, _) => "returned",
            (rules::Op::Accept, _) => "accepted",
            _ => "cancelled",
        };
        self.tell(team, &t, change, true);
        if let Some(w) = t.assignee {
            match op {
                rules::Op::Changes => {
                    let why = if was == st::BLOCKED {
                        "your lead answered your question"
                    } else {
                        "your reviewer asked for changes"
                    };
                    self.worker_turn(
                        w,
                        worker::return_text(&team.name, &t, why),
                        Some(t.id.clone()),
                    );
                }
                rules::Op::Redirect => {
                    // The turn in progress ends now (its queued turns were for the old instructions), then the
                    // worker's next turn is this task with the owner's comments
                    self.worker_interrupt(w);
                    self.worker_turn(
                        w,
                        worker::return_text(
                            &team.name,
                            &t,
                            "your owner interrupted your turn with urgent changes",
                        ),
                        Some(t.id.clone()),
                    );
                }
                rules::Op::Cancel if rules::holds_worker(&was) => {
                    self.worker_interrupt(w);
                    self.worker_turn(w, worker::cancel_text(&team.name, &t), None);
                }
                _ => {}
            }
        }
        Ok(t)
    }

    /// A worker's turn ended while its task is still assigned, working or returned: the first time in a round the
    /// worker gets a reminder (the turn text returned here); the second time the task goes to the lead as blocked.
    pub(crate) async fn team_turn_ended(
        &self,
        team: &TeamRow,
        id: &str,
        agent_id: i64,
    ) -> Option<String> {
        let lock = self.team_lock(team.id);
        let g = lock.lock().await;
        let mut t = self.load_task(team, id).ok()?;
        if t.assignee != Some(agent_id)
            || !matches!(t.state.as_str(), st::ASSIGNED | st::WORKING | st::RETURNED)
        {
            return None;
        }
        if t.reminded_round != t.round {
            t.reminded_round = t.round;
            let _ = self.save_task(&mut t);
            return Some(worker::remind_text(&team.name, &t));
        }
        drop(g);
        self.team_daemon_block(
            team,
            id,
            "the worker ended two turns without reporting on its task",
        )
        .await;
        None
    }

    /// The daemon hands a task back to the lead as blocked (a worker that keeps failing, a token limit).
    pub(crate) async fn team_daemon_block(&self, team: &TeamRow, id: &str, why: &str) {
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let Ok(mut t) = self.load_task(team, id) else {
            return;
        };
        let Ok(next) = rules::next_state(&t.state, rules::Op::Blocked) else {
            return;
        };
        t.state = next.into();
        t.report = Some(TaskReportInfo {
            by: "daemon".into(),
            state: st::BLOCKED.into(),
            summary: why.into(),
            at_ms: now_ms(),
        });
        if self.save_task(&mut t).is_ok() {
            self.log_task(team, &Actor::Daemon, "task_report", &t, st::BLOCKED, why);
            self.tell(team, &t, st::BLOCKED, false);
        }
    }

    /// Count a turn's tokens against its task; over the template's limit the worker stops and the task goes to the
    /// lead.
    pub(crate) async fn team_task_tokens(&self, team: &TeamRow, id: &str, tokens: u64) {
        let over = {
            let lock = self.team_lock(team.id);
            let _g = lock.lock().await;
            let Ok(mut t) = self.load_task(team, id) else {
                return;
            };
            t.tokens = t.tokens.saturating_add(tokens);
            let _ = self.save_task(&mut t);
            let max = team.cfg.template.max_task_tokens;
            (max > 0 && t.tokens > max && rules::holds_worker(&t.state) && t.state != st::SUBMITTED)
                .then_some((t.assignee, t.tokens, max))
        };
        if let Some((assignee, used, max)) = over {
            if let Some(w) = assignee {
                self.worker_stop_process(w);
            }
            self.team_daemon_block(
                team,
                id,
                &format!("the task used {used} tokens, over its limit of {max}"),
            )
            .await;
        }
    }
}
