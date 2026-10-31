// SPDX-License-Identifier: AGPL-3.0-only
//! Linux: probing the mechanisms, starting bwrap/the supervisor from the daemon, shared paths and the process tree.

use std::{
    ffi::OsString,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    process::Stdio,
    sync::OnceLock,
    time::{Duration, Instant},
};

use antenna_proto::control::code;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::{
    Running, SUPERVISOR_ARG, SandboxKind, SandboxSpec, Support,
    common::{ensure_dirs, link_ro_binds, program_paths, validate},
};
use crate::error::{Error, Result};

/// Where to look for bwrap (system paths only, not `PATH`).
const BWRAP_CANDIDATES: &[&str] = &["/usr/bin/bwrap", "/usr/local/bin/bwrap", "/bin/bwrap"];

/// System directories of programs and libraries, read-only (with usrmerge, `/bin` and `/lib*` are symlinks into
/// `/usr`).
pub(super) const SYSTEM_DIRS: &[&str] = &[
    "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32",
];

/// What the agent sees of `/etc`: a selected list, NOT the whole `/etc`. The daemon may run as root, and root reads
/// `/etc/shadow`, `/etc/ssl/private` and service keys even without capabilities (as the file owner). Directories with
/// private keys (`/etc/ssl/private`, `/etc/pki/tls/private`) are not included; neither is `resolv.conf`: the daemon
/// proxy resolves names.
pub(super) const ETC_ALLOW: &[&str] = &[
    "/etc/ld.so.cache",
    "/etc/ld.so.conf",
    "/etc/ld.so.conf.d",
    "/etc/ssl/certs",
    "/etc/ssl/openssl.cnf",
    "/etc/ca-certificates",
    "/etc/ca-certificates.conf",
    "/etc/pki/ca-trust",
    "/etc/pki/tls/certs",
    "/etc/pki/tls/cert.pem",
    "/etc/pki/tls/openssl.cnf",
    "/etc/crypto-policies",
    "/etc/alternatives",
    "/etc/passwd",
    "/etc/group",
    "/etc/nsswitch.conf",
    "/etc/hosts",
    "/etc/host.conf",
    "/etc/gai.conf",
    "/etc/localtime",
    "/etc/timezone",
    "/etc/mime.types",
    "/etc/terminfo",
    "/etc/bash.bashrc",
    "/etc/inputrc",
    "/etc/gitconfig",
    "/etc/os-release",
    "/etc/lsb-release",
    "/etc/debian_version",
    "/etc/protocols",
    "/etc/services",
    "/etc/shells",
];

/// Devices the agent sees in Landlock mode (read/write; bwrap has its own `/dev`).
pub(super) const DEV_FILES: &[&str] = &[
    "/dev/null",
    "/dev/zero",
    "/dev/full",
    "/dev/random",
    "/dev/urandom",
];

/// The first message to the supervisor (a JSON line on stdin).
#[derive(Debug, Serialize, Deserialize)]
pub(super) struct LaunchMsg {
    pub spec: SandboxSpec,
}

/// Probe result.
pub(super) struct Probe {
    pub support: Support,
    /// bwrap understands `--disable-userns` (≥ 0.8) and sets up namespaces with it.
    pub disable_userns: bool,
}

static PROBE: OnceLock<Probe> = OnceLock::new();

pub(super) fn probe() -> &'static Probe {
    PROBE.get_or_init(probe_now)
}

/// The kernel's Landlock ABI without restricting the process at all (an empty `RestrictSelf` only queries the kernel).
pub(super) fn landlock_abi() -> i32 {
    use landlock::{LandlockStatus, RestrictSelf};
    match RestrictSelf::default().no_new_privs(false).apply() {
        Ok(st) => match st.landlock {
            LandlockStatus::Available {
                effective_abi,
                kernel_abi,
            } => kernel_abi.unwrap_or(effective_abi as i32),
            _ => 0,
        },
        Err(_) => 0,
    }
}

