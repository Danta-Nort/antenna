// SPDX-License-Identifier: AGPL-3.0-only
//! CBOR (ciborium), as in `antenna_proto`: exactly one value, trailing bytes are an error; input length is capped
//! before parsing.

use crate::error::{Error, Result, code};

/// Encodes a value as CBOR.
pub fn to_cbor<T: serde::Serialize>(value: &T) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    ciborium::into_writer(value, &mut out).map_err(|e| Error::internal(format!("cbor: {e}")))?;
    Ok(out)
}

/// Decodes exactly one CBOR value of at most `max` bytes; extra bytes after it are an error.
pub fn from_cbor<T: serde::de::DeserializeOwned>(
    bytes: &[u8],
    max: usize,
    what: &str,
) -> Result<T> {
    if bytes.len() > max {
        return Err(Error::new(
            code::BAD_MANIFEST,
            format!("{what}: {} bytes > {max}", bytes.len()),
        ));
    }
    let mut rest = bytes;
    let v = ciborium::from_reader(&mut rest)
        .map_err(|e| Error::new(code::BAD_MANIFEST, format!("{what}: {e}")))?;
    if !rest.is_empty() {
        return Err(Error::new(
            code::BAD_MANIFEST,
            format!("{what}: {} trailing bytes", rest.len()),
        ));
    }
    Ok(v)
}
