// SPDX-License-Identifier: AGPL-3.0-only
//! Local models and local agents (CONTROL §24, D-104). `local_say` is a dialog and stays in `control.rs`.

use antenna_proto::control::Reply;

use super::{Answer, b, session};
use crate::node::Node;

/// `local_models`.
pub(crate) async fn models(node: &Node) -> Answer {
    let s = session(node).await?;
    s.local_models().map(Reply::LocalModels).map_err(b)
}

/// `model_install`: the reply comes at once; the download or check reports through `local_model` events.
pub(crate) async fn install(node: &Node, model: String, from_file: Option<String>) -> Answer {
    let s = session(node).await?;
    s.model_install(&model, from_file.as_deref())
        .map(Reply::LocalModel)
        .map_err(b)
}

/// `model_remove`.
pub(crate) async fn remove(node: &Node, model: String) -> Answer {
    let s = session(node).await?;
    s.model_remove(&model)
        .await
        .map(Reply::LocalModel)
        .map_err(b)
}

/// `local_agent_add` (the password was checked in `owner`).
pub(crate) async fn agent_add(node: &Node, name: String, model: String) -> Answer {
    let s = session(node).await?;
    s.local_agent_add(&name, &model)
        .map(Reply::LocalAgent)
        .map_err(b)
}

/// `local_history`.
pub(crate) async fn history(
    node: &Node,
    agent: String,
    limit: Option<u32>,
    before: Option<i64>,
) -> Answer {
    let s = session(node).await?;
    s.local_history(&agent, limit, before)
        .map(Reply::LocalHistory)
        .map_err(b)
}

/// `local_session`.
pub(crate) async fn local_session(node: &Node, agent: String, action: String) -> Answer {
    let s = session(node).await?;
    s.local_session(&agent, &action)
        .await
        .map(Reply::LocalAgent)
        .map_err(b)
}
