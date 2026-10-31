// SPDX-License-Identifier: AGPL-3.0-only
//! Pairing v0 (SPEC §6; specification in `docs/PROTOCOL.md` §3–§11).
//!
//! Pure protocol functions (PSK-MAC, commitment, transcript hash, keys, SAS) live in [`calc`]; the formal model reads
//! the same functions. The state machines are [`run_inviter`] (A) and [`run_joiner`] (B). The owner takes part
//! through [`Ui`]: events go to the control socket client, input (the code at B, the confirmation at A) comes back.
//! A network-level "B confirmed" turns nothing on by itself: A sends M6 only after the owner's local decision.

use std::{
    sync::{Arc, RwLock},
    time::{Duration, Instant},
};

use antenna_proto::{
    LinkId,
    control::{Event, Input, code},
    invite::InviteLink,
    link::ALPN_LINK,
    pairing::{
        ALPN_PAIR, AddrHints, B32, CLOSE_NOT_PQ, EXPORTER_LABEL, KX_GROUP, MAX_ATTEMPTS, MAX_FRAME,
        PairMsg, Party, SUITE, label,
    },
};
use iroh::{Endpoint, EndpointId, SecretKey, endpoint::Connection};
use libsignal_protocol::IdentityKey;
use tokio::sync::mpsc;
use zeroize::Zeroizing;

use crate::{
    crypto::{self, Secret32},
    e2e::{self, PairingE2e},
    error::{Error, Result},
    now_ms,
    store::{NetMode, NewLink, PairRole},
    transport::{self, EpMode, EpParams, NetConfig, PairGuard},
};

/// Pairing protocol version. v1 (slice 2, formal model F-3): `psk_mac` covers the whole M1 body.
pub const VERSION: u16 = 1;
/// Timeout of an automatic step.
pub const STEP_TIMEOUT: Duration = Duration::from_secs(30);
/// How long B waits for owner A's decision.
pub const OWNER_WAIT: Duration = Duration::from_secs(600);
/// Maximum invite TTL.
pub const MAX_TTL: Duration = Duration::from_secs(24 * 3600);
/// How long to wait for the endpoint to come online (relay).
pub const ONLINE_TIMEOUT: Duration = Duration::from_secs(20);

/// Protocol computations (`docs/PROTOCOL.md` §7). Only combinations of established constructions.
pub mod calc {
    use super::*;

    /// The M1 body covered by `psk_mac` (everything except `psk_mac` itself).
    pub struct M1Body<'a> {
        /// Version.
        pub v: u16,
        /// Algorithm suite.
        pub suite: &'a str,
        /// `C_B`.
        pub commit: &'a [u8; 32],
        /// `P_B` together with `addrs`.
        pub party: &'a Party,
    }

    /// `addrs(a)`: route hints, unambiguously: `0` (no relay) or `1 ‖ lp(relay)`, then
    /// `u32be(n) ‖ lp(d_1) … lp(d_n)`.
    pub fn addrs_bytes(a: &AddrHints) -> Vec<u8> {
        let mut v = Vec::new();
        match &a.relay {
            None => v.push(0),
            Some(r) => {
                v.push(1);
                v.extend_from_slice(&crypto::lp(r.as_bytes()));
            }
        }
        v.extend_from_slice(&(a.direct.len() as u32).to_be_bytes());
        for d in &a.direct {
            v.extend_from_slice(&crypto::lp(d.as_bytes()));
        }
        v
    }

    /// `K_psk = HKDF(salt, s, info)`;
    /// `psk_mac = HMAC(K_psk, label ‖ X ‖ E_A ‖ E_B ‖ u16be(v) ‖ lp(suite) ‖ C_B ‖ party(P_B) ‖ addrs(P_B.addrs))`.
    pub fn psk_mac(
        s: &[u8; 32],
        x: &[u8; 32],
        e_a: &[u8; 32],
        e_b: &[u8; 32],
        m1: &M1Body<'_>,
    ) -> [u8; 32] {
        let k = crypto::hkdf32(label::PSK_SALT, s, &[label::PSK_KEY]);
        crypto::hmac(
            k.as_slice(),
            &[
                label::PSK_PROOF,
                x,
                e_a,
                e_b,
                &m1.v.to_be_bytes(),
                &crypto::lp(m1.suite.as_bytes()),
                m1.commit,
                &party_bytes(m1.party),
                &addrs_bytes(&m1.party.addrs),
            ],
        )
    }

    /// `C_B = H(label ‖ X ‖ N_B)`.
    pub fn commit(x: &[u8; 32], n_b: &[u8; 32]) -> [u8; 32] {
        crypto::sha256(&[label::COMMIT, x, n_b])
    }

    /// `party(P) = lp(identity_key) ‖ root_ed25519 ‖ lp(root_mldsa65) ‖ endpoint`.
    pub fn party_bytes(p: &Party) -> Vec<u8> {
        let mut v = crypto::lp(&p.identity_key);
        v.extend_from_slice(&p.root_ed25519);
        v.extend_from_slice(&crypto::lp(&p.root_mldsa65));
        v.extend_from_slice(&p.endpoint);
        v
    }

    /// Transcript hash inputs.
    pub struct TranscriptInput<'a> {
        /// Version.
        pub v: u16,
        /// TLS group.
        pub kx: &'a str,
        /// `E_A`.
        pub e_a: &'a [u8; 32],
        /// `E_B`.
        pub e_b: &'a [u8; 32],
        /// TLS exporter.
        pub x: &'a [u8; 32],
        /// `C_B`.
        pub c_b: &'a [u8; 32],
        /// `N_A`.
        pub n_a: &'a [u8; 32],
        /// `N_B`.
        pub n_b: &'a [u8; 32],
        /// `P_A`.
        pub p_a: &'a Party,
        /// `P_B`.
        pub p_b: &'a Party,
    }

    /// `TH`.
    pub fn transcript(t: &TranscriptInput<'_>) -> [u8; 32] {
        let v = t.v.to_be_bytes();
        let suite = crypto::lp(SUITE.as_bytes());
        let kx = crypto::lp(t.kx.as_bytes());
        let pa = party_bytes(t.p_a);
        let pb = party_bytes(t.p_b);
        crypto::sha256(&[
            label::TRANSCRIPT,
            &v,
            &suite,
            &kx,
            t.e_a,
            t.e_b,
            t.x,
            t.c_b,
            t.n_a,
            t.n_b,
            &pa,
            &pb,
        ])
    }

    /// Pairing session keys.
    pub struct Keys {
        /// `K_A`.
        pub k_a: Secret32,
        /// `K_B`.
        pub k_b: Secret32,
        /// `link_id`.
        pub link_id: [u8; 32],
    }

    /// `PRK = HKDF-Extract(label, X ‖ s)`; `K_A`, `K_B`, `link_id` = HKDF-Expand(PRK, label ‖ TH).
    pub fn keys(x: &[u8; 32], s: &[u8; 32], th: &[u8; 32]) -> Keys {
        let mut ikm = Zeroizing::new([0u8; 64]);
        ikm[..32].copy_from_slice(x);
        ikm[32..].copy_from_slice(s);
        let prk = crypto::hkdf_extract(label::PRK, ikm.as_slice());
        Keys {
            k_a: crypto::hkdf_expand(&prk, &[label::KEY_A, th]),
            k_b: crypto::hkdf_expand(&prk, &[label::KEY_B, th]),
            link_id: *crypto::hkdf_expand(&prk, &[label::LINK_ID, th]),
        }
    }

    /// `HMAC(K, label ‖ TH)`.
    pub fn mac(k: &Secret32, lbl: &[u8], th: &[u8; 32]) -> [u8; 32] {
        crypto::hmac(k.as_slice(), &[lbl, th])
    }

    /// SAS: 6 digits from `HKDF(salt, TH, info, 4) mod 10^6`.
    pub fn sas(th: &[u8; 32]) -> String {
        let b = crypto::hkdf32(label::SAS_SALT, th, &[label::SAS_INFO]);
        let n = u32::from_be_bytes([b[0], b[1], b[2], b[3]]) % 1_000_000;
        format!("{n:06}")
    }
}

