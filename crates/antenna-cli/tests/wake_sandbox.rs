// SPDX-License-Identifier: AGPL-3.0-only
//! The agent sandbox for wake (`antenna_core::sandbox`, SPEC §11 "Wake", "Two sandboxes", §13, §9 "Taint outlives the
//! session"): the real supervisor `antennad --antenna-wake-exec`, the agent is `/bin/sh -c '…'`. Every test runs in
//! every available mode (Linux: bwrap and Landlock; macOS: Seatbelt, D-P-13); an unavailable mode prints a `SKIP: …`
//! line (a GitHub runner may have no bwrap).
//!
//! Run: `cargo test -p antenna-cli --test wake_sandbox -- --nocapture` (from the workspace root, so that `antennad` is
//! built); to match the runner, with extra fds: `bash -c 'exec 7</dev/null 8</dev/null; cargo test …'`.

#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

use antenna_core::sandbox::{
    self, Limits, ProxyBridge, ProxyConfig, Running, SandboxKind, SandboxSpec,
};
use tokio::io::AsyncReadExt;

fn antennad() -> PathBuf {
    let p = PathBuf::from(env!("CARGO_BIN_EXE_antenna")).with_file_name("antennad");
    assert!(
        p.exists(),
        "antennad binary not found at {} — run `cargo test` from the workspace root (or `cargo build -p antennad` first)",
        p.display()
    );
    p
}

/// Available modes; an unavailable one prints `SKIP`.
fn modes(test: &str) -> Vec<SandboxKind> {
    let s = sandbox::probe();
    let mut v = Vec::new();
    if cfg!(target_os = "macos") {
        if s.kind == Some(SandboxKind::Seatbelt) {
            v.push(SandboxKind::Seatbelt);
        } else {
            println!("SKIP: {test} [seatbelt]: {}", s.detail);
        }
        return v;
    }
    if s.bwrap.is_some() {
        v.push(SandboxKind::Bwrap);
    } else {
        println!("SKIP: {test} [bwrap]: {}", s.detail);
    }
    if s.landlock_abi >= 4 {
        v.push(SandboxKind::Landlock);
    } else {
        println!("SKIP: {test} [landlock]: ABI {}", s.landlock_abi);
    }
    v
}

/// A unique run marker (to find processes and content).
fn nonce() -> String {
    use std::sync::atomic::{AtomicU32, Ordering};
    static N: AtomicU32 = AtomicU32::new(0);
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .subsec_micros();
    format!(
        "{}{:06}{}",
        std::process::id() % 1000,
        t,
        N.fetch_add(1, Ordering::SeqCst)
    )
}

struct Dirs {
    root: tempfile::TempDir,
    cwd: PathBuf,
    home: PathBuf,
    tmp: PathBuf,
    rw: PathBuf,
}

fn dirs() -> Dirs {
    let root = tempfile::tempdir().unwrap();
    let p = root.path().to_path_buf();
    // home and tmp are not created in advance: launch creates them.
    let cwd = p.join("cwd");
    std::fs::create_dir(&cwd).unwrap();
    Dirs {
        root,
        cwd,
        home: p.join("home"),
        tmp: p.join("tmp"),
        rw: p.join("shared"),
    }
}

fn spec(kind: SandboxKind, d: &Dirs, script: &str) -> SandboxSpec {
    SandboxSpec {
        argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
        env: vec![
            ("PATH".into(), "/usr/bin:/bin".into()),
            ("LC_ALL".into(), "C".into()),
        ],
        cwd: d.cwd.clone(),
        home: d.home.clone(),
        tmp: d.tmp.clone(),
        rw: vec![d.rw.clone()],
        ro: vec![],
        ro_binds: vec![],
        sockets: vec![],
        proxy: None,
        limits: Limits {
            nofile: 256,
            fsize_bytes: 64 << 20,
            cpu_secs: 60,
            data_bytes: 0,
        },
        kind,
        start_gate: false,
        agent_stdin: false,
        listen: None,
        gpu: false,
    }
}

