// SPDX-License-Identifier: AGPL-3.0-only
//! Shared by the Linux (bwrap/Landlock) and macOS (Seatbelt) sandboxes: spec validation, run directories, read-only
//! credentials through a symlink, the proxy bridge, the agent environment, stage 2 rlimits.

use std::{
    io::{BufRead, Read},
    net::{Shutdown, TcpListener, TcpStream},
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::UnixStream,
    },
    path::{Component, Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

use antenna_proto::control::code;
use serde::Deserialize;

use super::{ProxyBridge, SandboxSpec};
use crate::error::{Error, Result};

/// Spec line limit.
const MAX_SPEC: u64 = 4 << 20;
/// Concurrent connections through the bridge (same as the proxy).
const MAX_BRIDGE: usize = 64;
/// Proxy variables the supervisor sets for the agent.
const PROXY_VARS: &[&str] = &[
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "https_proxy",
    "http_proxy",
    "ALL_PROXY",
    "all_proxy",
];

/// The path is absolute and has no `..`/`.`.
fn clean_abs(p: &Path, what: &str) -> Result<()> {
    if !p.is_absolute()
        || p.components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(Error::bad_request(format!(
            "sandbox: {what} must be an absolute path without `..`: {}",
            p.display()
        )));
    }
    Ok(())
}

pub(super) fn validate(spec: &SandboxSpec, supervisor_exe: &Path) -> Result<()> {
    let Some(prog) = spec.argv.first() else {
        return Err(Error::bad_request("sandbox: empty argv"));
    };
    let prog = Path::new(prog);
    clean_abs(prog, "argv[0]")?;
    match std::fs::metadata(prog) {
        Ok(m) if m.is_file() && m.mode() & 0o111 != 0 => {}
        Ok(_) => {
            return Err(Error::bad_request(format!(
                "sandbox: agent program is not an executable file: {}",
                prog.display()
            )));
        }
        Err(e) => {
            return Err(Error::new(
                code::NOT_FOUND,
                format!("sandbox: agent program {}: {e}", prog.display()),
            ));
        }
    }
    clean_abs(supervisor_exe, "supervisor")?;
    if !supervisor_exe.is_file() {
        return Err(Error::new(
            code::NOT_FOUND,
            format!("sandbox: supervisor {} not found", supervisor_exe.display()),
        ));
    }
    clean_abs(&spec.cwd, "cwd")?;
    clean_abs(&spec.home, "home")?;
    clean_abs(&spec.tmp, "tmp")?;
    for p in spec.rw.iter().chain(&spec.ro).chain(&spec.sockets) {
        clean_abs(p, "path")?;
    }
    for (s, d) in &spec.ro_binds {
        clean_abs(s, "ro_bind source")?;
        clean_abs(d, "ro_bind destination")?;
    }
    if let Some(b) = &spec.proxy {
        clean_abs(&b.unix, "proxy socket")?;
    }
    if let Some(l) = &spec.listen {
        clean_abs(l, "listen socket")?;
        if spec.proxy.is_some() {
            return Err(Error::bad_request(
                "sandbox: a program that only listens gets no proxy",
            ));
        }
        let inside = [&spec.cwd, &spec.home, &spec.tmp]
            .into_iter()
            .chain(&spec.rw)
            .any(|d| l.parent() == Some(d.as_path()));
        if !inside {
            return Err(Error::bad_request(
                "sandbox: the listen socket must be directly in a writable folder of the spec",
            ));
        }
    }
    for (k, v) in &spec.env {
        if k.is_empty() || k.contains('=') || k.contains('\0') || v.contains('\0') {
            return Err(Error::bad_request(format!(
                "sandbox: bad environment variable name {k:?}"
            )));
        }
    }
    if spec.argv.iter().any(|a| a.contains('\0')) {
        return Err(Error::bad_request("sandbox: NUL in argv"));
    }
    Ok(())
}

/// Writable directories: create them if missing (0700).
pub(super) fn ensure_dirs(spec: &SandboxSpec) -> Result<()> {
    for d in [&spec.cwd, &spec.home, &spec.tmp]
        .into_iter()
        .chain(&spec.rw)
    {
        if !d.is_dir() {
            std::fs::create_dir_all(d)
                .map_err(|e| Error::internal(format!("sandbox: create {}: {e}", d.display())))?;
            let _ = std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700));
        }
    }
    Ok(())
}

/// `ro_binds` without mounting (Landlock, Seatbelt mode): the destination is a symlink to the source. Reads follow the
/// source's rule, writes are refused (the source is not among the writable paths), the owner's original is unchanged.
pub(super) fn link_ro_binds(spec: &SandboxSpec) -> Result<()> {
    for (src, dst) in &spec.ro_binds {
        if !src.exists() {
            continue;
        }
        if let Some(parent) = dst.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                Error::internal(format!("sandbox: create {}: {e}", parent.display()))
            })?;
        }
        if let Ok(m) = std::fs::symlink_metadata(dst) {
            if m.is_dir() {
                return Err(Error::bad_request(format!(
                    "sandbox: ro_bind destination is a directory: {}",
                    dst.display()
                )));
            }
            std::fs::remove_file(dst)?;
        }
        std::os::unix::fs::symlink(src, dst)
            .map_err(|e| Error::internal(format!("sandbox: symlink {}: {e}", dst.display())))?;
    }
    Ok(())
}

