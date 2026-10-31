// SPDX-License-Identifier: Apache-2.0
//! Teams of agents (x-control/7, D-111, `docs/CONTROL.md` §25; experimental): a lead agent and workers on one project.
//! The owner creates a team once with the password (the project, the lead, a budget of worker slots, a permission
//! template); from then on the lead creates workers within the budget, gives them tasks, reviews and applies their
//! results, and the daemon decides every permission (SPEC §9).
//!
//! The owner's commands (`team_*`, `task_new`, `task_show`, `task_apply`, and the owner's `task_list`, `task_diff`,
//! `task_review`, `task_assign`; the dialog `team_watch`) live in [`super::Request`]; the agents' (`team_info`,
//! `task_*`, `run_check`, `apply_result`, `worker_*`, `capacity`) in [`super::AgentRequest`]. No agent command creates a team, changes a budget or a template,
//! or applies to the project's branch without the owner when the template keeps that for the owner.

use serde::{Deserialize, Serialize};

fn is_false(b: &bool) -> bool {
    !*b
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

/// Task states: `open` → `assigned` → `working` → `submitted` → `accepted` → `done`, with `blocked` (a question to
/// the lead), `returned` (changes requested) and `cancelled`.
pub mod task_state {
    /// Nobody is assigned.
    pub const OPEN: &str = "open";
    /// A worker is assigned; it has not reported yet.
    pub const ASSIGNED: &str = "assigned";
    /// The worker reported that it works on it.
    pub const WORKING: &str = "working";
    /// The worker asks the lead something.
    pub const BLOCKED: &str = "blocked";
    /// The worker submitted a result (a commit on `team/<task>`).
    pub const SUBMITTED: &str = "submitted";
    /// The reviewer (or the daemon's check) asked for changes: the worker continues.
    pub const RETURNED: &str = "returned";
    /// The reviewer accepted the result; it waits to be applied.
    pub const ACCEPTED: &str = "accepted";
    /// The result is merged into the team's integration branch.
    pub const DONE: &str = "done";
    /// Cancelled by the lead or the owner.
    pub const CANCELLED: &str = "cancelled";
}

/// One kind of worker the owner pre-authorized: "up to `max` workers of `kind` with role `role`" on this computer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamSlot {
    /// The role workers of this slot take: `coder`, `tester`, `reviewer`, `docs`, `summaries`, `triage`.
    pub role: String,
    /// `claude` (Claude Code run by the daemon), `codex`, `program` (another program that speaks Claude Code's
    /// stream-json), `local` (a local model of this computer, D-104).
    pub kind: String,
    /// `local`: the catalog model's ID (`qwen3.5-9b`); the daemon refuses a model that is not installed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// How many workers of this slot may exist at once.
    pub max: u32,
    /// `claude`, `program`: the command (`claude --model haiku`); empty means `claude` for the `claude` kind. The
    /// daemon adds what a resident agent needs and refuses the flags that remove permission checks (D-67).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub argv: Vec<String>,
    /// Extra hosts the worker's CLI may reach through the daemon's proxy (the provider's own are added by kind).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hosts: Vec<String>,
}

/// What workers may do, and the review rules. Every field narrows: nothing a team member does widens it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamTemplate {
    /// Workers may run commands in their sandbox (still capped by taint: a worker whose task carries a ceiling
    /// below 4 runs none).
    #[serde(default = "yes")]
    pub commands: bool,
    /// The check commands a task may name (exact argument lists): `cargo test`, `pytest -q`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub checks: Vec<Vec<String>>,
    /// Hosts a check may reach through the daemon's proxy (package registries); empty: no network at all.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub check_hosts: Vec<String>,
    /// Read-only folders a check needs besides the system's (a toolchain: `~/.rustup`, `~/.cargo/bin`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub check_paths: Vec<String>,
    /// Environment of a check besides `PATH`, `HOME`, `TMPDIR`: `NAME=value`, no secrets (a toolchain's home:
    /// `RUSTUP_HOME=/home/me/.rustup`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub check_env: Vec<String>,
    /// Time limit of one check, seconds.
    #[serde(default = "check_timeout")]
    pub check_timeout_secs: u64,
    /// How often a submitted result whose check fails goes back to its worker by itself before the lead decides.
    #[serde(default = "check_retries")]
    pub check_retries: u32,
    /// Time limit of one worker turn, seconds (the daemon interrupts it).
    #[serde(default = "turn_timeout")]
    pub turn_timeout_secs: u64,
    /// Tokens one task may use (input and output, all turns); 0: no limit.
    #[serde(default)]
    pub max_task_tokens: u64,
    /// Who applies the integration branch to the project's branch: `owner` (the default: the owner approves with
    /// the password) or `lead`.
    #[serde(default = "owner")]
    pub apply: String,
    /// Only local models may work here: no cloud worker and no cloud lead (PG-26).
    #[serde(default, skip_serializing_if = "is_false")]
    pub local_only: bool,
}