/// Owner channel: events out, input in.
pub struct Ui {
    /// Events to the client.
    pub events: mpsc::UnboundedSender<Event>,
    /// Owner input. Closing the channel = the owner left (refusal).
    pub inputs: mpsc::UnboundedReceiver<Input>,
}

impl Ui {
    fn emit(&self, e: Event) {
        let _ = self.events.send(e);
    }
}

/// The shared "only allowed key" of a pairwise endpoint: nobody until pairing ends.
#[derive(Debug, Clone, Default)]
pub struct PeerSlot(pub Arc<RwLock<Option<EndpointId>>>);

impl PeerSlot {
    /// Current key.
    pub fn get(&self) -> Option<EndpointId> {
        *self.0.read().expect("peer slot lock")
    }
    /// Pin the contact's key.
    pub fn set(&self, id: EndpointId) {
        *self.0.write().expect("peer slot lock") = Some(id);
    }
}

/// Pairwise endpoint accept-list over a [`PeerSlot`] (rejects everyone before activation).
#[derive(Debug, Clone)]
pub struct SlotGuard(pub PeerSlot);

impl iroh::endpoint::EndpointHooks for SlotGuard {
    async fn after_handshake<'a>(
        &'a self,
        conn: &'a Connection,
    ) -> iroh::endpoint::AfterHandshakeOutcome {
        match self.0.get() {
            Some(peer) => transport::LinkGuard { peer }.after_handshake(conn).await,
            None => iroh::endpoint::AfterHandshakeOutcome::Reject {
                error_code: antenna_proto::link::CLOSE_NOT_PAIRED.into(),
                reason: Vec::new(),
            },
        }
    }
}

/// A side's keys for one link (created for a single pairing attempt).
pub struct LocalKeys {
    identity: libsignal_protocol::IdentityKeyPair,
    registration_id: u32,
    root_ed25519_seed: Secret32,
    root_ed25519_pk: [u8; 32],
    root_mldsa_seed: Secret32,
    root_mldsa_vk: Vec<u8>,
    ep_seed: Secret32,
    /// Pairwise endpoint (already up; accepts connections only after activation).
    pub endpoint: Endpoint,
    /// Network mode of the pairwise endpoint.
    pub mode: EpMode,
    /// Slot for the contact's key.
    pub slot: PeerSlot,
    relay_enabled: bool,
}

impl LocalKeys {
    /// Generates the link keys and brings up the pairwise endpoint.
    pub async fn generate(net: &NetConfig, trust: u8) -> Result<Self> {
        let (identity, registration_id) = e2e::new_identity();
        let root_ed25519_seed = crypto::random_secret();
        let root_ed25519_pk = ed25519_dalek::SigningKey::from_bytes(&root_ed25519_seed)
            .verifying_key()
            .to_bytes();
        let root_mldsa_seed = crypto::random_secret();
        let root_mldsa_vk = libcrux_ml_dsa::ml_dsa_65::generate_key_pair(*root_mldsa_seed)
            .verification_key
            .as_slice()
            .to_vec();
        let ep_seed = crypto::random_secret();
        let mode = match NetMode::for_trust(trust) {
            NetMode::RelayOnly => EpMode::RelayOnly,
            NetMode::Direct => EpMode::Direct,
        };
        let slot = PeerSlot::default();
        let endpoint = transport::bind(
            net,
            EpParams {
                secret: SecretKey::from_bytes(&ep_seed),
                mode,
                port: None,
                hooks: SlotGuard(slot.clone()),
                alpns: vec![ALPN_LINK.to_vec()],
            },
            ONLINE_TIMEOUT,
        )
        .await?;
        Ok(Self {
            identity,
            registration_id,
            root_ed25519_seed,
            root_ed25519_pk,
            root_mldsa_seed,
            root_mldsa_vk,
            ep_seed,
            endpoint,
            mode,
            slot,
            relay_enabled: net.relay.enabled(),
        })
    }

    /// The side's public data. If there is a relay, IP addresses are not revealed before the SAS comparison: relay
    /// only; the contact learns direct addresses ("direct" mode) after activation from the `hello` frame (PROTOCOL §4,
    /// §12).
    pub fn party(&self) -> Party {
        let mut addrs = transport::addr_hints(&self.endpoint, self.mode);
        if self.relay_enabled {
            addrs.direct.clear();
        }
        Party {
            identity_key: self.identity.identity_key().serialize().to_vec(),
            root_ed25519: self.root_ed25519_pk,
            root_mldsa65: self.root_mldsa_vk.clone(),
            endpoint: *self.endpoint.id().as_bytes(),
            addrs,
        }
    }

    /// Close the endpoint (failure).
    pub async fn discard(self) {
        self.endpoint.close().await;
    }
}

/// Step B8 (PROTOCOL §8, §15; formal model F-1): A's bundle must carry the identity from `TH`. Without this check,
/// with broken TLS and a leaked link, B would activate a link with a man in the middle (`formal/neg_nopin.pv`).
/// libsignal then verifies the signed prekey and KEM prekey signatures with this identity (`process_bundle`).
fn check_bundle(bundle: &antenna_proto::pairing::Bundle, p_a: &Party) -> Result<()> {
    if !bundle.check_lengths() || bundle.identity_key != p_a.identity_key {
        return Err(Error::pairing("bundle identity differs from transcript"));
    }
    Ok(())
}

/// Checks the contact's public data.
fn check_party(p: &Party, own: &Party) -> Result<()> {
    if !p.check_lengths() {
        return Err(Error::pairing("peer keys have wrong lengths"));
    }
    IdentityKey::decode(&p.identity_key).map_err(|_| Error::pairing("bad peer identity key"))?;
    ed25519_dalek::VerifyingKey::from_bytes(&p.root_ed25519)
        .map_err(|_| Error::pairing("bad peer root key"))?;
    iroh::PublicKey::from_bytes(&p.endpoint)
        .map_err(|_| Error::pairing("bad peer endpoint key"))?;
    // Reflection of our own keys (the attacker returned our own P to us)
    if p.endpoint == own.endpoint
        || p.identity_key == own.identity_key
        || p.root_ed25519 == own.root_ed25519
    {
        return Err(Error::pairing("peer reflected our own keys"));
    }
    Ok(())
}

