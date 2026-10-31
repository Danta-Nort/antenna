// SPDX-License-Identifier: AGPL-3.0-only
//! Own devices on the node (`docs/PROTOCOL.md` §24, `docs/CONTROL.md` §27, D-106; experimental): the status this
//! computer tells the owner's other computers, what it keeps of theirs, approvals answered from another own device,
//! a lost computer, and lending this computer to teams.
//!
//! Everything goes over the link of two own computers as a `device` link request, sealed with the link's session like
//! `stream_open` (not part of the history), and only between contacts at trust level 5 both ways: this node sends to
//! a contact only while it has that contact at 5 and the contact's node announced `device/0`, and it serves a request
//! only from a contact it has at 5. What is decided is decided here, by this daemon (SPEC §9): a remote approval is the
//! D-102 owner proof over this node's own challenge, by a key the owner confirmed here for that device.

mod commands;
mod delegated;
mod remote;
mod status;

use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex as StdMutex, OnceLock, PoisonError, atomic::Ordering},
    time::Duration,
};

use antenna_proto::{
    LinkId, RoutingBlob,
    control::code,
    device::{DeviceMsg, DeviceReply, DeviceStatus, RemoteDecision},
    link::{LinkRequest, LinkResponse},
};
use tokio::sync::{mpsc, oneshot};
use zeroize::Zeroizing;

use super::{LinkRt, LinkShared, Session, request};
use crate::{
    devices::{self, Records},
    error::{Error, Result},
    events::NodeEvent,
    store::LinkRow,
};

/// How often the node looks at what to tell its other devices (a status goes only when it changed).
pub(crate) const TICK: Duration = Duration::from_secs(2);
/// A status goes at least this often while connected, so the other side's "last seen" stays current.
const HEARTBEAT_MS: u64 = 60_000;
/// How long to wait for the session to answer a request of the other device.
const JOB_WAIT: Duration = Duration::from_secs(10);
/// An own device without a connection is dialled at most this often.
const DIAL_EVERY_MS: u64 = 30_000;

/// A request of another own device for the session (the link cannot reach the approvals itself).
pub(crate) enum Job {
    /// It told this computer about itself.
    Status {
        /// The link.
        link: LinkId,
        /// What it said.
        status: Box<DeviceStatus>,
    },
    /// It asks for a challenge.
    Challenge {
        /// The link.
        link: LinkId,
        /// The answer.
        reply: oneshot::Sender<Result<DeviceReply>>,
    },
    /// It answers one of this computer's approval requests.
    Decide {
        /// The link.
        link: LinkId,
        /// The answer.
        decision: RemoteDecision,
        /// The outcome.
        reply: oneshot::Sender<Result<DeviceReply>>,
    },
    /// It asks for the other side of a connection between agents (an approval request here, CONTROL §30).
    Connect {
        /// The link.
        link: LinkId,
        /// What it asks.
        ask: antenna_proto::device::ConnectAsk,
        /// The outcome.
        reply: oneshot::Sender<Result<DeviceReply>>,
    },
    /// It asks for a challenge for one of its approver agents' answers to request `id` (PG-57).
    AgentChallenge {
        /// The link.
        link: LinkId,
        /// The request.
        id: String,
        /// The answer.
        reply: oneshot::Sender<Result<DeviceReply>>,
    },
    /// One of its approver agents answers one of this computer's approval requests (PG-57).
    AgentDecide {
        /// The link.
        link: LinkId,
        /// The answer.
        decision: antenna_proto::device::AgentDecision,
        /// The outcome.
        reply: oneshot::Sender<Result<DeviceReply>>,
    },
    /// Its owner stops one of this computer's agents and the processes it started (PG-58).
    StopAgent {
        /// The link.
        link: LinkId,
        /// The agent.
        agent: String,
        /// The outcome.
        reply: oneshot::Sender<Result<DeviceReply>>,
    },
}

/// What was last sent to a device: the connection, the status without its time, when.
#[derive(Clone, PartialEq, Eq)]
struct Sent {
    conn: usize,
    hash: [u8; 32],
    at_ms: u64,
}

/// An own device that lends itself to the owner's teams (PG-14), as it last said.
pub(crate) struct LendingDevice {
    /// Its label here.
    pub(crate) contact: String,
    /// Connected now.
    pub(crate) online: bool,
    /// Its OS and CPU architecture.
    pub(crate) os: String,
    /// Its CPU architecture.
    pub(crate) arch: String,
    /// Its memory, bytes.
    pub(crate) memory_bytes: u64,
}

