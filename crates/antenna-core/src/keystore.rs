// SPDX-License-Identifier: AGPL-3.0-only
//! Storage for the device root key (SPEC §5, §13; Q-4).
//!
//! At this stage there is one backend: the root key (32 random bytes) is wrapped with the owner password:
//! `KEK = Argon2id(password, salt, m = 64 MiB, t = 3, p = 1)`,
//! `file = ChaCha20-Poly1305(KEK, nonce, root, AAD = header)`. HKDF-SHA256 derives the SQLCipher key from the root key
//! (D-10). Hardware backends (TPM, Secure Enclave, Keychain), `systemd-creds` and a key file come later and only with
//! an explicit flag (Q-4); the CLI has the flag, but it honestly answers "not implemented". Since v7 (D-102) the root
//! key can also be opened from an owner key's unlock slot ([`slots`], its own file: this one is never rewritten).
//!
//! All secrets are kept in [`Zeroizing`] and wiped on drop. The password is not stored anywhere.

use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

use antenna_proto::control::code;
use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    ChaCha20Poly1305, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::{
    crypto::{self, Secret32},
    error::{Error, Result},
    owner_only::OwnerOnly,
};

pub mod slots;

/// Keystore file name in the data directory.
pub const FILE_NAME: &str = "keystore.cbor";
/// Minimum password length, bytes.
pub const MIN_PASSWORD_LEN: usize = 8;

const KDF_NAME: &str = "argon2id-v19";
const AEAD_NAME: &str = "chacha20poly1305";
const AAD_LABEL: &[u8] = b"x/keystore/v0";
const DB_KEY_SALT: &[u8] = b"x/device/v0";
const DB_KEY_INFO: &[u8] = b"x/device/v0/sqlcipher-key";
const PW_CHECK_INFO: &[u8] = b"x/device/v0/password-check";
const STATE_MAC_INFO: &[u8] = b"x/device/v0/state-counter-mac";
/// HKDF info for the file quarantine key (slice 4).
const FILES_KEY_INFO: &[u8] = b"x/device/v0/files-key";

/// Argon2id parameters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct KdfParams {
    /// Memory, KiB.
    pub m_kib: u32,
    /// Number of passes.
    pub t: u32,
    /// Parallelism.
    pub p: u32,
}

impl KdfParams {
    /// Default parameters: 64 MiB, 3 passes, 1 lane (RFC 9106 §4, the second recommended option, with p = 1).
    pub const DEFAULT: KdfParams = KdfParams {
        m_kib: 64 * 1024,
        t: 3,
        p: 1,
    };

    /// Weak parameters, for unit tests only.
    #[cfg(test)]
    pub const TEST: KdfParams = KdfParams {
        m_kib: 1024,
        t: 1,
        p: 1,
    };

    fn sane(&self) -> bool {
        // The lower bound prevents slipping in a file with weakened parameters (KdfParams::TEST passes only in tests)
        let min_m = if cfg!(test) { 1024 } else { 19 * 1024 };
        (min_m..=4 * 1024 * 1024).contains(&self.m_kib)
            && (1..=16).contains(&self.t)
            && (1..=8).contains(&self.p)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct KeystoreFile {
    v: u16,
    kdf: String,
    params: KdfParams,
    #[serde(with = "serde_bytes_16")]
    salt: [u8; 16],
    aead: String,
    #[serde(with = "serde_bytes_12")]
    nonce: [u8; 12],
    #[serde(with = "serde_bytes_vec")]
    ct: Vec<u8>,
}

impl KeystoreFile {
    /// AAD = label ‖ all header fields: substituting the parameters or the salt breaks decryption.
    fn aad(&self) -> Vec<u8> {
        let mut a = Vec::new();
        a.extend_from_slice(AAD_LABEL);
        a.extend_from_slice(&self.v.to_be_bytes());
        a.extend_from_slice(&crypto::lp(self.kdf.as_bytes()));
        a.extend_from_slice(&self.params.m_kib.to_be_bytes());
        a.extend_from_slice(&self.params.t.to_be_bytes());
        a.extend_from_slice(&self.params.p.to_be_bytes());
        a.extend_from_slice(&self.salt);
        a.extend_from_slice(&crypto::lp(self.aead.as_bytes()));
        a.extend_from_slice(&self.nonce);
        a
    }
}

/// Device root key. Never leaves the daemon process and is never shown to contacts (SPEC §5).
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct RootKey([u8; 32]);

impl std::fmt::Debug for RootKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RootKey(<redacted>)")
    }
}

impl RootKey {
    /// SQLCipher key (raw 32 bytes, D-10).
    pub fn db_key(&self) -> Secret32 {
        crypto::hkdf32(DB_KEY_SALT, &self.0, &[DB_KEY_INFO])
    }

    /// Root key fingerprint for re-checking the owner password: the daemon checks the password against the keystore
    /// **remembered at unlock** and compares the fingerprint, so replacing the file on disk gains nothing.
    pub fn fingerprint(&self) -> Secret32 {
        crypto::hkdf32(DB_KEY_SALT, &self.0, &[PW_CHECK_INFO])
    }

