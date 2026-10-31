// SPDX-License-Identifier: AGPL-3.0-only
//! What this computer tells its own devices (`docs/PROTOCOL.md` §24): the status, built from facts only (a quote
//! with a secret withheld), the keys it answers approvals with, and the announcer that sends it when it changed.

use std::sync::{Arc, PoisonError, atomic::Ordering};

use antenna_proto::device::{
    self, DeviceAgent, DeviceApproval, DeviceKey, DeviceMsg, DeviceStatus, HealthFact,
    KEY_TOUCH_ID, LostDevice, UpdateFacts,
};
use aws_lc_rs::signature::EcdsaKeyPair;
use data_encoding::BASE64;

use super::{DIAL_EVERY_MS, HEARTBEAT_MS, Sent};
use crate::{
    crypto, devices,
    error::Result,
    node::{LinkRt, Session},
    now_ms, owner_keys,
};

/// An app name as the other devices see it: the command name, plain characters only.
fn app_name(s: &str) -> Option<String> {
    let s: String = s
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(32)
        .collect();
    (!s.is_empty()).then_some(s)
}

/// A pending approval request as it travels: its quote cut, or withheld when it contains a secret.
fn approval_out(a: &antenna_proto::control::ApprovalInfo) -> DeviceApproval {
    let withheld = !crate::policy::scan_secrets(&a.quote).is_empty();
    let short = |s: &str, max: usize| device::cut(&s.replace(char::is_control, " "), max);
    DeviceApproval {
        id: short(&a.id, 32),
        action: short(&a.action, 64),
        requester: short(&a.requester, 64),
        contact: short(&a.contact, 256),
        contact_trust: a.contact_trust.clamp(1, 5),
        target: a.target.as_deref().map(|t| short(t, 256)),
        reasons: a.reasons.iter().take(16).map(|r| short(r, 64)).collect(),
        quote: if withheld {
            String::new()
        } else {
            device::cut(&a.quote, device::MAX_QUOTE)
        },
        quote_withheld: withheld,
        fingerprint: short(&a.fingerprint, 64),
        created_ms: a.created_ms,
        expires_ms: a.expires_ms,
        completes: a.completes,
        approvers: Vec::new(),
    }
}

impl Session {
    pub(super) fn device_machine(&self) -> &(String, String, u64) {
        self.devices.machine.get_or_init(|| {
            let (name, os) = devices::machine_names();
            let mem = crate::local::hardware::read(&self.cfg.data_dir).memory;
            (name, os, mem)
        })
    }