/// Result of a successful pairing.
pub struct Paired {
    /// Final contact label.
    pub label: String,
    /// Link ID.
    pub link_id: LinkId,
    /// Trust level.
    pub trust: u8,
    /// Network mode.
    pub net_mode: NetMode,
    /// TLS group during pairing.
    pub kx_group: String,
    /// Time from session start to activation, ms.
    pub pairing_ms: u64,
    /// Pairwise endpoint (the accept-list is already pinned to the contact).
    pub endpoint: Endpoint,
    /// Slot for the contact's key.
    pub slot: PeerSlot,
    /// The contact's address hints.
    pub peer_addrs: AddrHints,
    /// The contact's EndpointId.
    pub peer_endpoint: EndpointId,
}

/// Saving the link (called exactly at activation, before the last message at A).
pub type Persist<'a> = Box<dyn FnOnce(&NewLink) -> Result<String> + Send + 'a>;

// Pairing message channel over a single bi-stream

struct Chan {
    conn: Connection,
    send: iroh::endpoint::SendStream,
    rx: mpsc::Receiver<Result<PairMsg>>,
}

impl Chan {
    fn new(
        conn: Connection,
        send: iroh::endpoint::SendStream,
        mut recv: iroh::endpoint::RecvStream,
    ) -> Self {
        // A separate reader task: reading frames is not interrupted by select! (read_exact is not cancel-safe)
        let (tx, rx) = mpsc::channel(4);
        tokio::spawn(async move {
            loop {
                let r = match transport::read_frame(&mut recv, MAX_FRAME).await {
                    Ok(b) => antenna_proto::from_cbor::<PairMsg>(&b)
                        .map_err(|e| Error::pairing(format!("malformed message: {e}"))),
                    Err(e) => Err(e),
                };
                let stop = r.is_err();
                if tx.send(r).await.is_err() || stop {
                    break;
                }
            }
        });
        Self { conn, send, rx }
    }

    async fn send(&mut self, m: &PairMsg) -> Result<()> {
        let b = antenna_proto::to_cbor(m)?;
        transport::write_frame(&mut self.send, &b).await
    }

    async fn recv(&mut self, timeout: Duration) -> Result<PairMsg> {
        match tokio::time::timeout(timeout, self.rx.recv()).await {
            Err(_) => Err(Error::new(code::TIMEOUT, "peer did not answer in time")),
            Ok(None) => Err(Error::network("pairing connection closed")),
            Ok(Some(Err(e))) => Err(e),
            Ok(Some(Ok(PairMsg::Abort { reason }))) => Err(peer_abort(&reason)),
            Ok(Some(Ok(m))) => Ok(m),
        }
    }

    /// Send a refusal and let it arrive.
    async fn abort(mut self, reason: &str) {
        let _ = self
            .send(&PairMsg::Abort {
                reason: reason.into(),
            })
            .await;
        let _ = self.send.finish();
        let _ = tokio::time::timeout(Duration::from_secs(2), self.conn.closed()).await;
        self.conn.close(0u32.into(), b"");
    }

    /// The last message was sent: wait until the other side closes the connection (up to 5 s).
    async fn finish(mut self) {
        let _ = self.send.finish();
        let _ = tokio::time::timeout(Duration::from_secs(5), self.conn.closed()).await;
        self.conn.close(0u32.into(), b"");
    }

    /// The last message was received: close immediately.
    fn close_now(mut self) {
        let _ = self.send.finish();
        self.conn.close(0u32.into(), b"");
    }
}

fn peer_abort(reason: &str) -> Error {
    match reason {
        "sas_mismatch" => Error::new(
            code::SAS_MISMATCH,
            "the code was entered incorrectly; the invite is burned",
        ),
        "owner_rejected" => Error::new(code::REJECTED, "the other owner rejected the link"),
        // A string from the peer is never shown to a human as is (terminal injection)
        r if antenna_proto::pairing::ABORT_REASONS.contains(&r) => {
            Error::pairing(format!("peer aborted: {r}"))
        }
        _ => Error::pairing("peer aborted: <unknown reason>"),
    }
}

/// How long to wait: no longer than `t` and no longer than the invite lives.
fn left(expires: Instant, t: Duration) -> Duration {
    t.min(expires.saturating_duration_since(Instant::now()))
}

/// Owner input sent in advance (before the question) does not count as a decision.
fn drain_inputs(ui: &mut Ui) {
    while ui.inputs.try_recv().is_ok() {}
}

fn unexpected(m: &PairMsg) -> Error {
    Error::pairing(format!("unexpected message {}", m.name()))
}

fn exporter(conn: &Connection) -> Result<[u8; 32]> {
    let mut x = [0u8; 32];
    conn.export_keying_material(&mut x, EXPORTER_LABEL, b"")
        .map_err(|e| Error::internal(format!("tls exporter: {e:?}")))?;
    Ok(x)
}

fn ep_bytes(id: EndpointId) -> [u8; 32] {
    *id.as_bytes()
}

#[allow(
    clippy::too_many_arguments,
    reason = "the fields of the link record come from different pairing steps"
)]
fn new_link_record(
    role: PairRole,
    trust: u8,
    label_: Option<String>,
    link_id: LinkId,
    th: [u8; 32],
    keys: &LocalKeys,
    peer: &Party,
    ex: e2e::E2eExport,
    sig_local: String,
    sig_remote: String,
) -> NewLink {
    NewLink {
        link_id,
        role,
        label: label_,
        trust,
        transcript_hash: th,
        pairing_kx: KX_GROUP.into(),
        local_secret: Zeroizing::new(*keys.ep_seed),
        peer_endpoint: peer.endpoint,
        peer_addrs: peer.addrs.clone(),
        root_ed25519_seed: Zeroizing::new(*keys.root_ed25519_seed),
        root_ed25519_pk: keys.root_ed25519_pk,
        root_mldsa_seed: Zeroizing::new(*keys.root_mldsa_seed),
        root_mldsa_vk: keys.root_mldsa_vk.clone(),
        peer_root_ed25519: peer.root_ed25519,
        peer_root_mldsa: peer.root_mldsa65.clone(),
        sig_local_addr: sig_local,
        sig_remote_addr: sig_remote,
        sig_identity_keypair: ex.identity_keypair,
        sig_registration_id: ex.registration_id,
        sig_remote_identity: ex.remote_identity,
        sig_session_record: ex.session_record,
    }
}

// A: invite

/// A live invite.
pub struct Invite {
    /// Link (contains a secret; do not log).
    pub link: InviteLink,
    /// Ephemeral endpoint.
    pub endpoint: Endpoint,
    /// When it burns.
    pub expires: Instant,
    /// When it burns, Unix ms.
    pub expires_ms: u64,
    /// A's link keys (P_A is revealed only after a correct PSK).
    pub keys: LocalKeys,
    /// Trust level.
    pub trust: u8,
}