/// The session's part: the queue from the links, the challenges, the other devices' latest statuses.
pub(crate) struct DeviceState {
    pub(crate) tx: mpsc::UnboundedSender<Job>,
    rx: StdMutex<Option<mpsc::UnboundedReceiver<Job>>>,
    challenges: StdMutex<devices::Challenges>,
    /// The latest status of each device, with its approval requests, and when it arrived (memory only).
    latest: StdMutex<HashMap<LinkId, (DeviceStatus, u64)>>,
    sent: StdMutex<HashMap<LinkId, Sent>>,
    inflight: StdMutex<HashSet<LinkId>>,
    /// When each own device without a connection was last dialled.
    dialed: StdMutex<HashMap<LinkId, u64>>,
    /// This computer's name and OS release (read once).
    machine: OnceLock<(String, String, u64)>,
}

impl Default for DeviceState {
    fn default() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        Self {
            tx,
            rx: StdMutex::new(Some(rx)),
            challenges: StdMutex::default(),
            latest: StdMutex::default(),
            sent: StdMutex::default(),
            inflight: StdMutex::default(),
            dialed: StdMutex::default(),
            machine: OnceLock::new(),
        }
    }
}

fn level_error() -> Error {
    Error::new(
        code::FORBIDDEN,
        "that computer is not at ∞ (trust level 5) here: My devices are the contacts you set to ∞",
    )
}

fn refused(reason: String) -> Error {
    let message = match reason.as_str() {
        "level" => "the other computer does not have this one at ∞ (trust level 5)".to_string(),
        "malformed" => "the other computer's Antenna does not know own devices: update it".to_string(),
        code::CHALLENGE_INVALID => "the challenge expired or was used: try again".to_string(),
        code::PROOF_INVALID => "the other computer did not accept the signature".to_string(),
        code::OWNER_KEY_UNKNOWN => {
            "the other computer has not confirmed this key: confirm it there in My devices".to_string()
        }
        code::FORBIDDEN => {
            "the other computer has not confirmed any key of this one: confirm them there in My devices"
                .to_string()
        }
        code::APPROVAL_MISMATCH => "that request changed since it was shown: look again".to_string(),
        code::NOT_FOUND => "that request is no longer pending there".to_string(),
        other => format!("the other computer refused: {other}"),
    };
    let c = match reason.as_str() {
        "level" => code::FORBIDDEN,
        "malformed" => code::UNKNOWN_COMMAND,
        code::CHALLENGE_INVALID => code::CHALLENGE_INVALID,
        code::PROOF_INVALID => code::PROOF_INVALID,
        code::OWNER_KEY_UNKNOWN => code::OWNER_KEY_UNKNOWN,
        code::FORBIDDEN => code::FORBIDDEN,
        code::APPROVAL_MISMATCH => code::APPROVAL_MISMATCH,
        code::NOT_FOUND => code::NOT_FOUND,
        code::DENIED => code::DENIED,
        code::RATE_LIMITED => code::RATE_LIMITED,
        code::BAD_REQUEST => code::BAD_REQUEST,
        _ => code::REJECTED,
    };
    Error::new(c, message)
}

impl LinkShared {
    /// The contact's node speaks own devices (`device/0`, PROTOCOL §24).
    pub(crate) fn peer_supports_device(&self) -> bool {
        self.peer_feat.load(Ordering::SeqCst) & super::FEAT_DEVICE != 0
    }

