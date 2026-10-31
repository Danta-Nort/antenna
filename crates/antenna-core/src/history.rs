// SPDX-License-Identifier: AGPL-3.0-only
//! History (SPEC §7–§8, `docs/PROTOCOL.md` §12, §16): the message envelope, ID = BLAKE3 over the `core` bytes, the
//! author's Ed25519 signature with context, hash-DAG fields (`parents` = current heads, `lamport`, author counter `n`),
//! author chains and the history fingerprint for verification, packing into a `RoutingBlob` with padding.
//!
//! No custom cryptography: signatures are `ed25519-dalek` (RFC 8032, verification with `verify_strict`), hashes are
//! BLAKE3 `derive_key`. Where constructions are combined: PROTOCOL §14 (C12–C14).

use antenna_proto::{
    Auth, Body, Envelope, EnvelopeCore, LinkId, MessageId, MessageType, ProtocolVersion,
    ReceiptBody, RoutingBlob, padding,
};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};

use crate::{
    crypto::{self, Secret32},
    e2e::Encrypted,
    error::{Error, Result},
};

/// BLAKE3 `derive_key` context for the message ID.
pub const MSG_ID_CONTEXT: &str = "x 2026-10-02 message-id v0";
/// Message signature label (link format v1).
pub const MSG_SIG_LABEL: &[u8] = b"x/link/v1/msg-sig";
/// BLAKE3 context of the author chain (§16).
pub const CHAIN_CONTEXT: &str = "x 2026-10-02 author-chain v1";
/// BLAKE3 context of the history fingerprint (§16).
pub const FINGERPRINT_CONTEXT: &str = "x 2026-10-02 history-fingerprint v1";
/// Signature label of a rekey offer (§17).
pub const REKEY_OFFER_LABEL: &[u8] = b"x/link/v1/rekey-offer";
/// Initial value of the author chain: `chain(0)`.
pub const CHAIN_ZERO: [u8; 32] = [0; 32];

/// Message ID from the `core` bytes.
pub fn message_id(core: &[u8]) -> MessageId {
    MessageId(crypto::blake3_dk(MSG_ID_CONTEXT, core))
}

/// Signed bytes: `"x/link/v1/msg-sig" ‖ link_id ‖ recipient ‖ u64be(n) ‖ lp(core)` (SPEC §7 "signature with
/// context": link ID, recipient key, counter and content).
pub fn sig_message(link: &LinkId, recipient: &[u8; 32], n: u64, core: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(MSG_SIG_LABEL.len() + 32 + 32 + 8 + 4 + core.len());
    m.extend_from_slice(MSG_SIG_LABEL);
    m.extend_from_slice(&link.0);
    m.extend_from_slice(recipient);
    m.extend_from_slice(&n.to_be_bytes());
    m.extend_from_slice(&crypto::lp(core));
    m
}

/// Ed25519 signature with the author key (link-root seed from the DB).
pub fn sign(seed: &Secret32, msg: &[u8]) -> [u8; 64] {
    let sk = SigningKey::from_bytes(seed);
    sk.sign(msg).to_bytes()
}

/// Ed25519 signature verification (strict: no small subgroups and no non-canonical `S`).
pub fn verify(pk: &[u8; 32], msg: &[u8], sig: &[u8]) -> bool {
    let Ok(sig) = <[u8; 64]>::try_from(sig) else {
        return false;
    };
    let Ok(vk) = VerifyingKey::from_bytes(pk) else {
        return false;
    };
    vk.verify_strict(msg, &Signature::from_bytes(&sig)).is_ok()
}

/// The envelope's message signature is valid for author `author` and recipient `recipient`.
pub fn verify_envelope(
    link: &LinkId,
    env: &Envelope,
    core: &EnvelopeCore,
    recipient: &[u8; 32],
) -> bool {
    match &env.auth {
        Some(Auth::Sig(sig)) => verify(
            &core.author,
            &sig_message(link, recipient, core.n, &env.core),
            sig,
        ),
        _ => false,
    }
}

