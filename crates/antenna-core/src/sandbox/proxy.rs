// SPDX-License-Identifier: AGPL-3.0-only
//! The daemon's CONNECT proxy for a sandboxed agent (SPEC §11 "Two sandboxes": the agent gets outgoing connections to
//! the model provider only).
//!
//! Listens on a unix socket with mode 0600; inside the sandbox the supervisor's bridge leads to it (`127.0.0.1:port` ⇄
//! socket). Accepts only `CONNECT host:port HTTP/1.x` (a header ≤ 8 KiB within 10 s): the host from `allow_hosts` (an
//! exact name or `*.domain`), the port from `allow_ports`; the daemon resolves the name, and without `allow_private`
//! loopback/private/link-local/ULA/CGNAT/unspecified/multicast/documentation addresses (including inside IPv4-mapped,
//! NAT64, 6to4) are dropped, so DNS spoofing cannot lead the agent into the internal network. Then
//! `200 Connection established` and a transparent tunnel (TLS runs between the agent and the provider; the proxy does
//! not see the content). Anything else gets `403` (and the `blocked` counter), a malformed request `400`, a failed
//! connection `502`, more than 64 connections at once `503`.
//!
//! Windows: the proxy's socket and the bridge into the agent sandbox there are WP-20 (D-134, phase W3); [`start_proxy`]
//! refuses with `sandbox_unavailable`. The rules (allowlist, CONNECT parsing, public addresses) are the same and are
//! tested on every OS.
#![cfg_attr(
    windows,
    allow(
        dead_code,
        reason = "on Windows nothing serves connections until WP-20; the rules stay compiled and tested"
    )
)]

use std::{
    collections::BTreeMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use tokio::net::TcpStream;
#[cfg(unix)]
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
    task::JoinSet,
};

use crate::error::{Error, Result};

/// CONNECT header limit.
const MAX_HEADER: usize = 8 * 1024;
/// Time allowed for the header.
const HEADER_TIMEOUT: Duration = Duration::from_secs(10);
/// Time allowed to connect to the provider (per address).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Concurrent connections.
const MAX_CONNECTIONS: usize = 64;

/// Proxy rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyConfig {
    /// Allowed hosts: an exact name (`api.anthropic.com`), `*.domain` (any subdomain, not the domain itself) or an IP
    /// literal.
    pub allow_hosts: Vec<String>,
    /// Allowed ports; an empty list means `[443]`.
    pub allow_ports: Vec<u16>,
    /// `false` (always in the product): loopback/private/link-local/ULA/CGNAT/unspecified addresses after resolving are
    /// refused. `true` is for tests only.
    pub allow_private: bool,
}

impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            allow_hosts: Vec::new(),
            allow_ports: vec![443],
            allow_private: false,
        }
    }
}

/// Proxy counters.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProxyStats {
    /// CONNECTs let through by the rules: (host, port, count).
    pub allowed: Vec<(String, u16, u64)>,
    /// Rule refusals (403): (host, port, count); a non-CONNECT request has host `""`, port 0.
    pub blocked: Vec<(String, u16, u64)>,
    /// Bytes from the agent to the provider (over closed tunnels).
    pub bytes_up: u64,
    /// Bytes from the provider to the agent (over closed tunnels).
    pub bytes_down: u64,
    /// Allowed, but the connection failed (resolving, internal addresses only, timeout): 502.
    pub upstream_errors: u64,
}

#[derive(Default)]
struct Counters {
    allowed: BTreeMap<(String, u16), u64>,
    blocked: BTreeMap<(String, u16), u64>,
    bytes_up: u64,
    bytes_down: u64,
    upstream_errors: u64,
}

/// A running proxy; `drop` stops it (the socket is removed, tunnels are torn down).
pub struct ProxyHandle {
    path: PathBuf,
    counters: Arc<Mutex<Counters>>,
    task: tokio::task::JoinHandle<()>,
}

