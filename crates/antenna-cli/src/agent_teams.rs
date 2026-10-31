// SPDX-License-Identifier: AGPL-3.0-only
//! Teams for an agent (CONTROL §25, D-111): `antenna team info`, `antenna task …`, `antenna worker …` with an agent
//! token, the same commands the MCP server offers. The daemon decides who may call what (the lead, a worker of the
//! team); none of the owner's team commands exist here, so `antenna team create` with a token is "no such command".

use antenna_proto::control::{
    AgentRequest, ApplyResultReq, NoArgs, TaskAssign, TaskNew, TaskNoteReq, TaskRef, TaskReportReq,
    TaskReviewReq, WorkerSpawn, WorkerStop,
};
use clap::Subcommand;

use crate::client::CliResult;

/// `antenna team …` (agent).
#[derive(Debug, Subcommand)]
pub(crate) enum AgentTeamCommand {
    /// Your team: its lead, rules and your tasks (a worker sees only its own).
    Info,
    /// The lead: the machines' capacity for the team (facts only).
    Capacity,
}

/// `antenna task …` (agent).
#[derive(Debug, Subcommand)]
pub(crate) enum AgentTaskCommand {
    /// Tasks: the lead's are all of the team's, a worker's only its own.
    List,
    /// One task in full (a worker: only its own).
    Get {
        /// Task ID.
        id: String,
    },
    /// The lead: write a task (it carries your session's ceiling).
    Create {
        /// Title.
        title: String,
        /// What done means.
        #[arg(long, default_value = "")]
        brief: String,
        /// The check command (one of the team's).
        #[arg(long)]
        check: Option<String>,
        /// Assign it at once.
        #[arg(long)]
        assign: Option<String>,
    },
    /// The lead: assign a task to a worker.
    Assign {
        /// Task ID.
        id: String,
        /// The worker's name.
        worker: String,
    },
    /// The lead: accept a result, ask for changes (or answer a question), or cancel.
    Review {
        /// Task ID.
        id: String,
        /// `accept`, `changes`, `cancel`.
        #[arg(value_parser = ["accept", "changes", "cancel"])]
        verdict: String,
        /// Comments for the worker.
        #[arg(long, default_value = "")]
        comments: String,
    },
    /// What a result changes (a worker: its own folder as it is now).
    Diff {
        /// Task ID.
        id: String,
    },
    /// Read a task's notes, or replace them with `--set`.
    Note {
        /// Task ID.
        id: String,
        /// The new notes.
        #[arg(long)]
        set: Option<String>,
    },
    /// A worker: report on your task (`working`, `blocked` with a question, `submitted` with a summary).
    Report {
        /// Task ID.
        id: String,
        /// `working`, `blocked`, `submitted`.
        #[arg(value_parser = ["working", "blocked", "submitted"])]
        state: String,
        /// The note, the question or the summary.
        #[arg(long, default_value = "")]
        summary: String,
    },
    /// Run the task's check in the check sandbox (a worker: in its folder; the lead: on the submitted result).
    Check {
        /// Task ID.
        id: String,
    },
    /// The lead: merge an accepted task into the integration branch, or (`--target`) ask to apply the team's work to
    /// the project's branch.
    Apply {
        /// Task ID.
        id: Option<String>,
        /// The integration branch into the project's branch.
        #[arg(long, conflicts_with = "id")]
        target: bool,
    },
}

/// `antenna worker …` (the lead).
#[derive(Debug, Subcommand)]
pub(crate) enum AgentWorkerCommand {
    /// Fill a slot of the team's budget; prints the worker's name (never a token).
    Spawn {
        /// Role.
        role: String,
        /// Kind.
        #[arg(long)]
        kind: Option<String>,
    },
    /// Stop a worker.
    Stop {
        /// The worker's name.
        name: String,
    },
}

/// The request of `antenna team …`.
pub(crate) fn team_request(c: &AgentTeamCommand) -> AgentRequest {
    match c {
        AgentTeamCommand::Info => AgentRequest::TeamInfo(NoArgs {}),
        AgentTeamCommand::Capacity => AgentRequest::Capacity(NoArgs {}),
    }
}

/// The request of `antenna task …`.
pub(crate) fn task_request(c: &AgentTaskCommand) -> CliResult<AgentRequest> {
    Ok(match c {
        AgentTaskCommand::List => AgentRequest::TaskList(NoArgs {}),
        AgentTaskCommand::Get { id } => AgentRequest::TaskGet(TaskRef { id: id.clone() }),
        AgentTaskCommand::Create {
            title,
            brief,
            check,
            assign,
        } => AgentRequest::TaskCreate(TaskNew {
            team: None,
            title: title.clone(),
            brief: brief.clone(),
            check: match check {
                Some(c) => crate::owner::split_command(c)?,
                None => Vec::new(),
            },
            assignee: assign.clone(),
        }),
        AgentTaskCommand::Assign { id, worker } => AgentRequest::TaskAssign(TaskAssign {
            id: id.clone(),
            worker: worker.clone(),
        }),
        AgentTaskCommand::Review {
            id,
            verdict,
            comments,
        } => AgentRequest::TaskReview(TaskReviewReq {
            id: id.clone(),
            verdict: verdict.clone(),
            comments: comments.clone(),
            // Only the owner interrupts a worker (PG-58)
            urgent: false,
        }),
        AgentTaskCommand::Diff { id } => AgentRequest::TaskDiff(TaskRef { id: id.clone() }),
        AgentTaskCommand::Note { id, set } => AgentRequest::TaskNote(TaskNoteReq {
            id: id.clone(),
            text: set.clone(),
        }),
        AgentTaskCommand::Report { id, state, summary } => {
            AgentRequest::TaskReport(TaskReportReq {
                id: id.clone(),
                state: state.clone(),
                summary: summary.clone(),
            })
        }
        AgentTaskCommand::Check { id } => AgentRequest::RunCheck(TaskRef { id: id.clone() }),
        AgentTaskCommand::Apply { id, target } => AgentRequest::ApplyResult(ApplyResultReq {
            id: id.clone(),
            target: *target,
        }),
    })
}

/// The request of `antenna worker …`.
pub(crate) fn worker_request(c: &AgentWorkerCommand) -> AgentRequest {
    match c {
        AgentWorkerCommand::Spawn { role, kind } => AgentRequest::WorkerSpawn(WorkerSpawn {
            role: role.clone(),
            kind: kind.clone(),
        }),
        AgentWorkerCommand::Stop { name } => {
            AgentRequest::WorkerStop(WorkerStop { name: name.clone() })
        }
    }
}
