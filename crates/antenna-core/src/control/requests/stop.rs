// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's stop switch (CONTROL §33, PG-58): the terminal session an agent runs in, stopping an agent and the
//! processes it started, here or on an own computer.

use antenna_proto::control::{AgentStop, AgentTerminal, DeviceAgentStop, Reply};

use super::{Answer, b, session};
use crate::control::OwnerCtx;
use crate::node::Node;

/// `agent_terminal`: checked against the client's own process tree, no owner session needed.
pub(crate) async fn terminal(node: &Node, ctx: &OwnerCtx, r: AgentTerminal) -> Answer {
    session(node)
        .await?
        .agent_terminal(&r.agent, r.pid, ctx.chain.as_deref())
        .map_err(b)?;
    Ok(Reply::Done {
        state: "noted".into(),
    })
}

/// `agent_stop`.
pub(crate) async fn stop(node: &Node, ctx: &OwnerCtx, r: AgentStop) -> Answer {
    Ok(Reply::AgentStopped(
        session(node)
            .await?
            .agent_stop(&r.agent, "owner", ctx.chain.as_deref())
            .await
            .map_err(b)?,
    ))
}

/// `device_agent_stop`.
pub(crate) async fn device_stop(node: &Node, r: DeviceAgentStop) -> Answer {
    Ok(Reply::AgentStopped(
        session(node)
            .await?
            .device_agent_stop(&r.contact, &r.agent)
            .await
            .map_err(b)?,
    ))
}
