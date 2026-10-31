// SPDX-License-Identifier: AGPL-3.0-only
//! Owner proofs and unlock slots on the node (v7, `docs/CONTROL.md` §22, D-102, experimental): challenges, the check
//! of a proof, enrolling and removing owner keys, and unlocking with a key's slot.
//!
//! A proof is checked here, by the daemon, for every command it stands in for (SPEC §9); the window only carries it.
//! Every failure counts in the D-37 limiter together with wrong passwords, and in a count of its own: after three in a
//! row, or 14 days after the last correct password, proofs and slots are refused until the password is used again.

use std::sync::{MutexGuard, PoisonError};

use antenna_proto::control::{
    OwnerChallenge, OwnerKeyAdded, OwnerKeys, OwnerProof, SecretString, code,
    owner_keys::{OWNER_KEYS_MAX, PROOF_FAILS_MAX, PUBLIC_KEY_LEN},
};
use data_encoding::{BASE64, HEXLOWER};
use zeroize::Zeroizing;

use super::{Node, PwRef, Session, State};
use crate::{
    error::{Error, Result},
    keystore, now_ms,
    owner_keys::{self, Bind, KeyRecord, ProofState},
    store::Db,
};

/// The attempts the D-37 limiter counts: wrong passwords, and (v7) proofs and unlock slots that failed.
pub(super) fn counts_as_failed_attempt(c: &str) -> bool {
    matches!(
        c,
        code::WRONG_PASSWORD
            | code::PROOF_INVALID
            | code::CHALLENGE_INVALID
            | code::OWNER_KEY_UNKNOWN
            | code::OWNER_KEY_REFUSED
            | code::SLOT_INVALID
    )
}

fn unknown_key() -> Error {
    Error::new(
        code::OWNER_KEY_UNKNOWN,
        "this owner key is not enrolled here (removed?): use the password",
    )
}

fn refused_key() -> Error {
    Error::new(
        code::OWNER_KEY_REFUSED,
        "this is the public test key, which only a debug build started with ANTENNA_OWNER_TEST_KEY=1 accepts",
    )
}

/// An unlock by slot, checked against the database before anything starts: the key is still enrolled with its slot
/// (the database is the source, the slot file only a copy of the root key) and the password is not due.
pub(super) fn check_slot_unlock(db: &Db, key_id: &str, now: u64, every_ms: u64) -> Result<()> {
    let mut keys = owner_keys::load(db)?;
    let k = keys
        .iter_mut()
        .find(|k| k.key_id == key_id && k.unlock)
        .ok_or_else(unknown_key)?;
    if k.is_test_key() && !owner_keys::test_key_accepted() {
        return Err(refused_key());
    }
    if now >= owner_keys::password_due_ms(owner_keys::password_ms(db)?, every_ms) {
        return Err(owner_keys::password_due_error());
    }
    k.last_used_ms = Some(now);
    owner_keys::save(db, &keys)
}

impl Session {
    /// A correct owner password now (unlock, `init`): the 14-day clock starts again.
    pub(super) fn note_password(&self) {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(e) = owner_keys::note_password(&db, now_ms()) {
            tracing::warn!("owner keys: cannot record the password check: {e}");
        }
    }

    fn owner_keys_and_due(&self) -> Result<(Vec<KeyRecord>, u64)> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let keys = owner_keys::load(&db)?;
        let every = u64::try_from(self.cfg.owner_password_every.as_millis()).unwrap_or(u64::MAX);
        let due = owner_keys::password_due_ms(owner_keys::password_ms(&db)?, every);
        Ok((keys, due))
    }
}

impl Node {
    fn proofs(&self) -> MutexGuard<'_, ProofState> {
        self.proofs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Proofs wait for the password: three failed in a row, or 14 days since the last correct password.
    fn refuse_if_password_due(&self, due: u64, now: u64) -> Result<()> {
        if self.proofs().fails >= PROOF_FAILS_MAX || now >= due {
            return Err(owner_keys::password_due_error());
        }
        Ok(())
    }

    /// `owner_challenge`: a nonce for one proof by the client `bind` names. Refused when proofs wait for the
    /// password, so that the window asks for it before a Touch ID sheet; `enroll` (for `owner_key_add`, which carries
    /// the password) gets one anyway, and such a challenge serves that proof of possession and nothing else.
    pub async fn owner_challenge(&self, bind: Bind, enroll: bool) -> Result<OwnerChallenge> {
        let s = self.session().await?;
        let (_, due) = s.owner_keys_and_due()?;
        let now = now_ms();
        if !enroll {
            self.refuse_if_password_due(due, now)?;
        }
        let ttl = u64::try_from(self.cfg.owner_challenge_ttl.as_millis()).unwrap_or(u64::MAX);
        let (nonce, expires_ms) = self.proofs().issue(bind, now, ttl, enroll);
        Ok(OwnerChallenge {
            nonce: HEXLOWER.encode(&nonce),
            expires_ms,
            password_due_ms: due,
        })
    }

