// SPDX-License-Identifier: AGPL-3.0-only
//! My devices (CONTROL §27, D-106; experimental): the owner's own computers, approvals answered from this one with
//! its password, a lost computer, lending this computer to teams.

use antenna_proto::control::{Reply, Request};

use super::Owner;
use crate::DevicesCommand;
use crate::client::{CliResult, EXIT_FAIL, Fail};

/// `antenna devices …`.
pub(super) async fn run(o: &Owner, cmd: &Option<DevicesCommand>) -> CliResult<Reply> {
    match cmd {
        None | Some(DevicesCommand::List) => o.call(Request::Devices {}).await,
        Some(DevicesCommand::Confirm {
            contact,
            key_ids,
            pw,
        }) => {
            o.call_pw(pw, |password| Request::DeviceKeysConfirm {
                contact: contact.clone(),
                key_ids: key_ids.clone(),
                password,
            })
            .await
        }
        Some(DevicesCommand::Forget { contact, key_ids }) => {
            o.call(Request::DeviceKeysRemove {
                contact: contact.clone(),
                key_ids: key_ids.clone(),
            })
            .await
        }
        Some(DevicesCommand::Approve { contact, id, pw }) => approve(o, contact, id, pw).await,
        Some(DevicesCommand::Deny { contact, id }) => {
            o.call(Request::DeviceDecide {
                contact: contact.clone(),
                id: id.clone(),
                decision: "deny".into(),
                fingerprint: None,
                password: None,
            })
            .await
        }
        Some(DevicesCommand::Revoke {
            contact,
            delete_history,
            pw,
        }) => {
            o.call_pw(pw, |password| Request::DeviceRevoke {
                contact: contact.clone(),
                delete_history: *delete_history,
                password,
            })
            .await
        }
        Some(DevicesCommand::Lend { state, pw }) => {
            let enabled = state == "on";
            if enabled {
                o.call_pw(pw, |p| Request::DeviceLendSet {
                    enabled,
                    password: Some(p),
                })
                .await
            } else {
                o.call(Request::DeviceLendSet {
                    enabled,
                    password: None,
                })
                .await
            }
        }
        Some(DevicesCommand::Dismiss { contact }) => {
            o.call(Request::DeviceLostDismiss {
                contact: contact.clone(),
            })
            .await
        }
        Some(DevicesCommand::StopAgent { contact, agent }) => {
            o.call(Request::DeviceAgentStop(
                antenna_proto::control::DeviceAgentStop {
                    contact: contact.clone(),
                    agent: agent.clone(),
                },
            ))
            .await
        }
    }
}

/// `antenna devices approve`: the request is found in what that computer last said, so the approval names the
/// fingerprint the owner was shown by `antenna devices`.
async fn approve(o: &Owner, contact: &str, id: &str, pw: &crate::Pw) -> CliResult<Reply> {
    let Reply::Devices(d) = o.call(Request::Devices {}).await? else {
        return Err(Fail::new(
            EXIT_FAIL,
            "internal",
            "unexpected reply to devices",
        ));
    };
    let dev = d
        .devices
        .iter()
        .find(|x| x.contact == contact || x.link_id.starts_with(contact))
        .ok_or_else(|| {
            Fail::new(
                EXIT_FAIL,
                "not_found",
                format!(
                    "{contact} is not one of your own computers (∞): `antenna devices` lists them"
                ),
            )
        })?;
    let a = dev
        .status
        .as_ref()
        .and_then(|s| s.approvals.iter().find(|a| a.id == id))
        .ok_or_else(|| {
            Fail::new(
                EXIT_FAIL,
                "not_found",
                format!(
                    "{contact} has no pending request {id} (it may have been decided or expired)"
                ),
            )
        })?;
    o.call_pw(pw, |password| Request::DeviceDecide {
        contact: dev.contact.clone(),
        id: id.into(),
        decision: "approve".into(),
        fingerprint: Some(a.fingerprint.clone()),
        password: Some(password),
    })
    .await
}
