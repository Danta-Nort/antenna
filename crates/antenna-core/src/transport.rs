// SPDX-License-Identifier: AGPL-3.0-only
//! Transport (SPEC §4) on iroh 1.3: Q-1, Q-5, D-5…D-7, `docs/PROTOCOL.md` §5, §11, §13.
//!
//! - One endpoint per link (pairwise) and a separate ephemeral endpoint per invite.
//! - `presets::Minimal`: no pkarr/DNS publishing, no mDNS (D-6). Relay: n0 by default, a custom URL, or off.
//! - "Relay only" mode (levels 1–2): an endpoint without IP transports, the contact does not see the IP. Direct (3–5):
//!   relay + IP.
//! - TLS: aws-lc-rs, groups `[X25519MLKEM768, X25519]` (prefer-PQ, D-5); node-to-node connections must negotiate
//!   `X25519MLKEM768`, otherwise they are closed.
//! - Two-layer accept-list (D-7, Q-5): over relay, a foreign EndpointId is ignored before the handshake (no reply);
//!   directly, the connection is closed right after TLS, before any application data.

use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use antenna_proto::{
    control::HomeRelayInfo,
    link::CLOSE_NOT_PAIRED,
    pairing::{AddrHints, CLOSE_NOT_PQ, KX_GROUP},
};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr, Watcher,
    endpoint::{
        AfterHandshakeOutcome, Connection, EndpointHooks, Incoming, IncomingAddr, PortmapperConfig,
        RecvStream, SendStream, presets,
    },
    protocol::{IncomingFilter, IncomingFilterOutcome},
};
use rustls::NamedGroup;

use crate::error::{Error, Result};

/// Node relay setting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayConfig {
    /// Public n0 relays (the default, SPEC §4).
    N0,
    /// No relay (tests, LAN): direct addresses only.
    Disabled,
    /// Custom relay.
    Custom(RelayUrl),
}

impl RelayConfig {
    /// Parse: `n0`, `disabled` or a URL.
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "n0" | "default" => Ok(RelayConfig::N0),
            "disabled" | "none" | "off" => Ok(RelayConfig::Disabled),
            url => {
                Ok(RelayConfig::Custom(url.parse().map_err(|e| {
                    Error::bad_request(format!("relay url: {e}"))
                })?))
            }
        }
    }

    /// Description for `antenna status`.
    pub fn describe(&self) -> String {
        match self {
            RelayConfig::N0 => "n0".into(),
            RelayConfig::Disabled => "disabled".into(),
            RelayConfig::Custom(u) => u.to_string(),
        }
    }

    fn mode(&self) -> RelayMode {
        match self {
            RelayConfig::N0 => RelayMode::Default,
            RelayConfig::Disabled => RelayMode::Disabled,
            RelayConfig::Custom(u) => RelayMode::custom([u.clone()]),
        }
    }

    /// Whether there is a relay.
    pub fn enabled(&self) -> bool {
        !matches!(self, RelayConfig::Disabled)
    }

    /// Whether this is our own relay (from our own relay map). In "relay only" mode the node connects only to its own
    /// relays: a foreign relay named by the contact would see our IP (SPEC §4).
    pub fn is_own(&self, url: &str) -> bool {
        let Ok(u) = url.parse::<RelayUrl>() else {
            return false;
        };
        match self {
            RelayConfig::Disabled => false,
            RelayConfig::Custom(c) => *c == u,
            RelayConfig::N0 => RelayMode::Default
                .relay_map()
                .urls::<Vec<RelayUrl>>()
                .contains(&u),
        }
    }
}

/// Node network settings.
#[derive(Debug, Clone)]
pub struct NetConfig {
    /// Relay.
    pub relay: RelayConfig,
    /// Address for direct sockets (for example, `127.0.0.1` in tests). `None` means all interfaces.
    pub bind_ip: Option<IpAddr>,
}

/// Endpoint mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EpMode {
    /// Relay only, no IP transports.
    RelayOnly,
    /// Relay (if any) + IP.
    Direct,
}

/// TLS crypto provider: aws-lc-rs, prefer-PQ (D-5).
pub fn crypto_provider() -> Arc<rustls::crypto::CryptoProvider> {
    use rustls::crypto::aws_lc_rs::{self, kx_group};
    let mut p = aws_lc_rs::default_provider();
    p.kx_groups = vec![kx_group::X25519MLKEM768, kx_group::X25519];
    Arc::new(p)
}

/// Negotiated TLS key exchange group of a connection (as reported by rustls).
pub fn kx_group(conn: &Connection) -> Option<String> {
    kx_named(conn).map(|g| format!("{g:?}"))
}

