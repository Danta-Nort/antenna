// SPDX-License-Identifier: AGPL-3.0-only
//! Shared helpers for the antenna-files integration tests.
#![allow(
    dead_code,
    reason = "shared by several test binaries, each uses a part"
)]

pub mod samples;

use std::io::Read;

use antenna_files::sandbox::{Checker, CheckerConfig};
use iroh::{Endpoint, EndpointAddr, RelayMode, endpoint::presets};

/// Endpoint on 127.0.0.1 without a relay (like the pairwise link endpoint in the slice 1 tests).
pub async fn ep() -> Endpoint {
    Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Disabled)
        .bind_addr("127.0.0.1:0")
        .unwrap()
        .bind()
        .await
        .unwrap()
}

/// Endpoint address for dialing.
pub fn addr(ep: &Endpoint) -> EndpointAddr {
    EndpointAddr::new(ep.id()).with_ip_addr(ep.bound_sockets()[0])
}

/// Path to the sandbox worker.
pub fn worker() -> &'static str {
    env!("CARGO_BIN_EXE_antenna-files-sandbox")
}

/// Sandboxed check without an antivirus.
pub fn checker() -> Checker {
    let mut cfg = CheckerConfig::new(worker());
    cfg.av = None;
    Checker::new(cfg)
}

/// Deterministic pseudorandom stream of `len` bytes (BLAKE3 XOF): large files without disk space.
pub struct Synth {
    xof: blake3::OutputReader,
    left: u64,
}

impl Synth {
    pub fn new(seed: u8, len: u64) -> Self {
        Self {
            xof: blake3::Hasher::new_keyed(&[seed; 32]).finalize_xof(),
            left: len,
        }
    }
}

impl Read for Synth {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = (buf.len() as u64).min(self.left) as usize;
        self.xof.fill(&mut buf[..n]);
        self.left -= n as u64;
        Ok(n)
    }
}

/// BLAKE3 and length of a [`Synth`] stream.
pub fn synth_hash(seed: u8, len: u64) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    std::io::copy(&mut Synth::new(seed, len), &mut h).unwrap();
    *h.finalize().as_bytes()
}

/// Free space in a directory (bytes) via `statvfs`.
#[cfg(unix)]
pub fn free_bytes(p: &std::path::Path) -> Option<u64> {
    let s = rustix::fs::statvfs(p).unwrap();
    Some(s.f_bavail * s.f_frsize)
}

/// Windows: std cannot tell (it needs `GetDiskFreeSpaceExW`), so the guard is skipped; a full disk fails the test anyway.
#[cfg(windows)]
pub fn free_bytes(_p: &std::path::Path) -> Option<u64> {
    None
}

/// Encrypts into the link's store and allows serving it to the contact (as the daemon does after the policy decision).
pub async fn offered(
    blobs: &antenna_files::blobs::LinkBlobs,
    reader: impl Read + Send + 'static,
    secret: &antenna_files::crypt::FileSecret,
) -> antenna_files::blobs::Outgoing {
    let out = blobs.add_outgoing(reader, secret).await.unwrap();
    blobs.offer_existing(out.blob).await.unwrap();
    out
}
