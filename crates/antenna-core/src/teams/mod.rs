// SPDX-License-Identifier: AGPL-3.0-only
//! Teams of agents (D-111, `docs/CONTROL.md` §25; experimental, D-94): a
//! lead agent and workers on one project. The owner creates the team once, with the password: the project (a git
//! repository of this computer), the lead, a budget of worker slots and a permission template. From then on the lead
//! creates workers within the budget, gives each a task, collects, checks, returns or accepts the results, and
//! applies them; the owner approves what the template keeps for the owner. The daemon decides every permission
//! (SPEC §9); a model never does.
//!
//! - **Attenuation only** ([`rules::grant`]): a worker's rights are the template ∩ the lead's session ceiling when it
//!   spawned the worker ∩ this machine's limits. Nothing a member does widens them; a slot exists only because the
//!   owner put it in the budget.
//! - **Taint travels with tasks**: a task records the taint of the session that wrote it (its links and levels,
//!   [`Carried`]); assigning it applies that taint to the worker, so a lead that read a level-2 contact writes tasks
//!   whose worker runs no commands, and an instruction injected through the lead never reaches level-5 rights. A
//!   result carries the worker's taint back to whoever reads it.
//! - **Isolation**: each worker has its own checkout of the project (no git history, no `.git`), the only folder it
//!   can write; it never sees the project folder, the object store or another worker's folder ([`git`]). Results
//!   reach the project only through review and apply, which the daemon does with git outside every sandbox.
//! - **Two sandboxes** (SPEC §11): the worker's (network only to its model provider, or none for local models) and
//!   the check's ([`check`]: no daemon socket, no agent environment, no keys; network only to the template's
//!   registries through the daemon's proxy).
//! - **Tokens**: the daemon makes each worker's token at every start of its process and gives it only to that
//!   sandbox; the lead never sees it; stopping the worker invalidates it.
//! - **Audit**: spawns, task changes, checks and applies are entries of the team's log (`team_log`).

mod agent;
mod apply;
mod check;
mod db;
mod git;
mod local;
mod owner;
pub(crate) mod rules;
mod spawn;
mod spec;
mod tasks;
mod view;
mod watch;
mod worker;

/// The folder and environment rules of checks, which the own-machine profile of a wake rule shares (D-122).
pub(crate) use check::{valid_check_path, valid_env};
pub(crate) use watch::{Next, Watch};

use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex as StdMutex, PoisonError},
};

use antenna_proto::{
    LinkId,
    control::{
        ApplyRequest, CheckRun, TaskFact, TaskReportInfo, TaskResult, TaskReviewInfo, TeamEvent,
        TeamSlot, TeamTemplate, code,
    },
};
use serde::{Deserialize, Serialize};

use crate::{
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
    now_ms,
    store::TaintEntry,
};

/// Facts kept per member until its next `wait`; the oldest go first.
const MAX_FACTS: usize = 64;
/// The longest task notes.
pub(crate) const MAX_NOTES: usize = 8 * 1024;
/// The longest title, brief, report, review comment.
const MAX_TITLE: usize = 200;
const MAX_BRIEF: usize = 16 * 1024;
const MAX_REPORT: usize = 16 * 1024;
/// At most this many tasks per team that are not finished.
const MAX_OPEN_TASKS: usize = 200;

/// The node session's team state (memory only; the tables are the record).
#[derive(Default)]
pub(crate) struct TeamsState {
    /// Worker processes by agent ID.
    workers: StdMutex<HashMap<i64, worker::Handle>>,
    /// Facts for each member's next `wait` (agent ID → facts).
    facts: StdMutex<HashMap<i64, VecDeque<TaskFact>>>,
    /// One change at a time per team: task records and the git operations on the project (team ID → lock).
    locks: StdMutex<HashMap<i64, Arc<tokio::sync::Mutex<()>>>>,
    /// The sandbox roots of running checks: their processes are refused at the control socket.
    jails: StdMutex<Vec<crate::procinfo::Anchor>>,
    /// The workers' live output for the owner's `team_watch`.
    output: watch::Output,
    /// The state last announced in a `team` event per worker (agent ID): only a real change is announced.
    states: StdMutex<HashMap<i64, String>>,
}