struct Out {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl Out {
    fn has(&self, line: &str) -> bool {
        self.stdout.lines().any(|l| l.trim() == line)
    }
}

impl std::fmt::Display for Out {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "code={:?}\n--- stdout\n{}--- stderr\n{}",
            self.code, self.stdout, self.stderr
        )
    }
}

/// Run and wait for the end (stdout and stderr at EOF means the whole agent tree has died).
async fn run(spec: &SandboxSpec) -> Out {
    let mut r = sandbox::launch(spec, &antennad()).await.expect("launch");
    let mut so = r.stdout.take().unwrap();
    let mut se = r.stderr.take().unwrap();
    let (mut a, mut b) = (String::new(), String::new());
    let st = tokio::time::timeout(Duration::from_secs(60), async {
        let (_, _, s) = tokio::join!(
            so.read_to_string(&mut a),
            se.read_to_string(&mut b),
            r.wait()
        );
        s
    })
    .await
    .expect("agent timed out")
    .unwrap();
    r.stop(Duration::from_secs(1)).await;
    let o = Out {
        code: st.code(),
        stdout: a,
        stderr: b,
    };
    println!("[{:?}] {o}", spec.kind);
    o
}

/// A command that runs a program in a new session (leaving the agent's process group): macOS has no `setsid` utility,
/// so perl does the same.
fn setsid() -> &'static str {
    if cfg!(target_os = "macos") {
        "perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127'"
    } else {
        "setsid"
    }
}

/// Processes whose command line contains `marker` (zombies, with an empty command line, do not count).
#[cfg(target_os = "macos")]
fn procs_with(marker: &str) -> Vec<i32> {
    let out = Command::new("/bin/ps")
        .args(["-axo", "pid=,command="])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| l.contains(marker))
        .filter_map(|l| l.split_whitespace().next()?.parse().ok())
        .collect()
}

/// Processes whose command line contains `marker` (zombies, with an empty command line, do not count).
#[cfg(target_os = "linux")]
fn procs_with(marker: &str) -> Vec<i32> {
    let mut v = Vec::new();
    for e in std::fs::read_dir("/proc").unwrap().flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else {
            continue;
        };
        if let Ok(c) = std::fs::read(format!("/proc/{pid}/cmdline"))
            && String::from_utf8_lossy(&c).contains(marker)
        {
            v.push(pid);
        }
    }
    v
}