    /// The keys this computer answers its other devices' approvals with: its owner keys (the window's Touch ID keys)
    /// and its device key.
    pub(super) fn device_keys(&self) -> Result<(Vec<DeviceKey>, EcdsaKeyPair)> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let dk = devices::device_key(&db)?;
        let mut keys: Vec<DeviceKey> = owner_keys::load(&db)?
            .iter()
            .filter(|k| !k.is_test_key() || owner_keys::test_key_accepted())
            .filter_map(|k| {
                Some(DeviceKey {
                    key_id: k.key_id.clone(),
                    public: k.public().ok()?.to_vec(),
                    label: device::cut(&k.label, 64),
                    kind: KEY_TOUCH_ID.into(),
                })
            })
            .collect();
        keys.truncate(device::MAX_KEYS - 1);
        keys.push(devices::device_key_announced(&dk));
        Ok((keys, dk))
    }

    /// Problems this computer's own checks see (the doctor's codes, D-101), as facts without data.
    fn device_health(
        &self,
        agents: &[antenna_proto::control::AgentInfo],
        update: &UpdateFacts,
    ) -> Vec<HealthFact> {
        let mut out = Vec::new();
        if !self.cfg.net.relay.enabled() {
            out.push(HealthFact {
                code: "relay_disabled".into(),
                severity: "warning".into(),
                count: None,
            });
        } else {
            let (mut down, mut low) = (0u32, false);
            for rt in self.running_links() {
                if !crate::transport::home_relay(&rt.shared.endpoint).connected {
                    down += 1;
                    low |= rt.shared.trust.load(Ordering::SeqCst) <= 2;
                }
            }
            if down > 0 {
                out.push(HealthFact {
                    code: "relay_unreachable".into(),
                    severity: if low { "problem" } else { "warning" }.into(),
                    count: Some(down),
                });
            }
        }
        let refused = agents
            .iter()
            .filter(|a| a.session.refused_alive == Some(true))
            .count();
        if refused > 0 {
            out.push(HealthFact {
                code: "token_bound_elsewhere".into(),
                severity: "problem".into(),
                count: Some(u32::try_from(refused).unwrap_or(u32::MAX)),
            });
        }
        if update.last_result.as_deref() == Some("failed") {
            out.push(HealthFact {
                code: "update_failed".into(),
                severity: "warning".into(),
                count: None,
            });
        }
        out.truncate(device::MAX_HEALTH);
        out
    }

    /// The status this computer tells its other devices, without the per-device `accepts`.
    fn device_status_common(&self) -> Result<DeviceStatus> {
        let (name, os_version, memory) = self.device_machine().clone();
        let info = self.update_auto_info();
        let update = UpdateFacts {
            auto: info.enabled,
            staged: info.staged.as_ref().map(|s| device::cut(&s.version, 64)),
            staged_state: info.staged.as_ref().map(|s| device::cut(&s.state, 64)),
            last: info.last.as_ref().map(|l| device::cut(&l.version, 64)),
            last_result: info.last.as_ref().map(|l| device::cut(&l.result, 64)),
            last_at_ms: info.last.as_ref().map(|l| l.at_ms),
        };
        let agent_infos = self.agent_list()?;
        let agents: Vec<DeviceAgent> = agent_infos
            .iter()
            .take(device::MAX_AGENTS)
            .map(|a| {
                let s = &a.session;
                let (app, state) = if a.local_model.is_some() {
                    (Some("local".to_string()), "local")
                } else if s.bound_alive == Some(true) {
                    (s.bound_comm.as_deref().and_then(app_name), "connected")
                } else {
                    (s.bound_comm.as_deref().and_then(app_name), "idle")
                };
                DeviceAgent {
                    name: a.name.clone(),
                    app,
                    state: state.into(),
                    last_seen_ms: s.last_seen_ms,
                    // Per link, and only to a node with `agent-connect/0` (the announcer fills them)
                    counterpart: None,
                    takes_tasks: false,
                }
            })
            .collect();
        let health = self.device_health(&agent_infos, &update);
        let (all, _) = self.approvals_list(true);
        let mut pending: Vec<_> = all.into_iter().filter(|a| a.state == "pending").collect();
        pending.sort_by_key(|a| std::cmp::Reverse(a.created_ms));
        let pending_approvals = u32::try_from(pending.len()).unwrap_or(u32::MAX);
        let approvals = pending
            .iter()
            .take(device::MAX_APPROVALS)
            .map(approval_out)
            .collect();
        let (keys, _) = self.device_keys()?;
        let now = now_ms();
        let lend = self.lends();
        let lost = devices::lost(&self.db.lock().unwrap_or_else(PoisonError::into_inner), now)?;
        let lost = lost
            .iter()
            .filter_map(|l| {
                let keys: Vec<serde_bytes::ByteBuf> = l
                    .keys
                    .iter()
                    .filter_map(|k| BASE64.decode(k.as_bytes()).ok())
                    .filter(|k| k.len() == device::PUBLIC_KEY_LEN)
                    .take(device::MAX_KEYS)
                    .map(serde_bytes::ByteBuf::from)
                    .collect();
                (!keys.is_empty()).then_some(LostDevice {
                    keys,
                    at_ms: l.at_ms,
                })
            })
            .collect();
        Ok(DeviceStatus {
            v: device::STATUS_VERSION,
            at_ms: now,
            name,
            os: std::env::consts::OS.into(),
            os_version,
            arch: std::env::consts::ARCH.into(),
            memory_bytes: memory,
            version: device::cut(&self.cfg.daemon_version, 64),
            update,
            health,
            agents,
            approvals,
            pending_approvals,
            lend,
            keys,
            accepts: Vec::new(),
            lost,
            approvers: Vec::new(),
        })
    }

    /// The links this computer tells about itself now: at level 5, the contact's node speaks `device/0`, connected.
    /// An own device that is not connected is dialled at most every [`DIAL_EVERY_MS`] (a new link has no connection
    /// until something is sent, and its features are learned on the first one); a node known to lack `device/0` is
    /// not.
    fn device_links(self: &Arc<Self>, now: u64) -> Vec<Arc<LinkRt>> {
        let mut out = Vec::new();
        for rt in self.running_links() {
            if rt.shared.trust.load(Ordering::SeqCst) != 5 {
                continue;
            }
            if rt.shared.live_conn().is_some() {
                if rt.shared.peer_supports_device() {
                    out.push(rt);
                }
                continue;
            }
            let known = rt.shared.peer_feat.load(Ordering::SeqCst) != 0;
            if known && !rt.shared.peer_supports_device() {
                continue;
            }
            let link = rt.shared.link_id;
            let due = {
                let mut g = self
                    .devices
                    .dialed
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner);
                let due = g
                    .get(&link)
                    .is_none_or(|at| now.saturating_sub(*at) >= DIAL_EVERY_MS);
                if due {
                    g.insert(link, now);
                }
                due
            };
            if due {
                tokio::spawn(async move {
                    if let Err(e) = rt.shared.connect_raw().await {
                        tracing::debug!("link {}: own device not reached: {e}", rt.shared.short());
                    }
                });
            }
        }
        out
    }

    /// Tells the owner's other devices about this computer: a status when it changed, when a new connection came up,
    /// and at least every minute; one at a time per device.
    pub(in crate::node) async fn devices_announcer(self: Arc<Self>) {
        let mut tick = tokio::time::interval(self.cfg.device_tick);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = tick.tick() => {}
                _ = self.closed_wait() => break,
            }
            let links = self.device_links(now_ms());
            if links.is_empty() {
                continue;
            }
            let common = match self.device_status_common() {
                Ok(s) => s,
                Err(e) => {
                    tracing::debug!("devices: status: {e}");
                    continue;
                }
            };
            let records = self.device_records().unwrap_or_default();
            let now = now_ms();
            for rt in links {
                let link = rt.shared.link_id;
                let Some(conn) = rt.shared.live_conn() else {
                    continue;
                };
                let mut st = common.clone();
                st.accepts = records
                    .get(&link.to_hex())
                    .map(|r| r.confirmed.iter().map(|k| k.key_id.clone()).collect())
                    .unwrap_or_default();
                // Which of this computer's agents are connected to that one's, and take its messages as tasks: only
                // to a node that parses the fields (a `device/0` node without `agent-connect/0` would refuse them)
                if rt.shared.peer_supports_agent_connect() {
                    let facts = self.connection_facts(&link);
                    for a in &mut st.agents {
                        if let Some((cp, tasks)) = facts.get(&a.name) {
                            a.counterpart = cp.clone();
                            a.takes_tasks = *tasks;
                        }
                    }
                }
                // That computer's agents the owner made approvers here, and what each may answer now (PG-57): only to
                // a node that parses the fields
                if rt.shared.peer_supports_agent_approve() {
                    self.status_approvers(&link, &mut st);
                }
                let hash = {
                    let mut h = st.clone();
                    h.at_ms = 0;
                    crypto::sha256(&[&antenna_proto::to_cbor(&h).unwrap_or_default()])
                };
                let mark = Sent {
                    conn: conn.stable_id(),
                    hash,
                    at_ms: now,
                };
                let due = match self
                    .devices
                    .sent
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .get(&link)
                {
                    Some(s) => {
                        s.conn != mark.conn
                            || s.hash != mark.hash
                            || now.saturating_sub(s.at_ms) >= HEARTBEAT_MS
                    }
                    None => true,
                };
                if !due
                    || !self
                        .devices
                        .inflight
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .insert(link)
                {
                    continue;
                }
                let me = self.clone();
                tokio::spawn(async move {
                    let r = rt
                        .shared
                        .device_send(&DeviceMsg::Status(Box::new(st)))
                        .await;
                    match r {
                        Ok(_) => {
                            me.devices
                                .sent
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .insert(link, mark);
                        }
                        Err(e) => tracing::debug!(
                            "link {}: device status not sent: {e}",
                            rt.shared.short()
                        ),
                    }
                    me.devices
                        .inflight
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .remove(&link);
                });
            }
        }
    }
}