    /// Checks the proof that came with a request whose bytes hash to `request_hash`, from the client `bind`. Returns
    /// the key ID. The challenge is used up by this call whatever the outcome.
    pub async fn verify_proof(
        &self,
        proof: &OwnerProof,
        request_hash: &[u8; 32],
        bind: &Bind,
    ) -> Result<String> {
        let s = self.session().await?;
        let (keys, due) = s.owner_keys_and_due()?;
        self.refuse_if_password_due(due, now_ms())?;
        let _one = self
            .pw_gate
            .acquire()
            .await
            .map_err(|_| Error::internal("password gate closed"))?;
        self.limit_pause()?;
        let now = now_ms();
        let r = self.check_proof(&keys, proof, request_hash, bind, now);
        self.limit_record(&r);
        match &r {
            Ok(id) => {
                self.proofs().fails = 0;
                let db = s.db.lock().unwrap_or_else(PoisonError::into_inner);
                let mut keys = owner_keys::load(&db)?;
                if let Some(k) = keys.iter_mut().find(|k| &k.key_id == id) {
                    k.last_used_ms = Some(now);
                    owner_keys::save(&db, &keys)?;
                }
            }
            Err(e) if counts_as_failed_attempt(e.code) => {
                self.proofs().fails += 1;
                tracing::warn!("owner proof refused: {}", e.code);
            }
            Err(_) => {}
        }
        r
    }

    /// The order of `docs/CONTROL.md` §22.2: the challenge (taken first, once), the key, this build, the signature.
    fn check_proof(
        &self,
        keys: &[KeyRecord],
        proof: &OwnerProof,
        request_hash: &[u8; 32],
        bind: &Bind,
        now: u64,
    ) -> Result<String> {
        let nonce = self.proofs().take(&proof.nonce, bind, now, false)?;
        let k = keys
            .iter()
            .find(|k| k.key_id == proof.key_id)
            .ok_or_else(unknown_key)?;
        if k.is_test_key() && !owner_keys::test_key_accepted() {
            return Err(refused_key());
        }
        owner_keys::verify(&k.public()?, &nonce, request_hash, &proof.sig)?;
        Ok(k.key_id.clone())
    }

    /// `owner_key_add`'s proof of possession: signed by the key being enrolled, over a challenge of this client. The
    /// password was checked before (it is what authorizes the enrollment).
    pub async fn verify_new_key(
        &self,
        proof: &OwnerProof,
        request_hash: &[u8; 32],
        bind: &Bind,
        public: &[u8; PUBLIC_KEY_LEN],
    ) -> Result<()> {
        self.session().await?;
        if proof.key_id != owner_keys::key_id(public) {
            return Err(Error::new(
                code::PROOF_INVALID,
                "owner_key_add is signed by the key it enrolls",
            ));
        }
        let nonce = self.proofs().take(&proof.nonce, bind, now_ms(), true)?;
        owner_keys::verify(public, &nonce, request_hash, &proof.sig)
    }

