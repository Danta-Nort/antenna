// SPDX-License-Identifier: AGPL-3.0-only
//! The check sandbox (SPEC §11 "Two sandboxes", D-111 item 6): a task's check command (a build, the tests, a linter)
//! runs here, never in the worker's sandbox and never with the daemon's environment.
//!
//! - **What it sees**: the system folders, the folder it checks (writable: builds write there), its own empty HOME and
//!   TMPDIR, the program's folder and the template's toolchain folders read-only. No daemon socket, no agent token, no
//!   provider login, no owner file.
//! - **Network**: none, or only the template's registries through the daemon's CONNECT proxy (TLS end to end, port
//!   443; everything else gets `403` and is listed in the run's `blocked_hosts`).
//! - **No way back to the daemon**: the run's sandbox root is registered as a jail ([`Session::is_jailed`]), so a
//!   process of it that reaches the control socket anyway (Landlock mode shares the file system) gets `forbidden`
//!   before any role is given.
//! - **Limits**: a wall-clock limit (the process tree is stopped), CPU time, file size, open files.

use std::{
    path::{Path, PathBuf},
    sync::PoisonError,
    time::{Duration, Instant},
};

use antenna_proto::control::{CheckRun, code};
use tokio::io::AsyncReadExt;

use super::{Task, TeamRow, WorkerDirs};
use crate::{
    error::{Error, Result},
    node::Session,
    now_ms,
    procinfo::{self, Anchor, ProcStat},
    sandbox,
};

/// The output a run keeps: its last 16 KiB.
const OUTPUT_TAIL: usize = 16 * 1024;

/// What to check.
pub(super) struct CheckReq<'a> {
    pub team: &'a TeamRow,
    pub task: &'a Task,
    /// The folder the check runs in (a worker's own folder, or a fresh checkout of a result).
    pub tree: PathBuf,
    /// The commit the folder holds, if it is a checkout of one.
    pub commit: Option<String>,
    /// Who asked.
    pub by: String,
    /// Its own HOME, TMPDIR and proxy socket.
    pub dirs: WorkerDirs,
    /// Wall-clock limit, seconds.
    pub secs: u64,
}

/// A `NAME=value` entry of the template's check environment: a plain name that is none of the sandbox's own, and a
/// value without control characters.
pub(crate) fn valid_env(e: &str) -> bool {
    let Some((n, v)) = e.split_once('=') else {
        return false;
    };
    let reserved = ["PATH", "HOME", "TMPDIR", "LD_PRELOAD", "LD_LIBRARY_PATH"];
    !n.is_empty()
        && n.len() <= 64
        && n.chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
        && !n.starts_with(|c: char| c.is_ascii_digit())
        && !reserved.contains(&n)
        && !n.starts_with("ANTENNA_")
        && !n.ends_with("_PROXY")
        && !n.starts_with("DYLD_")
        && v.len() <= 4096
        && !v.chars().any(|c| c.is_control())
}

/// A toolchain folder for checks: absolute, existing, and none of the places the daemon or the owner keep secrets
/// in.
pub(crate) fn valid_check_path(p: &str, data_dir: &Path) -> std::result::Result<PathBuf, String> {
    let path = PathBuf::from(p);
    if !path.is_absolute() {
        return Err(format!("{p:?}: a check folder is an absolute path"));
    }
    let real = path.canonicalize().map_err(|e| format!("{p:?}: {e}"))?;
    if !real.is_dir() {
        return Err(format!("{p:?} is not a folder"));
    }
    let data = data_dir.canonicalize().unwrap_or(data_dir.to_path_buf());
    if real.starts_with(&data) || data.starts_with(&real) {
        return Err(format!(
            "{p:?} holds the daemon's data: checks never see it"
        ));
    }
    if let Some(home) = crate::wake::owner_home() {
        let home = home.canonicalize().unwrap_or(home);
        if real == home {
            return Err(format!(
                "{p:?} is the whole home folder: name the toolchain's folders"
            ));
        }
        for secret in [
            ".ssh",
            ".gnupg",
            ".aws",
            ".config",
            ".claude",
            ".codex",
            ".local/share",
        ] {
            let s = home.join(secret);
            if real.starts_with(&s) || s.starts_with(&real) {
                return Err(format!("{p:?} overlaps ~/{secret}: checks never see it"));
            }
        }
    }
    Ok(real)
}

impl Session {
    /// A sandbox root whose processes must never talk to the daemon (a check run).
    fn jail(&self, a: Anchor) {
        self.teams
            .jails
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(a);
    }