impl ProxyHandle {
    /// Counters.
    pub fn stats(&self) -> ProxyStats {
        let c = self.counters.lock().unwrap_or_else(|e| e.into_inner());
        let flat = |m: &BTreeMap<(String, u16), u64>| {
            m.iter()
                .map(|((h, p), n)| (h.clone(), *p, *n))
                .collect::<Vec<_>>()
        };
        ProxyStats {
            allowed: flat(&c.allowed),
            blocked: flat(&c.blocked),
            bytes_up: c.bytes_up,
            bytes_down: c.bytes_down,
            upstream_errors: c.upstream_errors,
        }
    }

    /// Socket path: the one asked for, or a short one when that was too long for a unix socket ([`start_proxy`]).
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ProxyHandle {
    fn drop(&mut self) {
        // The accept task owns the JoinSet of tunnels: cancelling it cancels them too.
        self.task.abort();
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Where the proxy socket goes: `path`, or, when `path` does not fit a unix socket address (`sun_path`: 107 bytes on
/// Linux, 103 on macOS; a long data folder, such as one under macOS's `$TMPDIR` in the tests, made a resident agent's
/// socket 105 bytes long), a socket named by a hash of `path` in a private short directory of this user,
/// `/tmp/antenna-<uid>`. The directory is created with `mkdir` and mode 0700 and used only if it is a real directory of
/// this user that nobody else can enter; a name squatted by someone else falls back to a random one. The directory stays
/// for later proxies of the user; the socket is removed with its proxy.
#[cfg(unix)]
fn socket_location(path: &Path) -> Result<PathBuf> {
    if path.as_os_str().len() <= crate::control::MAX_SOCKET_PATH {
        return Ok(path.to_path_buf());
    }
    let hex = |b: &[u8]| data_encoding::HEXLOWER.encode(&b[..6]);
    let name = format!(
        "{}.sock",
        hex(&crate::crypto::blake3_dk(
            "antenna proxy socket name",
            path.as_os_str().as_encoded_bytes()
        ))
    );
    let dir = private_tmp_dir()?;
    remove_stale_sockets(&dir);
    Ok(dir.join(&name))
}

/// A private directory for sockets whose natural path is too long for `sun_path`: `/tmp/antenna-<uid>` (0700, owned
/// by us), or a random `/tmp/antenna-<hex>` when another user holds that name.
#[cfg(unix)]
pub(crate) fn private_tmp_dir() -> Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    let hex = |b: &[u8]| data_encoding::HEXLOWER.encode(&b[..6]);
    let uid = rustix::process::geteuid().as_raw();
    let ours = |d: &Path| {
        std::fs::symlink_metadata(d)
            .is_ok_and(|m| m.is_dir() && m.uid() == uid && m.permissions().mode() & 0o077 == 0)
    };
    let random = (0..8).map(|_| hex(&crate::crypto::random::<6>()));
    for tag in std::iter::once(uid.to_string()).chain(random) {
        let dir = PathBuf::from(format!("/tmp/antenna-{tag}"));
        match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => {
                return Err(Error::internal(format!("proxy dir {}: {e}", dir.display())));
            }
        }
        if ours(&dir) {
            return Ok(dir);
        }
    }
    Err(Error::internal(
        "cannot create a private directory for the proxy socket in /tmp",
    ))
}

/// Sockets in the short directory whose proxy is gone (a daemon that was killed): nobody accepts a connection there.
#[cfg(unix)]
fn remove_stale_sockets(dir: &Path) {
    use std::os::unix::fs::FileTypeExt;
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        if e.file_type().is_ok_and(|t| t.is_socket())
            && std::os::unix::net::UnixStream::connect(&p)
                .is_err_and(|e| e.kind() == std::io::ErrorKind::ConnectionRefused)
        {
            let _ = std::fs::remove_file(&p);
        }
    }
}

/// Starts the proxy on the unix socket `path` (mode 0600; an old socket at that path is removed, any other file is an
/// error), or on a short path when `path` is too long for a unix socket ([`ProxyHandle::path`] says which). Call it
/// inside a tokio runtime.
#[cfg(unix)]
pub async fn start_proxy(path: &Path, cfg: ProxyConfig) -> Result<ProxyHandle> {
    use std::os::unix::fs::{FileTypeExt, PermissionsExt};
    let sock = socket_location(path)?;
    let path = sock.as_path();
    if let Ok(m) = std::fs::symlink_metadata(path) {
        if m.file_type().is_socket() {
            std::fs::remove_file(path)?;
        } else {
            return Err(Error::bad_request(format!(
                "proxy socket path is occupied by a non-socket: {}",
                path.display()
            )));
        }
    }
    let listener = UnixListener::bind(path)
        .map_err(|e| Error::internal(format!("proxy bind {}: {e}", path.display())))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let rules = Arc::new(Rules::new(cfg));
    let counters = Arc::new(Mutex::new(Counters::default()));
    let c2 = counters.clone();
    let task = tokio::spawn(async move {
        let limit = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        let mut tunnels = JoinSet::new();
        loop {
            tokio::select! {
                acc = listener.accept() => {
                    let Ok((stream, _)) = acc else { continue };
                    let rules = rules.clone();
                    let counters = c2.clone();
                    match limit.clone().try_acquire_owned() {
                        Ok(permit) => {
                            tunnels.spawn(async move {
                                serve(stream, &rules, &counters).await;
                                drop(permit);
                            });
                        }
                        Err(_) => {
                            tunnels.spawn(async move {
                                let mut s = stream;
                                let _ = s.write_all(&reply(503, "Too Many Connections")).await;
                            });
                        }
                    }
                }
                Some(_) = tunnels.join_next(), if !tunnels.is_empty() => {}
            }
        }
    });
    Ok(ProxyHandle {
        path: path.to_path_buf(),
        counters,
        task,
    })
}

/// Windows: refused (WP-20): the proxy serves only the agent sandbox, which Windows does not have yet.
#[cfg(windows)]
pub async fn start_proxy(_path: &Path, _cfg: ProxyConfig) -> Result<ProxyHandle> {
    Err(Error::new(
        antenna_proto::control::code::SANDBOX_UNAVAILABLE,
        "the agent sandbox and its proxy are not available on Windows yet",
    ))
}

fn reply(status: u16, reason: &str) -> Vec<u8> {
    format!("HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        .into_bytes()
}

fn bump(m: &mut BTreeMap<(String, u16), u64>, host: &str, port: u16) {
    *m.entry((host.to_string(), port)).or_insert(0) += 1;
}

#[cfg(unix)]
async fn serve(mut stream: UnixStream, rules: &Rules, counters: &Mutex<Counters>) {
    let lock = || counters.lock().unwrap_or_else(|e| e.into_inner());
    let (head, rest) = match tokio::time::timeout(HEADER_TIMEOUT, read_head(&mut stream)).await {
        Ok(Ok(v)) => v,
        _ => {
            let _ = stream.write_all(&reply(400, "Bad Request")).await;
            return;
        }
    };
    let target = match parse_connect(&head) {
        Ok(t) => t,
        Err(Parse::NotConnect) => {
            bump(&mut lock().blocked, "", 0);
            tracing::info!("agent proxy: blocked a non-CONNECT request");
            let _ = stream.write_all(&reply(403, "Forbidden")).await;
            return;
        }
        Err(Parse::Malformed) => {
            let _ = stream.write_all(&reply(400, "Bad Request")).await;
            return;
        }
    };
    if !rules.allows(&target.host, target.port) {
        bump(&mut lock().blocked, &target.host, target.port);
        tracing::info!(
            "agent proxy: blocked CONNECT {}:{}",
            target.host,
            target.port
        );
        let _ = stream.write_all(&reply(403, "Forbidden")).await;
        return;
    }
    bump(&mut lock().allowed, &target.host, target.port);
    let upstream = match connect_upstream(&target, rules.allow_private).await {
        Ok(s) => s,
        Err(e) => {
            lock().upstream_errors += 1;
            tracing::info!(
                "agent proxy: CONNECT {}:{} failed: {e}",
                target.host,
                target.port
            );
            let _ = stream.write_all(&reply(502, "Bad Gateway")).await;
            return;
        }
    };
    let mut upstream = upstream;
    if stream
        .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
        .await
        .is_err()
    {
        return;
    }
    // Bytes that came right after the header (the client did not wait for the response) go to the provider first.
    if !rest.is_empty() && upstream.write_all(&rest).await.is_err() {
        return;
    }
    if let Ok((up, down)) = tokio::io::copy_bidirectional(&mut stream, &mut upstream).await {
        let mut c = lock();
        c.bytes_up += up + rest.len() as u64;
        c.bytes_down += down;
    }
}

/// Read the header up to the empty line: (header, the rest after it).
#[cfg(unix)]
async fn read_head(s: &mut UnixStream) -> std::io::Result<(String, Vec<u8>)> {
    let mut buf = Vec::with_capacity(512);
    let mut chunk = [0u8; 1024];
    loop {
        let n = s.read(&mut chunk).await?;
        if n == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some((end, skip)) = find_head_end(&buf) {
            let rest = buf.split_off(end + skip);
            buf.truncate(end);
            let head = String::from_utf8(buf).map_err(|_| std::io::ErrorKind::InvalidData)?;
            return Ok((head, rest));
        }
        if buf.len() > MAX_HEADER {
            return Err(std::io::ErrorKind::InvalidData.into());
        }
    }
}

fn find_head_end(b: &[u8]) -> Option<(usize, usize)> {
    if let Some(i) = b.windows(4).position(|w| w == b"\r\n\r\n") {
        return Some((i, 4));
    }
    b.windows(2).position(|w| w == b"\n\n").map(|i| (i, 2))
}

/// CONNECT target.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Target {
    /// Lowercase name without a trailing dot, or an IP literal (IPv6 without brackets).
    host: String,
    port: u16,
}

#[derive(Debug, PartialEq, Eq)]
enum Parse {
    NotConnect,
    Malformed,
}

fn parse_connect(head: &str) -> std::result::Result<Target, Parse> {
    let line = head.lines().next().ok_or(Parse::Malformed)?;
    let mut parts = line.split(' ');
    let (Some(method), Some(authority), Some(version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(Parse::Malformed);
    };
    if !version.starts_with("HTTP/1.") {
        return Err(Parse::Malformed);
    }
    if method != "CONNECT" {
        return Err(Parse::NotConnect);
    }
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let (h, p) = rest.split_once("]:").ok_or(Parse::Malformed)?;
        let ip: Ipv6Addr = h.parse().map_err(|_| Parse::Malformed)?;
        (ip.to_string(), p)
    } else {
        let (h, p) = authority.rsplit_once(':').ok_or(Parse::Malformed)?;
        (h.to_string(), p)
    };
    let port: u16 = port.parse().map_err(|_| Parse::Malformed)?;
    if port == 0 {
        return Err(Parse::Malformed);
    }
    let host = normalize_host(&host).ok_or(Parse::Malformed)?;
    Ok(Target { host, port })
}

/// Name: letters, digits, `-`, `.`, `_`; lowercase, no trailing dot. An IP literal stays as is (canonical form).
fn normalize_host(h: &str) -> Option<String> {
    if let Ok(ip) = h.parse::<IpAddr>() {
        return Some(ip.to_string());
    }
    let h = h.strip_suffix('.').unwrap_or(h).to_ascii_lowercase();
    let ok = !h.is_empty()
        && h.len() <= 253
        && h.split('.').all(|l| {
            !l.is_empty()
                && l.len() <= 63
                && l.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        });
    ok.then_some(h)
}

struct Rules {
    exact: Vec<String>,
    suffixes: Vec<String>,
    ports: Vec<u16>,
    allow_private: bool,
}

impl Rules {
    fn new(cfg: ProxyConfig) -> Self {
        let mut exact = Vec::new();
        let mut suffixes = Vec::new();
        for h in &cfg.allow_hosts {
            let h = h.trim();
            if let Some(d) = h.strip_prefix("*.") {
                if let Some(d) = normalize_host(d) {
                    suffixes.push(format!(".{d}"));
                }
            } else if let Some(h) = normalize_host(h) {
                exact.push(h);
            }
        }
        let ports = if cfg.allow_ports.is_empty() {
            vec![443]
        } else {
            cfg.allow_ports
        };
        Self {
            exact,
            suffixes,
            ports,
            allow_private: cfg.allow_private,
        }
    }