fn yes() -> bool {
    true
}
fn check_timeout() -> u64 {
    600
}
fn check_retries() -> u32 {
    3
}
fn turn_timeout() -> u64 {
    1800
}
fn owner() -> String {
    "owner".into()
}

impl Default for TeamTemplate {
    fn default() -> Self {
        Self {
            commands: true,
            checks: Vec::new(),
            check_hosts: Vec::new(),
            check_paths: Vec::new(),
            check_env: Vec::new(),
            check_timeout_secs: check_timeout(),
            check_retries: check_retries(),
            turn_timeout_secs: turn_timeout(),
            max_task_tokens: 0,
            apply: owner(),
            local_only: false,
        }
    }
}

// Owner requests.

/// `team_create` (owner password): a team on a git repository of this computer.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamCreate {
    /// `[a-z0-9-]`, 1–24 characters: workers are named `<team>.<role>-<n>`.
    pub name: String,
    /// The project: a git repository (its top folder) on this computer.
    pub project: String,
    /// The lead: an existing agent of this node; `None`: the owner leads in person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lead: Option<String>,
    /// The budget.
    #[serde(default)]
    pub slots: Vec<TeamSlot>,
    /// At most this many workers at once (default: the sum of the slots).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_workers: Option<u32>,
    /// What workers may do.
    #[serde(default)]
    pub template: TeamTemplate,
    /// The project's branch results are applied to (default: the branch checked out in the project).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// Owner password.
    pub password: String,
}

impl std::fmt::Debug for TeamCreate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TeamCreate({})", self.name)
    }
}

/// `team_set` (owner password): replace the lead, the budget or the template. Workers already running keep their
/// sandbox until their next start; a slot removed or made smaller stops no worker by itself (`team_stop` does).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamSet {
    /// Team.
    pub team: String,
    /// A new lead (an agent name), or `""` for the owner in person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lead: Option<String>,
    /// A new budget.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slots: Option<Vec<TeamSlot>>,
    /// A new limit of workers at once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_workers: Option<u32>,
    /// A new template.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub template: Option<TeamTemplate>,
    /// Owner password.
    pub password: String,
}

impl std::fmt::Debug for TeamSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TeamSet({})", self.team)
    }
}

/// A team by name (`team_show`, `team_remove`, `team_capacity`, `team_watch`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamRef {
    /// Team.
    pub team: String,
}

/// No arguments (`team_list`; the agents' `team_info`, `task_list`, `capacity`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NoArgs {}

/// `team_add_worker` (owner session): a worker within the budget, as the lead's `worker_spawn` makes one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamAddWorker {
    /// Team.
    pub team: String,
    /// Role.
    pub role: String,
    /// Kind (`claude`, `program`, `local`, …); default: the first slot of the role with room.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// `team_stop` (owner session, no password: it only takes work away): stop every worker of the team, or one; their
/// processes end, their tokens stop working, their folders stay until `team_remove`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamStop {
    /// Team.
    pub team: String,
    /// Only this worker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker: Option<String>,
}

/// `team_apply` (owner password): merge the team's integration branch into the project's branch. With `commit`, only
/// if the integration branch is still at that commit (what the owner reviewed).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamApply {
    /// Team.
    pub team: String,
    /// The integration commit the owner saw.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// Owner password.
    pub password: String,
}

impl std::fmt::Debug for TeamApply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TeamApply({})", self.team)
    }
}

/// `team_log` (owner session): the team's audit log, newest last.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamLogReq {
    /// Team.
    pub team: String,
    /// How many of the latest entries (default 100).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

/// `task_new` (owner) / `task_create` (the lead): a new task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskNew {
    /// Team (the owner names it; for the lead it is the lead's team and must be absent or the same).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
    /// Title, one line.
    pub title: String,
    /// What done means.
    #[serde(default)]
    pub brief: String,
    /// The check command, one of the template's `checks`; empty: none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub check: Vec<String>,
    /// A worker to assign it to at once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
}