    fn unjail(&self, a: &Anchor) {
        self.teams
            .jails
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|j| j != a);
    }

    /// Whether a client process belongs to a check run (control socket: refused before any role). An unreadable
    /// chain while a check runs is a refusal too (fail closed).
    pub(crate) fn is_jailed(&self, chain: Option<&[ProcStat]>) -> bool {
        let jails = self
            .teams
            .jails
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if jails.is_empty() {
            return false;
        }
        match chain {
            None => true,
            Some(c) => jails
                .iter()
                .any(|a| procinfo::chain_position(c, a).is_some()),
        }
    }

    /// Run a task's check in the check sandbox. Never fails: an error is a run with outcome `error`.
    pub(super) async fn run_check_in(&self, r: CheckReq<'_>) -> CheckRun {
        let started = Instant::now();
        let mut run = CheckRun {
            task: r.task.id.clone(),
            commit: r.commit.clone(),
            argv: r.task.check.clone(),
            outcome: "error".into(),
            exit_code: None,
            output: String::new(),
            blocked_hosts: Vec::new(),
            sandbox: String::new(),
            duration_ms: 0,
            by: r.by.clone(),
            at_ms: now_ms(),
        };
        match self.check_once(&r, &mut run).await {
            Ok(()) => {}
            Err(e) => {
                run.outcome = "error".into();
                if run.output.is_empty() {
                    run.output = format!("{}: {}", e.code, e.message);
                }
            }
        }
        run.duration_ms = started.elapsed().as_millis() as u64;
        run
    }

    async fn check_once(&self, r: &CheckReq<'_>, run: &mut CheckRun) -> Result<()> {
        let support = self.wake_support();
        let kind = support.kind.ok_or_else(|| {
            Error::new(
                code::SANDBOX_UNAVAILABLE,
                format!(
                    "checks run only inside a sandbox, and this system has none: {}",
                    support.detail
                ),
            )
        })?;
        run.sandbox = kind.as_str().into();
        let t = &r.team.cfg.template;
        let program = crate::wake::resolve_program(&r.task.check[0])?;
        let program_dir = program
            .canonicalize()
            .ok()
            .and_then(|p| p.parent().map(Path::to_path_buf));
        // A fresh HOME and TMPDIR for every run: nothing of an earlier run (or of another worker's) stays.
        for d in [&r.dirs.home, &r.dirs.tmp] {
            if d.exists() {
                std::fs::remove_dir_all(d)?;
            }
            super::git::mkdir_private(d)?;
        }
        let mut ro: Vec<PathBuf> = Vec::new();
        let mut path_dirs: Vec<String> = Vec::new();
        if let Some(d) = &program_dir {
            ro.push(d.clone());
            path_dirs.push(d.to_string_lossy().into_owned());
        }
        for p in &t.check_paths {
            if let Ok(real) = valid_check_path(p, &self.cfg.data_dir) {
                if real.file_name().is_some_and(|n| n == "bin") {
                    path_dirs.push(real.to_string_lossy().into_owned());
                }
                ro.push(real);
            }
        }
        if cfg!(target_os = "macos") {
            path_dirs.extend(["/opt/homebrew/bin"].map(String::from));
        }
        path_dirs.extend(["/usr/local/bin", "/usr/bin", "/bin"].map(String::from));
        let mut env: Vec<(String, String)> = vec![
            ("PATH".into(), path_dirs.join(":")),
            ("HOME".into(), r.dirs.home.to_string_lossy().into_owned()),
            ("TMPDIR".into(), r.dirs.tmp.to_string_lossy().into_owned()),
            ("LANG".into(), "C.UTF-8".into()),
            ("LC_ALL".into(), "C.UTF-8".into()),
            ("TERM".into(), "dumb".into()),
            ("CI".into(), "1".into()),
        ];
        for e in &t.check_env {
            if valid_env(e)
                && let Some((n, v)) = e.split_once('=')
            {
                env.push((n.into(), v.into()));
            }
        }
        let proxy = if t.check_hosts.is_empty() {
            None
        } else {
            let _ = std::fs::remove_file(&r.dirs.proxy_sock);
            Some(
                sandbox::start_proxy(
                    &r.dirs.proxy_sock,
                    sandbox::ProxyConfig {
                        allow_hosts: t.check_hosts.clone(),
                        allow_ports: vec![443],
                        allow_private: false,
                    },
                )
                .await?,
            )
        };
        // `sh` puts the check's stderr into its stdout, in order; the sandbox's own notes stay on stderr.
        let mut argv = vec![
            "/bin/sh".to_string(),
            "-c".into(),
            "exec \"$@\" 2>&1".into(),
            "sh".into(),
            program.to_string_lossy().into_owned(),
        ];
        argv.extend(r.task.check[1..].iter().cloned());
        let spec = sandbox::SandboxSpec {
            argv,
            env,
            cwd: r.tree.clone(),
            home: r.dirs.home.clone(),
            tmp: r.dirs.tmp.clone(),
            rw: vec![],
            ro,
            ro_binds: vec![],
            sockets: vec![],
            proxy: proxy.as_ref().map(|p| sandbox::ProxyBridge {
                unix: p.path().to_path_buf(),
                port: 0,
            }),
            limits: sandbox::Limits {
                nofile: 4096,
                fsize_bytes: 2 << 30,
                cpu_secs: r.secs.saturating_mul(4).max(60),
                ..Default::default()
            },
            kind,
            start_gate: true,
            agent_stdin: false,
            listen: None,
            gpu: false,
        };
        let me = std::env::current_exe()?;
        let mut running = sandbox::launch(&spec, &me).await?;
        let anchor = procinfo::anchor_of(running.pid as i32).map(|(a, _)| a);
        let Some(anchor) = anchor else {
            running.stop(Duration::from_secs(1)).await;
            return Err(Error::internal("cannot read the check's sandbox process"));
        };
        // The jail holds before the check's first instruction.
        self.jail(anchor);
        let result = self.drive(&mut running, r.secs, run).await;
        running.stop(Duration::from_secs(3)).await;
        self.unjail(&anchor);
        if let Some(p) = &proxy {
            let st = p.stats();
            run.blocked_hosts = st
                .blocked
                .iter()
                .map(|(h, port, _)| format!("{h}:{port}"))
                .collect();
        }
        result
    }

    /// Start the check (`go`), collect its output, wait for it within the limit.
    async fn drive(
        &self,
        running: &mut sandbox::Running,
        secs: u64,
        run: &mut CheckRun,
    ) -> Result<()> {
        running.go().await?;
        let stdout = running.stdout.take();
        let stderr = running.stderr.take();
        let out_task = tokio::spawn(async move {
            match stdout {
                Some(o) => tail_of(o).await,
                None => Vec::new(),
            }
        });
        let err_task = tokio::spawn(async move {
            match stderr {
                Some(e) => tail_of(e).await,
                None => Vec::new(),
            }
        });
        let status = tokio::time::timeout(Duration::from_secs(secs), running.wait()).await;
        let timed_out = status.is_err();
        if timed_out {
            running.stop(Duration::from_secs(3)).await;
        }
        let out = tokio::time::timeout(Duration::from_secs(5), out_task)
            .await
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_default();
        let err = tokio::time::timeout(Duration::from_secs(5), err_task)
            .await
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_default();
        let notes = String::from_utf8_lossy(&err);
        let sandbox_error = notes
            .lines()
            .filter_map(|l| l.strip_prefix(sandbox::NOTE_PREFIX))
            .map(|l| l.trim().to_string())
            .find(|l| l.starts_with("error"));
        let started = notes.lines().any(|l| {
            l.strip_prefix(sandbox::NOTE_PREFIX)
                .is_some_and(|l| l.trim().starts_with("kind="))
        });
        run.output = super::text_of(&String::from_utf8_lossy(&out), OUTPUT_TAIL);
        let code = status
            .ok()
            .and_then(|s| s.ok())
            .and_then(|s| crate::sandbox::exit_code(&s));
        run.exit_code = code;
        run.outcome = if timed_out {
            "timeout"
        } else if code == Some(sandbox::EXIT_SANDBOX_FAILED) && !started {
            if let Some(e) = sandbox_error {
                run.output = format!("the check sandbox did not start, nothing ran: {e}");
            }
            "error"
        } else if code == Some(0) {
            "passed"
        } else {
            "failed"
        }
        .into();
        Ok(())
    }
}

