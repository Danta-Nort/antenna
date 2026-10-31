// SPDX-License-Identifier: AGPL-3.0-only
//! File encryption (SPEC §7 "Files and streams", §13): the STREAM construction over ChaCha20-Poly1305.
//!
//! No custom cryptography here (SPEC §7, §15): STREAM is the existing `aead-stream` 0.6 (RustCrypto, the `StreamBE32`
//! variant from Hoang–Reyhanitabar–Rogaway–Vizár 2015), AEAD is `chacha20poly1305` 0.11, key derivation is HKDF-SHA256
//! (`hkdf` 0.13), the hash is BLAKE3. The code below only lays out bytes into chunks.
//!
//! Format `xfile/0` (DECISIONS D-F-2):
//! ```text
//! header = "xfile/0\n" (8) ‖ u32be(65536) ‖ salt (32)                      — 44 bytes, in the clear
//! key    = HKDF-SHA256(salt = salt, ikm = file secret, info = "x/file/v0/stream-key")
//! chunk_i = ChaCha20-Poly1305(key, nonce = 0^7 ‖ u32be(i) ‖ last_flag, aad = header, 64 KiB of plaintext)
//! ```
//! The chunk index and the "last" flag go into the nonce, as in STREAM, age and Tink (the spec says "in the AAD"; the
//! effect is the same: both are authenticated; the AAD carries the header). The key is unique per file (random salt +
//! secret), so the nonce is a plain counter (SPEC §7). The last chunk is 0 to 64 KiB (an empty file is one empty last
//! chunk). Reordering, substitution, truncation at a chunk boundary and appending after the last chunk are a
//! `file_corrupt` error.

use std::io::Read;

use aead_stream::{DecryptorBE32, EncryptorBE32, StreamBE32};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit};
use hkdf::Hkdf;
use rand::{TryRngCore, rngs::OsRng};
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::error::{Error, Result};

/// Format v0 magic.
pub const MAGIC: &[u8; 8] = b"xfile/0\n";
/// Plaintext chunk size (SPEC §7: 64 KB).
pub const CHUNK: usize = 64 * 1024;
/// Poly1305 tag.
pub const TAG: usize = 16;
/// Header size.
pub const HEADER_LEN: usize = 8 + 4 + 32;
/// Size of an encrypted full chunk.
pub const CT_CHUNK: usize = CHUNK + TAG;

const KEY_INFO: &[u8] = b"x/file/v0/stream-key";

type Enc = EncryptorBE32<ChaCha20Poly1305>;
type Dec = DecryptorBE32<ChaCha20Poly1305>;

/// File secret (32 bytes). In stage B the sender creates it and sends it inside a Triple Ratchet message
/// (like Signal attachments); wiped on drop.
pub struct FileSecret(Zeroizing<[u8; 32]>);

impl FileSecret {
    /// New random secret from the OS CSPRNG.
    pub fn random() -> Self {
        let mut s = Zeroizing::new([0u8; 32]);
        OsRng
            .try_fill_bytes(s.as_mut())
            .expect("OS RNG must be available");
        Self(s)
    }

    /// From bytes (the secret arrived in an encrypted message or from a quarantine record).
    pub fn from_bytes(b: [u8; 32]) -> Self {
        Self(Zeroizing::new(b))
    }

    /// Secret bytes (for writing into the encrypted quarantine record).
    pub fn expose(&self) -> &[u8; 32] {
        &self.0
    }
}

impl Clone for FileSecret {
    fn clone(&self) -> Self {
        Self::from_bytes(*self.0)
    }
}

impl std::fmt::Debug for FileSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FileSecret(..)")
    }
}

/// `N` random bytes from the OS CSPRNG.
pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    OsRng
        .try_fill_bytes(&mut b)
        .expect("OS RNG must be available");
    b
}

fn stream_key(secret: &FileSecret, salt: &[u8]) -> Zeroizing<[u8; 32]> {
    let hk = Hkdf::<Sha256>::new(Some(salt), secret.expose());
    let mut k = Zeroizing::new([0u8; 32]);
    hk.expand(KEY_INFO, k.as_mut())
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    k
}