/// Creates an invite: ephemeral endpoint, secret, link (`docs/PROTOCOL.md` §3–§4).
pub async fn create_invite(net: &NetConfig, trust: u8, ttl: Duration) -> Result<Invite> {
    if !(1..=5).contains(&trust) {
        return Err(Error::bad_request("trust must be 1..5"));
    }
    if ttl.is_zero() || ttl > MAX_TTL {
        return Err(Error::bad_request("ttl must be between 1s and 24h"));
    }
    let mode = if net.relay.enabled() {
        EpMode::RelayOnly
    } else {
        EpMode::Direct
    };
    // The pairwise and the ephemeral endpoint come up in parallel: each waits to come online via relay
    let (keys, endpoint) = tokio::join!(
        LocalKeys::generate(net, trust),
        transport::bind(
            net,
            EpParams {
                secret: SecretKey::generate(),
                mode,
                port: None,
                hooks: PairGuard,
                alpns: vec![ALPN_PAIR.to_vec()],
            },
            ONLINE_TIMEOUT,
        )
    );
    let (keys, endpoint) = match (keys, endpoint) {
        (Ok(k), Ok(e)) => (k, e),
        (Ok(k), Err(e)) => {
            k.discard().await;
            return Err(e);
        }
        (Err(e), Ok(ep)) => {
            ep.close().await;
            return Err(e);
        }
        (Err(e), Err(_)) => return Err(e),
    };
    let a = endpoint.addr();
    let link = InviteLink {
        endpoint: ep_bytes(endpoint.id()),
        secret: crypto::random::<32>(),
        relay: a.relay_urls().next().map(|u| u.to_string()),
        direct: if net.relay.enabled() {
            Vec::new()
        } else if net.bind_ip.is_some() {
            endpoint.bound_sockets()
        } else {
            // Without an explicit bind_ip the socket listens on 0.0.0.0, so the real interface addresses go into the
            // link
            a.ip_addrs()
                .filter(|s| !s.ip().is_unspecified())
                .copied()
                .collect()
        },
    };
    Ok(Invite {
        link,
        endpoint,
        expires: Instant::now() + ttl,
        expires_ms: now_ms() + ttl.as_millis() as u64,
        keys,
        trust,
    })
}

enum SessionErr {
    /// A failed attempt before the secret check: the invite lives.
    Attempt(String),
    /// After the secret check: the invite burns.
    Fatal(Error),
}

/// Side A: accepts connections to the invite until success, burning or TTL expiry.
pub async fn run_inviter(
    inv: Invite,
    label_: Option<String>,
    auto_confirm: bool,
    ui: &mut Ui,
    persist: Persist<'_>,
) -> Result<Paired> {
    let Invite {
        link,
        endpoint,
        expires,
        keys,
        trust,
        ..
    } = inv;
    let secret = Zeroizing::new(link.secret);
    let mut attempts = 0u32;
    let mut keys = Some(keys);
    let mut persist = Some(persist);
    let result = loop {
        let incoming = tokio::select! {
            _ = tokio::time::sleep_until(expires.into()) => {
                break Err(Error::new(code::INVITE_UNAVAILABLE, "the invite expired"));
            }
            inc = endpoint.accept() => inc,
            _ = owner_left(ui) => {
                break Err(Error::new(code::REJECTED, "invite cancelled by owner"));
            }
        };
        let Some(incoming) = incoming else {
            break Err(Error::network("invite endpoint closed"));
        };
        let accepting = match incoming.accept() {
            Ok(a) => a,
            Err(_) => continue,
        };
        let conn = match tokio::time::timeout(STEP_TIMEOUT, accepting).await {
            Ok(Ok(c)) => c,
            _ => {
                attempts += 1;
                ui.emit(Event::AttemptFailed {
                    attempts,
                    max: MAX_ATTEMPTS,
                    reason: "handshake".into(),
                });
                if attempts >= MAX_ATTEMPTS {
                    break Err(Error::new(
                        code::INVITE_UNAVAILABLE,
                        "too many failed attempts; the invite is burned",
                    ));
                }
                continue;
            }
        };
        let started = Instant::now();
        let r = {
            let session = inviter_session(
                conn,
                &endpoint,
                &secret,
                &mut keys,
                trust,
                label_.clone(),
                auto_confirm,
                ui,
                &mut persist,
                started,
                expires,
            );
            tokio::pin!(session);
            // While a session is running, other connections are rejected without a handshake
            loop {
                tokio::select! {
                    r = &mut session => break r,
                    inc = endpoint.accept() => {
                        if let Some(i) = inc {
                            i.refuse();
                        }
                    }
                }
            }
        };
        match r {
            Ok(p) => break Ok(p),
            Err(SessionErr::Attempt(reason)) => {
                attempts += 1;
                tracing::info!("invite: failed attempt {attempts}/{MAX_ATTEMPTS}: {reason}");
                ui.emit(Event::AttemptFailed {
                    attempts,
                    max: MAX_ATTEMPTS,
                    reason,
                });
                if attempts >= MAX_ATTEMPTS {
                    break Err(Error::new(
                        code::INVITE_UNAVAILABLE,
                        "too many failed attempts; the invite is burned",
                    ));
                }
            }
            Err(SessionErr::Fatal(e)) => break Err(e),
        }
    };
    // The invite burns in any case: the ephemeral endpoint is closed, the secret is wiped (drop)
    endpoint.close().await;
    if result.is_err()
        && let Some(k) = keys.take()
    {
        k.discard().await;
    }
    result
}

async fn owner_left(ui: &mut Ui) {
    // No input is expected before the session starts; a closed channel = the owner closed `antenna invite`
    loop {
        match ui.inputs.recv().await {
            None => return,
            Some(Input::Confirm { yes: false, .. }) => return,
            Some(_) => continue,
        }
    }
}