fn kx_named(conn: &Connection) -> Option<NamedGroup> {
    let any = conn.handshake_data()?;
    let hd = any.downcast::<noq::crypto::rustls::HandshakeData>().ok()?;
    hd.negotiated_key_exchange_group
}

/// Whether a post-quantum group was negotiated.
pub fn is_pq(conn: &Connection) -> bool {
    kx_named(conn) == Some(NamedGroup::X25519MLKEM768)
}

/// Connection paths: `*relay:URL` / `ip:ADDR` (the asterisk marks the selected one).
pub fn describe_paths(conn: &Connection) -> Vec<String> {
    conn.paths()
        .iter()
        .map(|p| {
            let sel = if p.is_selected() { "*" } else { "" };
            match p.remote_addr() {
                TransportAddr::Relay(u) => format!("{sel}relay:{u}"),
                TransportAddr::Ip(a) => format!("{sel}ip:{a}"),
                other => format!("{sel}{other:?}"),
            }
        })
        .collect()
}

/// Pairwise endpoint accept-list, layer 2 (after TLS): a foreign key or a non-PQ group → close.
#[derive(Debug, Clone)]
pub struct LinkGuard {
    /// The only allowed key.
    pub peer: EndpointId,
}

impl EndpointHooks for LinkGuard {
    async fn after_handshake<'a>(&'a self, conn: &'a Connection) -> AfterHandshakeOutcome {
        if conn.remote_id() != self.peer {
            tracing::debug!("accept-list: closing connection from unpaired key after handshake");
            return AfterHandshakeOutcome::Reject {
                error_code: CLOSE_NOT_PAIRED.into(),
                reason: Vec::new(),
            };
        }
        if !is_pq(conn) {
            tracing::warn!("link connection without X25519MLKEM768, closing");
            return AfterHandshakeOutcome::Reject {
                error_code: CLOSE_NOT_PQ.into(),
                reason: Vec::new(),
            };
        }
        AfterHandshakeOutcome::Accept
    }
}

/// Ephemeral invite endpoint: B's key is not known in advance, but the TLS group must be PQ.
#[derive(Debug, Clone)]
pub struct PairGuard;

impl EndpointHooks for PairGuard {
    async fn after_handshake<'a>(&'a self, conn: &'a Connection) -> AfterHandshakeOutcome {
        if !is_pq(conn) {
            return AfterHandshakeOutcome::Reject {
                error_code: CLOSE_NOT_PQ.into(),
                reason: Vec::new(),
            };
        }
        AfterHandshakeOutcome::Accept
    }
}

/// Accept-list, layer 1 (before the handshake): over relay the sender ID is known, and a foreign one is silently
/// ignored. Direct UDP without a validated address gets a Retry (protection against address spoofing); [`LinkGuard`]
/// decides the rest.
pub fn link_filter(peer: EndpointId) -> IncomingFilter {
    Arc::new(move |inc: &Incoming| match inc.remote_addr() {
        IncomingAddr::Relay { endpoint_id, .. } if endpoint_id != peer => {
            IncomingFilterOutcome::Ignore
        }
        IncomingAddr::Ip(_) if !inc.remote_addr_validated() => IncomingFilterOutcome::Retry,
        _ => IncomingFilterOutcome::Accept,
    })
}

/// Parameters of a new endpoint.
pub struct EpParams<H> {
    /// Key.
    pub secret: SecretKey,
    /// Mode.
    pub mode: EpMode,
    /// Preferred UDP port (reused after a restart).
    pub port: Option<u16>,
    /// Hooks (accept-list).
    pub hooks: H,
    /// ALPNs the endpoint accepts.
    pub alpns: Vec<Vec<u8>>,
}

/// How long to wait for the relay when bringing up a saved link: no longer than this (no internet, LAN).
pub const SAVED_ONLINE_WAIT: Duration = Duration::from_secs(2);

/// Brings up an endpoint from the node settings. With a relay, waits until it is online (up to `online_timeout`);
/// otherwise an error (pairing: the relay address is needed in the `addrs` of pairing messages).
pub async fn bind<H: EndpointHooks + 'static>(
    net: &NetConfig,
    p: EpParams<H>,
    online_timeout: Duration,
) -> Result<Endpoint> {
    bind_inner(net, p, online_timeout, true).await
}

/// Endpoint of a saved link: the relay is waited for briefly ([`SAVED_ONLINE_WAIT`]) and is **not required**: without
/// internet (LAN, SPEC §18) the link still comes up; direct addresses work immediately and the relay endpoint catches
/// up on its own once the network appears.
pub async fn bind_saved<H: EndpointHooks + 'static>(
    net: &NetConfig,
    p: EpParams<H>,
) -> Result<Endpoint> {
    bind_inner(net, p, SAVED_ONLINE_WAIT, false).await
}

