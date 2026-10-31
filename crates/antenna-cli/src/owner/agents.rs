// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's agents: tokens, what they read, whose tasks they take, their connections (the agent map).

use antenna_proto::control::{AgentConnect, AgentDisconnect, Reply, Request};

use super::Owner;
use crate::client::CliResult;
use crate::{
    AgentAddArgs, AgentConnectArgs, AgentDisconnectArgs, AgentSetArgs, AgentTasksArgs,
    AgentTokenArgs, Pw,
};

/// `--x` / `--no-x` → `Some(true)` / `Some(false)`, neither → `None`.
fn flag(on: bool, off: bool) -> Option<bool> {
    match (on, off) {
        (true, _) => Some(true),
        (_, true) => Some(false),
        _ => None,
    }
}

/// `antenna agent connect`.
pub(super) async fn connect(o: &Owner, a: &AgentConnectArgs) -> CliResult<Reply> {
    o.call_pw(&a.pw, |password| {
        Request::AgentConnect(AgentConnect {
            name: a.name.clone(),
            contact: a.contact.clone().unwrap_or_default(),
            local: a.local.clone(),
            agent: a.agent.clone(),
            tasks: flag(a.tasks, a.no_tasks),
            peer_tasks: flag(a.peer_tasks, a.no_peer_tasks),
            ask: !a.here_only,
            password,
        })
    })
    .await
}

/// `antenna agent disconnect`.
pub(super) async fn disconnect(o: &Owner, a: &AgentDisconnectArgs) -> CliResult<Reply> {
    o.call(Request::AgentDisconnect(AgentDisconnect {
        name: a.name.clone(),
        contact: a.contact.clone(),
        local: a.local.clone(),
        agent: a.agent.clone(),
        tasks: a.no_tasks.then_some(false),
        peer_tasks: a.no_tasks.then_some(false),
        ask: !a.here_only,
    }))
    .await
}

/// `antenna agent add`.
pub(super) async fn add(o: &Owner, a: &AgentAddArgs) -> CliResult<Reply> {
    o.call_pw(&a.pw, |password| Request::AgentAdd {
        name: a.name.clone(),
        links: a.links.clone(),
        local_level: a.local_level,
        everyone: a.everyone,
        password,
        token_file: a.token_file,
    })
    .await
}

/// `antenna agent set`.
pub(super) async fn set(o: &Owner, a: &AgentSetArgs) -> CliResult<Reply> {
    let on = a.everyone == "on";
    // Widening what the agent reads needs the password; narrowing it does not
    let set = |password: Option<String>| Request::AgentSet {
        name: a.name.clone(),
        everyone: on,
        password,
    };
    if on {
        o.call_pw(&a.pw, |p| set(Some(p))).await
    } else {
        o.call(set(None)).await
    }
}

/// `antenna agent reset`.
pub(super) async fn reset(o: &Owner, name: &str, pw: &Pw) -> CliResult<Reply> {
    o.call_pw(pw, |password| Request::AgentReset {
        name: name.to_string(),
        password,
    })
    .await
}

/// `antenna agent token`.
pub(super) async fn token(o: &Owner, a: &AgentTokenArgs) -> CliResult<Reply> {
    o.call_pw(&a.pw, |password| Request::AgentToken {
        name: a.name.clone(),
        password,
        token_file: a.token_file,
    })
    .await
}

/// `antenna agent tasks`.
pub(super) async fn tasks(o: &Owner, a: &AgentTasksArgs) -> CliResult<Reply> {
    let contacts = if a.default {
        None
    } else if a.none {
        Some(Vec::new())
    } else {
        Some(a.from.clone())
    };
    o.call_pw(&a.pw, |password| Request::AgentTasks {
        name: a.name.clone(),
        contacts: contacts.clone(),
        password,
    })
    .await
}

/// `antenna agent escalate` (D-118): `None` is the owner.
pub(super) async fn escalate(
    o: &Owner,
    name: &str,
    to: &Option<String>,
    pw: &Pw,
) -> CliResult<Reply> {
    o.call_pw(pw, |password| Request::AgentEscalate {
        name: name.to_string(),
        to: to.clone(),
        password,
    })
    .await
}

/// `antenna agent remove`.
pub(super) async fn remove(o: &Owner, name: &str, pw: &Pw) -> CliResult<Reply> {
    o.call_pw(pw, |password| Request::AgentRemove {
        name: name.to_string(),
        password,
    })
    .await
}
