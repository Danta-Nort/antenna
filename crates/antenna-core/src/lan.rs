// SPDX-License-Identifier: AGPL-3.0-only
//! LAN without internet (SPEC §4 "LAN: discovery via mDNS, works without internet; off by default and enabled for
//! trusted networks", §18 "nodes in the same LAN without internet find each other, mDNS enabled manually";
//! DECISIONS D-77, `docs/PROTOCOL.md` §22).
//!
//! **What goes on the network and what does not.** Plain iroh mDNS discovery (`iroh-mdns-address-lookup`) announces
//! the EndpointId, the permanent address of a link, on the local network: anyone on the same Wi-Fi would see how many
//! links the node has, recognize it on another network and link its links to one another. Therefore:
//! - what goes on the network is not the EndpointId but a link **pseudonym**: an Ed25519 public key from
//!   `HMAC(K_lan, label ‖ EndpointId of the announcing side ‖ epoch)`, where `K_lan` is derived from `link_id` and the
//!   link-roots of both sides (known only to the two sides of the link). The pseudonym changes every hour: by the name,
//!   an observer on the network cannot link announcements to each other or to another network (the link endpoint's
//!   port in the announcement is constant, and that can link them, DECISIONS D-78, item 4); the contact computes the
//!   expected pseudonym and recognizes it;
//! - a node **announces itself only when needed**: when it has something to deliver to a contact and the contact does
//!   not answer at its known addresses, for 2 minutes after the last failure; the rest of the time it only listens
//!   (mDNS queries without its own names);
//! - only local network addresses are announced (RFC 1918, link-local, loopback): no relay, no Tailscale/CGNAT, no
//!   public IPv4/IPv6;
//! - only links the owner gave level 3+ (direct mode, SPEC §4); levels 1–2 are relay only: they are not in the LAN.
//!
//! A found address is only a routing hint: the connection still checks the contact's key (accept-list, TLS 1.3 with a
//! pinned EndpointId), and a pseudonym planted on the network yields only a failed attempt.
//! No custom cryptography: HKDF-SHA256 and HMAC-SHA256, as in the other protocol derivations (PROTOCOL §2); the Ed25519
//! key from 32 bytes is the standard `SecretKey::from_bytes` (the pseudonym is only a name in mDNS, nothing is signed
//! with it).

use std::{
    collections::{BTreeSet, HashMap},
    net::{IpAddr, SocketAddr},
    sync::{Mutex as StdMutex, PoisonError, Weak},
    time::{Duration, Instant},
};

use antenna_proto::{
    LinkId,
    control::{LanLink, LanReply},
};
use futures::StreamExt;
use iroh::{
    EndpointId, SecretKey, address_lookup::AddressLookup as _, endpoint_info::EndpointData,
};
use iroh_mdns_address_lookup::{DiscoveryEvent, MdnsAddressLookup};

use crate::{crypto, node::Session, now_ms};

/// Pseudonym epoch length, s: a link's pseudonym changes once an hour.
pub const EPOCH_SECS: u64 = 3600;
/// How long to keep announcing after the last failed delivery attempt.
pub const BEACON_FOR: Duration = Duration::from_secs(120);
/// At most one connection per found pseudonym within this time (mDNS repeats replies every second).
const CONNECT_EVERY: Duration = Duration::from_secs(3);
/// How long to remember found addresses.
const FOUND_TTL: Duration = Duration::from_secs(600);
/// The listener is recreated this often: the peer tables of the mDNS crates grow from foreign names on the network and
/// are only cleaned on expiry; recreating resets them (D-78, item 5).
const LISTENER_RENEW: Duration = Duration::from_secs(600);
/// At most this many contact addresses in the found set (newest first).
const MAX_FOUND: usize = 16;
/// Setting key in `meta`.
pub const META_KEY: &str = "lan_enabled";
/// How many contact addresses to take from one reply.
const MAX_ADDRS: usize = 8;

