// SPDX-License-Identifier: AGPL-3.0-only
//! Teams of agents for the owner (CONTROL §25, D-111, experimental): `antenna team …` and `antenna task …`. Creating a
//! team, changing its budget or template, and applying its work to the project's branch ask for the owner password;
//! the rest needs an owner session. The agent CLI has none of these (an agent's `antenna team`/`antenna task` are its
//! own commands, `agent_teams.rs`).

use antenna_proto::control::{
    ClientMsg, Event, NoArgs, Reply, Request, ServerMsg, TaskAssign, TaskListReq, TaskNew, TaskRef,
    TaskReviewReq, TeamAddWorker, TeamApply, TeamCreate, TeamLogReq, TeamRef, TeamSet, TeamSlot,
    TeamStop, TeamTemplate,
};
use clap::{Args, Subcommand};

use super::Owner;
use crate::client::{Auth, CliResult, Conn, EXIT_FAIL, EXIT_USAGE, Fail, explain_forced};
use crate::{Pw, output, parse_duration};

/// `antenna team …` (owner).
#[derive(Debug, Subcommand)]
pub(crate) enum TeamCommand {
    /// Create a team on a git repository of this computer (asks for the owner password): its lead, a budget of
    /// worker slots and what workers may do. The lead then creates workers within the budget.
    Create(TeamCreateArgs),
    /// The teams.
    List,
    /// A team: its workers, tasks, the integration branch and a pending apply request.
    Show {
        /// Team.
        team: String,
    },
    /// Change a team's lead, budget or template (asks for the owner password). Options not given stay as they are.
    Set(TeamSetArgs),
    /// Add a worker within the budget, as the lead would.
    AddWorker {
        /// Team.
        team: String,
        /// Role (`coder`, `tester`, `docs`, …).
        role: String,
        /// Kind (`claude`, `program`, `local`); default: the first slot of the role with room.
        #[arg(long)]
        kind: Option<String>,
    },
    /// Stop the team's workers (or one): their processes end and their tokens stop working. No password: it only
    /// takes work away.
    Stop {
        /// Team.
        team: String,
        /// Only this worker.
        #[arg(long)]
        worker: Option<String>,
    },
    /// Remove a team: its workers, their folders and the branches of unapplied tasks. The project and the team's
    /// integration branch stay.
    Remove {
        /// Team.
        team: String,
        /// Confirm.
        #[arg(long)]
        yes: bool,
    },
    /// Merge the team's integration branch into the project's branch (asks for the owner password: this is your
    /// approval).
    Apply {
        /// Team.
        team: String,
        /// Only if the integration branch is still at this commit (what you reviewed).
        #[arg(long)]
        commit: Option<String>,
        #[command(flatten)]
        pw: Pw,
    },
    /// The team's audit log.
    Log {
        /// Team.
        team: String,
        /// How many of the latest entries.
        #[arg(long, default_value_t = 100)]
        limit: u32,
    },
    /// The machines' capacity for the team: per machine its sandbox and workers, per slot how many are used.
    Capacity {
        /// Team.
        team: String,
    },
    /// Watch the team's workers live: what each one writes and the tools it uses, turn by turn. Runs until Ctrl+C.
    Watch {
        /// Team.
        team: String,
    },
}

/// `antenna task …` (owner).
#[derive(Debug, Subcommand)]
pub(crate) enum TaskCommand {
    /// Write a task for a team.
    New {
        /// Team.
        team: String,
        /// Title.
        title: String,
        /// What done means.
        #[arg(long, default_value = "")]
        brief: String,
        /// The check command (one of the team's `--check` commands).
        #[arg(long)]
        check: Option<String>,
        /// Assign it to this worker at once.
        #[arg(long)]
        assign: Option<String>,
    },
    /// A team's tasks.
    List {
        /// Team.
        team: String,
    },
    /// One task in full.
    Show {
        /// Task ID (6+ characters).
        id: String,
    },
    /// What a task's result changes.
    Diff {
        /// Task ID.
        id: String,
    },
    /// Review a task: accept it, ask for changes (or answer a blocked worker), or cancel it.
    Review {
        /// Task ID.
        id: String,
        /// `accept`, `changes`, `cancel`.
        #[arg(value_parser = ["accept", "changes", "cancel"])]
        verdict: String,
        /// Comments for the worker.
        #[arg(long, default_value = "")]
        comments: String,
        /// With `changes`: interrupt the worker's turn now and give it the task with the comments (experimental),
        /// also while it works on it.
        #[arg(long)]
        urgent: bool,
    },
    /// Merge an accepted task into the team's integration branch.
    Apply {
        /// Task ID.
        id: String,
    },
    /// Assign a task to a worker of its team (a worker takes one task at a time).
    Assign {
        /// Task ID.
        id: String,
        /// The worker's name.
        worker: String,
    },
}

