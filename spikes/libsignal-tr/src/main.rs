// SPDX-License-Identifier: AGPL-3.0-only
//! Spike c): libsignal-protocol (git tag v0.103.1) + SPQR v1.6.0: Triple Ratchet between two
//! nodes that already have an authenticated (SAS-verified) channel.
//!
//! Scheme (option 1): over the already verified channel Bob gives Alice his prekey bundle
//! (the link identity key, signed prekey, KEM prekey, one-time prekey). Bob's identity key is pinned
//! at Alice beforehand (it was part of the pairing transcript => covered by the SAS), so TOFU is not used.
//! Then the standard process_prekey_bundle / message_encrypt / message_decrypt (PQXDH + Double
//! Ratchet + SPQR). No custom cryptography: we only serialize public keys into bytes.
//!
//! Modes: `cargo run -- kyber1024` (the libsignal default) and `cargo run -- mlkem1024`
//! (FIPS 203, feature `mlkem1024`).

use std::time::{Instant, SystemTime};

use anyhow::{Result, anyhow, bail};
use futures::executor::block_on;
use libsignal_protocol::*;
use rand::{Rng, TryRngCore as _, rngs::OsRng};

/// A byte "wire" inside the already verified channel: length-prefixed fields.
fn put(buf: &mut Vec<u8>, field: &[u8]) {
    buf.extend_from_slice(&(field.len() as u32).to_be_bytes());
    buf.extend_from_slice(field);
}
fn take<'a>(buf: &mut &'a [u8]) -> Result<&'a [u8]> {
    if buf.len() < 4 {
        bail!("short");
    }
    let n = u32::from_be_bytes(buf[..4].try_into()?) as usize;
    let (f, rest) = buf[4..].split_at(n);
    *buf = rest;
    Ok(f)
}

struct Party {
    store: InMemSignalProtocolStore,
    addr: ProtocolAddress,
}

impl Party {
    fn new(link_id: &str) -> Result<Self> {
        let mut rng = OsRng.unwrap_err();
        // The identity key is per link (pairwise); the registration id does not matter.
        let identity = IdentityKeyPair::generate(&mut rng);
        let store = InMemSignalProtocolStore::new(identity, rng.random_range(1..16380))?;
        Ok(Self { store, addr: ProtocolAddress::new(link_id.to_string(), DeviceId::new(1)?) })
    }
}

/// Bob prepares the bundle and keeps the private parts. Returns the bytes for the channel.
async fn make_bundle(bob: &mut Party, kem_type: kem::KeyType) -> Result<Vec<u8>> {
    let mut rng = OsRng.unwrap_err();
    let idk = bob.store.get_identity_key_pair().await?;
    let pre = KeyPair::generate(&mut rng);
    let spk = KeyPair::generate(&mut rng);
    let kyber = kem::KeyPair::generate(kem_type, &mut rng);
    let spk_sig = idk.private_key().calculate_signature(&spk.public_key.serialize(), &mut rng)?;
    let kyber_sig = idk.private_key().calculate_signature(&kyber.public_key.serialize(), &mut rng)?;
    let (pre_id, spk_id, kyber_id) = (1u32, 1u32, 1u32);
    bob.store.save_pre_key(pre_id.into(), &PreKeyRecord::new(pre_id.into(), &pre)).await?;
    bob.store
        .save_signed_pre_key(
            spk_id.into(),
            &SignedPreKeyRecord::new(spk_id.into(), Timestamp::from_epoch_millis(1), &spk, &spk_sig),
        )
        .await?;
    bob.store
        .save_kyber_pre_key(
            kyber_id.into(),
            &KyberPreKeyRecord::new(kyber_id.into(), Timestamp::from_epoch_millis(1), &kyber, &kyber_sig),
        )
        .await?;
    let mut w = Vec::new();
    put(&mut w, &bob.store.get_local_registration_id().await?.to_be_bytes());
    put(&mut w, &idk.identity_key().serialize());
    put(&mut w, &pre.public_key.serialize());
    put(&mut w, &spk.public_key.serialize());
    put(&mut w, &spk_sig);
    put(&mut w, &kyber.public_key.serialize());
    put(&mut w, &kyber_sig);
    Ok(w)
}

fn parse_bundle(mut r: &[u8]) -> Result<PreKeyBundle> {
    let reg = u32::from_be_bytes(take(&mut r)?.try_into()?);
    let idk = IdentityKey::decode(take(&mut r)?)?;
    let pre = PublicKey::deserialize(take(&mut r)?)?;
    let spk = PublicKey::deserialize(take(&mut r)?)?;
    let spk_sig = take(&mut r)?.to_vec();
    let kyber = kem::PublicKey::deserialize(take(&mut r)?)?;
    let kyber_sig = take(&mut r)?.to_vec();
    Ok(PreKeyBundle::new(
        reg,
        DeviceId::new(1)?,
        Some((1u32.into(), pre)),
        1u32.into(),
        spk,
        spk_sig,
        1u32.into(),
        kyber,
        kyber_sig,
        idk,
    )?)
}

