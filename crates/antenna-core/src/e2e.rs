// SPDX-License-Identifier: AGPL-3.0-only
//! E2E (SPEC §7): libsignal Triple Ratchet (PQXDH + Double Ratchet + SPQR), `docs/PROTOCOL.md` §10, D-8.
//!
//! - During pairing the libsignal state lives in memory ([`PairingE2e`] on top of `InMemSignalProtocolStore`):
//!   nothing reaches the disk on failure. After activation it is moved into SQLCipher.
//! - After pairing the libsignal stores are implemented on top of the DB ([`DbIdentity`], [`DbSession`]). The contact's
//!   identity is pinned from the transcript: no TOFU, a foreign key gives `UntrustedIdentity`. Prekeys are not needed
//!   after pairing (both sides' sessions are confirmed before activation), so the prekey stores are empty
//!   ([`NoPreKeys`]).
//! - No custom cryptography: only the standard `process_prekey_bundle` / `message_encrypt` / `message_decrypt`.

use std::time::SystemTime;

use antenna_proto::{LinkId, link::e2e_type, pairing::Bundle};
use async_trait::async_trait;
use futures::executor::block_on;
use libsignal_protocol::{
    CiphertextMessage, CiphertextMessageType, DeviceId, Direction, GenericSignedPreKey,
    IdentityChange, IdentityKey, IdentityKeyPair, IdentityKeyStore, InMemKyberPreKeyStore,
    InMemPreKeyStore, InMemSignalProtocolStore, InMemSignedPreKeyStore, KeyPair, KyberPreKeyId,
    KyberPreKeyRecord, KyberPreKeyStore, PreKeyBundle, PreKeyId, PreKeyRecord, PreKeySignalMessage,
    PreKeyStore, ProtocolAddress, PublicKey, SessionRecord, SessionStore, SignalMessage,
    SignalProtocolError, SignedPreKeyId, SignedPreKeyRecord, SignedPreKeyStore, Timestamp, kem,
    message_decrypt, message_encrypt, process_prekey_bundle,
};
use rusqlite::{Connection, OptionalExtension, params};
use zeroize::Zeroizing;

use crate::{
    crypto,
    error::{Error, Result},
};

type SResult<T> = std::result::Result<T, SignalProtocolError>;

/// KEM prekey type: ML-KEM-1024 (FIPS 203), not Kyber1024 (D-8).
pub const KEM_TYPE: kem::KeyType = kem::KeyType::MLKEM1024;

/// libsignal address (device id 1).
pub fn address(name: &str) -> ProtocolAddress {
    ProtocolAddress::new(
        name.to_string(),
        DeviceId::new(1).expect("1 is a valid device id"),
    )
}

/// libsignal address names of a link: `hex(link_id).a` (A) and `hex(link_id).b` (B), `docs/PROTOCOL.md` §10.
pub fn address_names(link: &LinkId) -> (String, String) {
    let h = link.to_hex();
    (format!("{h}.a"), format!("{h}.b"))
}

/// New libsignal identity for a link, and a registration id.
pub fn new_identity() -> (IdentityKeyPair, u32) {
    let mut rng = crypto::rng();
    let kp = IdentityKeyPair::generate(&mut rng);
    let reg = 1 + (u32::from_be_bytes(crypto::random::<4>()) % 16380);
    (kp, reg)
}

/// libsignal ciphertext with its type.
#[derive(Debug, Clone)]
pub struct Encrypted {
    /// [`e2e_type::WHISPER`] or [`e2e_type::PREKEY`].
    pub kind: u8,
    /// libsignal message bytes.
    pub bytes: Vec<u8>,
}

fn encrypted(c: CiphertextMessage) -> Result<Encrypted> {
    let kind = match c.message_type() {
        CiphertextMessageType::Whisper => e2e_type::WHISPER,
        CiphertextMessageType::PreKey => e2e_type::PREKEY,
        other => {
            return Err(Error::internal(format!(
                "unexpected ciphertext type {other:?}"
            )));
        }
    };
    Ok(Encrypted {
        kind,
        bytes: c.serialize().to_vec(),
    })
}

