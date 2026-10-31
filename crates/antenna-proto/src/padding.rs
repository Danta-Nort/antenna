// SPDX-License-Identifier: Apache-2.0
//! Ciphertext padding buckets (SPEC §7): 256 B, 1 KB, 4 KB, 16 KB, then multiples of 16 KB, so that the length
//! does not reveal the content.
//!
//! Format (`docs/PROTOCOL.md` §12): `pad(x) = u32be(len(x)) ‖ x ‖ 0x00…` up to `padded_len(4 + len(x))`.
//! The padding lies **outside** the libsignal ciphertext: integrity comes from the libsignal MAC; the length is only
//! needed for parsing.

/// Smallest bucket.
pub const MIN_BUCKET: usize = 256;
/// Bucket step above 16 KB.
pub const LARGE_STEP: usize = 16 * 1024;

/// Size to which a payload of `len` bytes must be padded.
///
/// Returns `None` on `usize` overflow.
pub fn padded_len(len: usize) -> Option<usize> {
    for bucket in [256usize, 1024, 4 * 1024, 16 * 1024] {
        if len <= bucket {
            return Some(bucket);
        }
    }
    len.checked_add(LARGE_STEP - 1)
        .map(|n| n / LARGE_STEP * LARGE_STEP)
}

/// Error parsing a padded block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PadError {
    /// The block is shorter than the length header.
    Short,
    /// The length in the header exceeds the block.
    BadLength,
    /// The block size does not match any bucket for this length.
    NotABucket,
    /// The padding tail is not zero.
    NonZeroPadding,
    /// The payload is too large (overflow).
    TooLarge,
}

impl std::fmt::Display for PadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "padding: {self:?}")
    }
}

impl std::error::Error for PadError {}

/// Pads `payload` to a bucket: `u32be(len) ‖ payload ‖ zeros`.
pub fn pad(payload: &[u8]) -> Result<Vec<u8>, PadError> {
    let len = u32::try_from(payload.len()).map_err(|_| PadError::TooLarge)?;
    let total = padded_len(payload.len().checked_add(4).ok_or(PadError::TooLarge)?)
        .ok_or(PadError::TooLarge)?;
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(payload);
    out.resize(total, 0);
    Ok(out)
}

/// Removes the padding. Strict: the block size must be the bucket for this length and the tail must be zeros.
pub fn unpad(block: &[u8]) -> Result<&[u8], PadError> {
    if block.len() < 4 {
        return Err(PadError::Short);
    }
    let len = u32::from_be_bytes([block[0], block[1], block[2], block[3]]) as usize;
    let end = len.checked_add(4).ok_or(PadError::BadLength)?;
    if end > block.len() {
        return Err(PadError::BadLength);
    }
    if padded_len(end) != Some(block.len()) {
        return Err(PadError::NotABucket);
    }
    if block[end..].iter().any(|&b| b != 0) {
        return Err(PadError::NonZeroPadding);
    }
    Ok(&block[4..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_unpad_roundtrip_and_sizes_are_buckets() {
        for len in [0usize, 1, 100, 252, 253, 1020, 1021, 5000, 70_000] {
            let payload: Vec<u8> = (0..len).map(|i| (i % 251) as u8 + 1).collect();
            let block = pad(&payload).unwrap();
            assert_eq!(Some(block.len()), padded_len(len + 4), "len={len}");
            assert_eq!(unpad(&block).unwrap(), &payload[..]);
        }
        assert_eq!(pad(&[0u8; 252]).unwrap().len(), 256);
        assert_eq!(pad(&[0u8; 253]).unwrap().len(), 1024);
    }

    #[test]
    fn unpad_is_strict() {
        let mut block = pad(b"hello").unwrap();
        assert_eq!(unpad(&block[..3]), Err(PadError::Short));
        assert_eq!(unpad(&block[..255]), Err(PadError::NotABucket));
        block[200] = 1;
        assert_eq!(unpad(&block), Err(PadError::NonZeroPadding));
        let mut block = pad(b"hello").unwrap();
        block[0..4].copy_from_slice(&1000u32.to_be_bytes());
        assert_eq!(unpad(&block), Err(PadError::BadLength));
        let mut block = pad(b"hello").unwrap();
        block[0..4].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(unpad(&block).is_err());
    }

    #[test]
    fn buckets_from_spec_section_7() {
        let cases = [
            (0, 256),
            (1, 256),
            (256, 256),
            (257, 1024),
            (1024, 1024),
            (1025, 4096),
            (4096, 4096),
            (4097, 16384),
            (16384, 16384),
            (16385, 32768),
            (32768, 32768),
            (32769, 49152),
        ];
        for (len, want) in cases {
            assert_eq!(padded_len(len), Some(want), "len={len}");
        }
    }

    #[test]
    fn never_shrinks_and_overflow_is_none() {
        for len in (0..200_000).step_by(997) {
            assert!(padded_len(len).unwrap() >= len);
        }
        assert_eq!(padded_len(usize::MAX), None);
    }
}