    /// HMAC key for the link state counter file (rollback protection, SPEC §8; `statefile`).
    pub fn state_key(&self) -> Secret32 {
        crypto::hkdf32(DB_KEY_SALT, &self.0, &[STATE_MAC_INFO])
    }

    /// File quarantine key (slice 4, D-F-5): quarantine records (manifest, file secret, report, preview) are encrypted
    /// with keys derived from it.
    pub fn files_key(&self) -> Secret32 {
        crypto::hkdf32(DB_KEY_SALT, &self.0, &[FILES_KEY_INFO])
    }

    #[cfg(test)]
    fn bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

/// The root key across an automatic update's restart (D-103, R2): it leaves the old daemon image only through the
/// inherited pipe and enters the new one from it; it is never written anywhere else.
impl RootKey {
    /// A copy for the handover (wiped on drop).
    pub fn handover_bytes(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.0)
    }

    /// The key read from the handover pipe. Whether it is the right key shows when the database opens with it.
    pub fn from_handover(bytes: &Zeroizing<[u8; 32]>) -> Self {
        RootKey(**bytes)
    }
}

/// Path to the keystore file.
pub fn path(data_dir: &Path) -> PathBuf {
    data_dir.join(FILE_NAME)
}

/// Whether the keystore exists.
pub fn exists(data_dir: &Path) -> bool {
    path(data_dir).exists()
}