/// What a new envelope is created from.
pub struct NewMessage<'a> {
    /// Link.
    pub link: &'a LinkId,
    /// The author's Ed25519 link-root seed.
    pub seed: &'a Secret32,
    /// The author's public link-root.
    pub author: [u8; 32],
    /// The recipient's public link-root.
    pub recipient: [u8; 32],
    /// Heads.
    pub parents: Vec<MessageId>,
    /// Lamport.
    pub lamport: u64,
    /// Author time.
    pub ts: u64,
    /// Author counter.
    pub n: u64,
    /// Type.
    pub kind: MessageType,
    /// Content.
    pub body: Body,
}

/// New signed envelope. Returns the ratchet plaintext (CBOR of the envelope), the envelope and its `core`.
pub fn build(m: NewMessage<'_>) -> Result<(Vec<u8>, Envelope, EnvelopeCore)> {
    build_with_salt(m, crypto::random::<32>())
}

/// The same with a given salt: the final message of a stream carries a salt derived from the stream secret
/// (`docs/PROTOCOL.md` §20), by which the recipient recognizes the stream's final message. The salt is still
/// unpredictable to everyone except the two sides of the link.
pub fn build_with_salt(
    m: NewMessage<'_>,
    salt: [u8; 32],
) -> Result<(Vec<u8>, Envelope, EnvelopeCore)> {
    build_addressed(m, salt, None, None, false)
}

/// The same with the address and topic in `core` (`docs/PROTOCOL.md` §23): only for a contact node with `addr/0`;
/// `urgent` (PG-58) only for one with `urgent/0`.
pub fn build_addressed(
    m: NewMessage<'_>,
    salt: [u8; 32],
    to: Option<antenna_proto::To>,
    topic: Option<antenna_proto::Topic>,
    urgent: bool,
) -> Result<(Vec<u8>, Envelope, EnvelopeCore)> {
    let core = EnvelopeCore {
        salt,
        author: m.author,
        parents: m.parents,
        lamport: m.lamport,
        ts: m.ts,
        n: m.n,
        kind: m.kind,
        body: m.body,
        to,
        topic,
        urgent: urgent.then_some(true),
    };
    let core_bytes = antenna_proto::to_cbor(&core)?;
    let sig = sign(m.seed, &sig_message(m.link, &m.recipient, m.n, &core_bytes));
    let env = Envelope {
        id: message_id(&core_bytes),
        core: core_bytes,
        auth: Some(Auth::Sig(sig.to_vec())),
    };
    Ok((antenna_proto::to_cbor(&env)?, env, core))
}

/// New text envelope (signed).
pub fn new_text(m: NewMessage<'_>) -> Result<(Vec<u8>, Envelope, EnvelopeCore)> {
    build(m)
}

/// Parses an envelope and **recomputes** the ID (the caller verifies the signature: it knows the link and the sides).
pub fn open(plaintext: &[u8]) -> Result<(Envelope, EnvelopeCore)> {
    let env: Envelope = antenna_proto::from_cbor(plaintext)?;
    open_envelope(env)
}

/// The same for an already parsed envelope.
pub fn open_envelope(env: Envelope) -> Result<(Envelope, EnvelopeCore)> {
    if message_id(&env.core) != env.id {
        return Err(Error::bad_request("message id does not match its content"));
    }
    let core: EnvelopeCore = antenna_proto::from_cbor(&env.core)?;
    let mut sorted = core.parents.clone();
    sorted.sort();
    sorted.dedup();
    if sorted != core.parents {
        return Err(Error::bad_request("parents must be sorted and unique"));
    }
    Ok((env, core))
}

/// Text stored in the `body` column and displayed: the message text or the receipt line. It is derived
/// unambiguously from `core`: the local copy check compares the column with this value.
pub fn display_body(core: &EnvelopeCore) -> Option<String> {
    match (&core.kind, &core.body) {
        (MessageType::Text, Body::Text(t)) => Some(t.clone()),
        (MessageType::Receipt, Body::Receipt(r)) => Some(receipt_line(r)),
        (MessageType::File, Body::File(o)) => Some(file_line(o)),
        (MessageType::Request, Body::FileRequest(r)) => Some(format!(
            "file request: {}",
            antenna_files::text::escape_visible(&r.path, 300)
        )),
        // The side's agent announcement (PROTOCOL §21): the name is already checked against `[A-Za-z0-9._-]`
        (MessageType::Control, Body::Agent(a)) => Some(format!("agent {}: {}", a.name, a.state)),
        // A profile picture (PROTOCOL §25): the agent name and the id are checked against their patterns
        (MessageType::Control, Body::Picture(p)) => Some(crate::pictures::display(p)),
        _ => None,
    }
}

