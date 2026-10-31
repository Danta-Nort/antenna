// SPDX-License-Identifier: Apache-2.0
//! Own devices (`docs/PROTOCOL.md` §24, experimental): what the owner's computers tell each other over their level-5
//! links, and an approval answered from another own device (D-106).
//!
//! Everything here travels as a link request `device` whose plaintext is encrypted with the link's session (Triple
//! Ratchet, like `stream_open`, §20) and is not part of the history. A node sends it only to a contact it has at trust
//! level 5 whose node announced the feature [`FEATURE_DEVICE`]; a node accepts it only from a contact it has at level 5.
//!
//! - [`DeviceStatus`]: facts about the sending computer (its name, OS, Antenna version and updates, health facts, its
//!   agents, its pending approval requests, whether it lends itself to teams, the keys it answers approvals with).
//!   Facts only: no message text, no file content, no secrets (a request's quote that contains one is withheld).
//! - A remote approval: the device where the owner is asks the computer that holds the request for a one-time
//!   challenge ([`DeviceMsg::Challenge`]), signs the exact text of a [`RemoteRequest`] with an owner key the asking
//!   computer's owner confirmed for that device (the D-102 owner proof: `"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖
//!   SHA-256(request)`, ECDSA P-256), and sends it ([`DeviceMsg::Decide`]). The computer that asked verifies it as a
//!   local proof. Only approve and deny exist; no other owner command is remote.
//!
//! - A connection between agents (the agent map, [`FEATURE_AGENT_CONNECT`]): [`DeviceMsg::Connect`] asks the recipient
//!   to set the other side of a connection the sender's owner drew (its agent's default counterpart and whose tasks it
//!   takes). The recipient changes nothing by itself: it makes an approval request, which its owner approves there or
//!   from another own device as above. The status then says which of its agents are connected to the recipient's.
//!
//! - An agent that answers approvals in the owner's place ([`FEATURE_AGENT_APPROVE`], PG-57, experimental): the
//!   computer that holds a request names, in its status, the recipient's agents its owner made approvers
//!   ([`DeviceStatus::approvers`]) and which pending requests each may answer ([`DeviceApproval::approvers`]). Such an
//!   agent's answer travels as [`DeviceMsg::AgentDecide`]: the exact text of an [`AgentDecisionText`] over a one-time
//!   challenge bound to that request ([`DeviceMsg::AgentChallenge`]), signed by the agent's own Ed25519 key in this
//!   link (its sub-identity, `docs/PROTOCOL.md` §21) under its own label ([`AGENT_DECISION_LABEL`]). It is never an
//!   owner proof: a different key, a different algorithm, a different label, a different message.
//!
//! Data and limits only; the core does the cryptography with audited crates.

use serde::{Deserialize, Serialize};

/// Node feature: own-device status and approvals from another own device (this module).
pub const FEATURE_DEVICE: &str = "device/0";
/// Node feature: connections between agents of own computers ([`DeviceMsg::Connect`], [`DeviceAgent::counterpart`],
/// [`DeviceAgent::takes_tasks`]). A node without it parses `device` strictly and would refuse them, so they go only to
/// a node that has it (`docs/PROTOCOL.md` §24).
pub const FEATURE_AGENT_CONNECT: &str = "agent-connect/0";
/// Node feature: agents that answer approvals in the owner's place ([`DeviceMsg::AgentChallenge`],
/// [`DeviceMsg::AgentDecide`], [`DeviceStatus::approvers`], [`DeviceApproval::approvers`]). Only to a node that has it:
/// a node without it parses `device` strictly and would refuse them.
pub const FEATURE_AGENT_APPROVE: &str = "agent-approve/0";
/// Node feature: the owner on one own computer stops an agent of another and the processes it started
/// ([`DeviceMsg::StopAgent`], [`DeviceReply::Stopped`]; PG-58). Only to a node that has it: a node without it parses
/// `device` strictly and would refuse the message.
pub const FEATURE_AGENT_STOP: &str = "agent-stop/0";
/// The signature context of an agent's answer: `label ‖ 0x00 ‖ nonce ‖ SHA-256(text)`, Ed25519 by the agent's key in
/// the link. Distinct from the owner proof's (`antenna/owner-proof/v1`, ECDSA P-256): neither verifies as the other.
pub const AGENT_DECISION_LABEL: &[u8] = b"antenna/agent-decision/v1";
/// The longest agent decision text, in bytes (the reason is up to 500 characters).
pub const MAX_AGENT_DECISION: usize = 4096;
/// Length of an Ed25519 signature.
pub const ED25519_SIGNATURE_LEN: usize = 64;
/// At most this many of the recipient's agents named approvers in one status, and per request.
pub const MAX_APPROVERS: usize = 16;
/// Version of [`DeviceStatus`].
pub const STATUS_VERSION: u8 = 0;
/// At most this many agents in a status.
pub const MAX_AGENTS: usize = 64;
/// At most this many pending approval requests in a status (the count says how many there are in all).
pub const MAX_APPROVALS: usize = 32;
/// At most this many health facts.
pub const MAX_HEALTH: usize = 16;
/// At most this many keys a device answers approvals with: the owner keys (8, D-102) and its own device key.
pub const MAX_KEYS: usize = 9;
/// At most this many computers reported as lost in one status.
pub const MAX_LOST: usize = 32;
/// The longest quote of an approval request that travels, in bytes (cut on a character boundary).
pub const MAX_QUOTE: usize = 1024;
/// The longest remote request text, in bytes.
pub const MAX_REQUEST: usize = 1024;
/// Length of an uncompressed P-256 public key (X9.62: `0x04 ‖ X ‖ Y`).
pub const PUBLIC_KEY_LEN: usize = 65;
/// Length of a fixed-size P-256 signature (`r ‖ s`).
pub const SIGNATURE_LEN: usize = 64;
/// `kind` of a key the device's owner touches (a Secure Enclave key behind Touch ID).
pub const KEY_TOUCH_ID: &str = "touch_id";
/// `kind` of the device's own key, used by its daemon only after the owner typed the password there.
pub const KEY_PASSWORD: &str = "password";

