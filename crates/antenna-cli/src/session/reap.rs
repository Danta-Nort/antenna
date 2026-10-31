// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna session-reap <program> <args…>` (internal; Linux): the child subreaper between `antenna session`'s pane
//! process and the agent CLI (PG-58, D-133).
//!
//! The owner's stop switch takes the agent's terminal session whole: every process in it and everything under its
//! leader. A process the agent started that calls `setsid` and loses its parent (a daemonizing server, `nohup setsid
//! …&`) leaves both: the kernel hands an orphan to the nearest ancestor that is a child subreaper
//! (`PR_SET_CHILD_SUBREAPER`, the mechanism of systemd and container inits), otherwise to PID 1. This process is that
//! subreaper, so such orphans stay under the pane's process and the stop still finds them. It reaps every child
//! (`waitpid(-1)`: it has no others), forwards SIGHUP and SIGTERM to the CLI and ignores the terminal's SIGINT and
//! SIGQUIT (those keys are the CLI's), and exits with the CLI's exit code. It runs no daemon command and holds no
//! token: it only starts the program it is given, as the pane's process would.
//!
//! Started only by the pane's process on Linux; macOS has no subreaper, so there the pane starts the CLI itself.

use std::{ffi::OsString, process::ExitCode};

/// The first argument that selects this mode, before any parsing (like `local-agent`).
pub(crate) const MODE: &str = "session-reap";

/// Run the CLI under this subreaper.
pub(crate) fn main() -> ExitCode {
    let argv: Vec<OsString> = std::env::args_os().skip(2).collect();
    let Some((program, args)) = argv.split_first() else {
        eprintln!("antenna {MODE}: no program");
        return ExitCode::from(2);
    };
    #[cfg(target_os = "linux")]
    if let Err(e) = rustix::process::set_child_subreaper(Some(rustix::process::getpid())) {
        // Without it the stop still takes the session and the tree; only orphans that left both escape
        eprintln!("antenna {MODE}: cannot become a child subreaper: {e}");
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("antenna {MODE}: runtime: {e}");
            return ExitCode::from(1);
        }
    };
    rt.block_on(async move {
        use tokio::signal::unix::{SignalKind, signal};
        // The handlers come before the CLI starts, so no signal slips between; handlers (not "ignore") are reset in
        // the child by exec, so the CLI keeps its own default reactions to Ctrl-C and Ctrl-\.
        let (Ok(mut hup), Ok(mut term), Ok(mut int), Ok(mut quit), Ok(mut chld)) = (
            signal(SignalKind::hangup()),
            signal(SignalKind::terminate()),
            signal(SignalKind::interrupt()),
            signal(SignalKind::quit()),
            signal(SignalKind::child()),
        ) else {
            eprintln!("antenna {MODE}: cannot handle signals");
            return ExitCode::from(1);
        };
        let child = match std::process::Command::new(program).args(args).spawn() {
            Ok(c) => c,
            Err(e) => {
                eprintln!(
                    "antenna {MODE}: cannot start {}: {e}",
                    std::path::Path::new(program).display()
                );
                return ExitCode::from(126);
            }
        };
        let cli = rustix::process::Pid::from_raw(child.id() as i32);
        // The CLI's status is read here, by `waitpid`, not through `std::process::Child` (dropping it waits for nothing)
        drop(child);
        let forward = |sig| {
            if let Some(p) = cli {
                let _ = rustix::process::kill_process(p, sig);
            }
        };
        loop {
            if let Some(code) = reap(cli) {
                return ExitCode::from(code);
            }
            tokio::select! {
                _ = chld.recv() => {}
                _ = hup.recv() => forward(rustix::process::Signal::HUP),
                _ = term.recv() => forward(rustix::process::Signal::TERM),
                _ = int.recv() => {}
                _ = quit.recv() => {}
            }
        }
    })
}

/// Reap every child that has ended; the CLI's exit code when it was one of them.
fn reap(cli: Option<rustix::process::Pid>) -> Option<u8> {
    use rustix::process::{WaitOptions, waitpid};
    loop {
        match waitpid(None, WaitOptions::NOHANG) {
            Ok(Some((pid, status))) => {
                if Some(pid) == cli {
                    let code = status
                        .exit_status()
                        .or_else(|| status.terminating_signal().map(|n| 128 + n))
                        .unwrap_or(1);
                    return Some(code.clamp(0, 255) as u8);
                }
            }
            // Nothing more has ended, or no children at all (the CLI is gone without a status we saw)
            Ok(None) => return None,
            // No children left at all: the CLI is gone
            Err(_) => return Some(1),
        }
    }
}