fn probe_now() -> Probe {
    let abi = landlock_abi();
    let mut notes = Vec::new();
    let mut bwrap = None;
    let mut disable_userns = false;
    for c in BWRAP_CANDIDATES {
        let p = Path::new(c);
        if !p.exists() {
            continue;
        }
        match trusted_root_executable(p) {
            Err(e) => notes.push(format!("{c}: not trusted ({e})")),
            Ok(()) => {
                let version = run_probe(p, &[OsString::from("--version")])
                    .map(|o| o.trim().to_string())
                    .unwrap_or_default();
                match bwrap_works(p, true) {
                    Ok(()) => {
                        disable_userns = true;
                        notes.push(format!("{c} ({version}): namespaces ok"));
                        bwrap = Some(p.to_path_buf());
                    }
                    Err(e1) => match bwrap_works(p, false) {
                        Ok(()) => {
                            notes.push(format!(
                                "{c} ({version}): namespaces ok, without --disable-userns ({e1})"
                            ));
                            bwrap = Some(p.to_path_buf());
                        }
                        Err(e) => notes.push(format!(
                            "{c} ({version}): cannot create namespaces ({e}) — e.g. unprivileged user namespaces are disabled or restricted by AppArmor"
                        )),
                    },
                }
                if bwrap.is_some() {
                    break;
                }
            }
        }
    }
    if bwrap.is_none() && notes.is_empty() {
        notes.push("bubblewrap not found in /usr/bin, /usr/local/bin, /bin".into());
    }
    let ll = match abi {
        0 => "Landlock unavailable".to_string(),
        a if a < 4 => format!("Landlock ABI {a} (< 4: no TCP rules)"),
        a if a < 6 => format!(
            "Landlock ABI {a}: files + TCP; NOT closed without bwrap: same-user unix sockets, abstract unix sockets, signals to same-user processes, /proc process list"
        ),
        a => format!(
            "Landlock ABI {a}: files + TCP + signal/abstract-socket scope; NOT closed without bwrap: same-user pathname unix sockets, /proc process list"
        ),
    };
    notes.push(ll);
    let kind = if bwrap.is_some() {
        Some(SandboxKind::Bwrap)
    } else if abi >= 4 {
        Some(SandboxKind::Landlock)
    } else {
        None
    };
    if kind.is_none() {
        notes.push("no sandbox: agents are not started on wake".into());
    }
    Probe {
        support: Support {
            kind,
            bwrap,
            landlock_abi: abi,
            detail: notes.join("; "),
        },
        disable_userns,
    }
}

/// The file and its directory are owned by root and not writable by group/others; the file is regular and executable.
fn trusted_root_executable(p: &Path) -> std::result::Result<(), String> {
    let real = std::fs::canonicalize(p).map_err(|e| e.to_string())?;
    let mut check = vec![real.clone()];
    if let Some(d) = real.parent() {
        check.push(d.to_path_buf());
    }
    if let Some(d) = p.parent() {
        check.push(d.to_path_buf());
    }
    for f in &check {
        let m = std::fs::metadata(f).map_err(|e| format!("{}: {e}", f.display()))?;
        if m.uid() != 0 {
            return Err(format!("{} is not owned by root", f.display()));
        }
        if m.mode() & 0o022 != 0 {
            return Err(format!("{} is writable by group/others", f.display()));
        }
    }
    let m = std::fs::metadata(&real).map_err(|e| e.to_string())?;
    if !m.is_file() || m.mode() & 0o111 == 0 {
        return Err("not an executable file".into());
    }
    Ok(())
}

/// Functional probe: bwrap sets up all the needed namespaces and runs a program inside.
fn bwrap_works(bwrap: &Path, disable_userns: bool) -> std::result::Result<(), String> {
    let mut a: Vec<OsString> = Vec::new();
    for s in common_bwrap_flags(disable_userns) {
        a.push(s.into());
    }
    for s in [
        "--ro-bind",
        "/",
        "/",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--tmpfs",
        "/tmp",
        "--",
    ] {
        a.push(s.into());
    }
    a.push(bwrap.as_os_str().to_owned());
    a.push("--version".into());
    run_probe(bwrap, &a).map(|_| ())
}

/// Run briefly (≤ 5 s), without an environment and inherited descriptors; stdout on success.
fn run_probe(prog: &Path, args: &[OsString]) -> std::result::Result<String, String> {
    let mut c = std::process::Command::new(prog);
    c.args(args)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    antenna_sys::fds::no_inherited_fds_in_child(&mut c);
    let mut child = c.spawn().map_err(|e| e.to_string())?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if start.elapsed() > Duration::from_secs(5) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("timed out".into());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(5)),
            Err(e) => return Err(e.to_string()),
        }
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        Err(format!(
            "{}: {}",
            out.status,
            err.trim().lines().last().unwrap_or("")
        ))
    }
}