/// The plaintext of a `device` link request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum DeviceMsg {
    /// Facts about the sending computer. Reply: `ok`.
    Status(Box<DeviceStatus>),
    /// A one-time challenge for one remote decision on this link. Reply: [`DeviceReply::Challenge`].
    Challenge {},
    /// An answer to one of the recipient's approval requests. Reply: [`DeviceReply::Decided`], or `rejected` with the
    /// error code.
    Decide(RemoteDecision),
    /// Set or clear the other side of a connection between agents ([`FEATURE_AGENT_CONNECT`]): the recipient makes an
    /// approval request for it. Reply: [`DeviceReply::ConnectAsked`], or `rejected` with the error code.
    Connect(ConnectAsk),
    /// A one-time challenge for one agent's answer to the recipient's approval request `id`
    /// ([`FEATURE_AGENT_APPROVE`]). Reply: [`DeviceReply::Challenge`], or `rejected` with the error code.
    AgentChallenge {
        /// The approval request it is for.
        id: String,
    },
    /// An approver agent's answer to one of the recipient's approval requests ([`FEATURE_AGENT_APPROVE`]). Reply:
    /// [`DeviceReply::Decided`], or `rejected` with the error code.
    AgentDecide(AgentDecision),
    /// The sender's owner stops one of the recipient's agents and the processes it started ([`FEATURE_AGENT_STOP`],
    /// PG-58). Reply: [`DeviceReply::Stopped`], or `rejected` with the error code.
    StopAgent {
        /// The recipient's agent, by the name it announced on this link (or the name the recipient's status gave).
        agent: String,
    },
}

/// The most process names a [`DeviceReply::Stopped`] carries.
pub const MAX_STOPPED_NAMES: usize = 16;
/// The longest process name in a [`DeviceReply::Stopped`], in bytes.
pub const MAX_STOPPED_NAME: usize = 64;

/// An approver agent's answer: the exact text that was signed, the recipient's challenge, the agent's signature.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentDecision {
    /// An [`AgentDecisionText`] as JSON, byte for byte what was signed (≤ [`MAX_AGENT_DECISION`]).
    pub request: String,
    /// The recipient's challenge, issued for this request on this link.
    #[serde(with = "serde_bytes")]
    pub nonce: [u8; 32],
    /// Ed25519 over [`agent_decision_message`] by the agent's key in this link.
    #[serde(with = "serde_bytes")]
    pub sig: Vec<u8>,
}

impl std::fmt::Debug for AgentDecision {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AgentDecision")
            .field("request_len", &self.request.len())
            .finish_non_exhaustive()
    }
}

impl AgentDecision {
    /// Sizes.
    pub fn check(&self) -> Result<(), &'static str> {
        if self.request.is_empty() || self.request.len() > MAX_AGENT_DECISION {
            return Err("request");
        }
        if self.sig.len() != ED25519_SIGNATURE_LEN {
            return Err("sig");
        }
        Ok(())
    }
}

/// What an approver agent's answer says, as the JSON text that is signed. It names the link (as the signer's node
/// knows it), the request and its fingerprint, the agent and its key, so an answer made for one request or one
/// computer cannot be used for another.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentDecisionText {
    /// Always [`AgentDecisionText::CMD`]: the text says what it is, so it is never read as another signed text.
    pub cmd: String,
    /// The link between the two computers (64 hex).
    pub link: String,
    /// The approval request.
    pub id: String,
    /// Its fingerprint, as the approver read it.
    pub fingerprint: String,
    /// `approve` or `deny`.
    pub decision: String,
    /// The agent, by the name it announced on this link.
    pub agent: String,
    /// Its public key in this link (64 hex), which signs.
    pub key: String,
    /// Its reason, for the owner (≤ 500 characters).
    pub reason: String,
    /// The signer's node checked that the agent's session read nothing of a contact below level 5 there.
    pub clean: bool,
}

impl AgentDecisionText {
    /// The value of [`Self::cmd`].
    pub const CMD: &'static str = "agent_decision";

    /// Strict parse of the signed text: exactly this object, nothing else.
    pub fn parse(text: &str) -> Result<Self, String> {
        if text.len() > MAX_AGENT_DECISION {
            return Err("the answer is too long".into());
        }
        let t: Self = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if t.cmd != Self::CMD {
            return Err(format!("cmd is {}", Self::CMD));
        }
        let hex = |s: &str, n: usize| {
            s.len() == n && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        };
        if !hex(&t.link, 64) || !hex(&t.key, 64) {
            return Err("link and key are 64 lowercase hex".into());
        }
        if !matches!(t.decision.as_str(), "approve" | "deny") {
            return Err("decision is approve or deny".into());
        }
        if !name_ok(&t.agent) || !text_ok(&t.id, 32) || !text_ok(&t.fingerprint, 64) {
            return Err("agent, id or fingerprint".into());
        }
        if t.reason.trim().is_empty()
            || t.reason.chars().count() > crate::control::REASON_MAX_CHARS
            || t.reason.chars().any(char::is_control)
        {
            return Err("the reason is 1–500 characters on one line".into());
        }
        Ok(t)
    }