fn cipher(secret: &FileSecret, header: &[u8; HEADER_LEN]) -> ChaCha20Poly1305 {
    let k = stream_key(secret, &header[12..]);
    ChaCha20Poly1305::new(&(*k).into())
}

fn zero_prefix() -> aead_stream::Nonce<ChaCha20Poly1305, StreamBE32<ChaCha20Poly1305>> {
    Default::default()
}

/// Ciphertext length for a plaintext of length `plain_len`.
pub fn ciphertext_len(plain_len: u64) -> u64 {
    let chunks = plain_len.div_ceil(CHUNK as u64).max(1);
    HEADER_LEN as u64 + plain_len + chunks * TAG as u64
}

/// Plaintext length from the ciphertext length; `None` if an `xfile/0` ciphertext cannot have this length.
pub fn plaintext_len(ct_len: u64) -> Option<u64> {
    let body = ct_len.checked_sub(HEADER_LEN as u64)?;
    if body < TAG as u64 {
        return None;
    }
    let chunks = body.div_ceil(CT_CHUNK as u64);
    let last = body - (chunks - 1) * CT_CHUNK as u64;
    if last < TAG as u64 {
        return None;
    }
    Some(body - chunks * TAG as u64)
}

/// Result of encryption/decryption: length and BLAKE3 of the plaintext.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Plain {
    /// Plaintext length.
    pub len: u64,
    /// BLAKE3 of the plaintext (SPEC §7: "the file's BLAKE3 hash is computed over the plaintext content").
    pub blake3: [u8; 32],
}

/// Streaming encryptor: plaintext in pieces of any size → `xfile/0` ciphertext.
pub struct StreamEncryptor {
    enc: Option<Enc>,
    header: [u8; HEADER_LEN],
    header_out: bool,
    pending: Vec<u8>,
    hasher: blake3::Hasher,
    len: u64,
}

impl StreamEncryptor {
    /// New encryptor with a random salt.
    pub fn new(secret: &FileSecret) -> Self {
        let mut header = [0u8; HEADER_LEN];
        header[..8].copy_from_slice(MAGIC);
        header[8..12].copy_from_slice(&(CHUNK as u32).to_be_bytes());
        header[12..].copy_from_slice(&random_bytes::<32>());
        let enc = Enc::from_aead(cipher(secret, &header), &zero_prefix());
        Self {
            enc: Some(enc),
            header,
            header_out: false,
            pending: Vec::with_capacity(CT_CHUNK),
            hasher: blake3::Hasher::new(),
            len: 0,
        }
    }

    fn emit_header(&mut self, out: &mut Vec<u8>) {
        if !self.header_out {
            out.extend_from_slice(&self.header);
            self.header_out = true;
        }
    }

    /// Adds plaintext; appends to `out` the ciphertext of chunks already known not to be the last one.
    pub fn update(&mut self, mut data: &[u8], out: &mut Vec<u8>) -> Result<()> {
        self.emit_header(out);
        self.hasher.update(data);
        self.len += data.len() as u64;
        while !data.is_empty() {
            if self.pending.len() == CHUNK {
                // More data arrived, so the buffered full chunk is not the last one.
                let enc = self
                    .enc
                    .as_mut()
                    .ok_or_else(|| Error::internal("encryptor finished"))?;
                enc.encrypt_next_in_place(&self.header, &mut self.pending)
                    .map_err(|_| Error::internal("STREAM counter exhausted"))?;
                out.extend_from_slice(&self.pending);
                self.pending.clear();
            }
            let take = (CHUNK - self.pending.len()).min(data.len());
            self.pending.extend_from_slice(&data[..take]);
            data = &data[take..];
        }
        Ok(())
    }