/// The agent program itself and its real path (if it is a symlink), so that it is visible and can run.
pub(super) fn program_paths(spec: &SandboxSpec) -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(p) = spec.argv.first() {
        let p = PathBuf::from(p);
        if let Ok(real) = std::fs::canonicalize(&p)
            && real != p
        {
            v.push(real);
        }
        v.push(p);
    }
    v
}

/// A JSON line from stdin (the spec for the supervisor, the stage 2 plan).
pub(super) fn read_line_json<T: for<'de> Deserialize<'de>>() -> std::result::Result<T, String> {
    let mut line = String::new();
    std::io::stdin()
        .lock()
        .take(MAX_SPEC)
        .read_line(&mut line)
        .map_err(|e| format!("read spec: {e}"))?;
    serde_json::from_str(line.trim_end()).map_err(|e| format!("bad spec: {e}"))
}

/// Stage 2 reads its plan one byte at a time: with [`SandboxSpec::agent_stdin`] the same pipe becomes the agent's
/// stdin after `exec`, and a buffered reader would swallow the start of the agent's input (std's `Stdin` buffers up
/// to 8 KiB, and that buffer does not survive `exec`).
pub(super) fn read_line_json_unbuffered<T: for<'de> Deserialize<'de>>()
-> std::result::Result<T, String> {
    use std::os::fd::AsFd;
    let stdin = std::io::stdin();
    let fd = stdin.as_fd();
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    loop {
        match rustix::io::read(fd, &mut b) {
            Ok(0) => break,
            Ok(_) if b[0] == b'\n' => break,
            Ok(_) => {
                if line.len() as u64 >= MAX_SPEC {
                    return Err("read spec: the line is too long".into());
                }
                line.push(b[0]);
            }
            Err(rustix::io::Errno::INTR) => continue,
            Err(e) => return Err(format!("read spec: {e}")),
        }
    }
    serde_json::from_slice(&line).map_err(|e| format!("bad spec: {e}"))
}