/// File offer line: `file: <name> (<size> bytes, <mime>, blake3 <16 hex>)`, the hash cut to its first 8 bytes. The
/// name is contact data: control and invisible characters are escaped. A broken manifest gives
/// `file: <unreadable manifest>` (checked on receipt).
pub fn file_line(o: &antenna_proto::files::FileOffer) -> String {
    match antenna_proto::from_cbor::<antenna_proto::files::Manifest>(&o.manifest.body) {
        Ok(m) => format!(
            "file: {} ({} bytes, {}, blake3 {})",
            antenna_files::text::escape_visible(&m.name, 300),
            m.size,
            antenna_files::text::escape_visible(&m.mime, 128),
            &data_encoding::HEXLOWER.encode(&m.blake3)[..16]
        ),
        Err(_) => "file: <unreadable manifest>".into(),
    }
}

/// Receipt line: `actor action decision (k)`; a batch (Q-22) also gets `×N`.
pub fn receipt_line(r: &ReceiptBody) -> String {
    if r.count > 1 {
        format!(
            "{} {} {} ({}) ×{}",
            r.actor,
            r.action,
            r.decision,
            r.refs.len(),
            r.count
        )
    } else {
        format!("{} {} {} ({})", r.actor, r.action, r.decision, r.refs.len())
    }
}

/// Author chain step: `chain(n) = BLAKE3-DK(CHAIN_CONTEXT, chain(n−1) ‖ id(n))` (§16).
pub fn chain_step(prev: &[u8; 32], id: &MessageId) -> [u8; 32] {
    let mut b = [0u8; 64];
    b[..32].copy_from_slice(prev);
    b[32..].copy_from_slice(&id.0);
    crypto::blake3_dk(CHAIN_CONTEXT, &b)
}

/// History fingerprint (§16): `BLAKE3-DK(FINGERPRINT_CONTEXT, link_id ‖ heads…)`, the first 4 bytes big-endian
/// `mod 1000` → 3 digits → 3 emoji from the same table as SAS (PROTOCOL §7). Returns (digits, emoji).
pub fn fingerprint(link: &LinkId, heads: &[MessageId]) -> (String, String) {
    let mut sorted = heads.to_vec();
    sorted.sort();
    let mut b = Vec::with_capacity(32 + 32 * sorted.len());
    b.extend_from_slice(&link.0);
    for h in &sorted {
        b.extend_from_slice(&h.0);
    }
    let h = crypto::blake3_dk(FINGERPRINT_CONTEXT, &b);
    let v = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) % 1000;
    let digits = format!("{v:03}");
    let emoji = antenna_proto::sas::digits_to_emoji(&digits).unwrap_or_default();
    (digits, emoji)
}

/// Packs a ciphertext into a `RoutingBlob`: `pad(type ‖ bytes)`.
pub fn seal(link: &LinkId, enc: &Encrypted) -> Result<Vec<u8>> {
    Ok(antenna_proto::to_cbor(&seal_blob(link, enc)?)?)
}

/// The same, without encoding to CBOR.
pub fn seal_blob(link: &LinkId, enc: &Encrypted) -> Result<RoutingBlob> {
    let mut frame = Vec::with_capacity(1 + enc.bytes.len());
    frame.push(enc.kind);
    frame.extend_from_slice(&enc.bytes);
    Ok(RoutingBlob {
        v: ProtocolVersion::CURRENT,
        link: *link,
        ct: padding::pad(&frame).map_err(|e| Error::internal(e.to_string()))?,
    })
}

/// Removes the padding: `(type, libsignal bytes)`.
pub fn unseal(blob: &RoutingBlob) -> Result<(u8, Vec<u8>)> {
    if blob.v != ProtocolVersion::CURRENT {
        return Err(Error::bad_request("unsupported protocol version"));
    }
    let frame = padding::unpad(&blob.ct).map_err(|e| Error::bad_request(e.to_string()))?;
    let (&kind, rest) = frame
        .split_first()
        .ok_or_else(|| Error::bad_request("empty e2e frame"))?;
    Ok((kind, rest.to_vec()))
}

