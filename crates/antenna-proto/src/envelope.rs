// SPDX-License-Identifier: Apache-2.0
//! Message envelope (SPEC §7 "Message format (CBOR)", `docs/PROTOCOL.md` §12) and the outer routing blob.
//!
//! From the outside (relay, mailbox) only the [`RoutingBlob`] is visible: the link ID and the ciphertext.
//! The whole [`Envelope`] lies inside the Triple Ratchet ciphertext. The envelope does not and will not carry the
//! trust level: it is stored only locally (SPEC §7).
//!
//! The message ID is computed over the **bytes** of [`Envelope::core`], exactly the ones transmitted. So CBOR
//! canonicalization is not needed: the recipient hashes what it received (the hash function lives in the core; this
//! crate holds only the format).
//!
//! Link format v1 (slice 3, `docs/PROTOCOL.md` §12): `core` contains the author counter `n`; `auth` is the author's
//! Ed25519 signature over the same `core` bytes with a context (link ID, recipient key, `n`); the `receipt` type is
//! a receipt for an action taken on a contact's request (audit log in the shared hash DAG, SPEC §9).

use serde::{Deserialize, Serialize};

use crate::ProtocolVersion;

/// Link identifier. 32 bytes, derived from the transcript during pairing (`docs/PROTOCOL.md` §7);
/// shared only by the two sides of this link and unrelated to any other identifier (SPEC §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct LinkId(#[serde(with = "serde_bytes")] pub [u8; 32]);

impl LinkId {
    /// Hexadecimal form (lowercase).
    pub fn to_hex(&self) -> String {
        hex32(&self.0)
    }
}

/// Message ID: BLAKE3 (`derive_key`) over the bytes of [`Envelope::core`], which contain a random salt (SPEC §7, §8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct MessageId(#[serde(with = "serde_bytes")] pub [u8; 32]);

impl MessageId {
    /// Hexadecimal form (lowercase).
    pub fn to_hex(&self) -> String {
        hex32(&self.0)
    }
}

fn hex32(b: &[u8; 32]) -> String {
    data_encoding::HEXLOWER.encode(b)
}

/// BLAKE3 hash of a file's content (plaintext), see SPEC §7 "Files and streams".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct BlobHash(#[serde(with = "serde_bytes")] pub [u8; 32]);

/// Outer blob seen by the transport, relays and mailboxes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoutingBlob {
    /// Wire protocol version.
    pub v: ProtocolVersion,
    /// The link the ciphertext belongs to.
    pub link: LinkId,
    /// `pad(e2e-frame)`: its length is exactly one of the [`crate::padding::padded_len`] buckets.
    #[serde(with = "serde_bytes")]
    pub ct: Vec<u8>,
}

/// Message type (SPEC §7).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageType {
    /// Text.
    Text,
    /// File (manifest + blob reference).
    File,
    /// Request (to an agent or the owner).
    Request,
    /// Response to a request.
    Response,
    /// Task for an agent (A2A Task).
    Task,
    /// Receipt for an action taken on a contact's request (audit log, SPEC §9).
    Receipt,
    /// Joint checkpoint of the history head (SPEC §8).
    Checkpoint,
    /// Deletion: the text is erased, the hash and metadata remain (SPEC §8).
    Tombstone,
    /// Protocol service message.
    Control,
}

impl MessageType {
    /// Type name as in CBOR.
    pub fn as_str(&self) -> &'static str {
        match self {
            MessageType::Text => "text",
            MessageType::File => "file",
            MessageType::Request => "request",
            MessageType::Response => "response",
            MessageType::Task => "task",
            MessageType::Receipt => "receipt",
            MessageType::Checkpoint => "checkpoint",
            MessageType::Tombstone => "tombstone",
            MessageType::Control => "control",
        }
    }
}