impl TeamsState {
    /// A worker's turn runs or waits (an automatic update waits for it, D-103).
    pub(crate) fn any_busy(&self) -> bool {
        self.workers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .any(worker::Handle::busy)
    }
}

/// A team: its row.
#[derive(Debug, Clone)]
pub(crate) struct TeamRow {
    pub id: i64,
    pub name: String,
    /// The project's top folder.
    pub project: PathBuf,
    /// The project's git directory (common dir).
    pub git_dir: PathBuf,
    /// The lead's agent ID; `None`: the owner leads.
    pub lead_id: Option<i64>,
    /// The project's branch results go to.
    pub target: String,
    /// `antenna/<team>`.
    pub integration: String,
    pub cfg: TeamCfg,
    /// `active`, `stopped`.
    pub state: String,
    pub apply_request: Option<ApplyRequest>,
    pub created_ms: u64,
}

/// The budget and the template (JSON in `teams.cfg`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub(crate) struct TeamCfg {
    pub slots: Vec<TeamSlot>,
    pub max_workers: u32,
    pub template: TeamTemplate,
}

/// A worker: its row (the agent is an ordinary `agents` row with no links).
#[derive(Debug, Clone)]
pub(crate) struct MemberRow {
    pub agent_id: i64,
    pub team_id: i64,
    /// The agent's name.
    pub name: String,
    pub role: String,
    pub kind: String,
    pub spec: MemberSpec,
    /// `owner` or the lead's name.
    pub spawned_by: String,
    /// `active`, `stopped`.
    pub state: String,
    pub created_ms: u64,
}

/// What the daemon runs for a worker and its counters (JSON in `team_members.spec`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub(crate) struct MemberSpec {
    /// The slot it fills.
    pub slot: usize,
    /// The command (absolute program first); empty for a local model.
    #[serde(default)]
    pub argv: Vec<String>,
    /// The proxy's hosts for its process.
    #[serde(default)]
    pub hosts: Vec<String>,
    /// Owner files its CLI reads, read-only (its provider login).
    #[serde(default)]
    pub home_files: Vec<String>,
    /// `local`: the model.
    #[serde(default)]
    pub model: Option<String>,
    /// The grant at spawn: it may run commands at all.
    #[serde(default)]
    pub commands: bool,
    /// The grant at spawn: a turn's time limit, seconds.
    #[serde(default)]
    pub turn_secs: u64,
    /// The agent CLI's session (`--session-id`, then `--resume`).
    #[serde(default)]
    pub session: Option<String>,
    /// The agent CLI wrote the session (the next start resumes it).
    #[serde(default)]
    pub created: bool,
    #[serde(default)]
    pub starts: u32,
    #[serde(default)]
    pub turns: u64,
    #[serde(default)]
    pub input_tokens: u64,
    #[serde(default)]
    pub output_tokens: u64,
    /// The last thing that happened to it (for the owner), never a model's text.
    #[serde(default)]
    pub detail: String,
}

/// One taint entry a task or a result carries: a link whose contact's data the writing session had read, and the
/// level at that time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Carried {
    /// Link (hex).
    pub link: String,
    /// Trust level when it was read.
    pub level: u8,
}

/// A task record (JSON in `team_tasks.rec`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Task {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub brief: String,
    #[serde(default)]
    pub check: Vec<String>,
    #[serde(default)]
    pub assignee: Option<i64>,
    pub state: String,
    pub created_by: String,
    /// The writer's taint.
    #[serde(default)]
    pub carried: Vec<Carried>,
    #[serde(default)]
    pub round: u32,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub reviews: Vec<TaskReviewInfo>,
    #[serde(default)]
    pub report: Option<TaskReportInfo>,
    #[serde(default)]
    pub result: Option<TaskResult>,
    /// The worker's taint when it submitted the result.
    #[serde(default)]
    pub result_carried: Vec<Carried>,
    /// A text-only result of a local model (no commit).
    #[serde(default)]
    pub result_text: Option<String>,
    #[serde(default)]
    pub check_run: Option<CheckRun>,
    #[serde(default)]
    pub applied: Option<String>,
    #[serde(default)]
    pub tokens: u64,
    /// Returns by a failed check on submit, this round of reviews.
    #[serde(default)]
    pub auto_returns: u32,
    /// The round in which the worker was last reminded to report.
    #[serde(default)]
    pub reminded_round: u32,
    /// The commit the current assignment started from.
    #[serde(default)]
    pub base: Option<String>,
    pub created_ms: u64,
    pub updated_ms: u64,
}

