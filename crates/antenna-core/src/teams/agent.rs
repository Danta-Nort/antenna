// SPDX-License-Identifier: AGPL-3.0-only
//! The agents' side of teams (D-111, CONTROL §25): what the lead and the workers may call. Every call is decided
//! here, by the daemon: who the caller is (the team's lead, a worker of it, or neither: `not_found`), whether its role
//! has the command (`forbidden` for a worker calling a lead's tool), whose tasks it may read (a worker only its own),
//! and the taint reading carries. Owner commands do not exist here: no tool creates a team, changes a budget or a
//! template, or applies to the project's branch without the owner when the template keeps that for the owner.

use std::sync::{Arc, PoisonError};

use antenna_proto::control::{
    AgentRequest, ApplyResultReq, CapacityInfo, MachineCapacity, Reply, SlotCapacity, TaskDiff,
    TaskNoteReq, code,
};

use super::{Actor, MAX_NOTES, MemberRow, Task, TeamRow, db, git, not_in_team, rules, text_of};
use crate::{
    agents::AgentCtx,
    error::{Error, Result},
    node::Session,
};

/// The caller's place in a team.
enum Member {
    Lead(TeamRow),
    Worker(TeamRow, Box<MemberRow>),
}

impl Member {
    fn team(&self) -> &TeamRow {
        match self {
            Member::Lead(t) | Member::Worker(t, _) => t,
        }
    }
}

fn lead_only(what: &str) -> Error {
    Error::new(code::FORBIDDEN, format!("only the team's lead can {what}"))
}

impl Session {
    fn member_of(&self, agent_id: i64) -> Result<Member> {
        if let Some(m) = self.team_member(agent_id) {
            if m.state == "stopped" {
                return Err(Error::new(code::FORBIDDEN, "this worker was stopped"));
            }
            return Ok(Member::Worker(self.load_team(m.team_id)?, Box::new(m)));
        }
        let led = db::team_led_by(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            agent_id,
        )?;
        led.map(Member::Lead).ok_or_else(not_in_team)
    }