    fn allows(&self, host: &str, port: u16) -> bool {
        if !self.ports.contains(&port) {
            return false;
        }
        if self.exact.iter().any(|h| h == host) {
            return true;
        }
        // `*.domain`: names only (not IP literals) and subdomains only.
        host.parse::<IpAddr>().is_err() && self.suffixes.iter().any(|s| host.ends_with(s.as_str()))
    }
}

async fn connect_upstream(t: &Target, allow_private: bool) -> std::io::Result<TcpStream> {
    let addrs: Vec<SocketAddr> = tokio::time::timeout(
        CONNECT_TIMEOUT,
        tokio::net::lookup_host((t.host.as_str(), t.port)),
    )
    .await
    .map_err(|_| std::io::Error::from(std::io::ErrorKind::TimedOut))??
    .collect();
    let usable: Vec<SocketAddr> = addrs
        .into_iter()
        .filter(|a| allow_private || is_public(a.ip()))
        .collect();
    if usable.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "no public address",
        ));
    }
    let mut last = std::io::Error::from(std::io::ErrorKind::NotFound);
    for a in usable {
        match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(a)).await {
            Ok(Ok(s)) => {
                let _ = s.set_nodelay(true);
                return Ok(s);
            }
            Ok(Err(e)) => last = e,
            Err(_) => last = std::io::ErrorKind::TimedOut.into(),
        }
    }
    Err(last)
}