/// A task by ID (`task_show`, `task_get`, `task_diff`, `run_check`, `task_apply`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskRef {
    /// Task ID (the first 6+ characters are enough).
    pub id: String,
}

/// `task_list` (owner: a team's tasks).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskListReq {
    /// Team.
    pub team: String,
}

/// `task_review`: `accept` (a submitted result), `changes` (back to the worker with the comments; also the answer to
/// a blocked worker's question), `cancel`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskReviewReq {
    /// Task ID.
    pub id: String,
    /// `accept`, `changes`, `cancel`.
    pub verdict: String,
    /// Comments for the worker.
    #[serde(default)]
    pub comments: String,
    /// The owner's "urgent: interrupt the worker now" (v7, `docs/CONTROL.md` §33, PG-58): only with `changes`; the
    /// worker's turn in progress is interrupted and the task returns to it at once, also from `assigned`, `working`
    /// or `returned`. An agent's `task_review` with it is `forbidden`: only the owner interrupts.
    #[serde(default, skip_serializing_if = "is_false")]
    pub urgent: bool,
}

// Agent requests.

/// `task_assign` (the lead, or the owner): give a task to one of the team's workers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskAssign {
    /// Task ID.
    pub id: String,
    /// The worker's name.
    pub worker: String,
}

/// `task_report` (a worker, its own task): `working` (with a progress note), `blocked` (with the question), or
/// `submitted` (the daemon records the worker's folder as a commit on `team/<task>` and runs the task's check).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskReportReq {
    /// Task ID.
    pub id: String,
    /// `working`, `blocked`, `submitted`.
    pub state: String,
    /// The note, the question, or the summary of the result.
    #[serde(default)]
    pub summary: String,
}

/// `task_note`: read the task's notes (`text` absent) or replace them (state, decisions, next step; at most 8 KiB).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskNoteReq {
    /// Task ID.
    pub id: String,
    /// The new notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// `apply_result` (the lead): with `id`, merge that accepted result into the team's integration branch; with
/// `target`, merge the integration branch into the project's branch, which needs the owner unless the template says
/// `apply: lead` (`approval_required`: the request waits for the owner, who applies it with `team_apply`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApplyResultReq {
    /// The accepted task.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Apply the integration branch to the project's branch.
    #[serde(default, skip_serializing_if = "is_false")]
    pub target: bool,
}

/// `worker_spawn` (the lead): fill a slot of the budget. The reply names the worker, never its token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerSpawn {
    /// Role.
    pub role: String,
    /// Kind; default: the first slot of the role with room.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// `worker_stop` (the lead): free a slot; the worker's process ends and its token stops working.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerStop {
    /// The worker's name.
    pub name: String,
}

// Replies.

/// A team.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamInfo {
    /// Name.
    pub name: String,
    /// The project folder.
    pub project: String,
    /// The project's branch results are applied to.
    pub target: String,
    /// The team's integration branch (`antenna/<team>`): accepted results are merged here first.
    pub integration: String,
    /// Its commit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub integration_commit: Option<String>,
    /// The lead's agent name; `None`: the owner leads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lead: Option<String>,
    /// `active`, `stopped`.
    pub state: String,
    /// The budget.
    pub slots: Vec<TeamSlot>,
    /// At most this many workers at once.
    pub max_workers: u32,
    /// What workers may do.
    pub template: TeamTemplate,
    /// The workers.
    #[serde(default)]
    pub workers: Vec<WorkerInfo>,
    /// The tasks (summaries: no notes and no reviews; `task_show` has them).
    #[serde(default)]
    pub tasks: Vec<TaskInfo>,
    /// The lead asked to apply the integration branch to the project's branch; the owner decides (`team_apply`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub apply_request: Option<ApplyRequest>,
    /// The caller's role when an agent asks: `lead` or `worker`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// Unix ms.
    pub created_ms: u64,
}

/// A pending request to apply the integration branch to the project's branch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApplyRequest {
    /// Who asked (the lead's name).
    pub by: String,
    /// The integration commit at that time.
    pub commit: String,
    /// Unix ms.
    pub at_ms: u64,
}