/// Content: text, receipt, file offer, file request or a reference to a file by BLAKE3 hash.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Body {
    /// Message text.
    Text(String),
    /// File reference.
    Ref(BlobHash),
    /// Receipt for an action taken on a contact's request (type `receipt`, SPEC §9).
    Receipt(ReceiptBody),
    /// File offer (type `file`, slice 4): signed manifest and file secret (`docs/PROTOCOL.md` §19).
    File(crate::files::FileOffer),
    /// Request for a file from a contact's `shared/` (type `request`, `antenna request`).
    #[serde(rename = "file_request")]
    FileRequest(crate::files::FileRequest),
    /// Announcement of a side's agent, a sub-identity inside the link (type `control`, SPEC §5, `docs/PROTOCOL.md`
    /// §21). Only the side's link-root may author such a message: the message signature is the link-root's signature
    /// over the agent's key.
    Agent(AgentAnnounce),
    /// A profile picture of the side's owner or of one of its agents (type `control`, `docs/PROTOCOL.md` §25, only to
    /// a node with the feature `picture/0`). Only the side's link-root may author it, like an agent announcement.
    Picture(crate::picture::PictureBody),
    /// Empty (for example, a tombstone).
    None,
}

/// Receipt (audit log in the shared hash DAG, SPEC §9, Q-16). Only the fact of the action: no message text, no trust
/// level (it is stored only locally, SPEC §7) and no labels of other links (SPEC §5).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReceiptBody {
    /// Who acted: `owner` or the agent's name, a sub-identity inside the link (SPEC §5).
    pub actor: String,
    /// Action: `read_messages`, `read_history`, `send_message`, `check:read|write|exec`, `share_file`, `request_file`,
    /// `accept_file`, `reject_file` (slice 4).
    pub action: String,
    /// Decision: `allowed`, `denied`, `approval_required`, `approved`, `accepted`, `rejected`.
    pub decision: String,
    /// Link messages the action refers to (for example, the ones read), at most [`ReceiptBody::MAX_REFS`].
    pub refs: Vec<MessageId>,
    /// How many identical actions this receipt covers (slice 4, Q-22: an agent's `check:*` checks for contacts of
    /// levels 1–2 go into one receipt per 10 minutes). 0 (field absent) means one action.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub count: u32,
    /// With `accept_file` / `accepted` (D-128, only to a node with `file-saved-as/0`): another file had the offered
    /// name in the recipient's folder, so the file was saved as `<stem> (n).<ext>` with this `n`, 2 to
    /// [`ReceiptBody::MAX_NAME_NUMBER`]. A number, not a name: the sender derives the name from its own manifest, and
    /// no free text crosses in a receipt. 0 (field absent): saved under the offered name, or under one the owner chose.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub name_number: u32,
    /// Why (D-130, only to a node with `file-fate/0`): with `check_file` / `held`, why the recipient's node holds the
    /// file for its owner ([`crate::files::fate::HELD_WHY`]); with `reject_file` / `denied`, why it was blocked
    /// ([`crate::files::fate::BLOCKED_WHY`]). Empty (absent) otherwise.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub why: String,
    /// With `why`: the rules of the recipient's check that matched, at most [`crate::files::fate::MAX_RULES`], each
    /// [`crate::files::fate::valid_rule`]: finding codes, never the file's name or content.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rules: Vec<String>,
}

fn is_zero(v: &u32) -> bool {
    *v == 0
}

impl ReceiptBody {
    /// Maximum number of references in one receipt.
    pub const MAX_REFS: usize = 64;
    /// Maximum length of the text fields, in bytes.
    pub const MAX_FIELD: usize = 64;
    /// The highest number a received file's name gets when its name is taken (`report (1000).pdf`).
    pub const MAX_NAME_NUMBER: u32 = 1000;
}