/// bwrap flags shared by the probe and the launch.
fn common_bwrap_flags(disable_userns: bool) -> Vec<&'static str> {
    let mut v = vec![
        // user (try), ipc, pid, net, uts, cgroup (try)
        "--unshare-all",
    ];
    if disable_userns {
        // A user ns of our own is mandatory and nested ones are forbidden: less kernel surface for the agent.
        v.extend(["--unshare-user", "--disable-userns"]);
    }
    v.extend([
        // If bwrap is killed (by the daemon after grace), the sandbox's PID 1 gets SIGKILL and the kernel kills the
        // tree.
        "--die-with-parent",
        // setsid: the agent cannot reach the daemon's terminal (TIOCSTI).
        "--new-session",
        // The supervisor is PID 1: the agent cannot kill or stop it; when it exits the kernel kills the whole pidns.
        "--as-pid-1",
        "--cap-drop",
        "ALL",
        "--clearenv",
        "--hostname",
        "antenna-sandbox",
    ]);
    v
}

/// Landlock mode: rules only add permissions, so a read-only path inside a writable directory cannot be closed and is
/// refused (fail closed; bwrap is needed). `ro_binds` destinations are symlinks to the source.
fn prepare_landlock(spec: &SandboxSpec) -> Result<()> {
    let rw: Vec<PathBuf> = [&spec.cwd, &spec.home, &spec.tmp]
        .into_iter()
        .chain(&spec.rw)
        .filter_map(|p| std::fs::canonicalize(p).ok())
        .collect();
    let ro = spec
        .ro
        .iter()
        .chain(spec.ro_binds.iter().map(|(s, _)| s))
        .filter_map(|p| std::fs::canonicalize(p).ok());
    for r in ro {
        if let Some(w) = rw.iter().find(|w| r.starts_with(w)) {
            return Err(Error::new(
                code::SANDBOX_UNAVAILABLE,
                format!(
                    "sandbox: Landlock cannot keep {} read-only inside the writable {} (rules only add rights) — bubblewrap is required for this layout",
                    r.display(),
                    w.display()
                ),
            ));
        }
    }
    link_ro_binds(spec)
}

/// What is mounted in bwrap (besides the system paths).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Mount {
    Rw(PathBuf),
    Ro(PathBuf),
    RoBind(PathBuf, PathBuf),
}

impl Mount {
    fn dst(&self) -> &Path {
        match self {
            Mount::Rw(p) | Mount::Ro(p) => p,
            Mount::RoBind(_, d) => d,
        }
    }
    /// At equal depth, read-only is mounted later and wins.
    fn rank(&self) -> u8 {
        match self {
            Mount::Rw(_) => 0,
            Mount::Ro(_) | Mount::RoBind(..) => 1,
        }
    }
}

/// bwrap arguments: namespaces, a root built from the selection, the spec's paths from shallow to deep, the supervisor.
fn bwrap_args(spec: &SandboxSpec, supervisor_exe: &Path, disable_userns: bool) -> Vec<OsString> {
    let mut a: Vec<OsString> = common_bwrap_flags(disable_userns)
        .into_iter()
        .map(OsString::from)
        .collect();
    let mut push = |v: &[&dyn AsRef<std::ffi::OsStr>]| {
        for x in v {
            a.push(x.as_ref().to_owned());
        }
    };
    for d in SYSTEM_DIRS {
        let p = Path::new(d);
        match std::fs::symlink_metadata(p) {
            Ok(m) if m.file_type().is_symlink() => {
                if let Ok(t) = std::fs::read_link(p) {
                    push(&[&"--symlink", &t, d]);
                }
            }
            Ok(m) if m.is_dir() => push(&[&"--ro-bind", d, d]),
            _ => {}
        }
    }
    for e in ETC_ALLOW {
        push(&[&"--ro-bind-try", e, e]);
    }
    push(&[&"--proc", &"/proc", &"--dev", &"/dev", &"--tmpfs", &"/tmp"]);
    let mut mounts: Vec<Mount> = Vec::new();
    for p in [&spec.cwd, &spec.home, &spec.tmp]
        .into_iter()
        .chain(&spec.rw)
    {
        mounts.push(Mount::Rw(p.clone()));
    }
    for p in spec
        .ro
        .iter()
        .cloned()
        .chain(program_paths(spec))
        .chain(spec.sockets.iter().cloned())
        .chain(spec.proxy.iter().map(|b| b.unix.clone()))
        .chain(std::iter::once(supervisor_exe.to_path_buf()))
    {
        mounts.push(Mount::Ro(p));
    }
    for (s, d) in &spec.ro_binds {
        mounts.push(Mount::RoBind(s.clone(), d.clone()));
    }
    // Shallow to deep: a nested path is mounted over the enclosing one (ro inside rw and the other way round).
    mounts.sort_by_key(|m| (m.dst().components().count(), m.rank()));
    mounts.dedup();
    for m in &mounts {
        match m {
            Mount::Rw(p) => push(&[&"--bind", p, p]),
            Mount::Ro(p) => push(&[&"--ro-bind-try", p, p]),
            Mount::RoBind(s, d) => push(&[&"--ro-bind-try", s, d]),
        }
    }
    push(&[
        &"--chdir",
        &spec.cwd,
        &"--",
        &supervisor_exe,
        &SUPERVISOR_ARG,
    ]);
    a
}

