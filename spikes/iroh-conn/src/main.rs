// SPDX-License-Identifier: AGPL-3.0-only
//! Spike a): iroh 1.3, transport checks for SPEC §4.
//!
//! Modes:
//!   all              — all checks in one process (T1..T6)
//!   listen           — listen (prints the id and relay), echo back; allow-list from the arguments
//!   dial <id> <relay> [direct-addr] — connect to a listen from another process
//!
//! What we check:
//!   T1 relay-only (clear_ip_transports): a connection by EndpointId only through the n0 relay
//!   T2 direct-only (RelayMode::Disabled): a connection by IP without a relay
//!   T3 relay+IP: start through the relay, upgrade to a direct path (hole punching)
//!   T4 accept-list: an unpaired key is dropped (relay: Ignore before the handshake; IP: Reject after TLS)
//!   T5 many endpoints in one process (pairwise): time, RSS, fds
//!   T6 PQ key exchange in iroh TLS (aws-lc-rs, X25519MLKEM768), through the relay and directly
//!   T7 TLS exporter: both sides get the same channel binding secret (for the SAS)
//!   Everywhere: preset Minimal => no pkarr/DNS address publishing, mDNS is not enabled.

use std::{
    collections::HashSet,
    sync::{Arc, RwLock},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey,
    endpoint::{
        AfterHandshakeOutcome, Connection, EndpointHooks, Incoming, IncomingAddr, presets,
    },
    protocol::{AcceptError, IncomingFilterOutcome, ProtocolHandler, Router},
};

const ALPN: &[u8] = b"x-spike/echo/0";
const CLOSE_NOT_PAIRED: u32 = 403;

// ---------- accept-list ----------

#[derive(Debug, Clone, Default)]
struct AllowList(Arc<RwLock<HashSet<EndpointId>>>);

impl AllowList {
    fn allow(&self, id: EndpointId) {
        self.0.write().unwrap().insert(id);
    }
    fn contains(&self, id: &EndpointId) -> bool {
        self.0.read().unwrap().contains(id)
    }
}

impl EndpointHooks for AllowList {
    // Called after the TLS handshake: remote_id is already known (from the certificate's raw public key).
    async fn after_handshake<'a>(&'a self, conn: &'a Connection) -> AfterHandshakeOutcome {
        if self.contains(&conn.remote_id()) {
            AfterHandshakeOutcome::Accept
        } else {
            eprintln!(
                "    [hook after_handshake] reject {} (not paired)",
                conn.remote_id().fmt_short()
            );
            AfterHandshakeOutcome::Reject {
                error_code: CLOSE_NOT_PAIRED.into(),
                reason: b"".to_vec(), // we reveal nothing
            }
        }
    }
}

/// Filter before the handshake. For relay packets the relay reports the sender's EndpointId,
/// so they can be silently ignored (no reply). For direct UDP the ID is not known yet.
fn incoming_filter(allow: AllowList) -> iroh::protocol::IncomingFilter {
    Arc::new(move |inc: &Incoming| match inc.remote_addr() {
        IncomingAddr::Relay { endpoint_id, .. } if !allow.contains(&endpoint_id) => {
            eprintln!(
                "    [incoming_filter] relay packet from unpaired {} -> Ignore (no response)",
                endpoint_id.fmt_short()
            );
            IncomingFilterOutcome::Ignore
        }
        IncomingAddr::Ip(_) if !inc.remote_addr_validated() => IncomingFilterOutcome::Retry,
        _ => IncomingFilterOutcome::Accept,
    })
}

// ---------- echo protocol ----------

#[derive(Debug, Clone)]
struct Echo;

impl ProtocolHandler for Echo {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        // Each bi-stream is a separate echo; exit when the connection is closed.
        while let Ok((mut send, mut recv)) = connection.accept_bi().await {
            tokio::spawn(async move {
                let _ = tokio::io::copy(&mut recv, &mut send).await;
                let _ = send.finish();
            });
        }
        Ok(())
    }
}