async fn bind_inner<H: EndpointHooks + 'static>(
    net: &NetConfig,
    p: EpParams<H>,
    online_timeout: Duration,
    require_online: bool,
) -> Result<Endpoint> {
    if p.mode == EpMode::RelayOnly && !net.relay.enabled() {
        return Err(Error::bad_request(
            "relay-only mode (trust 1–2) needs a relay; this node runs with relay disabled",
        ));
    }
    let mut b = Endpoint::builder(presets::Minimal)
        .crypto_provider(crypto_provider())
        .relay_mode(net.relay.mode())
        .secret_key(p.secret)
        .alpns(p.alpns)
        .hooks(p.hooks);
    match p.mode {
        EpMode::RelayOnly => {
            b = b
                .clear_ip_transports()
                .portmapper_config(PortmapperConfig::Disabled);
        }
        EpMode::Direct => {
            if let Some(ip) = net.bind_ip {
                b = b
                    .clear_ip_transports()
                    .portmapper_config(PortmapperConfig::Disabled);
                b = bind_port(b, SocketAddr::new(ip, p.port.unwrap_or(0)))?;
            } else if let Some(port) = p.port {
                b = bind_port(b, SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port))?;
            }
        }
    }
    // If the saved port is taken, the caller retries bind with a random port;
    // the contact learns the new address from the `hello` frame on the next connection
    let ep = b
        .bind()
        .await
        .map_err(|e| Error::network(format!("bind: {e}")))?;
    if net.relay.enabled()
        && tokio::time::timeout(online_timeout, ep.online())
            .await
            .is_err()
    {
        if !require_online {
            tracing::warn!(
                "relay unreachable for now: the link works over direct addresses until it is back"
            );
            return Ok(ep);
        }
        ep.close().await;
        return Err(Error::network(
            "relay unreachable: endpoint did not come online",
        ));
    }
    Ok(ep)
}

fn bind_port(b: iroh::endpoint::Builder, addr: SocketAddr) -> Result<iroh::endpoint::Builder> {
    b.bind_addr(addr)
        .map_err(|e| Error::bad_request(format!("bind address {addr}: {e}")))
}

/// Address hints of our own endpoint for the contact (without IP in "relay only" mode).
pub fn addr_hints(ep: &Endpoint, mode: EpMode) -> AddrHints {
    let a = ep.addr();
    AddrHints {
        relay: a.relay_urls().next().map(|u| u.to_string()),
        direct: if mode == EpMode::Direct {
            a.ip_addrs().map(|s| s.to_string()).collect()
        } else {
            Vec::new()
        },
    }
}

/// Dial address from hints, taking the mode into account: in "relay only", only via our own relay.
pub fn link_dial_addr(
    id: EndpointId,
    hints: &AddrHints,
    mode: EpMode,
    net: &NetConfig,
) -> Result<EndpointAddr> {
    if mode == EpMode::RelayOnly {
        match hints.relay.as_deref() {
            Some(r) if net.relay.is_own(r) => {}
            Some(r) => {
                return Err(Error::network(format!(
                    "contact's relay {r} is not one of ours; in relay-only mode it would see our IP"
                )));
            }
            None => return Err(Error::network("contact has no relay address")),
        }
        let only_relay = AddrHints {
            relay: hints.relay.clone(),
            direct: Vec::new(),
        };
        return Ok(dial_addr(id, &only_relay));
    }
    Ok(dial_addr(id, hints))
}

/// Dial address from hints.
pub fn dial_addr(id: EndpointId, hints: &AddrHints) -> EndpointAddr {
    let mut a = EndpointAddr::new(id);
    if let Some(r) = hints
        .relay
        .as_deref()
        .and_then(|r| r.parse::<RelayUrl>().ok())
    {
        a = a.with_relay_url(r);
    }
    for d in &hints.direct {
        if let Ok(s) = d.parse::<SocketAddr>() {
            a = a.with_ip_addr(s);
        }
    }
    a
}

/// The endpoint's home relay as iroh reports it (`contacts[].transport.relay`, the doctor's `relay_unreachable`, D-96):
/// the first entry of `home_relay_status`, or an empty URL before the endpoint has chosen one. The error is iroh's own
/// text, which may quote the relay server (an auth denial reason), so control characters go and the length is capped.
pub fn home_relay(ep: &Endpoint) -> HomeRelayInfo {
    let all = ep.home_relay_status().get();
    let Some(s) = all.first() else {
        return HomeRelayInfo {
            url: String::new(),
            connected: false,
            error: None,
        };
    };
    let connected = s.is_connected();
    HomeRelayInfo {
        url: s.url().to_string(),
        connected,
        error: s
            .last_error()
            .filter(|_| !connected)
            .map(|e| relay_error_text(&format!("{e:#}"))),
    }
}