/// The budget and template options of `team create` and `team set`.
#[derive(Debug, Args)]
pub(crate) struct TemplateArgs {
    /// A worker slot: `ROLE:KIND:MAX[:REST]`, REST being the command for `claude` and `program`
    /// (`coder:claude:2:claude --model haiku`) or the model for `local` (`docs:local:1:qwen3.5-9b`). Repeatable.
    #[arg(long = "slot", value_name = "ROLE:KIND:MAX[:REST]")]
    slots: Vec<String>,
    /// At most this many workers at once (default: the sum of the slots).
    #[arg(long)]
    max_workers: Option<u32>,
    /// A check command tasks may name (`cargo test`, `pytest -q`). Repeatable.
    #[arg(long = "check", value_name = "COMMAND")]
    checks: Vec<String>,
    /// A host checks may reach through the daemon's proxy (a package registry). Repeatable.
    #[arg(long = "check-host", value_name = "HOST")]
    check_hosts: Vec<String>,
    /// A read-only folder checks need (a toolchain). Repeatable.
    #[arg(long = "check-path", value_name = "PATH")]
    check_paths: Vec<String>,
    /// `NAME=value` for checks (no secrets). Repeatable.
    #[arg(long = "check-env", value_name = "NAME=VALUE")]
    check_env: Vec<String>,
    /// Time limit of one check, e.g. `10m`.
    #[arg(long)]
    check_timeout: Option<String>,
    /// How often a failed check sends a result back to its worker before the lead decides.
    #[arg(long)]
    check_retries: Option<u32>,
    /// Time limit of one worker turn, e.g. `30m`.
    #[arg(long)]
    turn_timeout: Option<String>,
    /// Tokens one task may use (0: no limit).
    #[arg(long)]
    max_task_tokens: Option<u64>,
    /// Workers run no commands at all (they still edit files in their folders).
    #[arg(long)]
    no_commands: bool,
    /// Workers may run commands again (`team set`).
    #[arg(long, conflicts_with = "no_commands")]
    commands: bool,
    /// Who applies the team's work to the project's branch: `owner` (default) or `lead`.
    #[arg(long, value_parser = ["owner", "lead"])]
    apply: Option<String>,
    /// Only local models may work here (no cloud worker, no cloud lead).
    #[arg(long)]
    local_only: bool,
}

/// `antenna team create`.
#[derive(Debug, Args)]
pub(crate) struct TeamCreateArgs {
    /// Team name (`[a-z0-9-]`, 1–24).
    name: String,
    /// The project: a git repository on this computer.
    #[arg(long)]
    project: std::path::PathBuf,
    /// The lead: one of your agents (`antenna agent list`); without it you lead in person.
    #[arg(long)]
    lead: Option<String>,
    /// The project's branch the team's work goes to (default: the branch checked out there).
    #[arg(long)]
    target: Option<String>,
    #[command(flatten)]
    t: TemplateArgs,
    #[command(flatten)]
    pw: Pw,
}

/// `antenna team set`.
#[derive(Debug, Args)]
pub(crate) struct TeamSetArgs {
    /// Team.
    team: String,
    /// A new lead.
    #[arg(long, conflicts_with = "no_lead")]
    lead: Option<String>,
    /// Lead the team in person.
    #[arg(long)]
    no_lead: bool,
    /// Replace the budget with the `--slot` options given.
    #[arg(long)]
    replace_slots: bool,
    #[command(flatten)]
    t: TemplateArgs,
    #[command(flatten)]
    pw: Pw,
}

fn usage(m: impl Into<String>) -> Fail {
    Fail::new(EXIT_USAGE, "bad_request", m)
}

/// `ROLE:KIND:MAX[:REST]`.
fn parse_slot(s: &str) -> CliResult<TeamSlot> {
    let mut parts = s.splitn(4, ':');
    let role = parts.next().unwrap_or("").to_string();
    let kind = parts.next().unwrap_or("").to_string();
    let max: u32 = parts
        .next()
        .unwrap_or("")
        .parse()
        .map_err(|_| usage(format!("--slot {s:?}: ROLE:KIND:MAX[:REST], MAX a number")))?;
    let rest = parts.next().map(str::trim).filter(|r| !r.is_empty());
    let (argv, model) = match (kind.as_str(), rest) {
        ("local", r) => (Vec::new(), r.map(str::to_string)),
        (_, Some(r)) => (super::wake::split_command(r)?, None),
        (_, None) => (Vec::new(), None),
    };
    Ok(TeamSlot {
        role,
        kind,
        model,
        max,
        argv,
        hosts: Vec::new(),
    })
}