/// A worker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerInfo {
    /// Agent name: `<team>.<role>-<n>`.
    pub name: String,
    /// Team.
    pub team: String,
    /// Role.
    pub role: String,
    /// Kind (`claude`, `program`, `local`, …).
    pub kind: String,
    /// `local`: the model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Where it runs: `this computer` (other machines come later).
    pub machine: String,
    /// `idle`, `starting`, `busy`, `sleeping`, `stopped`, `failed`.
    pub state: String,
    /// Its current task.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    /// `owner` or the lead's name.
    pub spawned_by: String,
    /// Its session ceiling (taint): `None` while it read nothing below the owner's own data.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ceiling: Option<u8>,
    /// Turns so far.
    #[serde(default)]
    pub turns: u64,
    /// Turns waiting in its queue behind the one in progress.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub queued: u32,
    /// Tokens: fresh input + cache, and output.
    #[serde(default)]
    pub input_tokens: u64,
    /// Output tokens.
    #[serde(default)]
    pub output_tokens: u64,
    /// What it does now, or why it stopped.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub detail: String,
    /// Unix ms.
    pub created_ms: u64,
}

/// A task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskInfo {
    /// ID (16 hex digits).
    pub id: String,
    /// Team.
    pub team: String,
    /// Title.
    pub title: String,
    /// What done means (written by the lead or the owner).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub brief: String,
    /// The check command.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub check: Vec<String>,
    /// The worker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
    /// [`task_state`].
    pub state: String,
    /// `owner` or the lead's name.
    pub created_by: String,
    /// The ceiling the task carries: the lowest trust level the session that wrote it had read (`None`: none, the
    /// owner's or a clean session's task). A worker that reads it is capped by it (SPEC §9 taint).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ceiling: Option<u8>,
    /// The round: 1 at the first assignment, +1 at every return.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub round: u32,
    /// The task's notes file (state, decisions, next step).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub notes: String,
    /// Reviews, oldest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reviews: Vec<TaskReviewInfo>,
    /// The worker's last report.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report: Option<TaskReportInfo>,
    /// The submitted result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<TaskResult>,
    /// The last check run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_run: Option<CheckRun>,
    /// The integration commit that merged it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub applied: Option<String>,
    /// Tokens the task used so far.
    #[serde(default)]
    pub tokens: u64,
    /// Unix ms.
    pub created_ms: u64,
    /// Unix ms.
    pub updated_ms: u64,
}

/// One review of a task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskReviewInfo {
    /// `owner`, the lead's name, or `daemon` (a failed check sent it back).
    pub by: String,
    /// `accept`, `changes`, `cancel`.
    pub verdict: String,
    /// Comments.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub comments: String,
    /// Unix ms.
    pub at_ms: u64,
}

/// A worker's report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskReportInfo {
    /// The worker.
    pub by: String,
    /// `working`, `blocked`, `submitted`.
    pub state: String,
    /// The note, the question or the summary: the worker's text, data for whoever reads it.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub summary: String,
    /// Unix ms.
    pub at_ms: u64,
}

/// A submitted result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskResult {
    /// `team/<task>`.
    pub branch: String,
    /// The commit the worker started from.
    pub base: String,
    /// The result's commit (empty for a text-only result of a local model).
    pub commit: String,
    /// Files changed.
    pub files: u32,
    /// Lines added.
    pub insertions: u64,
    /// Lines removed.
    pub deletions: u64,
    /// The ceiling of the worker's session when it submitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ceiling: Option<u8>,
    /// Unix ms.
    pub at_ms: u64,
}

/// A check run in the check sandbox.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckRun {
    /// The task.
    pub task: String,
    /// The commit it checked (`None`: the worker's folder as it was).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// The command.
    pub argv: Vec<String>,
    /// `passed`, `failed`, `timeout`, `refused` (taint or the template), `error` (the sandbox did not come up).
    pub outcome: String,
    /// Exit code.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// The output's tail (stdout and stderr, at most 16 KiB): the check's text, data for whoever reads it.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub output: String,
    /// Hosts the check tried and the proxy refused.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocked_hosts: Vec<String>,
    /// The sandbox: `bwrap`, `landlock`, `seatbelt`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub sandbox: String,
    /// Duration, ms.
    pub duration_ms: u64,
    /// Who asked: a worker, the lead, `owner` or `daemon` (on submit).
    pub by: String,
    /// Unix ms.
    pub at_ms: u64,
}

/// `task_diff`: what a result changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskDiff {
    /// The task.
    pub task: String,
    /// The base commit.
    pub base: String,
    /// The result commit, or `None` for a worker's folder not submitted yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// `git diff --stat`.
    pub stat: String,
    /// The diff (at most 256 KiB): the worker's text, data for whoever reads it.
    pub diff: String,
    /// The diff was cut at the limit.
    #[serde(default, skip_serializing_if = "is_false")]
    pub truncated: bool,
}

