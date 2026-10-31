// SPDX-License-Identifier: AGPL-3.0-only
//! What the owner's other computers ask of this one (`docs/PROTOCOL.md` §24): a status to keep, a challenge, a
//! decision on one of this computer's approval requests, checked here against keys the owner confirmed.

use std::sync::{Arc, PoisonError};

use antenna_proto::{
    LinkId,
    control::code,
    device::{DeviceReply, DeviceStatus, RemoteDecision},
};
use data_encoding::HEXLOWER;

use super::Job;
use crate::{
    devices::{self, Checked},
    error::{Error, Result},
    node::Session,
    now_ms,
};

impl Session {
    /// Serves what the owner's other devices ask of this computer (the links hand it over).
    pub(in crate::node) async fn devices_loop(self: Arc<Self>) {
        let rx = self
            .devices
            .rx
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        let Some(mut rx) = rx else { return };
        loop {
            let job = tokio::select! {
                j = rx.recv() => match j {
                    Some(j) => j,
                    None => break,
                },
                _ = self.closed_wait() => break,
            };
            match job {
                Job::Status { link, status } => {
                    if let Err(e) = self.device_status_in(link, *status) {
                        tracing::debug!("devices: status: {e}");
                    }
                }
                Job::Challenge { link, reply } => {
                    let r = self.device_challenge_in(link);
                    let _ = reply.send(r);
                }
                Job::Decide {
                    link,
                    decision,
                    reply,
                } => {
                    let r = self.device_decide_in(link, &decision);
                    let _ = reply.send(r);
                }
                Job::Connect { link, ask, reply } => {
                    let r = self.connect_ask_in(link, &ask);
                    if let Err(e) = &r {
                        tracing::info!(
                            "link {}: a connection asked by that computer refused: {}",
                            &link.to_hex()[..8],
                            e.code
                        );
                    }
                    let _ = reply.send(r);
                }
                Job::AgentChallenge { link, id, reply } => {
                    let _ = reply.send(self.agent_challenge_in(link, &id));
                }
                Job::AgentDecide {
                    link,
                    decision,
                    reply,
                } => {
                    let r = self.agent_decide_in(link, &decision);
                    if let Err(e) = &r {
                        tracing::info!(
                            "link {}: an approver agent's answer from that computer refused: {}",
                            &link.to_hex()[..8],
                            e.code
                        );
                    }
                    let _ = reply.send(r);
                }
                // A stop takes a few seconds (the processes get time to end): off the loop, so the other requests of
                // own devices are not held up
                Job::StopAgent { link, agent, reply } => {
                    let me = self.clone();
                    tokio::spawn(async move {
                        let r = me.stop_agent_in(link, &agent).await;
                        let _ = reply.send(r);
                    });
                }
            }
        }
    }

    fn device_status_in(&self, link: LinkId, status: DeviceStatus) -> Result<()> {
        // The level is checked again here: it may have changed since the link served the request
        if self.link_trust(&link) != 5 {
            return Ok(());
        }
        let now = now_ms();
        let changed = {
            let mut g = self
                .devices
                .latest
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let same = g.get(&link).is_some_and(|(old, _)| {
                let mut a = old.clone();
                a.at_ms = 0;
                let mut b = status.clone();
                b.at_ms = 0;
                a == b
            });
            g.insert(link, (status.clone(), now));
            !same
        };
        if !changed {
            return Ok(());
        }
        // Requests that computer offers this computer's approver agents for the first time (PG-57)
        self.offer_device_requests(link, &status);
        let hex = link.to_hex();
        let reporter = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&link)
            .map(|r| r.label)
            .unwrap_or_default();
        let (dropped, marked) = self.device_records_update(|r| {
            let dropped = devices::note_status(r.entry(hex.clone()).or_default(), &status, now);
            let marked = if status.lost.is_empty() {
                Vec::new()
            } else {
                devices::apply_lost(r, &hex, &reporter, &status.lost)
            };
            Ok((dropped, marked))
        })?;
        self.device_event(&link, if dropped { "keys" } else { "status" });
        for m in marked {
            let id = HEXLOWER
                .decode(m.as_bytes())
                .ok()
                .and_then(|v| <[u8; 32]>::try_from(v).ok())
                .map(LinkId);
            if let Some(id) = id {
                tracing::warn!(
                    "link {}: another own device ({reporter}) reported this computer as lost: its keys are no \
                     longer accepted for approvals here",
                    &m[..8]
                );
                self.device_event(&id, "lost");
            }
        }
        Ok(())
    }

    fn device_challenge_in(&self, link: LinkId) -> Result<DeviceReply> {
        if self.link_trust(&link) != 5 {
            return Err(Error::new("level", "not at level 5"));
        }
        let ttl = u64::try_from(self.cfg.owner_challenge_ttl.as_millis()).unwrap_or(u64::MAX);
        let (nonce, expires_ms) = self
            .devices
            .challenges
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .issue(link, now_ms(), ttl);
        Ok(DeviceReply::Challenge { nonce, expires_ms })
    }

    /// A remote decision on one of this computer's approval requests (`docs/PROTOCOL.md` §24): the device is at level 5
    /// here and its owner confirmed at least one of its keys; the decision passes [`devices::check_decision`]; then it
    /// is approved or denied exactly as the owner would here, and logged as coming from that device.
    fn device_decide_in(self: &Arc<Self>, link: LinkId, d: &RemoteDecision) -> Result<DeviceReply> {
        if self.link_trust(&link) != 5 {
            return Err(Error::new("level", "not at level 5"));
        }
        let hex = link.to_hex();
        let confirmed = self
            .device_records()?
            .get(&hex)
            .map(|r| r.confirmed.clone())
            .unwrap_or_default();
        if confirmed.is_empty() {
            return Err(Error::new(
                code::FORBIDDEN,
                "no key of that computer is confirmed here for approvals",
            ));
        }
        let now = now_ms();
        self.devices
            .challenges
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .check_pause(&link, now)?;
        let checked = devices::check_decision(&link, &confirmed, d, |n| {
            self.devices
                .challenges
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take(&link, n, now)
        });
        match &checked {
            Ok(Checked::Approve { .. }) => self
                .devices
                .challenges
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .record(link, true, now),
            Err(e) if devices::counts_as_failed(e.code) => {
                tracing::warn!(
                    "link {}: an approval from another device refused: {}",
                    &hex[..8],
                    e.code
                );
                self.devices
                    .challenges
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .record(link, false, now);
            }
            _ => {}
        }
        let (info, what) = match checked? {
            Checked::Approve {
                id,
                fingerprint,
                key_id,
            } => {
                let info =
                    self.approve_checked_as(&id, Some(&fingerprint), "approved_from_own_device")?;
                // The daemon carries out the approved request itself (D-100), as after a local approval
                let s2 = self.clone();
                let id2 = id.clone();
                tokio::spawn(async move { s2.complete_approved(&id2).await });
                (info, format!("approved {id} with key {key_id}"))
            }
            Checked::Deny { id } => {
                let info = self.deny_as(&id, "denied_from_own_device")?;
                (info, format!("denied {id}"))
            }
        };
        // The record on the device's own link: which request it decided, and with which key
        self.receipt(
            &link,
            "owner",
            "device_decision",
            if info.state == "denied" {
                "denied"
            } else {
                "approved"
            },
            &format!("{what} ({} for {})", info.action, info.contact),
            None,
            Some(&info.id),
        );
        self.device_event(&link, "decided");
        Ok(DeviceReply::Decided {
            id: info.id,
            state: info.state,
        })
    }
}