    /// Finishes: the last chunk (with the "last" flag), length and BLAKE3 of the plaintext.
    pub fn finish(mut self, out: &mut Vec<u8>) -> Result<Plain> {
        self.emit_header(out);
        let enc = self
            .enc
            .take()
            .ok_or_else(|| Error::internal("encryptor finished"))?;
        enc.encrypt_last_in_place(&self.header, &mut self.pending)
            .map_err(|_| Error::internal("STREAM encryption failed"))?;
        out.extend_from_slice(&self.pending);
        Ok(Plain {
            len: self.len,
            blake3: *self.hasher.finalize().as_bytes(),
        })
    }
}

/// Streaming `xfile/0` decryptor: ciphertext in pieces of any size → verified plaintext.
///
/// Every piece it outputs has already passed the tag check, but the **whole** file is authentic only if
/// [`Self::finish`] returned `Ok` (the last chunk carries the "last" flag). The consumer must not release the result
/// before that.
pub struct StreamDecryptor {
    secret: FileSecret,
    header: Vec<u8>,
    dec: Option<Dec>,
    pending: Vec<u8>,
    hasher: blake3::Hasher,
    len: u64,
    failed: bool,
}

impl StreamDecryptor {
    /// New decryptor.
    pub fn new(secret: &FileSecret) -> Self {
        Self {
            secret: secret.clone(),
            header: Vec::with_capacity(HEADER_LEN),
            dec: None,
            pending: Vec::with_capacity(2 * CT_CHUNK),
            hasher: blake3::Hasher::new(),
            len: 0,
            failed: false,
        }
    }

    fn header_arr(&self) -> [u8; HEADER_LEN] {
        let mut h = [0u8; HEADER_LEN];
        h.copy_from_slice(&self.header);
        h
    }

    fn fail(&mut self, what: &str) -> Error {
        self.failed = true;
        self.dec = None;
        Error::corrupt(what.to_string())
    }

    /// Adds ciphertext; appends to `out` the decrypted text of full chunks that are not the last one.
    pub fn update(&mut self, mut data: &[u8], out: &mut Vec<u8>) -> Result<()> {
        if self.failed {
            return Err(Error::corrupt("decryptor already failed"));
        }
        if self.header.len() < HEADER_LEN {
            let take = (HEADER_LEN - self.header.len()).min(data.len());
            self.header.extend_from_slice(&data[..take]);
            data = &data[take..];
            if self.header.len() == HEADER_LEN {
                if &self.header[..8] != MAGIC {
                    return Err(self.fail("not an xfile/0 ciphertext"));
                }
                if self.header[8..12] != (CHUNK as u32).to_be_bytes() {
                    return Err(self.fail("unsupported chunk size"));
                }
                let h = self.header_arr();
                self.dec = Some(Dec::from_aead(cipher(&self.secret, &h), &zero_prefix()));
            }
        }
        if self.header.len() < HEADER_LEN {
            return Ok(()); // the header has not fully arrived yet
        }
        self.pending.extend_from_slice(data);
        let header = self.header_arr();
        let mut off = 0;
        let mut chunk = Vec::with_capacity(CT_CHUNK);
        // A chunk is not the last one only if at least one more byte follows it.
        while self.pending.len() - off > CT_CHUNK {
            chunk.clear();
            chunk.extend_from_slice(&self.pending[off..off + CT_CHUNK]);
            let Some(dec) = self.dec.as_mut() else {
                return Err(self.fail("missing header"));
            };
            if dec.decrypt_next_in_place(&header, &mut chunk).is_err() {
                return Err(self.fail("chunk authentication failed"));
            }
            self.hasher.update(&chunk);
            self.len += chunk.len() as u64;
            out.extend_from_slice(&chunk);
            off += CT_CHUNK;
        }
        self.pending.drain(..off);
        Ok(())
    }