/// Link pseudonym key: `HKDF-SHA256(salt "x/lan/v0/salt", link_id ‖ min(root) ‖ max(root), "x/lan/v0/key")`.
pub fn lan_key(link: &LinkId, root_a: &[u8; 32], root_b: &[u8; 32]) -> crypto::Secret32 {
    let (lo, hi) = if root_a <= root_b {
        (root_a, root_b)
    } else {
        (root_b, root_a)
    };
    let mut ikm = Vec::with_capacity(96);
    ikm.extend_from_slice(&link.0);
    ikm.extend_from_slice(lo);
    ikm.extend_from_slice(hi);
    crypto::hkdf32(b"x/lan/v0/salt", &ikm, &[b"x/lan/v0/key"])
}

/// Pseudonym of a link side in an epoch: an Ed25519 public key with the secret `HMAC(K_lan, "x/lan/v0/beacon" ‖
/// endpoint ‖ u64be(epoch))`. In mDNS it is the instance name instead of the EndpointId (`endpoint` is the EndpointId
/// of the announcing side).
pub fn beacon_name(key: &crypto::Secret32, endpoint: &[u8; 32], epoch: u64) -> EndpointId {
    let seed = zeroize::Zeroizing::new(crypto::hmac(
        key.as_slice(),
        &[b"x/lan/v0/beacon", endpoint, &epoch.to_be_bytes()],
    ));
    SecretKey::from_bytes(&seed).public()
}

/// Current pseudonym epoch.
pub fn epoch_now() -> u64 {
    now_ms() / 1000 / EPOCH_SECS
}

/// The address is usable for LAN: private IPv4 networks (RFC 1918), link-local, loopback. Not usable: CGNAT/Tailscale
/// (100.64/10), public addresses, IPv6 except `::1` (global addresses reveal the ISP prefix, ULA is often a VPN).
pub fn addr_ok(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_link_local() || v4.is_loopback(),
        IpAddr::V6(v6) => v6.is_loopback(),
    }
}

/// What is needed to announce for a link.
#[derive(Clone)]
pub struct BeaconSpec {
    /// Link pseudonym key.
    pub key: crypto::Secret32,
    /// Our own EndpointId in this link.
    pub endpoint: [u8; 32],
    /// Our own addresses on the local network.
    pub addrs: Vec<SocketAddr>,
}

struct Beacon {
    _mdns: MdnsAddressLookup,
    epoch: u64,
    until: Instant,
    spec: BeaconSpec,
}

struct Found {
    addrs: Vec<SocketAddr>,
    at: Instant,
    at_ms: u64,
    last_connect: Option<Instant>,
}

struct Listener {
    _mdns: MdnsAddressLookup,
    task: tokio::task::JoinHandle<()>,
    started: Instant,
    session: Weak<Session>,
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[derive(Default)]
struct Inner {
    enabled: bool,
    listener: Option<Listener>,
    error: Option<String>,
    beacons: HashMap<LinkId, Beacon>,
    found: HashMap<LinkId, Found>,
}

/// Start the listener (the listener's name never goes on the network: without addresses there are no mDNS replies;
/// random key).
fn spawn_listener(session: Weak<Session>) -> Result<Listener, String> {
    let mdns = MdnsAddressLookup::builder()
        .advertise(false)
        .build(SecretKey::generate().public())
        .map_err(|e| e.to_string())?;
    let task = tokio::spawn(listen(mdns.clone(), session.clone()));
    Ok(Listener {
        _mdns: mdns,
        task,
        started: Instant::now(),
        session,
    })
}

/// The node's LAN (one per unlocked session).
#[derive(Default)]
pub struct Lan {
    inner: StdMutex<Inner>,
}

impl std::fmt::Debug for Lan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Lan")
    }
}

impl Lan {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The mode is on.
    pub fn enabled(&self) -> bool {
        self.lock().enabled
    }

    /// Turn on: listen to the network (without our own names). An mDNS error (port, multicast) goes to `lan_status`;
    /// the mode stays on (the listener comes up at the next enable or unlock).
    pub fn start(&self, session: Weak<Session>) {
        let mut g = self.lock();
        g.enabled = true;
        if g.listener.is_some() {
            return;
        }
        match spawn_listener(session) {
            Ok(l) => {
                g.listener = Some(l);
                g.error = None;
            }
            Err(e) => {
                tracing::warn!("lan: mDNS is unavailable: {e}");
                g.error = Some(format!("mDNS is unavailable: {e}"));
            }
        }
    }

