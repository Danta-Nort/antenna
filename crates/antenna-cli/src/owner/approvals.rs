// SPDX-License-Identifier: AGPL-3.0-only
//! Approving and denying agents' requests (SPEC §9; D-84, D-92).

use std::io::{IsTerminal, Write};

use antenna_proto::control::{
    ApproveItem, ApproverNarrow, ApproverRemove, ApproverSet, NoArgs, Reply, Request,
};

use super::Owner;
use crate::client::{CliResult, EXIT_FAIL, EXIT_USAGE, Fail};
use crate::{ApproverCommand, DenyArgs, Pw, read_line_stdin};

/// What naming an approver means, shown before the password (PG-57, like the level-5 warning of D-99).
pub(crate) const APPROVER_WARNING: &str = "Experimental. An approver agent answers your other agents' approval \
     requests in your place, without asking you. Antenna lets its answer count only while everything the request \
     touches stays on your own computers (∞), and logs every answer with its reason. A model can be wrong or misled: \
     name only an agent you trust like yourself on these computers.";

/// `antenna approve <id>…`.
pub(super) async fn approve(o: &Owner, ids: &[String], pw: &Pw) -> CliResult<Reply> {
    if let [id] = ids {
        o.call_pw(pw, |password| Request::Approve {
            id: id.clone(),
            password,
            fingerprint: None,
        })
        .await
    } else {
        // One password (or one touch) for the call; the daemon approves each request on its own (CONTROL §20)
        o.call_pw(pw, |password| Request::ApproveMany {
            items: ids
                .iter()
                .map(|id| ApproveItem {
                    id: id.clone(),
                    fingerprint: None,
                })
                .collect(),
            password,
        })
        .await
    }
}

/// `antenna deny <id>…`.
pub(super) async fn deny(o: &Owner, a: &DenyArgs) -> CliResult<Reply> {
    if a.password_stdin {
        // Consumed so that it does not linger on stdin; the daemon needs no password to deny (D-84)
        let _ = read_line_stdin();
    }
    if let [id] = a.ids.as_slice() {
        o.call(Request::Deny {
            id: id.clone(),
            hour: a.hour,
            password: None,
        })
        .await
    } else {
        o.call(Request::DenyMany {
            ids: a.ids.clone(),
            hour: a.hour,
        })
        .await
    }
}

/// The warning, accepted in a terminal or with `--yes`; without a terminal only `--yes` accepts it.
fn confirm_approver(yes: bool, pw: &Pw) -> CliResult<()> {
    if yes {
        return Ok(());
    }
    if pw.password_stdin || !std::io::stdin().is_terminal() {
        return Err(Fail::new(
            EXIT_USAGE,
            "bad_request",
            format!("{APPROVER_WARNING} Pass --yes to accept this."),
        ));
    }
    eprint!("{APPROVER_WARNING}\nLet this agent answer in your place? [y/N] ");
    let _ = std::io::stderr().flush();
    let answer = read_line_stdin()?;
    if matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
        Ok(())
    } else {
        Err(Fail::new(EXIT_FAIL, "cancelled", "nothing was changed"))
    }
}

/// `antenna approver …` (PG-57).
pub(super) async fn approver(o: &Owner, cmd: Option<&ApproverCommand>) -> CliResult<Reply> {
    match cmd {
        None | Some(ApproverCommand::List) => o.call(Request::Approvers(NoArgs {})).await,
        Some(ApproverCommand::Set(a)) => {
            confirm_approver(a.yes, &a.pw)?;
            o.call_pw(&a.pw, |password| {
                Request::ApproverSet(ApproverSet {
                    name: a.scope.name.clone(),
                    contact: a.scope.on.clone(),
                    agents: a.scope.agents.clone(),
                    kinds: a.scope.kinds.clone(),
                    password,
                })
            })
            .await
        }
        Some(ApproverCommand::Narrow(a)) => {
            o.call(Request::ApproverNarrow(ApproverNarrow {
                name: a.name.clone(),
                contact: a.on.clone(),
                agents: a.agents.clone(),
                kinds: a.kinds.clone(),
            }))
            .await
        }
        Some(ApproverCommand::Remove { name, on }) => {
            o.call(Request::ApproverRemove(ApproverRemove {
                name: name.clone(),
                contact: on.clone(),
            }))
            .await
        }
    }
}