    /// The text that is signed (compact JSON, fields in this order).
    pub fn to_text(&self) -> String {
        // A struct of strings and a bool always serializes
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// The message an approver agent's key signs: [`AGENT_DECISION_LABEL`] ‖ 0x00 ‖ nonce ‖ SHA-256(text).
pub fn agent_decision_message(nonce: &[u8; 32], text_hash: &[u8; 32]) -> Vec<u8> {
    let mut m = Vec::with_capacity(AGENT_DECISION_LABEL.len() + 1 + 64);
    m.extend_from_slice(AGENT_DECISION_LABEL);
    m.push(0);
    m.extend_from_slice(nonce);
    m.extend_from_slice(text_hash);
    m
}

/// One of the recipient's agents the sender accepts approval answers from, with the scope the sender's owner set
/// ([`FEATURE_AGENT_APPROVE`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StatusApprover {
    /// The recipient's agent, by the name it announced on this link.
    pub agent: String,
    /// Whose requests (the sender's agents); absent: all of them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agents: Option<Vec<String>>,
    /// Which kinds; absent: all delegable kinds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Vec<String>>,
}

impl StatusApprover {
    fn check(&self) -> bool {
        name_ok(&self.agent)
            && self
                .agents
                .as_ref()
                .is_none_or(|a| a.len() <= MAX_AGENTS && a.iter().all(|n| name_ok(n)))
            && self
                .kinds
                .as_ref()
                .is_none_or(|k| crate::control::kinds_ok(k))
    }
}

/// The other side of a connection the sender's owner drew: the recipient's agent `agent` gets the sender's agent
/// `peer_agent` as its default counterpart on this link (`None`: its counterpart on this link is cleared), and takes
/// the sender's messages as tasks (`tasks`), once the recipient's owner approves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectAsk {
    /// The recipient's agent.
    pub agent: String,
    /// The sender's agent, as it announced itself on this link; `None`: disconnect.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_agent: Option<String>,
    /// The recipient's agent takes the sender's messages as tasks (`true`) or not (`false`); `None`: unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tasks: Option<bool>,
}

impl ConnectAsk {
    /// Agent names as §21 announces them.
    pub fn check(&self) -> Result<(), &'static str> {
        if !name_ok(&self.agent) || self.peer_agent.as_deref().is_some_and(|n| !name_ok(n)) {
            return Err("agent");
        }
        if self.peer_agent.is_none() && self.tasks == Some(true) {
            return Err("tasks");
        }
        Ok(())
    }
}

/// The encrypted reply to a `device` request that needs one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum DeviceReply {
    /// A challenge: 32 random bytes, valid until `expires_ms`, good for one proof sent on this link.
    Challenge {
        /// The nonce.
        #[serde(with = "serde_bytes")]
        nonce: [u8; 32],
        /// When it expires (the issuer's clock, Unix ms).
        expires_ms: u64,
    },
    /// The request was decided: its state now (`approved`, `denied`).
    Decided {
        /// Approval request ID.
        id: String,
        /// Its state.
        state: String,
    },
    /// A [`DeviceMsg::Connect`] was taken: `pending` with the approval request's ID, or `unchanged` when the recipient
    /// already has exactly that (no request, `id` empty).
    ConnectAsked {
        /// Approval request ID (empty for `unchanged`).
        id: String,
        /// `pending` or `unchanged`.
        state: String,
    },
    /// A [`DeviceMsg::StopAgent`] was carried out (PG-58).
    Stopped {
        /// The agent.
        agent: String,
        /// What was stopped: `terminal`, `process`, `app`, `resident`, `wake`, `worker`, `local` or `none`
        /// (CONTROL §33).
        how: String,
        /// How many processes got a signal.
        processes: u32,
        /// How many were still alive afterwards.
        left: u32,
        /// Their distinct names, at most [`MAX_STOPPED_NAMES`] of at most [`MAX_STOPPED_NAME`] bytes.
        names: Vec<String>,
    },
}

impl DeviceReply {
    /// The limits of a [`DeviceReply::Stopped`] from another computer (its names are shown to the owner).
    pub fn check(&self) -> Result<(), &'static str> {
        if let DeviceReply::Stopped {
            agent, how, names, ..
        } = self
        {
            if agent.len() > 64 || how.len() > 16 || names.len() > MAX_STOPPED_NAMES {
                return Err("stopped");
            }
            if names
                .iter()
                .any(|n| n.len() > MAX_STOPPED_NAME || n.chars().any(char::is_control))
            {
                return Err("stopped");
            }
        }
        Ok(())
    }
}

/// An answer to an approval request of the recipient: the exact text that was signed, and the proof.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoteDecision {
    /// A [`RemoteRequest`] as JSON text, byte for byte what was signed (≤ [`MAX_REQUEST`]).
    pub request: String,
    /// The recipient's challenge (approve only).
    #[serde(default, skip_serializing_if = "Option::is_none", with = "serde_bytes")]
    pub nonce: Option<[u8; 32]>,
    /// The signing key's ID (approve only): 16 hex, the first 8 bytes of SHA-256 of its public key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_id: Option<String>,
    /// The signature, 64 bytes `r ‖ s` (approve only).
    #[serde(default, skip_serializing_if = "Option::is_none", with = "serde_bytes")]
    pub sig: Option<Vec<u8>>,
}

impl std::fmt::Debug for RemoteDecision {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RemoteDecision")
            .field("request", &self.request)
            .field("key_id", &self.key_id)
            .finish_non_exhaustive()
    }
}