/// The template options on top of `base`.
fn template(t: &TemplateArgs, mut base: TeamTemplate) -> CliResult<TeamTemplate> {
    if !t.checks.is_empty() {
        base.checks = t
            .checks
            .iter()
            .map(|c| super::wake::split_command(c))
            .collect::<CliResult<_>>()?;
    }
    if !t.check_hosts.is_empty() {
        base.check_hosts = t.check_hosts.clone();
    }
    if !t.check_paths.is_empty() {
        base.check_paths = t
            .check_paths
            .iter()
            .map(|p| crate::absolute_path(std::path::Path::new(p)))
            .collect::<CliResult<_>>()?;
    }
    if !t.check_env.is_empty() {
        base.check_env = t.check_env.clone();
    }
    if let Some(d) = &t.check_timeout {
        base.check_timeout_secs = parse_duration(d)?.as_secs().max(1);
    }
    if let Some(n) = t.check_retries {
        base.check_retries = n;
    }
    if let Some(d) = &t.turn_timeout {
        base.turn_timeout_secs = parse_duration(d)?.as_secs().max(1);
    }
    if let Some(n) = t.max_task_tokens {
        base.max_task_tokens = n;
    }
    if t.no_commands {
        base.commands = false;
    }
    if t.commands {
        base.commands = true;
    }
    if let Some(a) = &t.apply {
        base.apply = a.clone();
    }
    if t.local_only {
        base.local_only = true;
    }
    Ok(base)
}

/// Runs one `antenna team …` command.
pub(super) async fn team(o: &Owner, c: &TeamCommand) -> CliResult<Reply> {
    match c {
        TeamCommand::Create(a) => create(o, a).await,
        TeamCommand::List => o.call(Request::TeamList(NoArgs {})).await,
        TeamCommand::Show { team } => {
            o.call(Request::TeamShow(TeamRef { team: team.clone() }))
                .await
        }
        TeamCommand::Set(a) => set(o, a).await,
        TeamCommand::AddWorker { team, role, kind } => {
            o.call(Request::TeamAddWorker(TeamAddWorker {
                team: team.clone(),
                role: role.clone(),
                kind: kind.clone(),
            }))
            .await
        }
        TeamCommand::Stop { team, worker } => {
            o.call(Request::TeamStop(TeamStop {
                team: team.clone(),
                worker: worker.clone(),
            }))
            .await
        }
        TeamCommand::Remove { team, yes } => {
            if !yes {
                return Err(usage(format!(
                    "removing {team} deletes its workers, their folders and the branches of unapplied tasks: \
                     add --yes"
                )));
            }
            o.call(Request::TeamRemove(TeamRef { team: team.clone() }))
                .await
        }
        TeamCommand::Apply { team, commit, pw } => apply(o, team, commit.clone(), pw).await,
        TeamCommand::Log { team, limit } => {
            o.call(Request::TeamLog(TeamLogReq {
                team: team.clone(),
                limit: Some(*limit),
            }))
            .await
        }
        TeamCommand::Capacity { team } => {
            o.call(Request::TeamCapacity(TeamRef { team: team.clone() }))
                .await
        }
        TeamCommand::Watch { team } => watch(o, team).await,
    }
}

/// `team watch`: the workers' output as it comes (`--json`: one event per line), until Ctrl+C or the daemon ends the
/// watch (the team was removed, the keys locked, the session ended).
async fn watch(o: &Owner, team: &str) -> CliResult<Reply> {
    use std::io::Write as _;
    let mut c = Conn::open(&o.path, &Auth::Owner).await?;
    c.send(&ClientMsg::Req(Request::TeamWatch(TeamRef {
        team: team.into(),
    })))
    .await?;
    let mut view = output::WatchView::default();
    loop {
        let shown = match c.recv().await? {
            ServerMsg::Event(e) if o.json => {
                output::print_json(&e);
                continue;
            }
            ServerMsg::Event(Event::WorkerOutput(w)) => view.render(&w),
            ServerMsg::Event(Event::Lagged { missed }) => view.lagged(missed),
            ServerMsg::Event(_) | ServerMsg::HelloOk(_) => continue,
            ServerMsg::Ok(r) => return Ok(r),
            ServerMsg::Err(e) => return Err(explain_forced(&c.hello, Fail::from_daemon(e))),
        };
        let mut out = std::io::stdout();
        let _ = out.write_all(shown.as_bytes());
        let _ = out.flush();
    }
}