async fn wait_procs(marker: &str, want: usize) {
    let t = Instant::now();
    while procs_with(marker).len() < want {
        assert!(
            t.elapsed() < Duration::from_secs(10),
            "processes {marker} did not start: {:?}",
            procs_with(marker)
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn gone_within(marker: &str, limit: Duration) -> bool {
    let t = Instant::now();
    loop {
        if procs_with(marker).is_empty() {
            return true;
        }
        if t.elapsed() > limit {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// 1. Files: writes only to cwd/home/tmp/rw; the owner's "agent memory" (`~/.claude`, CLAUDE.md) cannot be written;
/// the daemon data directory (keystore) cannot be read; credentials from `ro_binds` can be read but not written.
#[tokio::test(flavor = "multi_thread")]
async fn files_only_what_the_spec_allows() {
    for kind in modes("files_only_what_the_spec_allows") {
        let d = dirs();
        let n = nonce();
        let owner = d.root.path().join("owner-claude");
        std::fs::create_dir(&owner).unwrap();
        std::fs::write(owner.join("CLAUDE.md"), "owner rules").unwrap();
        let data = d.root.path().join("daemon-data");
        std::fs::create_dir(&data).unwrap();
        std::fs::write(data.join("keystore.cbor"), "secret-key").unwrap();
        let cred_src = d.root.path().join("owner-cred").join(".credentials.json");
        std::fs::create_dir(cred_src.parent().unwrap()).unwrap();
        std::fs::write(&cred_src, format!("token-{n}")).unwrap();
        let cred_dst = d.home.join(".claude").join(".credentials.json");
        let script = format!(
            r#"
w() {{ if (echo agent > "$1") 2>/dev/null; then echo "W ok $2"; else echo "W no $2"; fi; }}
r() {{ if cat "$1" >/dev/null 2>&1; then echo "R ok $2"; else echo "R no $2"; fi; }}
w "$PWD/f" cwd; w "$HOME/f" home; w "$TMPDIR/f" tmp; w '{rw}/f' rw
w '{owner}/CLAUDE.md' claude-md; w '{owner}/new' claude-new
r '{data}/keystore.cbor' keystore
if ls '{data}' >/dev/null 2>&1; then echo "L ok data"; else echo "L no data"; fi
r '{cred}' cred; w '{cred}' cred
echo "C $(cat '{cred}')"
r /etc/shadow shadow; r /etc/passwd passwd
"#,
            rw = d.rw.display(),
            owner = owner.display(),
            data = data.display(),
            cred = cred_dst.display(),
        );
        let mut s = spec(kind, &d, &script);
        s.ro_binds = vec![(cred_src.clone(), cred_dst.clone())];
        let o = run(&s).await;
        assert_eq!(o.code, Some(0), "{o}");
        for l in [
            "W ok cwd",
            "W ok home",
            "W ok tmp",
            "W ok rw",
            "W no claude-md",
            "W no claude-new",
            "R no keystore",
            "L no data",
            "R ok cred",
            "W no cred",
            "R no shadow",
            "R ok passwd",
        ] {
            assert!(o.has(l), "{kind:?}: expected {l:?}\n{o}");
        }
        assert!(o.has(&format!("C token-{n}")), "{o}");
        // On the host: the allowed files are written, the others are untouched.
        for f in [
            d.cwd.join("f"),
            d.home.join("f"),
            d.tmp.join("f"),
            d.rw.join("f"),
        ] {
            assert_eq!(std::fs::read_to_string(&f).unwrap(), "agent\n", "{f:?}");
        }
        assert_eq!(
            std::fs::read_to_string(owner.join("CLAUDE.md")).unwrap(),
            "owner rules"
        );
        assert!(!owner.join("new").exists());
        assert_eq!(
            std::fs::read_to_string(&cred_src).unwrap(),
            format!("token-{n}")
        );
        assert!(
            o.stderr
                .contains(&format!("{} kind={}", sandbox::NOTE_PREFIX, kind.as_str())),
            "{o}"
        );
    }
}

/// 2. The environment is exactly the spec (+ HOME/TMPDIR by default); no daemon variables.
#[tokio::test(flavor = "multi_thread")]
async fn environment_is_only_the_spec() {
    for kind in modes("environment_is_only_the_spec") {
        let d = dirs();
        let mut s = spec(kind, &d, "");
        s.argv = vec!["/usr/bin/env".into()];
        s.env.push(("ANTENNA_AGENT_VAR".into(), "yes".into()));
        let o = run(&s).await;
        assert_eq!(o.code, Some(0), "{o}");
        let mut keys: Vec<&str> = o
            .stdout
            .lines()
            .filter_map(|l| l.split_once('=').map(|(k, _)| k))
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            ["ANTENNA_AGENT_VAR", "HOME", "LC_ALL", "PATH", "TMPDIR"],
            "{o}"
        );
        assert!(o.has(&format!("HOME={}", d.home.display())), "{o}");
        // No variable of the "daemon" process (except those that match by meaning) is visible.
        for (k, v) in std::env::vars() {
            if ["PATH", "HOME", "LC_ALL", "TMPDIR"].contains(&k.as_str()) {
                continue;
            }
            assert!(!o.has(&format!("{k}={v}")), "{kind:?}: leaked {k}\n{o}");
        }
    }
}

/// The test's HTTP server on 127.0.0.1: answers with `body`, counts connections.
fn http_server(body: String) -> (u16, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let h = hits.clone();
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            h.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let body = body.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 2048];
                let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
                let _ = s.read(&mut buf);
                let _ = write!(
                    s,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
            });
        }
    });
    (port, hits)
}