/// `capacity`: facts about the machines a team may use.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapacityInfo {
    /// Team.
    pub team: String,
    /// Workers now.
    pub workers: u32,
    /// The team's limit of workers at once.
    pub max_workers: u32,
    /// Per machine.
    pub machines: Vec<MachineCapacity>,
}

/// One machine's capacity for a team.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MachineCapacity {
    /// `this computer`.
    pub name: String,
    /// The sandbox workers and checks run in, or `none` (no worker starts).
    pub sandbox: String,
    /// Workers of all teams on this machine now, and the machine's own limit.
    pub workers: u32,
    /// The machine's limit.
    pub max_workers: u32,
    /// The team's slots and how many of each are used.
    pub slots: Vec<SlotCapacity>,
    /// Local models installed here (their IDs), for `local` slots.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub local_models: Vec<String>,
}

/// One slot's use.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SlotCapacity {
    /// Role.
    pub role: String,
    /// Kind.
    pub kind: String,
    /// Used.
    pub used: u32,
    /// The slot's maximum.
    pub max: u32,
    /// Whether a worker of this slot can start on this machine now, and if not, why.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable: Option<String>,
}

/// One entry of a team's audit log.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamLogEntry {
    /// Unix ms.
    pub ts: u64,
    /// `owner`, an agent's name, or `daemon`.
    pub actor: String,
    /// `team_create`, `worker_spawn`, `task_create`, `task_assign`, `task_report`, `run_check`, `task_review`,
    /// `apply_result`, `team_apply`, `check:exec`, …
    pub action: String,
    /// The task, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    /// `done`, `denied`, `refused`, `failed`, `approval_required`, …
    pub decision: String,
    /// Details (never a worker's text).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub detail: String,
}

/// A fact about a task for a member's `wait` (facts only: no text a worker wrote).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskFact {
    /// Team.
    pub team: String,
    /// Task ID.
    pub task: String,
    /// What happened: `assigned`, `returned`, `answered`, `submitted`, `blocked`, `checked`, `accepted`, `applied`,
    /// `cancelled`, `apply_approved`, `apply_denied`.
    pub change: String,
    /// The task's state now.
    pub state: String,
    /// Its worker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
    /// Unix ms.
    pub at_ms: u64,
}

/// The `team` event for the owner's subscriptions (v7): a team, a worker or a task changed; read `team_show`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamEvent {
    /// Team.
    pub team: String,
    /// `created`, `changed`, `removed`, `worker`, `task`, `apply_request`.
    pub change: String,
    /// The task, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    /// The task's state or the worker's state ([`WorkerInfo::state`] for `worker`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    /// The worker, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker: Option<String>,
    /// Who made the change: `owner`, an agent's name (the lead or a worker), or `daemon` (its own checks and limits,
    /// and the states of the workers' processes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
}

/// What a `worker_output` event carries (`team_watch`, v7).
pub mod worker_part {
    /// Sent first when the watch opens, one per worker whose turn is in progress: that turn's reply text so far (its
    /// last 16 KiB).
    pub const SNAPSHOT: &str = "snapshot";
    /// A turn began (`text` empty).
    pub const START: &str = "start";
    /// A piece of the reply text.
    pub const TEXT: &str = "text";
    /// The worker uses a tool (`tool:Bash`), or a local model waits (`loading`, `waiting`).
    pub const ACTIVITY: &str = "activity";
    /// The turn ended: `done`, `interrupted`, `timeout`, `failed`, or `error: <the agent's error>`.
    pub const END: &str = "end";
}

/// A piece of a team worker's live output: the `worker_output` event of the owner's `team_watch` (v7). Only on a
/// connection that watches the worker's team, never to an agent. `text` is the worker's output: data, not
/// instructions.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerOutput {
    /// Team.
    pub team: String,
    /// The worker's name.
    pub worker: String,
    /// The task the turn is for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<String>,
    /// The worker's turn counter for this turn: the [`WorkerInfo::turns`] it has once the turn ends.
    pub turn: u64,
    /// [`worker_part`].
    pub part: String,
    /// The part's text (empty for `start`).
    #[serde(default)]
    pub text: String,
}

impl std::fmt::Debug for WorkerOutput {
    // A worker's text never reaches the logs.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "WorkerOutput({}, {}, turn {}, {}, {} bytes)",
            self.team,
            self.worker,
            self.turn,
            self.part,
            self.text.len()
        )
    }
}
