// SPDX-License-Identifier: AGPL-3.0-only
//! Node events for control socket subscribers (`subscribe`, `docs/CONTROL.md`, v1): messages, delivery statuses,
//! contacts (level, network mode, presence), invites, approval requests.
//!
//! Inside the daemon there is one `broadcast`; `control` decides who sees what by the subscriber's role (an agent gets
//! only facts about incoming messages on its own links, without text, and only its own approval requests).

use antenna_proto::{
    LinkId,
    control::{
        ApprovalInfo, ApprovalResolution, ContactSummary, FileInfo, HistoryItem, HistoryStatus,
        InviteInfo, LocalAgentInfo, LocalModelInfo, StreamEventBody, WakeEventBody,
    },
};

/// Event queue capacity per subscriber; a subscriber that falls behind gets `lagged` and rereads the state.
pub const CAPACITY: usize = 512;

/// Node event.
#[derive(Debug, Clone)]
pub enum NodeEvent {
    /// New message (incoming or outgoing).
    Message {
        /// Link.
        link: LinkId,
        /// Contact label.
        contact: String,
        /// Trust level.
        trust: u8,
        /// Message.
        item: Box<HistoryItem>,
    },
    /// Delivery status of an outgoing message.
    Status {
        /// Link.
        link: LinkId,
        /// Contact label.
        contact: String,
        /// Message ID (hex).
        id: String,
        /// `delivered` / `failed`.
        status: &'static str,
    },
    /// A contact appeared or changed.
    Contact {
        /// Link.
        link: LinkId,
        /// Summary.
        summary: ContactSummary,
    },
    /// An invite changed phase.
    Invite(Box<InviteInfo>),
    /// An approval request was created or decided.
    Approval {
        /// Who asked (`agent:<id>` / `owner`).
        requester_id: String,
        /// Request.
        info: Box<ApprovalInfo>,
    },
    /// The link's history verification state changed (slice 3).
    History {
        /// Link.
        link: LinkId,
        /// Contact label.
        contact: String,
        /// State.
        status: Box<HistoryStatus>,
    },
    /// A link's file changed state (slice 4): offered, downloaded, checked, accepted, rejected.
    File {
        /// Link.
        link: LinkId,
        /// File (full: for an agent, `control` strips the name and details).
        info: Box<FileInfo>,
    },
    /// Link rekey: the contact asks / waiting for the contact / finished (slice 3, for the owner).
    Rekey {
        /// Link.
        link: LinkId,
        /// Contact label.
        contact: String,
        /// State.
        state: &'static str,
    },
    /// Streaming message (v0.2, for the owner): an event of a "live" bubble.
    Stream {
        /// Link.
        link: LinkId,
        /// Event.
        body: Box<StreamEventBody>,
    },
    /// Agent wake (v0.2, for the owner).
    Wake(Box<WakeEventBody>),
    /// One of the owner's agents changed (v5, for the owner): `added`, `token`, `bound`, `removed`.
    Agent {
        /// Agent name.
        name: String,
        /// What changed.
        change: String,
        /// With `stopped` (PG-58): `owner`, or the label of the own computer that asked.
        by: Option<String>,
    },
    /// What became of an approval request (D-100): carried out by the daemon, failed, approved, denied, expired.
    ApprovalResolved {
        /// Who asked (`agent:<id>` / `owner`).
        requester_id: String,
        /// The outcome.
        resolution: Box<ApprovalResolution>,
    },
    /// A local model's state changed (D-104; owner only).
    LocalModel(Box<LocalModelInfo>),
    /// A local agent's state changed (D-104; owner only).
    LocalAgent(Box<LocalAgentInfo>),
    /// An automatic install step (D-103, for the owner): staged, soon, installing, refused, failed, postponed.
    UpdateAuto(Box<antenna_proto::control::UpdateAutoEvent>),
    /// One of the owner's own devices changed (PROTOCOL §24, for the owner): `status`, `keys`, `lost`, `decided`.
    Device {
        /// Link.
        link: LinkId,
        /// Contact label.
        contact: String,
        /// What changed.
        change: &'static str,
    },
    /// A team, one of its workers or tasks changed (D-111; owner only).
    Team(Box<antenna_proto::control::TeamEvent>),
    /// The owner changed a chat's local settings (D-113; owner only: a local name says what a conversation is about).
    Chat(Box<antenna_proto::control::ChatInfo>),
    /// An agent's question was asked, answered or dismissed (D-118): the owner gets every change, the agent its own
    /// once decided.
    Escalation {
        /// The agent that asked.
        agent_id: i64,
        /// The question.
        info: Box<antenna_proto::control::EscalationInfo>,
    },
    /// A request waits for an approver's answer (PG-57; that agent only, facts without text).
    ToAnswer {
        /// The approver.
        agent_id: i64,
        /// The request.
        fact: Box<antenna_proto::control::ToAnswerFact>,
    },
    /// A message over a local route waits for an agent of this computer (D-132; that agent only, facts without text).
    LocalMessage {
        /// The recipient.
        agent_id: i64,
        /// The writer's name.
        from: String,
        /// The message's ID.
        id: String,
        /// The lowest level its writer had read (5: none).
        trust: u8,
        /// Length, characters.
        chars: u64,
        /// When it was written.
        at_ms: u64,
    },
    /// A picture changed (PROTOCOL §25; owner only): the owner chose one, a contact announced one, or a contact's
    /// photo finished its check.
    Picture(Box<antenna_proto::control::PictureEntry>),
}

/// Contact presence given the trust level (SPEC §4, Q-8): levels 1–2 have no persistent connection, so `not_tracked`.
pub fn presence(trust: u8, connected: bool) -> &'static str {
    if trust <= 2 {
        "not_tracked"
    } else if connected {
        "online"
    } else {
        "offline"
    }
}