/// 3. Network: to an allowed host only through the bridge to the proxy; to a disallowed one, 403; no direct TCP; no
///    UDP.
#[tokio::test(flavor = "multi_thread")]
async fn network_only_through_the_proxy() {
    // bash comes from the spec's PATH (`/usr/bin:/bin`): `/usr/bin/bash` on Linux, `/bin/bash` on macOS.
    if !Path::new("/usr/bin/curl").exists()
        || !(Path::new("/usr/bin/bash").exists() || Path::new("/bin/bash").exists())
    {
        println!("SKIP: network_only_through_the_proxy: no /usr/bin/curl or bash");
        return;
    }
    for kind in modes("network_only_through_the_proxy") {
        let d = dirs();
        let n = nonce();
        let (port, hits) = http_server(format!("proxied-{n}"));
        let udp = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        udp.set_read_timeout(Some(Duration::from_millis(300)))
            .unwrap();
        let uport = udp.local_addr().unwrap().port();
        let sock = d.root.path().join("proxy.sock");
        let proxy = sandbox::start_proxy(
            &sock,
            ProxyConfig {
                allow_hosts: vec!["localhost".into()],
                allow_ports: vec![port],
                // Test only: the server is on 127.0.0.1.
                allow_private: true,
            },
        )
        .await
        .unwrap();
        let script = format!(
            r#"
echo "proxy=$HTTPS_PROXY"
curl -sS -m 10 -p --proxy "$HTTPS_PROXY" "http://localhost:{port}/"; echo " rc=$?"
curl -sS -m 10 -p --proxy "$HTTPS_PROXY" "http://blocked.example:{port}/" 2>&1; echo " rc=$?"
curl -sS -m 5 --noproxy '*' "http://127.0.0.1:{port}/" 2>&1; echo " rc=$?"
if bash -c 'exec 3<>/dev/tcp/127.0.0.1/{port}' 2>/dev/null; then echo "TCP open"; else echo "TCP closed"; fi
if bash -c 'echo udp-{n} > /dev/udp/127.0.0.1/{uport}' 2>/dev/null; then echo "UDP sent"; else echo "UDP denied"; fi
"#
        );
        let mut s = spec(kind, &d, &script);
        s.proxy = Some(ProxyBridge {
            unix: sock.clone(),
            // bwrap has its own network, so any port works; without it the host network is shared, so a free one.
            port: if kind == SandboxKind::Bwrap { 3128 } else { 0 },
        });
        let o = run(&s).await;
        assert_eq!(o.code, Some(0), "{o}");
        assert!(o.stdout.contains(&format!("proxied-{n} rc=0")), "{o}");
        assert!(
            o.stdout.contains("CONNECT tunnel failed, response 403"),
            "{o}"
        );
        assert!(o.has("TCP closed"), "{o}");
        assert!(o.has("UDP denied"), "{o}");
        // The direct curl did not reach the server: there is one connection, from the proxy.
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1, "{o}");
        let mut buf = [0u8; 64];
        assert!(udp.recv(&mut buf).is_err(), "UDP datagram escaped\n{o}");
        let st = proxy.stats();
        assert_eq!(
            st.allowed,
            vec![("localhost".to_string(), port, 1)],
            "{st:?}"
        );
        assert_eq!(
            st.blocked,
            vec![("blocked.example".to_string(), port, 1)],
            "{st:?}"
        );
    }
}

