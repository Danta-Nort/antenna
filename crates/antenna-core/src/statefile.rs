// SPDX-License-Identifier: AGPL-3.0-only
//! Link state counters outside the DB: rollback protection (SPEC §8 "State rollback protection", §13; D-45).
//!
//! Restoring `antenna.db` from a backup would bring back an old ratchet state: the next message would be encrypted
//! with already used keys. Therefore every transaction that changes a link session (send, receive, rekey) increments
//! the counter `links.state_counter` in the DB, and **after** the transaction commits, the same value is written here,
//! to a separate file `state-counters.cbor` with HMAC-SHA256 under a key derived from the device root key. If on unlock
//! the DB counter is lower than the file counter, the database has fallen behind: sending on the link is blocked until
//! a rekey confirmed by the owners (`antenna rekey`).
//!
//! The order "DB first, then the file" rules out false positives: after a crash between the two, the file lags behind
//! the DB and simply catches up. The file is written atomically (temporary file, fsync, rename); its values only grow.
//!
//! **Limits (honestly, without a TPM):** the file lives on the same disk. Rolling back the whole data directory or a VM
//! snapshot rolls it back too, which cannot be seen locally; such a rollback is caught by the contact through message
//! numbers during verification (`sync`, §16). A deleted or damaged file with non-empty DB counters counts as a rollback
//! (the safe side).

use std::sync::PoisonError;
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

use antenna_proto::LinkId;
use serde::{Deserialize, Serialize};

use crate::{
    crypto::{self, Secret32},
    error::{Error, Result},
    owner_only::OwnerOnly,
};

/// File name in the data directory.
pub const FILE_NAME: &str = "state-counters.cbor";
const MAC_LABEL: &[u8] = b"x/state-counters/v1";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileV1 {
    v: u16,
    links: Vec<Entry>,
    #[serde(with = "serde_bytes")]
    mac: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    #[serde(with = "serde_bytes")]
    link: [u8; 32],
    counter: u64,
}

/// How the file was read on unlock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Loaded {
    /// Read, HMAC valid.
    Ok,
    /// No file.
    Missing,
    /// The file exists but is damaged or its HMAC did not match.
    Damaged,
}

/// Link counters.
pub struct StateFile {
    path: PathBuf,
    key: Secret32,
    map: Mutex<BTreeMap<LinkId, u64>>,
    loaded: Loaded,
}

impl std::fmt::Debug for StateFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "StateFile({:?})", self.loaded)
    }
}

fn mac(key: &Secret32, entries: &BTreeMap<LinkId, u64>) -> [u8; 32] {
    let mut m = Vec::with_capacity(MAC_LABEL.len() + 4 + entries.len() * 40);
    m.extend_from_slice(MAC_LABEL);
    m.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for (l, c) in entries {
        m.extend_from_slice(&l.0);
        m.extend_from_slice(&c.to_be_bytes());
    }
    crypto::hmac(key.as_slice(), &[&m])
}

impl StateFile {
    /// File path in the data directory.
    pub fn path(data_dir: &Path) -> PathBuf {
        data_dir.join(FILE_NAME)
    }

    /// Reads the file (the key comes from the device root key).
    pub fn load(data_dir: &Path, key: Secret32) -> StateFile {
        let path = Self::path(data_dir);
        let (map, loaded) = match fs::read(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                (BTreeMap::new(), Loaded::Missing)
            }
            Err(_) => (BTreeMap::new(), Loaded::Damaged),
            Ok(bytes) => match antenna_proto::from_cbor::<FileV1>(&bytes) {
                Ok(f) if f.v == 1 => {
                    let map: BTreeMap<LinkId, u64> = f
                        .links
                        .iter()
                        .map(|e| (LinkId(e.link), e.counter))
                        .collect();
                    if map.len() == f.links.len() && crypto::ct_eq(&mac(&key, &map), &f.mac) {
                        (map, Loaded::Ok)
                    } else {
                        (BTreeMap::new(), Loaded::Damaged)
                    }
                }
                _ => (BTreeMap::new(), Loaded::Damaged),
            },
        };
        StateFile {
            path,
            key,
            map: Mutex::new(map),
            loaded,
        }
    }

    /// How it was read.
    pub fn loaded(&self) -> Loaded {
        self.loaded
    }

    /// Link counter in the file (0 if there is no entry).
    pub fn get(&self, link: &LinkId) -> u64 {
        self.map
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(link)
            .copied()
            .unwrap_or(0)
    }

    /// Record a link counter value after the DB transaction commits. The value only grows.
    pub fn record(&self, link: &LinkId, value: u64) -> Result<()> {
        let mut m = self.map.lock().unwrap_or_else(PoisonError::into_inner);
        let cur = m.get(link).copied().unwrap_or(0);
        if value <= cur {
            return Ok(());
        }
        m.insert(*link, value);
        self.write(&m)
    }

    /// Remove a link (`antenna revoke`).
    pub fn remove(&self, link: &LinkId) -> Result<()> {
        let mut m = self.map.lock().unwrap_or_else(PoisonError::into_inner);
        if m.remove(link).is_some() {
            self.write(&m)?;
        }
        Ok(())
    }

    /// Rewrite the file (after unlock: create it if it did not exist).
    pub fn flush(&self) -> Result<()> {
        let m = self.map.lock().unwrap_or_else(PoisonError::into_inner);
        self.write(&m)
    }

    fn write(&self, m: &BTreeMap<LinkId, u64>) -> Result<()> {
        let f = FileV1 {
            v: 1,
            links: m
                .iter()
                .map(|(l, c)| Entry {
                    link: l.0,
                    counter: *c,
                })
                .collect(),
            mac: mac(&self.key, m).to_vec(),
        };
        let bytes = antenna_proto::to_cbor(&f)?;
        let tmp = self.path.with_extension("cbor.tmp");
        {
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .owner_only()
                .open(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        fs::rename(&tmp, &self.path)
            .map_err(|e| Error::internal(format!("state counters: {e}")))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_grows_only_and_detects_tampering() {
        let dir = tempfile::tempdir().unwrap();
        let key = crypto::random_secret();
        let k2 = zeroize::Zeroizing::new(*key);
        let s = StateFile::load(dir.path(), key);
        assert_eq!(s.loaded(), Loaded::Missing);
        let l = LinkId([1; 32]);
        s.record(&l, 5).unwrap();
        s.record(&l, 3).unwrap(); // Does not decrease
        assert_eq!(s.get(&l), 5);
        let s2 = StateFile::load(dir.path(), zeroize::Zeroizing::new(*k2));
        assert_eq!(s2.loaded(), Loaded::Ok);
        assert_eq!(s2.get(&l), 5);
        // A different key (a different keystore): the file is rejected
        let s3 = StateFile::load(dir.path(), crypto::random_secret());
        assert_eq!(s3.loaded(), Loaded::Damaged);
        // A modified byte: rejected
        let p = StateFile::path(dir.path());
        let mut b = fs::read(&p).unwrap();
        let i = b.len() - 40;
        b[i] ^= 1;
        fs::write(&p, &b).unwrap();
        assert_eq!(StateFile::load(dir.path(), k2).loaded(), Loaded::Damaged);
    }
}