    /// A team command of an agent (`AgentRequest::TeamInfo` … `Capacity`).
    pub(crate) async fn agent_team(
        self: &Arc<Self>,
        ctx: &AgentCtx,
        req: AgentRequest,
    ) -> Result<Reply> {
        let me = self.member_of(ctx.id)?;
        let actor = Actor::Agent {
            id: ctx.id,
            name: ctx.name.clone(),
        };
        let team = me.team().clone();
        match (req, &me) {
            (AgentRequest::TeamInfo(_), _) => self.agent_team_info(&me).await,
            (AgentRequest::TaskList(_), Member::Lead(_)) => {
                let tasks = db::tasks(
                    &self.db.lock().unwrap_or_else(PoisonError::into_inner),
                    team.id,
                )?;
                // Summaries carry no text a worker wrote: listing them taints nothing.
                Ok(Reply::Tasks {
                    tasks: tasks
                        .iter()
                        .map(|t| self.task_info(&team, t, false))
                        .collect(),
                })
            }
            (AgentRequest::TaskList(_), Member::Worker(_, m)) => {
                let tasks: Vec<Task> = db::tasks(
                    &self.db.lock().unwrap_or_else(PoisonError::into_inner),
                    team.id,
                )?
                .into_iter()
                .filter(|t| t.assignee == Some(m.agent_id))
                .collect();
                Ok(Reply::Tasks {
                    tasks: tasks
                        .iter()
                        .map(|t| self.task_info(&team, t, false))
                        .collect(),
                })
            }
            (AgentRequest::TaskGet(r), Member::Lead(_)) => {
                let t = self.load_task(&team, &r.id)?;
                self.read_results(ctx.id, std::slice::from_ref(&t))?;
                Ok(Reply::Task(self.task_info(&team, &t, true)))
            }
            (AgentRequest::TaskGet(r), Member::Worker(_, m)) => {
                let t = self.own_task(&team, m, &r.id)?;
                // Reading the task applies the taint its writer had (already applied when it was assigned).
                self.carry_into(m.agent_id, &t.carried)?;
                Ok(Reply::Task(self.task_info(&team, &t, true)))
            }
            (AgentRequest::TaskCreate(r), Member::Lead(_)) => {
                if r.team.as_deref().is_some_and(|n| n != team.name) {
                    return Err(Error::new(code::NOT_FOUND, "you lead another team"));
                }
                let t = self.task_create_as(&team, &actor, r).await?;
                Ok(Reply::Task(self.task_info(&team, &t, true)))
            }
            (AgentRequest::TaskAssign(r), Member::Lead(_)) => {
                let t = self.task_assign_as(&team, &actor, &r.id, &r.worker).await?;
                Ok(Reply::Task(self.task_info(&team, &t, true)))
            }
            (AgentRequest::TaskReview(r), Member::Lead(_)) => {
                // Only the owner interrupts a worker (PG-58): a lead's review waits for the worker's turn
                if r.urgent {
                    return Err(Error::new(
                        code::FORBIDDEN,
                        "only the owner can interrupt a worker",
                    ));
                }
                let t = self
                    .task_review_as(&team, &actor, &r.id, &r.verdict, &r.comments, false)
                    .await?;
                Ok(Reply::Task(self.task_info(&team, &t, true)))
            }
            (AgentRequest::TaskDiff(r), _) => self.agent_task_diff(&me, ctx.id, &r.id).await,
            (AgentRequest::TaskNote(r), _) => self.agent_task_note(&me, ctx.id, r),
            (AgentRequest::TaskReport(r), Member::Worker(_, m)) => {
                let t = self
                    .task_report_as(&team, m, &r.id, &r.state, &r.summary)
                    .await?;
                Ok(Reply::Task(self.task_info(&team, &t, true)))
            }
            (AgentRequest::TaskReport(_), Member::Lead(_)) => Err(Error::new(
                code::FORBIDDEN,
                "only a task's worker reports on it; the lead reviews it with task_review",
            )),
            (AgentRequest::RunCheck(r), Member::Lead(_)) => {
                let run = self.run_check_as(&team, &actor, &r.id, None).await?;
                let t = self.load_task(&team, &r.id)?;
                self.read_results(ctx.id, std::slice::from_ref(&t))?;
                Ok(Reply::CheckRun(run))
            }
            (AgentRequest::RunCheck(r), Member::Worker(_, m)) => Ok(Reply::CheckRun(
                self.run_check_as(&team, &actor, &r.id, Some(m)).await?,
            )),
            (AgentRequest::ApplyResult(r), Member::Lead(_)) => {
                self.agent_apply(&team, &actor, r).await
            }
            (AgentRequest::WorkerSpawn(r), Member::Lead(_)) => {
                let m = self.worker_spawn_as(&team, &actor, &r.role, r.kind.as_deref())?;
                let tasks = db::tasks(
                    &self.db.lock().unwrap_or_else(PoisonError::into_inner),
                    team.id,
                )?;
                Ok(Reply::TeamWorker(self.worker_info(&team, &m, &tasks)))
            }
            (AgentRequest::WorkerStop(r), Member::Lead(_)) => {
                let m = self.worker_stop_as(&team, &actor, &r.name).await?;
                Ok(Reply::TeamWorker(self.worker_info(&team, &m, &[])))
            }
            (AgentRequest::Capacity(_), Member::Lead(_)) => {
                Ok(Reply::Capacity(self.capacity(&team)?))
            }
            (req, Member::Worker(..)) => Err(lead_only(match req.name() {
                "task_create" => "write tasks",
                "task_assign" => "assign tasks",
                "task_review" => "review tasks",
                "apply_result" => "apply results",
                "worker_spawn" => "create workers",
                "worker_stop" => "stop workers",
                "capacity" => "read the team's capacity",
                other => other,
            })),
            (req, Member::Lead(_)) => Err(Error::bad_request(format!(
                "{} is not a team command",
                req.name()
            ))),
        }
    }

    /// The lead reads results: each one's taint, the worker's when it submitted, applies to the lead (SPEC §9).
    fn read_results(&self, lead: i64, tasks: &[Task]) -> Result<()> {
        for t in tasks
            .iter()
            .filter(|t| t.result.is_some() || t.report.is_some())
        {
            self.carry_into(lead, &t.result_carried)?;
        }
        Ok(())
    }

    async fn agent_team_info(&self, me: &Member) -> Result<Reply> {
        let team = me.team();
        let mut info = self.team_info_now(team, true).await?;
        match me {
            Member::Lead(_) => info.role = Some("lead".into()),
            Member::Worker(_, m) => {
                // A worker sees its own tasks and nobody else's (§3.7 item 3).
                info.role = Some("worker".into());
                info.workers.retain(|w| w.name == m.name);
                let mine = m.name.clone();
                info.tasks
                    .retain(|t| t.assignee.as_deref() == Some(mine.as_str()));
                info.apply_request = None;
            }
        }
        Ok(Reply::Team(info))
    }

    async fn agent_task_diff(&self, me: &Member, agent_id: i64, id: &str) -> Result<Reply> {
        let team = me.team();
        let repo = git::Repo::new(&team.git_dir);
        let (t, folder) = match me {
            Member::Lead(_) => (self.load_task(team, id)?, None),
            Member::Worker(_, m) => (self.own_task(team, m, id)?, Some(m)),
        };
        let base = t
            .result
            .as_ref()
            .map(|r| r.base.clone())
            .or_else(|| t.base.clone())
            .ok_or_else(|| Error::new(code::TASK_STATE, "the task was never assigned"))?;
        let (stat, diff, truncated, commit) = match (folder, &t.result) {
            // A worker sees its folder as it is now.
            (Some(m), _) => {
                let dirs = self.worker_dirs(team, m.agent_id);
                let (s, d, tr) = repo.diff_folder(&base, &dirs.tree, &dirs.index).await?;
                (s, d, tr, None)
            }
            (None, Some(r)) if git::is_oid(&r.commit) => {
                self.carry_into(agent_id, &t.result_carried)?;
                let (s, d, tr) = repo.diff(&base, &r.commit).await?;
                (s, d, tr, Some(r.commit.clone()))
            }
            (None, _) => {
                return Err(Error::new(
                    code::TASK_STATE,
                    format!("the task is {}: no submitted result yet", t.state),
                ));
            }
        };
        Ok(Reply::TaskDiff(TaskDiff {
            task: t.id,
            base,
            commit,
            stat,
            diff,
            truncated,
        }))
    }