/// Facts for the CI log (`FACT …`; the `core` job on macOS checks Seatbelt, Linux checks bwrap/Landlock): writing to
/// the owner's "memory" (`CLAUDE.md`) is denied, reading the daemon directory is denied, direct TCP is denied, through
/// the daemon proxy it works.
#[tokio::test(flavor = "multi_thread")]
async fn facts_for_the_log() {
    if !Path::new("/usr/bin/curl").exists() {
        println!("SKIP: facts_for_the_log: no /usr/bin/curl");
        return;
    }
    for kind in modes("facts_for_the_log") {
        let d = dirs();
        let n = nonce();
        let owner = d.root.path().join("owner-home").join(".claude");
        std::fs::create_dir_all(&owner).unwrap();
        std::fs::write(owner.join("CLAUDE.md"), "owner rules\n").unwrap();
        let data = d.root.path().join("daemon-data");
        std::fs::create_dir(&data).unwrap();
        std::fs::write(data.join("keystore.cbor"), "secret-key").unwrap();
        let (port, hits) = http_server(format!("proxied-{n}"));
        let sock = d.root.path().join("proxy.sock");
        let proxy = sandbox::start_proxy(
            &sock,
            ProxyConfig {
                allow_hosts: vec!["localhost".into()],
                allow_ports: vec![port],
                // Test only: the server is on 127.0.0.1.
                allow_private: true,
            },
        )
        .await
        .unwrap();
        let script = format!(
            r#"if (echo pwned >> '{owner}/CLAUDE.md') 2>/dev/null; then echo claude_md_write=ALLOWED; else echo claude_md_write=denied; fi
if cat '{data}/keystore.cbor' >/dev/null 2>&1; then echo keystore_read=ALLOWED; else echo keystore_read=denied; fi
if curl -sS -m 5 --noproxy '*' "http://127.0.0.1:{port}/" >/dev/null 2>&1; then echo direct_tcp=ALLOWED; else echo direct_tcp=denied; fi
if curl -sS -m 10 -p --proxy "$HTTPS_PROXY" "http://localhost:{port}/" 2>/dev/null | grep -q 'proxied-{n}'; then echo via_proxy=ok; else echo via_proxy=FAILED; fi"#,
            owner = owner.display(),
            data = data.display(),
        );
        let mut s = spec(kind, &d, &script);
        s.proxy = Some(ProxyBridge {
            unix: sock.clone(),
            port: if kind == SandboxKind::Bwrap { 3128 } else { 0 },
        });
        let o = run(&s).await;
        let facts: Vec<&str> = o.stdout.lines().filter(|l| l.contains('=')).collect();
        println!("FACT agent sandbox={} {}", kind.as_str(), facts.join(" "));
        for want in [
            "claude_md_write=denied",
            "keystore_read=denied",
            "direct_tcp=denied",
            "via_proxy=ok",
        ] {
            assert!(o.has(want), "{kind:?}: expected {want}\n{o}");
        }
        assert_eq!(
            std::fs::read_to_string(owner.join("CLAUDE.md")).unwrap(),
            "owner rules\n"
        );
        // Exactly one connection reached the server: through the proxy.
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1, "{o}");
        assert_eq!(
            proxy.stats().allowed,
            vec![("localhost".to_string(), port, 1)]
        );
    }
}

/// 4. Process tree: a double fork and `setsid` do not take processes away: once the agent ends, they are gone.
#[tokio::test(flavor = "multi_thread")]
async fn orphans_die_with_the_agent() {
    for kind in modes("orphans_die_with_the_agent") {
        let d = dirs();
        let n = nonce();
        let script = format!(
            "({} sleep 600.{n} >/dev/null 2>&1 &) ; (sleep 601.{n} &) ; sleep 602.{n} & echo started",
            setsid()
        );
        let o = run(&spec(kind, &d, &script)).await;
        assert!(o.has("started"), "{o}");
        assert!(
            gone_within(&format!(".{n}"), Duration::from_secs(2)).await,
            "{kind:?}: left behind: {:?}",
            procs_with(&format!(".{n}"))
        );
    }
}