    /// Finishes: the last chunk must carry the "last" flag. Returns the length and BLAKE3 of the plaintext.
    pub fn finish(mut self, out: &mut Vec<u8>) -> Result<Plain> {
        if self.failed {
            return Err(Error::corrupt("decryptor already failed"));
        }
        if self.header.len() < HEADER_LEN {
            return Err(self.fail("truncated header"));
        }
        if self.pending.len() < TAG || self.pending.len() > CT_CHUNK {
            return Err(self.fail("truncated ciphertext"));
        }
        let header = self.header_arr();
        let Some(dec) = self.dec.take() else {
            return Err(self.fail("missing header"));
        };
        let mut last = std::mem::take(&mut self.pending);
        if dec.decrypt_last_in_place(&header, &mut last).is_err() {
            return Err(self.fail("last chunk authentication failed (truncated or reordered)"));
        }
        self.hasher.update(&last);
        self.len += last.len() as u64;
        out.extend_from_slice(&last);
        Ok(Plain {
            len: self.len,
            blake3: *self.hasher.finalize().as_bytes(),
        })
    }
}

/// Encrypts bytes in one go (tests, small files).
pub fn encrypt_to_vec(secret: &FileSecret, plain: &[u8]) -> Result<(Vec<u8>, Plain)> {
    let mut e = StreamEncryptor::new(secret);
    let mut out = Vec::with_capacity(ciphertext_len(plain.len() as u64) as usize);
    e.update(plain, &mut out)?;
    let p = e.finish(&mut out)?;
    Ok((out, p))
}

/// Decrypts bytes in one go (tests, small files).
pub fn decrypt_to_vec(secret: &FileSecret, ct: &[u8]) -> Result<(Vec<u8>, Plain)> {
    let mut d = StreamDecryptor::new(secret);
    let mut out = Vec::with_capacity(ct.len());
    d.update(ct, &mut out)?;
    let p = d.finish(&mut out)?;
    Ok((out, p))
}