/// Parses an `e2e-frame`: message version and SPQR part length (facts for `antenna contacts`).
fn parse_ct(kind: u8, bytes: &[u8]) -> Result<(CiphertextMessage, u32, u32)> {
    let bad = |e: SignalProtocolError| Error::bad_request(format!("bad libsignal message: {e}"));
    Ok(match kind {
        e2e_type::WHISPER => {
            let m = SignalMessage::try_from(bytes).map_err(bad)?;
            let (v, pq) = (m.message_version() as u32, m.pq_ratchet().len() as u32);
            (CiphertextMessage::SignalMessage(m), v, pq)
        }
        e2e_type::PREKEY => {
            let m = PreKeySignalMessage::try_from(bytes).map_err(bad)?;
            let (v, pq) = (
                m.message_version() as u32,
                m.message().pq_ratchet().len() as u32,
            );
            (CiphertextMessage::PreKeySignalMessage(m), v, pq)
        }
        _ => return Err(Error::bad_request("unknown e2e message type")),
    })
}

// libsignal stores on top of SQLCipher

#[derive(Debug)]
struct StoreErr(String);

impl std::fmt::Display for StoreErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for StoreErr {}

fn db_err(e: rusqlite::Error) -> SignalProtocolError {
    SignalProtocolError::ApplicationCallbackError("x-store", Box::new(StoreErr(e.to_string())))
}

/// Identity store of a link: our own key pair and the contact's **pinned** key.
pub struct DbIdentity<'a> {
    conn: &'a Connection,
    link: LinkId,
}

impl<'a> DbIdentity<'a> {
    /// For a link.
    pub fn new(conn: &'a Connection, link: LinkId) -> Self {
        Self { conn, link }
    }

    fn pinned(&self, address: &ProtocolAddress) -> SResult<Option<IdentityKey>> {
        let v: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT identity FROM sig_remote_identity WHERE link_id = ?1 AND address = ?2",
                params![&self.link.0[..], address.name()],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_err)?;
        v.map(|b| IdentityKey::decode(&b)).transpose()
    }
}

#[async_trait(?Send)]
impl IdentityKeyStore for DbIdentity<'_> {
    async fn get_identity_key_pair(&self) -> SResult<IdentityKeyPair> {
        let b: Zeroizing<Vec<u8>> = Zeroizing::new(
            self.conn
                .query_row(
                    "SELECT keypair FROM sig_identity WHERE link_id = ?1",
                    params![&self.link.0[..]],
                    |r| r.get(0),
                )
                .map_err(db_err)?,
        );
        IdentityKeyPair::try_from(&b[..])
    }

    async fn get_local_registration_id(&self) -> SResult<u32> {
        self.conn
            .query_row(
                "SELECT registration_id FROM sig_identity WHERE link_id = ?1",
                params![&self.link.0[..]],
                |r| r.get(0),
            )
            .map_err(db_err)
    }

    async fn save_identity(
        &mut self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
    ) -> SResult<IdentityChange> {
        // Contact keys are pinned only during pairing; they cannot be replaced over the network.
        match self.pinned(address)? {
            Some(k) if &k == identity => Ok(IdentityChange::NewOrUnchanged),
            _ => Err(SignalProtocolError::UntrustedIdentity(address.clone())),
        }
    }

    async fn is_trusted_identity(
        &self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
        _direction: Direction,
    ) -> SResult<bool> {
        Ok(matches!(self.pinned(address)?, Some(k) if &k == identity))
    }

    async fn get_identity(&self, address: &ProtocolAddress) -> SResult<Option<IdentityKey>> {
        self.pinned(address)
    }
}

/// Session store of a link.
pub struct DbSession<'a> {
    conn: &'a Connection,
    link: LinkId,
}

impl<'a> DbSession<'a> {
    /// For a link.
    pub fn new(conn: &'a Connection, link: LinkId) -> Self {
        Self { conn, link }
    }
}