    /// A `device` request of the contact: only from a contact at level 5 here; decrypted with the link's session,
    /// parsed strictly, then handed to the session.
    pub(super) async fn serve_device(self: &Arc<Self>, blob: RoutingBlob) -> LinkResponse {
        let reject = |reason: &str| LinkResponse::Rejected {
            reason: reason.into(),
        };
        if self.trust.load(Ordering::SeqCst) != 5 {
            // Before decryption: a contact that is not the owner's own computer gets nothing from here
            return reject("level");
        }
        let me = self.clone();
        let msg = match tokio::task::spawn_blocking(move || me.open_ephemeral(&blob)).await {
            Ok(Ok(pt)) => antenna_proto::from_cbor::<DeviceMsg>(&pt).ok(),
            _ => None,
        };
        let Some(msg) = msg else {
            return reject("malformed");
        };
        let (job, rx) = match msg {
            DeviceMsg::Status(status) => {
                if let Err(f) = status.check() {
                    tracing::debug!("link {}: device status refused: {f}", self.short());
                    return reject("malformed");
                }
                let _ = self.devices_tx.send(Job::Status {
                    link: self.link_id,
                    status,
                });
                return LinkResponse::Ok;
            }
            DeviceMsg::Challenge {} => {
                let (tx, rx) = oneshot::channel();
                (
                    Job::Challenge {
                        link: self.link_id,
                        reply: tx,
                    },
                    rx,
                )
            }
            DeviceMsg::Decide(decision) => {
                let (tx, rx) = oneshot::channel();
                (
                    Job::Decide {
                        link: self.link_id,
                        decision,
                        reply: tx,
                    },
                    rx,
                )
            }
            DeviceMsg::Connect(ask) => {
                let (tx, rx) = oneshot::channel();
                (
                    Job::Connect {
                        link: self.link_id,
                        ask,
                        reply: tx,
                    },
                    rx,
                )
            }
            DeviceMsg::AgentChallenge { id } => {
                let (tx, rx) = oneshot::channel();
                (
                    Job::AgentChallenge {
                        link: self.link_id,
                        id,
                        reply: tx,
                    },
                    rx,
                )
            }
            DeviceMsg::AgentDecide(decision) => {
                let (tx, rx) = oneshot::channel();
                (
                    Job::AgentDecide {
                        link: self.link_id,
                        decision,
                        reply: tx,
                    },
                    rx,
                )
            }
            DeviceMsg::StopAgent { agent } => {
                let (tx, rx) = oneshot::channel();
                (
                    Job::StopAgent {
                        link: self.link_id,
                        agent,
                        reply: tx,
                    },
                    rx,
                )
            }
        };
        if self.devices_tx.send(job).is_err() {
            return reject(code::INTERNAL);
        }
        let reply = match tokio::time::timeout(JOB_WAIT, rx).await {
            Ok(Ok(Ok(r))) => r,
            Ok(Ok(Err(e))) => return reject(e.code),
            _ => return reject(code::INTERNAL),
        };
        let me = self.clone();
        let sealed = tokio::task::spawn_blocking(move || {
            let pt = Zeroizing::new(antenna_proto::to_cbor(&reply)?);
            me.seal_ephemeral(&pt)
        })
        .await;
        match sealed {
            Ok(Ok(blob)) => LinkResponse::Device { blob },
            _ => reject(code::INTERNAL),
        }
    }

    /// Sends a `device` request over the live connection (or a new one) and reads the answer: `None` for `ok`.
    pub(crate) async fn device_send(
        self: &Arc<Self>,
        msg: &DeviceMsg,
    ) -> Result<Option<DeviceReply>> {
        if !self.peer_supports_device() {
            return Err(Error::new(
                code::UNKNOWN_COMMAND,
                "that computer's Antenna does not know own devices yet: update it",
            ));
        }
        let conn = self.connect_raw().await?;
        let pt = Zeroizing::new(antenna_proto::to_cbor(msg)?);
        let me = self.clone();
        let blob = tokio::task::spawn_blocking(move || me.seal_ephemeral(&pt))
            .await
            .map_err(|e| Error::internal(e.to_string()))??;
        self.touch();
        match request(&conn, &LinkRequest::Device { blob }).await? {
            LinkResponse::Ok => Ok(None),
            LinkResponse::Device { blob } => {
                let me = self.clone();
                let pt = tokio::task::spawn_blocking(move || me.open_ephemeral(&blob))
                    .await
                    .map_err(|e| Error::internal(e.to_string()))??;
                Ok(Some(antenna_proto::from_cbor::<DeviceReply>(&pt)?))
            }
            LinkResponse::Rejected { reason } => Err(refused(reason)),
            other => Err(Error::network(format!("device: {other:?}"))),
        }
    }
}

impl Session {
    fn device_records(&self) -> Result<Records> {
        devices::load(&self.db.lock().unwrap_or_else(PoisonError::into_inner))
    }

    fn device_records_update<T>(&self, f: impl FnOnce(&mut Records) -> Result<T>) -> Result<T> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let mut r = devices::load(&db)?;
        let out = f(&mut r)?;
        devices::save(&db, &r)?;
        Ok(out)
    }

    pub(crate) fn device_event(&self, link: &LinkId, change: &'static str) {
        let label = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(link)
            .map(|r| r.label)
            .unwrap_or_default();
        let _ = self.events.send(NodeEvent::Device {
            link: *link,
            contact: label,
            change,
        });
    }

    /// The trust level here of a running link (0 when it is not running).
    pub(crate) fn link_trust(&self, link: &LinkId) -> u8 {
        self.rt(link)
            .map(|rt| rt.shared.trust.load(Ordering::SeqCst))
            .unwrap_or(0)
    }

    /// The own device on `link` listed an agent of this name in its last status.
    pub(crate) fn device_lists_agent(&self, link: &LinkId, name: &str) -> bool {
        self.devices
            .latest
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(link)
            .is_some_and(|(s, _)| s.agents.iter().any(|a| a.name == name))
    }

    /// The link of an own device named by the owner: running, at level 5.
    fn device_row(&self, contact: &str) -> Result<(LinkRow, Arc<LinkRt>)> {
        let row = self.find_link(contact)?;
        if row.trust != 5 {
            return Err(level_error());
        }
        let rt = self.rt(&row.link_id)?;
        Ok((row, rt))
    }
}
