// SPDX-License-Identifier: Apache-2.0
//! Streaming messages (v0.2: an agent's reply is shown while it is being written, `docs/PROTOCOL.md` §20).
//!
//! A stream is a "live" view of a message that is still being written: `open` → pieces → last piece. It is **not**
//! part of the history, the hash DAG, signatures or history verification: only the final message gets there, an
//! ordinary signed `text` (§12) that goes through the ordinary queue. So a node that does not know about streams simply
//! receives the final message.
//!
//! Data and domain-separation labels only. Pieces are encrypted with the ready-made STREAM construction
//! (`aead-stream`, ChaCha20-Poly1305, like `xfile/0` files) in the AGPL core; the stream secret is sent inside a
//! Triple Ratchet message (like the file secret, D-F-2), so there is no custom cryptography.
//!
//! ```text
//! open       = Triple Ratchet( CBOR(StreamOpen) )                       — link request `stream_open`
//! key        = HKDF-SHA256(salt = stream_id, ikm = secret, info = "x/stream/v0/key")
//! aad        = "x/stream/v0/piece" ‖ link_id ‖ stream_id
//! piece_i    = ChaCha20-Poly1305(key, nonce = 0^7 ‖ u32be(i) ‖ last, aad, pad(CBOR(StreamPiece)))
//! final_salt = HKDF-SHA256(salt = stream_id, ikm = secret, info = "x/stream/v0/final-salt")   — final message salt
//! ```

use serde::{Deserialize, Serialize};

use crate::MessageId;

/// Stream format version.
pub const STREAM_VERSION: u8 = 0;
/// HKDF `info` for the piece key.
pub const KEY_INFO: &[u8] = b"x/stream/v0/key";
/// HKDF `info` for the final message's salt: by it the recipient recognizes the stream's final message in the history
/// even if the last piece did not arrive (link dropped) or the final message was sent later (after owner approval).
pub const FINAL_SALT_INFO: &[u8] = b"x/stream/v0/final-salt";
/// AAD label of the pieces.
pub const AAD_LABEL: &[u8] = b"x/stream/v0/piece";
/// Maximum number of pieces in one stream.
pub const MAX_PIECES: u32 = 8192;
/// Maximum size of one piece frame (ciphertext), in bytes.
pub const MAX_FRAME: usize = 80 * 1024;
/// Maximum length of `activity`, in characters.
pub const MAX_ACTIVITY: usize = 64;
/// String that ends the final message of a stream if the source broke off (the agent crashed, `antenna send --stream`
/// was interrupted, a limit was exceeded): the history keeps what arrived, plus this mark.
pub const INTERRUPTED_MARK: &str = "\n\n[interrupted]";

/// Stream opening: the plaintext of the Triple Ratchet message in a `stream_open` request (not part of the history).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamOpen {
    /// Version ([`STREAM_VERSION`]).
    pub v: u8,
    /// Random stream ID.
    #[serde(with = "serde_bytes")]
    pub id: [u8; 16],
    /// Stream secret: the piece key and the final message's salt are derived from it.
    #[serde(with = "serde_bytes")]
    pub secret: [u8; 32],
    /// Opening time, Unix ms (sender's clock).
    pub ts: u64,
    /// The sender's agent that writes, by the name the contact knows it by (PROTOCOL §21): only to a node with
    /// `stream-agent/0` (an older one parses this strictly and refuses the field). The final message's author is what
    /// counts; this name is for the live display until it arrives.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

impl std::fmt::Debug for StreamOpen {
    // The stream secret never reaches the logs.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "StreamOpen(v{}, secret: ..)", self.v)
    }
}

/// Piece frame on the same QUIC stream after `stream_open`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamFrame {
    /// Piece ciphertext (STREAM).
    #[serde(with = "serde_bytes")]
    pub c: Vec<u8>,
    /// Last piece (the flag is also part of the STREAM nonce, so tampering shows up on decryption).
    pub last: bool,
}