/// Announcement of a side's agent in the link (`docs/PROTOCOL.md` §21): the sub-identity's name and key. The message
/// carrying it is signed by the side's link-root (like any of its messages, §12): this is the "sub-identity signed by
/// link-root" (SPEC §5). After it, the side's messages with `author` = `key` (and `n` greater than the announcement's)
/// come from this agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentAnnounce {
    /// Agent name the contact will see: `[A-Za-z0-9._-]{1,64}`.
    pub name: String,
    /// The agent's Ed25519 public key in this link (one per link: nothing is shared between links, SPEC §5).
    #[serde(with = "serde_bytes")]
    pub key: [u8; 32],
    /// `active`: the agent writes with this key; `revoked`: the key is revoked and messages with `n` after the
    /// revocation are not accepted.
    pub state: String,
}

impl AgentAnnounce {
    /// Maximum name length.
    pub const MAX_NAME: usize = 64;
    /// Maximum number of announced keys of one side in a link.
    pub const MAX_PER_SIDE: usize = 64;
    /// The key is in effect.
    pub const ACTIVE: &'static str = "active";
    /// The key is revoked.
    pub const REVOKED: &'static str = "revoked";

    /// The name is fit to show to the contact. `owner` is reserved: receipts (`actor`) use it for the owner.
    pub fn valid_name(name: &str) -> bool {
        !name.is_empty()
            && !name.eq_ignore_ascii_case("owner")
            && name.len() <= Self::MAX_NAME
            && name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    }
}

/// Who a message is for (`docs/PROTOCOL.md` §23, feature `addr/0`): the other side's owner, one of its agents by
/// the name it announced (§21), or everyone. A message without the field has no address (a node without `addr/0`,
/// or a message from before addressing).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum To {
    /// The person: the recipient side's owner.
    Person,
    /// Everyone on the recipient side: the owner and the agents the owner allows to see such messages.
    Everyone,
    /// One agent of the recipient side, by the name it announced in this link: `[A-Za-z0-9._-]{1,64}`.
    Agent(String),
}

impl To {
    /// Wire and control-protocol name of the kind: `person`, `everyone`, `agent`.
    pub fn kind(&self) -> &'static str {
        match self {
            To::Person => "person",
            To::Everyone => "everyone",
            To::Agent(_) => "agent",
        }
    }

    /// The agent's name, for [`To::Agent`].
    pub fn agent(&self) -> Option<&str> {
        match self {
            To::Agent(n) => Some(n),
            _ => None,
        }
    }

    /// From the kind and the agent name (as stored and as in the control protocol); `None` for anything else.
    pub fn from_parts(kind: &str, agent: Option<&str>) -> Option<To> {
        match (kind, agent) {
            ("person", None) => Some(To::Person),
            ("everyone", None) => Some(To::Everyone),
            ("agent", Some(n)) if AgentAnnounce::valid_name(n) => Some(To::Agent(n.to_string())),
            _ => None,
        }
    }

    /// The field fits the format: an agent name follows [`AgentAnnounce::valid_name`].
    pub fn valid(&self) -> bool {
        match self {
            To::Agent(n) => AgentAnnounce::valid_name(n),
            _ => true,
        }
    }
}

/// The topic a message belongs to (`docs/PROTOCOL.md` §23): a thread for a task inside the link. Local organization
/// carried in the signed message, not a separate cryptographic channel: whoever is in the link reads every topic.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Topic {
    /// Random 16 bytes chosen by whoever started the topic.
    #[serde(with = "serde_bytes")]
    pub id: [u8; 16],
    /// Title: 1–120 bytes of UTF-8 without control characters.
    pub title: String,
}

impl Topic {
    /// Maximum title length, bytes.
    pub const MAX_TITLE: usize = 120;

    /// The title fits: not empty after trimming, at most [`Topic::MAX_TITLE`] bytes, no control characters.
    pub fn valid_title(t: &str) -> bool {
        !t.trim().is_empty() && t.len() <= Self::MAX_TITLE && !t.chars().any(char::is_control)
    }

    /// Hexadecimal ID (32 characters).
    pub fn id_hex(&self) -> String {
        data_encoding::HEXLOWER.encode(&self.id)
    }
}