pub(super) async fn launch(spec: &SandboxSpec, supervisor_exe: &Path) -> Result<Running> {
    validate(spec, supervisor_exe)?;
    let pr = probe();
    let unavailable = |why: String| Error::new(code::SANDBOX_UNAVAILABLE, why);
    let mut cmd = match spec.kind {
        SandboxKind::Bwrap => {
            let Some(b) = &pr.support.bwrap else {
                return Err(unavailable(format!(
                    "sandbox: bubblewrap is not available: {}",
                    pr.support.detail
                )));
            };
            ensure_dirs(spec)?;
            let mut c = tokio::process::Command::new(b);
            c.args(bwrap_args(spec, supervisor_exe, pr.disable_userns));
            c
        }
        SandboxKind::Landlock => {
            if pr.support.landlock_abi < 4 {
                return Err(unavailable(format!(
                    "sandbox: Landlock ABI >= 4 is required: {}",
                    pr.support.detail
                )));
            }
            ensure_dirs(spec)?;
            prepare_landlock(spec)?;
            let mut c = tokio::process::Command::new(supervisor_exe);
            c.arg(SUPERVISOR_ARG).current_dir(&spec.cwd);
            c
        }
        SandboxKind::Seatbelt => {
            return Err(unavailable(
                "sandbox: Seatbelt exists only on macOS".to_string(),
            ));
        }
    };
    cmd.env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .process_group(0);
    // Daemon descriptors (DB, sockets, the window) are not for the agent, whoever left them without CLOEXEC (D-61).
    antenna_sys::fds::no_inherited_fds_in_child(cmd.as_std_mut());
    let mut child = cmd
        .spawn()
        .map_err(|e| unavailable(format!("sandbox: spawn: {e}")))?;
    let pid = child.id().unwrap_or(0);
    let mut stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    let mut line = serde_json::to_vec(&LaunchMsg { spec: spec.clone() })
        .map_err(|e| Error::internal(format!("sandbox: spec: {e}")))?;
    line.push(b'\n');
    let written = match stdin.as_mut() {
        Some(s) => s.write_all(&line).await.and(s.flush().await),
        None => Err(std::io::ErrorKind::BrokenPipe.into()),
    };
    if let Err(e) = written {
        // bwrap/the supervisor died right away: its stderr goes into the error.
        let mut err = Vec::new();
        if let Some(s) = stderr.as_mut() {
            let _ =
                tokio::time::timeout(Duration::from_secs(2), s.take(4096).read_to_end(&mut err))
                    .await;
        }
        let _ = child.start_kill();
        let _ = child.wait().await;
        return Err(unavailable(format!(
            "sandbox: supervisor did not start ({e}): {}",
            String::from_utf8_lossy(&err).trim()
        )));
    }
    Ok(Running {
        child,
        pid,
        stdout,
        stderr,
        lifeline: stdin,
    })
}

// Process tree (`/proc`): descendants of the root and SIGKILL through a pidfd (no race with PID reuse).