async fn connect_to(ep: &Endpoint, target: EndpointAddr) -> Result<Connection> {
    match tokio::time::timeout(Duration::from_secs(20), ep.connect(target, ALPN)).await {
        Ok(Ok(c)) => Ok(c),
        Ok(Err(e)) => Err(anyhow!("connect: {e:#}")),
        Err(_) => Err(anyhow!("connect: timeout 20s")),
    }
}

async fn echo_roundtrip(conn: &Connection, msg: &[u8]) -> Result<Duration> {
    match tokio::time::timeout(Duration::from_secs(15), echo_inner(conn, msg)).await {
        Ok(r) => r,
        Err(_) => Err(anyhow!("echo of {} bytes: timeout 15s", msg.len())),
    }
}

async fn echo_inner(conn: &Connection, msg: &[u8]) -> Result<Duration> {
    let t = Instant::now();
    let (mut send, mut recv) = conn.open_bi().await?;
    send.write_all(msg).await?;
    send.finish()?;
    let resp = recv.read_to_end(1 << 20).await?;
    if resp != msg {
        bail!("echo mismatch");
    }
    Ok(t.elapsed())
}

fn describe_paths(conn: &Connection) -> String {
    let paths = conn.paths();
    let mut v = Vec::new();
    for p in paths.iter() {
        v.push(format!(
            "{}{}{}(rtt {:?})",
            if p.is_selected() { "*" } else { "" },
            if p.is_relay() { "relay:" } else { "ip:" },
            match p.remote_addr() {
                iroh::TransportAddr::Relay(u) => u.to_string(),
                iroh::TransportAddr::Ip(a) => a.to_string(),
                other => format!("{other:?}"),
            },
            p.rtt()
        ));
    }
    v.join(", ")
}

fn kx_group(conn: &Connection) -> String {
    match conn.handshake_data() {
        Some(any) => match any.downcast::<noq::crypto::rustls::HandshakeData>() {
            Ok(hd) => format!("{:?}", hd.negotiated_key_exchange_group),
            Err(_) => "handshake_data: unknown type".into(),
        },
        None => "handshake_data: none".into(),
    }
}

/// T7: TLS exporter (RFC 5705/8446 §7.5), the basis of channel binding for the SAS at pairing.
#[derive(Debug, Clone)]
struct ExporterProto;
const EXPORTER_ALPN: &[u8] = b"x-spike/exporter/0";
const EXPORTER_LABEL: &[u8] = b"EXPORTER-x-spike-pairing-v0";

impl ProtocolHandler for ExporterProto {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let (mut send, mut recv) = connection.accept_bi().await?;
        let _ = recv.read_to_end(16).await;
        let mut out = [0u8; 32];
        connection
            .export_keying_material(&mut out, EXPORTER_LABEL, b"ctx")
            .map_err(|e| AcceptError::from_err(std::io::Error::other(format!("{e:?}"))))?;
        send.write_all(&out).await.map_err(AcceptError::from_err)?;
        send.finish()?;
        connection.closed().await;
        Ok(())
    }
}