/// 4b. The agent cannot escape supervision: `kill -9 $PPID` (the supervisor), a signal to an unrelated process of the
/// same uid and `kill -9 -1` (all processes of the uid: the daemon, the owner's session) do not reach them; its orphans
/// are reaped.
#[tokio::test(flavor = "multi_thread")]
async fn agent_cannot_kill_its_supervisor() {
    for kind in modes("agent_cannot_kill_its_supervisor") {
        let d = dirs();
        let n = nonce();
        // An unrelated process of the same user (like the daemon or the owner's window).
        let mut victim = Command::new("/bin/sleep").arg("60").spawn().unwrap();
        let script = format!(
            r#"({setsid} sleep 610.{n} >/dev/null 2>&1 &)
kill -9 $PPID 2>/dev/null; echo "ppid rc=$?"
kill -9 {victim} 2>/dev/null; echo "victim rc=$?"
kill -9 -1 2>/dev/null; echo "all rc=$?"
sleep 0.3; echo alive"#,
            setsid = setsid(),
            victim = victim.id()
        );
        let o = run(&spec(kind, &d, &script)).await;
        let victim_alive = victim.try_wait().unwrap().is_none();
        if kind == SandboxKind::Landlock {
            // A known limit of the Landlock mode before ABI 6 (Support.detail, CONTROL §11 item 11): signals to other
            // processes of the uid.
            println!(
                "NOTE: landlock mode, a signal to another same-user process: victim alive={victim_alive}"
            );
        } else {
            assert!(o.has("victim rc=1"), "{o}");
            assert!(victim_alive, "{kind:?}: the victim was killed\n{o}");
        }
        let _ = victim.kill();
        let _ = victim.wait();
        if kind == SandboxKind::Seatbelt {
            // Signals only within its own sandbox: the supervisor and everything outside are unreachable (`EPERM`);
            // `kill -9 -1` (on macOS POSIX includes the process itself) kills only the agent's sandbox, the agent
            // included.
            assert!(o.has("ppid rc=1"), "{o}");
            assert!(
                o.code == Some(0) || o.code == Some(128 + 9),
                "the supervisor must report the agent's own exit\n{o}"
            );
        } else {
            assert_eq!(o.code, Some(0), "{o}");
            assert!(o.has("alive"), "{o}");
            assert!(o.has("all rc=1"), "{o}");
        }
        if kind == SandboxKind::Landlock {
            // Without a pidns the supervisor is an ordinary process of the same uid: seccomp (and the Landlock ABI ≥ 6
            // scope).
            assert!(o.has("ppid rc=1"), "{o}");
        }
        assert!(
            gone_within(&format!(".{n}"), Duration::from_secs(2)).await,
            "{kind:?}: left behind: {:?}",
            procs_with(&format!(".{n}"))
        );
    }
}

/// 5. rlimits: core 0, nofile from the spec.
#[tokio::test(flavor = "multi_thread")]
async fn resource_limits_apply() {
    for kind in modes("resource_limits_apply") {
        let d = dirs();
        let o = run(&spec(
            kind,
            &d,
            r#"echo "core=$(ulimit -c) nofile=$(ulimit -n)""#,
        ))
        .await;
        assert!(o.has("core=0 nofile=256"), "{o}");
    }
}

/// The test's unix socket: answers every connection with the HTTP response `body`.
fn unix_server(path: &Path, body: String) {
    let l = std::os::unix::net::UnixListener::bind(path).unwrap();
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            let mut buf = [0u8; 2048];
            let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
            let _ = s.read(&mut buf);
            let _ = write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
        }
    });
}