impl RemoteDecision {
    /// Sizes: the request text, the key ID, the signature.
    pub fn check(&self) -> Result<(), &'static str> {
        if self.request.is_empty() || self.request.len() > MAX_REQUEST {
            return Err("request");
        }
        if let Some(k) = &self.key_id
            && !is_key_id(k)
        {
            return Err("key_id");
        }
        if self.sig.as_ref().is_some_and(|s| s.len() != SIGNATURE_LEN) {
            return Err("sig");
        }
        Ok(())
    }
}

/// What a remote decision says, as the JSON text that is signed. The text names the link it travels on (its ID as the
/// signer's node knows it), so a proof made for one device's request cannot be relayed over another link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case", deny_unknown_fields)]
pub enum RemoteRequest {
    /// Approve request `id`, which the owner was shown with `fingerprint`.
    RemoteApprove {
        /// The link between the two devices (64 hex).
        link: String,
        /// Approval request ID.
        id: String,
        /// `ApprovalInfo.fingerprint`: the approval applies only to that request.
        fingerprint: String,
    },
    /// Deny request `id` (needs no signature, as a local `deny` needs no password, D-84).
    RemoteDeny {
        /// The link between the two devices (64 hex).
        link: String,
        /// Approval request ID.
        id: String,
    },
}

impl RemoteRequest {
    /// Strict parse of the signed text: exactly one object of one of the two shapes, nothing else.
    pub fn parse(text: &str) -> Result<Self, String> {
        if text.len() > MAX_REQUEST {
            return Err("the request is too long".into());
        }
        serde_json::from_str(text).map_err(|e| e.to_string())
    }

    /// The text a client signs (compact JSON, fields in this order).
    pub fn to_text(&self) -> String {
        // A struct of strings always serializes
        serde_json::to_string(self).unwrap_or_default()
    }

    /// The link it names.
    pub fn link(&self) -> &str {
        match self {
            RemoteRequest::RemoteApprove { link, .. } | RemoteRequest::RemoteDeny { link, .. } => {
                link
            }
        }
    }

    /// The approval request it names.
    pub fn id(&self) -> &str {
        match self {
            RemoteRequest::RemoteApprove { id, .. } | RemoteRequest::RemoteDeny { id, .. } => id,
        }
    }
}

/// Facts about the sending computer (its owner's own device).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceStatus {
    /// [`STATUS_VERSION`].
    pub v: u8,
    /// When it was made (the sender's clock, Unix ms).
    pub at_ms: u64,
    /// The computer's name (its host name), ≤ 64 bytes.
    pub name: String,
    /// `macos`, `linux`.
    pub os: String,
    /// The OS release (`27.0`, `Ubuntu 26.04 LTS`), ≤ 64 bytes; empty when unknown.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub os_version: String,
    /// `aarch64`, `x86_64`.
    pub arch: String,
    /// Total memory, bytes (0 when unknown).
    #[serde(default)]
    pub memory_bytes: u64,
    /// The daemon's version (`antennad 0.2.0 (abc1234)`), ≤ 64 bytes.
    pub version: String,
    /// Updates that install by themselves (D-103).
    pub update: UpdateFacts,
    /// Problems the computer's own checks see (the codes of `antenna doctor`).
    pub health: Vec<HealthFact>,
    /// Its agents.
    pub agents: Vec<DeviceAgent>,
    /// Its pending approval requests, newest first (at most [`MAX_APPROVALS`]).
    pub approvals: Vec<DeviceApproval>,
    /// How many approval requests are pending in all.
    pub pending_approvals: u32,
    /// "Lend this computer to my teams" is on (PG-14; the teams read it).
    pub lend: bool,
    /// The keys this computer answers other devices' approval requests with.
    pub keys: Vec<DeviceKey>,
    /// Which of the recipient's keys the sender accepts approvals from (its owner confirmed them), by key ID.
    pub accepts: Vec<String>,
    /// Owner keys of computers the sender's owner removed as lost (each entry: one computer's keys).
    pub lost: Vec<LostDevice>,
    /// The recipient's agents the sender's owner made approvers, with their scopes ([`FEATURE_AGENT_APPROVE`] only;
    /// absent when none, so a status without them is byte for byte the older encoding).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub approvers: Vec<StatusApprover>,
}

/// Updates that install by themselves, as the sending computer sees them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateFacts {
    /// "Install signed updates by itself" is on.
    pub auto: bool,
    /// A verified release waits to be installed: its version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub staged: Option<String>,
    /// Its state: `waiting`, `soon`, `installing`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub staged_state: Option<String>,
    /// The last automatic install or refusal: the version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last: Option<String>,
    /// Its result: `installed`, `failed`, `refused`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_result: Option<String>,
    /// When (Unix ms).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_at_ms: Option<u64>,
}

/// One health fact: a code of `antenna doctor` (`relay_unreachable`, `token_bound_elsewhere`, …).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HealthFact {
    /// The code.
    pub code: String,
    /// `problem` or `warning`.
    pub severity: String,
    /// How many (links, agents), when it counts something.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<u32>,
}

/// One agent of the sending computer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceAgent {
    /// Its name.
    pub name: String,
    /// The program it runs as (`claude`, `codex`, the bound process's command name) or `local` for a local model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// `connected` (a process holds its token), `idle`, `local`.
    pub state: String,
    /// When it last reached its daemon (Unix ms).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_ms: Option<u64>,
    /// Its default counterpart is the recipient's agent of this name, or the recipient's person when `""`
    /// ([`FEATURE_AGENT_CONNECT`]; absent: none on this link). A counterpart on another link is never told.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub counterpart: Option<String>,
    /// It takes the recipient's messages as tasks (D-88; [`FEATURE_AGENT_CONNECT`] only).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub takes_tasks: bool,
}

