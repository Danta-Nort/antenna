// SPDX-License-Identifier: Apache-2.0
//! Wire formats of the Antenna protocol (SPEC §7, `docs/PROTOCOL.md`): invite link, pairing messages, link frames,
//! message envelope, padding, file formats, streaming messages, the daemon's local control protocol.
//!
//! The crate is Apache-2.0: this is the specification layer that independent implementations are written against
//! (SPEC §16). It holds only data types, their encoding and domain-separation labels, no cryptography:
//! signatures, MACs, hashes and encryption are computed by the AGPL core (`antenna-core`) with audited crates.
//!
//! Status: link format v1 (slice 3: signatures, history verification, receipts, rekey), **not frozen** (D-12).

pub mod control;
pub mod device;
pub mod envelope;
pub mod files;
pub mod invite;
pub mod link;
pub mod local;
pub mod models;
pub mod padding;
pub mod pairing;
pub mod picture;
pub mod sas;
pub mod stream;
pub mod version;

pub use envelope::{
    AgentAnnounce, Auth, BlobHash, Body, Envelope, EnvelopeCore, LinkId, MessageId, MessageType,
    ReceiptBody, RoutingBlob, To, Topic,
};
pub use version::ProtocolVersion;

/// CBOR encoding or decoding error.
#[derive(Debug)]
pub struct CodecError(pub String);

impl std::fmt::Display for CodecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "cbor: {}", self.0)
    }
}

impl std::error::Error for CodecError {}

/// Encodes a value as CBOR.
pub fn to_cbor<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, CodecError> {
    let mut out = Vec::new();
    ciborium::into_writer(value, &mut out).map_err(|e| CodecError(e.to_string()))?;
    Ok(out)
}

/// Decodes exactly one CBOR value; trailing bytes after it are an error.
pub fn from_cbor<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, CodecError> {
    let mut rest = bytes;
    let v = ciborium::from_reader(&mut rest).map_err(|e| CodecError(e.to_string()))?;
    if !rest.is_empty() {
        return Err(CodecError(format!("{} trailing bytes", rest.len())));
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trailing_bytes_are_rejected() {
        let mut b = to_cbor(&42u32).unwrap();
        assert_eq!(from_cbor::<u32>(&b).unwrap(), 42);
        b.push(0);
        assert!(from_cbor::<u32>(&b).is_err());
    }
}