/// 6. A unix socket from `sockets` (the daemon control socket) is reachable; another one is closed only in bwrap.
#[tokio::test(flavor = "multi_thread")]
async fn spec_socket_is_reachable() {
    if !Path::new("/usr/bin/curl").exists() {
        println!("SKIP: spec_socket_is_reachable: no /usr/bin/curl");
        return;
    }
    for kind in modes("spec_socket_is_reachable") {
        let d = dirs();
        let n = nonce();
        let sdir = d.root.path().join("daemon");
        std::fs::create_dir(&sdir).unwrap();
        let ctl = sdir.join("antennad.sock");
        let other = sdir.join("other.sock");
        unix_server(&ctl, format!("ctl-{n}"));
        unix_server(&other, format!("other-{n}"));
        let script = format!(
            r#"curl -sS -m 5 --unix-socket '{}' http://antenna/; echo " rc=$?"
curl -sS -m 5 --unix-socket '{}' http://antenna/ 2>/dev/null; echo " rc=$?""#,
            ctl.display(),
            other.display()
        );
        let mut s = spec(kind, &d, &script);
        s.sockets = vec![ctl.clone()];
        let o = run(&s).await;
        assert!(o.stdout.contains(&format!("ctl-{n} rc=0")), "{o}");
        let other_reached = o.stdout.contains(&format!("other-{n}"));
        match kind {
            // bwrap: the socket does not exist in the sandbox; Seatbelt: `network-outbound` only to the spec's sockets.
            SandboxKind::Bwrap | SandboxKind::Seatbelt => assert!(!other_reached, "{o}"),
            // A known limit of the Landlock mode (Support.detail): unix sockets of the same user are not closed.
            SandboxKind::Landlock => println!(
                "NOTE: landlock mode, a same-user unix socket outside the spec reachable: {other_reached}"
            ),
        }
    }
}

/// 7. Lifeline: `stop` closes the supervisor's stdin and the whole tree dies within ≤ grace; so does `drop`.
#[tokio::test(flavor = "multi_thread")]
async fn lifeline_stops_the_whole_tree() {
    for kind in modes("lifeline_stops_the_whole_tree") {
        let d = dirs();
        let n = nonce();
        let marker = format!(".{n}");
        let script = format!(
            "({} sleep 700.{n} &) ; (sleep 701.{n} &) ; exec sleep 702.{n}",
            setsid()
        );
        let mut r = sandbox::launch(&spec(kind, &d, &script), &antennad())
            .await
            .unwrap();
        wait_procs(&marker, 3).await;
        let grace = Duration::from_secs(3);
        let t = Instant::now();
        r.stop(grace).await;
        let took = t.elapsed();
        assert!(took < grace, "{kind:?}: stop took {took:?}");
        assert!(
            gone_within(&marker, Duration::from_millis(500)).await,
            "{kind:?}: after stop: {:?}",
            procs_with(&marker)
        );
        // The daemon abandoned the agent without stop.
        let n = nonce();
        let marker = format!(".{n}");
        let script = format!(
            "({} sleep 703.{n} &) ; (sleep 704.{n} &) ; exec sleep 705.{n}",
            setsid()
        );
        let r: Running = sandbox::launch(&spec(kind, &d, &script), &antennad())
            .await
            .unwrap();
        wait_procs(&marker, 3).await;
        drop(r);
        assert!(
            gone_within(&marker, Duration::from_secs(3)).await,
            "{kind:?}: after drop: {:?}",
            procs_with(&marker)
        );
    }
}