#[async_trait(?Send)]
impl SessionStore for DbSession<'_> {
    async fn load_session(&self, address: &ProtocolAddress) -> SResult<Option<SessionRecord>> {
        let v: Option<Zeroizing<Vec<u8>>> = self
            .conn
            .query_row(
                "SELECT record FROM sig_session WHERE link_id = ?1 AND address = ?2",
                params![&self.link.0[..], address.name()],
                |r| r.get::<_, Vec<u8>>(0),
            )
            .optional()
            .map_err(db_err)?
            .map(Zeroizing::new);
        v.map(|b| SessionRecord::deserialize(&b)).transpose()
    }

    async fn store_session(
        &mut self,
        address: &ProtocolAddress,
        record: &SessionRecord,
    ) -> SResult<()> {
        let bytes = Zeroizing::new(record.serialize()?);
        self.conn
            .execute(
                "INSERT INTO sig_session(link_id, address, record) VALUES (?1, ?2, ?3)
                 ON CONFLICT(link_id, address) DO UPDATE SET record = excluded.record",
                params![&self.link.0[..], address.name(), bytes.as_slice()],
            )
            .map_err(db_err)?;
        Ok(())
    }
}

/// Empty prekey stores: no PreKey messages are expected after pairing.
pub struct NoPreKeys;

#[async_trait(?Send)]
impl PreKeyStore for NoPreKeys {
    async fn get_pre_key(&self, _: PreKeyId) -> SResult<PreKeyRecord> {
        Err(SignalProtocolError::InvalidPreKeyId)
    }
    async fn save_pre_key(&mut self, _: PreKeyId, _: &PreKeyRecord) -> SResult<()> {
        Err(SignalProtocolError::InvalidPreKeyId)
    }
    async fn remove_pre_key(&mut self, _: PreKeyId) -> SResult<()> {
        Ok(())
    }
}

#[async_trait(?Send)]
impl SignedPreKeyStore for NoPreKeys {
    async fn get_signed_pre_key(&self, _: SignedPreKeyId) -> SResult<SignedPreKeyRecord> {
        Err(SignalProtocolError::InvalidSignedPreKeyId)
    }
    async fn save_signed_pre_key(
        &mut self,
        _: SignedPreKeyId,
        _: &SignedPreKeyRecord,
    ) -> SResult<()> {
        Err(SignalProtocolError::InvalidSignedPreKeyId)
    }
}

#[async_trait(?Send)]
impl KyberPreKeyStore for NoPreKeys {
    async fn get_kyber_pre_key(&self, _: KyberPreKeyId) -> SResult<KyberPreKeyRecord> {
        Err(SignalProtocolError::InvalidKyberPreKeyId)
    }
    async fn save_kyber_pre_key(&mut self, _: KyberPreKeyId, _: &KyberPreKeyRecord) -> SResult<()> {
        Err(SignalProtocolError::InvalidKyberPreKeyId)
    }
    async fn mark_kyber_pre_key_used(
        &mut self,
        _: KyberPreKeyId,
        _: SignedPreKeyId,
        _: &PublicKey,
    ) -> SResult<()> {
        Err(SignalProtocolError::InvalidKyberPreKeyId)
    }
}

/// Encrypts plaintext for the link's contact (inside the caller's transaction: the ratchet state and the message
/// record are committed together).
pub fn encrypt(
    conn: &Connection,
    link: &LinkId,
    local: &str,
    remote: &str,
    plaintext: &[u8],
) -> Result<Encrypted> {
    let (la, ra) = (address(local), address(remote));
    let mut sessions = DbSession::new(conn, *link);
    let mut identity = DbIdentity::new(conn, *link);
    let mut rng = crypto::rng();
    let c = block_on(message_encrypt(
        plaintext,
        &ra,
        &la,
        &mut sessions,
        &mut identity,
        SystemTime::now(),
        &mut rng,
    ))?;
    encrypted(c)
}

/// Decryption result.
pub enum Decrypted {
    /// New message.
    Message {
        /// Plaintext.
        plaintext: Zeroizing<Vec<u8>>,
        /// libsignal message version (4 = PQXDH + SPQR).
        version: u32,
        /// SPQR part length.
        pq_len: u32,
    },
    /// A repeat of an already accepted message (libsignal: "old counter").
    Duplicate,
}