/// Author authentication: a signature ("signed" history) or a MAC ("deniable" history, v0.3), SPEC §8.
/// Link format v1 requires a signature: `{"sig": bstr .size 64}` (`docs/PROTOCOL.md` §12).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Auth {
    /// Ed25519 signature over the link ID, recipient key, counter and content.
    Sig(#[serde(with = "serde_bytes")] Vec<u8>),
    /// MAC with the link's shared key.
    Mac(#[serde(with = "serde_bytes")] Vec<u8>),
}

/// Content part of the envelope. Its CBOR bytes lie in [`Envelope::core`] and are hashed into the ID.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnvelopeCore {
    /// Random 32-byte salt, so the text cannot be guessed from the hash.
    #[serde(with = "serde_bytes")]
    pub salt: [u8; 32],
    /// Author key (human or agent) inside the link: the side's link-root Ed25519 key or the key of its agent announced
    /// earlier by a `control`/`agent` message of this side (`docs/PROTOCOL.md` §21).
    #[serde(with = "serde_bytes")]
    pub author: [u8; 32],
    /// Hashes of all known history "heads" (hash DAG, SPEC §8), in ascending byte order.
    pub parents: Vec<MessageId>,
    /// Lamport clock.
    pub lamport: u64,
    /// Sender's wall clock, Unix milliseconds.
    pub ts: u64,
    /// Message counter of the **side** in this link: 1, 2, 3… without gaps (SPEC §7 "signature with context …
    /// counter"); the owner and their agents share the side's counter.
    /// It is covered by the signature; from it the contact detects state rollback (SPEC §8) and finds where the
    /// history diverged.
    pub n: u64,
    /// Message type.
    #[serde(rename = "type")]
    pub kind: MessageType,
    /// Text or file reference.
    pub body: Body,
    /// Who the message is for (`docs/PROTOCOL.md` §23): only on `text` messages and only to a node with the feature
    /// `addr/0`; when absent, the bytes of `core` are exactly those a node without addressing writes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<To>,
    /// The topic (§23): only on `text` messages and only to a node with `addr/0`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub topic: Option<Topic>,
    /// "Interrupt now" (§23, feature `urgent/0`, PG-58; experimental): only `true`, only on a `text` message the side's
    /// owner (link-root) addresses to one agent, only to a node that answered `urgent/0`. The recipient honours it
    /// only from a contact it has at level 5 (its owner's own computer); when absent, the bytes of `core` are exactly
    /// those an older node writes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub urgent: Option<bool>,
}

impl EnvelopeCore {
    /// The urgent flag fits the format (§23): absent, or `true` on a `text` message addressed to one agent. `false`
    /// is not a value a node writes (the field is left out instead), so it is refused like any other malformed field.
    pub fn urgent_valid(&self) -> bool {
        match self.urgent {
            None => true,
            Some(false) => false,
            Some(true) => self.kind == MessageType::Text && matches!(self.to, Some(To::Agent(_))),
        }
    }
}