/// 8. Inherited fds: the test process holds fds 7 and 8 without CLOEXEC (like a GitHub runner); the sandbox gets none.
#[test]
fn inherited_descriptors_do_not_reach_the_agent() {
    const ENV: &str = "ANTENNA_WAKE_FDS_CHILD";
    const NAME: &str = "inherited_descriptors_do_not_reach_the_agent";
    // Directory of our own descriptors: `/proc/self/fd` on Linux, `/dev/fd` on macOS.
    let fd_dir = if cfg!(target_os = "macos") {
        "/dev/fd"
    } else {
        "/proc/self/fd"
    };
    if std::env::var_os(ENV).is_some() {
        // The child: the process itself has fd 7, the agent does not.
        let own = Path::new(&format!("{fd_dir}/7")).exists();
        let rt = tokio::runtime::Runtime::new().unwrap();
        for kind in modes(NAME) {
            let d = dirs();
            let o = rt.block_on(run(&spec(
                kind,
                &d,
                &format!(
                    "for i in 3 4 5 6 7 8 9; do [ -e {fd_dir}/$i ] && echo \"open $i\"; done; echo done"
                ),
            )));
            let open: Vec<&str> = o.stdout.lines().filter(|l| l.starts_with("open")).collect();
            println!("RESULT kind={kind:?} own7={own} agent_open={open:?}");
        }
        return;
    }
    let me = std::env::current_exe().unwrap();
    let out = Command::new("/bin/sh")
        .arg("-c")
        .arg(r#"exec 7<"$0" 8<"$0"; exec "$0" --exact "$1" --nocapture --test-threads=1"#)
        .arg(&me)
        .arg(NAME)
        .env(ENV, "1")
        .output()
        .unwrap();
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    // With `--nocapture` libtest prints `test <name> ... ` without a newline, so the child's first line follows it on
    // the same line: match anywhere in the line, not at its start.
    let results: Vec<&str> = text
        .lines()
        .filter(|l| l.contains("RESULT kind="))
        .collect();
    let skips = text.lines().filter(|l| l.contains("SKIP: ")).count();
    // Modes: bwrap and Landlock on Linux, Seatbelt on macOS.
    let want = if cfg!(target_os = "macos") { 1 } else { 2 };
    assert_eq!(results.len() + skips, want, "{text}");
    for r in &results {
        assert!(r.ends_with("own7=true agent_open=[]"), "{text}");
    }
    for l in text.lines().filter(|l| l.contains("SKIP: ")) {
        println!("{l}");
    }
}

/// A live agent binary: `claude --version` starts in the sandbox (no network, so no subscription usage).
#[tokio::test(flavor = "multi_thread")]
async fn claude_binary_starts_in_the_sandbox() {
    let claude = Path::new("/usr/bin/claude");
    if !claude.exists() {
        println!("SKIP: claude_binary_starts_in_the_sandbox: no /usr/bin/claude");
        return;
    }
    for kind in modes("claude_binary_starts_in_the_sandbox") {
        let d = dirs();
        let mut s = spec(kind, &d, "");
        s.argv = vec![claude.display().to_string(), "--version".into()];
        let o = run(&s).await;
        assert_eq!(o.code, Some(0), "{o}");
        assert!(
            o.stdout.chars().next().is_some_and(|c| c.is_ascii_digit()),
            "{o}"
        );
    }
}

/// Probe: what was found, for the run log.
#[test]
fn probe_reports_what_is_available() {
    let s = sandbox::probe();
    println!(
        "probe: kind={:?} bwrap={:?} landlock_abi={} detail={}",
        s.kind, s.bwrap, s.landlock_abi, s.detail
    );
    if cfg!(target_os = "macos") {
        assert_eq!(s.kind, Some(SandboxKind::Seatbelt));
    } else if s.bwrap.is_some() {
        assert_eq!(s.kind, Some(SandboxKind::Bwrap));
    } else if s.landlock_abi >= 4 {
        assert_eq!(s.kind, Some(SandboxKind::Landlock));
    } else {
        assert_eq!(s.kind, None);
    }
    // A nonexistent agent program gives a clear error, not a crash.
    let d = dirs();
    let mut sp = spec(s.kind.unwrap_or(SandboxKind::Landlock), &d, "");
    sp.argv = vec!["/nonexistent/agent".into()];
    let rt = tokio::runtime::Runtime::new().unwrap();
    let e = rt
        .block_on(sandbox::launch(&sp, &antennad()))
        .err()
        .expect("must fail");
    assert_eq!(e.code, "not_found", "{e}");
}
