// SPDX-License-Identifier: AGPL-3.0-only
//! Unlock slots (v7, `docs/CONTROL.md` §22.4, D-102, experimental): the root key wrapped a second time, once per owner
//! key enrolled with `unlock`, under a 32-byte random slot key the window keeps sealed to its Secure Enclave key.
//!
//! The same construction as the password slot, with HKDF-SHA256 in place of Argon2id (the slot key is uniformly random,
//! so it needs no password hardening): `KEK = HKDF-SHA256(salt, slot_key, "antenna/keyslot/v1/kek")`, the root key
//! sealed with ChaCha20-Poly1305 under it, the AAD covering the slot's header and SHA-256 of `keystore.cbor`, so a slot
//! opens only the keystore it was made for. Only `hkdf`, `sha2` and `chacha20poly1305` (`docs/STACK.md`), no new
//! construction.
//!
//! The slots live in their own file, `keyslots.cbor`, and `keystore.cbor` (the password slot, v0) is never rewritten:
//! a daemon before v7, started after `antenna update --rollback`, parses `keystore.cbor` strictly and would refuse any
//! other format, which would lock the owner out of their node. The file is written atomically (a temporary file,
//! `fsync`, rename), so a crash leaves the old set of slots or the new one, never half of one.

use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

use antenna_proto::control::code;
use chacha20poly1305::{
    ChaCha20Poly1305, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use super::{RootKey, serde_bytes_12, serde_bytes_vec};
use crate::{
    crypto::{self, Secret32},
    error::{Error, Result},
    owner_only::OwnerOnly,
};

/// The slots file in the data directory.
pub const FILE_NAME: &str = "keyslots.cbor";

const KDF_NAME: &str = "hkdf-sha256";
const AEAD_NAME: &str = "chacha20poly1305";
const AAD_LABEL: &[u8] = b"antenna/keyslot/v1";
const KEK_INFO: &[u8] = b"antenna/keyslot/v1/kek";
/// At most this many slots (one per owner key; `OWNER_KEYS_MAX` is lower).
const SLOTS_MAX: usize = 16;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SlotsFile {
    v: u16,
    slots: Vec<Slot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Slot {
    /// The owner key this slot belongs to (16 hex).
    key_id: String,
    kdf: String,
    #[serde(with = "serde_bytes_32")]
    salt: [u8; 32],
    aead: String,
    #[serde(with = "serde_bytes_12")]
    nonce: [u8; 12],
    #[serde(with = "serde_bytes_vec")]
    ct: Vec<u8>,
}

impl Slot {
    /// AAD = label ‖ the header ‖ SHA-256 of the keystore file: a changed header, or a slot moved to another keystore,
    /// does not open.
    fn aad(&self, keystore: &[u8]) -> Vec<u8> {
        let mut a = Vec::new();
        a.extend_from_slice(AAD_LABEL);
        a.extend_from_slice(&crypto::lp(self.key_id.as_bytes()));
        a.extend_from_slice(&crypto::lp(self.kdf.as_bytes()));
        a.extend_from_slice(&self.salt);
        a.extend_from_slice(&crypto::lp(self.aead.as_bytes()));
        a.extend_from_slice(&self.nonce);
        a.extend_from_slice(&crypto::sha256(&[keystore]));
        a
    }
}

fn kek(salt: &[u8; 32], slot_key: &[u8; 32]) -> Secret32 {
    crypto::hkdf32(salt, slot_key, &[KEK_INFO])
}

/// Path to the slots file.
pub fn path(data_dir: &Path) -> PathBuf {
    data_dir.join(FILE_NAME)
}

fn load(data_dir: &Path) -> Result<SlotsFile> {
    match fs::read(path(data_dir)) {
        Ok(b) => {
            let f: SlotsFile = antenna_proto::from_cbor(&b).map_err(|e| {
                Error::new(code::SLOT_INVALID, format!("keyslots.cbor is corrupt: {e}"))
            })?;
            if f.v != 0 {
                return Err(Error::new(
                    code::SLOT_INVALID,
                    "unsupported keyslots.cbor format",
                ));
            }
            Ok(f)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(SlotsFile::default()),
        Err(e) => Err(e.into()),
    }
}

/// Atomically: a temporary 0600 file next to it, fsync, rename (as `keystore::create`).
fn store(data_dir: &Path, f: &SlotsFile) -> Result<()> {
    let target = path(data_dir);
    if f.slots.is_empty() {
        return match fs::remove_file(&target) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        };
    }
    let bytes = antenna_proto::to_cbor(f)?;
    let tmp = data_dir.join(format!("{FILE_NAME}.tmp"));
    let _ = fs::remove_file(&tmp);
    {
        let mut w = OpenOptions::new()
            .write(true)
            .create_new(true)
            .owner_only()
            .open(&tmp)?;
        w.write_all(&bytes)?;
        w.sync_all()?;
    }
    fs::rename(&tmp, &target)?;
    Ok(())
}

/// Adds (or replaces) the slot of `key_id`: a new random slot key wraps `root`. Returns the slot key, which the caller
/// hands to the window once and never keeps.
pub fn add(data_dir: &Path, key_id: &str, root: &RootKey, keystore: &[u8]) -> Result<Secret32> {
    let mut f = load(data_dir)?;
    f.slots.retain(|s| s.key_id != key_id);
    if f.slots.len() >= SLOTS_MAX {
        return Err(Error::bad_request("too many unlock slots"));
    }
    let slot_key = crypto::random_secret();
    let mut slot = Slot {
        key_id: key_id.to_string(),
        kdf: KDF_NAME.into(),
        salt: crypto::random::<32>(),
        aead: AEAD_NAME.into(),
        nonce: crypto::random::<12>(),
        ct: Vec::new(),
    };
    let k = kek(&slot.salt, &slot_key);
    let cipher = ChaCha20Poly1305::new_from_slice(k.as_slice()).expect("32-byte key");
    let aad = slot.aad(keystore);
    slot.ct = cipher
        .encrypt(
            &Nonce::from(slot.nonce),
            Payload {
                msg: &root.0,
                aad: &aad,
            },
        )
        .map_err(|_| Error::internal("unlock slot encryption failed"))?;
    f.slots.push(slot);
    store(data_dir, &f)?;
    Ok(slot_key)
}

/// Removes the slot of `key_id`; `false` if there was none.
pub fn remove(data_dir: &Path, key_id: &str) -> Result<bool> {
    let mut f = load(data_dir)?;
    let before = f.slots.len();
    f.slots.retain(|s| s.key_id != key_id);
    if f.slots.len() == before {
        return Ok(false);
    }
    store(data_dir, &f)?;
    Ok(true)
}

/// The key IDs that have a slot.
pub fn key_ids(data_dir: &Path) -> Result<Vec<String>> {
    Ok(load(data_dir)?
        .slots
        .into_iter()
        .map(|s| s.key_id)
        .collect())
}

/// Opens the root key with the slot of `key_id` and its slot key. `keystore` is the keystore file the slot must belong
/// to (the bytes the daemon reads at unlock).
pub fn open(
    data_dir: &Path,
    key_id: &str,
    slot_key: &[u8; 32],
    keystore: &[u8],
) -> Result<RootKey> {
    let f = load(data_dir)?;
    let slot = f.slots.iter().find(|s| s.key_id == key_id).ok_or_else(|| {
        Error::new(
            code::OWNER_KEY_UNKNOWN,
            "no unlock slot for this key: use the password",
        )
    })?;
    if slot.kdf != KDF_NAME || slot.aead != AEAD_NAME {
        return Err(Error::new(code::SLOT_INVALID, "unsupported unlock slot"));
    }
    let k = kek(&slot.salt, slot_key);
    let cipher = ChaCha20Poly1305::new_from_slice(k.as_slice()).expect("32-byte key");
    let aad = slot.aad(keystore);
    let pt = Zeroizing::new(
        cipher
            .decrypt(
                &Nonce::from(slot.nonce),
                Payload {
                    msg: &slot.ct,
                    aad: &aad,
                },
            )
            .map_err(|_| {
                Error::new(
                    code::SLOT_INVALID,
                    "the unlock slot did not open: use the password",
                )
            })?,
    );
    let arr: [u8; 32] = pt
        .as_slice()
        .try_into()
        .map_err(|_| Error::new(code::SLOT_INVALID, "unlock slot payload has wrong length"))?;
    Ok(RootKey(arr))
}

mod serde_bytes_32 {
    pub fn serialize<S: serde::Serializer>(v: &[u8; 32], s: S) -> Result<S::Ok, S::Error> {
        serde_bytes::serialize(v.as_slice(), s)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(d: D) -> Result<[u8; 32], D::Error> {
        let v: serde_bytes::ByteBuf = serde::Deserialize::deserialize(d)?;
        v.into_vec()
            .try_into()
            .map_err(|_| serde::de::Error::custom("expected 32 bytes"))
    }
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::super::{KdfParams, create, read, unlock};
    use super::*;

    const PW: &[u8] = b"correct horse battery";

    fn node() -> (tempfile::TempDir, RootKey, Vec<u8>) {
        let dir = tempfile::tempdir().unwrap();
        let root = create(dir.path(), PW, KdfParams::TEST).unwrap();
        let ks = read(dir.path()).unwrap();
        (dir, root, ks)
    }

    #[test]
    fn a_slot_opens_the_same_root_key_and_leaves_the_password_slot_alone() {
        let (dir, root, ks) = node();
        let k = add(dir.path(), "aaaa", &root, &ks).unwrap();
        let opened = open(dir.path(), "aaaa", &k, &ks).unwrap();
        assert_eq!(opened.bytes(), root.bytes());
        // The password slot: the same bytes as before, and it still opens with the password.
        assert_eq!(read(dir.path()).unwrap(), ks);
        assert_eq!(unlock(dir.path(), PW).unwrap().bytes(), root.bytes());
        // Windows: the data folder's DACL, not a mode (WP-4).
        #[cfg(unix)]
        {
            let mode = fs::metadata(path(dir.path())).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        // The file holds no plain root key and no slot key.
        let bytes = fs::read(path(dir.path())).unwrap();
        assert!(!bytes.windows(32).any(|w| w == root.bytes()));
        assert!(!bytes.windows(32).any(|w| w == k.as_slice()));
    }

    /// Negative control (run once, 2026-10-06): with the AAD reduced to the label, the tampered header and the slot
    /// moved to another keystore both opened.
    #[test]
    fn a_wrong_key_a_removed_slot_a_tampered_header_or_another_keystore_do_not_open() {
        let (dir, root, ks) = node();
        let k = add(dir.path(), "aaaa", &root, &ks).unwrap();
        let k2 = add(dir.path(), "bbbb", &root, &ks).unwrap();
        // Another slot's key does not open this slot.
        assert_eq!(
            open(dir.path(), "aaaa", &k2, &ks).unwrap_err().code,
            code::SLOT_INVALID
        );
        assert_eq!(
            open(dir.path(), "aaaa", &[7; 32], &ks).unwrap_err().code,
            code::SLOT_INVALID
        );
        // A tampered header (the salt) does not open even with the right key.
        let mut f = load(dir.path()).unwrap();
        f.slots[0].salt[0] ^= 1;
        store(dir.path(), &f).unwrap();
        assert_eq!(
            open(dir.path(), "aaaa", &k, &ks).unwrap_err().code,
            code::SLOT_INVALID
        );
        f.slots[0].salt[0] ^= 1;
        // A key ID moved to another slot does not open either.
        f.slots[0].key_id = "cccc".into();
        store(dir.path(), &f).unwrap();
        assert_eq!(
            open(dir.path(), "cccc", &k, &ks).unwrap_err().code,
            code::SLOT_INVALID
        );
        f.slots[0].key_id = "aaaa".into();
        store(dir.path(), &f).unwrap();
        assert!(open(dir.path(), "aaaa", &k, &ks).is_ok());
        // Another keystore (a new `init` in the same folder): the slot does not open it.
        let mut other = ks.clone();
        let last = other.len() - 1;
        other[last] ^= 1;
        assert_eq!(
            open(dir.path(), "aaaa", &k, &other).unwrap_err().code,
            code::SLOT_INVALID
        );
        // Removed: no slot.
        assert!(remove(dir.path(), "aaaa").unwrap());
        assert!(!remove(dir.path(), "aaaa").unwrap());
        assert_eq!(
            open(dir.path(), "aaaa", &k, &ks).unwrap_err().code,
            code::OWNER_KEY_UNKNOWN
        );
        assert!(open(dir.path(), "bbbb", &k2, &ks).is_ok());
        assert_eq!(key_ids(dir.path()).unwrap(), vec!["bbbb".to_string()]);
        // The last slot removed: no file at all.
        assert!(remove(dir.path(), "bbbb").unwrap());
        assert!(!path(dir.path()).exists());
    }

    #[test]
    fn the_v0_keystore_still_opens_and_a_node_without_slots_has_none() {
        let (dir, root, ks) = node();
        assert!(key_ids(dir.path()).unwrap().is_empty());
        assert_eq!(
            open(dir.path(), "aaaa", &[0; 32], &ks).unwrap_err().code,
            code::OWNER_KEY_UNKNOWN
        );
        // keystore.cbor is still the v0 format a daemon before v7 parses (deny_unknown_fields, v = 0).
        add(dir.path(), "aaaa", &root, &ks).unwrap();
        let f: super::super::KeystoreFile =
            antenna_proto::from_cbor(&read(dir.path()).unwrap()).unwrap();
        assert_eq!(f.v, 0);
        assert_eq!(unlock(dir.path(), PW).unwrap().bytes(), root.bytes());
    }

    /// The write is atomic: a temporary file left by a crash is ignored and replaced, and a failed write leaves the
    /// previous file as it was.
    #[test]
    fn writing_the_slots_is_atomic() {
        let (dir, root, ks) = node();
        let k = add(dir.path(), "aaaa", &root, &ks).unwrap();
        let before = fs::read(path(dir.path())).unwrap();
        // A crash between writing the temporary file and the rename: half a file next to the real one.
        let tmp = dir.path().join(format!("{FILE_NAME}.tmp"));
        fs::write(&tmp, b"\xa2half").unwrap();
        assert!(
            open(dir.path(), "aaaa", &k, &ks).is_ok(),
            "the leftover is not read"
        );
        let k2 = add(dir.path(), "bbbb", &root, &ks).unwrap();
        assert!(!tmp.exists(), "replaced and renamed");
        assert!(open(dir.path(), "aaaa", &k, &ks).is_ok());
        assert!(open(dir.path(), "bbbb", &k2, &ks).is_ok());
        // A write that cannot happen (the folder is read-only) leaves the file as it was. (A folder's mode is unix; on
        // Windows a read-only folder is a DACL, WP-4.)
        let after_two = fs::read(path(dir.path())).unwrap();
        assert_ne!(after_two, before);
        #[cfg(unix)]
        {
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o500)).unwrap();
            let r = add(dir.path(), "cccc", &root, &ks);
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
            if r.is_err() {
                assert_eq!(fs::read(path(dir.path())).unwrap(), after_two);
            } else {
                // Running as root ignores the folder's mode; the write then simply succeeded.
                assert!(key_ids(dir.path()).unwrap().contains(&"cccc".to_string()));
            }
        }
        // A corrupt file is an error with a code, not a panic, and is never taken for "no slots".
        fs::write(path(dir.path()), b"\xff\x00garbage").unwrap();
        assert_eq!(
            open(dir.path(), "aaaa", &k, &ks).unwrap_err().code,
            code::SLOT_INVALID
        );
        assert_eq!(
            add(dir.path(), "dddd", &root, &ks).unwrap_err().code,
            code::SLOT_INVALID
        );
    }
}
