// SPDX-License-Identifier: AGPL-3.0-only
//! Core of the `antennad` daemon (SPEC §3): keys, encrypted store, transport, pairing, E2E, control socket.
//!
//! v0.1 MVP: slice 1 "link" (Argon2id keystore, SQLCipher, pairwise iroh endpoints with an accept-list, pairing,
//! libsignal Triple Ratchet, send queue), slice 2 "agents and permissions" (tokens, policy engine, taint, approval,
//! control protocol), slice 3 "history and integrity" (message signatures, history verification, rollback protection,
//! rekey, receipts in the shared DAG, owner session). Files are slice 4 (the `antenna-files` crate).
//! No custom cryptography (SPEC §7, §15): only audited crates, listed in `docs/PROTOCOL.md` §2.

pub mod addressing;
pub mod agent_api;
mod agent_stop;
pub mod agentid;
pub mod agents;
mod app_hosts;
pub mod approvals;
pub mod autoupdate;
pub mod chats;
pub mod connections;
/// The English BIP-0039 word list moved to `antenna-files` together with the secret scanner (slice 4).
pub use antenna_files::bip39_english;
pub mod control;
pub mod crypto;
#[cfg(windows)]
pub mod data_folder;
pub mod data_lock;
pub mod delegation;
pub mod devices;
pub mod e2e;
pub mod error;
pub mod escalations;
pub mod events;
mod file_fate;
mod file_notices;
mod file_prefs;
pub mod files;
pub mod history;
pub mod invites;
pub mod keystore;
pub mod lan;
pub mod linksync;
pub mod local;
pub mod local_routes;
pub mod node;
pub mod owner;
pub mod owner_keys;
mod owner_only;
pub mod pairing;
pub mod pictures;
pub mod policy;
pub mod procinfo;
pub mod resident;
mod resident_park;
pub mod sandbox;
pub mod statefile;
pub mod store;
pub mod stream;
pub mod sync;
pub mod teams;
pub mod transport;
mod urgent;
pub mod wake;

pub use antenna_proto::ProtocolVersion;

/// Protocol version implemented by this core build.
pub const PROTOCOL_VERSION: ProtocolVersion = ProtocolVersion::CURRENT;

/// Current time, Unix milliseconds.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