async fn create(o: &Owner, a: &TeamCreateArgs) -> CliResult<Reply> {
    let slots =
        a.t.slots
            .iter()
            .map(|s| parse_slot(s))
            .collect::<CliResult<Vec<_>>>()?;
    let template = template(&a.t, TeamTemplate::default())?;
    let project = crate::absolute_path(&a.project)?;
    o.call_pw(&a.pw, |password| {
        Request::TeamCreate(Box::new(TeamCreate {
            name: a.name.clone(),
            project: project.clone(),
            lead: a.lead.clone(),
            slots: slots.clone(),
            max_workers: a.t.max_workers,
            template: template.clone(),
            target: a.target.clone(),
            password,
        }))
    })
    .await
}

async fn set(o: &Owner, a: &TeamSetArgs) -> CliResult<Reply> {
    let Reply::Team(now) = o
        .call(Request::TeamShow(TeamRef {
            team: a.team.clone(),
        }))
        .await?
    else {
        return Err(Fail::new(EXIT_FAIL, "internal", "unexpected reply"));
    };
    let mut slots = if a.replace_slots {
        Vec::new()
    } else {
        now.slots.clone()
    };
    for s in &a.t.slots {
        slots.push(parse_slot(s)?);
    }
    let template = template(&a.t, now.template.clone())?;
    o.call_pw(&a.pw, |password| {
        Request::TeamSet(Box::new(TeamSet {
            team: a.team.clone(),
            lead: if a.no_lead {
                Some(String::new())
            } else {
                a.lead.clone()
            },
            slots: Some(slots.clone()),
            max_workers: a.t.max_workers,
            template: Some(template.clone()),
            password,
        }))
    })
    .await
}

/// `team apply`: show what goes in, then ask for the password.
async fn apply(o: &Owner, team: &str, commit: Option<String>, pw: &Pw) -> CliResult<Reply> {
    let commit = match commit {
        Some(c) => Some(c),
        None => {
            let Reply::Team(now) = o
                .call(Request::TeamShow(TeamRef { team: team.into() }))
                .await?
            else {
                return Err(Fail::new(EXIT_FAIL, "internal", "unexpected reply"));
            };
            if !o.json {
                eprintln!(
                    "Applying {} ({}) to {} of {}.",
                    now.integration,
                    now.integration_commit
                        .as_deref()
                        .map_or("?", |c| &c[..12.min(c.len())]),
                    now.target,
                    crate::output::clean(&now.project)
                );
            }
            now.integration_commit
        }
    };
    o.call_pw(pw, |password| {
        Request::TeamApply(TeamApply {
            team: team.into(),
            commit: commit.clone(),
            password,
        })
    })
    .await
}

/// Runs one `antenna task …` command (owner).
pub(super) async fn task(o: &Owner, c: &TaskCommand) -> CliResult<Reply> {
    match c {
        TaskCommand::New {
            team,
            title,
            brief,
            check,
            assign,
        } => {
            o.call(Request::TaskNew(TaskNew {
                team: Some(team.clone()),
                title: title.clone(),
                brief: brief.clone(),
                check: match check {
                    Some(c) => super::wake::split_command(c)?,
                    None => Vec::new(),
                },
                assignee: assign.clone(),
            }))
            .await
        }
        TaskCommand::List { team } => {
            o.call(Request::TaskList(TaskListReq { team: team.clone() }))
                .await
        }
        TaskCommand::Show { id } => o.call(Request::TaskShow(TaskRef { id: id.clone() })).await,
        TaskCommand::Diff { id } => o.call(Request::TaskDiff(TaskRef { id: id.clone() })).await,
        TaskCommand::Review {
            id,
            verdict,
            comments,
            urgent,
        } => {
            o.call(Request::TaskReview(TaskReviewReq {
                id: id.clone(),
                verdict: verdict.clone(),
                comments: comments.clone(),
                urgent: *urgent,
            }))
            .await
        }
        TaskCommand::Apply { id } => o.call(Request::TaskApply(TaskRef { id: id.clone() })).await,
        TaskCommand::Assign { id, worker } => {
            o.call(Request::TaskAssign(TaskAssign {
                id: id.clone(),
                worker: worker.clone(),
            }))
            .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slots_from_the_command_line() {
        let s = parse_slot("coder:claude:2:claude --model haiku")
            .ok()
            .unwrap();
        assert_eq!(
            (s.role.as_str(), s.kind.as_str(), s.max),
            ("coder", "claude", 2)
        );
        assert_eq!(s.argv, vec!["claude", "--model", "haiku"]);
        let s = parse_slot("docs:local:1:qwen3.5-9b").ok().unwrap();
        assert_eq!(s.model.as_deref(), Some("qwen3.5-9b"));
        assert!(s.argv.is_empty());
        let s = parse_slot("tester:program:1:'/opt/my agent/run' --fast")
            .ok()
            .unwrap();
        assert_eq!(s.argv, vec!["/opt/my agent/run", "--fast"]);
        assert!(parse_slot("coder:claude:x").is_err());
        assert!(parse_slot("coder").is_err());
    }
}
