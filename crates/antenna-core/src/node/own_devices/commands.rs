// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's commands of My devices (`docs/CONTROL.md` §27): the list, answering another computer's request, the
//! keys accepted from each, lending to teams, a lost computer.

use std::sync::{Arc, PoisonError};

use antenna_proto::{
    LinkId,
    control::{
        DeviceChallenge, DeviceDecided, DeviceInfo, DeviceView, DevicesReply, LostInfo, LostReport,
        ThisDevice,
    },
    device::{self, DeviceMsg, DeviceReply, RemoteDecision, RemoteRequest},
};
use data_encoding::{BASE64, HEXLOWER};

use super::{LendingDevice, level_error};
use crate::{
    devices,
    error::{Error, Result},
    node::{LinkRt, Session},
    now_ms, owner_keys,
    store::LinkRow,
};

impl Session {
    /// `devices`.
    pub fn devices_list(&self) -> Result<DevicesReply> {
        let (keys, _) = self.device_keys()?;
        let (name, os_version, _) = self.device_machine().clone();
        let now = now_ms();
        let (lend, lost, rows) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            (devices::lend(&db)?, devices::lost(&db, now)?, db.links()?)
        };
        let records = self.device_records()?;
        let latest = self
            .devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let mut out = Vec::new();
        for row in rows.iter().filter(|r| r.trust == 5) {
            let rt = self.rt(&row.link_id).ok();
            let rec = records
                .get(&row.link_id.to_hex())
                .cloned()
                .unwrap_or_default();
            let (status, received_ms) = match latest.get(&row.link_id) {
                Some((s, at)) => (Some(s.clone()), Some(*at)),
                None => (rec.last.clone(), rec.received_ms),
            };
            out.push(DeviceInfo {
                contact: row.label.clone(),
                link_id: row.link_id.to_hex(),
                presence: if rt
                    .as_ref()
                    .is_some_and(|rt| rt.shared.live_conn().is_some())
                {
                    "online"
                } else {
                    "offline"
                }
                .into(),
                supported: rt
                    .as_ref()
                    .is_some_and(|rt| rt.shared.peer_supports_device()),
                stop_agents: rt
                    .as_ref()
                    .is_some_and(|rt| rt.shared.peer_supports_agent_stop()),
                accepts_mine: status
                    .as_ref()
                    .map(|s| s.accepts.clone())
                    .unwrap_or_default(),
                status: status.map(|s| DeviceView {
                    at_ms: s.at_ms,
                    name: s.name,
                    os: s.os,
                    os_version: s.os_version,
                    arch: s.arch,
                    memory_bytes: s.memory_bytes,
                    version: s.version,
                    update: s.update,
                    health: s.health,
                    agents: s.agents,
                    approvals: s.approvals,
                    pending_approvals: s.pending_approvals,
                    lend: s.lend,
                }),
                received_ms,
                confirmed: rec.confirmed.iter().map(devices::KeyEntry::info).collect(),
                offered: devices::offered(&rec),
                lost_by: rec
                    .lost_by
                    .map(|(contact, at_ms)| LostReport { contact, at_ms }),
            });
        }
        Ok(DevicesReply {
            this: ThisDevice {
                name,
                os: std::env::consts::OS.into(),
                os_version,
                arch: std::env::consts::ARCH.into(),
                version: self.cfg.daemon_version.clone(),
                lend,
                keys: keys.iter().map(devices::key_info).collect(),
                lost: lost
                    .iter()
                    .map(|l| LostInfo {
                        contact: l.contact.clone(),
                        key_ids: l
                            .keys
                            .iter()
                            .filter_map(|k| BASE64.decode(k.as_bytes()).ok())
                            .map(|k| owner_keys::key_id(&k))
                            .collect(),
                        at_ms: l.at_ms,
                    })
                    .collect(),
            },
            devices: out,
        })
    }

    /// `device_challenge`: the other device's challenge for one decision answered from here.
    pub async fn device_challenge(&self, contact: &str) -> Result<DeviceChallenge> {
        let (row, rt) = self.device_row(contact)?;
        match rt.shared.device_send(&DeviceMsg::Challenge {}).await? {
            Some(DeviceReply::Challenge { nonce, expires_ms }) => Ok(DeviceChallenge {
                contact: row.label,
                link_id: row.link_id.to_hex(),
                nonce: HEXLOWER.encode(&nonce),
                expires_ms,
            }),
            other => Err(Error::network(format!("device challenge: {other:?}"))),
        }
    }

    async fn device_decision_send(
        &self,
        row: &LinkRow,
        rt: &Arc<LinkRt>,
        decision: RemoteDecision,
    ) -> Result<DeviceDecided> {
        match rt.shared.device_send(&DeviceMsg::Decide(decision)).await? {
            Some(DeviceReply::Decided { id, state }) => {
                self.device_event(&row.link_id, "decided");
                Ok(DeviceDecided {
                    contact: row.label.clone(),
                    id,
                    state,
                })
            }
            other => Err(Error::network(format!("device decision: {other:?}"))),
        }
    }

    /// `device_approve`: a proof made in the window (Touch ID), passed on unchanged. The text is checked here only for
    /// its shape and its link, so a mistake is told before it travels; the other device checks everything.
    pub async fn device_approve(
        &self,
        contact: &str,
        request: String,
        nonce: &str,
        key_id: String,
        sig: &str,
    ) -> Result<DeviceDecided> {
        let (row, rt) = self.device_row(contact)?;
        let parsed = RemoteRequest::parse(&request).map_err(Error::bad_request)?;
        if parsed.link() != row.link_id.to_hex() {
            return Err(Error::bad_request("the signed request names another link"));
        }
        let sig = BASE64
            .decode(sig.trim().as_bytes())
            .map_err(|_| Error::bad_request("sig: base64 of 64 bytes"))?;
        let decision = RemoteDecision {
            request,
            nonce: Some(devices::nonce_from_hex(nonce)?),
            key_id: Some(key_id),
            sig: Some(sig),
        };
        decision
            .check()
            .map_err(|f| Error::bad_request(format!("bad {f}")))?;
        self.device_decision_send(&row, &rt, decision).await
    }

    /// `device_decide`: approve with this computer's password (checked before this call), signed with the device key
    /// over the other device's challenge; or deny.
    pub async fn device_decide(
        &self,
        contact: &str,
        id: &str,
        decision: &str,
        fingerprint: Option<&str>,
    ) -> Result<DeviceDecided> {
        let (row, rt) = self.device_row(contact)?;
        let link = row.link_id.to_hex();
        let d = match decision {
            "deny" => RemoteDecision {
                request: RemoteRequest::RemoteDeny {
                    link,
                    id: id.into(),
                }
                .to_text(),
                nonce: None,
                key_id: None,
                sig: None,
            },
            "approve" => {
                let fingerprint = fingerprint.ok_or_else(|| {
                    Error::bad_request("approving names the fingerprint the owner was shown")
                })?;
                let request = RemoteRequest::RemoteApprove {
                    link,
                    id: id.into(),
                    fingerprint: fingerprint.into(),
                }
                .to_text();
                let Some(DeviceReply::Challenge { nonce, .. }) =
                    rt.shared.device_send(&DeviceMsg::Challenge {}).await?
                else {
                    return Err(Error::network("device challenge: no answer"));
                };
                let (_, key) = self.device_keys()?;
                let sig = devices::sign(&key, &nonce, &request)?;
                RemoteDecision {
                    key_id: Some(devices::device_key_announced(&key).key_id),
                    request,
                    nonce: Some(nonce),
                    sig: Some(sig),
                }
            }
            _ => return Err(Error::bad_request("decision: approve or deny")),
        };
        self.device_decision_send(&row, &rt, d).await
    }

    /// `device_keys_confirm` (the password was checked).
    pub fn device_keys_confirm(&self, contact: &str, key_ids: &[String]) -> Result<DevicesReply> {
        let row = self.find_link(contact)?;
        if row.trust != 5 {
            return Err(level_error());
        }
        let now = now_ms();
        self.device_records_update(|r| {
            devices::confirm(r.entry(row.link_id.to_hex()).or_default(), key_ids, now)
        })?;
        tracing::info!(
            "link {}: approvals from that computer accepted with {} key(s)",
            &row.link_id.to_hex()[..8],
            if key_ids.is_empty() {
                "all its".to_string()
            } else {
                key_ids.len().to_string()
            }
        );
        self.receipt(
            &row.link_id,
            "owner",
            "device_keys",
            "confirmed",
            &key_ids.join(" "),
            None,
            None,
        );
        self.device_event(&row.link_id, "keys");
        self.devices_list()
    }

    /// `device_keys_remove`: no password (it only takes a way in away).
    pub fn device_keys_remove(&self, contact: &str, key_ids: &[String]) -> Result<DevicesReply> {
        let row = self.find_link(contact)?;
        self.device_keys_forget(&row.link_id, key_ids)?;
        self.devices_list()
    }

    /// Drops confirmed keys of a link (all when `key_ids` is empty).
    pub(in crate::node) fn device_keys_forget(
        &self,
        link: &LinkId,
        key_ids: &[String],
    ) -> Result<()> {
        let hex = link.to_hex();
        let removed = self.device_records_update(|r| {
            Ok(r.get_mut(&hex).map_or(0, |rec| {
                let before = rec.confirmed.len();
                rec.confirmed
                    .retain(|k| !key_ids.is_empty() && !key_ids.contains(&k.key_id));
                before - rec.confirmed.len()
            }))
        })?;
        if removed > 0 {
            self.receipt(
                link,
                "owner",
                "device_keys",
                "removed",
                &key_ids.join(" "),
                None,
                None,
            );
            self.device_event(link, "keys");
        }
        Ok(())
    }

    /// "Lend this computer to my teams" on this computer (PG-14): what a team reads before it takes work from another
    /// own device (remote workers come with the teams' "other machines").
    pub(crate) fn lends(&self) -> bool {
        devices::lend(&self.db.lock().unwrap_or_else(PoisonError::into_inner)).unwrap_or(false)
    }

    /// The owner's other computers (at ∞) that say they lend themselves to teams, as they last told this one: the
    /// machines a team may place work on once remote workers exist (facts only).
    pub(crate) fn lending_devices(&self) -> Vec<LendingDevice> {
        let rows = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .links();
        let Ok(rows) = rows else {
            return Vec::new();
        };
        let latest = self
            .devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        rows.iter()
            .filter(|r| r.trust == 5)
            .filter_map(|r| {
                let (s, _) = latest.get(&r.link_id)?;
                s.lend.then(|| LendingDevice {
                    contact: r.label.clone(),
                    online: self
                        .rt(&r.link_id)
                        .is_ok_and(|rt| rt.shared.live_conn().is_some()),
                    os: s.os.clone(),
                    arch: s.arch.clone(),
                    memory_bytes: s.memory_bytes,
                })
            })
            .collect()
    }

    /// `device_lend_set` (the password was checked to turn it on).
    pub fn device_lend_set(&self, enabled: bool) -> Result<DevicesReply> {
        devices::set_lend(
            &self.db.lock().unwrap_or_else(PoisonError::into_inner),
            enabled,
        )?;
        tracing::info!(
            "devices: lending this computer to teams {}",
            if enabled { "on" } else { "off" }
        );
        self.devices_list()
    }

    /// `device_revoke` (the password was checked): the computer's keys go to the lost list the other devices are told
    /// about, then the link is revoked.
    pub async fn device_revoke(&self, contact: &str, delete_history: bool) -> Result<LinkRow> {
        let row = self.find_link(contact)?;
        if row.trust != 5 {
            return Err(level_error());
        }
        let hex = row.link_id.to_hex();
        let rec = self.device_records()?.remove(&hex).unwrap_or_default();
        let mut keys: Vec<String> = rec
            .last
            .iter()
            .flat_map(|s| s.keys.iter().map(|k| BASE64.encode(&k.public)))
            .chain(rec.confirmed.iter().map(|k| k.public.clone()))
            .collect();
        if let Some((s, _)) = self
            .devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&row.link_id)
        {
            keys.extend(s.keys.iter().map(|k| BASE64.encode(&k.public)));
        }
        keys.sort();
        keys.dedup();
        keys.truncate(device::MAX_KEYS);
        if !keys.is_empty() {
            let now = now_ms();
            devices::add_lost(
                &self.db.lock().unwrap_or_else(PoisonError::into_inner),
                devices::Lost {
                    contact: row.label.clone(),
                    keys,
                    at_ms: now,
                },
                now,
            )?;
        }
        tracing::warn!("link {}: revoked as a lost computer", &hex[..8]);
        self.revoke(&row, delete_history).await?;
        Ok(row)
    }

    /// `device_lost_dismiss`.
    pub fn device_lost_dismiss(&self, contact: &str) -> Result<DevicesReply> {
        let row = self.find_link(contact)?;
        let hex = row.link_id.to_hex();
        self.device_records_update(|r| {
            if let Some(rec) = r.get_mut(&hex) {
                rec.lost_by = None;
            }
            Ok(())
        })?;
        self.device_event(&row.link_id, "lost");
        self.devices_list()
    }

    /// The link is gone (`revoke`): nothing about that device stays.
    pub(in crate::node) fn devices_forget(&self, link: &LinkId) {
        let hex = link.to_hex();
        let r = self.device_records_update(|r| {
            r.remove(&hex);
            Ok(())
        });
        if let Err(e) = r {
            tracing::warn!("devices: {e}");
        }
        self.devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(link);
        self.devices
            .sent
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(link);
        self.devices
            .challenges
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .forget(link);
    }
}