    /// `owner_key_add` (the password and the proof of possession were checked): stores the key and, with `unlock`, an
    /// unlock slot, whose key is returned once.
    pub async fn owner_key_add(
        &self,
        public: [u8; PUBLIC_KEY_LEN],
        label: &str,
        unlock: bool,
        password: Zeroizing<String>,
    ) -> Result<OwnerKeyAdded> {
        let s = self.session().await?;
        let id = owner_keys::key_id(&public);
        let mut rec = KeyRecord {
            key_id: id.clone(),
            public: BASE64.encode(&public),
            label: owner_keys::label(label)?,
            created_ms: now_ms(),
            last_used_ms: None,
            unlock: false,
        };
        if rec.is_test_key() && !owner_keys::test_key_accepted() {
            return Err(refused_key());
        }
        let (keys, _) = s.owner_keys_and_due()?;
        if keys.iter().any(|k| k.key_id == id) {
            return Err(Error::bad_request(
                "this key is already enrolled: remove it first to enroll it again",
            ));
        }
        if keys.len() >= OWNER_KEYS_MAX {
            return Err(Error::bad_request(format!(
                "at most {OWNER_KEYS_MAX} owner keys: remove one first"
            )));
        }
        let slot_key = if unlock {
            // The root key from the keystore remembered at unlock and the password the owner just gave (D-38: never
            // the file on disk); the slot is bound to those keystore bytes.
            let (bytes, fp) = {
                let g = self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner);
                let r = g.as_ref().ok_or_else(|| {
                    Error::new(code::LOCKED, "keystore is locked: run `antenna unlock`")
                })?;
                (r.keystore.clone(), Zeroizing::new(*r.fingerprint))
            };
            let dir = self.cfg.data_dir.clone();
            let id2 = id.clone();
            let k = tokio::task::spawn_blocking(move || {
                let root = keystore::unlock_bytes(&bytes, password.as_bytes())?;
                if !crate::crypto::ct_eq(root.fingerprint().as_slice(), fp.as_slice()) {
                    return Err(Error::new(code::WRONG_PASSWORD, "wrong password"));
                }
                keystore::slots::add(&dir, &id2, &root, &bytes)
            })
            .await
            .map_err(|e| Error::internal(e.to_string()))??;
            Some(k)
        } else {
            None
        };
        rec.unlock = slot_key.is_some();
        let saved = {
            let db = s.db.lock().unwrap_or_else(PoisonError::into_inner);
            owner_keys::load(&db).and_then(|mut keys| {
                keys.push(rec.clone());
                owner_keys::save(&db, &keys)
            })
        };
        if let Err(e) = saved {
            if slot_key.is_some() {
                let _ = keystore::slots::remove(&self.cfg.data_dir, &id);
            }
            return Err(e);
        }
        tracing::info!(
            "owner key {id} enrolled{}",
            if rec.unlock {
                " with an unlock slot"
            } else {
                ""
            }
        );
        Ok(OwnerKeyAdded {
            key: rec.info(),
            slot_key: slot_key.map(|k| SecretString(BASE64.encode(k.as_slice()))),
        })
    }

    /// `owner_key_list`.
    pub async fn owner_key_list(&self) -> Result<OwnerKeys> {
        let s = self.session().await?;
        let (keys, due) = s.owner_keys_and_due()?;
        Ok(OwnerKeys {
            keys: keys.iter().map(KeyRecord::info).collect(),
            password_due_ms: due,
            test_key: owner_keys::test_key_accepted(),
        })
    }

    /// `owner_key_remove`: the key and its unlock slot. Needs no password (D-84): it only takes a way in away.
    pub async fn owner_key_remove(&self, key_id: &str) -> Result<()> {
        let s = self.session().await?;
        let in_db = {
            let db = s.db.lock().unwrap_or_else(PoisonError::into_inner);
            let mut keys = owner_keys::load(&db)?;
            let before = keys.len();
            keys.retain(|k| k.key_id != key_id);
            let changed = keys.len() != before;
            if changed {
                owner_keys::save(&db, &keys)?;
            }
            changed
        };
        let dir = self.cfg.data_dir.clone();
        let id = key_id.to_string();
        let in_slots = tokio::task::spawn_blocking(move || keystore::slots::remove(&dir, &id))
            .await
            .map_err(|e| Error::internal(e.to_string()))??;
        if !in_db && !in_slots {
            return Err(Error::new(code::NOT_FOUND, "no such owner key"));
        }
        tracing::info!("owner key {key_id} removed");
        Ok(())
    }

    /// `unlock {key_id, slot_key}`: the root key from the key's unlock slot instead of the password.
    pub async fn unlock_slot(&self, key_id: String, slot_key: Zeroizing<[u8; 32]>) -> Result<()> {
        let mut state = self.state.lock().await;
        match *state {
            State::Unlocked(_) => return Ok(()),
            State::Uninitialized => {
                return Err(Error::new(
                    code::NOT_INITIALIZED,
                    "run `antenna init` first",
                ));
            }
            State::Locked => {}
        }
        if self.proofs().fails >= PROOF_FAILS_MAX {
            return Err(owner_keys::password_due_error());
        }
        let bytes = keystore::read(&self.cfg.data_dir)?;
        let (b2, dir, id) = (bytes.clone(), self.cfg.data_dir.clone(), key_id.clone());
        let r = self
            .with_password_limit(move || keystore::slots::open(&dir, &id, &slot_key, &b2))
            .await;
        if let Err(e) = &r
            && counts_as_failed_attempt(e.code)
        {
            self.proofs().fails += 1;
        }
        let root = r?;
        let fp_root = root.fingerprint();
        let s = match self.open_session(root, Some(&key_id)).await {
            Ok(s) => s,
            Err(e) => {
                if e.code == code::OWNER_KEY_UNKNOWN {
                    // A slot whose key the database no longer has: it is not a way in any more
                    let _ = keystore::slots::remove(&self.cfg.data_dir, &key_id);
                }
                if counts_as_failed_attempt(e.code) {
                    self.proofs().fails += 1;
                }
                return Err(e);
            }
        };
        self.proofs().fails = 0;
        *self.pw_ref.lock().unwrap_or_else(PoisonError::into_inner) = Some(PwRef {
            keystore: bytes,
            fingerprint: fp_root,
        });
        *state = State::Unlocked(s);
        tracing::info!("unlocked with the unlock slot of owner key {key_id}");
        Ok(())
    }
}