/// One pending approval request of the sending computer (what its owner would see on the card there).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceApproval {
    /// Request ID.
    pub id: String,
    /// Action (`send_message`, `share_file`, `check:exec`…).
    pub action: String,
    /// Who asks: the agent's name or `owner`.
    pub requester: String,
    /// The contact it is about (the sender's label).
    pub contact: String,
    /// That contact's level there.
    pub contact_trust: u8,
    /// To whom, for a send (the sender's label).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// Why approval is needed (machine-readable).
    pub reasons: Vec<String>,
    /// The request's text, cut to [`MAX_QUOTE`] bytes; empty when withheld.
    pub quote: String,
    /// The quote is withheld because it contains a secret (the reasons say which kind).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub quote_withheld: bool,
    /// The request's fingerprint: an approval applies only to it.
    pub fingerprint: String,
    /// Created and expires (the sender's clock, Unix ms).
    pub created_ms: u64,
    /// Expires.
    pub expires_ms: u64,
    /// After an approval the daemon carries the request out itself (D-100).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub completes: bool,
    /// Which of the recipient's approver agents may answer it now ([`FEATURE_AGENT_APPROVE`] only; absent: none).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub approvers: Vec<String>,
}

/// A key the sending computer answers approvals with.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceKey {
    /// 16 hex: the first 8 bytes of SHA-256 of the public key.
    pub key_id: String,
    /// The 65-byte uncompressed P-256 point.
    #[serde(with = "serde_bytes")]
    pub public: Vec<u8>,
    /// Its label there (`touchid@Mayas-MacBook-Pro`, `password`).
    pub label: String,
    /// [`KEY_TOUCH_ID`] or [`KEY_PASSWORD`].
    pub kind: String,
}

/// A computer the sender's owner removed as lost: the public keys it had announced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LostDevice {
    /// Its public keys (65 bytes each).
    pub keys: Vec<serde_bytes::ByteBuf>,
    /// When it was removed (Unix ms).
    pub at_ms: u64,
}

/// 16 lowercase hex characters.
pub fn is_key_id(s: &str) -> bool {
    s.len() == 16 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Text from another node: at most `max` bytes, no control characters.
fn text_ok(s: &str, max: usize) -> bool {
    s.len() <= max && !s.chars().any(char::is_control)
}

fn name_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

impl DeviceStatus {
    /// Every limit of `docs/PROTOCOL.md` §24; the field that broke it.
    pub fn check(&self) -> Result<(), &'static str> {
        if self.v != STATUS_VERSION {
            return Err("v");
        }
        if !text_ok(&self.name, 64)
            || !text_ok(&self.os, 32)
            || !text_ok(&self.os_version, 64)
            || !text_ok(&self.arch, 16)
            || !text_ok(&self.version, 64)
        {
            return Err("facts");
        }
        let u = &self.update;
        let short = |o: &Option<String>| o.as_deref().is_none_or(|s| text_ok(s, 64));
        if !short(&u.staged) || !short(&u.staged_state) || !short(&u.last) || !short(&u.last_result)
        {
            return Err("update");
        }
        if self.health.len() > MAX_HEALTH
            || self.health.iter().any(|h| {
                !text_ok(&h.code, 32) || !matches!(h.severity.as_str(), "problem" | "warning")
            })
        {
            return Err("health");
        }
        if self.agents.len() > MAX_AGENTS
            || self.agents.iter().any(|a| {
                !name_ok(&a.name)
                    || a.app.as_deref().is_some_and(|x| !text_ok(x, 32))
                    || !text_ok(&a.state, 16)
                    || a.counterpart
                        .as_deref()
                        .is_some_and(|c| !c.is_empty() && !name_ok(c))
            })
        {
            return Err("agents");
        }
        if self.approvals.len() > MAX_APPROVALS || self.approvals.iter().any(|a| a.check().is_err())
        {
            return Err("approvals");
        }
        if self.keys.len() > MAX_KEYS || self.keys.iter().any(|k| k.check().is_err()) {
            return Err("keys");
        }
        if self.accepts.len() > MAX_KEYS || self.accepts.iter().any(|k| !is_key_id(k)) {
            return Err("accepts");
        }
        if self.lost.len() > MAX_LOST
            || self.lost.iter().any(|l| {
                l.keys.is_empty()
                    || l.keys.len() > MAX_KEYS
                    || l.keys.iter().any(|k| k.len() != PUBLIC_KEY_LEN)
            })
        {
            return Err("lost");
        }
        if self.approvers.len() > MAX_APPROVERS || self.approvers.iter().any(|a| !a.check()) {
            return Err("approvers");
        }
        Ok(())
    }
}

impl DeviceApproval {
    /// Sizes and characters.
    pub fn check(&self) -> Result<(), &'static str> {
        let ok = text_ok(&self.id, 32)
            && text_ok(&self.action, 64)
            && text_ok(&self.requester, 64)
            && text_ok(&self.contact, 256)
            && self.target.as_deref().is_none_or(|t| text_ok(t, 256))
            && self.reasons.len() <= 16
            && self.reasons.iter().all(|r| text_ok(r, 64))
            // The quote is the request's own text: newlines and tabs are part of it
            && self.quote.len() <= MAX_QUOTE
            && text_ok(&self.fingerprint, 64)
            && (1..=5).contains(&self.contact_trust)
            && self.approvers.len() <= MAX_APPROVERS
            && self.approvers.iter().all(|a| name_ok(a));
        if ok { Ok(()) } else { Err("approval") }
    }
}