    /// Turn off: neither listen nor announce; forget what was found.
    pub fn stop(&self) {
        let mut g = self.lock();
        g.enabled = false;
        g.listener = None;
        g.beacons.clear();
        g.found.clear();
        g.error = None;
    }

    /// Delivery to the contact failed (it does not answer at its known addresses): announce for this link for
    /// [`BEACON_FOR`]. The caller has checked that the link is level 3+.
    pub fn want_beacon(&self, link: LinkId, spec: BeaconSpec) {
        let mut g = self.lock();
        if !g.enabled || spec.addrs.is_empty() {
            return;
        }
        let until = Instant::now() + BEACON_FOR;
        let epoch = epoch_now();
        if let Some(b) = g.beacons.get_mut(&link)
            && b.epoch == epoch
            && b.spec.addrs == spec.addrs
        {
            b.until = until;
            return;
        }
        match start_beacon(&spec, epoch) {
            Ok(mdns) => {
                tracing::debug!("lan: link {} beacon on", &link.to_hex()[..8]);
                g.beacons.insert(
                    link,
                    Beacon {
                        _mdns: mdns,
                        epoch,
                        until,
                        spec,
                    },
                );
            }
            Err(e) => {
                tracing::warn!("lan: beacon: {e}");
                g.error = Some(format!("mDNS beacon failed: {e}"));
            }
        }
    }

    /// Keep announcements and findings only for these links (when the level is lowered to 1–2, or the link is revoked
    /// or stopped, the announcement is removed immediately, D-78, item 8).
    pub fn retain(&self, eligible: &[LinkId]) {
        let mut g = self.lock();
        g.beacons.retain(|l, _| eligible.contains(l));
        g.found.retain(|l, _| eligible.contains(l));
    }

    /// The contact is connected: no more reason to announce for it.
    pub fn connected(&self, link: &LinkId) {
        self.lock().beacons.remove(link);
    }

    /// Maintenance every few seconds: remove expired announcements, change the pseudonym at the epoch boundary, forget
    /// old findings.
    pub fn tick(&self) {
        let mut g = self.lock();
        let now = Instant::now();
        if let Some(l) = &g.listener
            && l.started.elapsed() > LISTENER_RENEW
        {
            let session = l.session.clone();
            g.listener = None;
            match spawn_listener(session) {
                Ok(l) => g.listener = Some(l),
                Err(e) => g.error = Some(format!("mDNS is unavailable: {e}")),
            }
        }
        g.beacons.retain(|_, b| b.until > now);
        g.found.retain(|_, f| now.duration_since(f.at) < FOUND_TTL);
        let epoch = epoch_now();
        let stale: Vec<LinkId> = g
            .beacons
            .iter()
            .filter(|(_, b)| b.epoch != epoch)
            .map(|(l, _)| *l)
            .collect();
        for l in stale {
            let Some(old) = g.beacons.remove(&l) else {
                continue;
            };
            if let Ok(mdns) = start_beacon(&old.spec, epoch) {
                g.beacons.insert(
                    l,
                    Beacon {
                        _mdns: mdns,
                        epoch,
                        until: old.until,
                        spec: old.spec,
                    },
                );
            }
        }
    }

    /// Contact addresses found on the local network (routing hints for the connection).
    pub fn found_addrs(&self, link: &LinkId) -> Vec<SocketAddr> {
        let g = self.lock();
        if !g.enabled {
            return Vec::new();
        }
        g.found
            .get(link)
            .filter(|f| f.at.elapsed() < FOUND_TTL)
            .map(|f| f.addrs.clone())
            .unwrap_or_default()
    }