/// Whether the address is public (otherwise it is refused without `allow_private`).
fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local()
        || ip.is_multicast()
        || ip.is_broadcast()
        || ip.is_documentation()
        || o[0] == 0 // 0.0.0.0/8 "this host"
        || (o[0] == 100 && (o[1] & 0xc0) == 64) // 100.64.0.0/10 CGNAT
        || (o[0] == 192 && o[1] == 0 && o[2] == 0) // 192.0.0.0/24 IETF
        || (o[0] == 198 && (o[1] & 0xfe) == 18) // 198.18.0.0/15 benchmarking
        || o[0] >= 240) // 240.0.0.0/4 reserved
}

fn is_public_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    let s = ip.segments();
    // ::/96 (IPv4-compatible, deprecated) and 64:ff9b::/96 (NAT64): by the embedded IPv4.
    if (s[0..6] == [0, 0, 0, 0, 0, 0] && !ip.is_unspecified() && !ip.is_loopback())
        || s[0..6] == [0x64, 0xff9b, 0, 0, 0, 0]
    {
        let o = ip.octets();
        return is_public_v4(Ipv4Addr::new(o[12], o[13], o[14], o[15]));
    }
    // 2002::/16 (6to4): by the embedded IPv4.
    if s[0] == 0x2002 {
        let o = ip.octets();
        return is_public_v4(Ipv4Addr::new(o[2], o[3], o[4], o[5]));
    }
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_multicast()
        || (s[0] & 0xfe00) == 0xfc00 // fc00::/7 ULA
        || (s[0] & 0xffc0) == 0xfe80 // fe80::/10 link-local
        || (s[0] & 0xffc0) == 0xfec0 // fec0::/10 site-local (deprecated)
        || (s[0] == 0x2001 && s[1] == 0x0db8)) // 2001:db8::/32 documentation
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules(hosts: &[&str], ports: &[u16]) -> Rules {
        Rules::new(ProxyConfig {
            allow_hosts: hosts.iter().map(|s| s.to_string()).collect(),
            allow_ports: ports.to_vec(),
            allow_private: false,
        })
    }

    /// A socket path longer than `sun_path` allows (a long data folder, macOS's `$TMPDIR`) moves to the user's short
    /// private directory, under a name that is the same for the same path; a short path stays; a socket left by a
    /// killed proxy there is removed, a live one is not.
    // Unix sockets and `/tmp`; the proxy on Windows is WP-20.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_long_socket_path_moves_to_a_short_private_directory() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let short = Path::new("/tmp/x/proxy.sock");
        assert_eq!(socket_location(short).unwrap(), short);
        let long = PathBuf::from(format!("/tmp/{}/proxy.sock", "d".repeat(120)));
        let p = socket_location(&long).unwrap();
        assert!(
            p.as_os_str().len() <= crate::control::MAX_SOCKET_PATH,
            "{p:?}"
        );
        assert_eq!(
            socket_location(&long).unwrap(),
            p,
            "the same name for the same path"
        );
        let dir = p.parent().unwrap().to_path_buf();
        let uid = rustix::process::geteuid().as_raw();
        assert_eq!(dir, PathBuf::from(format!("/tmp/antenna-{uid}")));
        let m = std::fs::symlink_metadata(&dir).unwrap();
        assert!(m.is_dir() && m.uid() == uid && m.permissions().mode() & 0o077 == 0);
        let proxy = start_proxy(&long, ProxyConfig::default()).await.unwrap();
        assert_eq!(proxy.path(), p);
        // A stale socket (its listener is gone) is cleaned up by the next proxy in that directory; the live one stays.
        let stale = dir.join("000000000000.sock");
        drop(std::os::unix::net::UnixListener::bind(&stale).unwrap());
        let other = PathBuf::from(format!("/tmp/{}/proxy.sock", "e".repeat(120)));
        let q = socket_location(&other).unwrap();
        assert!(!stale.exists(), "stale socket removed");
        assert!(p.exists(), "a live proxy's socket stays");
        assert_ne!(p, q);
        drop(proxy);
        assert!(!p.exists(), "the proxy removes its socket");
    }

    #[test]
    fn parses_connect_lines() {
        assert_eq!(
            parse_connect("CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443"),
            Ok(Target {
                host: "api.anthropic.com".into(),
                port: 443
            })
        );
        // Case and a trailing dot are normalized.
        assert_eq!(
            parse_connect("CONNECT API.Anthropic.COM.:443 HTTP/1.0")
                .unwrap()
                .host,
            "api.anthropic.com"
        );
        assert_eq!(
            parse_connect("CONNECT [2001:DB8::1]:8443 HTTP/1.1"),
            Ok(Target {
                host: "2001:db8::1".into(),
                port: 8443
            })
        );
        assert_eq!(
            parse_connect("CONNECT 127.0.0.1:443 HTTP/1.1")
                .unwrap()
                .host,
            "127.0.0.1"
        );
        for bad in [
            "",
            "CONNECT api.anthropic.com HTTP/1.1",
            "CONNECT api.anthropic.com:0 HTTP/1.1",
            "CONNECT api.anthropic.com:99999 HTTP/1.1",
            "CONNECT api.anthropic.com:443",
            "CONNECT api.anthropic.com:443 HTTP/2",
            "CONNECT api.anthropic.com:443 HTTP/1.1 extra",
            "CONNECT a..b:443 HTTP/1.1",
            "CONNECT a/b:443 HTTP/1.1",
            "CONNECT a@b:443 HTTP/1.1",
            "CONNECT [::1:443 HTTP/1.1",
            "CONNECT :443 HTTP/1.1",
        ] {
            assert_eq!(parse_connect(bad), Err(Parse::Malformed), "{bad:?}");
        }
        for not in [
            "GET http://api.anthropic.com/ HTTP/1.1",
            "POST http://x/ HTTP/1.1",
            "connect api.anthropic.com:443 HTTP/1.1",
        ] {
            assert_eq!(parse_connect(not), Err(Parse::NotConnect), "{not:?}");
        }
    }

    #[test]
    fn head_end_and_rest() {
        assert_eq!(
            find_head_end(b"CONNECT a:1 HTTP/1.1\r\n\r\nXY"),
            Some((20, 4))
        );
        assert_eq!(find_head_end(b"CONNECT a:1 HTTP/1.1\n\n"), Some((20, 2)));
        assert_eq!(find_head_end(b"CONNECT a:1 HTTP/1.1\r\n"), None);
    }

    #[test]
    fn allowlist_exact_and_wildcard() {
        let r = rules(&["api.anthropic.com", "*.openai.com", "1.2.3.4"], &[443]);
        assert!(r.allows("api.anthropic.com", 443));
        assert!(!r.allows("api.anthropic.com", 80));
        assert!(!r.allows("evil-api.anthropic.com", 443));
        assert!(!r.allows("anthropic.com", 443));
        assert!(!r.allows("api.anthropic.com.evil.com", 443));
        assert!(r.allows("api.openai.com", 443));
        assert!(r.allows("a.b.openai.com", 443));
        assert!(!r.allows("openai.com", 443), "`*.` — only subdomains");
        assert!(!r.allows("evilopenai.com", 443));
        assert!(r.allows("1.2.3.4", 443));
        assert!(!r.allows("1.2.3.5", 443));
        // An empty port list means 443.
        let r = rules(&["x.example"], &[]);
        assert!(r.allows("x.example", 443) && !r.allows("x.example", 8443));
        // Patterns are normalized too; "*" on its own allows nothing.
        let r = rules(&["*.Example.COM.", "*"], &[443]);
        assert!(r.allows("a.example.com", 443));
        assert!(!r.allows("example.org", 443));
    }

    #[test]
    fn private_addresses_are_refused() {
        for a in [
            "0.0.0.0",
            "0.1.2.3",
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "100.127.255.255",
            "192.0.0.1",
            "198.18.0.1",
            "224.0.0.1",
            "240.0.0.1",
            "255.255.255.255",
            "192.0.2.1",
            "::",
            "::1",
            "fe80::1",
            "fc00::1",
            "fd12:3456::1",
            "fec0::1",
            "ff02::1",
            "2001:db8::1",
            "::ffff:127.0.0.1",
            "::ffff:169.254.169.254",
            "::127.0.0.1",
            "64:ff9b::a00:1",
            "2002:c0a8:0101::1",
        ] {
            let ip: IpAddr = a.parse().unwrap();
            assert!(!is_public(ip), "{a} must be refused");
        }
        for a in [
            "1.1.1.1",
            "8.8.8.8",
            "100.128.0.1",
            "172.32.0.1",
            "160.79.104.10",
            "2606:4700::1111",
            "::ffff:1.1.1.1",
            "64:ff9b::808:808",
            "2002:0808:0808::1",
        ] {
            let ip: IpAddr = a.parse().unwrap();
            assert!(is_public(ip), "{a} is public");
        }
    }

    /// A live proxy on a unix socket: allowlist, 403 for a foreign host and for GET, refusal of an internal address
    /// without `allow_private`, a tunnel to an allowed server with `allow_private`, and the counters.
    // A unix socket; the proxy on Windows is WP-20.
    #[cfg(unix)]
    #[tokio::test]
    async fn live_proxy_tunnels_and_refuses() {
        let dir = tempfile::tempdir().unwrap();
        let srv = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = srv.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = srv.accept().await {
                tokio::spawn(async move {
                    let mut b = [0u8; 5];
                    if s.read_exact(&mut b).await.is_ok() {
                        let _ = s.write_all(&b).await;
                    }
                });
            }
        });
        async fn ask(sock: &Path, req: &str, payload: &[u8]) -> (String, Vec<u8>) {
            let mut s = UnixStream::connect(sock).await.unwrap();
            s.write_all(req.as_bytes()).await.unwrap();
            s.write_all(payload).await.unwrap();
            let mut out = Vec::new();
            let _ = tokio::time::timeout(Duration::from_secs(5), s.read_to_end(&mut out)).await;
            let text = String::from_utf8_lossy(&out).to_string();
            let body = out
                .windows(4)
                .position(|w| w == b"\r\n\r\n")
                .map(|i| out[i + 4..].to_vec())
                .unwrap_or_default();
            (text, body)
        }
        // allow_private = false: 127.0.0.1 after resolving gives 502.
        let sock = dir.path().join("p.sock");
        let p = start_proxy(
            &sock,
            ProxyConfig {
                allow_hosts: vec!["localhost".into()],
                allow_ports: vec![port],
                allow_private: false,
            },
        )
        .await
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&sock).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let (t, _) = ask(
            &sock,
            &format!("CONNECT localhost:{port} HTTP/1.1\r\n\r\n"),
            b"",
        )
        .await;
        assert!(t.starts_with("HTTP/1.1 502"), "{t}");
        assert_eq!(p.stats().upstream_errors, 1);
        drop(p);
        assert!(!sock.exists(), "socket removed on drop");
        // allow_private = true (test): a tunnel; extra bytes after the header get through.
        let p = start_proxy(
            &sock,
            ProxyConfig {
                allow_hosts: vec!["localhost".into()],
                allow_ports: vec![port],
                allow_private: true,
            },
        )
        .await
        .unwrap();
        let (t, body) = ask(
            &sock,
            &format!("CONNECT localhost:{port} HTTP/1.1\r\nHost: localhost\r\n\r\n"),
            b"hello",
        )
        .await;
        assert!(t.starts_with("HTTP/1.1 200"), "{t}");
        assert_eq!(body, b"hello");
        let (t, _) = ask(
            &sock,
            &format!("CONNECT example.com:{port} HTTP/1.1\r\n\r\n"),
            b"",
        )
        .await;
        assert!(t.starts_with("HTTP/1.1 403"), "{t}");
        let (t, _) = ask(&sock, "CONNECT localhost:1 HTTP/1.1\r\n\r\n", b"").await;
        assert!(t.starts_with("HTTP/1.1 403"), "{t}");
        let (t, _) = ask(
            &sock,
            &format!("GET http://localhost:{port}/ HTTP/1.1\r\n\r\n"),
            b"",
        )
        .await;
        assert!(t.starts_with("HTTP/1.1 403"), "{t}");
        let (t, _) = ask(&sock, "garbage\r\n\r\n", b"").await;
        assert!(t.starts_with("HTTP/1.1 400"), "{t}");
        let st = p.stats();
        assert_eq!(st.allowed, vec![("localhost".to_string(), port, 1)]);
        assert!(st.blocked.contains(&("example.com".to_string(), port, 1)));
        assert!(st.blocked.contains(&("localhost".to_string(), 1, 1)));
        assert!(st.blocked.contains(&(String::new(), 0, 1)));
        assert_eq!((st.bytes_up, st.bytes_down), (5, 5));
        // A path taken by a non-socket is an error.
        let f = dir.path().join("file");
        std::fs::write(&f, b"x").unwrap();
        assert!(start_proxy(&f, ProxyConfig::default()).await.is_err());
    }
}