async fn t7_exporter() -> Result<()> {
    println!("\n== T7 TLS exporter: both sides derive the same channel-binding secret");
    let mut seen = Vec::new();
    for (net, kx) in [(Net::DirectOnly, Kx::PreferPq), (Net::RelayOnly, Kx::PreferPq), (Net::DirectOnly, Kx::PreferPq)] {
        let allow = AllowList::default();
        let ep = make_endpoint(net, kx, Some(allow.clone()), None).await?;
        let router = Router::builder(ep).accept(EXPORTER_ALPN, ExporterProto).spawn();
        let bob = make_endpoint(net, kx, None, None).await?;
        allow.allow(bob.id());
        let mut target = EndpointAddr::new(router.endpoint().id());
        target = match net {
            Net::DirectOnly => target.with_ip_addr(router.endpoint().bound_sockets()[0]),
            _ => target.with_relay_url(relay_url_of(router.endpoint()).ok_or(anyhow!("no relay"))?),
        };
        let conn = match tokio::time::timeout(Duration::from_secs(20), bob.connect(target, EXPORTER_ALPN)).await {
            Ok(Ok(c)) => c,
            Ok(Err(e)) => bail!("connect: {e:#}"),
            Err(_) => bail!("connect timeout"),
        };
        let mut mine = [0u8; 32];
        conn.export_keying_material(&mut mine, EXPORTER_LABEL, b"ctx").map_err(|e| anyhow!("{e:?}"))?;
        let (mut send, mut recv) = conn.open_bi().await?;
        send.write_all(b"?").await?;
        send.finish()?;
        let theirs = recv.read_to_end(64).await?;
        let same = theirs.as_slice() == mine.as_slice();
        println!(
            "  {net:?} kx={}: exporter client={} server={} equal={same}",
            kx_group(&conn),
            data_encoding::HEXLOWER.encode(&mine[..8]),
            data_encoding::HEXLOWER.encode(&theirs[..8.min(theirs.len())])
        );
        if !same {
            bail!("exporter mismatch");
        }
        seen.push(mine);
        conn.close(0u32.into(), b"bye");
        router.shutdown().await?;
        bob.close().await;
    }
    let distinct = seen.iter().collect::<HashSet<_>>().len() == seen.len();
    println!("  exporters of different connections are distinct: {distinct}");
    Ok(())
}

// ---------- builders ----------