#[allow(
    clippy::too_many_arguments,
    reason = "the inviter's pairing state (keys, owner input, persistence, deadlines) threaded through its steps"
)]
async fn inviter_session(
    conn: Connection,
    endpoint: &Endpoint,
    s: &[u8; 32],
    keys_slot: &mut Option<LocalKeys>,
    trust: u8,
    label_: Option<String>,
    auto_confirm: bool,
    ui: &mut Ui,
    persist: &mut Option<Persist<'_>>,
    started: Instant,
    expires: Instant,
) -> std::result::Result<Paired, SessionErr> {
    // TTL bounds all waits up to M6; once the link is saved, the session can no longer be aborted by TTL.
    // The TLS group was checked by the PairGuard hook; check again explicitly (protection against changes to hooks)
    if !transport::is_pq(&conn) {
        conn.close(CLOSE_NOT_PQ.into(), b"");
        return Err(SessionErr::Attempt("non-PQ TLS group".into()));
    }
    let x = exporter(&conn).map_err(SessionErr::Fatal)?;
    let e_a = ep_bytes(endpoint.id());
    let e_b = ep_bytes(conn.remote_id());
    let (send, recv) = match tokio::time::timeout(STEP_TIMEOUT, conn.accept_bi()).await {
        Ok(Ok(sr)) => sr,
        _ => return Err(SessionErr::Attempt("no stream".into())),
    };
    let mut ch = Chan::new(conn, send, recv);
    // M1
    let (c_b, p_b) = match ch.recv(left(expires, STEP_TIMEOUT)).await {
        Ok(PairMsg::Join {
            v,
            suite,
            psk_mac,
            commit,
            party,
        }) => {
            if v != VERSION {
                ch.abort("version").await;
                return Err(SessionErr::Attempt("version".into()));
            }
            if suite != SUITE {
                ch.abort("suite").await;
                return Err(SessionErr::Attempt("suite".into()));
            }
            let body = calc::M1Body {
                v,
                suite: &suite,
                commit: &commit.0,
                party: &party,
            };
            if !crypto::ct_eq(&psk_mac.0, &calc::psk_mac(s, &x, &e_a, &e_b, &body)) {
                ch.abort("auth").await;
                return Err(SessionErr::Attempt("wrong link secret".into()));
            }
            (commit.0, party)
        }
        Ok(m) => {
            ch.abort("protocol").await;
            return Err(SessionErr::Attempt(format!("unexpected {}", m.name())));
        }
        Err(e) => {
            ch.abort("timeout").await;
            return Err(SessionErr::Attempt(e.message));
        }
    };
    // From here on the invite is used up: any error is Fatal
    let keys = keys_slot
        .as_ref()
        .ok_or_else(|| SessionErr::Fatal(Error::internal("invite keys already used")))?;
    let p_a = keys.party();
    let fail = |e: Error| SessionErr::Fatal(e);
    if let Err(e) = check_party(&p_b, &p_a) {
        ch.abort("protocol").await;
        return Err(fail(e));
    }
    let n_a = crypto::random::<32>();
    ch.send(&PairMsg::Offer {
        party: p_a.clone(),
        nonce: B32(n_a),
    })
    .await
    .map_err(fail)?;
    // M3
    let (n_b, kc_b) = match ch.recv(left(expires, STEP_TIMEOUT)).await.map_err(fail)? {
        PairMsg::Reveal { nonce, kc } => (nonce.0, kc.0),
        m => {
            ch.abort("protocol").await;
            return Err(fail(unexpected(&m)));
        }
    };
    if !crypto::ct_eq(&calc::commit(&x, &n_b), &c_b) {
        ch.abort("commit").await;
        return Err(fail(Error::pairing("commitment does not open")));
    }
    let th = calc::transcript(&calc::TranscriptInput {
        v: VERSION,
        kx: KX_GROUP,
        e_a: &e_a,
        e_b: &e_b,
        x: &x,
        c_b: &c_b,
        n_a: &n_a,
        n_b: &n_b,
        p_a: &p_a,
        p_b: &p_b,
    });
    let k = calc::keys(&x, s, &th);
    if !crypto::ct_eq(&kc_b, &calc::mac(&k.k_b, label::KEY_CONFIRM, &th)) {
        ch.abort("key_confirm").await;
        return Err(fail(Error::pairing("key confirmation failed")));
    }
    ch.send(&PairMsg::KeyConfirm {
        kc: B32(calc::mac(&k.k_a, label::KEY_CONFIRM, &th)),
    })
    .await
    .map_err(fail)?;
    // SAS to owner A
    let code = calc::sas(&th);
    ui.emit(Event::Sas {
        emoji: antenna_proto::sas::to_emoji(&code).unwrap_or_default(),
        code,
    });
    ui.emit(Event::Waiting {
        what: "peer_code_entry".into(),
    });
    // M5: wait for the code input at B (or owner A's refusal / burning by TTL, which the outer loop counts)
    let m5 = tokio::select! {
        m = ch.recv(left(expires, OWNER_WAIT)) => match m {
            Ok(m) => m,
            Err(e) => {
                if e.code == code::TIMEOUT {
                    ch.abort("timeout").await;
                }
                return Err(fail(e));
            }
        },
        _ = owner_left(ui) => {
            ch.abort("owner_rejected").await;
            return Err(fail(Error::new(code::REJECTED, "owner rejected")));
        }
    };
    match m5 {
        PairMsg::CodeEntered { mac } => {
            if !crypto::ct_eq(&mac.0, &calc::mac(&k.k_b, label::CODE_ENTERED, &th)) {
                ch.abort("protocol").await;
                return Err(fail(Error::pairing("bad code_entered mac")));
            }
        }
        m => {
            ch.abort("protocol").await;
            return Err(fail(unexpected(&m)));
        }
    }
    ui.emit(Event::PeerEnteredCode);
    // Owner A's decision is local only (SPEC §6 item 9)
    if !auto_confirm {
        drain_inputs(ui);
        // Whether the owner may confirm without the code is the daemon's call over all its invites (`invites.rs`, D-95):
        // the invite task fills `confirm_without_code` in before the event reaches a client.
        ui.emit(Event::NeedInput {
            what: "confirm".into(),
            confirm_without_code: false,
        });
        let decision = tokio::select! {
            i = ui.inputs.recv() => i,
            // B must not send anything before M6; a timeout here = owner A did not answer before the end of TTL / 10
            // min
            m = ch.recv(left(expires, OWNER_WAIT)) => {
                let e = match m { Ok(m) => unexpected(&m), Err(e) => e };
                ch.abort(if e.code == code::TIMEOUT { "timeout" } else { "protocol" }).await;
                return Err(fail(e));
            }
        };
        match decision {
            Some(Input::Confirm { yes: true, .. }) => {}
            _ => {
                ch.abort("owner_rejected").await;
                return Err(fail(Error::new(code::REJECTED, "owner rejected the link")));
            }
        }
    }
    // M6 … M8: the link keys are taken from the invite; on any error the endpoint is closed
    let keys = keys_slot.take().expect("checked above");
    let persist = persist.take().expect("persist used once");
    let tail = InviterTail {
        k: &k,
        th: &th,
        p_b: &p_b,
        trust,
        label_,
    };
    match inviter_tail(&mut ch, &keys, tail, ui, persist).await {
        Ok((label_final, link_id)) => {
            ch.finish().await;
            finish_paired(keys, &p_b, label_final, link_id, trust, started)
        }
        Err((e, reason)) => {
            ch.abort(reason).await;
            keys.discard().await;
            Err(fail(e))
        }
    }
}

struct InviterTail<'a> {
    k: &'a calc::Keys,
    th: &'a [u8; 32],
    p_b: &'a Party,
    trust: u8,
    label_: Option<String>,
}

async fn inviter_tail(
    ch: &mut Chan,
    keys: &LocalKeys,
    t: InviterTail<'_>,
    ui: &mut Ui,
    persist: Persist<'_>,
) -> std::result::Result<(String, LinkId), (Error, &'static str)> {
    let InviterTail {
        k,
        th,
        p_b,
        trust,
        label_,
    } = t;
    let internal = |e: Error| (e, "internal");
    let link_id = LinkId(k.link_id);
    let (an, bn) = e2e::address_names(&link_id);
    let mut sig = PairingE2e::new(
        keys.identity,
        keys.registration_id,
        &an,
        &bn,
        &p_b.identity_key,
    )
    .map_err(internal)?;
    let bundle = sig.make_bundle().map_err(internal)?;
    ch.send(&PairMsg::Confirmed {
        mac: B32(calc::mac(&k.k_a, label::OWNER_CONFIRMED, th)),
        bundle,
    })
    .await
    .map_err(internal)?;
    ui.emit(Event::Waiting {
        what: "session_init".into(),
    });
    // M7
    let ct = match ch.recv(STEP_TIMEOUT).await {
        Ok(PairMsg::SessionInit { ct }) => ct,
        Ok(m) => return Err((unexpected(&m), "protocol")),
        Err(e) => return Err((e, "protocol")),
    };
    let expected_init: Vec<u8> = [label::SESSION_INIT, &th[..]].concat();
    match sig.decrypt(antenna_proto::link::e2e_type::PREKEY, &ct) {
        Ok(pt) if crypto::ct_eq(&pt, &expected_init) => {}
        _ => return Err((Error::pairing("bad session_init"), "protocol")),
    }
    // Activation at A: save atomically, then M8
    let ack: Vec<u8> = [label::SESSION_ACK, &th[..]].concat();
    let done_ct = sig.encrypt(&ack).map_err(internal)?;
    let ex = sig.export().map_err(internal)?;
    let rec = new_link_record(
        PairRole::Inviter,
        trust,
        label_,
        link_id,
        *th,
        keys,
        p_b,
        ex,
        an,
        bn,
    );
    let label_final = persist(&rec).map_err(internal)?;
    let _ = ch.send(&PairMsg::Done { ct: done_ct.bytes }).await;
    Ok((label_final, link_id))
}