/// Decrypts a contact's message (inside the caller's transaction).
pub fn decrypt(
    conn: &Connection,
    link: &LinkId,
    local: &str,
    remote: &str,
    kind: u8,
    bytes: &[u8],
) -> Result<Decrypted> {
    let (msg, version, pq_len) = parse_ct(kind, bytes)?;
    let (la, ra) = (address(local), address(remote));
    let mut sessions = DbSession::new(conn, *link);
    let mut identity = DbIdentity::new(conn, *link);
    let (mut pre, signed, mut kyber) = (NoPreKeys, NoPreKeys, NoPreKeys);
    let mut rng = crypto::rng();
    match block_on(message_decrypt(
        &msg,
        &ra,
        &la,
        &mut sessions,
        &mut identity,
        &mut pre,
        &signed,
        &mut kyber,
        &mut rng,
    )) {
        Ok(pt) => Ok(Decrypted::Message {
            plaintext: Zeroizing::new(pt),
            version,
            pq_len,
        }),
        Err(SignalProtocolError::DuplicatedMessage(_, _)) => Ok(Decrypted::Duplicate),
        Err(e) => Err(Error::bad_request(format!("decrypt: {e}"))),
    }
}

// Rekey after a state rollback (SPEC §8, `docs/PROTOCOL.md` §17)

/// Plaintext label of the first message of a new session during a rekey.
pub const L_REKEY: &[u8] = b"x/link/v1/rekey-init";
/// Plaintext label of the new session confirmation.
pub const L_REKEY_ACK: &[u8] = b"x/link/v1/rekey-ack";

/// Fresh prekeys of the side requesting a rekey (kept in memory until confirmation).
pub struct RekeyKeys {
    pre: PreKeyRecord,
    signed: SignedPreKeyRecord,
    kyber: KyberPreKeyRecord,
    ids: (u32, u32, u32),
}

/// Fresh bundle on the link's identity from the DB (the same identity the contact pinned during pairing).
pub fn rekey_bundle(conn: &Connection, link: &LinkId) -> Result<(Bundle, RekeyKeys)> {
    let identity = DbIdentity::new(conn, *link);
    let idk = block_on(identity.get_identity_key_pair())?;
    let reg = block_on(identity.get_local_registration_id())?;
    // Prekey IDs are random (they do not collide with the pairing bundle or earlier rekeys)
    let rid = || 2 + (u32::from_be_bytes(crypto::random::<4>()) % 0x00FF_FFF0);
    let ids = (rid(), rid(), rid());
    let (bundle, pre, signed, kyber) = make_bundle_records(&idk, reg, ids)?;
    Ok((
        bundle,
        RekeyKeys {
            pre,
            signed,
            kyber,
            ids,
        },
    ))
}

fn make_bundle_records(
    idk: &IdentityKeyPair,
    reg: u32,
    (pre_id, spk_id, kyber_id): (u32, u32, u32),
) -> Result<(Bundle, PreKeyRecord, SignedPreKeyRecord, KyberPreKeyRecord)> {
    let mut rng = crypto::rng();
    let pre = KeyPair::generate(&mut rng);
    let spk = KeyPair::generate(&mut rng);
    let kyber = kem::KeyPair::generate(KEM_TYPE, &mut rng);
    let spk_sig = idk
        .private_key()
        .calculate_signature(&spk.public_key.serialize(), &mut rng)
        .map_err(lib)?;
    let kyber_sig = idk
        .private_key()
        .calculate_signature(&kyber.public_key.serialize(), &mut rng)
        .map_err(lib)?;
    let bundle = Bundle {
        registration_id: reg,
        identity_key: idk.identity_key().serialize().to_vec(),
        prekey_id: pre_id,
        prekey: pre.public_key.serialize().to_vec(),
        signed_prekey_id: spk_id,
        signed_prekey: spk.public_key.serialize().to_vec(),
        signed_prekey_sig: spk_sig.to_vec(),
        kyber_prekey_id: kyber_id,
        kyber_prekey: kyber.public_key.serialize().to_vec(),
        kyber_prekey_sig: kyber_sig.to_vec(),
    };
    let now = Timestamp::from_epoch_millis(now_ms());
    Ok((
        bundle,
        PreKeyRecord::new(pre_id.into(), &pre),
        SignedPreKeyRecord::new(spk_id.into(), now, &spk, &spk_sig),
        KyberPreKeyRecord::new(kyber_id.into(), now, &kyber, &kyber_sig),
    ))
}