/// Who acts: the owner in person or an agent (the lead, a worker).
#[derive(Debug, Clone)]
pub(crate) enum Actor {
    Owner,
    Agent { id: i64, name: String },
    Daemon,
}

impl Actor {
    pub(crate) fn name(&self) -> &str {
        match self {
            Actor::Owner => "owner",
            Actor::Agent { name, .. } => name,
            Actor::Daemon => "daemon",
        }
    }
}

/// The folders of a worker: `tree` is its checkout (the one folder it writes besides its own HOME and TMPDIR);
/// `index` is the daemon's git index for it and stays outside every sandbox.
pub(crate) struct WorkerDirs {
    pub root: PathBuf,
    pub tree: PathBuf,
    pub home: PathBuf,
    pub tmp: PathBuf,
    pub index: PathBuf,
    pub proxy_sock: PathBuf,
}

/// A team name: `[a-z0-9-]`, 1–24 characters, starting with a letter or digit.
pub(crate) fn valid_team_name(n: &str) -> Result<()> {
    if n.is_empty()
        || n.len() > 24
        || n.starts_with('-')
        || !n
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(Error::bad_request(
            "team name: 1–24 characters of [a-z0-9-], not starting with -",
        ));
    }
    Ok(())
}

/// A role: `[a-z]`, 1–16 characters.
pub(crate) fn valid_role(r: &str) -> Result<()> {
    if r.is_empty() || r.len() > 16 || !r.chars().all(|c| c.is_ascii_lowercase()) {
        return Err(Error::bad_request("role: 1–16 characters of [a-z]"));
    }
    Ok(())
}

/// One line of text from a member for a title: no control characters, at most [`MAX_TITLE`].
fn one_line(s: &str, max: usize) -> String {
    s.chars()
        .filter(|c| !c.is_control())
        .take(max)
        .collect::<String>()
        .trim()
        .to_string()
}

/// Text from a member (a brief, a report, comments): no control characters but line breaks and tabs, at most `max`
/// bytes (cut on a character boundary).
fn text_of(s: &str, max: usize) -> String {
    let mut t: String = s
        .chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect();
    if t.len() > max {
        let mut cut = max;
        while !t.is_char_boundary(cut) {
            cut -= 1;
        }
        t.truncate(cut);
    }
    t
}

/// A new task ID: 16 hex digits.
fn new_task_id() -> String {
    data_encoding::HEXLOWER.encode(&crate::crypto::random::<8>())
}

/// The ceiling-bearing taint entries of an agent row.
fn carried_of(taint: &[TaintEntry]) -> Vec<Carried> {
    taint
        .iter()
        .filter(|t| t.ceiling)
        .map(|t| Carried {
            link: t.link.clone(),
            level: t.level,
        })
        .collect()
}

/// Merge two carried lists: the lower level per link.
fn merge_carried(a: &[Carried], b: &[Carried]) -> Vec<Carried> {
    let mut out: Vec<Carried> = a.to_vec();
    for c in b {
        match out.iter_mut().find(|x| x.link == c.link) {
            Some(x) => x.level = x.level.min(c.level),
            None => out.push(c.clone()),
        }
    }
    out
}

impl Session {
    /// `<data>/teams`.
    fn teams_dir(&self) -> PathBuf {
        self.cfg.data_dir.join("teams")
    }

    fn team_dir(&self, team: &TeamRow) -> PathBuf {
        self.teams_dir().join(&team.name)
    }

    /// A worker's folders. The short worker number keeps the proxy socket within `sun_path`.
    fn worker_dirs(&self, team: &TeamRow, agent_id: i64) -> WorkerDirs {
        let root = self.team_dir(team).join("w").join(agent_id.to_string());
        WorkerDirs {
            tree: root.join("tree"),
            home: root.join("home"),
            tmp: root.join("tmp"),
            index: root.join("index"),
            proxy_sock: root.join("proxy.sock"),
            root,
        }
    }