    fn agent_task_note(&self, me: &Member, agent_id: i64, r: TaskNoteReq) -> Result<Reply> {
        let team = me.team();
        let mut t = match me {
            Member::Lead(_) => self.load_task(team, &r.id)?,
            Member::Worker(_, m) => self.own_task(team, m, &r.id)?,
        };
        if let Some(text) = r.text {
            if text.len() > MAX_NOTES {
                return Err(Error::new(
                    code::TOO_LARGE,
                    format!("notes are at most {MAX_NOTES} bytes"),
                ));
            }
            t.notes = text_of(&text, MAX_NOTES);
            self.save_task(&mut t)?;
        } else if let Member::Lead(_) = me {
            // The notes of a worker's task are the worker's text.
            self.read_results(agent_id, std::slice::from_ref(&t))?;
        }
        Ok(Reply::Task(self.task_info(team, &t, true)))
    }

    async fn agent_apply(&self, team: &TeamRow, actor: &Actor, r: ApplyResultReq) -> Result<Reply> {
        match (r.id, r.target) {
            (Some(id), false) => {
                let t = self.task_apply_as(team, actor, &id).await?;
                Ok(Reply::Task(self.task_info(team, &t, true)))
            }
            (None, true) if team.cfg.template.apply == "lead" => {
                let team = self.team_apply_as(team, actor, None).await?;
                Ok(Reply::Team(self.team_info_now(&team, false).await?))
            }
            (None, true) => {
                let req = self.team_apply_request(team, actor).await?;
                Err(Error::new(
                    code::APPROVAL_REQUIRED,
                    format!(
                        "applying the team's work ({}) to {} needs the owner: the request waits for them \
                         (`antenna team apply {}`); the daemon tells you when it is done (wait_for_message)",
                        &req.commit[..12],
                        team.target,
                        team.name
                    ),
                ))
            }
            _ => Err(Error::bad_request(
                "apply_result takes either the id of an accepted task or target: true",
            )),
        }
    }

    /// The capacity of this machine for a team, and the own devices that lend themselves to teams: facts only.
    pub(super) fn capacity(&self, team: &TeamRow) -> Result<CapacityInfo> {
        let members = self.load_members(team)?;
        let active: Vec<&MemberRow> = members.iter().filter(|m| m.state != "stopped").collect();
        let machine_workers =
            db::active_workers(&self.db.lock().unwrap_or_else(PoisonError::into_inner))?;
        let support = self.wake_support();
        let local_models: Vec<String> = self
            .local_models()
            .map(|r| {
                r.models
                    .into_iter()
                    .filter(|m| m.state == "ready")
                    .map(|m| m.id)
                    .collect()
            })
            .unwrap_or_default();
        // The owner's other computers that lend themselves to teams ("Lend this computer to my teams", PG-14): listed
        // as facts, every slot unavailable there until remote workers exist
        let lent = self.lending_devices().into_iter().map(|d| MachineCapacity {
            name: format!(
                "{} (own device, {}, {} {}, {} GB)",
                d.contact,
                if d.online { "online" } else { "offline" },
                d.os,
                d.arch,
                d.memory_bytes >> 30
            ),
            sandbox: "remote".into(),
            workers: 0,
            max_workers: 0,
            slots: team
                .cfg
                .slots
                .iter()
                .map(|s| SlotCapacity {
                    role: s.role.clone(),
                    kind: s.kind.clone(),
                    used: 0,
                    max: s.max,
                    unavailable: Some("workers on another own computer are not built yet".into()),
                })
                .collect(),
            local_models: Vec::new(),
        });
        let mut machines = vec![MachineCapacity {
            name: "this computer".into(),
            sandbox: support.kind.map_or("none", |k| k.as_str()).into(),
            workers: machine_workers,
            max_workers: rules::THIS_COMPUTER.max_workers,
            slots: team
                .cfg
                .slots
                .iter()
                .enumerate()
                .map(|(i, s)| SlotCapacity {
                    role: s.role.clone(),
                    kind: s.kind.clone(),
                    used: active.iter().filter(|m| m.spec.slot == i).count() as u32,
                    max: s.max,
                    unavailable: self.slot_unavailable(team, s),
                })
                .collect(),
            local_models,
        }];
        machines.extend(lent);
        Ok(CapacityInfo {
            team: team.name.clone(),
            workers: active.len() as u32,
            max_workers: team.cfg.max_workers,
            machines,
        })
    }
}
