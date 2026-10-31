// SPDX-License-Identifier: AGPL-3.0-only
//! Updates that install by themselves (D-103, experimental): the owner's `antenna update --auto on|off|status|now|later`,
//! and the hidden `antenna update --from <staged> --handover` that the daemon starts for an automatic install.
//!
//! `--handover` is the same install as `antenna update --from` (the same verification, the same swap and journal), with
//! one difference: the daemon is not stopped and started; it replaces itself with the new binary once the files are in
//! place ([`antenna_update::install::Keeper::Handover`]). It talks to the daemon over its stdin (one JSON line: who the
//! daemon is) and stdout (`{"step":"swapped"}` when the daemon may replace itself, then the usual `--json` result). It
//! refuses to run unless its parent is the daemon that named itself on stdin: started by anyone else it does nothing.

use std::{
    cell::Cell,
    io::{BufRead, IsTerminal, Read, Write},
    path::{Path, PathBuf},
};

use antenna_proto::control::{Reply, Request};
use antenna_update::install::{Handoff, Installer, Keeper, RunningDaemon};
use serde::Deserialize;
use serde_json::json;

use super::{outcome_json, recover, up_fail, verify};
use crate::{
    UpdateArgs,
    client::{EXIT_FAIL, EXIT_NOPERM, EXIT_USAGE, Fail, call_owner},
};

/// What the daemon writes on the installer's stdin: who it is, so that the installer can check it is its parent and
/// start it again the same way after a failure.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    /// The daemon's PID.
    pid: u32,
    /// Its executable (canonical, read when it started).
    exe: PathBuf,
    /// Its version line (`antennad 0.1.0-preview.8 (…)`).
    version: String,
    /// Its arguments after the program name.
    #[serde(default)]
    args: Vec<String>,
    /// Its working folder.
    #[serde(default)]
    cwd: Option<PathBuf>,
}

/// Tells the daemon on stdout when to replace itself and remembers what came up.
#[derive(Default)]
pub(super) struct StdoutHandoff {
    unlocked: Cell<Option<bool>>,
}

impl Handoff for StdoutHandoff {
    fn swapped(&self) -> antenna_update::Result<()> {
        let mut o = std::io::stdout().lock();
        writeln!(o, "{}", json!({ "step": "swapped" }))
            .and_then(|()| o.flush())
            .map_err(|e| antenna_update::Error::io("telling the daemon to replace itself", e))
    }

    fn came_up(&self, unlocked: bool) {
        self.unlocked.set(Some(unlocked));
    }
}

/// `antenna update --from <staged> --yes --json --handover`, started by the daemon.
pub(super) fn handover(
    json: bool,
    inst: &mut Installer<'_>,
    a: &UpdateArgs,
    handoff: &StdoutHandoff,
) -> Result<(), Fail> {
    let refuse = |m: &str| Fail::new(EXIT_NOPERM, "forbidden", m.to_string());
    if std::io::stdin().is_terminal() || !a.yes || !json {
        return Err(refuse(
            "--handover is the daemon's own automatic install: it starts it itself",
        ));
    }
    let mut line = String::new();
    Read::take(std::io::stdin().lock(), 64 * 1024)
        .read_line(&mut line)
        .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("stdin: {e}")))?;
    let plan: Plan = serde_json::from_str(line.trim())
        .map_err(|e| Fail::new(EXIT_USAGE, "bad_request", format!("handover plan: {e}")))?;
    if !inst.sys.is_parent(plan.pid) {
        return Err(refuse(
            "--handover runs only as a child of the daemon that names itself on its stdin",
        ));
    }
    if let Some(r) = recover(inst)? {
        inst.log.step(r);
    }
    let v = verify(inst, a)?;
    inst.running = Some(RunningDaemon {
        pid: plan.pid,
        exe: Some(plan.exe),
        version: plan.version,
        args: plan.args,
        cwd: plan.cwd,
    });
    if !matches!(inst.keeper(), Keeper::Handover { .. }) {
        return Err(Fail::new(
            EXIT_FAIL,
            antenna_update::code::UNSUPPORTED_INSTALL,
            "the daemon that asked is not this installation's antennad: nothing was changed",
        ));
    }
    inst.log.step(format!(
        "automatic install of {} (D-103), started by the daemon (pid {})",
        v.rel.manifest.version,
        inst.running.as_ref().map(|r| r.pid).unwrap_or(0)
    ));
    let (asset, path) = v.asset.as_ref().expect("a full verification has the asset");
    let mut out = inst.install(&v.rel, asset, path).map_err(up_fail)?;
    out.keys_locked = handoff.unlocked.get() != Some(true);
    let mut j = outcome_json(&out, inst.log);
    j["unlocked"] = handoff.unlocked.get().unwrap_or(false).into();
    out!(j);
    Ok(())
}