/// The supervisor's lifeline: read the daemon's stdin until EOF. With an agent input pipe (`agent_stdin`), every byte
/// after the start gate is passed to the agent's stdin as is (the daemon writes whole stream-json lines). Returns when
/// the daemon closed the lifeline or died.
pub(super) fn lifeline(mut agent_input: Option<std::process::ChildStdin>) {
    use std::io::Write;
    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 8192];
    loop {
        match stdin.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if let Some(w) = agent_input.as_mut()
                    && w.write_all(&buf[..n]).and_then(|()| w.flush()).is_err()
                {
                    // The agent closed its stdin or exited: keep holding the lifeline, drop its input.
                    agent_input = None;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
}

/// The agent environment: the spec + default `HOME`/`TMPDIR`/`PATH`; proxy variables point to the bridge.
pub(super) fn agent_env(spec: &SandboxSpec, port: Option<u16>) -> Vec<(String, String)> {
    let mut env = spec.env.clone();
    let has = |env: &Vec<(String, String)>, k: &str| env.iter().any(|(x, _)| x == k);
    if !has(&env, "HOME") {
        env.push(("HOME".into(), spec.home.to_string_lossy().into_owned()));
    }
    if !has(&env, "TMPDIR") {
        env.push(("TMPDIR".into(), spec.tmp.to_string_lossy().into_owned()));
    }
    if !has(&env, "PATH") {
        env.push(("PATH".into(), "/usr/local/bin:/usr/bin:/bin".into()));
    }
    if let Some(p) = port {
        let url = format!("http://127.0.0.1:{p}");
        env.retain(|(k, _)| !PROXY_VARS.contains(&k.as_str()));
        for k in PROXY_VARS {
            env.push(((*k).into(), url.clone()));
        }
    }
    env
}

/// Bridge: `127.0.0.1:port` (0: a free one) ⇄ the proxy unix socket, one thread per connection. Returns the port.
pub(super) fn start_bridge(b: &ProxyBridge) -> std::result::Result<u16, String> {
    let l = TcpListener::bind(("127.0.0.1", b.port))
        .map_err(|e| format!("bridge bind 127.0.0.1:{}: {e}", b.port))?;
    let port = l.local_addr().map_err(|e| e.to_string())?.port();
    let unix = b.unix.clone();
    std::thread::Builder::new()
        .name("bridge".into())
        .spawn(move || bridge_accept(l, unix))
        .map_err(|e| format!("bridge thread: {e}"))?;
    Ok(port)
}

fn bridge_accept(l: TcpListener, unix: PathBuf) {
    let active = Arc::new(AtomicUsize::new(0));
    for conn in l.incoming() {
        let Ok(tcp) = conn else { continue };
        if active.load(Ordering::SeqCst) >= MAX_BRIDGE {
            continue;
        }
        active.fetch_add(1, Ordering::SeqCst);
        let unix = unix.clone();
        let mine = active.clone();
        let spawned = std::thread::Builder::new()
            .stack_size(128 * 1024)
            .spawn(move || {
                if let Ok(u) = UnixStream::connect(&unix) {
                    pump(tcp, u);
                }
                mine.fetch_sub(1, Ordering::SeqCst);
            });
        if spawned.is_err() {
            // The thread was not created: the connection was closed together with the closure; give the slot back.
            active.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

fn pump(tcp: TcpStream, unix: UnixStream) {
    let (Ok(mut tcp_r), Ok(mut unix_w)) = (tcp.try_clone(), unix.try_clone()) else {
        return;
    };
    let up = std::thread::Builder::new()
        .stack_size(128 * 1024)
        .spawn(move || {
            let _ = std::io::copy(&mut tcp_r, &mut unix_w);
            let _ = unix_w.shutdown(Shutdown::Write);
        });
    let (mut unix_r, mut tcp_w) = (unix, tcp);
    let _ = std::io::copy(&mut unix_r, &mut tcp_w);
    let _ = tcp_w.shutdown(Shutdown::Write);
    if let Ok(h) = up {
        let _ = h.join();
    }
}

/// Soft and hard limit = `v` (not above the current hard limit).
pub(super) fn set_rlimit(r: rustix::process::Resource, v: u64) -> std::result::Result<(), String> {
    use rustix::process::{Rlimit, getrlimit, setrlimit};
    let hard = getrlimit(r).maximum;
    let v = hard.map_or(v, |h| v.min(h));
    setrlimit(
        r,
        Rlimit {
            current: Some(v),
            maximum: Some(v),
        },
    )
    .map_err(|e| format!("setrlimit {r:?}: {e}"))
}

/// The agent's rlimits (stage 2): core 0, `nofile`, `fsize`, CPU (soft: SIGXCPU, hard 5 s later: SIGKILL).
pub(super) fn rlimits(spec: &SandboxSpec) -> std::result::Result<(), String> {
    use rustix::process::{Resource, Rlimit, getrlimit, setrlimit};
    set_rlimit(Resource::Core, 0)?;
    let l = &spec.limits;
    if l.nofile > 0 {
        set_rlimit(Resource::Nofile, l.nofile.max(16))?;
    }
    if l.fsize_bytes > 0 {
        set_rlimit(Resource::Fsize, l.fsize_bytes)?;
    }
    #[cfg(target_os = "linux")]
    if l.data_bytes > 0 {
        set_rlimit(Resource::Data, l.data_bytes)?;
    }
    if l.cpu_secs > 0 {
        let hard = getrlimit(Resource::Cpu).maximum;
        let soft = hard.map_or(l.cpu_secs, |h| l.cpu_secs.min(h));
        let max = hard.map_or(soft + 5, |h| (soft + 5).min(h));
        setrlimit(
            Resource::Cpu,
            Rlimit {
                current: Some(soft),
                maximum: Some(max),
            },
        )
        .map_err(|e| format!("setrlimit Cpu: {e}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sandbox::{Limits, SandboxKind};

    #[test]
    fn agent_env_fills_defaults_and_overrides_proxy() {
        let spec = SandboxSpec {
            argv: vec!["/bin/true".into()],
            env: vec![
                ("HTTPS_PROXY".into(), "http://evil:1".into()),
                ("PATH".into(), "/usr/bin".into()),
            ],
            cwd: "/w".into(),
            home: "/h".into(),
            tmp: "/t".into(),
            rw: vec![],
            ro: vec![],
            ro_binds: vec![],
            sockets: vec![],
            proxy: None,
            limits: Limits::default(),
            kind: SandboxKind::Bwrap,
            start_gate: false,
            agent_stdin: false,
            listen: None,
            gpu: false,
        };
        let env = agent_env(&spec, Some(3128));
        let get = |k: &str| {
            env.iter()
                .filter(|(x, _)| x == k)
                .map(|(_, v)| v.as_str())
                .collect::<Vec<_>>()
        };
        assert_eq!(get("HOME"), ["/h"]);
        assert_eq!(get("TMPDIR"), ["/t"]);
        assert_eq!(get("PATH"), ["/usr/bin"]);
        assert_eq!(get("HTTPS_PROXY"), ["http://127.0.0.1:3128"]);
        assert_eq!(get("http_proxy"), ["http://127.0.0.1:3128"]);
        let env = agent_env(&spec, None);
        assert!(
            env.iter()
                .any(|(k, v)| k == "HTTPS_PROXY" && v == "http://evil:1")
        );
    }
}