fn finish_paired(
    keys: LocalKeys,
    peer: &Party,
    label_: String,
    link_id: LinkId,
    trust: u8,
    started: Instant,
) -> std::result::Result<Paired, SessionErr> {
    let peer_id = iroh::PublicKey::from_bytes(&peer.endpoint)
        .map_err(|_| SessionErr::Fatal(Error::internal("peer endpoint")))?;
    keys.slot.set(peer_id);
    Ok(Paired {
        label: label_,
        link_id,
        trust,
        net_mode: NetMode::for_trust(trust),
        kx_group: KX_GROUP.into(),
        pairing_ms: started.elapsed().as_millis() as u64,
        endpoint: keys.endpoint,
        slot: keys.slot,
        peer_addrs: peer.addrs.clone(),
        peer_endpoint: peer_id,
    })
}

// B: join

/// Side B: `antenna join <link>`.
#[allow(
    clippy::too_many_arguments,
    reason = "the options of `join` plus the network, the owner's terminal and persistence"
)]
pub async fn run_joiner(
    net: &NetConfig,
    link_str: &str,
    trust: u8,
    label_: Option<String>,
    sas_code: Option<String>,
    connect_timeout: Duration,
    ui: &mut Ui,
    persist: Persist<'_>,
) -> Result<Paired> {
    if !(1..=5).contains(&trust) {
        return Err(Error::bad_request("trust must be 1..5"));
    }
    let link = InviteLink::parse(link_str).map_err(|e| Error::bad_request(e.to_string()))?;
    let e_a_id = iroh::PublicKey::from_bytes(&link.endpoint)
        .map_err(|_| Error::bad_request("invalid invite link: endpoint key"))?;
    // B's ephemeral endpoint: the relay is the one in the link (relay only, no IP); without a relay, direct
    let eph_net = match &link.relay {
        Some(r) => NetConfig {
            relay: transport::RelayConfig::Custom(
                r.parse()
                    .map_err(|_| Error::bad_request("invalid invite link: relay"))?,
            ),
            bind_ip: net.bind_ip,
        },
        None => NetConfig {
            relay: transport::RelayConfig::Disabled,
            bind_ip: net.bind_ip,
        },
    };
    let eph_mode = if link.relay.is_some() {
        EpMode::RelayOnly
    } else {
        EpMode::Direct
    };
    let (keys, eph) = tokio::join!(
        LocalKeys::generate(net, trust),
        transport::bind(
            &eph_net,
            EpParams {
                secret: SecretKey::generate(),
                mode: eph_mode,
                port: None,
                hooks: PairGuard,
                alpns: vec![],
            },
            ONLINE_TIMEOUT,
        )
    );
    let (keys, eph) = match (keys, eph) {
        (Ok(k), Ok(e)) => (k, e),
        (Ok(k), Err(e)) => {
            k.discard().await;
            return Err(e);
        }
        (Err(e), Ok(ep)) => {
            ep.close().await;
            return Err(e);
        }
        (Err(e), Err(_)) => return Err(e),
    };
    let started = Instant::now();
    let hints = AddrHints {
        relay: link.relay.clone(),
        direct: link.direct.iter().map(|a| a.to_string()).collect(),
    };
    let r = joiner_session(
        &eph,
        e_a_id,
        &hints,
        &link.secret,
        keys,
        trust,
        label_,
        sas_code,
        connect_timeout,
        ui,
        persist,
        started,
    )
    .await;
    eph.close().await;
    r
}

#[allow(
    clippy::too_many_arguments,
    reason = "the joiner's pairing state (keys, owner input, persistence, deadlines) threaded through its steps"
)]
async fn joiner_session(
    eph: &Endpoint,
    e_a_id: EndpointId,
    hints: &AddrHints,
    secret: &[u8; 32],
    keys: LocalKeys,
    trust: u8,
    label_: Option<String>,
    sas_code: Option<String>,
    connect_timeout: Duration,
    ui: &mut Ui,
    persist: Persist<'_>,
    started: Instant,
) -> Result<Paired> {
    let conn = match tokio::time::timeout(
        connect_timeout,
        eph.connect(transport::dial_addr(e_a_id, hints), ALPN_PAIR),
    )
    .await
    {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => {
            keys.discard().await;
            return Err(Error::new(
                code::INVITE_UNAVAILABLE,
                format!("cannot reach the invite (used, expired or offline): {e}"),
            ));
        }
        Err(_) => {
            keys.discard().await;
            return Err(Error::new(
                code::INVITE_UNAVAILABLE,
                "cannot reach the invite (used, expired or offline): timeout",
            ));
        }
    };
    match joiner_inner(
        conn, eph, secret, &keys, trust, label_, sas_code, ui, persist, started,
    )
    .await
    {
        Ok((label_final, link_id, peer)) => {
            finish_paired(keys, &peer, label_final, link_id, trust, started).map_err(|e| match e {
                SessionErr::Fatal(e) => e,
                SessionErr::Attempt(r) => Error::pairing(r),
            })
        }
        Err(e) => {
            keys.discard().await;
            Err(e)
        }
    }
}