async fn send(from: &mut Party, to_addr: &ProtocolAddress, text: &str) -> Result<(CiphertextMessageType, Vec<u8>)> {
    let mut rng = OsRng.unwrap_err();
    let c = message_encrypt(
        text.as_bytes(),
        to_addr,
        &from.addr,
        &mut from.store.session_store,
        &mut from.store.identity_store,
        SystemTime::now(),
        &mut rng,
    )
    .await?;
    Ok((c.message_type(), c.serialize().to_vec()))
}

async fn recv(to: &mut Party, from_addr: &ProtocolAddress, ty: CiphertextMessageType, wire: &[u8]) -> Result<(String, usize, u8)> {
    let mut rng = OsRng.unwrap_err();
    let msg = match ty {
        CiphertextMessageType::PreKey => CiphertextMessage::PreKeySignalMessage(PreKeySignalMessage::try_from(wire)?),
        CiphertextMessageType::Whisper => CiphertextMessage::SignalMessage(SignalMessage::try_from(wire)?),
        other => bail!("unexpected {other:?}"),
    };
    let (pq_len, ver) = match &msg {
        CiphertextMessage::PreKeySignalMessage(m) => (m.message().pq_ratchet().len(), m.message_version()),
        CiphertextMessage::SignalMessage(m) => (m.pq_ratchet().len(), m.message_version()),
        _ => unreachable!(),
    };
    let pt = message_decrypt(
        &msg,
        from_addr,
        &to.addr,
        &mut to.store.session_store,
        &mut to.store.identity_store,
        &mut to.store.pre_key_store,
        &to.store.signed_pre_key_store,
        &mut to.store.kyber_pre_key_store,
        &mut rng,
    )
    .await?;
    Ok((String::from_utf8(pt)?, pq_len, ver))
}

/// SPQR message header: [version][epoch varint][index varint][msg type][chunk]
/// (spqr v1.6.0, src/v1/chunked/states/serialize.rs). Read only for observation in the spike.
fn spqr_epoch(pq: &[u8]) -> Option<(u64, u8)> {
    fn varint(b: &[u8], pos: &mut usize) -> Option<u64> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let x = *b.get(*pos)?;
            *pos += 1;
            v |= ((x & 0x7f) as u64) << shift;
            if x & 0x80 == 0 {
                return Some(v);
            }
        }
        None
    }
    if pq.first() != Some(&1) {
        return None;
    }
    let mut pos = 1;
    let epoch = varint(pq, &mut pos)?;
    let _index = varint(pq, &mut pos)?;
    Some((epoch, *pq.get(pos)?))
}

async fn session_info(p: &Party, remote: &ProtocolAddress) -> Result<String> {
    let rec = p.store.session_store.load_session(remote).await?.ok_or(anyhow!("no session"))?;
    let ver = rec.session_version()?;
    let pq = rec.current_pq_state().ok_or(anyhow!("no pq state"))?;
    let pqv = spqr::current_version(pq).map_err(|e| anyhow!("{e}"))?;
    Ok(format!(
        "session_version={ver}, spqr={pqv:?}, pq_state={}B, record={}B",
        pq.len(),
        rec.serialize()?.len()
    ))
}