fn to_prekey_bundle(b: &Bundle) -> Result<PreKeyBundle> {
    Ok(PreKeyBundle::new(
        b.registration_id,
        DeviceId::new(1).expect("1 is a valid device id"),
        Some((
            b.prekey_id.into(),
            PublicKey::deserialize(&b.prekey).map_err(lib)?,
        )),
        b.signed_prekey_id.into(),
        PublicKey::deserialize(&b.signed_prekey).map_err(lib)?,
        b.signed_prekey_sig.clone(),
        b.kyber_prekey_id.into(),
        kem::PublicKey::deserialize(&b.kyber_prekey)?,
        b.kyber_prekey_sig.clone(),
        IdentityKey::decode(&b.identity_key)?,
    )?)
}

/// The side accepting a rekey: a new session from the contact's bundle (the bundle's identity must match the pinned
/// one, otherwise libsignal refuses), the first message `L_REKEY ‖ link_id ‖ H(bundle)` (PreKeySignalMessage). Inside
/// the caller's transaction.
pub fn rekey_accept(
    conn: &Connection,
    link: &LinkId,
    local: &str,
    remote: &str,
    bundle: &Bundle,
    bundle_hash: &[u8; 32],
) -> Result<Encrypted> {
    let pk = to_prekey_bundle(bundle)?;
    let (la, ra) = (address(local), address(remote));
    let mut sessions = DbSession::new(conn, *link);
    let mut identity = DbIdentity::new(conn, *link);
    let mut rng = crypto::rng();
    block_on(process_prekey_bundle(
        &ra,
        &la,
        &mut sessions,
        &mut identity,
        &pk,
        SystemTime::now(),
        &mut rng,
    ))?;
    let mut pt = Vec::new();
    pt.extend_from_slice(L_REKEY);
    pt.extend_from_slice(&link.0);
    pt.extend_from_slice(bundle_hash);
    encrypt(conn, link, local, remote, &pt)
}

/// The side that requested a rekey: accept the first message of the new session with its fresh prekeys. Returns the
/// plaintext (the caller checks it). Inside the caller's transaction.
pub fn rekey_receive(
    conn: &Connection,
    link: &LinkId,
    local: &str,
    remote: &str,
    kind: u8,
    bytes: &[u8],
    keys: &RekeyKeys,
) -> Result<Zeroizing<Vec<u8>>> {
    if kind != e2e_type::PREKEY {
        return Err(Error::bad_request("rekey: expected a PreKeySignalMessage"));
    }
    let (msg, _, _) = parse_ct(kind, bytes)?;
    let (la, ra) = (address(local), address(remote));
    let mut sessions = DbSession::new(conn, *link);
    let mut identity = DbIdentity::new(conn, *link);
    let mut pre = InMemPreKeyStore::new();
    let mut signed = InMemSignedPreKeyStore::new();
    let mut kyber = InMemKyberPreKeyStore::new();
    block_on(pre.save_pre_key(keys.ids.0.into(), &keys.pre))?;
    block_on(signed.save_signed_pre_key(keys.ids.1.into(), &keys.signed))?;
    block_on(kyber.save_kyber_pre_key(keys.ids.2.into(), &keys.kyber))?;
    let mut rng = crypto::rng();
    let pt = block_on(message_decrypt(
        &msg,
        &ra,
        &la,
        &mut sessions,
        &mut identity,
        &mut pre,
        &signed,
        &mut kyber,
        &mut rng,
    ))
    .map_err(|e| Error::bad_request(format!("rekey decrypt: {e}")))?;
    Ok(Zeroizing::new(pt))
}

/// Session facts: version and SPQR state (from the stored `SessionRecord`).
pub fn session_info(
    conn: &Connection,
    link: &LinkId,
    remote: &str,
) -> Result<(Option<u32>, Option<String>)> {
    let sessions = DbSession::new(conn, *link);
    let Some(rec) = block_on(sessions.load_session(&address(remote)))? else {
        return Ok((None, None));
    };
    let version = rec.session_version().ok();
    let pq = rec
        .current_pq_state()
        .map(|s| match spqr::current_version(s) {
            Ok(v) => format!("{v:?}"),
            Err(e) => format!("error: {e}"),
        });
    Ok((version, pq))
}

// libsignal during pairing (in memory)