impl DeviceKey {
    /// A key ID, a 65-byte uncompressed point (the curve check is the core's), a label, a known kind.
    pub fn check(&self) -> Result<(), &'static str> {
        let ok = is_key_id(&self.key_id)
            && self.public.len() == PUBLIC_KEY_LEN
            && self.public.first() == Some(&0x04)
            && !self.label.is_empty()
            && text_ok(&self.label, 64)
            && matches!(self.kind.as_str(), KEY_TOUCH_ID | KEY_PASSWORD);
        if ok { Ok(()) } else { Err("key") }
    }
}

/// `quote` cut to at most `max` bytes on a character boundary.
pub fn cut(quote: &str, max: usize) -> String {
    if quote.len() <= max {
        return quote.to_string();
    }
    let mut i = max;
    while !quote.is_char_boundary(i) {
        i -= 1;
    }
    quote[..i].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{from_cbor, to_cbor};

    pub(crate) fn status() -> DeviceStatus {
        DeviceStatus {
            v: STATUS_VERSION,
            at_ms: 1_791_000_000_000,
            name: "mac-mini".into(),
            os: "macos".into(),
            os_version: "27.0".into(),
            arch: "aarch64".into(),
            memory_bytes: 64 << 30,
            version: "antennad 0.2.0".into(),
            update: UpdateFacts {
                auto: true,
                staged: Some("0.2.1".into()),
                staged_state: Some("waiting".into()),
                ..Default::default()
            },
            health: vec![HealthFact {
                code: "relay_unreachable".into(),
                severity: "warning".into(),
                count: Some(2),
            }],
            agents: vec![DeviceAgent {
                name: "codex".into(),
                app: Some("codex".into()),
                state: "connected".into(),
                last_seen_ms: Some(1),
                counterpart: None,
                takes_tasks: false,
            }],
            approvals: vec![DeviceApproval {
                id: "k2ab9c1d".into(),
                action: "send_message".into(),
                requester: "codex".into(),
                contact: "Bob".into(),
                contact_trust: 3,
                target: Some("Bob".into()),
                reasons: vec!["secret:password".into()],
                quote: String::new(),
                quote_withheld: true,
                fingerprint: "9c41e07a3b5d0f12".into(),
                created_ms: 1,
                expires_ms: 2,
                completes: true,
                approvers: vec![],
            }],
            pending_approvals: 1,
            lend: false,
            keys: vec![DeviceKey {
                key_id: "01b3e9c533123cb8".into(),
                public: [vec![4u8], vec![7; 64]].concat(),
                label: "password".into(),
                kind: KEY_PASSWORD.into(),
            }],
            accepts: vec!["a1b2c3d4e5f60718".into()],
            lost: vec![LostDevice {
                keys: vec![serde_bytes::ByteBuf::from(
                    [vec![4u8], vec![1; 64]].concat(),
                )],
                at_ms: 3,
            }],
            approvers: vec![],
        }
    }

    #[test]
    fn messages_round_trip_and_have_their_wire_shape() {
        let s = status();
        assert_eq!(s.check(), Ok(()));
        for m in [
            DeviceMsg::Status(Box::new(s.clone())),
            DeviceMsg::Challenge {},
            DeviceMsg::Decide(RemoteDecision {
                request: RemoteRequest::RemoteApprove {
                    link: "ab".repeat(32),
                    id: "k2".into(),
                    fingerprint: "9c41".into(),
                }
                .to_text(),
                nonce: Some([5; 32]),
                key_id: Some("01b3e9c533123cb8".into()),
                sig: Some(vec![1; 64]),
            }),
            DeviceMsg::Decide(RemoteDecision {
                request: "{}".into(),
                nonce: None,
                key_id: None,
                sig: None,
            }),
            DeviceMsg::Connect(ConnectAsk {
                agent: "session-2".into(),
                peer_agent: Some("volna".into()),
                tasks: Some(true),
            }),
            DeviceMsg::Connect(ConnectAsk {
                agent: "session-2".into(),
                peer_agent: None,
                tasks: None,
            }),
            DeviceMsg::AgentChallenge { id: "k2".into() },
            DeviceMsg::AgentDecide(AgentDecision {
                request: "{}".into(),
                nonce: [3; 32],
                sig: vec![2; 64],
            }),
        ] {
            assert_eq!(from_cbor::<DeviceMsg>(&to_cbor(&m).unwrap()).unwrap(), m);
        }
        let v: ciborium::Value = from_cbor(&to_cbor(&DeviceMsg::Challenge {}).unwrap()).unwrap();
        assert_eq!(v.as_map().unwrap()[0].0.as_text(), Some("challenge"));
        for r in [
            DeviceReply::Challenge {
                nonce: [9; 32],
                expires_ms: 7,
            },
            DeviceReply::Decided {
                id: "k2".into(),
                state: "approved".into(),
            },
            DeviceReply::ConnectAsked {
                id: "k3".into(),
                state: "pending".into(),
            },
        ] {
            assert_eq!(from_cbor::<DeviceReply>(&to_cbor(&r).unwrap()).unwrap(), r);
        }
    }

    /// PG-58: the stop request and its answer round-trip; the answer's names are bounded; an older node's strict
    /// `device` parser has no such message (the sender checks `agent-stop/0` first).
    #[test]
    fn stop_agent_round_trips_and_its_answer_is_bounded() {
        let m = DeviceMsg::StopAgent {
            agent: "claude-code".into(),
        };
        let bytes = to_cbor(&m).unwrap();
        assert_eq!(from_cbor::<DeviceMsg>(&bytes).unwrap(), m);
        let v: ciborium::Value = from_cbor(&bytes).unwrap();
        assert_eq!(v.as_map().unwrap()[0].0.as_text(), Some("stop_agent"));
        #[derive(Deserialize)]
        #[serde(rename_all = "snake_case", deny_unknown_fields)]
        #[allow(dead_code, reason = "only parsed, to see it refused")]
        enum OlderMsg {
            Status(Box<DeviceStatus>),
            Challenge {},
            Decide(RemoteDecision),
            Connect(ConnectAsk),
            AgentChallenge { id: String },
            AgentDecide(AgentDecision),
        }
        assert!(from_cbor::<OlderMsg>(&bytes).is_err());
        let ok = DeviceReply::Stopped {
            agent: "claude-code".into(),
            how: "terminal".into(),
            processes: 3,
            left: 0,
            names: vec!["claude".into(), "sleep".into()],
        };
        assert_eq!(ok.check(), Ok(()));
        assert_eq!(
            from_cbor::<DeviceReply>(&to_cbor(&ok).unwrap()).unwrap(),
            ok
        );
        let mut many = ok.clone();
        if let DeviceReply::Stopped { names, .. } = &mut many {
            *names = (0..=MAX_STOPPED_NAMES).map(|i| format!("p{i}")).collect();
        }
        assert!(many.check().is_err());
        let mut bad = ok;
        if let DeviceReply::Stopped { names, .. } = &mut bad {
            *names = vec!["evil\u{1b}[2J".into()];
        }
        assert!(bad.check().is_err());
    }

    /// A status with the connection fields is the old encoding when they are empty, so a node without
    /// `agent-connect/0` still parses it; with them it is refused by the strict old shape (the sender checks the
    /// feature first).
    #[test]
    fn connection_fields_are_absent_when_empty() {
        let s = status();
        let v: ciborium::Value = from_cbor(&to_cbor(&s.agents[0]).unwrap()).unwrap();
        let keys: Vec<_> = v
            .as_map()
            .unwrap()
            .iter()
            .map(|(k, _)| k.as_text().unwrap().to_string())
            .collect();
        assert_eq!(keys, ["name", "app", "state", "last_seen_ms"]);
        let mut a = s.agents[0].clone();
        a.counterpart = Some("volna".into());
        a.takes_tasks = true;
        assert_eq!(from_cbor::<DeviceAgent>(&to_cbor(&a).unwrap()).unwrap(), a);
    }

    /// The approver fields (PG-57) are absent when empty, so a status without them is the old encoding a node without
    /// `agent-approve/0` parses; with them it round-trips and is checked.
    #[test]
    fn approver_fields_are_absent_when_empty_and_checked() {
        let s = status();
        assert_eq!(
            to_cbor(&s).unwrap(),
            to_cbor(&DeviceStatus {
                approvers: vec![],
                ..s.clone()
            })
            .unwrap()
        );
        let v: ciborium::Value = from_cbor(&to_cbor(&s.approvals[0]).unwrap()).unwrap();
        assert!(
            !v.as_map()
                .unwrap()
                .iter()
                .any(|(k, _)| k.as_text() == Some("approvers"))
        );
        let mut s = status();
        s.approvers = vec![StatusApprover {
            agent: "volna".into(),
            agents: Some(vec!["codex".into()]),
            kinds: Some(vec!["send_message".into()]),
        }];
        s.approvals[0].approvers = vec!["volna".into()];
        assert_eq!(s.check(), Ok(()));
        assert_eq!(from_cbor::<DeviceStatus>(&to_cbor(&s).unwrap()).unwrap(), s);
        let mut bad = s.clone();
        bad.approvers[0].kinds = Some(vec!["check:exec".into()]);
        assert_eq!(
            bad.check(),
            Err("approvers"),
            "tool checks are never delegated"
        );
        let mut bad = s.clone();
        bad.approvers[0].agent = "a b".into();
        assert_eq!(bad.check(), Err("approvers"));
        let mut bad = s.clone();
        bad.approvals[0].approvers = vec!["x y".into()];
        assert_eq!(bad.check(), Err("approvals"));
        let mut bad = s;
        bad.approvers = vec![bad.approvers[0].clone(); MAX_APPROVERS + 1];
        assert_eq!(bad.check(), Err("approvers"));
    }

    /// An approver's answer (PG-57): the signed text has one strict shape; the message its key signs has its own
    /// label, so it is never the owner proof's.
    #[test]
    fn agent_decisions_are_strict_and_have_their_own_context() {
        let t = AgentDecisionText {
            cmd: AgentDecisionText::CMD.into(),
            link: "ab".repeat(32),
            id: "k2abcdefg".into(),
            fingerprint: "9c41e07a3b5d0f12".into(),
            decision: "approve".into(),
            agent: "volna".into(),
            key: "cd".repeat(32),
            reason: "the build report for the server, as asked".into(),
            clean: true,
        };
        let text = t.to_text();
        assert!(
            text.starts_with(r#"{"cmd":"agent_decision","link":"#),
            "{text}"
        );
        assert_eq!(AgentDecisionText::parse(&text).unwrap(), t);
        for bad in [
            text.replace(r#""clean":true"#, r#""clean":true,"x":1"#),
            text.replace("agent_decision", "remote_approve"),
            text.replace(r#""decision":"approve""#, r#""decision":"trust""#),
            text.replace(&"ab".repeat(32), "ab"),
            text.replace("the build report for the server, as asked", ""),
            text.replace("the build report for the server, as asked", "line\nbreak"),
            text.replace(
                "the build report for the server, as asked",
                &"x".repeat(501),
            ),
            text.replace(r#""agent":"volna""#, r#""agent":"vol na""#),
            text.clone() + "{}",
        ] {
            assert!(AgentDecisionText::parse(&bad).is_err(), "{bad}");
        }
        let m = agent_decision_message(&[1; 32], &[2; 32]);
        assert!(m.starts_with(b"antenna/agent-decision/v1\0"));
        assert_eq!(m.len(), AGENT_DECISION_LABEL.len() + 1 + 64);
        assert_ne!(
            m,
            crate::control::owner_keys::proof_message(&[1; 32], &[2; 32]),
            "an agent's answer is never an owner proof"
        );
        let d = AgentDecision {
            request: text,
            nonce: [1; 32],
            sig: vec![0; 63],
        };
        assert_eq!(d.check(), Err("sig"));
        assert!(
            !format!("{d:?}").contains("approve"),
            "the text stays out of logs"
        );
    }

    #[test]
    fn parsing_is_strict() {
        // An unknown field in a status, an unknown message.
        let mut v: ciborium::Value = from_cbor(&to_cbor(&status()).unwrap()).unwrap();
        if let ciborium::Value::Map(m) = &mut v {
            m.push(("extra".into(), 1.into()));
        }
        assert!(from_cbor::<DeviceStatus>(&to_cbor(&v).unwrap()).is_err());
        let unknown = ciborium::Value::Map(vec![("reboot".into(), ciborium::Value::Map(vec![]))]);
        assert!(from_cbor::<DeviceMsg>(&to_cbor(&unknown).unwrap()).is_err());
        // The signed text: one of two shapes, nothing more.
        let link = "ab".repeat(32);
        let ok =
            format!(r#"{{"cmd":"remote_approve","link":"{link}","id":"k2","fingerprint":"9c"}}"#);
        assert_eq!(
            RemoteRequest::parse(&ok).unwrap(),
            RemoteRequest::RemoteApprove {
                link: link.clone(),
                id: "k2".into(),
                fingerprint: "9c".into()
            }
        );
        for bad in [
            format!(r#"{{"cmd":"remote_approve","link":"{link}","id":"k2"}}"#),
            format!(
                r#"{{"cmd":"remote_approve","link":"{link}","id":"k2","fingerprint":"9c","x":1}}"#
            ),
            format!(r#"{{"cmd":"trust","link":"{link}","id":"k2"}}"#),
            format!(r#"{{"cmd":"remote_deny","link":"{link}","id":"k2"}} "#) + "{}",
            "x".repeat(MAX_REQUEST + 1),
        ] {
            assert!(RemoteRequest::parse(&bad).is_err(), "{bad}");
        }
        // The text a client signs is the compact form, in field order.
        assert_eq!(
            RemoteRequest::RemoteDeny {
                link: "00".into(),
                id: "k2".into()
            }
            .to_text(),
            r#"{"cmd":"remote_deny","link":"00","id":"k2"}"#
        );
    }

    #[test]
    fn limits_are_checked() {
        let mut s = status();
        s.v = 1;
        assert_eq!(s.check(), Err("v"));
        let mut s = status();
        s.name = "a\u{7}b".into();
        assert_eq!(s.check(), Err("facts"));
        let mut s = status();
        s.agents[0].name = "bad name".into();
        assert_eq!(s.check(), Err("agents"));
        let mut s = status();
        s.approvals[0].quote = "x".repeat(MAX_QUOTE + 1);
        assert_eq!(s.check(), Err("approvals"));
        let mut s = status();
        s.approvals = vec![s.approvals[0].clone(); MAX_APPROVALS + 1];
        assert_eq!(s.check(), Err("approvals"));
        let mut s = status();
        s.keys[0].public = vec![2; 33];
        assert_eq!(s.check(), Err("keys"));
        let mut s = status();
        s.keys[0].kind = "root".into();
        assert_eq!(s.check(), Err("keys"));
        let mut s = status();
        s.accepts = vec!["XYZ".into()];
        assert_eq!(s.check(), Err("accepts"));
        let mut s = status();
        s.lost[0].keys.clear();
        assert_eq!(s.check(), Err("lost"));
        let mut s = status();
        s.health[0].severity = "fine".into();
        assert_eq!(s.check(), Err("health"));
        let mut s = status();
        s.agents[0].counterpart = Some("bad name".into());
        assert_eq!(s.check(), Err("agents"));
        s.agents[0].counterpart = Some(String::new());
        assert_eq!(s.check(), Ok(()), "the person");
        let ask = |agent: &str, peer: Option<&str>, tasks| ConnectAsk {
            agent: agent.into(),
            peer_agent: peer.map(Into::into),
            tasks,
        };
        assert_eq!(ask("a", Some("b"), Some(true)).check(), Ok(()));
        assert_eq!(ask("a b", Some("b"), None).check(), Err("agent"));
        assert_eq!(ask("a", Some(""), None).check(), Err("agent"));
        assert_eq!(ask("a", None, Some(true)).check(), Err("tasks"));
        assert_eq!(ask("a", None, Some(false)).check(), Ok(()));
        let d = RemoteDecision {
            request: "{}".into(),
            nonce: None,
            key_id: Some("nothex".into()),
            sig: None,
        };
        assert_eq!(d.check(), Err("key_id"));
        let d = RemoteDecision {
            sig: Some(vec![0; 63]),
            key_id: None,
            ..d
        };
        assert_eq!(d.check(), Err("sig"));
        assert_eq!(cut("ab✓c", 3), "ab");
        assert_eq!(cut("abc", 3), "abc");
    }
}