/// How the stream ended (only in the last piece).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamEnd {
    /// The source finished; the final message is `final_id`.
    Done,
    /// The source broke off (the agent crashed or ran out of time, input was interrupted); the final message is the
    /// text that arrived plus [`INTERRUPTED_MARK`] (`final_id`), if there was any text.
    Interrupted,
    /// The sender cut the stream without a final message for now: the message needs the owner's decision (for
    /// example, the secret scanner found a secret). If the owner approves, the final message arrives later as an
    /// ordinary message with this stream's salt.
    Cut,
}

impl StreamEnd {
    /// Name as on the wire.
    pub fn as_str(&self) -> &'static str {
        match self {
            StreamEnd::Done => "done",
            StreamEnd::Interrupted => "interrupted",
            StreamEnd::Cut => "cut",
        }
    }
}

/// Plaintext of a piece (before padding with [`crate::padding::pad`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamPiece {
    /// Continuation of the text (may be empty: "alive", an `activity` change).
    pub text: String,
    /// What the source is busy with now (`tool:Read`…), only for contacts of levels 4–5; `""` clears it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity: Option<String>,
    /// Only in the last piece.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<StreamEnd>,
    /// Only in the last piece: ID of the final message in the link history.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub final_id: Option<MessageId>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{from_cbor, to_cbor};

    #[test]
    fn stream_types_roundtrip_and_wire_names() {
        let o = StreamOpen {
            v: STREAM_VERSION,
            id: [1; 16],
            secret: [7; 32],
            ts: 5,
            agent: None,
        };
        assert_eq!(from_cbor::<StreamOpen>(&to_cbor(&o).unwrap()).unwrap(), o);
        // Without an agent the opening is what an older node expects: four fields
        let v: ciborium::Value = from_cbor(&to_cbor(&o).unwrap()).unwrap();
        assert_eq!(v.as_map().unwrap().len(), 4);
        let named = StreamOpen {
            agent: Some("claude".into()),
            ..o.clone()
        };
        assert_eq!(
            from_cbor::<StreamOpen>(&to_cbor(&named).unwrap()).unwrap(),
            named
        );
        assert!(!format!("{o:?}").contains("7, 7"));
        let p = StreamPiece {
            text: "hello".into(),
            activity: None,
            end: Some(StreamEnd::Done),
            final_id: Some(MessageId([3; 32])),
        };
        let b = to_cbor(&p).unwrap();
        assert_eq!(from_cbor::<StreamPiece>(&b).unwrap(), p);
        let v: ciborium::Value = from_cbor(&b).unwrap();
        let keys: Vec<_> = v
            .as_map()
            .unwrap()
            .iter()
            .map(|(k, _)| k.as_text().unwrap().to_string())
            .collect();
        assert_eq!(keys, ["text", "end", "final_id"]);
        let e: ciborium::Value = from_cbor(&to_cbor(&StreamEnd::Cut).unwrap()).unwrap();
        assert_eq!(e.as_text(), Some("cut"));
        // A piece without optional fields carries only the text.
        let short = to_cbor(&StreamPiece {
            text: String::new(),
            activity: None,
            end: None,
            final_id: None,
        })
        .unwrap();
        let v: ciborium::Value = from_cbor(&short).unwrap();
        assert_eq!(v.as_map().unwrap().len(), 1);
        let f = StreamFrame {
            c: vec![1, 2],
            last: true,
        };
        assert_eq!(from_cbor::<StreamFrame>(&to_cbor(&f).unwrap()).unwrap(), f);
        // Unknown fields are an error (strict parsing, like all protocol types).
        let with_extra = |b: &[u8]| -> Vec<u8> {
            let mut v: ciborium::Value = from_cbor(b).unwrap();
            v.as_map_mut()
                .unwrap()
                .push(("x".into(), ciborium::Value::Integer(1.into())));
            to_cbor(&v).unwrap()
        };
        assert!(from_cbor::<StreamFrame>(&with_extra(&to_cbor(&f).unwrap())).is_err());
        assert!(from_cbor::<StreamPiece>(&with_extra(&b)).is_err());
        assert!(from_cbor::<StreamOpen>(&with_extra(&to_cbor(&o).unwrap())).is_err());
    }
}
