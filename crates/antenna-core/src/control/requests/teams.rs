// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's team commands (CONTROL §25, D-111): creating and changing teams (the password), showing them, adding
//! and stopping workers, removing a team, applying the integration branch (the password: the owner's approval), the
//! team's capacity, the owner's tasks, assignments and reviews. An agent has none of these (the dialog `team_watch` is
//! in `control/watch.rs`).

use antenna_proto::control::{
    Reply, TaskAssign, TaskListReq, TaskNew, TaskRef, TaskReviewReq, TeamAddWorker, TeamApply,
    TeamCreate, TeamLogReq, TeamRef, TeamSet, TeamStop,
};

use super::{Answer, b, session};
use crate::node::Node;

/// `team_create`.
pub(crate) async fn create(node: &Node, req: TeamCreate) -> Answer {
    Ok(Reply::Team(
        session(node).await?.team_create(req).await.map_err(b)?,
    ))
}

/// `team_set`.
pub(crate) async fn set(node: &Node, req: TeamSet) -> Answer {
    Ok(Reply::Team(
        session(node).await?.team_set(req).await.map_err(b)?,
    ))
}

/// `team_list`.
pub(crate) async fn list(node: &Node) -> Answer {
    Ok(Reply::Teams {
        teams: session(node).await?.team_list().map_err(b)?,
    })
}

/// `team_show`.
pub(crate) async fn show(node: &Node, req: TeamRef) -> Answer {
    Ok(Reply::Team(
        session(node).await?.team_show(&req.team).await.map_err(b)?,
    ))
}

/// `team_add_worker`.
pub(crate) async fn add_worker(node: &Node, req: TeamAddWorker) -> Answer {
    Ok(Reply::TeamWorker(
        session(node)
            .await?
            .team_add_worker(&req.team, &req.role, req.kind.as_deref())
            .map_err(b)?,
    ))
}

/// `team_stop`.
pub(crate) async fn stop(node: &Node, req: TeamStop) -> Answer {
    Ok(Reply::Team(
        session(node).await?.team_stop(req).await.map_err(b)?,
    ))
}

/// `team_remove`.
pub(crate) async fn remove(node: &Node, req: TeamRef) -> Answer {
    Ok(Reply::Teams {
        teams: session(node)
            .await?
            .team_remove(&req.team)
            .await
            .map_err(b)?,
    })
}

/// `team_apply`.
pub(crate) async fn apply(node: &Node, req: TeamApply) -> Answer {
    Ok(Reply::Team(
        session(node).await?.team_apply(req).await.map_err(b)?,
    ))
}

/// `team_log`.
pub(crate) async fn log(node: &Node, req: TeamLogReq) -> Answer {
    Ok(Reply::TeamLog {
        entries: session(node)
            .await?
            .team_log_entries(&req.team, req.limit)
            .map_err(b)?,
    })
}

/// `task_new`.
pub(crate) async fn task_new(node: &Node, req: TaskNew) -> Answer {
    Ok(Reply::Task(
        session(node).await?.task_new(req).await.map_err(b)?,
    ))
}

/// `task_list`.
pub(crate) async fn task_list(node: &Node, req: TaskListReq) -> Answer {
    Ok(Reply::Tasks {
        tasks: session(node).await?.task_list(&req.team).map_err(b)?,
    })
}

/// `task_show`.
pub(crate) async fn task_show(node: &Node, req: TaskRef) -> Answer {
    Ok(Reply::Task(
        session(node).await?.task_show(&req.id).map_err(b)?,
    ))
}

/// `task_diff`.
pub(crate) async fn task_diff(node: &Node, req: TaskRef) -> Answer {
    Ok(Reply::TaskDiff(
        session(node).await?.task_diff(&req.id).await.map_err(b)?,
    ))
}

/// `task_review`.
pub(crate) async fn task_review(node: &Node, req: TaskReviewReq) -> Answer {
    Ok(Reply::Task(
        session(node)
            .await?
            .task_review_owner(&req.id, &req.verdict, &req.comments, req.urgent)
            .await
            .map_err(b)?,
    ))
}

/// `task_assign` (the owner's).
pub(crate) async fn task_assign(node: &Node, req: TaskAssign) -> Answer {
    Ok(Reply::Task(
        session(node)
            .await?
            .task_assign_owner(&req.id, &req.worker)
            .await
            .map_err(b)?,
    ))
}

/// `team_capacity`.
pub(crate) async fn capacity(node: &Node, req: TeamRef) -> Answer {
    Ok(Reply::Capacity(
        session(node).await?.team_capacity(&req.team).map_err(b)?,
    ))
}

/// `task_apply`.
pub(crate) async fn task_apply(node: &Node, req: TaskRef) -> Answer {
    Ok(Reply::Task(
        session(node)
            .await?
            .task_apply_owner(&req.id)
            .await
            .map_err(b)?,
    ))
}