    /// Contact found: remember the addresses; `true` means it is time to connect (at most every [`CONNECT_EVERY`]).
    fn record_found(&self, link: LinkId, addrs: Vec<SocketAddr>) -> bool {
        let mut g = self.lock();
        if !g.enabled {
            return false;
        }
        let now = Instant::now();
        let e = g.found.entry(link).or_insert(Found {
            addrs: Vec::new(),
            at: now,
            at_ms: now_ms(),
            last_connect: None,
        });
        // Merge, newest first: a planted announcement with the same pseudonym does not erase the real addresses
        // (D-78, item 6); TLS still checks the contact's key
        let mut merged = addrs;
        for a in &e.addrs {
            if !merged.contains(a) {
                merged.push(*a);
            }
        }
        merged.truncate(MAX_FOUND);
        e.addrs = merged;
        e.at = now;
        e.at_ms = now_ms();
        if e.last_connect
            .is_some_and(|t| now.duration_since(t) < CONNECT_EVERY)
        {
            return false;
        }
        e.last_connect = Some(now);
        true
    }

    /// State for `lan_status`: `links` are the level 3+ links (label, link).
    pub fn status(&self, links: &[(String, LinkId)]) -> LanReply {
        let g = self.lock();
        LanReply {
            enabled: g.enabled,
            listening: g.listener.is_some(),
            error: g.error.clone(),
            links: links
                .iter()
                .map(|(label, l)| {
                    let f = g.found.get(l).filter(|f| f.at.elapsed() < FOUND_TTL);
                    LanLink {
                        contact: label.clone(),
                        beacon: g.beacons.contains_key(l),
                        found: f
                            .map(|f| f.addrs.iter().map(|a| a.to_string()).collect())
                            .unwrap_or_default(),
                        found_ms: f.map(|f| f.at_ms),
                    }
                })
                .collect(),
        }
    }
}

fn start_beacon(spec: &BeaconSpec, epoch: u64) -> Result<MdnsAddressLookup, String> {
    let name = beacon_name(&spec.key, &spec.endpoint, epoch);
    let mdns = MdnsAddressLookup::builder()
        .advertise(true)
        .build(name)
        .map_err(|e| e.to_string())?;
    // Local network addresses only, no relay and no user data
    let addrs: BTreeSet<SocketAddr> = spec
        .addrs
        .iter()
        .filter(|a| addr_ok(&a.ip()))
        .copied()
        .collect();
    mdns.publish(&EndpointData::from(addrs));
    Ok(mdns)
}

/// Expected contact pseudonyms (level 3+ links, epochs −1, 0, +1: the two sides' clocks may differ).
struct Table {
    epoch: u64,
    links: Vec<LinkId>,
    names: HashMap<EndpointId, LinkId>,
    built: Instant,
}

impl Table {
    fn refresh(&mut self, s: &Session) {
        let epoch = epoch_now();
        let mut eligible = s.lan_eligible();
        eligible.sort_by_key(|e| e.0);
        let links: Vec<LinkId> = eligible.iter().map(|e| e.0).collect();
        if epoch == self.epoch
            && links == self.links
            && self.built.elapsed() < Duration::from_secs(60)
        {
            return;
        }
        self.names.clear();
        for (link, key, peer_endpoint) in &eligible {
            for t in [epoch.saturating_sub(1), epoch, epoch + 1] {
                self.names.insert(beacon_name(key, peer_endpoint, t), *link);
            }
        }
        self.epoch = epoch;
        self.links = links;
        self.built = Instant::now();
    }
}

/// Listener: every name found on the network is compared with the expected contact pseudonyms; on a match the
/// addresses are remembered and the node connects to the contact (it announced itself because it has something to
/// deliver).
async fn listen(mdns: MdnsAddressLookup, session: Weak<Session>) {
    let mut events = mdns.subscribe().await;
    let mut table = Table {
        epoch: u64::MAX,
        links: Vec::new(),
        names: HashMap::new(),
        built: Instant::now(),
    };
    while let Some(ev) = events.next().await {
        let DiscoveryEvent::Discovered { endpoint_info, .. } = ev else {
            continue;
        };
        let Some(s) = session.upgrade() else { break };
        if s.is_closed() {
            break;
        }
        table.refresh(&s);
        let Some(link) = table.names.get(&endpoint_info.endpoint_id).copied() else {
            continue;
        };
        let addrs: Vec<SocketAddr> = endpoint_info
            .data
            .ip_addrs()
            .filter(|a| addr_ok(&a.ip()))
            .take(MAX_ADDRS)
            .copied()
            .collect();
        if addrs.is_empty() {
            continue;
        }
        if s.lan.record_found(link, addrs) {
            tracing::debug!("lan: link {} contact found", &link.to_hex()[..8]);
            s.lan_connect(&link);
        }
    }
}