/// Export of the libsignal state after a successful pairing.
pub struct E2eExport {
    /// `IdentityKeyPair` (serialized).
    pub identity_keypair: Zeroizing<Vec<u8>>,
    /// Registration id.
    pub registration_id: u32,
    /// `SessionRecord` (serialized).
    pub session_record: Zeroizing<Vec<u8>>,
    /// The contact's pinned `IdentityKey`.
    pub remote_identity: Vec<u8>,
}

/// libsignal state during pairing.
pub struct PairingE2e {
    store: InMemSignalProtocolStore,
    local: ProtocolAddress,
    remote: ProtocolAddress,
}

impl PairingE2e {
    /// Store with this link's identity and the contact's pinned identity (from the transcript).
    pub fn new(
        identity: IdentityKeyPair,
        registration_id: u32,
        local: &str,
        remote: &str,
        remote_identity: &[u8],
    ) -> Result<Self> {
        let mut store = InMemSignalProtocolStore::new(identity, registration_id)?;
        let remote_addr = address(remote);
        let rid = IdentityKey::decode(remote_identity)?;
        // Pinning: the in-memory libsignal store is TOFU, so the key from the transcript is written before anything
        // else
        block_on(store.save_identity(&remote_addr, &rid))?;
        Ok(Self {
            store,
            local: address(local),
            remote: remote_addr,
        })
    }

    /// Side A's bundle: one-time prekey, signed prekey, ML-KEM-1024 KEM prekey (all with id 1).
    pub fn make_bundle(&mut self) -> Result<Bundle> {
        let mut rng = crypto::rng();
        let idk = block_on(self.store.get_identity_key_pair())?;
        let reg = block_on(self.store.get_local_registration_id())?;
        let pre = KeyPair::generate(&mut rng);
        let spk = KeyPair::generate(&mut rng);
        let kyber = kem::KeyPair::generate(KEM_TYPE, &mut rng);
        let spk_sig = idk
            .private_key()
            .calculate_signature(&spk.public_key.serialize(), &mut rng)
            .map_err(lib)?;
        let kyber_sig = idk
            .private_key()
            .calculate_signature(&kyber.public_key.serialize(), &mut rng)
            .map_err(lib)?;
        block_on(
            self.store
                .save_pre_key(1u32.into(), &PreKeyRecord::new(1u32.into(), &pre)),
        )?;
        block_on(self.store.save_signed_pre_key(
            1u32.into(),
            &SignedPreKeyRecord::new(
                1u32.into(),
                Timestamp::from_epoch_millis(now_ms()),
                &spk,
                &spk_sig,
            ),
        ))?;
        block_on(self.store.save_kyber_pre_key(
            1u32.into(),
            &KyberPreKeyRecord::new(
                1u32.into(),
                Timestamp::from_epoch_millis(now_ms()),
                &kyber,
                &kyber_sig,
            ),
        ))?;
        Ok(Bundle {
            registration_id: reg,
            identity_key: idk.identity_key().serialize().to_vec(),
            prekey_id: 1,
            prekey: pre.public_key.serialize().to_vec(),
            signed_prekey_id: 1,
            signed_prekey: spk.public_key.serialize().to_vec(),
            signed_prekey_sig: spk_sig.to_vec(),
            kyber_prekey_id: 1,
            kyber_prekey: kyber.public_key.serialize().to_vec(),
            kyber_prekey_sig: kyber_sig.to_vec(),
        })
    }

    /// Side B: PQXDH over A's bundle (the bundle's identity must match the pinned one).
    pub fn process_bundle(&mut self, b: &Bundle) -> Result<()> {
        let bundle = to_prekey_bundle(b)?;
        let mut rng = crypto::rng();
        block_on(process_prekey_bundle(
            &self.remote,
            &self.local,
            &mut self.store.session_store,
            &mut self.store.identity_store,
            &bundle,
            SystemTime::now(),
            &mut rng,
        ))?;
        Ok(())
    }