/// The last [`OUTPUT_TAIL`] bytes of a stream (read to its end).
async fn tail_of(mut r: impl tokio::io::AsyncRead + Unpin) -> Vec<u8> {
    let mut tail = Vec::new();
    let mut buf = vec![0u8; 8192];
    while let Ok(n) = r.read(&mut buf).await {
        if n == 0 {
            break;
        }
        tail.extend_from_slice(&buf[..n]);
        if tail.len() > OUTPUT_TAIL * 2 {
            tail.drain(..tail.len() - OUTPUT_TAIL);
        }
    }
    if tail.len() > OUTPUT_TAIL {
        tail.drain(..tail.len() - OUTPUT_TAIL);
    }
    tail
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_environment_and_folders() {
        assert!(valid_env("RUSTUP_HOME=/home/a/.rustup"));
        assert!(valid_env("CARGO_TERM_COLOR=never"));
        for bad in [
            "PATH=/x",
            "HOME=/x",
            "LD_PRELOAD=/x.so",
            "HTTPS_PROXY=http://x",
            "ANTENNA_AGENT_TOKEN=x",
            "lower=x",
            "1X=y",
            "NOEQUALS",
            "X=a\nb",
            "DYLD_INSERT_LIBRARIES=x",
        ] {
            assert!(!valid_env(bad), "{bad}");
        }
        let d = tempfile::tempdir().unwrap();
        let data = d.path().join("data");
        let tool = d.path().join("tool");
        std::fs::create_dir_all(&data).unwrap();
        std::fs::create_dir_all(&tool).unwrap();
        assert!(valid_check_path(tool.to_str().unwrap(), &data).is_ok());
        assert!(valid_check_path(data.to_str().unwrap(), &data).is_err());
        assert!(valid_check_path(d.path().to_str().unwrap(), &data).is_err());
        assert!(valid_check_path("relative/bin", &data).is_err());
        assert!(valid_check_path("/nonexistent-xyz", &data).is_err());
    }
}