/// Signed bytes of a rekey offer: `"x/link/v1/rekey-offer" ‖ link_id ‖ recipient ‖ u64be(ts) ‖ lp(bundle)`.
pub fn rekey_offer_message(link: &LinkId, recipient: &[u8; 32], ts: u64, bundle: &[u8]) -> Vec<u8> {
    let mut m = Vec::new();
    m.extend_from_slice(REKEY_OFFER_LABEL);
    m.extend_from_slice(&link.0);
    m.extend_from_slice(recipient);
    m.extend_from_slice(&ts.to_be_bytes());
    m.extend_from_slice(&crypto::lp(bundle));
    m
}

/// Rekey confirmation code (§17): 6 digits from `link_id` and the bundle hash. The owner of the side accepting the
/// offer types the code the other side read out to them (the confirmation names exactly this offer).
/// `u32be(HKDF-SHA256(salt "x/link/v1/rekey-code", link_id ‖ H(bundle), "x/link/v1/rekey-digits")[0..4]) mod 10⁶`.
pub fn rekey_code(link: &LinkId, bundle_hash: &[u8; 32]) -> String {
    let mut ikm = [0u8; 64];
    ikm[..32].copy_from_slice(&link.0);
    ikm[32..].copy_from_slice(bundle_hash);
    let k = crypto::hkdf32(b"x/link/v1/rekey-code", &ikm, &[b"x/link/v1/rekey-digits"]);
    let v = u32::from_be_bytes([k[0], k[1], k[2], k[3]]) % 1_000_000;
    format!("{v:06}")
}

/// Second rekey code (§17): 6 digits from `link_id`, the bundle hash and the hash of the first message of the new
/// session. The side that accepted the offer shows it, and the owner of the rolled-back side types it: this way the
/// owner confirms that the answer came from the real contact and not from someone holding a stolen copy of the
/// contact's keys.
/// `u32be(HKDF-SHA256(salt "x/link/v1/rekey-confirm", link_id ‖ H(bundle) ‖ H(init), "x/link/v1/rekey-digits")[0..4])
/// mod 10⁶`.
pub fn rekey_confirm_code(link: &LinkId, bundle_hash: &[u8; 32], init_hash: &[u8; 32]) -> String {
    let mut ikm = [0u8; 96];
    ikm[..32].copy_from_slice(&link.0);
    ikm[32..64].copy_from_slice(bundle_hash);
    ikm[64..].copy_from_slice(init_hash);
    let k = crypto::hkdf32(
        b"x/link/v1/rekey-confirm",
        &ikm,
        &[b"x/link/v1/rekey-digits"],
    );
    let v = u32::from_be_bytes([k[0], k[1], k[2], k[3]]) % 1_000_000;
    format!("{v:06}")
}

/// Hash of the first message of the new session (for the second code): `SHA-256(type ‖ libsignal bytes)` without
/// padding.
pub fn rekey_init_hash(blob: &RoutingBlob) -> Result<[u8; 32]> {
    let (kind, bytes) = unseal(blob)?;
    Ok(crypto::sha256(&[&[kind], &bytes]))
}

