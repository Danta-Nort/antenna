// SPDX-License-Identifier: Apache-2.0
//! Link protocol after pairing: ALPN `x/link/0` (`docs/PROTOCOL.md` §12, link format v1: §16–§17).
//!
//! Each request is a separate bi-stream: a request frame, then a response frame. A frame is `u32be(len) ‖ CBOR`.
//!
//! What is visible at which layer: `deliver`, `resend`, `rekey_*` carry E2E ciphertext (Triple Ratchet). `sync`,
//! `chain`, `conflict`, `want` are history verification service frames **without message content** (hashes,
//! counters): they travel under the link's TLS 1.3 (pairwise endpoint, the contact's key pinned at pairing) and must
//! work when the ratchet is broken by a state rollback: that is how the contact detects the rollback (SPEC §8).

use serde::{Deserialize, Serialize};

use crate::{MessageId, RoutingBlob, pairing::AddrHints};

/// ALPN of the link's pairwise endpoint.
pub const ALPN_LINK: &[u8] = b"x/link/0";
/// Maximum link frame size.
pub const MAX_FRAME: usize = 1024 * 1024;
/// QUIC close code: the key is not paired with this endpoint (accept list).
pub const CLOSE_NOT_PAIRED: u32 = 403;
/// Maximum message text size in slice 1.
pub const MAX_TEXT: usize = 64 * 1024;

/// libsignal message type inside the `e2e-frame` (`CiphertextMessageType` values).
pub mod e2e_type {
    /// SignalMessage (an ordinary ratchet message).
    pub const WHISPER: u8 = 2;
    /// PreKeySignalMessage (the first message of a session).
    pub const PREKEY: u8 = 3;
}