#[allow(
    clippy::too_many_arguments,
    reason = "the joiner's pairing state (keys, owner input, persistence) threaded through its steps"
)]
async fn joiner_inner(
    conn: Connection,
    eph: &Endpoint,
    s: &[u8; 32],
    keys: &LocalKeys,
    trust: u8,
    label_: Option<String>,
    sas_code: Option<String>,
    ui: &mut Ui,
    persist: Persist<'_>,
    _started: Instant,
) -> Result<(String, LinkId, Party)> {
    if !transport::is_pq(&conn) {
        conn.close(CLOSE_NOT_PQ.into(), b"");
        return Err(Error::pairing(
            "the invite endpoint did not negotiate X25519MLKEM768",
        ));
    }
    let x = exporter(&conn)?;
    let e_a = ep_bytes(conn.remote_id());
    let e_b = ep_bytes(eph.id());
    let (send, recv) = conn
        .open_bi()
        .await
        .map_err(|e| Error::network(format!("open stream: {e}")))?;
    let mut ch = Chan::new(conn, send, recv);
    let p_b = keys.party();
    let n_b = crypto::random::<32>();
    let c_b = calc::commit(&x, &n_b);
    let body = calc::M1Body {
        v: VERSION,
        suite: SUITE,
        commit: &c_b,
        party: &p_b,
    };
    ch.send(&PairMsg::Join {
        v: VERSION,
        suite: SUITE.into(),
        psk_mac: B32(calc::psk_mac(s, &x, &e_a, &e_b, &body)),
        commit: B32(c_b),
        party: p_b.clone(),
    })
    .await?;
    // M2
    let (p_a, n_a) = match ch.recv(STEP_TIMEOUT).await? {
        PairMsg::Offer { party, nonce } => (party, nonce.0),
        m => {
            ch.abort("protocol").await;
            return Err(unexpected(&m));
        }
    };
    if let Err(e) = check_party(&p_a, &p_b) {
        ch.abort("protocol").await;
        return Err(e);
    }
    let th = calc::transcript(&calc::TranscriptInput {
        v: VERSION,
        kx: KX_GROUP,
        e_a: &e_a,
        e_b: &e_b,
        x: &x,
        c_b: &c_b,
        n_a: &n_a,
        n_b: &n_b,
        p_a: &p_a,
        p_b: &p_b,
    });
    let k = calc::keys(&x, s, &th);
    ch.send(&PairMsg::Reveal {
        nonce: B32(n_b),
        kc: B32(calc::mac(&k.k_b, label::KEY_CONFIRM, &th)),
    })
    .await?;
    // M4
    match ch.recv(STEP_TIMEOUT).await? {
        PairMsg::KeyConfirm { kc } => {
            if !crypto::ct_eq(&kc.0, &calc::mac(&k.k_a, label::KEY_CONFIRM, &th)) {
                ch.abort("key_confirm").await;
                return Err(Error::pairing("key confirmation failed"));
            }
        }
        m => {
            ch.abort("protocol").await;
            return Err(unexpected(&m));
        }
    }
    // Code input by owner B (there is no "it matches" button: the code is typed, SPEC §6 item 8)
    let entered: Zeroizing<String> = match sas_code {
        Some(c) => Zeroizing::new(c),
        None => {
            drain_inputs(ui);
            ui.emit(Event::NeedInput {
                what: "sas_code".into(),
                confirm_without_code: false,
            });
            let i = tokio::select! {
                i = ui.inputs.recv() => i,
                m = ch.recv(OWNER_WAIT) => {
                    let e = match m { Ok(m) => unexpected(&m), Err(e) => e };
                    return Err(e);
                }
            };
            match i {
                Some(Input::SasCode { code }) => Zeroizing::new(code),
                _ => {
                    ch.abort("owner_rejected").await;
                    return Err(Error::new(code::REJECTED, "owner cancelled"));
                }
            }
        }
    };
    // Digits, the same emoji or animal names are one and the same code representation (Q-6, PROTOCOL §7)
    let normalized = Zeroizing::new(antenna_proto::sas::parse_input(&entered).unwrap_or_default());
    if !crypto::ct_eq(normalized.as_bytes(), calc::sas(&th).as_bytes()) {
        ch.abort("sas_mismatch").await;
        return Err(Error::new(
            code::SAS_MISMATCH,
            "the code does not match; the link is rejected and the invite is burned",
        ));
    }
    ch.send(&PairMsg::CodeEntered {
        mac: B32(calc::mac(&k.k_b, label::CODE_ENTERED, &th)),
    })
    .await?;
    ui.emit(Event::Waiting {
        what: "owner_a_confirm".into(),
    });
    // M6: owner A's confirmation
    let m6 = match ch.recv(OWNER_WAIT).await {
        Ok(m) => m,
        Err(e) => {
            if e.code == code::TIMEOUT {
                ch.abort("timeout").await;
            }
            return Err(e);
        }
    };
    let bundle = match m6 {
        PairMsg::Confirmed { mac, bundle } => {
            if !crypto::ct_eq(&mac.0, &calc::mac(&k.k_a, label::OWNER_CONFIRMED, &th)) {
                ch.abort("protocol").await;
                return Err(Error::pairing("bad owner confirmation mac"));
            }
            bundle
        }
        m => {
            ch.abort("protocol").await;
            return Err(unexpected(&m));
        }
    };
    if let Err(e) = check_bundle(&bundle, &p_a) {
        ch.abort("protocol").await;
        return Err(e);
    }
    let link_id = LinkId(k.link_id);
    let (an, bn) = e2e::address_names(&link_id);
    let mut sig = PairingE2e::new(
        keys.identity,
        keys.registration_id,
        &bn,
        &an,
        &p_a.identity_key,
    )?;
    if let Err(e) = sig.process_bundle(&bundle) {
        ch.abort("protocol").await;
        return Err(e);
    }
    let init: Vec<u8> = [label::SESSION_INIT, &th[..]].concat();
    let ct = sig.encrypt(&init)?;
    ch.send(&PairMsg::SessionInit { ct: ct.bytes }).await?;
    // M8
    let done = match ch.recv(STEP_TIMEOUT).await? {
        PairMsg::Done { ct } => ct,
        m => {
            ch.abort("protocol").await;
            return Err(unexpected(&m));
        }
    };
    let ack: Vec<u8> = [label::SESSION_ACK, &th[..]].concat();
    match sig.decrypt(antenna_proto::link::e2e_type::WHISPER, &done) {
        Ok(pt) if crypto::ct_eq(&pt, &ack) => {}
        _ => {
            ch.abort("protocol").await;
            return Err(Error::pairing("bad session ack"));
        }
    }
    let ex = sig.export()?;
    let rec = new_link_record(
        PairRole::Joiner,
        trust,
        label_,
        link_id,
        th,
        keys,
        &p_a,
        ex,
        bn,
        an,
    );
    let label_final = persist(&rec)?;
    ch.close_now();
    Ok((label_final, link_id, p_a))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// They match an independent check on the Python standard library: `docs/protocol_vectors.py`.
    const VECTORS: [(&str, &str); 8] = [
        (
            "psk_mac",
            "40e04b7f0482cebb95be72ab94c69122560e26ab40d0e8591d7e187f333874a2",
        ),
        (
            "C_B",
            "096fa366a8867f0286d2994cf692929d734a281ed0cc7f4973cd3c7484332e57",
        ),
        (
            "TH",
            "9cb46025c108ff6a309fe45c0331057da45d8ae289631958968712fbab7624da",
        ),
        (
            "K_A",
            "b31f4aa5fde46f5e5af271ca0bb472053120a97bb1526748b2e78ed623fda127",
        ),
        (
            "K_B",
            "02a0bcf3dfa72f9a88a39921c270b7d04f21e1e0835ee5164712aa107ae054d3",
        ),
        (
            "link_id",
            "bf1b744029928db4e74ae94fe2a0ce658d66407b3b149bd4c70fc7d43ddc6e7b",
        ),
        (
            "kc_B",
            "a6006f723a32891eaa84db8d1e2a0552de59de8b58de2674cf9a6ab2dc725045",
        ),
        ("SAS", "169264"),
    ];

    fn party(seed: u8) -> Party {
        Party {
            identity_key: vec![seed; 33],
            root_ed25519: [seed; 32],
            root_mldsa65: vec![seed; 1952],
            endpoint: [seed; 32],
            addrs: AddrHints::default(),
        }
    }

    #[test]
    fn transcript_binds_every_field() {
        let (pa, pb) = (party(1), party(2));
        let base = |n_b: [u8; 32], x: [u8; 32], kx: &str, pa: &Party| {
            calc::transcript(&calc::TranscriptInput {
                v: 0,
                kx,
                e_a: &[3; 32],
                e_b: &[4; 32],
                x: &x,
                c_b: &calc::commit(&x, &n_b),
                n_a: &[5; 32],
                n_b: &n_b,
                p_a: pa,
                p_b: &pb,
            })
        };
        let t0 = base([6; 32], [7; 32], KX_GROUP, &pa);
        assert_ne!(t0, base([8; 32], [7; 32], KX_GROUP, &pa), "nonce");
        assert_ne!(t0, base([6; 32], [9; 32], KX_GROUP, &pa), "exporter");
        assert_ne!(
            t0,
            base([6; 32], [7; 32], "X25519", &pa),
            "downgrade of TLS group"
        );
        let mut pa2 = pa.clone();
        pa2.root_mldsa65[100] ^= 1;
        assert_ne!(t0, base([6; 32], [7; 32], KX_GROUP, &pa2), "ML-DSA key");
        // addrs are not part of TH
        let mut pa3 = pa.clone();
        pa3.addrs.relay = Some("https://other/".into());
        assert_eq!(t0, base([6; 32], [7; 32], KX_GROUP, &pa3));
    }

    /// Vectors for independent implementations (PROTOCOL.md, appendix A).
    #[test]
    fn regression_vectors() {
        let hex = |b: &[u8]| data_encoding::HEXLOWER.encode(b);
        let s = [0x11u8; 32];
        let x = [0x22u8; 32];
        let (e_a, e_b) = ([0x33u8; 32], [0x44u8; 32]);
        let (n_a, n_b) = ([0x55u8; 32], [0x66u8; 32]);
        let (pa, pb) = (party(0xa1), party(0xb2));
        let c_b = calc::commit(&x, &n_b);
        let th = calc::transcript(&calc::TranscriptInput {
            v: VERSION,
            kx: KX_GROUP,
            e_a: &e_a,
            e_b: &e_b,
            x: &x,
            c_b: &c_b,
            n_a: &n_a,
            n_b: &n_b,
            p_a: &pa,
            p_b: &pb,
        });
        let k = calc::keys(&x, &s, &th);
        let got = [
            (
                "psk_mac",
                hex(&calc::psk_mac(
                    &s,
                    &x,
                    &e_a,
                    &e_b,
                    &calc::M1Body {
                        v: VERSION,
                        suite: SUITE,
                        commit: &c_b,
                        party: &pb,
                    },
                )),
            ),
            ("C_B", hex(&c_b)),
            ("TH", hex(&th)),
            ("K_A", hex(k.k_a.as_slice())),
            ("K_B", hex(k.k_b.as_slice())),
            ("link_id", hex(&k.link_id)),
            ("kc_B", hex(&calc::mac(&k.k_b, label::KEY_CONFIRM, &th))),
            ("SAS", calc::sas(&th)),
        ];
        for (n, v) in &got {
            println!("VECTOR {n} = {v}");
        }
        let want = VECTORS;
        for ((n, v), (wn, wv)) in got.iter().zip(want.iter()) {
            assert_eq!(n, wn);
            assert_eq!(v, wv, "{n}");
        }
    }

    /// Formal model F-3: `psk_mac` covers the whole M1 body; substituting any field (including `addrs`) changes the
    /// MAC.
    #[test]
    fn psk_mac_covers_every_field_of_m1() {
        let base = party(7);
        let mac = |v: u16, suite: &str, commit: [u8; 32], p: &Party| {
            calc::psk_mac(
                &[1; 32],
                &[2; 32],
                &[3; 32],
                &[4; 32],
                &calc::M1Body {
                    v,
                    suite,
                    commit: &commit,
                    party: p,
                },
            )
        };
        let m0 = mac(VERSION, SUITE, [8; 32], &base);
        assert_ne!(m0, mac(VERSION + 1, SUITE, [8; 32], &base), "v");
        assert_ne!(m0, mac(VERSION, "x-pair/0;weak", [8; 32], &base), "suite");
        assert_ne!(m0, mac(VERSION, SUITE, [9; 32], &base), "commit");
        let mut changes: Vec<(&str, Party)> = Vec::new();
        let mut p = base.clone();
        p.identity_key[5] ^= 1;
        changes.push(("identity_key", p));
        let mut p = base.clone();
        p.root_ed25519[0] ^= 1;
        changes.push(("root_ed25519", p));
        let mut p = base.clone();
        p.root_mldsa65[1000] ^= 1;
        changes.push(("root_mldsa65", p));
        let mut p = base.clone();
        p.endpoint[31] ^= 1;
        changes.push(("endpoint", p));
        let mut p = base.clone();
        p.addrs.relay = Some("https://evil.example/".into());
        changes.push(("addrs.relay", p));
        let mut p = base.clone();
        p.addrs.direct.push("10.0.0.1:1".into());
        changes.push(("addrs.direct", p));
        for (what, p) in &changes {
            assert_ne!(m0, mac(VERSION, SUITE, [8; 32], p), "{what}");
        }
        // addrs are unambiguous: an empty relay and no relay are distinguished
        let mut a = AddrHints::default();
        let none = calc::addrs_bytes(&a);
        a.relay = Some(String::new());
        assert_ne!(none, calc::addrs_bytes(&a));
    }

    /// F-1: a bundle with a foreign identity (or broken lengths) is rejected before `process_bundle`; and even if it
    /// got through, libsignal rejects signatures by a foreign key
    /// (`e2e::tests::bundle_with_foreign_identity_is_rejected`).
    #[test]
    fn bundle_must_carry_the_identity_from_the_transcript() {
        let link = LinkId([4; 32]);
        let (an, bn) = e2e::address_names(&link);
        let (a_id, a_reg) = e2e::new_identity();
        let (m_id, m_reg) = e2e::new_identity();
        let p_a = Party {
            identity_key: a_id.identity_key().serialize().to_vec(),
            ..party(1)
        };
        let mut a = PairingE2e::new(a_id, a_reg, &an, &bn, &[5; 33]).unwrap();
        let mut m = PairingE2e::new(m_id, m_reg, &an, &bn, &[5; 33]).unwrap();
        assert!(check_bundle(&a.make_bundle().unwrap(), &p_a).is_ok());
        let evil = m.make_bundle().unwrap();
        assert!(check_bundle(&evil, &p_a).is_err(), "foreign identity");
        let mut broken = a.make_bundle().unwrap();
        broken.kyber_prekey.pop();
        assert!(check_bundle(&broken, &p_a).is_err(), "bad lengths");
    }

    #[test]
    fn sas_is_six_digits_and_depends_on_th() {
        let a = calc::sas(&[1; 32]);
        assert_eq!(a.len(), 6);
        assert!(a.chars().all(|c| c.is_ascii_digit()));
        assert_ne!(a, calc::sas(&[2; 32]));
    }

    #[test]
    fn keys_are_role_separated_and_depend_on_secret() {
        let p = party(7);
        let m1 = calc::M1Body {
            v: VERSION,
            suite: SUITE,
            commit: &[8; 32],
            party: &p,
        };
        let k = calc::keys(&[1; 32], &[2; 32], &[3; 32]);
        assert_ne!(k.k_a.as_slice(), k.k_b.as_slice());
        let k2 = calc::keys(&[1; 32], &[9; 32], &[3; 32]);
        assert_ne!(k.k_a.as_slice(), k2.k_a.as_slice());
        assert_ne!(k.link_id, k2.link_id);
        assert_ne!(
            calc::psk_mac(&[1; 32], &[2; 32], &[3; 32], &[4; 32], &m1),
            calc::psk_mac(&[1; 32], &[2; 32], &[4; 32], &[3; 32], &m1),
            "endpoint order matters"
        );
    }
}