/// Message envelope: the Triple Ratchet plaintext.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    /// Message ID = BLAKE3-DK(context, `core`). The recipient recomputes and compares it.
    pub id: MessageId,
    /// CBOR([`EnvelopeCore`]): exactly the bytes that are hashed.
    #[serde(with = "serde_bytes")]
    pub core: Vec<u8>,
    /// Author's signature (required in format v1; `None` only in format v0 messages, which are rejected).
    pub auth: Option<Auth>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{from_cbor, to_cbor};

    fn core() -> EnvelopeCore {
        EnvelopeCore {
            salt: [2; 32],
            author: [3; 32],
            parents: vec![MessageId([4; 32]), MessageId([5; 32])],
            lamport: 42,
            ts: 1_790_000_000_000,
            n: 7,
            kind: MessageType::Text,
            body: Body::Text("hello".into()),
            to: None,
            topic: None,
            urgent: None,
        }
    }

    #[test]
    fn envelope_cbor_roundtrip() {
        let c = core();
        let e = Envelope {
            id: MessageId([1; 32]),
            core: to_cbor(&c).unwrap(),
            auth: Some(Auth::Sig(vec![9; 64])),
        };
        let bytes = to_cbor(&e).unwrap();
        let back: Envelope = from_cbor(&bytes).unwrap();
        assert_eq!(e, back);
        let c2: EnvelopeCore = from_cbor(&back.core).unwrap();
        assert_eq!(c, c2);
    }

    #[test]
    fn body_and_type_wire_names_match_spec() {
        // PROTOCOL.md §12: "type": "text", "body": { "text": tstr }
        let v: ciborium::Value = from_cbor(&to_cbor(&core()).unwrap()).unwrap();
        let map = v.as_map().unwrap();
        let get = |k: &str| {
            map.iter()
                .find(|(kk, _)| kk.as_text() == Some(k))
                .map(|(_, v)| v.clone())
                .unwrap()
        };
        assert_eq!(get("type").as_text(), Some("text"));
        let body = get("body");
        let body = body.as_map().unwrap();
        assert_eq!(body[0].0.as_text(), Some("text"));
        assert!(get("salt").is_bytes());
        assert_eq!(get("n").as_integer(), Some(7.into()));
        // auth: {"sig": bstr}
        let e = Envelope {
            id: MessageId([1; 32]),
            core: vec![],
            auth: Some(Auth::Sig(vec![0; 64])),
        };
        let v: ciborium::Value = from_cbor(&to_cbor(&e).unwrap()).unwrap();
        let auth = v
            .as_map()
            .unwrap()
            .iter()
            .find(|(k, _)| k.as_text() == Some("auth"))
            .unwrap()
            .1
            .clone();
        let auth = auth.as_map().unwrap();
        assert_eq!(auth[0].0.as_text(), Some("sig"));
        assert!(auth[0].1.is_bytes());
    }

    #[test]
    fn receipt_body_wire_shape() {
        let mut c = core();
        c.kind = MessageType::Receipt;
        c.body = Body::Receipt(ReceiptBody {
            actor: "claude".into(),
            action: "read_messages".into(),
            decision: "allowed".into(),
            refs: vec![MessageId([1; 32])],
            count: 0,
            name_number: 0,
            why: String::new(),
            rules: vec![],
        });
        let back: EnvelopeCore = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        assert_eq!(back, c);
        let keys = |c: &EnvelopeCore| -> Vec<String> {
            let v: ciborium::Value = from_cbor(&to_cbor(c).unwrap()).unwrap();
            let body = v
                .as_map()
                .unwrap()
                .iter()
                .find(|(k, _)| k.as_text() == Some("body"))
                .unwrap()
                .1
                .clone();
            assert_eq!(body.as_map().unwrap()[0].0.as_text(), Some("receipt"));
            let inner = body.as_map().unwrap()[0].1.clone();
            inner
                .as_map()
                .unwrap()
                .iter()
                .filter_map(|(k, _)| k.as_text().map(str::to_string))
                .collect()
        };
        // count = 0 and name_number = 0 are not written (compatibility with slice 3 receipts and with nodes without
        // `file-saved-as/0`, D-128).
        assert_eq!(keys(&c), ["actor", "action", "decision", "refs"]);
        if let Body::Receipt(r) = &mut c.body {
            r.name_number = 2;
        }
        assert!(keys(&c).contains(&"name_number".to_string()));
        let back: EnvelopeCore = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        assert_eq!(back, c);
        // `why` and `rules` (D-130) only when there is a reason: a node without `file-fate/0` never sees them.
        if let Body::Receipt(r) = &mut c.body {
            r.name_number = 0;
            r.action = "check_file".into();
            r.decision = "held".into();
            r.why = "executable".into();
            r.rules = vec!["archive_member_executable".into()];
        }
        assert_eq!(
            keys(&c),
            ["actor", "action", "decision", "refs", "why", "rules"]
        );
        let back: EnvelopeCore = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        assert_eq!(back, c);
    }

    #[test]
    fn file_bodies_wire_names() {
        let mut c = core();
        c.kind = MessageType::Request;
        c.body = Body::FileRequest(crate::files::FileRequest {
            path: "docs/a.pdf".into(),
        });
        let v: ciborium::Value = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        let body = v
            .as_map()
            .unwrap()
            .iter()
            .find(|(k, _)| k.as_text() == Some("body"))
            .unwrap()
            .1
            .clone();
        assert_eq!(body.as_map().unwrap()[0].0.as_text(), Some("file_request"));
        let back: EnvelopeCore = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        assert_eq!(back, c);
        c.kind = MessageType::File;
        c.body = Body::File(crate::files::FileOffer {
            manifest: crate::files::SignedManifest {
                body: vec![1, 2],
                sig: vec![3; 64],
            },
            secret: [4; 32],
        });
        let v: ciborium::Value = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        let body = v
            .as_map()
            .unwrap()
            .iter()
            .find(|(k, _)| k.as_text() == Some("body"))
            .unwrap()
            .1
            .clone();
        assert_eq!(body.as_map().unwrap()[0].0.as_text(), Some("file"));
    }

    #[test]
    fn agent_announce_wire_shape() {
        let mut c = core();
        c.kind = MessageType::Control;
        c.body = Body::Agent(AgentAnnounce {
            name: "claude-backend".into(),
            key: [7; 32],
            state: AgentAnnounce::ACTIVE.into(),
        });
        let back: EnvelopeCore = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        assert_eq!(back, c);
        let v: ciborium::Value = from_cbor(&to_cbor(&c).unwrap()).unwrap();
        let get = |k: &str| {
            v.as_map()
                .unwrap()
                .iter()
                .find(|(kk, _)| kk.as_text() == Some(k))
                .map(|(_, v)| v.clone())
                .unwrap()
        };
        assert_eq!(get("type").as_text(), Some("control"));
        let body = get("body");
        let (k, inner) = &body.as_map().unwrap()[0];
        assert_eq!(k.as_text(), Some("agent"));
        let key = inner
            .as_map()
            .unwrap()
            .iter()
            .find(|(k, _)| k.as_text() == Some("key"))
            .unwrap()
            .1
            .clone();
        assert!(key.is_bytes(), "key is a CBOR bstr");
        assert!(AgentAnnounce::valid_name("claude-backend"));
        for bad in ["", "a b", "ñame", "x/y", &"a".repeat(65), "owner", "Owner"] {
            assert!(!AgentAnnounce::valid_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn unknown_fields_are_rejected() {
        #[derive(Serialize)]
        struct Evil {
            v: u16,
            #[serde(with = "serde_bytes")]
            link: [u8; 32],
            #[serde(with = "serde_bytes")]
            ct: Vec<u8>,
            extra: u8,
        }
        let bytes = to_cbor(&Evil {
            v: 0,
            link: [0; 32],
            ct: vec![],
            extra: 1,
        })
        .unwrap();
        assert!(from_cbor::<RoutingBlob>(&bytes).is_err());
    }

    #[test]
    fn byte_fields_are_cbor_byte_strings_not_arrays() {
        // 32-byte fields must be encoded as a CBOR bstr (major type 2), not as an array of numbers.
        let bytes = to_cbor(&LinkId([0xab; 32])).unwrap();
        assert_eq!(bytes[0], 0x58, "bstr with 1-byte length");
        assert_eq!(bytes[1], 32);
        assert_eq!(bytes.len(), 34);
    }

    #[test]
    fn routing_blob_roundtrip_and_type_names() {
        let r = RoutingBlob {
            v: ProtocolVersion::CURRENT,
            link: LinkId([9; 32]),
            ct: vec![0; 256],
        };
        let back: RoutingBlob = from_cbor(&to_cbor(&r).unwrap()).unwrap();
        assert_eq!(r, back);
        let t: MessageType = from_cbor(&to_cbor(&"checkpoint").unwrap()).unwrap();
        assert_eq!(t, MessageType::Checkpoint);
        assert_eq!(MessageType::Checkpoint.as_str(), "checkpoint");
    }

    #[test]
    fn garbage_is_an_error_not_a_panic() {
        for input in [&[][..], &[0xff], &[0xa1, 0x00], &[0x58, 0xff, 0x00]] {
            assert!(from_cbor::<Envelope>(input).is_err());
            assert!(from_cbor::<EnvelopeCore>(input).is_err());
        }
    }

    /// `envelope-core` as nodes without addressing (`0.1.0-preview.3` and older) define it: strict, no `to`/`topic`.
    #[derive(Debug, Serialize, Deserialize, PartialEq)]
    #[serde(deny_unknown_fields)]
    struct OldCore {
        #[serde(with = "serde_bytes")]
        salt: [u8; 32],
        #[serde(with = "serde_bytes")]
        author: [u8; 32],
        parents: Vec<MessageId>,
        lamport: u64,
        ts: u64,
        n: u64,
        #[serde(rename = "type")]
        kind: MessageType,
        body: Body,
    }

    fn old(c: &EnvelopeCore) -> OldCore {
        OldCore {
            salt: c.salt,
            author: c.author,
            parents: c.parents.clone(),
            lamport: c.lamport,
            ts: c.ts,
            n: c.n,
            kind: c.kind,
            body: c.body.clone(),
        }
    }

    #[test]
    fn a_plain_core_is_byte_for_byte_the_old_format() {
        // The message ID and signature are over these bytes (§12, §16): a message without an address must hash the
        // same on old and new nodes, so history verification across versions is unchanged
        let c = core();
        let new = to_cbor(&c).unwrap();
        assert_eq!(new, to_cbor(&old(&c)).unwrap());
        let parsed: OldCore = from_cbor(&new).unwrap();
        assert_eq!(parsed, old(&c));
    }

    #[test]
    fn addressing_round_trip_and_wire_shape() {
        let mut c = core();
        for to in [To::Person, To::Everyone, To::Agent("claude-backend".into())] {
            c.to = Some(to.clone());
            c.topic = Some(Topic {
                id: [0xab; 16],
                title: "Build preview.4".into(),
            });
            let bytes = to_cbor(&c).unwrap();
            let back: EnvelopeCore = from_cbor(&bytes).unwrap();
            assert_eq!(back, c);
            let v: ciborium::Value = from_cbor(&bytes).unwrap();
            let get = |k: &str| {
                v.as_map()
                    .unwrap()
                    .iter()
                    .find(|(kk, _)| kk.as_text() == Some(k))
                    .map(|(_, v)| v.clone())
                    .unwrap()
            };
            match &to {
                To::Agent(n) => {
                    let m = get("to");
                    let (k, name) = &m.as_map().unwrap()[0];
                    assert_eq!(k.as_text(), Some("agent"));
                    assert_eq!(name.as_text(), Some(n.as_str()));
                }
                other => assert_eq!(get("to").as_text(), Some(other.kind())),
            }
            let topic = get("topic");
            let id = topic
                .as_map()
                .unwrap()
                .iter()
                .find(|(k, _)| k.as_text() == Some("id"))
                .unwrap()
                .1
                .clone();
            assert!(id.is_bytes(), "topic id is a CBOR bstr");
            assert_eq!(
                To::from_parts(to.kind(), to.agent()),
                Some(to.clone()),
                "{to:?}"
            );
        }
    }

    #[test]
    fn a_node_without_addressing_rejects_the_new_fields() {
        // Why addressing is a node feature (§23): the old strict parser refuses a core with `to` or `topic`, and
        // such a message would be `failed` after five rejections. A new node sends these fields only to `addr/0`.
        let mut c = core();
        c.to = Some(To::Agent("builder".into()));
        assert!(from_cbor::<OldCore>(&to_cbor(&c).unwrap()).is_err());
        c.to = None;
        c.topic = Some(Topic {
            id: [1; 16],
            title: "Avatars".into(),
        });
        assert!(from_cbor::<OldCore>(&to_cbor(&c).unwrap()).is_err());
    }

    /// PG-58: `urgent` only as `true` on a text message for one agent; a core with it is refused by every older strict
    /// parser (so it goes only to `urgent/0`), and a core without it is the old encoding byte for byte.
    #[test]
    fn the_urgent_flag_has_one_shape_and_older_nodes_refuse_it() {
        let mut c = core();
        assert!(c.urgent_valid());
        c.to = Some(To::Agent("helper".into()));
        let plain = to_cbor(&c).unwrap();
        c.urgent = Some(true);
        assert!(c.urgent_valid());
        let bytes = to_cbor(&c).unwrap();
        assert_ne!(bytes, plain);
        let back: EnvelopeCore = from_cbor(&bytes).unwrap();
        assert_eq!(back.urgent, Some(true));
        // A node with addressing but without `urgent/0` parses `core` as it did before this field: strict
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        #[allow(dead_code, reason = "only parsed, to see it refused")]
        struct AddrCore {
            #[serde(with = "serde_bytes")]
            salt: [u8; 32],
            #[serde(with = "serde_bytes")]
            author: [u8; 32],
            parents: Vec<MessageId>,
            lamport: u64,
            ts: u64,
            n: u64,
            #[serde(rename = "type")]
            kind: MessageType,
            body: Body,
            #[serde(default)]
            to: Option<To>,
            #[serde(default)]
            topic: Option<Topic>,
        }
        assert!(from_cbor::<AddrCore>(&plain).is_ok());
        assert!(from_cbor::<AddrCore>(&bytes).is_err());
        assert!(from_cbor::<OldCore>(&bytes).is_err());
        // Only on text for one agent, never `false`
        c.urgent = Some(false);
        assert!(!c.urgent_valid());
        c.urgent = Some(true);
        c.to = Some(To::Everyone);
        assert!(!c.urgent_valid());
        c.to = None;
        assert!(!c.urgent_valid());
        c.to = Some(To::Agent("helper".into()));
        c.kind = MessageType::File;
        assert!(!c.urgent_valid());
    }

    #[test]
    fn addressing_field_rules() {
        assert!(To::Agent("lead".into()).valid());
        assert!(!To::Agent("a b".into()).valid());
        assert!(!To::Agent("owner".into()).valid());
        assert_eq!(To::from_parts("agent", None), None);
        assert_eq!(To::from_parts("person", Some("x")), None);
        assert_eq!(To::from_parts("nobody", None), None);
        assert!(Topic::valid_title("Avatars"));
        assert!(Topic::valid_title(&"é".repeat(60)));
        assert!(!Topic::valid_title(&"é".repeat(61)));
        assert!(!Topic::valid_title("   "));
        assert!(!Topic::valid_title("a\nb"));
        // Unknown fields inside the new structures are refused too
        #[derive(Serialize)]
        struct EvilTopic {
            #[serde(with = "serde_bytes")]
            id: [u8; 16],
            title: String,
            extra: u8,
        }
        let bytes = to_cbor(&EvilTopic {
            id: [0; 16],
            title: "t".into(),
            extra: 1,
        })
        .unwrap();
        assert!(from_cbor::<Topic>(&bytes).is_err());
    }

    #[test]
    fn hex_ids() {
        assert_eq!(LinkId([0xab; 32]).to_hex().len(), 64);
        assert!(MessageId([0x0f; 32]).to_hex().starts_with("0f0f"));
    }
}