#[derive(Clone, Copy, Debug, PartialEq)]
enum Net {
    RelayOnly,
    DirectOnly,
    Both,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Kx {
    Default, // iroh default features: ring => classic X25519 only
    PreferPq,
    PqOnly,
}

fn provider(kx: Kx) -> Option<Arc<rustls::crypto::CryptoProvider>> {
    use rustls::crypto::aws_lc_rs::{self, kx_group};
    match kx {
        Kx::Default => None,
        Kx::PreferPq => {
            let mut p = aws_lc_rs::default_provider();
            p.kx_groups = vec![kx_group::X25519MLKEM768, kx_group::X25519];
            Some(Arc::new(p))
        }
        Kx::PqOnly => {
            let mut p = aws_lc_rs::default_provider();
            p.kx_groups = vec![kx_group::X25519MLKEM768];
            Some(Arc::new(p))
        }
    }
}

struct Node {
    router: Router,
    allow: AllowList,
}

impl Node {
    fn ep(&self) -> &Endpoint {
        self.router.endpoint()
    }
}

async fn make_endpoint(
    net: Net,
    kx: Kx,
    hooks: Option<AllowList>,
    secret: Option<SecretKey>,
) -> Result<Endpoint> {
    // Minimal = only the crypto provider; NO address lookup (pkarr publish/resolve, DNS) and no mDNS.
    let mut b = Endpoint::builder(presets::Minimal);
    if let Some(p) = provider(kx) {
        b = b.crypto_provider(p);
    }
    b = match net {
        Net::RelayOnly => b.relay_mode(RelayMode::Default).clear_ip_transports(),
        Net::DirectOnly => b.relay_mode(RelayMode::Disabled),
        Net::Both => b.relay_mode(RelayMode::Default),
    };
    if net == Net::DirectOnly {
        b = b.bind_addr("127.0.0.1:0")?;
    }
    if let Some(h) = hooks {
        b = b.hooks(h);
    }
    if let Some(s) = secret {
        b = b.secret_key(s);
    }
    let ep = b.bind().await.map_err(|e| anyhow!("bind: {e:#}"))?;
    if net != Net::DirectOnly {
        tokio::time::timeout(Duration::from_secs(20), ep.online())
            .await
            .context("endpoint.online() timeout (relay unreachable?)")?;
    }
    Ok(ep)
}

async fn make_listener(net: Net, kx: Kx) -> Result<Node> {
    let allow = AllowList::default();
    let ep = make_endpoint(net, kx, Some(allow.clone()), None).await?;
    let router = Router::builder(ep)
        .incoming_filter(incoming_filter(allow.clone()))
        .accept(ALPN, Echo)
        .spawn();
    Ok(Node { router, allow })
}

fn relay_url_of(ep: &Endpoint) -> Option<RelayUrl> {
    ep.addr().relay_urls().next().cloned()
}

// ---------- tests ----------

async fn t1_relay_only() -> Result<()> {
    println!("\n== T1 relay-only (clear_ip_transports, n0 relay, address lookup off)");
    let alice = make_listener(Net::RelayOnly, Kx::Default).await?;
    let bob = make_endpoint(Net::RelayOnly, Kx::Default, None, None).await?;
    alice.allow.allow(bob.id());
    let a_addr = alice.ep().addr();
    println!(
        "  alice id={} addr: relay={:?} ip_addrs={}",
        alice.ep().id().fmt_short(),
        relay_url_of(alice.ep()).map(|u| u.to_string()),
        a_addr.ip_addrs().count()
    );
    let target = EndpointAddr::new(alice.ep().id())
        .with_relay_url(relay_url_of(alice.ep()).ok_or(anyhow!("no relay"))?);
    let t = Instant::now();
    let conn = connect_to(&bob, target).await?;
    let t_conn = t.elapsed();
    let rtt1 = echo_roundtrip(&conn, b"hello via relay").await?;
    println!("  echo 15B via relay: {rtt1:?}");
    let rtt2 = echo_roundtrip(&conn, &vec![7u8; 64 * 1024]).await?;
    println!(
        "  OK connect {:?}; echo 15B {:?}; echo 64KiB {:?}; paths: {}; kx={}",
        t_conn,
        rtt1,
        rtt2,
        describe_paths(&conn),
        kx_group(&conn)
    );
    if conn.paths().iter().any(|p| p.is_ip()) {
        bail!("relay-only connection has an IP path!");
    }
    conn.close(0u32.into(), b"bye");
    alice.router.shutdown().await?;
    bob.close().await;
    Ok(())
}

async fn t2_direct_only() -> Result<()> {
    println!("\n== T2 direct-only (RelayMode::Disabled, 127.0.0.1)");
    let alice = make_listener(Net::DirectOnly, Kx::Default).await?;
    let bob = make_endpoint(Net::DirectOnly, Kx::Default, None, None).await?;
    alice.allow.allow(bob.id());
    let sock = alice.ep().bound_sockets()[0];
    let target = EndpointAddr::new(alice.ep().id()).with_ip_addr(sock);
    let t = Instant::now();
    let conn = connect_to(&bob, target).await?;
    let t_conn = t.elapsed();
    let rtt = echo_roundtrip(&conn, b"hello direct").await?;
    println!(
        "  OK connect {:?}; echo {:?}; paths: {}; kx={}",
        t_conn,
        rtt,
        describe_paths(&conn),
        kx_group(&conn)
    );
    conn.close(0u32.into(), b"bye");
    alice.router.shutdown().await?;
    bob.close().await;
    Ok(())
}

async fn t3_relay_then_direct() -> Result<()> {
    println!("\n== T3 relay+IP: dial by EndpointId + relay URL only, expect upgrade to direct path");
    let alice = make_listener(Net::Both, Kx::Default).await?;
    let bob = make_endpoint(Net::Both, Kx::Default, None, None).await?;
    alice.allow.allow(bob.id());
    let target = EndpointAddr::new(alice.ep().id())
        .with_relay_url(relay_url_of(alice.ep()).ok_or(anyhow!("no relay"))?);
    let t = Instant::now();
    let conn = connect_to(&bob, target).await?;
    println!("  connected in {:?}; paths at start: {}", t.elapsed(), describe_paths(&conn));
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut upgraded = false;
    while Instant::now() < deadline {
        if conn.paths().iter().any(|p| p.is_selected() && p.is_ip()) {
            upgraded = true;
            break;
        }
        let _ = echo_roundtrip(&conn, b"ping").await?;
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let rtt = echo_roundtrip(&conn, b"after upgrade").await?;
    println!(
        "  direct path selected: {} after {:?}; echo {:?}; paths: {}",
        upgraded,
        t.elapsed(),
        rtt,
        describe_paths(&conn)
    );
    conn.close(0u32.into(), b"bye");
    alice.router.shutdown().await?;
    bob.close().await;
    Ok(())
}

async fn t4_accept_list() -> Result<()> {
    println!("\n== T4 accept-list: unpaired key must be dropped");
    // Relay path: incoming_filter sees the EndpointId from the relay => Ignore without a reply.
    let alice = make_listener(Net::Both, Kx::Default).await?;
    let mallory = make_endpoint(Net::RelayOnly, Kx::Default, None, None).await?;
    let target = EndpointAddr::new(alice.ep().id())
        .with_relay_url(relay_url_of(alice.ep()).ok_or(anyhow!("no relay"))?);
    let t = Instant::now();
    let r = tokio::time::timeout(Duration::from_secs(8), mallory.connect(target, ALPN)).await;
    match r {
        Err(_) => println!(
            "  OK relay: mallory got NO response, gave up after {:?} (timeout)",
            t.elapsed()
        ),
        Ok(Ok(_)) => bail!("relay: unpaired mallory connected!"),
        Ok(Err(e)) => println!("  relay: mallory error after {:?}: {e:#}", t.elapsed()),
    }
    mallory.close().await;

    // Direct path: the ID is unknown before TLS => after_handshake hook Reject (CONNECTION_CLOSE 403).
    let alice2 = make_listener(Net::DirectOnly, Kx::Default).await?;
    let mallory2 = make_endpoint(Net::DirectOnly, Kx::Default, None, None).await?;
    let target = EndpointAddr::new(alice2.ep().id()).with_ip_addr(alice2.ep().bound_sockets()[0]);
    let t = Instant::now();
    match mallory2.connect(target, ALPN).await {
        Ok(conn) => {
            // The client handshake may finish before the server closes the connection.
            let res = echo_roundtrip(&conn, b"let me in").await;
            match res {
                Ok(_) => bail!("direct: unpaired mallory got echo!"),
                Err(e) => println!(
                    "  OK direct: TLS done, then closed by hook after {:?}: {e:#}",
                    t.elapsed()
                ),
            }
        }
        Err(e) => println!("  OK direct: connect failed after {:?}: {e:#}", t.elapsed()),
    }
    // paired bob on the same listener still works
    let bob = make_endpoint(Net::DirectOnly, Kx::Default, None, None).await?;
    alice2.allow.allow(bob.id());
    let target = EndpointAddr::new(alice2.ep().id()).with_ip_addr(alice2.ep().bound_sockets()[0]);
    let conn = connect_to(&bob, target).await?;
    echo_roundtrip(&conn, b"paired").await?;
    println!("  OK paired bob on the same endpoint: echo works");
    alice.router.shutdown().await?;
    alice2.router.shutdown().await?;
    Ok(())
}

/// T4c: a "PSK-like" pre-filter without a reply for direct UDP too: a secret link token in the ALPN.
/// The ALPN is in the ClientHello (an Initial packet, whose keys are public), visible to an on-path observer,
/// so this is NOT authentication, only weeding out scanners/strangers before the TLS work.
async fn t4c_alpn_token(kx: Kx) -> Result<()> {
    let token_alpn: Vec<u8> = b"x/link/1/3f9a0c55e1d24b7a".to_vec();
    let expected = token_alpn.clone();
    let allow = AllowList::default();
    let ep = make_endpoint(Net::DirectOnly, kx, Some(allow.clone()), None).await?;
    let filter: iroh::protocol::IncomingFilter = Arc::new(move |inc: &Incoming| {
        let alpns: Option<Vec<Vec<u8>>> = inc
            .decrypt()
            .and_then(|d| d.alpns())
            .map(|it| it.filter_map(|a| a.ok()).map(|b| b.to_vec()).collect());
        match alpns {
            Some(list) if list.iter().any(|a| *a == expected) => IncomingFilterOutcome::Accept,
            Some(list) => {
                eprintln!("    [alpn filter] wrong token {:?} -> Ignore", list.iter().map(|a| String::from_utf8_lossy(a).to_string()).collect::<Vec<_>>());
                IncomingFilterOutcome::Ignore
            }
            None => {
                eprintln!("    [alpn filter] ClientHello not parseable from first Initial (multi-packet?) -> Accept, rely on hook");
                IncomingFilterOutcome::Accept
            }
        }
    });
    let router = Router::builder(ep).incoming_filter(filter).accept(token_alpn.clone(), Echo).spawn();
    let sock = router.endpoint().bound_sockets()[0];
    let id = router.endpoint().id();
    // mallory: wrong token
    let mallory = make_endpoint(Net::DirectOnly, kx, None, None).await?;
    let t = Instant::now();
    match tokio::time::timeout(
        Duration::from_secs(5),
        mallory.connect(EndpointAddr::new(id).with_ip_addr(sock), b"x/link/1/0000000000000000"),
    )
    .await
    {
        Err(_) => println!("  [{kx:?}] OK mallory (wrong ALPN token, direct UDP): no response, timeout {:?}", t.elapsed()),
        Ok(Ok(_)) => println!("  [{kx:?}] mallory connected at TLS level (filter could not parse) — hook must reject"),
        Ok(Err(e)) => println!("  [{kx:?}] mallory error {:?}: {e:#}", t.elapsed()),
    }
    // bob: right token + paired
    let bob = make_endpoint(Net::DirectOnly, kx, None, None).await?;
    allow.allow(bob.id());
    let conn = match tokio::time::timeout(
        Duration::from_secs(10),
        bob.connect(EndpointAddr::new(id).with_ip_addr(sock), &token_alpn),
    )
    .await
    {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => bail!("bob connect: {e:#}"),
        Err(_) => bail!("bob connect timeout"),
    };
    echo_roundtrip(&conn, b"token ok").await?;
    println!("  [{kx:?}] OK bob (right token, paired): echo works, kx={}", kx_group(&conn));
    router.shutdown().await?;
    Ok(())
}

fn proc_stat() -> String {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let rss = status
        .lines()
        .find(|l| l.starts_with("VmRSS"))
        .unwrap_or("")
        .split_whitespace()
        .nth(1)
        .unwrap_or("?")
        .to_string();
    let threads = status
        .lines()
        .find(|l| l.starts_with("Threads"))
        .unwrap_or("")
        .split_whitespace()
        .nth(1)
        .unwrap_or("?")
        .to_string();
    let fds = std::fs::read_dir("/proc/self/fd").map(|d| d.count()).unwrap_or(0);
    format!("RSS={rss} kB, threads={threads}, fds={fds}")
}

async fn t5_many_endpoints(n: usize, pairs: usize) -> Result<()> {
    println!("\n== T5 many endpoints in one process: {n} pairwise endpoints with n0 relay");
    println!("  before: {}", proc_stat());
    let t = Instant::now();
    let mut nodes = Vec::new();
    for _ in 0..n {
        nodes.push(make_listener(Net::Both, Kx::Default).await?);
    }
    println!("  {n} endpoints bound+online in {:?}; {}", t.elapsed(), proc_stat());
    let relays: HashSet<String> = nodes
        .iter()
        .filter_map(|n| relay_url_of(n.ep()).map(|u| u.to_string()))
        .collect();
    println!("  distinct home relays: {relays:?}");
    // Each "link" has its own endpoint both on our side and at the contact.
    let t = Instant::now();
    let mut ok = 0;
    for node in nodes.iter().take(pairs) {
        let peer = make_endpoint(Net::Both, Kx::Default, None, None).await?;
        node.allow.allow(peer.id());
        let target = EndpointAddr::new(node.ep().id())
            .with_relay_url(relay_url_of(node.ep()).ok_or(anyhow!("no relay"))?);
        let conn = connect_to(&peer, target).await?;
        echo_roundtrip(&conn, b"pairwise").await?;
        ok += 1;
        conn.close(0u32.into(), b"bye");
        peer.close().await;
    }
    println!("  {ok}/{pairs} pairwise links echoed via relay in {:?}", t.elapsed());
    tokio::time::sleep(Duration::from_secs(5)).await;
    println!("  idle 5s with {n} endpoints: {}", proc_stat());
    for node in nodes {
        node.router.shutdown().await?;
    }
    println!("  after shutdown: {}", proc_stat());
    Ok(())
}

async fn t6_pq() -> Result<()> {
    println!("\n== T6 PQ key exchange inside iroh QUIC TLS (rustls aws-lc-rs)");
    // a) Default iroh (ring): which kx?
    {
        let alice = make_listener(Net::DirectOnly, Kx::Default).await?;
        let bob = make_endpoint(Net::DirectOnly, Kx::Default, None, None).await?;
        alice.allow.allow(bob.id());
        let target = EndpointAddr::new(alice.ep().id()).with_ip_addr(alice.ep().bound_sockets()[0]);
        let conn = connect_to(&bob, target).await?;
        echo_roundtrip(&conn, b"x").await?;
        println!("  default provider (ring): kx={}", kx_group(&conn));
        alice.router.shutdown().await?;
    }
    // b) PQ-only both sides, direct
    {
        let alice = make_listener(Net::DirectOnly, Kx::PqOnly).await?;
        let bob = make_endpoint(Net::DirectOnly, Kx::PqOnly, None, None).await?;
        alice.allow.allow(bob.id());
        let target = EndpointAddr::new(alice.ep().id()).with_ip_addr(alice.ep().bound_sockets()[0]);
        let conn = connect_to(&bob, target).await?;
        echo_roundtrip(&conn, b"x").await?;
        println!("  PQ-only direct: OK kx={}", kx_group(&conn));
        alice.router.shutdown().await?;
    }
    // c) prefer-PQ both sides via n0 relay only
    {
        let alice = make_listener(Net::RelayOnly, Kx::PreferPq).await?;
        let bob = make_endpoint(Net::RelayOnly, Kx::PreferPq, None, None).await?;
        alice.allow.allow(bob.id());
        let target = EndpointAddr::new(alice.ep().id())
            .with_relay_url(relay_url_of(alice.ep()).ok_or(anyhow!("no relay"))?);
        let conn = connect_to(&bob, target).await?;
        echo_roundtrip(&conn, b"x").await?;
        println!("  prefer-PQ via n0 relay: OK kx={} paths: {}", kx_group(&conn), describe_paths(&conn));
        alice.router.shutdown().await?;
    }
    // d) PQ-only via n0 relay (relay TLS shares the provider)
    {
        match tokio::time::timeout(
            Duration::from_secs(25),
            make_endpoint(Net::RelayOnly, Kx::PqOnly, None, None),
        )
        .await
        {
            Ok(Ok(ep)) => {
                println!("  PQ-only endpoint reached n0 relay: home relay {:?}", relay_url_of(&ep));
                ep.close().await;
            }
            Ok(Err(e)) => println!("  PQ-only endpoint vs n0 relay: FAILED: {e:#}"),
            Err(_) => println!("  PQ-only endpoint vs n0 relay: FAILED (timeout)"),
        }
    }
    Ok(())
}

// ---------- two-process mode ----------

async fn listen() -> Result<()> {
    let secret = SecretKey::generate();
    let alice = {
        let allow = AllowList::default();
        let ep = make_endpoint(Net::Both, Kx::PreferPq, Some(allow.clone()), Some(secret)).await?;
        let router = Router::builder(ep)
            .incoming_filter(incoming_filter(allow.clone()))
            .accept(ALPN, Echo)
            .spawn();
        Node { router, allow }
    };
    // Allow-list for the second process: taken from env if set (hex id).
    if let Ok(ids) = std::env::var("ALLOW") {
        for s in ids.split(',') {
            alice.allow.allow(s.parse().context("ALLOW id")?);
        }
    }
    println!("LISTEN id={} relay={}", alice.ep().id(), relay_url_of(alice.ep()).unwrap());
    println!("LISTEN direct={:?}", alice.ep().bound_sockets());
    tokio::time::sleep(Duration::from_secs(60)).await;
    alice.router.shutdown().await?;
    Ok(())
}

async fn dial(id: &str, relay: &str, direct: Option<&str>) -> Result<()> {
    let secret = match std::env::var("DIAL_SECRET_HEX") {
        Ok(h) => {
            let b = data_encoding::HEXLOWER.decode(h.as_bytes())?;
            SecretKey::from_bytes(&b.try_into().map_err(|_| anyhow!("32 bytes"))?)
        }
        Err(_) => SecretKey::generate(),
    };
    let ep = make_endpoint(Net::Both, Kx::PreferPq, None, Some(secret)).await?;
    println!("DIAL my id={}", ep.id());
    let mut target = EndpointAddr::new(id.parse()?).with_relay_url(relay.parse()?);
    if let Some(d) = direct {
        target = target.with_ip_addr(d.parse()?);
    }
    let t = Instant::now();
    let conn = connect_to(&ep, target).await?;
    let rtt = echo_roundtrip(&conn, b"cross-process hello").await?;
    println!(
        "DIAL OK connect+echo {:?} (echo {:?}) kx={} paths: {}",
        t.elapsed(),
        rtt,
        kx_group(&conn),
        describe_paths(&conn)
    );
    conn.close(0u32.into(), b"bye");
    ep.close().await;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str).unwrap_or("all") {
        "all" | "t1" | "t2" | "t3" | "t4" | "t4c" | "t5" | "t6" | "t7" => {
            let sel: Vec<&str> = if args[1..].is_empty() || args[1] == "all" {
                vec!["t1", "t2", "t3", "t4", "t4c", "t6", "t7", "t5"]
            } else {
                args[1..].iter().map(String::as_str).collect()
            };
            let mut failed = 0;
            for t in sel {
                let r = match t {
                    "t1" => t1_relay_only().await,
                    "t2" => t2_direct_only().await,
                    "t3" => t3_relay_then_direct().await,
                    "t4" => t4_accept_list().await,
                    "t6" => t6_pq().await,
                    "t7" => t7_exporter().await,
                    "t4c" => match t4c_alpn_token(Kx::Default).await {
                        Ok(()) => t4c_alpn_token(Kx::PreferPq).await,
                        e => e,
                    },
                    "t5" => {
                        let n = std::env::var("N").ok().and_then(|s| s.parse().ok()).unwrap_or(50);
                        let pairs = std::env::var("PAIRS").ok().and_then(|s| s.parse().ok()).unwrap_or(10);
                        t5_many_endpoints(n, pairs).await
                    }
                    _ => Err(anyhow!("unknown test")),
                };
                if let Err(e) = r {
                    failed += 1;
                    println!("  FAILED {t}: {e:#}");
                }
            }
            println!("\nDONE, failed={failed}");
        }
        "listen" => listen().await?,
        "id" => {
            let b = data_encoding::HEXLOWER.decode(args[2].as_bytes())?;
            let sk = SecretKey::from_bytes(&b.try_into().map_err(|_| anyhow!("32 bytes"))?);
            println!("{}", sk.public());
        }
        "dial" => dial(&args[2], &args[3], args.get(4).map(String::as_str)).await?,
        other => bail!("unknown mode {other}"),
    }
    Ok(())
}