async fn run(kem_type: kem::KeyType) -> Result<()> {
    println!("\n=== KEM prekey type: {kem_type:?} ===");
    // A link ID instead of a phone number/UUID: ProtocolAddress is just a string.
    let mut alice = Party::new("link-7f3a/alice")?;
    let mut bob = Party::new("link-7f3a/bob")?;
    let (a_addr, b_addr) = (alice.addr.clone(), bob.addr.clone());

    // 0) Pairing has already pinned each other's identity keys (they are in the transcript => under the SAS).
    let bob_idk = *bob.store.get_identity_key_pair().await?.identity_key();
    let alice_idk = *alice.store.get_identity_key_pair().await?.identity_key();
    alice.store.save_identity(&b_addr, &bob_idk).await?;
    bob.store.save_identity(&a_addr, &alice_idk).await?;

    // 1) Bob -> Alice: the bundle over the verified channel.
    let t = Instant::now();
    let wire_bundle = make_bundle(&mut bob, kem_type).await?;
    println!("bundle on the wire: {} bytes", wire_bundle.len());
    let bundle = parse_bundle(&wire_bundle)?;
    if bundle.identity_key()? != &bob_idk {
        bail!("bundle identity != pinned identity");
    }
    let mut rng = OsRng.unwrap_err();
    process_prekey_bundle(
        &b_addr,
        &a_addr,
        &mut alice.store.session_store,
        &mut alice.store.identity_store,
        &bundle,
        SystemTime::now(),
        &mut rng,
    )
    .await?;
    println!("alice: PQXDH done in {:?}; {}", t.elapsed(), session_info(&alice, &b_addr).await?);

    // 2) Message exchange: ping-pong + one-way bursts + out-of-order delivery.
    let mut log = Vec::new();
    for i in 0..6 {
        let (ty, w) = send(&mut alice, &b_addr, &format!("A{i}")).await?;
        let (pt, pq, ver) = recv(&mut bob, &a_addr, ty, &w).await?;
        log.push(format!("A->B {pt} {ty:?} v{ver} {}B pq_ratchet={}B", w.len(), pq));
        let (ty, w) = send(&mut bob, &a_addr, &format!("B{i}")).await?;
        let (pt, pq, ver) = recv(&mut alice, &b_addr, ty, &w).await?;
        log.push(format!("B->A {pt} {ty:?} v{ver} {}B pq_ratchet={}B", w.len(), pq));
    }
    // A burst of 5 from Alice, delivered in reverse order.
    let mut batch = Vec::new();
    for i in 0..5 {
        batch.push(send(&mut alice, &b_addr, &format!("burst{i}")).await?);
    }
    for (ty, w) in batch.into_iter().rev() {
        let (pt, pq, _) = recv(&mut bob, &a_addr, ty, &w).await?;
        log.push(format!("A->B {pt} (out of order) pq_ratchet={pq}B"));
    }
    for l in &log {
        println!("  {l}");
    }
    println!("alice: {}", session_info(&alice, &b_addr).await?);
    println!("bob:   {}", session_info(&bob, &a_addr).await?);

    // 2b) Long ping-pong: shows SPQR moving to new epochs (new ML-KEM-768 secrets).
    async fn step(from: &mut Party, to: &mut Party, text: &str) -> Result<(u64, u8)> {
        let (faddr, taddr) = (from.addr.clone(), to.addr.clone());
        let (ty, w) = send(from, &taddr, text).await?;
        let sm = SignalMessage::try_from(&w[..])?;
        let hdr = spqr_epoch(sm.pq_ratchet()).ok_or(anyhow!("bad spqr hdr"))?;
        recv(to, &faddr, ty, &w).await?;
        Ok(hdr)
    }
    let (mut ea, mut eb, mut msgs) = (0u64, 0u64, 0);
    for i in 0..200 {
        let (ep, mt) = step(&mut alice, &mut bob, &format!("a{i}")).await?;
        msgs += 1;
        if ep != ea {
            println!("  spqr epoch {ea} -> {ep} (A->B) at message #{msgs} (msg type {mt})");
            ea = ep;
        }
        let (ep, mt) = step(&mut bob, &mut alice, &format!("b{i}")).await?;
        msgs += 1;
        if ep != eb {
            println!("  spqr epoch {eb} -> {ep} (B->A) at message #{msgs} (msg type {mt})");
            eb = ep;
        }
    }
    println!("after {msgs} more messages: alice: {}", session_info(&alice, &b_addr).await?);

    // 3) Session save/restore (the daemon restarted).
    let rec = bob.store.session_store.load_session(&a_addr).await?.unwrap();
    let bytes = rec.serialize()?;
    let restored = SessionRecord::deserialize(&bytes)?;
    bob.store.session_store.store_session(&a_addr, &restored).await?;
    let (ty, w) = send(&mut bob, &a_addr, "after restore").await?;
    let (pt, _, _) = recv(&mut alice, &b_addr, ty, &w).await?;
    println!("restore session record ({} B) and continue: {pt:?} OK", bytes.len());

    // 4) A replay of the same ciphertext is rejected.
    let (ty, w) = send(&mut alice, &b_addr, "once").await?;
    recv(&mut bob, &a_addr, ty, &w).await?;
    match recv(&mut bob, &a_addr, ty, &w).await {
        Ok(_) => bail!("replay accepted!"),
        Err(e) => println!("replay rejected: {e}"),
    }
    // 5) A substituted ciphertext byte is rejected.
    let (ty, mut w) = send(&mut alice, &b_addr, "tamper me").await?;
    let n = w.len();
    w[n - 12] ^= 1;
    match recv(&mut bob, &a_addr, ty, &w).await {
        Ok(_) => bail!("tampered accepted!"),
        Err(e) => println!("tampered rejected: {e}"),
    }
    // 6) An unknown identity (not the one pinned at pairing): the bundle is not accepted.
    let mut mallory = Party::new("link-7f3a/bob")?;
    let evil = parse_bundle(&make_bundle(&mut mallory, kem_type).await?)?;
    let mut alice2 = Party::new("link-7f3a/alice")?;
    alice2.store.save_identity(&b_addr, &bob_idk).await?;
    match process_prekey_bundle(
        &b_addr,
        &a_addr,
        &mut alice2.store.session_store,
        &mut alice2.store.identity_store,
        &evil,
        SystemTime::now(),
        &mut rng,
    )
    .await
    {
        Ok(()) => bail!("bundle with foreign identity accepted!"),
        Err(e) => println!("bundle with non-pinned identity rejected: {e}"),
    }
    Ok(())
}

fn main() -> Result<()> {
    let arg = std::env::args().nth(1).unwrap_or_else(|| "both".into());
    if arg == "kyber1024" || arg == "both" {
        block_on(run(kem::KeyType::Kyber1024))?;
    }
    if arg == "mlkem1024" || arg == "both" {
        block_on(run(kem::KeyType::MLKEM1024))?;
    }
    println!("\nDONE");
    Ok(())
}