/// Ed25519 public key from a seed.
pub fn public_key(seed: &Secret32) -> [u8; 32] {
    SigningKey::from_bytes(seed).verifying_key().to_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Keys {
        a_seed: Secret32,
        a: [u8; 32],
        b: [u8; 32],
    }

    fn keys() -> Keys {
        let a_seed = crypto::random_secret();
        let b_seed = crypto::random_secret();
        Keys {
            a: public_key(&a_seed),
            b: public_key(&b_seed),
            a_seed,
        }
    }

    fn msg<'a>(k: &'a Keys, link: &'a LinkId, n: u64, text: &str) -> NewMessage<'a> {
        NewMessage {
            link,
            seed: &k.a_seed,
            author: k.a,
            recipient: k.b,
            parents: vec![MessageId([2; 32])],
            lamport: 5,
            ts: 7,
            n,
            kind: MessageType::Text,
            body: Body::Text(text.into()),
        }
    }

    #[test]
    fn id_is_recomputed_and_tamper_detected() {
        let k = keys();
        let link = LinkId([1; 32]);
        let (pt, env, core) = build(msg(&k, &link, 1, "hi")).unwrap();
        let (env2, core2) = open(&pt).unwrap();
        assert_eq!(env, env2);
        assert_eq!(core, core2);
        assert!(verify_envelope(&link, &env2, &core2, &k.b));
        // One substituted byte of core → a different ID
        let mut bad = env.clone();
        let n = bad.core.len();
        bad.core[n - 1] ^= 1;
        assert!(open(&antenna_proto::to_cbor(&bad).unwrap()).is_err());
        // Same text, different IDs (salt)
        let (_, env3, _) = build(msg(&k, &link, 1, "hi")).unwrap();
        assert_ne!(env.id, env3.id);
    }

    /// The signature is bound to the link, the recipient, the counter and the content (SPEC §7): any substitution
    /// is rejected.
    #[test]
    fn signature_binds_link_recipient_counter_and_content() {
        let k = keys();
        let link = LinkId([1; 32]);
        let (_, env, core) = build(msg(&k, &link, 3, "pay 10")).unwrap();
        assert!(verify_envelope(&link, &env, &core, &k.b));
        // Different link
        assert!(!verify_envelope(&LinkId([9; 32]), &env, &core, &k.b));
        // Different recipient (forwarding to a third party as if addressed to them)
        assert!(!verify_envelope(&link, &env, &core, &[7; 32]));
        // Different counter
        let mut c2 = core.clone();
        c2.n = 4;
        assert!(!verify_envelope(&link, &env, &c2, &k.b));
        // Different content with a recomputed ID but the old signature
        let mut c3 = core.clone();
        c3.body = Body::Text("pay 1000".into());
        let mut e3 = env.clone();
        e3.core = antenna_proto::to_cbor(&c3).unwrap();
        e3.id = message_id(&e3.core);
        let (e3, c3) = open_envelope(e3).unwrap();
        assert!(!verify_envelope(&link, &e3, &c3, &k.b));
        // Corrupted signature, no signature, a MAC instead of a signature
        let mut e4 = env.clone();
        if let Some(Auth::Sig(s)) = &mut e4.auth {
            s[10] ^= 1;
        }
        assert!(!verify_envelope(&link, &e4, &core, &k.b));
        let mut e5 = env.clone();
        e5.auth = None;
        assert!(!verify_envelope(&link, &e5, &core, &k.b));
        e5.auth = Some(Auth::Mac(vec![0; 32]));
        assert!(!verify_envelope(&link, &e5, &core, &k.b));
        // Foreign author: signed by A, but core has B's key
        let mut c6 = core.clone();
        c6.author = k.b;
        assert!(!verify_envelope(&link, &env, &c6, &k.a));
    }

    #[test]
    fn chain_and_fingerprint_are_deterministic() {
        let a = chain_step(&CHAIN_ZERO, &MessageId([1; 32]));
        let b = chain_step(&a, &MessageId([2; 32]));
        assert_ne!(a, b);
        assert_eq!(
            b,
            chain_step(
                &chain_step(&CHAIN_ZERO, &MessageId([1; 32])),
                &MessageId([2; 32])
            )
        );
        let link = LinkId([3; 32]);
        let (d1, e1) = fingerprint(&link, &[MessageId([5; 32]), MessageId([4; 32])]);
        let (d2, e2) = fingerprint(&link, &[MessageId([4; 32]), MessageId([5; 32])]);
        assert_eq!((d1.clone(), e1.clone()), (d2, e2));
        assert_eq!(d1.len(), 3);
        assert_eq!(e1.chars().count(), 3);
        let (d3, _) = fingerprint(&LinkId([4; 32]), &[MessageId([4; 32]), MessageId([5; 32])]);
        let (d4, _) = fingerprint(&link, &[MessageId([4; 32])]);
        // A different link or different heads: almost always a different fingerprint (1000 values)
        assert!(d3 != d1 || d4 != d1);
    }

    /// The second rekey code names a specific answer: a different answer to the same offer almost always gives a
    /// different code, and it does not match the first code (a different HKDF label).
    #[test]
    fn rekey_confirm_code_names_the_answer() {
        let link = LinkId([7; 32]);
        let bundle = [1u8; 32];
        let first = rekey_code(&link, &bundle);
        let codes: std::collections::HashSet<String> = (0u8..50)
            .map(|i| rekey_confirm_code(&link, &bundle, &[i; 32]))
            .collect();
        assert!(codes.len() >= 49, "{codes:?}");
        assert!(
            codes
                .iter()
                .all(|c| c.len() == 6 && c.bytes().all(|b| b.is_ascii_digit()))
        );
        assert_eq!(
            rekey_confirm_code(&link, &bundle, &[3; 32]),
            rekey_confirm_code(&link, &bundle, &[3; 32])
        );
        assert!(!codes.contains(&first) || codes.len() == 50);
        assert_ne!(
            rekey_confirm_code(&link, &bundle, &[3; 32]),
            rekey_confirm_code(&LinkId([8; 32]), &bundle, &[3; 32])
        );
    }

    /// Test vectors of PROTOCOL.md appendix B (checked against the independent `docs/protocol_vectors.py` in Python:
    /// `blake3` and `cryptography`).
    #[test]
    fn history_vectors_appendix_b() {
        let hex = |b: &[u8]| data_encoding::HEXLOWER.encode(b);
        let core = b"core-bytes-of-the-envelope";
        assert_eq!(
            hex(&message_id(core).0),
            "7b68fc614f894f083963a6af39c0c8459e5c02b13f0abc0269322314e4637d28"
        );
        let seed = zeroize::Zeroizing::new([0x77u8; 32]);
        assert_eq!(
            hex(&public_key(&seed)),
            "c853ad0f0cd2b619aea92ceec4fd56a24d6499d584ce79257e45cfd8139b60a7"
        );
        let m = sig_message(&LinkId([0x33; 32]), &[0x44; 32], 2, core);
        assert_eq!(
            hex(&crypto::sha256(&[&m])),
            "9e57db6810f59356a55fb9280de1ca49cfea518a81b00a21a161da488f953bf9"
        );
        assert_eq!(
            hex(&sign(&seed, &m)),
            "7770c44ef6acffd3dc5dd97e7f981f2060586e3897a9b19f87ac4418d397cab8\
             05bc844c8daf05d6bd23e1a8918789f2d77d4b194874a42274be6fd79ff2590c"
        );
        let c1 = chain_step(&CHAIN_ZERO, &MessageId([0x11; 32]));
        let c2 = chain_step(&c1, &MessageId([0x22; 32]));
        assert_eq!(
            hex(&c1),
            "714b85e3169bcc51d0f7979feda9bbf246c362b16312d056815d5f4f6a6fc455"
        );
        assert_eq!(
            hex(&c2),
            "b30e9e7717a0c85b1b150d691bfce0a8e8a33dceb34978b8358c4017adf36779"
        );
        let (d, e) = fingerprint(
            &LinkId([0x33; 32]),
            &[MessageId([0x55; 32]), MessageId([0x44; 32])],
        );
        assert_eq!(
            (d.as_str(), e.as_str()),
            ("809", "\u{1F43C}\u{1F436}\u{1F413}")
        );
    }

    #[test]
    fn seal_unseal_bucket_sizes() {
        let enc = Encrypted {
            kind: 2,
            bytes: vec![9; 105],
        };
        let blob_bytes = seal(&LinkId([3; 32]), &enc).unwrap();
        let blob: RoutingBlob = antenna_proto::from_cbor(&blob_bytes).unwrap();
        assert_eq!(blob.ct.len(), 256);
        let (k, b) = unseal(&blob).unwrap();
        assert_eq!((k, b), (2, vec![9; 105]));
        let big = Encrypted {
            kind: 3,
            bytes: vec![1; 1759],
        };
        let blob: RoutingBlob =
            antenna_proto::from_cbor(&seal(&LinkId([3; 32]), &big).unwrap()).unwrap();
        assert_eq!(blob.ct.len(), 4096);
        // A v0 format blob (slices 1–2) is rejected
        let mut old = blob.clone();
        old.v = ProtocolVersion::V0;
        assert!(unseal(&old).is_err());
    }

    #[test]
    fn unsorted_parents_rejected() {
        let k = keys();
        let link = LinkId([1; 32]);
        let (_, mut env, mut core) = build(msg(&k, &link, 1, "x")).unwrap();
        core.parents = vec![MessageId([9; 32]), MessageId([1; 32])];
        env.core = antenna_proto::to_cbor(&core).unwrap();
        env.id = message_id(&env.core);
        assert!(open(&antenna_proto::to_cbor(&env).unwrap()).is_err());
    }
}
