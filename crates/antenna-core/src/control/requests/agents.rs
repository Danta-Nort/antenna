// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's agents (CONTROL §4, §5): tokens and token files (D-86), what they read (D-91), whose tasks they take
//! (D-88), and their connections on the agent map (CONTROL §30).

use antenna_proto::control::{AgentConnect, AgentDisconnect, AgentTrafficReq, Reply};

use super::{Answer, b, session};
use crate::node::Node;

/// `agent_add`.
pub(crate) async fn add(
    node: &Node,
    name: String,
    links: Option<Vec<String>>,
    local_level: u8,
    everyone: bool,
    token_file: bool,
) -> Answer {
    let (token, token_file) = session(node)
        .await?
        .agent_add(&name, links, local_level, everyone, token_file)
        .map_err(b)?;
    Ok(Reply::AgentAdded {
        name,
        token: antenna_proto::control::SecretString(token.to_string()),
        token_file,
    })
}

/// `agent_set`.
pub(crate) async fn set(node: &Node, name: String, everyone: bool) -> Answer {
    Ok(Reply::Agents {
        agents: session(node).await?.agent_set(&name, everyone).map_err(b)?,
    })
}

/// `agent_list`.
pub(crate) async fn list(node: &Node) -> Answer {
    Ok(Reply::Agents {
        agents: session(node).await?.agent_list().map_err(b)?,
    })
}

/// `agent_reset`.
pub(crate) async fn reset(node: &Node, name: String) -> Answer {
    Ok(Reply::Agents {
        agents: vec![session(node).await?.agent_reset(&name).map_err(b)?],
    })
}

/// `agent_token`.
pub(crate) async fn token(node: &Node, name: String, token_file: bool) -> Answer {
    let (token, token_file) = session(node)
        .await?
        .agent_token(&name, token_file)
        .map_err(b)?;
    Ok(Reply::AgentAdded {
        name,
        token: antenna_proto::control::SecretString(token.to_string()),
        token_file,
    })
}

/// `agent_tasks`.
pub(crate) async fn tasks(node: &Node, name: String, contacts: Option<Vec<String>>) -> Answer {
    Ok(Reply::Agents {
        agents: vec![
            session(node)
                .await?
                .agent_tasks(&name, contacts)
                .map_err(b)?,
        ],
    })
}

/// `agent_escalate` (D-118).
pub(crate) async fn escalate_to(node: &Node, name: String, to: Option<String>) -> Answer {
    Ok(Reply::Agents {
        agents: vec![
            session(node)
                .await?
                .agent_escalate_to(&name, to)
                .map_err(b)?,
        ],
    })
}

/// `escalations` (D-118).
pub(crate) async fn escalations(node: &Node, all: bool) -> Answer {
    Ok(Reply::Escalations(
        antenna_proto::control::EscalationsReply {
            escalations: session(node).await?.escalations(all).map_err(b)?,
        },
    ))
}

/// `escalation_answer` (D-118).
pub(crate) async fn escalation_answer(
    node: &Node,
    id: String,
    answer: Option<String>,
    dismiss: bool,
) -> Answer {
    Ok(Reply::Escalation(
        session(node)
            .await?
            .escalation_answer(&id, answer, dismiss)
            .map_err(b)?,
    ))
}

/// `agent_remove`.
pub(crate) async fn remove(node: &Node, name: String) -> Answer {
    session(node).await?.agent_remove(&name).map_err(b)?;
    Ok(Reply::Done {
        state: format!("agent {name} removed"),
    })
}

/// `agent_connect` (the password was checked in `authorize`).
pub(crate) async fn connect(node: &Node, req: AgentConnect) -> Answer {
    Ok(Reply::AgentConnected(Box::new(
        session(node).await?.agent_connect(&req).await.map_err(b)?,
    )))
}

/// `agent_disconnect`.
pub(crate) async fn disconnect(node: &Node, req: AgentDisconnect) -> Answer {
    Ok(Reply::AgentConnected(Box::new(
        session(node)
            .await?
            .agent_disconnect(&req)
            .await
            .map_err(b)?,
    )))
}

/// `agent_traffic`.
pub(crate) async fn traffic(node: &Node, req: AgentTrafficReq) -> Answer {
    Ok(Reply::AgentTraffic(
        session(node).await?.agent_traffic(req.days).map_err(b)?,
    ))
}