/// Node feature: agent announcements and messages with `author` = agent key (`docs/PROTOCOL.md` §21).
pub const FEATURE_AGENTS: &str = "agents/0";
/// Node feature: addressing and topics, the `to` and `topic` fields of `envelope-core` (`docs/PROTOCOL.md` §23).
/// A node without it parses `envelope-core` strictly and refuses them, so they go only to a node that has it.
pub const FEATURE_ADDR: &str = "addr/0";
/// Node feature: the sender may withdraw a file offer the recipient has not accepted yet, with a `withdraw_file` /
/// `withdrawn` receipt (`docs/PROTOCOL.md` §19). A node without it refuses the receipt's unknown action, so it goes only
/// to a node that has it.
pub const FEATURE_FILE_WITHDRAW: &str = "file-withdraw/0";
/// Node feature: own-device status and approvals from another own device, the `device` request
/// (`docs/PROTOCOL.md` §24). Sent only to a contact at level 5 whose node has it.
pub const FEATURE_DEVICE: &str = crate::device::FEATURE_DEVICE;
/// Node feature: a message addressed to an agent the recipient's node does not have (for this link) is answered with
/// a `deliver` / `no_such_agent` receipt (`docs/PROTOCOL.md` §23). A node without it refuses the receipt's unknown
/// action, so the receipt goes only to a node that has it; a node that has it learns at once that nobody will read the
/// message instead of seeing it "delivered".
pub const FEATURE_NO_AGENT: &str = "no-agent/0";
/// Node feature: profile pictures, a `control` message with body `picture` (`docs/PROTOCOL.md` §25). A node without it
/// refuses the unknown body, so pictures go only to a node that has it; its owner keeps seeing initials.
pub const FEATURE_PICTURE: &str = "picture/0";
/// Node feature: a stream opening may name the sender's agent that writes (`stream_open`'s `agent`,
/// `docs/PROTOCOL.md` §20), so the live display shows who writes before the final message arrives. A node without it
/// parses the opening strictly and refuses the field, so the name goes only to a node that has it.
pub const FEATURE_STREAM_AGENT: &str = "stream-agent/0";
/// Node feature: a file offer may carry an address (`to` in `envelope-core` of a `file` message, `docs/PROTOCOL.md`
/// §19, §23), so only the addressed agent of the recipient's node sees it. A node without it refuses `to` on anything
/// but text, so the address goes only to a node that has it (and stays in the sender's own history otherwise).
pub const FEATURE_FILE_ADDR: &str = "file-addr/0";
/// Node feature: connections between agents of own computers, inside `device` (`docs/PROTOCOL.md` §24).
pub const FEATURE_AGENT_CONNECT: &str = crate::device::FEATURE_AGENT_CONNECT;
/// Node feature: approver agents' answers and the approver fields of a status, inside `device` (`docs/PROTOCOL.md`
/// §24, PG-57).
pub const FEATURE_AGENT_APPROVE: &str = crate::device::FEATURE_AGENT_APPROVE;
/// Node feature: an `accept_file` / `accepted` receipt may carry `name_number` (`docs/PROTOCOL.md` §19, D-128): the
/// offered name was taken at the recipient, so the file was saved as `<stem> (n).<ext>`. A node without it parses
/// receipts strictly and refuses the field, so the number goes only to a node that has it.
pub const FEATURE_FILE_SAVED_AS: &str = "file-saved-as/0";
/// Node feature: the recipient of a file tells the sender its fate (`docs/PROTOCOL.md` §19 "The file's fate",
/// D-130): a `check_file` / `held` receipt when the file waits for the recipient's owner, and `why` with the matched
/// `rules` on it and on a `reject_file` / `denied`. A node without it refuses the unknown action and fields, so they go
/// only to a node that has it.
pub const FEATURE_FILE_FATE: &str = "file-fate/0";
/// Node feature: the owner's urgent message, the `urgent` field of `envelope-core` (`docs/PROTOCOL.md` §23, PG-58). A
/// node without it parses `envelope-core` strictly and refuses the field, so it goes only to a node that has it; the
/// owner is told the message went as a normal one otherwise.
pub const FEATURE_URGENT: &str = "urgent/0";
/// Node feature: stopping an agent and its processes at the request of an own computer, inside `device`
/// (`docs/PROTOCOL.md` §24, PG-58).
pub const FEATURE_AGENT_STOP: &str = crate::device::FEATURE_AGENT_STOP;
/// Features this node knows (reply to [`LinkRequest::Features`]).
pub const FEATURES: &[&str] = &[
    FEATURE_FILE_FATE,
    FEATURE_FILE_SAVED_AS,
    FEATURE_AGENTS,
    FEATURE_ADDR,
    FEATURE_FILE_WITHDRAW,
    FEATURE_DEVICE,
    FEATURE_NO_AGENT,
    FEATURE_PICTURE,
    FEATURE_STREAM_AGENT,
    FEATURE_FILE_ADDR,
    FEATURE_AGENT_CONNECT,
    FEATURE_AGENT_APPROVE,
    FEATURE_URGENT,
    FEATURE_AGENT_STOP,
];
/// Maximum number of features in the list and maximum length of one.
pub const MAX_FEATURES: usize = 32;
/// Maximum length of a feature name.
pub const MAX_FEATURE_LEN: usize = 32;

/// Maximum number of items in one `chain` reply and in one `want`.
pub const MAX_CHAIN_POINTS: usize = 1024;
/// Maximum number of envelopes in one `resend`.
pub const MAX_RESEND: usize = 64;