/// At most [`RELAY_ERROR_MAX`] characters, without control characters.
fn relay_error_text(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(RELAY_ERROR_MAX)
        .collect()
}

/// The longest relay error text in `contacts` (CONTROL §9).
const RELAY_ERROR_MAX: usize = 200;

/// Port of the endpoint's first direct socket.
pub fn bound_port(ep: &Endpoint) -> Option<u16> {
    ep.bound_sockets().first().map(|s| s.port())
}

/// Writes a frame `u32be(len) ‖ payload`.
pub async fn write_frame(send: &mut SendStream, payload: &[u8]) -> Result<()> {
    send.write_all(&antenna_proto::link::frame(payload))
        .await
        .map_err(|e| Error::network(format!("write: {e}")))
}

/// Reads a frame no longer than `max`.
pub async fn read_frame(recv: &mut RecvStream, max: usize) -> Result<Vec<u8>> {
    let mut len = [0u8; 4];
    recv.read_exact(&mut len)
        .await
        .map_err(|e| Error::network(format!("read: {e}")))?;
    let n = u32::from_be_bytes(len) as usize;
    if n > max {
        return Err(Error::bad_request(format!(
            "frame of {n} bytes exceeds {max}"
        )));
    }
    let mut buf = vec![0u8; n];
    recv.read_exact(&mut buf)
        .await
        .map_err(|e| Error::network(format!("read: {e}")))?;
    Ok(buf)
}

/// Check: `KX_GROUP` from antenna-proto matches the rustls group name.
pub fn kx_name_matches_spec() -> bool {
    format!("{:?}", NamedGroup::X25519MLKEM768) == KX_GROUP
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_group_name_is_rustls_name() {
        assert!(kx_name_matches_spec());
    }

    #[test]
    fn relay_config_parse() {
        assert_eq!(RelayConfig::parse("n0").unwrap(), RelayConfig::N0);
        assert_eq!(
            RelayConfig::parse("disabled").unwrap(),
            RelayConfig::Disabled
        );
        assert!(matches!(
            RelayConfig::parse("https://relay.example/").unwrap(),
            RelayConfig::Custom(_)
        ));
        assert!(RelayConfig::parse("not a url").is_err());
    }

    #[test]
    fn foreign_relay_is_refused_in_relay_only_mode() {
        let net = NetConfig {
            relay: RelayConfig::N0,
            bind_ip: None,
        };
        let own = RelayMode::Default.relay_map().urls::<Vec<RelayUrl>>()[0].to_string();
        assert!(net.relay.is_own(&own));
        assert!(!net.relay.is_own("https://evil.example/"));
        let id = SecretKey::generate().public();
        let hints = |r: &str| AddrHints {
            relay: Some(r.into()),
            direct: vec!["10.0.0.1:1".into()],
        };
        assert!(
            link_dial_addr(id, &hints("https://evil.example/"), EpMode::RelayOnly, &net).is_err()
        );
        let a = link_dial_addr(id, &hints(&own), EpMode::RelayOnly, &net).unwrap();
        assert_eq!(a.ip_addrs().count(), 0, "relay-only never dials IP");
        let a = link_dial_addr(id, &hints("https://evil.example/"), EpMode::Direct, &net).unwrap();
        assert_eq!(a.ip_addrs().count(), 1);
    }

    #[tokio::test]
    async fn relay_only_without_relay_is_refused() {
        let net = NetConfig {
            relay: RelayConfig::Disabled,
            bind_ip: Some("127.0.0.1".parse().unwrap()),
        };
        let r = bind(
            &net,
            EpParams {
                secret: SecretKey::generate(),
                mode: EpMode::RelayOnly,
                port: None,
                hooks: PairGuard,
                alpns: vec![],
            },
            Duration::from_secs(1),
        )
        .await;
        assert!(r.is_err());
    }

    #[test]
    fn relay_error_text_is_one_capped_line() {
        let long = format!("dial failed:\n\x1b[31m{}", "\u{e9}".repeat(500));
        let t = relay_error_text(&long);
        assert_eq!(t.chars().count(), RELAY_ERROR_MAX);
        assert!(!t.chars().any(char::is_control), "{t:?}");
        assert!(t.starts_with("dial failed:  [31m\u{e9}"), "{t:?}");
    }
}
