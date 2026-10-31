// SPDX-License-Identifier: AGPL-3.0-only
//! The owner CLI's commands (SPEC §12): one handler per command, grouped by area, and [`run`], whose arms are one line
//! per command. The agent CLI (`agent` in `main.rs`) has none of them: an agent's connection parses `AgentRequest`,
//! which has no owner commands (SPEC §9).

mod agents;
mod approvals;
pub(crate) mod chats;
mod devices;
pub(crate) mod doctor;
mod files;
mod links;
mod local;
mod messages;
mod node;
mod pairing;
pub(crate) mod pictures;
mod teams;
pub(crate) mod touch;
mod wake;

pub(crate) use teams::{TaskCommand, TeamCommand};
pub(crate) use wake::split_command;

use std::path::PathBuf;

use antenna_proto::control::{Reply, Request};

use crate::client::{Auth, CliResult, EXIT_NOPERM, Fail, call_owner, socket_path};
use crate::{
    AgentCommand, Cli, Command, FilesCommand, LanCommand, LocalCommand, OwnerKeyCommand,
    PairingCommand, WakeCommand,
};
use crate::{events, not_implemented};

/// What every owner command needs: where the daemon listens and whether the output is JSON.
pub(crate) struct Owner {
    path: PathBuf,
    json: bool,
}

impl Owner {
    /// One request, one reply, over an owner connection.
    async fn call(&self, req: Request) -> CliResult<Reply> {
        call_owner(&self.path, req).await.map(|(_, r)| r)
    }

    /// An owner command that takes the password: one touch first when Touch ID is on here (D-131), the password
    /// otherwise; [build] makes the request with the password it is given.
    async fn call_pw(&self, pw: &crate::Pw, build: impl Fn(String) -> Request) -> CliResult<Reply> {
        touch::call_pw(&self.path, pw, build).await
    }
}

