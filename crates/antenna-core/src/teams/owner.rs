// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's side of teams (D-111, CONTROL §25): creating a team and changing its budget or template (with the
//! password: the budget lets the lead create agents), listing and showing, adding and stopping workers, removing a
//! team, applying the integration branch to the project's branch (the approval the template keeps for the owner,
//! with the password), the team's capacity, and the owner's own tasks, assignments and reviews. None of these exist for
//! an agent (the lead's `task_assign` and `capacity` are its own commands, `agent.rs`).

use std::sync::{Arc, PoisonError};

use antenna_proto::control::{
    CapacityInfo, TaskDiff, TaskInfo, TaskNew, TeamApply, TeamCreate, TeamInfo, TeamLogEntry,
    TeamSet, TeamSlot, TeamStop, TeamTemplate, WorkerInfo, code,
};

use super::{Actor, TeamCfg, TeamRow, check, db, git, rules, valid_role, valid_team_name};
use crate::{
    error::{Error, Result},
    node::Session,
    now_ms,
};

/// The most slots and workers a team may have.
const MAX_SLOTS: usize = 16;
const MAX_TEAM_WORKERS: u32 = 32;

impl Session {
    /// Validate a budget: kinds, sizes, commands (no flag that removes the agent's permission checks, D-67), hosts,
    /// local models and the roles their class takes.
    fn validate_slots(&self, slots: &[TeamSlot], template: &TeamTemplate) -> Result<()> {
        if slots.len() > MAX_SLOTS {
            return Err(Error::bad_request(format!("at most {MAX_SLOTS} slots")));
        }
        for s in slots {
            valid_role(&s.role)?;
            if s.max == 0 || s.max > MAX_TEAM_WORKERS {
                return Err(Error::bad_request(format!(
                    "a slot holds 1..{MAX_TEAM_WORKERS} workers"
                )));
            }
            match s.kind.as_str() {
                "claude" | "program" | "codex" => {
                    if template.local_only {
                        return Err(Error::bad_request(format!(
                            "the team is local only: a {} worker would send what it reads to its provider",
                            s.kind
                        )));
                    }
                    if s.kind == "program" && s.argv.is_empty() {
                        return Err(Error::bad_request(
                            "a program slot needs its command (it must speak Claude Code's stream-json)",
                        ));
                    }
                    if s.argv.len() > 32
                        || s.argv.iter().any(|a| a.len() > 4096 || a.contains('\0'))
                    {
                        return Err(Error::bad_request(
                            "a worker command has at most 32 arguments of at most 4096 bytes",
                        ));
                    }
                    let mut prev: Option<&str> = None;
                    for a in &s.argv {
                        if let Some(why) = crate::wake::forbidden_arg(a, prev) {
                            return Err(Error::new(code::DENIED, format!("{a:?}: {why}")));
                        }
                        prev = Some(a);
                    }
                    if s.model.is_some() {
                        return Err(Error::bad_request("only a local slot names a model"));
                    }
                }
                "local" => {
                    let model = s
                        .model
                        .as_deref()
                        .ok_or_else(|| Error::bad_request("a local slot names its model"))?;
                    let cm = self.catalog_model(model)?;
                    let class = rules::class_of(&cm.params).ok_or_else(|| {
                        Error::bad_request(format!("{model}: its size has no class"))
                    })?;
                    if !rules::local_roles(class).contains(&s.role.as_str()) {
                        return Err(Error::bad_request(format!(
                            "{model} is a class {class} model: its roles are {}; {:?} is not offered (local models \
                             have no tools yet, D-104)",
                            rules::local_roles(class).join(", "),
                            s.role
                        )));
                    }
                    if !s.argv.is_empty() {
                        return Err(Error::bad_request(
                            "a local slot has no command: the daemon runs the model",
                        ));
                    }
                }
                k => {
                    return Err(Error::bad_request(format!(
                        "worker kind {k:?}: one of claude, codex, program, local"
                    )));
                }
            }
            for h in &s.hosts {
                if !crate::wake::valid_host(h) {
                    return Err(Error::bad_request(format!("{h:?} is not a host name")));
                }
            }
        }
        Ok(())
    }