/// Request over a link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum LinkRequest {
    /// The sender's address hints.
    Hello {
        /// Addresses.
        addrs: AddrHints,
    },
    /// Delivery of a new message (E2E: the plaintext is the envelope's CBOR).
    Deliver {
        /// Routing blob.
        blob: RoutingBlob,
    },
    /// Resending history during verification (E2E: the plaintext is a CBOR array of envelopes, ≤ [`MAX_RESEND`]).
    Resend {
        /// Routing blob.
        blob: RoutingBlob,
    },
    /// History verification: the sender's summary; the reply is [`LinkResponse::Sync`] with the recipient's summary.
    Sync(SyncSummary),
    /// An author's chain values, for finding where the history diverged.
    Chain(ChainQuery),
    /// The divergence point was found: the recipient checks its copy and replies with [`LinkResponse::Conflict`].
    Conflict(ConflictNote),
    /// Please resend the messages with these IDs (missing parents, restoring a damaged copy), ≤ 1024.
    Want {
        /// ID.
        ids: Vec<MessageId>,
    },
    /// Rekey after a rollback: a fresh prekey bundle of the side, signed by its link-root (§17).
    RekeyOffer(RekeyOffer),
    /// Rekey: the first message of the new session (PreKeySignalMessage); the reply is [`LinkResponse::RekeyAck`].
    RekeyInit {
        /// Routing blob.
        blob: RoutingBlob,
    },
    /// Rekey: confirmation of the new session (when `rekey_init` came in the reply to `rekey_offer`).
    RekeyAck {
        /// Routing blob.
        blob: RoutingBlob,
    },
    /// Streaming message (v0.2, `docs/PROTOCOL.md` §20): E2E stream opening (the plaintext is
    /// the CBOR of a [`crate::stream::StreamOpen`]). An `ok` reply means accepted; then [`crate::stream::StreamFrame`]
    /// frames follow on the **same** QUIC stream up to the last one, and the recipient replies with one more `ok`.
    /// A node without streams replies `rejected` (`malformed`), and the sender simply sends the final message through
    /// the ordinary queue.
    StreamOpen {
        /// Routing blob.
        blob: RoutingBlob,
    },
    /// The sender's features (`docs/PROTOCOL.md` §21): on every new connection, after `hello`. The reply is
    /// [`LinkResponse::Features`] with the recipient's features. A node without this request (`0.1.0-preview.1`)
    /// replies `rejected` (`malformed`): it has no features, and nothing new is sent to it.
    Features {
        /// Feature names ([`FEATURES`]); the recipient skips unknown ones.
        list: Vec<String>,
    },
    /// Own devices (`docs/PROTOCOL.md` §24, experimental): E2E, the plaintext is the CBOR of a
    /// [`crate::device::DeviceMsg`], outside the history. Only between contacts at level 5 with
    /// [`FEATURE_DEVICE`]. The reply is `ok`, [`LinkResponse::Device`] or `rejected`.
    Device {
        /// Routing blob.
        blob: RoutingBlob,
    },
}

/// Response over a link.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum LinkResponse {
    /// Accepted and stored.
    Ok,
    /// Already seen (a repeat after a lost acknowledgement).
    Duplicate,
    /// Rejected.
    Rejected {
        /// Reason (without content details).
        reason: String,
    },
    /// The recipient's history summary (reply to `sync`).
    Sync(SyncSummary),
    /// Chain values (reply to `chain`).
    Chain(ChainReply),
    /// Own copy at the divergence point (reply to `conflict`).
    Conflict(ConflictReply),
    /// The rekey is waiting for the recipient owner's confirmation.
    Pending,
    /// Rekey: the first message of the new session (reply to `rekey_offer` if the owner has already confirmed).
    RekeyInit {
        /// Routing blob.
        blob: RoutingBlob,
    },
    /// Rekey: confirmation of the new session (reply to `rekey_init`).
    RekeyAck {
        /// Routing blob.
        blob: RoutingBlob,
    },
    /// The recipient's features (reply to [`LinkRequest::Features`]).
    Features {
        /// Feature names.
        list: Vec<String>,
    },
    /// Reply to a [`LinkRequest::Device`] that needs one: E2E, the plaintext is the CBOR of a
    /// [`crate::device::DeviceReply`].
    Device {
        /// Routing blob.
        blob: RoutingBlob,
    },
}