fn kek(password: &[u8], salt: &[u8; 16], params: KdfParams) -> Result<Secret32> {
    let p = Params::new(params.m_kib, params.t, params.p, Some(32))
        .map_err(|e| Error::internal(format!("argon2 params: {e}")))?;
    let mut out = Zeroizing::new([0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, p)
        .hash_password_into(password, salt, out.as_mut())
        .map_err(|e| Error::internal(format!("argon2: {e}")))?;
    Ok(out)
}

/// Creates a new root key and stores it wrapped with the password. Error if a keystore already exists.
pub fn create(data_dir: &Path, password: &[u8], params: KdfParams) -> Result<RootKey> {
    if password.len() < MIN_PASSWORD_LEN {
        return Err(Error::bad_request(format!(
            "password must be at least {MIN_PASSWORD_LEN} bytes"
        )));
    }
    if !params.sane() {
        return Err(Error::bad_request("unsupported Argon2id parameters"));
    }
    let file_path = path(data_dir);
    if file_path.exists() {
        return Err(Error::new(
            code::ALREADY_INITIALIZED,
            "keystore already exists",
        ));
    }
    let root = RootKey(*crypto::random_secret());
    let mut file = KeystoreFile {
        v: 0,
        kdf: KDF_NAME.into(),
        params,
        salt: crypto::random::<16>(),
        aead: AEAD_NAME.into(),
        nonce: crypto::random::<12>(),
        ct: Vec::new(),
    };
    let key = kek(password, &file.salt, params)?;
    let cipher = ChaCha20Poly1305::new_from_slice(key.as_slice()).expect("32-byte key");
    let aad = file.aad();
    file.ct = cipher
        .encrypt(
            &Nonce::from(file.nonce),
            Payload {
                msg: &root.0,
                aad: &aad,
            },
        )
        .map_err(|_| Error::internal("keystore encryption failed"))?;
    let bytes = antenna_proto::to_cbor(&file)?;
    // Atomically: a temporary 0600 file next to it, fsync, rename
    let tmp = data_dir.join(format!("{FILE_NAME}.tmp"));
    let _ = fs::remove_file(&tmp);
    {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .owner_only()
            .open(&tmp)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, &file_path)?;
    Ok(root)
}

/// Keystore file bytes.
pub fn read(data_dir: &Path) -> Result<Vec<u8>> {
    match fs::read(path(data_dir)) {
        Ok(b) => Ok(b),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(Error::new(
            code::NOT_INITIALIZED,
            "run `antenna init` first",
        )),
        Err(e) => Err(e.into()),
    }
}

/// Unlocks the root key with the password.
pub fn unlock(data_dir: &Path, password: &[u8]) -> Result<RootKey> {
    unlock_bytes(&read(data_dir)?, password)
}

/// Unlocks the root key with the password from keystore bytes (including those the daemon remembered at unlock).
pub fn unlock_bytes(bytes: &[u8], password: &[u8]) -> Result<RootKey> {
    let file: KeystoreFile = antenna_proto::from_cbor(bytes)
        .map_err(|e| Error::internal(format!("keystore file is corrupt: {e}")))?;
    if file.v != 0 || file.kdf != KDF_NAME || file.aead != AEAD_NAME || !file.params.sane() {
        return Err(Error::internal("unsupported keystore format"));
    }
    let key = kek(password, &file.salt, file.params)?;
    let cipher = ChaCha20Poly1305::new_from_slice(key.as_slice()).expect("32-byte key");
    let aad = file.aad();
    let pt = Zeroizing::new(
        cipher
            .decrypt(
                &Nonce::from(file.nonce),
                Payload {
                    msg: &file.ct,
                    aad: &aad,
                },
            )
            .map_err(|_| Error::new(code::WRONG_PASSWORD, "wrong password"))?,
    );
    let arr: [u8; 32] = pt
        .as_slice()
        .try_into()
        .map_err(|_| Error::internal("keystore payload has wrong length"))?;
    Ok(RootKey(arr))
}

mod serde_bytes_16 {
    pub fn serialize<S: serde::Serializer>(v: &[u8; 16], s: S) -> Result<S::Ok, S::Error> {
        serde_bytes::serialize(v.as_slice(), s)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(d: D) -> Result<[u8; 16], D::Error> {
        let v: serde_bytes::ByteBuf = serde::Deserialize::deserialize(d)?;
        v.into_vec()
            .try_into()
            .map_err(|_| serde::de::Error::custom("expected 16 bytes"))
    }
}

mod serde_bytes_12 {
    pub fn serialize<S: serde::Serializer>(v: &[u8; 12], s: S) -> Result<S::Ok, S::Error> {
        serde_bytes::serialize(v.as_slice(), s)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(d: D) -> Result<[u8; 12], D::Error> {
        let v: serde_bytes::ByteBuf = serde::Deserialize::deserialize(d)?;
        v.into_vec()
            .try_into()
            .map_err(|_| serde::de::Error::custom("expected 12 bytes"))
    }
}

mod serde_bytes_vec {
    pub fn serialize<S: serde::Serializer>(v: &[u8], s: S) -> Result<S::Ok, S::Error> {
        serde_bytes::serialize(v, s)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let v: serde_bytes::ByteBuf = serde::Deserialize::deserialize(d)?;
        Ok(v.into_vec())
    }
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    const PW: &[u8] = b"correct horse battery";

    #[test]
    fn create_then_unlock_returns_same_key_and_db_key() {
        let dir = tempfile::tempdir().unwrap();
        let k1 = create(dir.path(), PW, KdfParams::TEST).unwrap();
        let k2 = unlock(dir.path(), PW).unwrap();
        assert_eq!(k1.bytes(), k2.bytes());
        assert_eq!(k1.db_key().as_slice(), k2.db_key().as_slice());
        assert_ne!(k1.db_key().as_slice(), k1.bytes().as_slice());
        // Windows: the data folder's DACL, not a mode (WP-4).
        #[cfg(unix)]
        {
            let mode = fs::metadata(path(dir.path())).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn wrong_password_is_rejected_with_code() {
        let dir = tempfile::tempdir().unwrap();
        create(dir.path(), PW, KdfParams::TEST).unwrap();
        let e = unlock(dir.path(), b"wrong password!!").unwrap_err();
        assert_eq!(e.code, code::WRONG_PASSWORD);
    }

    #[test]
    fn short_password_and_double_init_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            create(dir.path(), b"short", KdfParams::TEST)
                .unwrap_err()
                .code,
            code::BAD_REQUEST
        );
        create(dir.path(), PW, KdfParams::TEST).unwrap();
        assert_eq!(
            create(dir.path(), PW, KdfParams::TEST).unwrap_err().code,
            code::ALREADY_INITIALIZED
        );
    }

    #[test]
    fn missing_keystore_is_not_initialized() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            unlock(dir.path(), PW).unwrap_err().code,
            code::NOT_INITIALIZED
        );
    }

    #[test]
    fn tampered_header_breaks_unlock() {
        // AAD covers the header: substituting parameters/salt/nonce fails even with the correct password
        let dir = tempfile::tempdir().unwrap();
        create(dir.path(), PW, KdfParams::TEST).unwrap();
        let bytes = fs::read(path(dir.path())).unwrap();
        let mut f: KeystoreFile = antenna_proto::from_cbor(&bytes).unwrap();
        f.params.t = 2;
        fs::write(path(dir.path()), antenna_proto::to_cbor(&f).unwrap()).unwrap();
        assert_eq!(
            unlock(dir.path(), PW).unwrap_err().code,
            code::WRONG_PASSWORD
        );
    }

    #[test]
    fn root_key_is_zeroized() {
        // ZeroizeOnDrop is checked at the type level; an explicit zeroize is checked by value.
        fn assert_zod<T: ZeroizeOnDrop>() {}
        assert_zod::<RootKey>();
        let mut k = RootKey([0xaa; 32]);
        k.zeroize();
        assert_eq!(k.bytes(), &[0u8; 32]);
        assert!(!format!("{k:?}").contains("aa"));
    }

    #[test]
    fn file_contains_no_plain_key() {
        let dir = tempfile::tempdir().unwrap();
        let k = create(dir.path(), PW, KdfParams::TEST).unwrap();
        let bytes = fs::read(path(dir.path())).unwrap();
        assert!(!bytes.windows(32).any(|w| w == k.bytes()));
    }

    #[test]
    fn default_params_are_sane_and_test_params_are_not_in_release() {
        assert!(KdfParams::DEFAULT.sane());
        assert!(KdfParams::TEST.sane()); // Only under cfg(test)
    }
}