    /// Validate a template: checks (each program exists), registries, toolchain folders, environment, apply rule.
    fn validate_template(&self, t: &mut TeamTemplate) -> Result<()> {
        if t.checks.len() > 16 {
            return Err(Error::bad_request("at most 16 check commands"));
        }
        for c in &t.checks {
            if c.is_empty() || c.len() > 32 || c.iter().any(|a| a.len() > 4096 || a.contains('\0'))
            {
                return Err(Error::bad_request(
                    "a check command has 1..32 arguments of at most 4096 bytes",
                ));
            }
            crate::wake::resolve_program(&c[0])?;
        }
        if t.check_hosts.len() > 32 {
            return Err(Error::bad_request("at most 32 check hosts"));
        }
        for h in &mut t.check_hosts {
            *h = h.to_ascii_lowercase();
            if !crate::wake::valid_host(h) {
                return Err(Error::bad_request(format!(
                    "{h:?} is not a host name (example: index.crates.io or *.pypi.org)"
                )));
            }
        }
        for p in &t.check_paths {
            check::valid_check_path(p, &self.cfg.data_dir).map_err(Error::bad_request)?;
        }
        for e in &t.check_env {
            if !check::valid_env(e) {
                return Err(Error::bad_request(format!(
                    "{e:?}: a check variable is NAME=value, not PATH/HOME/ANTENNA_*/LD_*/*_PROXY"
                )));
            }
        }
        if !matches!(t.apply.as_str(), "owner" | "lead") {
            return Err(Error::bad_request("apply is owner or lead"));
        }
        t.check_timeout_secs = t
            .check_timeout_secs
            .clamp(5, rules::THIS_COMPUTER.max_check_secs);
        t.turn_timeout_secs = t
            .turn_timeout_secs
            .clamp(10, rules::THIS_COMPUTER.max_turn_secs);
        t.check_retries = t.check_retries.min(10);
        Ok(())
    }

