// SPDX-License-Identifier: AGPL-3.0-only
//! Agent wake (CONTROL §16) and resident sessions (CONTROL §21).

use antenna_proto::control::{Reply, Request};

use super::{Answer, b, session};
use crate::error::Error;
use crate::node::Node;

/// `wake_set` (the password was checked in `owner`).
pub(crate) async fn set(node: &Node, req: Request) -> Answer {
    let Request::WakeSet {
        contact,
        argv,
        agent,
        timeout_secs,
        allow_hosts,
        home_files,
        max_runs_per_hour,
        secret_env,
        resident,
        idle_stop_secs,
        compact_idle_secs,
        compact_above_tokens,
        project,
        tool_paths,
        env,
        ..
    } = req
    else {
        return Err(Error::internal("not a wake_set").body());
    };
    let s = session(node).await?;
    s.wake_set(crate::wake::WakeSetArgs {
        resident: resident.then_some(crate::wake::ResidentArgs {
            idle_stop_secs,
            compact_idle_secs,
            compact_above_tokens,
        }),
        project,
        tool_paths,
        env,
        contact,
        argv,
        agent,
        timeout_secs,
        allow_hosts,
        home_files,
        max_runs_per_hour,
        secret_env: secret_env
            .into_iter()
            .map(|e| (e.name, zeroize::Zeroizing::new(e.value.0)))
            .collect(),
    })
    .map_err(b)?;
    s.wake_list().map_err(b)
}

/// `wake_list`.
pub(crate) async fn list(node: &Node) -> Answer {
    session(node).await?.wake_list().map_err(b)
}

/// `wake_off`.
pub(crate) async fn off(node: &Node, contact: String) -> Answer {
    let s = session(node).await?;
    s.wake_off(&contact).await.map_err(b)?;
    s.wake_list().map_err(b)
}

/// `wake_session` (with `reset`, the password was checked in `owner`).
pub(crate) async fn resident_session(node: &Node, contact: String, action: String) -> Answer {
    let s = session(node).await?;
    let resident = s.resident_session(&contact, &action).await.map_err(b)?;
    Ok(Reply::ResidentSession { contact, resident })
}