fn password(a: &UpdateArgs) -> Result<zeroize::Zeroizing<String>, Fail> {
    if a.pw.password_stdin {
        return crate::read_line_stdin();
    }
    if !std::io::stdin().is_terminal() {
        return Err(Fail::new(
            EXIT_USAGE,
            "bad_request",
            "the owner password is needed: run this in a terminal or pass --password-stdin",
        ));
    }
    crate::get_password(false, false, "Owner password: ")
}

/// `antenna update --auto on|off|status|now|later`: owner commands; `on` takes the password, `off` the password or one
/// touch (D-131), the rest an owner session (asked for in a terminal, like any owner command).
pub(super) fn auto(
    json: bool,
    rt: &tokio::runtime::Runtime,
    socket: &Path,
    a: &UpdateArgs,
    action: &str,
) -> Result<(), Fail> {
    // Off takes one touch when Touch ID is on here (D-131); on keeps the password, which the daemon needs to open the
    // root key it keeps for the restart (D-103). Without a terminal and with --password-stdin: the password as before.
    if action == "off" && !a.pw.password_stdin {
        let r = rt.block_on(crate::owner::touch::call_pw(socket, &a.pw, |password| {
            Request::UpdateAutoSet {
                enabled: false,
                password,
            }
        }));
        return finish(json, r);
    }
    let req = match action {
        "on" | "off" => Request::UpdateAutoSet {
            enabled: action == "on",
            password: password(a)?.to_string(),
        },
        "status" => Request::UpdateAutoStatus {},
        // With the setting off the daemon keeps no keys for the restart: the password opens them (D-137); in a
        // terminal it is asked for only when the daemon says it is needed.
        "now" => Request::UpdateAutoNow {
            password: if a.pw.password_stdin {
                Some(password(a)?.to_string())
            } else {
                None
            },
        },
        "later" => Request::UpdateAutoLater {},
        other => {
            return Err(Fail::new(
                EXIT_USAGE,
                "bad_request",
                format!("--auto {other:?}: on, off, status, now or later"),
            ));
        }
    };
    let mut r = rt.block_on(call_owner(socket, req.clone()));
    if let Err(f) = &r
        && f.code == "login_required"
        && std::io::stdin().is_terminal()
    {
        let pw = crate::get_password(false, false, "Owner password: ")?;
        rt.block_on(call_owner(
            socket,
            Request::Login {
                password: pw.to_string(),
                hold: false,
            },
        ))?;
        r = rt.block_on(call_owner(socket, req.clone()));
    }
    if let Err(f) = &r
        && f.code == "password_required"
        && action == "now"
        && std::io::stdin().is_terminal()
    {
        let pw = crate::get_password(false, false, "Owner password: ")?;
        r = rt.block_on(call_owner(
            socket,
            Request::UpdateAutoNow {
                password: Some(pw.to_string()),
            },
        ));
    }
    finish(json, r.map(|(_, reply)| reply))
}

/// The reply of an `--auto` command, printed; an older daemon said in words.
fn finish(json: bool, r: Result<Reply, Fail>) -> Result<(), Fail> {
    match r {
        Ok(reply @ Reply::UpdateAuto(_)) => {
            if json {
                crate::output::print_json(&reply);
            } else {
                crate::output::human(&reply, crate::output::SasView::Digits);
            }
            Ok(())
        }
        Ok(_) => Err(Fail::new(
            EXIT_FAIL,
            "protocol",
            "unexpected reply to update_auto",
        )),
        Err(f) if f.code == "unknown_command" || f.code == "bad_request" => Err(Fail::new(
            EXIT_NOPERM,
            f.code.as_str(),
            format!(
                "the running daemon cannot install updates by itself ({}): it is older than this antenna",
                f.message
            ),
        )),
        Err(f) => Err(f),
    }
}