    /// The lead: an existing agent that leads no other team and is no team's worker; a local-only team takes only a
    /// local model as its lead (or the owner in person).
    fn validate_lead(&self, name: &str, team_id: Option<i64>, local_only: bool) -> Result<i64> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let a = db.agent_by_name(name)?;
        if db::member(&db, a.id)?.is_some() {
            return Err(Error::bad_request(format!(
                "{name} is a team's worker; a lead is an agent of its own"
            )));
        }
        if let Some(t) = db::team_led_by(&db, a.id)?
            && Some(t.id) != team_id
        {
            return Err(Error::bad_request(format!(
                "{name} already leads the team {}",
                t.name
            )));
        }
        if local_only && !crate::local::is_local_agent(&db, a.id) {
            return Err(Error::bad_request(format!(
                "the team is local only: its lead must be a local model or you ({name} is not a local agent)"
            )));
        }
        Ok(a.id)
    }

    /// `team_create` (the caller checked the password).
    pub async fn team_create(&self, req: TeamCreate) -> Result<TeamInfo> {
        valid_team_name(&req.name)?;
        if self.load_team_by_name(&req.name).is_ok() {
            return Err(Error::bad_request(format!("a team {} exists", req.name)));
        }
        let dir = std::path::PathBuf::from(&req.project);
        if !dir.is_absolute() {
            return Err(Error::bad_request("the project is an absolute path"));
        }
        let project = git::project(&dir).await?;
        if project.git_dir.starts_with(&self.cfg.data_dir) {
            return Err(Error::bad_request(
                "the project cannot be inside the daemon's data",
            ));
        }
        let target = match req.target.clone().or(project.branch.clone()) {
            Some(t) if git::valid_branch(&t) => t,
            Some(t) => return Err(Error::bad_request(format!("{t:?} is not a branch name"))),
            None => {
                return Err(Error::bad_request(
                    "the project has no branch checked out: name the target branch",
                ));
            }
        };
        let repo = git::Repo::new(&project.git_dir);
        let tip = repo.branch_tip(&target).await?.ok_or_else(|| {
            Error::bad_request(format!(
                "the project has no branch {target} (or no commit on it)"
            ))
        })?;
        let mut template = req.template;
        self.validate_template(&mut template)?;
        self.validate_slots(&req.slots, &template)?;
        let sum: u32 = req.slots.iter().map(|s| s.max).sum();
        let max_workers = req.max_workers.unwrap_or(sum).min(MAX_TEAM_WORKERS);
        let lead_id = match &req.lead {
            Some(l) => Some(self.validate_lead(l, None, template.local_only)?),
            None => None,
        };
        let integration = format!("antenna/{}", req.name);
        if repo.branch_tip(&integration).await?.is_some() {
            return Err(Error::bad_request(format!(
                "the project already has a branch {integration}: delete it or choose another team name"
            )));
        }
        repo.set_branch(&integration, &tip, None).await?;
        let mut team = TeamRow {
            id: 0,
            name: req.name.clone(),
            project: project.top,
            git_dir: project.git_dir,
            lead_id,
            target,
            integration,
            cfg: TeamCfg {
                slots: req.slots,
                max_workers,
                template,
            },
            state: "active".into(),
            apply_request: None,
            created_ms: now_ms(),
        };
        let inserted = db::team_insert(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            &team,
        );
        team.id = match inserted {
            Ok(id) => id,
            Err(e) => {
                let _ = repo.delete_branch(&team.integration).await;
                return Err(e);
            }
        };
        git::mkdir_private(&self.team_dir(&team))?;
        self.team_log(
            team.id,
            &db::Entry {
                actor: "owner",
                action: "team_create",
                task: None,
                decision: "done",
                detail: &format!(
                    "{} slots, at most {max_workers} workers, apply by {}",
                    team.cfg.slots.len(),
                    team.cfg.template.apply
                ),
            },
        );
        self.team_event(&team.name, "created", None, "owner");
        self.team_info_now(&team, true).await
    }

    /// `team_set` (the caller checked the password).
    pub async fn team_set(&self, req: TeamSet) -> Result<TeamInfo> {
        let mut team = self.load_team_by_name(&req.team)?;
        let mut template = req.template.unwrap_or_else(|| team.cfg.template.clone());
        self.validate_template(&mut template)?;
        let slots = req.slots.unwrap_or_else(|| team.cfg.slots.clone());
        self.validate_slots(&slots, &template)?;
        let max_workers = req
            .max_workers
            .unwrap_or(team.cfg.max_workers)
            .min(MAX_TEAM_WORKERS);
        match req.lead.as_deref() {
            Some("") => team.lead_id = None,
            Some(l) => {
                team.lead_id = Some(self.validate_lead(l, Some(team.id), template.local_only)?)
            }
            None => {}
        }
        team.cfg = TeamCfg {
            slots,
            max_workers,
            template,
        };
        // Changing a team with the password also starts a stopped one again; its stopped workers stay stopped.
        team.state = "active".into();
        db::team_save(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            &team,
        )?;
        self.team_log(
            team.id,
            &db::Entry {
                actor: "owner",
                action: "team_set",
                task: None,
                decision: "done",
                detail: "",
            },
        );
        self.team_event(&team.name, "changed", None, "owner");
        self.team_info_now(&team, true).await
    }

    /// `team_list`.
    pub fn team_list(&self) -> Result<Vec<TeamInfo>> {
        let teams = db::teams(&self.db.lock().unwrap_or_else(PoisonError::into_inner))?;
        teams.iter().map(|t| self.team_info(t, false)).collect()
    }

    /// `team_show`.
    pub async fn team_show(&self, name: &str) -> Result<TeamInfo> {
        let team = self.load_team_by_name(name)?;
        self.team_info_now(&team, true).await
    }

    /// `team_add_worker`: a worker within the budget, as the lead's `worker_spawn`.
    pub fn team_add_worker(
        &self,
        team: &str,
        role: &str,
        kind: Option<&str>,
    ) -> Result<WorkerInfo> {
        let team = self.load_team_by_name(team)?;
        let m = self.worker_spawn_as(&team, &Actor::Owner, role, kind)?;
        Ok(self.worker_info(&team, &m, &[]))
    }

    /// The owner's stop switch for an agent that is a team's worker (PG-58): as `team_stop` with that worker.
    pub(crate) async fn team_stop_worker_of(&self, agent_id: i64) -> Result<()> {
        let Some(m) = self.team_member(agent_id) else {
            return Ok(());
        };
        let team = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db::team(&db, m.team_id)?
        };
        if m.state != "stopped" {
            self.worker_stop_as(&team, &Actor::Owner, &m.name).await?;
        }
        Ok(())
    }

    /// `team_stop`: one worker, or every worker and the team.
    pub async fn team_stop(&self, req: TeamStop) -> Result<TeamInfo> {
        let mut team = self.load_team_by_name(&req.team)?;
        match &req.worker {
            Some(w) => {
                self.worker_stop_as(&team, &Actor::Owner, w).await?;
            }
            None => {
                for m in self.load_members(&team)? {
                    if m.state != "stopped" {
                        self.worker_stop_as(&team, &Actor::Owner, &m.name).await?;
                    }
                }
                team.state = "stopped".into();
                db::team_save(
                    &self.db.lock().unwrap_or_else(PoisonError::into_inner),
                    &team,
                )?;
                self.team_log(
                    team.id,
                    &db::Entry {
                        actor: "owner",
                        action: "team_stop",
                        task: None,
                        decision: "done",
                        detail: "",
                    },
                );
                self.team_event(&team.name, "changed", None, "owner");
            }
        }
        self.team_info_now(&team, true).await
    }

    /// `team_remove`: workers (their agents, folders), task branches of unapplied tasks and the team's records go;
    /// the integration branch and the project stay.
    pub async fn team_remove(&self, name: &str) -> Result<Vec<TeamInfo>> {
        let team = self.load_team_by_name(name)?;
        let lock = self.team_lock(team.id);
        let _g = lock.lock().await;
        let members = self.load_members(&team)?;
        for m in &members {
            self.worker_shutdown(m.agent_id);
            if m.kind == "local" {
                self.local_team_stop(m.agent_id, &team);
                self.local_forget(m.agent_id);
            }
            self.team_forget_agent(m.agent_id);
            let _ = self
                .db
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .agent_remove(m.agent_id);
            self.emit_agent(&m.name, "removed");
        }
        let repo = git::Repo::new(&team.git_dir);
        let tasks = db::tasks(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
        )?;
        for t in &tasks {
            if let Some(r) = &t.result
                && !r.branch.is_empty()
            {
                let _ = repo.delete_branch(&r.branch).await;
            }
        }
        db::team_delete(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
        )?;
        let _ = std::fs::remove_dir_all(self.team_dir(&team));
        self.team_event(&team.name, "removed", None, "owner");
        self.team_list()
    }

    /// `team_apply` (the caller checked the password): the integration branch into the project's branch.
    pub async fn team_apply(&self, req: TeamApply) -> Result<TeamInfo> {
        let team = self.load_team_by_name(&req.team)?;
        let team = self
            .team_apply_as(&team, &Actor::Owner, req.commit.as_deref())
            .await?;
        self.team_info_now(&team, true).await
    }

    /// `team_log`.
    pub fn team_log_entries(&self, name: &str, limit: Option<u32>) -> Result<Vec<TeamLogEntry>> {
        let team = self.load_team_by_name(name)?;
        db::log_entries(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
            limit.unwrap_or(100).clamp(1, 1000),
        )
    }

    /// The team of a task the owner names by ID.
    fn team_of_task(&self, id: &str) -> Result<TeamRow> {
        let team_id = db::task_team(&self.db.lock().unwrap_or_else(PoisonError::into_inner), id)?;
        self.load_team(team_id)
    }

    /// `task_new`.
    pub async fn task_new(self: &Arc<Self>, req: TaskNew) -> Result<TaskInfo> {
        let name = req
            .team
            .clone()
            .ok_or_else(|| Error::bad_request("name the team"))?;
        let team = self.load_team_by_name(&name)?;
        let t = self.task_create_as(&team, &Actor::Owner, req).await?;
        Ok(self.task_info(&team, &t, true))
    }

    /// `task_list` (the owner's).
    pub fn task_list(&self, team: &str) -> Result<Vec<TaskInfo>> {
        let team = self.load_team_by_name(team)?;
        let tasks = db::tasks(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
        )?;
        Ok(tasks
            .iter()
            .map(|t| self.task_info(&team, t, false))
            .collect())
    }

    /// `task_show`.
    pub fn task_show(&self, id: &str) -> Result<TaskInfo> {
        let team = self.team_of_task(id)?;
        let t = self.load_task(&team, id)?;
        Ok(self.task_info(&team, &t, true))
    }

    /// `task_diff` (the owner's).
    pub async fn task_diff(&self, id: &str) -> Result<TaskDiff> {
        let team = self.team_of_task(id)?;
        let t = self.load_task(&team, id)?;
        let r = t
            .result
            .clone()
            .filter(|r| git::is_oid(&r.commit))
            .ok_or_else(|| {
                Error::new(
                    code::TASK_STATE,
                    format!("the task is {}: no submitted result yet", t.state),
                )
            })?;
        let (stat, diff, truncated) = git::Repo::new(&team.git_dir)
            .diff(&r.base, &r.commit)
            .await?;
        Ok(TaskDiff {
            task: t.id,
            base: r.base,
            commit: Some(r.commit),
            stat,
            diff,
            truncated,
        })
    }

    /// `task_review` (the owner's).
    pub async fn task_review_owner(
        self: &Arc<Self>,
        id: &str,
        verdict: &str,
        comments: &str,
        urgent: bool,
    ) -> Result<TaskInfo> {
        let team = self.team_of_task(id)?;
        let t = self
            .task_review_as(&team, &Actor::Owner, id, verdict, comments, urgent)
            .await?;
        Ok(self.task_info(&team, &t, true))
    }

    /// `task_apply` (the owner's): an accepted task into the integration branch.
    pub async fn task_apply_owner(&self, id: &str) -> Result<TaskInfo> {
        let team = self.team_of_task(id)?;
        let t = self.task_apply_as(&team, &Actor::Owner, id).await?;
        Ok(self.task_info(&team, &t, true))
    }

    /// `task_assign` (the owner's): the lead's rules, by the owner.
    pub async fn task_assign_owner(self: &Arc<Self>, id: &str, worker: &str) -> Result<TaskInfo> {
        let team = self.team_of_task(id)?;
        let t = self
            .task_assign_as(&team, &Actor::Owner, id, worker)
            .await?;
        Ok(self.task_info(&team, &t, true))
    }

    /// `team_capacity`: what the team's lead reads with `capacity`.
    pub fn team_capacity(&self, name: &str) -> Result<CapacityInfo> {
        let team = self.load_team_by_name(name)?;
        self.capacity(&team)
    }
}