    /// The folders of a task's check (a checkout of its result).
    fn check_dirs(&self, team: &TeamRow, task: &str) -> WorkerDirs {
        let root = self.team_dir(team).join("c").join(task);
        WorkerDirs {
            tree: root.join("tree"),
            home: root.join("home"),
            tmp: root.join("tmp"),
            index: root.join("index"),
            proxy_sock: root.join("proxy.sock"),
            root,
        }
    }

    /// The team's lock: one change of its tasks or its git state at a time.
    fn team_lock(&self, team_id: i64) -> Arc<tokio::sync::Mutex<()>> {
        self.teams
            .locks
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(team_id)
            .or_default()
            .clone()
    }

    /// An entry of the team's audit log (a failure to write it is logged, never fatal to the action).
    fn team_log(&self, team_id: i64, e: &db::Entry<'_>) {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(err) = db::log(&db, team_id, now_ms(), e) {
            tracing::warn!("team log: {}", err.message);
        }
    }

    /// The owner's subscriptions learn that a team or one of its tasks changed, and who changed it.
    fn team_event(&self, team: &str, change: &str, task: Option<&Task>, by: &str) {
        let _ = self.events.send(NodeEvent::Team(Box::new(TeamEvent {
            team: team.into(),
            change: change.into(),
            task: task.map(|t| t.id.clone()),
            state: task.map(|t| t.state.clone()),
            worker: None,
            by: Some(by.into()),
        })));
    }

    /// The owner's subscriptions learn that a worker changed: spawned, stopped, or (by the daemon) its state.
    fn worker_event(&self, team: &str, worker: &str, state: &str, by: &str) {
        let _ = self.events.send(NodeEvent::Team(Box::new(TeamEvent {
            team: team.into(),
            change: "worker".into(),
            task: None,
            state: Some(state.into()),
            worker: Some(worker.into()),
            by: Some(by.into()),
        })));
    }

    /// A worker's process or turn changed: announce its state (as `team_worker.state` reports it) if it is not the
    /// one last announced. A stopped worker's state was announced by whoever stopped it.
    pub(crate) fn worker_state_changed(&self, agent_id: i64) {
        let Some(m) = self.team_member(agent_id) else {
            return;
        };
        if m.state == "stopped" {
            return;
        }
        let Ok(team) = self.load_team(m.team_id) else {
            return;
        };
        let state = self.worker_state(&m);
        if !self.note_worker_state(agent_id, &state) {
            return;
        }
        self.worker_event(&team.name, &m.name, &state, "daemon");
    }

    /// Record the state announced for a worker; false if it is the one already announced (a worker without an entry
    /// is `sleeping`, the state of a worker with no process).
    fn note_worker_state(&self, agent_id: i64, state: &str) -> bool {
        let mut g = self
            .teams
            .states
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if g.get(&agent_id).map_or("sleeping", String::as_str) == state {
            return false;
        }
        g.insert(agent_id, state.into());
        true
    }

    /// A fact for a member's next `wait`, which it also wakes.
    fn team_fact(
        &self,
        agent_id: i64,
        team: &str,
        task: &Task,
        change: &str,
        assignee: Option<String>,
    ) {
        {
            let mut g = self
                .teams
                .facts
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let q = g.entry(agent_id).or_default();
            q.push_back(TaskFact {
                team: team.into(),
                task: task.id.clone(),
                change: change.into(),
                state: task.state.clone(),
                assignee,
                at_ms: now_ms(),
            });
            while q.len() > MAX_FACTS {
                q.pop_front();
            }
        }
        self.inbox.send_modify(|v| *v += 1);
    }

    /// The facts for this agent since its last `wait` (they are gone after this).
    pub(crate) fn take_team_facts(&self, agent_id: i64) -> Vec<TaskFact> {
        self.teams
            .facts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&agent_id)
            .map(Vec::from)
            .unwrap_or_default()
    }

    /// Whether this agent has facts waiting.
    pub(crate) fn has_team_facts(&self, agent_id: i64) -> bool {
        self.teams
            .facts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&agent_id)
            .is_some_and(|q| !q.is_empty())
    }

    /// The taint an agent's session carries now.
    fn carried_now(&self, agent_id: i64) -> Result<Vec<Carried>> {
        let row = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agent(agent_id)?;
        Ok(carried_of(&row.taint))
    }

    /// Apply carried taint to an agent's session: per link the lower level (SPEC §9: reading data taints).
    fn carry_into(&self, agent_id: i64, carried: &[Carried]) -> Result<()> {
        if carried.is_empty() {
            return Ok(());
        }
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let mut agent = db.agent(agent_id)?;
        for c in carried {
            match agent.taint.iter_mut().find(|t| t.link == c.link) {
                Some(t) if t.ceiling => t.level = t.level.min(c.level),
                Some(t) => {
                    t.ceiling = true;
                    t.level = c.level;
                }
                None => agent.taint.push(TaintEntry {
                    link: c.link.clone(),
                    level: c.level,
                    at: now_ms(),
                    ceiling: true,
                }),
            }
        }
        db.agent_save_label(agent.id, &agent.taint, &agent.declared)?;
        Ok(())
    }

    /// The ceiling of carried taint with today's trust levels (a level lowered since counts, as for any taint).
    fn ceiling_of(&self, carried: &[Carried]) -> Option<u8> {
        if carried.is_empty() {
            return None;
        }
        let links = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links()
            .unwrap_or_default();
        carried
            .iter()
            .map(|c| {
                let now = data_encoding::HEXLOWER
                    .decode(c.link.as_bytes())
                    .ok()
                    .and_then(|v| <[u8; 32]>::try_from(v).ok())
                    .and_then(|a| {
                        let id = LinkId(a);
                        links.iter().find(|r| r.link_id == id).map(|r| r.trust)
                    });
                now.map_or(c.level, |t| t.min(c.level))
            })
            .min()
    }

    /// An agent session's ceiling now.
    fn agent_ceiling(&self, agent_id: i64) -> Option<u8> {
        self.carried_now(agent_id)
            .map(|c| self.ceiling_of(&c))
            .unwrap_or(Some(0))
    }

    fn agent_name(&self, id: i64) -> Option<String> {
        self.db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agent(id)
            .ok()
            .map(|a| a.name)
    }

    fn load_team(&self, id: i64) -> Result<TeamRow> {
        db::team(&self.db.lock().unwrap_or_else(PoisonError::into_inner), id)
    }

    fn load_team_by_name(&self, name: &str) -> Result<TeamRow> {
        db::team_by_name(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            name,
        )
    }

    fn load_task(&self, team: &TeamRow, id: &str) -> Result<Task> {
        db::task(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
            id,
        )
    }

    fn save_task(&self, t: &mut Task) -> Result<()> {
        t.updated_ms = now_ms();
        db::task_save(&self.db.lock().unwrap_or_else(PoisonError::into_inner), t)
    }

    fn load_members(&self, team: &TeamRow) -> Result<Vec<MemberRow>> {
        db::members(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            team.id,
        )
    }

    /// The worker row of an agent, if it is one.
    pub(crate) fn team_member(&self, agent_id: i64) -> Option<MemberRow> {
        db::member(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            agent_id,
        )
        .ok()
        .flatten()
    }

    fn save_member(&self, m: &MemberRow) -> Result<()> {
        db::member_save(&self.db.lock().unwrap_or_else(PoisonError::into_inner), m)
    }

    /// The decision on a team worker's tool call (`check`, the host hook), before the ordinary ceiling rule: the
    /// template's commands and the worker's own folder. `None` for an agent that is not a worker.
    pub(crate) fn team_check(
        &self,
        agent_id: i64,
        action: crate::policy::Action,
        detail: &str,
        ceiling: Option<u8>,
    ) -> Option<crate::policy::Verdict> {
        let m = self.team_member(agent_id)?;
        if m.state == "stopped" {
            return Some(crate::policy::Verdict::Deny(
                "team:stopped: this worker was stopped".into(),
            ));
        }
        let team = self.load_team(m.team_id).ok()?;
        let dirs = self.worker_dirs(&team, agent_id);
        let in_own = in_folder(detail, &dirs.tree) || in_folder(detail, &dirs.tmp);
        Some(rules::worker_action(
            m.spec.commands && team.cfg.template.commands,
            ceiling,
            action,
            in_own,
            detail,
        ))
    }

    /// At unlock: workers whose task was in progress get a turn to continue it (their processes ended with the
    /// daemon); nothing else starts.
    pub(crate) fn teams_start(self: &Arc<Self>) {
        let s = self.clone();
        tokio::spawn(async move {
            let teams = {
                let db = s.db.lock().unwrap_or_else(PoisonError::into_inner);
                db::teams(&db).unwrap_or_default()
            };
            for team in teams.iter().filter(|t| t.state == "active") {
                let tasks = {
                    let db = s.db.lock().unwrap_or_else(PoisonError::into_inner);
                    db::tasks(&db, team.id).unwrap_or_default()
                };
                for t in tasks.iter().filter(|t| {
                    matches!(
                        t.state.as_str(),
                        antenna_proto::control::task_state::ASSIGNED
                            | antenna_proto::control::task_state::WORKING
                            | antenna_proto::control::task_state::RETURNED
                    )
                }) {
                    if let Some(w) = t.assignee {
                        s.worker_turn(w, worker::resume_text(&team.name, t), Some(t.id.clone()));
                    }
                }
            }
        });
    }

    /// An agent is being removed (`agent_remove`): its worker process stops; its rows go with the agent's.
    pub(crate) fn team_forget_agent(&self, agent_id: i64) {
        self.worker_shutdown(agent_id);
        self.teams
            .facts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&agent_id);
        self.teams
            .states
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&agent_id);
        self.teams.output.forget(agent_id);
    }

    /// `team_watch`: the owner watches a team's workers live (`not_found` for an unknown team).
    pub(crate) fn team_watch(&self, name: &str) -> Result<Watch> {
        let team = self.load_team_by_name(name)?;
        Ok(self.teams.output.watch(&team.name))
    }

    /// Whether the team exists (a watch ends when it is removed).
    pub(crate) fn team_exists(&self, name: &str) -> bool {
        self.load_team_by_name(name).is_ok()
    }
}