/// The needed part of a `/proc/<pid>/stat` line.
#[derive(Debug, Clone, Copy)]
pub(super) struct ProcStat {
    pub pid: i32,
    pub ppid: i32,
    pub state: u8,
    pub start: u64,
}

pub(super) fn read_stat(pid: i32) -> Option<ProcStat> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // comm may contain spaces and parentheses, so the fields follow the last ')'.
    let rest = &s[s.rfind(')')? + 2..];
    let f: Vec<&str> = rest.split(' ').collect();
    // After comm: state(0) ppid(1) … starttime(19).
    Some(ProcStat {
        pid,
        state: f.first()?.bytes().next()?,
        ppid: f.get(1)?.parse().ok()?,
        start: f.get(19)?.parse().ok()?,
    })
}

/// Live (non-zombie) descendants of `root`.
pub(super) fn descendants(root: i32) -> Vec<ProcStat> {
    let Ok(rd) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    let all: Vec<ProcStat> = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<i32>().ok())
        .filter_map(read_stat)
        .collect();
    let mut out = Vec::new();
    let mut frontier = vec![root];
    while let Some(p) = frontier.pop() {
        for s in all.iter().filter(|s| s.ppid == p) {
            if out.iter().any(|o: &ProcStat| o.pid == s.pid) {
                continue;
            }
            frontier.push(s.pid);
            if s.state != b'Z' && s.state != b'X' {
                out.push(*s);
            }
        }
    }
    out
}

/// SIGKILL to a process if it is still the same one (same start time): the pidfd pins the process, the check runs after
/// opening it.
pub(super) fn kill_exact(s: &ProcStat) {
    use rustix::process::{Pid, PidfdFlags, Signal, pidfd_open, pidfd_send_signal};
    let Some(pid) = Pid::from_raw(s.pid) else {
        return;
    };
    match pidfd_open(pid, PidfdFlags::empty()) {
        Ok(fd) => {
            if read_stat(s.pid).is_some_and(|n| n.start == s.start) {
                let _ = pidfd_send_signal(&fd, Signal::KILL);
            }
        }
        // Kernel < 5.3: no pidfd (the race window is between reading /proc and kill).
        Err(rustix::io::Errno::NOSYS) => {
            if read_stat(s.pid).is_some_and(|n| n.start == s.start) {
                let _ = rustix::process::kill_process(pid, Signal::KILL);
            }
        }
        Err(_) => {}
    }
}