    /// Encrypts.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Encrypted> {
        let mut rng = crypto::rng();
        let c = block_on(message_encrypt(
            plaintext,
            &self.remote,
            &self.local,
            &mut self.store.session_store,
            &mut self.store.identity_store,
            SystemTime::now(),
            &mut rng,
        ))?;
        encrypted(c)
    }

    /// Decrypts.
    pub fn decrypt(&mut self, kind: u8, bytes: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
        let (msg, _, _) = parse_ct(kind, bytes)?;
        let mut rng = crypto::rng();
        let pt = block_on(message_decrypt(
            &msg,
            &self.remote,
            &self.local,
            &mut self.store.session_store,
            &mut self.store.identity_store,
            &mut self.store.pre_key_store,
            &self.store.signed_pre_key_store,
            &mut self.store.kyber_pre_key_store,
            &mut rng,
        ))?;
        Ok(Zeroizing::new(pt))
    }

    /// Export for storing in the DB.
    pub fn export(&self) -> Result<E2eExport> {
        let idk = block_on(self.store.get_identity_key_pair())?;
        let reg = block_on(self.store.get_local_registration_id())?;
        let rec = block_on(self.store.load_session(&self.remote))?
            .ok_or_else(|| Error::internal("no session after pairing"))?;
        let remote = block_on(self.store.get_identity(&self.remote))?
            .ok_or_else(|| Error::internal("no pinned identity"))?;
        Ok(E2eExport {
            identity_keypair: Zeroizing::new(idk.serialize().to_vec()),
            registration_id: reg,
            session_record: Zeroizing::new(rec.serialize()?),
            remote_identity: remote.serialize().to_vec(),
        })
    }
}

fn now_ms() -> u64 {
    crate::now_ms()
}

fn lib(e: impl std::fmt::Display) -> Error {
    Error::internal(format!("libsignal: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The full libsignal path without a network: A's bundle → PQXDH at B → PreKey message → reply → export.
    #[test]
    fn pairing_e2e_session_is_v4_with_spqr_and_pins_identity() {
        let link = LinkId([7; 32]);
        let (an, bn) = address_names(&link);
        let (a_id, a_reg) = new_identity();
        let (b_id, b_reg) = new_identity();
        let a_pub = a_id.identity_key().serialize().to_vec();
        let b_pub = b_id.identity_key().serialize().to_vec();
        let mut a = PairingE2e::new(a_id, a_reg, &an, &bn, &b_pub).unwrap();
        let mut b = PairingE2e::new(b_id, b_reg, &bn, &an, &a_pub).unwrap();
        let bundle = a.make_bundle().unwrap();
        assert_eq!(
            bundle.kyber_prekey.len(),
            1569,
            "ML-KEM-1024 public key + type byte"
        );
        b.process_bundle(&bundle).unwrap();
        let m1 = b.encrypt(b"init").unwrap();
        assert_eq!(m1.kind, e2e_type::PREKEY);
        assert_eq!(&a.decrypt(m1.kind, &m1.bytes).unwrap()[..], b"init");
        let m2 = a.encrypt(b"ack").unwrap();
        assert_eq!(m2.kind, e2e_type::WHISPER);
        assert_eq!(&b.decrypt(m2.kind, &m2.bytes).unwrap()[..], b"ack");
        let (_, v, pq) = parse_ct(m2.kind, &m2.bytes).unwrap();
        assert_eq!(v, 4);
        assert!(pq > 0, "SPQR chunk present");
        let ex = a.export().unwrap();
        let rec = SessionRecord::deserialize(&ex.session_record).unwrap();
        assert_eq!(rec.session_version().unwrap(), 4);
        assert!(rec.current_pq_state().is_some());
    }

    #[test]
    fn bundle_with_foreign_identity_is_rejected() {
        let link = LinkId([8; 32]);
        let (an, bn) = address_names(&link);
        let (a_id, a_reg) = new_identity();
        let (b_id, b_reg) = new_identity();
        let (m_id, m_reg) = new_identity();
        let a_pub = a_id.identity_key().serialize().to_vec();
        let b_pub = b_id.identity_key().serialize().to_vec();
        // B pinned A, but the bundle came from M
        let mut b = PairingE2e::new(b_id, b_reg, &bn, &an, &a_pub).unwrap();
        let mut m = PairingE2e::new(m_id, m_reg, &an, &bn, &b_pub).unwrap();
        let evil = m.make_bundle().unwrap();
        let _ = a_reg;
        assert!(b.process_bundle(&evil).is_err());
    }
}