/// Encrypts a stream (`Read`) in pieces: `sink` receives ciphertext as it becomes ready (about 1 MiB at a time).
pub fn encrypt_reader(
    secret: &FileSecret,
    mut reader: impl Read,
    mut sink: impl FnMut(Vec<u8>) -> Result<()>,
) -> Result<Plain> {
    let mut e = StreamEncryptor::new(secret);
    let mut buf = vec![0u8; 16 * CHUNK];
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        };
        let mut out = Vec::with_capacity(n + 2 * CT_CHUNK);
        e.update(&buf[..n], &mut out)?;
        if !out.is_empty() {
            sink(out)?;
        }
    }
    let mut out = Vec::with_capacity(CT_CHUNK);
    let p = e.finish(&mut out)?;
    sink(out)?;
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i * 31 + 7) as u8).collect()
    }

    #[test]
    fn roundtrip_all_boundaries() {
        let s = FileSecret::random();
        for n in [0, 1, CHUNK - 1, CHUNK, CHUNK + 1, 2 * CHUNK, 3 * CHUNK + 17] {
            let plain = data(n);
            let (ct, p) = encrypt_to_vec(&s, &plain).unwrap();
            assert_eq!(ct.len() as u64, ciphertext_len(n as u64), "n={n}");
            assert_eq!(plaintext_len(ct.len() as u64), Some(n as u64), "n={n}");
            assert_eq!(p.len, n as u64);
            assert_eq!(p.blake3, *blake3::hash(&plain).as_bytes());
            let (back, q) = decrypt_to_vec(&s, &ct).unwrap();
            assert_eq!(back, plain);
            assert_eq!(p, q);
            // One byte at a time gives the same result.
            let mut d = StreamDecryptor::new(&s);
            let mut out = Vec::new();
            for b in &ct {
                d.update(std::slice::from_ref(b), &mut out).unwrap();
            }
            assert_eq!(d.finish(&mut out).unwrap(), p);
            assert_eq!(out, plain);
        }
    }

    #[test]
    fn same_plaintext_gives_unrelated_ciphertexts() {
        // Unique salt: the same file in two links does not give the same blob (no dedup across links).
        let s = FileSecret::random();
        let (a, _) = encrypt_to_vec(&s, b"same").unwrap();
        let (b, _) = encrypt_to_vec(&s, b"same").unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn wrong_key_is_rejected() {
        let (ct, _) = encrypt_to_vec(&FileSecret::random(), &data(1000)).unwrap();
        let e = decrypt_to_vec(&FileSecret::random(), &ct).unwrap_err();
        assert_eq!(e.code, crate::error::code::CORRUPT);
    }

    #[test]
    fn tampering_reordering_truncation_and_extension_are_rejected() {
        let s = FileSecret::random();
        let plain = data(3 * CHUNK + 100);
        let (ct, _) = encrypt_to_vec(&s, &plain).unwrap();
        let chunk =
            |i: usize| HEADER_LEN + i * CT_CHUNK..(HEADER_LEN + (i + 1) * CT_CHUNK).min(ct.len());
        let reject = |bad: Vec<u8>, what: &str| {
            let r = decrypt_to_vec(&s, &bad);
            assert!(r.is_err(), "{what} must be rejected");
            assert_eq!(r.unwrap_err().code, crate::error::code::CORRUPT, "{what}");
        };
        // One flipped byte in every chunk and in the header.
        for i in 0..4 {
            let mut bad = ct.clone();
            bad[chunk(i).start + 5] ^= 1;
            reject(bad, &format!("flip in chunk {i}"));
        }
        for pos in [0, 9, 20, HEADER_LEN - 1] {
            let mut bad = ct.clone();
            bad[pos] ^= 1;
            reject(bad, &format!("flip in header at {pos}"));
        }
        // Swap chunks 0 and 1.
        let mut bad = ct[..HEADER_LEN].to_vec();
        bad.extend_from_slice(&ct[chunk(1)]);
        bad.extend_from_slice(&ct[chunk(0)]);
        bad.extend_from_slice(&ct[chunk(2).start..]);
        reject(bad, "swap of chunks 0 and 1");
        // Truncation at a chunk boundary (without the last chunk) and in the middle of a chunk.
        reject(
            ct[..chunk(3).start].to_vec(),
            "truncation at a chunk boundary",
        );
        reject(
            ct[..chunk(3).start + 10].to_vec(),
            "truncation inside the last chunk",
        );
        reject(ct[..HEADER_LEN].to_vec(), "header only");
        reject(ct[..HEADER_LEN - 1].to_vec(), "short header");
        // Appending after the last chunk: a foreign chunk and garbage.
        let mut bad = ct.clone();
        bad.extend_from_slice(&ct[chunk(0)]);
        reject(bad, "extension with a chunk");
        let mut bad = ct.clone();
        bad.push(0);
        reject(bad, "extension with a byte");
        // Repeated chunk.
        let mut bad = ct[..chunk(1).end].to_vec();
        bad.extend_from_slice(&ct[chunk(1)]);
        bad.extend_from_slice(&ct[chunk(2).start..]);
        reject(bad, "duplicated chunk");
        // A chunk from another file with the same secret (different salt → different key).
        let (other, _) = encrypt_to_vec(&s, &plain).unwrap();
        let mut bad = ct.clone();
        bad[chunk(1)].copy_from_slice(&other[chunk(1)]);
        reject(bad, "chunk from another file");
    }

    #[test]
    fn reader_api_matches() {
        let s = FileSecret::random();
        let plain = data(5 * CHUNK + 3);
        let mut ct = Vec::new();
        let p = encrypt_reader(&s, &plain[..], |b| {
            ct.extend_from_slice(&b);
            Ok(())
        })
        .unwrap();
        let (back, q) = decrypt_to_vec(&s, &ct).unwrap();
        assert_eq!(back, plain);
        assert_eq!(p, q);
    }

    #[test]
    fn impossible_ciphertext_lengths() {
        assert_eq!(plaintext_len(HEADER_LEN as u64 + 15), None);
        assert_eq!(plaintext_len(HEADER_LEN as u64 + 16), Some(0));
        assert_eq!(plaintext_len((HEADER_LEN + CT_CHUNK + 5) as u64), None);
        assert_eq!(plaintext_len(3), None);
    }
}