/// Whether `path` is inside `dir` (lexically, after making it absolute against `dir`; `..` is refused).
fn in_folder(path: &str, dir: &std::path::Path) -> bool {
    if path.is_empty() {
        return false;
    }
    let p = std::path::Path::new(path);
    let p = if p.is_absolute() {
        p.to_path_buf()
    } else {
        dir.join(p)
    };
    if p.components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return false;
    }
    p.starts_with(dir) || dir.canonicalize().is_ok_and(|d| p.starts_with(d))
}

/// Whether an agent is a team's worker.
pub(crate) fn is_worker(db: &crate::store::Db, agent_id: i64) -> bool {
    db::member(db, agent_id).ok().flatten().is_some()
}

/// `not_found` for an agent in no team.
fn not_in_team() -> Error {
    Error::new(
        code::NOT_FOUND,
        "this agent is in no team: the owner creates teams (`antenna team create`)",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_text() {
        assert!(valid_team_name("web-1").is_ok());
        for bad in ["", "-x", "Web", "a.b", "a b", &"x".repeat(25)] {
            assert!(valid_team_name(bad).is_err(), "{bad}");
        }
        assert!(valid_role("coder").is_ok());
        assert!(valid_role("Coder").is_err());
        assert_eq!(one_line("a\nb\u{1b}[2Jc", 200), "ab[2Jc");
        assert_eq!(text_of("a\nb\u{1b}c\t", 100), "a\nbc\t");
        assert_eq!(text_of("ééé", 3), "é");
        assert_eq!(new_task_id().len(), 16);
    }

    #[test]
    fn carried_taint_merges_to_the_lower_level() {
        let a = vec![Carried {
            link: "aa".into(),
            level: 4,
        }];
        let b = vec![
            Carried {
                link: "aa".into(),
                level: 2,
            },
            Carried {
                link: "bb".into(),
                level: 5,
            },
        ];
        let m = merge_carried(&a, &b);
        assert_eq!(m.len(), 2);
        assert_eq!(m[0].level, 2);
        assert_eq!(m[1].level, 5);
    }

    #[test]
    fn a_path_is_in_a_folder_only_lexically_inside() {
        let d = std::path::Path::new("/data/teams/web/w/7/tree");
        assert!(in_folder("/data/teams/web/w/7/tree/src/a.rs", d));
        assert!(in_folder("src/a.rs", d));
        assert!(!in_folder("/data/teams/web/w/8/tree/a.rs", d));
        assert!(!in_folder("/data/teams/web/w/7/tree/../../8/tree/a.rs", d));
        assert!(!in_folder("../x", d));
        assert!(!in_folder("", d));
    }
}
