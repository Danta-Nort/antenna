// SPDX-License-Identifier: AGPL-3.0-only
//! Approving and denying agents' requests (SPEC §9; CONTROL §4, §20; D-84, D-92).

use antenna_proto::control::{ApproveItem, ApproverNarrow, ApproverRemove, ApproverSet, Reply};

use super::{Answer, b, session};
use crate::node::Node;

/// `approvals`.
pub(crate) async fn approvals(node: &Node, all: bool) -> Answer {
    let (approvals, hidden_quiet) = session(node).await?.approvals_for_owner(all);
    Ok(Reply::Approvals {
        approvals,
        hidden_quiet,
    })
}

/// `approve` (the password or the owner proof was checked in `authorize`); `fingerprint` (v7), when given, must be
/// the request's, as in `approve_many`.
pub(crate) async fn approve(node: &Node, id: String, fingerprint: Option<String>) -> Answer {
    let s = session(node).await?;
    let info = s.approve_checked(&id, fingerprint.as_deref()).map_err(b)?;
    // The daemon carries out the approved request itself and tells the agent (D-70, D-100)
    let s2 = s.clone();
    tokio::spawn(async move { s2.complete_approved(&id).await });
    Ok(Reply::Approval(info))
}

/// `approve_many`.
pub(crate) async fn approve_many(node: &Node, items: Vec<ApproveItem>) -> Answer {
    // The password was checked once for the whole call in `owner`; each item is a single approval
    let s = session(node).await?;
    let items: Vec<(String, Option<String>)> =
        items.into_iter().map(|i| (i.id, i.fingerprint)).collect();
    let results = s.approve_many(&items).map_err(b)?;
    for r in &results {
        if r.approval.is_some() {
            let s2 = s.clone();
            let id = r.id.clone();
            tokio::spawn(async move { s2.complete_approved(&id).await });
        }
    }
    Ok(Reply::ApprovalsDecided { results })
}

/// `deny`: no password and no session needed (D-84).
pub(crate) async fn deny(node: &Node, id: String, hour: bool) -> Answer {
    Ok(Reply::Approval(
        session(node).await?.deny(&id, hour).map_err(b)?,
    ))
}

/// `deny_many`.
pub(crate) async fn deny_many(node: &Node, ids: Vec<String>, hour: bool) -> Answer {
    Ok(Reply::ApprovalsDecided {
        results: session(node).await?.deny_many(&ids, hour).map_err(b)?,
    })
}

/// `approver_set` (PG-57; the password or the owner proof was checked in `authorize`).
pub(crate) async fn approver_set(node: &Node, r: ApproverSet) -> Answer {
    Ok(Reply::Approvers(
        session(node).await?.approver_set(&r).map_err(b)?,
    ))
}

/// `approver_narrow`: an owner session, no password (it only takes away, D-84).
pub(crate) async fn approver_narrow(node: &Node, r: ApproverNarrow) -> Answer {
    Ok(Reply::Approvers(
        session(node).await?.approver_narrow(&r).map_err(b)?,
    ))
}

/// `approver_remove`: an owner session, no password.
pub(crate) async fn approver_remove(node: &Node, r: ApproverRemove) -> Answer {
    Ok(Reply::Approvers(
        session(node).await?.approver_remove(&r).map_err(b)?,
    ))
}

/// `approvers`.
pub(crate) async fn approvers(node: &Node) -> Answer {
    Ok(Reply::Approvers(
        session(node).await?.approvers_view().map_err(b)?,
    ))
}