/// Runs one owner command.
pub(crate) async fn run(cli: &Cli) -> CliResult<Reply> {
    let o = Owner {
        path: socket_path(&cli.socket, &cli.data_dir),
        json: cli.json,
    };
    match &cli.command {
        Command::Init { pw, key_backend } => node::init(&o, pw, *key_backend).await,
        Command::Unlock { pw } => node::unlock(&o, pw).await,
        Command::Lock => o.call(Request::Lock {}).await,
        Command::Login { pw } => node::login(&o, pw).await,
        Command::Logout => o.call(Request::Logout {}).await,
        Command::Status => o.call(Request::Status {}).await,
        Command::Lan { cmd } => match cmd {
            Some(LanCommand::On { pw }) => node::lan_on(&o, pw).await,
            Some(LanCommand::Off) => node::lan_off(&o).await,
            None | Some(LanCommand::Status) => o.call(Request::LanStatus {}).await,
        },
        Command::Invite(a) => pairing::invite(&o, a).await,
        Command::Join(a) => pairing::join(&o, a).await,
        Command::Pairing(p) => match &p.cmd {
            None | Some(PairingCommand::List) => pairing::list(&o, p).await,
            Some(PairingCommand::Confirm(a)) => pairing::confirm(&o, a).await,
            Some(PairingCommand::Cancel { id, pw }) => pairing::cancel(&o, id, pw).await,
        },
        Command::Contacts => o.call(Request::Contacts {}).await,
        Command::Trust(a) => links::trust(&o, a).await,
        Command::Revoke(a) => links::revoke(&o, a).await,
        Command::Rename { contact, label } => links::rename(&o, contact, label).await,
        Command::Rekey(a) => links::rekey(&o, a).await,
        Command::Verify(a) => links::verify(&o, a).await,
        Command::Approvals { all } => o.call(Request::Approvals { all: *all }).await,
        Command::Questions { all } => o.call(Request::Escalations { all: *all }).await,
        Command::Answer { id, text, dismiss } => {
            o.call(Request::EscalationAnswer {
                id: id.clone(),
                answer: text.clone(),
                dismiss: *dismiss,
            })
            .await
        }
        Command::Approve { ids, pw } => approvals::approve(&o, ids, pw).await,
        Command::Deny(a) => approvals::deny(&o, a).await,
        Command::Approver { cmd } => approvals::approver(&o, cmd.as_ref()).await,
        Command::Agent(a) => match a {
            AgentCommand::Add(a) => agents::add(&o, a).await,
            AgentCommand::Set(a) => agents::set(&o, a).await,
            AgentCommand::List => o.call(Request::AgentList {}).await,
            AgentCommand::Reset { name, pw } => agents::reset(&o, name, pw).await,
            AgentCommand::Token(a) => agents::token(&o, a).await,
            AgentCommand::Tasks(a) => agents::tasks(&o, a).await,
            AgentCommand::Remove { name, pw } => agents::remove(&o, name, pw).await,
            AgentCommand::Escalate { name, to, pw, .. } => agents::escalate(&o, name, to, pw).await,
            AgentCommand::Connect(a) => agents::connect(&o, a).await,
            AgentCommand::Disconnect(a) => agents::disconnect(&o, a).await,
            AgentCommand::Stop { name } => {
                o.call(Request::AgentStop(antenna_proto::control::AgentStop {
                    agent: name.clone(),
                }))
                .await
            }
            AgentCommand::Setup(_) => {
                unreachable!("antenna agent setup is handled by main::agent_setup")
            }
            AgentCommand::Traffic { days } => {
                o.call(Request::AgentTraffic(
                    antenna_proto::control::AgentTrafficReq { days: *days },
                ))
                .await
            }
        },
        Command::Send(s) => messages::send(&o, s).await,
        Command::Inbox(i) => messages::inbox(&o, i).await,
        Command::History(h) => messages::history(&o, h).await,
        Command::Log(l) => messages::log(&o, l).await,
        Command::Topics { contact } => messages::topics(&o, contact).await,
        Command::Chats(a) => chats::run(&o, a).await,
        Command::Picture(a) => pictures::run(&o, a).await,
        Command::Streams => o.call(Request::Streams {}).await,
        Command::Events => events(&o.path, &Auth::Owner, o.json).await,
        Command::Share(a) => files::share(&o, a).await,
        Command::Request { contact, path } => files::request(&o, contact, path).await,
        Command::Files(f) => match f {
            FilesCommand::Pending { contact, all } => files::pending(&o, contact, *all).await,
            FilesCommand::Preview { id, images } => files::preview(&o, id, images).await,
            FilesCommand::Accept(a) => files::accept(&o, a).await,
            FilesCommand::Reject { id } => files::reject(&o, id).await,
            FilesCommand::Withdraw { id } => files::withdraw(&o, id).await,
            FilesCommand::Allow {
                contact,
                entries,
                pw,
            } => files::allow(&o, contact, entries, pw).await,
            FilesCommand::Disallow { contact, entries } => {
                files::disallow(&o, contact, entries).await
            }
            FilesCommand::SaveTo {
                contact,
                folder,
                agent,
                clear,
                pw,
            } => files::save_to(&o, contact, folder.as_deref(), agent, *clear, pw).await,
        },
        Command::Wake(w) => match w {
            WakeCommand::Set(a) => wake::set(&o, a).await,
            WakeCommand::Say(a) => wake::say(&o, a).await,
            WakeCommand::Session(a) => wake::session(&o, a).await,
            WakeCommand::List => o.call(Request::WakeList {}).await,
            WakeCommand::Off { contact } => wake::off(&o, contact).await,
        },
        Command::Update(_) => unreachable!("antenna update is handled by update::run"),
        Command::Mcp { .. } => Err(mcp_is_for_agents()),
        Command::Chat { .. } => Err(not_implemented("chat", "TUI comes in v0.2")),
        Command::Rotate { .. } => Err(not_implemented("rotate", "key rotation is v0.3 (TZ §17)")),
        Command::Relay(_) => Err(not_implemented("relay set", "next slice")),
        Command::Doctor => unreachable!("antenna doctor is handled by owner::doctor::run"),
        Command::Connect(_) => unreachable!("antenna connect is handled by connect::run"),
        #[cfg(unix)]
        Command::Session(_) => unreachable!("antenna session is handled by session::run"),
        Command::Local(l) => match l {
            LocalCommand::Models => o.call(Request::LocalModels {}).await,
            LocalCommand::Install(a) => local::install(&o, a).await,
            LocalCommand::Remove { model } => {
                o.call(Request::ModelRemove {
                    model: model.clone(),
                })
                .await
            }
            LocalCommand::Add(a) => local::add(&o, a).await,
            LocalCommand::Say(a) => local::say(&o, a).await,
            LocalCommand::History {
                agent,
                limit,
                before,
            } => {
                o.call(Request::LocalHistory {
                    agent: agent.clone(),
                    limit: Some(*limit),
                    before: *before,
                })
                .await
            }
            LocalCommand::Session { agent, action } => {
                o.call(Request::LocalSession {
                    agent: agent.clone(),
                    action: action.clone(),
                })
                .await
            }
        },
        Command::Team(c) => teams::team(&o, c).await,
        Command::Task(c) => teams::task(&o, c).await,
        Command::OwnerKey(OwnerKeyCommand::List) => o.call(Request::OwnerKeyList {}).await,
        Command::Devices { cmd } => devices::run(&o, cmd).await,
        Command::OwnerKey(OwnerKeyCommand::Remove { key_id }) => {
            o.call(Request::OwnerKeyRemove {
                key_id: key_id.clone(),
            })
            .await
        }
    }
}

/// `antenna mcp` without an agent token: say where the token comes from.
fn mcp_is_for_agents() -> Fail {
    Fail::new(
        EXIT_NOPERM,
        "token_invalid",
        "antenna mcp runs for an agent: the owner issues a token with `antenna agent add <name> --token-file`, the \
         agent's MCP config runs `antenna mcp --token-file <path>` (or passes the token as ANTENNA_AGENT_TOKEN)",
    )
}