/// LAN maintenance of a session: every 2 s (expired announcements, epoch change, contact already connected).
pub async fn maintenance(session: Weak<Session>) {
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let Some(s) = session.upgrade() else { break };
        if s.is_closed() {
            break;
        }
        s.lan.tick();
        let eligible: Vec<LinkId> = s.lan_eligible().into_iter().map(|e| e.0).collect();
        s.lan.retain(&eligible);
        for l in s.lan_connected_links() {
            s.lan.connected(&l);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pseudonym: the same for both sides of a link, different for sides, links and epochs; it cannot be computed
    /// without `link_id` and the link keys (an observer sees different names every hour).
    #[test]
    fn pseudonyms_are_per_link_side_and_epoch() {
        let link = LinkId([1; 32]);
        let (ra, rb) = ([2u8; 32], [3u8; 32]);
        let k_a = lan_key(&link, &ra, &rb);
        let k_b = lan_key(&link, &rb, &ra);
        assert_eq!(*k_a, *k_b, "both sides derive the same key");
        let (ea, eb) = ([4u8; 32], [5u8; 32]);
        let n = beacon_name(&k_a, &ea, 10);
        assert_eq!(n, beacon_name(&k_b, &ea, 10));
        assert_ne!(n, beacon_name(&k_a, &eb, 10), "sides differ");
        assert_ne!(n, beacon_name(&k_a, &ea, 11), "epochs differ");
        let other = lan_key(&LinkId([9; 32]), &ra, &rb);
        assert_ne!(n, beacon_name(&other, &ea, 10), "links differ");
        assert_ne!(n.as_bytes(), &ea, "the EndpointId itself is never the name");
    }

    /// D-78, item 6: a planted announcement with the same pseudonym adds addresses but does not erase the real ones;
    /// connecting by pseudonym happens at most once every 3 s; the disabled mode remembers nothing.
    #[test]
    fn found_addresses_merge_and_connects_are_rate_limited() {
        let lan = Lan::default();
        let link = LinkId([1; 32]);
        let real: SocketAddr = "192.168.1.7:5000".parse().unwrap();
        let fake: SocketAddr = "192.168.1.66:6000".parse().unwrap();
        assert!(
            !lan.record_found(link, vec![real]),
            "off: nothing is recorded"
        );
        lan.lock().enabled = true;
        assert!(lan.record_found(link, vec![real]));
        assert!(
            !lan.record_found(link, vec![fake]),
            "no reconnect within 3 s"
        );
        assert_eq!(lan.found_addrs(&link), vec![fake, real]);
        let many: Vec<SocketAddr> = (0..40)
            .map(|i| format!("10.0.0.{i}:1").parse().unwrap())
            .collect();
        lan.record_found(link, many);
        assert_eq!(lan.found_addrs(&link).len(), MAX_FOUND);
        lan.retain(&[]);
        assert!(lan.found_addrs(&link).is_empty(), "link no longer eligible");
    }

    #[test]
    fn only_local_network_addresses() {
        for ok in [
            "192.168.1.5",
            "10.0.0.2",
            "172.16.4.1",
            "169.254.3.3",
            "127.0.0.1",
            "::1",
        ] {
            assert!(addr_ok(&ok.parse().unwrap()), "{ok}");
        }
        for bad in [
            "100.64.0.1",
            "203.0.113.10",
            "8.8.8.8",
            "2001:db8::1",
            "fd7a:115c:a1e0::1",
            "fe80::1",
        ] {
            assert!(!addr_ok(&bad.parse().unwrap()), "{bad}");
        }
    }
}