/// Features from the contact's list that this node knows (unknown and excess ones are dropped).
pub fn known_features(list: &[String]) -> Vec<String> {
    let mut out: Vec<String> = list
        .iter()
        .take(MAX_FEATURES)
        .filter(|f| f.len() <= MAX_FEATURE_LEN && FEATURES.contains(&f.as_str()))
        .cloned()
        .collect();
    out.sort();
    out.dedup();
    out
}

/// An author's chain in a summary: how many of their consecutive messages (1…`count`) the side has, and the chain
/// value at `count`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuthorChain {
    /// The author's link-root Ed25519 key.
    #[serde(with = "serde_bytes")]
    pub author: [u8; 32],
    /// The author's consecutive messages, without gaps.
    pub count: u64,
    /// `chain(count)` (`docs/PROTOCOL.md` §16).
    #[serde(with = "serde_bytes")]
    pub tip: [u8; 32],
}

/// A place in the history: the author's message with this counter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Place {
    /// The author's link-root Ed25519 key.
    #[serde(with = "serde_bytes")]
    pub author: [u8; 32],
    /// Counter `n`.
    pub n: u64,
}

/// Result of the local check of one's own copy of the history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum AuditState {
    /// Checked, no mismatches with the signed content.
    Ok,
    /// Not checked yet.
    Unchecked,
    /// Own copy is damaged at this place (the content does not match its own ID / signature).
    Damaged(Place),
}

/// State of the side, as reported to the contact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LinkState {
    /// Working.
    Ok,
    /// The side's state rolled back: sending is blocked until a rekey.
    RolledBack,
    /// History divergence: the link is read-only until the owner decides.
    ReadOnly,
}

/// The side's history summary (`sync`, §16). No message content: only hashes and counters.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SyncSummary {
    /// Summary version (1).
    pub v: u16,
    /// The side's history heads, in ascending byte order.
    pub heads: Vec<MessageId>,
    /// Author chains (both sides of the link).
    pub authors: Vec<AuthorChain>,
    /// Local check of the own copy.
    pub audit: AuditState,
    /// State of the side.
    pub state: LinkState,
}

/// Request for an author's chain values: `n = from + k·step − 1`…, more precisely, all `n ∈ [from, to]` that are
/// multiples of `step` (with `step = 1`, every `n` in the range, with the ID and the signature check of the own copy).
/// At most [`MAX_CHAIN_POINTS`] points.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChainQuery {
    /// Author.
    #[serde(with = "serde_bytes")]
    pub author: [u8; 32],
    /// From which `n` (≥ 1).
    pub from: u64,
    /// Up to which `n`, inclusive.
    pub to: u64,
    /// Step (≥ 1).
    pub step: u64,
}

/// A chain point.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChainPoint {
    /// Counter.
    pub n: u64,
    /// `chain(n)`.
    #[serde(with = "serde_bytes")]
    pub tip: [u8; 32],
    /// ID of message `n` (with `step = 1`).
    pub id: Option<MessageId>,
    /// The signature of the own copy is valid (with `step = 1`).
    pub sig_ok: Option<bool>,
}

/// Reply to `chain`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChainReply {
    /// Points in ascending `n` (only those the responder has).
    pub points: Vec<ChainPoint>,
}

/// The divergence point found and the own copy at it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConflictNote {
    /// Place.
    pub place: Place,
    /// ID of the own copy.
    pub id: MessageId,
    /// The signature of the own copy is valid.
    pub sig_ok: bool,
}

/// The responder's own copy at the divergence point.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConflictReply {
    /// ID of the own copy (`None`: there is no message with this counter).
    pub id: Option<MessageId>,
    /// The signature of the own copy is valid.
    pub sig_ok: Option<bool>,
}

