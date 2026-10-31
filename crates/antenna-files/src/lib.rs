// SPDX-License-Identifier: AGPL-3.0-only
//! Files and quarantine (SPEC §7 "Files and streams", §10, §13, §15 "Files"): slice 4, stage A.
//!
//! Receive pipeline (SPEC §10): manifest → quarantine → sandboxed check → safe preview → explicit acceptance.
//! - [`crypt`]. File encryption with the STREAM construction (ChaCha20-Poly1305, 64 KiB chunks), BLAKE3 of the
//!   plaintext;
//! - [`manifest`]. Signed manifest (Ed25519 with the link context) and the file offer;
//! - [`policy`]. Per-level limits and who may accept a file;
//! - [`blobs`]. Ciphertext transfer as an iroh-blobs blob: separate store and ACL per link, resumption;
//! - [`quarantine`]. Encrypted quarantine (neither the agent nor the OS has a path to the plaintext);
//! - [`sandbox`] / [`worker`] / `sandbox_linux` / `sandbox_macos`, [`detect`], [`inspect`], [`secrets`], `yara`. The
//!   check runs in a separate process without network, file system or keys (Linux: Landlock + seccomp + rlimits;
//!   macOS: Seatbelt + rlimits, profile in [`seatbelt`]);
//! - [`cdr`]. Preview: image → clean PNG, PDF → pixels and text, documents → text;
//! - [`kinds`]. Kinds of files (code and markup, executables, installers) and the rules on them: what an own
//!   computer saves and holds, a contact's allowlist, why a held file waits (D-130);
//! - [`names`] / [`accept`]. Name normalization and acceptance into `inbox/` or `shared/`;
//! - [`outgoing`]. Sending: sender-side check, encryption, signed manifest;
//! - [`picture`]. Profile picture photos: the same check, then a square JPEG made from the rebuilt pixels only.
//!
//! No custom cryptography (SPEC §7, §15): `aead-stream`, `chacha20poly1305`, `hkdf`, `blake3`, `ed25519-dalek`.

pub mod accept;
pub mod bip39_english;
pub mod blobs;
pub mod cdr;
pub mod codec;
pub mod crypt;
pub mod detect;
pub mod error;
pub mod inspect;
pub mod kinds;
pub mod manifest;
pub mod names;
pub mod outgoing;
pub mod pdfscan;
pub mod picture;
pub mod policy;
pub mod quarantine;
pub mod report;
pub mod sandbox;
#[cfg(target_os = "linux")]
pub mod sandbox_linux;
#[cfg(target_os = "macos")]
pub mod sandbox_macos;
pub mod seatbelt;
pub mod secrets;
pub mod text;
pub mod worker;
#[cfg(feature = "yara")]
pub mod yara;

pub use error::{Error, Result};

/// Current time, Unix milliseconds.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