/// Kill the descendants of `root` while there are any (new ones may be born during the walk); for at most ~2 s.
pub(super) fn kill_descendants(root: i32) -> bool {
    for _ in 0..400 {
        let ds = descendants(root);
        if ds.is_empty() {
            return true;
        }
        for d in &ds {
            kill_exact(d);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    descendants(root).is_empty()
}

/// Daemon: SIGKILL to the whole tree under the direct child and to its group.
pub(super) fn kill_tree(pid: u32) {
    let Ok(p) = i32::try_from(pid) else { return };
    if p <= 1 {
        return;
    }
    // Descendants first (in Landlock mode the agent is in its own group, and orphans hang off the subreaper
    // supervisor).
    for _ in 0..3 {
        let ds = descendants(p);
        if ds.is_empty() {
            break;
        }
        for d in &ds {
            kill_exact(d);
        }
    }
    if let Some(pid) = rustix::process::Pid::from_raw(p) {
        let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::KILL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sandbox::{Limits, ProxyBridge};

    fn spec() -> SandboxSpec {
        SandboxSpec {
            argv: vec!["/bin/sh".into(), "-c".into(), "true".into()],
            env: vec![],
            cwd: "/work/link/shared".into(),
            home: "/run/agent/home".into(),
            tmp: "/run/agent/tmp".into(),
            rw: vec![],
            ro: vec!["/work".into(), "/work/link/shared/CLAUDE.md".into()],
            ro_binds: vec![(
                "/owner/.claude/.credentials.json".into(),
                "/run/agent/home/.claude/.credentials.json".into(),
            )],
            sockets: vec!["/owner/antennad.sock".into()],
            proxy: Some(ProxyBridge {
                unix: "/owner/proxy.sock".into(),
                port: 3128,
            }),
            limits: Limits::default(),
            kind: SandboxKind::Bwrap,
            start_gate: false,
            agent_stdin: false,
            listen: None,
            gpu: false,
        }
    }

    fn pos(a: &[OsString], w: &[&str]) -> usize {
        a.windows(w.len())
            .position(|x| x.iter().zip(w).all(|(p, q)| p == q))
            .unwrap_or_else(|| panic!("{w:?} not in {a:?}"))
    }

    #[test]
    fn bwrap_args_layer_mounts_from_shallow_to_deep() {
        let a = bwrap_args(&spec(), Path::new("/opt/antenna/antennad"), true);
        // ro /work, then rw /work/link/shared over it, then ro CLAUDE.md over that.
        let work = pos(&a, &["--ro-bind-try", "/work", "/work"]);
        let cwd = pos(&a, &["--bind", "/work/link/shared", "/work/link/shared"]);
        let md = pos(
            &a,
            &[
                "--ro-bind-try",
                "/work/link/shared/CLAUDE.md",
                "/work/link/shared/CLAUDE.md",
            ],
        );
        assert!(work < cwd && cwd < md, "{a:?}");
        // Credentials over HOME, read-only.
        let home = pos(&a, &["--bind", "/run/agent/home", "/run/agent/home"]);
        let cred = pos(
            &a,
            &[
                "--ro-bind-try",
                "/owner/.claude/.credentials.json",
                "/run/agent/home/.claude/.credentials.json",
            ],
        );
        assert!(home < cred);
        pos(
            &a,
            &[
                "--ro-bind-try",
                "/owner/antennad.sock",
                "/owner/antennad.sock",
            ],
        );
        pos(
            &a,
            &["--ro-bind-try", "/owner/proxy.sock", "/owner/proxy.sock"],
        );
        pos(&a, &["--unshare-all", "--unshare-user", "--disable-userns"]);
        pos(&a, &["--die-with-parent", "--new-session", "--as-pid-1"]);
        pos(&a, &["--cap-drop", "ALL", "--clearenv"]);
        pos(&a, &["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]);
        pos(&a, &["--ro-bind-try", "/etc/passwd", "/etc/passwd"]);
        // Not the whole /etc and no private keys.
        assert!(
            !a.iter()
                .any(|x| x == "/etc" || x == "/etc/shadow" || x == "/etc/ssl")
        );
        assert!(!a.iter().any(|x| x.to_string_lossy().contains("private")));
        let tail: Vec<String> = a[a.len() - 5..]
            .iter()
            .map(|x| x.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            tail,
            [
                "--chdir",
                "/work/link/shared",
                "--",
                "/opt/antenna/antennad",
                SUPERVISOR_ARG
            ]
        );
    }

    #[test]
    fn validation_rejects_relative_and_dotdot() {
        let mut s = spec();
        s.cwd = "rel/dir".into();
        assert_eq!(
            validate(&s, Path::new("/bin/sh")).unwrap_err().code,
            code::BAD_REQUEST
        );
        let mut s = spec();
        s.ro.push("/work/../etc".into());
        assert_eq!(
            validate(&s, Path::new("/bin/sh")).unwrap_err().code,
            code::BAD_REQUEST
        );
        let mut s = spec();
        s.argv[0] = "/nonexistent/agent".into();
        assert_eq!(
            validate(&s, Path::new("/bin/sh")).unwrap_err().code,
            code::NOT_FOUND
        );
        let mut s = spec();
        s.argv[0] = "sh".into();
        assert_eq!(
            validate(&s, Path::new("/bin/sh")).unwrap_err().code,
            code::BAD_REQUEST
        );
        let mut s = spec();
        s.env.push(("A=B".into(), "x".into()));
        assert!(validate(&s, Path::new("/bin/sh")).is_err());
        assert!(validate(&spec(), Path::new("/bin/sh")).is_ok());
    }

    #[test]
    fn proc_stat_parses_own_process() {
        let me = std::process::id() as i32;
        let s = read_stat(me).unwrap();
        assert_eq!(s.pid, me);
        assert_eq!(
            s.ppid,
            rustix::process::getppid().unwrap().as_raw_nonzero().get()
        );
        assert!(s.start > 0);
    }

    #[test]
    fn landlock_abi_does_not_restrict() {
        let abi = landlock_abi();
        assert!(abi >= 0);
        // The process is not restricted: what is outside any rules is readable.
        assert!(std::fs::read_dir("/").is_ok());
    }
}