/// Rekey offer (§17): a fresh libsignal bundle (identity: the one pinned at pairing), signed by the link-root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RekeyOffer {
    /// CBOR [`crate::pairing::Bundle`]: exactly the signed bytes.
    #[serde(with = "serde_bytes")]
    pub bundle: Vec<u8>,
    /// Creation time, Unix ms (an offer older than 10 minutes is rejected).
    pub ts: u64,
    /// The sender's link-root Ed25519 signature (`docs/PROTOCOL.md` §17).
    #[serde(with = "serde_bytes")]
    pub sig: Vec<u8>,
}

/// Encodes a frame `u32be(len) ‖ payload`.
pub fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 4);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{LinkId, ProtocolVersion, from_cbor, to_cbor};

    #[test]
    fn link_frames_roundtrip_and_wire_shape() {
        let req = LinkRequest::Deliver {
            blob: RoutingBlob {
                v: ProtocolVersion::CURRENT,
                link: LinkId([1; 32]),
                ct: vec![0; 256],
            },
        };
        let back: LinkRequest = from_cbor(&to_cbor(&req).unwrap()).unwrap();
        assert_eq!(back, req);
        // A unit variant is encoded as the string "ok" (PROTOCOL.md §12).
        let ok = to_cbor(&LinkResponse::Ok).unwrap();
        let v: ciborium::Value = from_cbor(&ok).unwrap();
        assert_eq!(v.as_text(), Some("ok"));
        for r in [
            LinkResponse::Ok,
            LinkResponse::Duplicate,
            LinkResponse::Rejected { reason: "x".into() },
            LinkResponse::Pending,
            LinkResponse::Sync(SyncSummary {
                v: 1,
                heads: vec![MessageId([1; 32])],
                authors: vec![AuthorChain {
                    author: [2; 32],
                    count: 3,
                    tip: [4; 32],
                }],
                audit: AuditState::Damaged(Place {
                    author: [2; 32],
                    n: 2,
                }),
                state: LinkState::RolledBack,
            }),
        ] {
            assert_eq!(from_cbor::<LinkResponse>(&to_cbor(&r).unwrap()).unwrap(), r);
        }
        assert_eq!(frame(b"abc"), vec![0, 0, 0, 3, b'a', b'b', b'c']);
        // Features (§21): {"features": {"list": [...]}} in both directions.
        let f = LinkRequest::Features {
            list: vec![FEATURE_AGENTS.into()],
        };
        assert_eq!(from_cbor::<LinkRequest>(&to_cbor(&f).unwrap()).unwrap(), f);
        let v: ciborium::Value = from_cbor(&to_cbor(&f).unwrap()).unwrap();
        assert_eq!(v.as_map().unwrap()[0].0.as_text(), Some("features"));
        let r = LinkResponse::Features { list: vec![] };
        assert_eq!(from_cbor::<LinkResponse>(&to_cbor(&r).unwrap()).unwrap(), r);
        assert_eq!(
            known_features(&[
                "agents/0".into(),
                "x".repeat(40),
                "future/1".into(),
                "agents/0".into()
            ]),
            vec!["agents/0".to_string()]
        );
        assert_eq!(
            known_features(&["addr/0".into(), "agents/0".into()]),
            vec!["addr/0".to_string(), "agents/0".to_string()]
        );
        // Profile pictures (§25): a known feature, kept when the contact announces it.
        assert!(FEATURES.contains(&FEATURE_PICTURE));
        assert_eq!(
            known_features(&["picture/0".into(), "picture/1".into()]),
            vec!["picture/0".to_string()]
        );
        // The unit variant of the rekey reply is a string, like "ok".
        let v: ciborium::Value = from_cbor(&to_cbor(&LinkResponse::Pending).unwrap()).unwrap();
        assert_eq!(v.as_text(), Some("pending"));
        let a: ciborium::Value = from_cbor(&to_cbor(&AuditState::Ok).unwrap()).unwrap();
        assert_eq!(a.as_text(), Some("ok"));
        let st: ciborium::Value = from_cbor(&to_cbor(&LinkState::RolledBack).unwrap()).unwrap();
        assert_eq!(st.as_text(), Some("rolled_back"));
    }
}
