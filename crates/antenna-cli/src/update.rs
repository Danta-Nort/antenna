// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna update` (SPEC §12, §13; D-82; format and steps: `docs/UPDATES.md`).
//!
//! - `antenna update`: the installed version, where, the previous version, the pinned release keys, the update URL;
//! - `antenna update --from <folder | files…> [--dry-run | --manifest-only]`: verify a signed release (signature with
//!   the pinned keys, the manifest, strictly newer, the asset's hashes and platform) and install it;
//! - `antenna update --rollback`: put the `.previous` version back;
//! - `antenna update --check [--url …] [--download DIR]`: fetch a manifest over HTTPS and report.
//!
//! An owner command: it exists only in the owner CLI, not in the agent CLI and not in MCP (SPEC §9, rule 2). Installing
//! and rolling back are authorized by the daemon (`update_authorize`: the owner password, or an owner session); the
//! update itself is done here, because the daemon is one of the things being replaced. Output never panics on a closed
//! pipe: when the window starts an install, the CLI closes the window and keeps going, and the log file is the record.

#![deny(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "the window closes the CLI's stdio during an update; the update log file is the record"
)]

use std::{
    io::{BufRead, IsTerminal},
    path::{Path, PathBuf},
    process::ExitCode,
};

use antenna_proto::control::{Reply, Request};
use antenna_update::{
    self as up, Version,
    install::{
        DaemonOutcome, Env, Expect, FailAt, Installer, Log, Outcome, Probe, RealSys, RunningDaemon,
        Target, default_log_path,
    },
    keys::KeySet,
    manifest::{self, Asset, Manifest, Platform},
    package::{self, Release},
    sig,
};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::{
    UpdateArgs,
    client::{EXIT_FAIL, EXIT_NOPERM, EXIT_TEMPFAIL, EXIT_USAGE, Fail, call_owner},
};

macro_rules! errln {
    ($($t:tt)*) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stderr(), $($t)*);
    }};
}

macro_rules! out {
    ($v:expr) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stdout(), "{}", $v);
    }};
}

// After the macros: the automatic install uses `out!` and `errln!`.
mod auto;

fn up_fail(e: up::Error) -> Fail {
    let exit = match e.code {
        up::code::BAD_REQUEST => EXIT_USAGE,
        up::code::UPDATE_IN_PROGRESS => EXIT_TEMPFAIL,
        _ => EXIT_FAIL,
    };
    Fail::new(exit, e.code, e.message)
}

fn fail_out(f: &Fail, json: bool) -> ExitCode {
    if json {
        out!(json!({
            "ok": false,
            "error": f.code,
            "message": f.message,
            "command": "update",
            "protocol": antenna_proto::ProtocolVersion::CURRENT.to_string(),
            "approval": Value::Null,
        }));
    }
    errln!("antenna update: {}: {}", f.code, f.message);
    ExitCode::from(f.exit)
}

/// The running version (debug builds: `ANTENNA_UPDATE_CURRENT_VERSION` pretends to be another one, for tests).
fn current() -> Expect {
    #[allow(unused_mut, reason = "reassigned only in debug builds")]
    let mut version = env!("CARGO_PKG_VERSION").to_string();
    #[cfg(debug_assertions)]
    if let Ok(v) = std::env::var("ANTENNA_UPDATE_CURRENT_VERSION")
        && !v.is_empty()
    {
        version = v;
    }
    Expect {
        version,
        commit: env!("ANTENNA_COMMIT").to_string(),
    }
}

/// Debug builds: `ANTENNA_UPDATE_FAIL_AT=<point>[:abort]` (tests of an interrupted update).
fn fail_at() -> FailAt {
    #[cfg(debug_assertions)]
    if let Ok(v) = std::env::var("ANTENNA_UPDATE_FAIL_AT")
        && !v.is_empty()
    {
        return Some(match v.split_once(':') {
            Some((p, "abort")) => (p.to_string(), true),
            _ => (v, false),
        });
    }
    None
}

struct SocketProbe<'a> {
    rt: &'a tokio::runtime::Runtime,
    path: PathBuf,
}

impl Probe for SocketProbe<'_> {
    fn daemon_version(&self) -> Option<String> {
        self.daemon_state().map(|(v, _)| v)
    }

    fn daemon_state(&self) -> Option<(String, String)> {
        match self.rt.block_on(call_owner(&self.path, Request::Status {})) {
            Ok((_, Reply::Status(s))) => Some((s.daemon, s.state)),
            _ => None,
        }
    }
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

fn abs_env(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
}

/// The user's uid (`launchctl … gui/<uid>`).
#[cfg(unix)]
fn own_uid() -> u32 {
    rustix::process::getuid().as_raw()
}

/// Windows has no uid; nothing there reaches `launchctl` (the installation is unsupported, D-134, WP-29).
#[cfg(windows)]
fn own_uid() -> u32 {
    0
}

/// The update URL: `--url`, then `ANTENNA_UPDATE_URL`, then `~/.config/antenna/update-url`, then the one built into
/// release builds (D-137); `off` turns it off. The daemon's daily check reads the same places through the same function.
fn update_url(explicit: Option<&str>) -> Option<String> {
    up::fetch::update_url(explicit, &up::fetch::config_dir())
}

fn this_target() -> Target {
    let exe = std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .unwrap_or_default();
    Target::detect(&exe, std::env::consts::OS, &|p: &Path| p.is_file())
}

/// The platform whose asset this installation needs (for an unsupported one, the closest guess, for reporting).
fn platform_of(t: &Target) -> Platform {
    t.platform().unwrap_or_else(|| {
        Platform::this(if std::env::consts::OS == "macos" {
            "app"
        } else {
            "cli"
        })
    })
}

fn line_json(e: &Expect) -> Value {
    json!({ "version": e.version, "commit": e.commit })
}

fn install_json(t: &Target) -> Value {
    json!({
        "kind": t.kind(),
        "path": t.path().map(|p| p.display().to_string()),
        "reason": match t { Target::Unsupported { reason, .. } => Some(reason.clone()), _ => None },
    })
}

fn asset_json(a: &Asset, path: Option<&Path>, url: Option<&str>) -> Value {
    let mut v = json!({
        "name": a.name, "os": a.os, "arch": a.arch, "kind": a.kind, "size": a.size, "sha256": a.sha256,
        "blake3": a.blake3,
    });
    if let Some(p) = path {
        v["path"] = p.display().to_string().into();
    }
    if let Some(u) = url {
        v["url"] = u.into();
    }
    v
}

fn update_json(rel: &Release) -> Value {
    json!({
        "version": rel.manifest.version,
        "channel": rel.manifest.channel,
        "commit": rel.manifest.commit,
        "created": rel.manifest.created,
        "manifest": rel.path.display().to_string(),
    })
}

fn sig_json(v: &sig::Verified) -> Value {
    json!({ "valid": true, "key_ids": v.key_ids, "test_key": v.test_key })
}

fn outcome_json(o: &Outcome, log: &Log) -> Value {
    let d: &DaemonOutcome = &o.daemon;
    json!({
        "ok": true,
        "action": o.action,
        "from": Expect::parse(&o.from).map(|e| line_json(&e)).unwrap_or(Value::Null),
        "to": Expect::parse(&o.to).map(|e| line_json(&e)).unwrap_or(Value::Null),
        "previous": o.previous.as_ref().map(|p| p.display().to_string()),
        "daemon": { "restarted": d.restarted, "how": d.how, "note": d.note },
        "app": o.app_relaunched.map(|r| json!({ "relaunched": r })),
        "keys_locked": o.keys_locked,
        "log": log.path().map(|p| p.display().to_string()),
    })
}

fn human_size(n: u64) -> String {
    if n >= 1 << 20 {
        format!("{:.1} MB", n as f64 / 1_000_000.0)
    } else {
        format!("{n} bytes")
    }
}

/// `antenna update …`.
pub(crate) fn run(
    json: bool,
    socket: Option<&PathBuf>,
    data_dir: Option<&PathBuf>,
    a: &UpdateArgs,
) -> ExitCode {
    let rt = match crate::runtime() {
        Ok(rt) => rt,
        Err(c) => return c,
    };
    let socket = crate::client::socket_path(&socket.cloned(), &data_dir.cloned());
    let target = this_target();
    let log_path = default_log_path(
        &home(),
        std::env::consts::OS,
        abs_env("XDG_STATE_HOME").as_deref(),
    );
    // A dry run, a check and the status write nothing to the log; installing and rolling back log every step.
    let acting = !a.from.is_empty() && !a.dry_run && !a.manifest_only || a.rollback;
    // Every step goes to the log file (a dry run and the status have none, except recovering an interrupted update);
    // installing and rolling back also show them on stderr.
    let log = Log::new(Some(log_path.clone()), acting && !json);
    let probe = SocketProbe {
        rt: &rt,
        path: socket.clone(),
    };
    let sys = RealSys;
    let env = Env {
        home: home(),
        uid: own_uid(),
        xdg_config: abs_env("XDG_CONFIG_HOME"),
    };
    let handoff = auto::StdoutHandoff::default();
    let mut inst = Installer {
        target: target.clone(),
        sys: &sys,
        log: &log,
        probe: &probe,
        env,
        running: None,
        fail_at: fail_at(),
        handoff: a.handover.then_some(&handoff as &dyn up::install::Handoff),
    };
    let r = if let Some(action) = &a.auto {
        auto::auto(json, &rt, &socket, a, action)
    } else if a.handover {
        auto::handover(json, &mut inst, a, &handoff)
    } else if a.check {
        check(json, &inst, a)
    } else if a.rollback {
        rollback(json, &rt, &socket, &mut inst, a)
    } else if !a.from.is_empty() {
        from(json, &rt, &socket, &mut inst, a, &log_path)
    } else {
        status(json, &inst, &log_path)
    };
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(f) => fail_out(&f, json),
    }
}

/// Recovers an interrupted update before doing anything else.
fn recover(inst: &Installer<'_>) -> Result<Option<String>, Fail> {
    inst.recover().map_err(up_fail)
}

fn status(json: bool, inst: &Installer<'_>, log_path: &Path) -> Result<(), Fail> {
    let recovered = recover(inst)?;
    let cur = current();
    let keys = KeySet::pinned();
    let prev = inst.previous();
    let url = update_url(None);
    if json {
        out!(json!({
            "ok": true,
            "action": "status",
            "current": line_json(&cur),
            "install": install_json(&inst.target),
            "previous": prev.as_ref().map(|(_, e)| line_json(e)),
            "keys": { "pinned": keys.keys.iter().filter(|k| !k.test).count(), "ids": keys.ids(), "test_key": keys.has_test_key() },
            "update_url": url,
            "recovered": recovered,
            "log": log_path.display().to_string(),
        }));
        return Ok(());
    }
    out!(format!("Antenna {} ({})", cur.version, cur.commit));
    match &inst.target {
        Target::Unsupported { reason, .. } => {
            out!(format!("installed:    cannot update itself: {reason}"))
        }
        t => out!(format!(
            "installed at: {} ({})",
            t.path()
                .map(|p| p.display().to_string())
                .unwrap_or_default(),
            if t.kind() == "macos_app" {
                "macOS app"
            } else {
                "antenna and antennad"
            }
        )),
    }
    match &prev {
        Some((_, e)) => out!(format!(
            "previous:     {} ({}): antenna update --rollback puts it back",
            e.version, e.commit
        )),
        None => out!("previous:     none"),
    }
    if keys.is_empty() {
        out!("release keys: none pinned in this build, so every update is refused");
    } else {
        out!(format!("release keys: {}", keys.ids().join(", ")));
    }
    out!(format!(
        "update URL:   {}",
        url.as_deref().unwrap_or("not configured")
    ));
    out!(format!("log:          {}", log_path.display()));
    if let Some(r) = recovered {
        out!(format!("note: {r}"));
    }
    Ok(())
}

/// Verifies a package: signature, manifest, version policy, asset.
struct Verified {
    rel: Release,
    asset: Option<(Asset, PathBuf)>,
    newer: bool,
}

fn verify(inst: &Installer<'_>, a: &UpdateArgs) -> Result<Verified, Fail> {
    let loc = package::locate(&a.from).map_err(up_fail)?;
    let rel = package::open_release(&loc, &KeySet::pinned()).map_err(up_fail)?;
    let cur: Version = current()
        .version
        .parse()
        .map_err(|e| Fail::new(EXIT_FAIL, up::code::BAD_MANIFEST, format!("{e}")))?;
    let allow_same = a.allow_same && cfg!(debug_assertions);
    if a.allow_same && !allow_same {
        return Err(Fail::new(
            EXIT_USAGE,
            "bad_request",
            "--allow-same is for test builds only",
        ));
    }
    let newer = package::check_newer(&cur, &rel.version, allow_same);
    let platform = platform_of(&inst.target);
    if a.manifest_only {
        let asset = match package::find_asset(&rel, &loc, &platform) {
            Ok(x) => Some(x),
            Err(e) if e.code == up::code::ASSET_MISSING || e.code == up::code::WRONG_PLATFORM => {
                None
            }
            Err(e) => return Err(up_fail(e)),
        };
        return Ok(Verified {
            newer: newer.is_ok(),
            rel,
            asset,
        });
    }
    newer.map_err(up_fail)?;
    let asset = package::find_asset(&rel, &loc, &platform).map_err(up_fail)?;
    Ok(Verified {
        rel,
        asset: Some(asset),
        newer: true,
    })
}

fn print_verified(
    json: bool,
    v: &Verified,
    inst: &Installer<'_>,
    steps: &[String],
    log_path: &Path,
) {
    let cur = current();
    if json {
        out!(json!({
            "ok": true,
            "action": "verify",
            "current": line_json(&cur),
            "update": update_json(&v.rel),
            "newer": v.newer,
            "signature": sig_json(&v.rel.sig),
            "assets": v.rel.manifest.assets.iter().map(|a| asset_json(a, None, None)).collect::<Vec<_>>(),
            "asset": v.asset.as_ref().map(|(a, p)| asset_json(a, Some(p), None)),
            "install": install_json(&inst.target),
            "steps": steps,
            "log": log_path.display().to_string(),
        }));
        return;
    }
    let m = &v.rel.manifest;
    errln!(
        "Antenna {} ({} channel, built {}, commit {})",
        m.version,
        m.channel,
        m.created,
        m.commit
    );
    errln!(
        "  signature: valid (release key {}){}",
        v.rel.sig.key_ids.join(", "),
        if v.rel.sig.test_key {
            " — THE PUBLIC TEST KEY: a test build"
        } else {
            ""
        }
    );
    match &v.asset {
        Some((a, p)) => errln!(
            "  file:      {} ({}), hashes match the manifest",
            p.display(),
            human_size(a.size)
        ),
        None => errln!("  file:      this platform's file is not here"),
    }
    errln!(
        "  installed: {} ({}){}",
        cur.version,
        cur.commit,
        if v.newer {
            ""
        } else {
            ": the update is not newer"
        }
    );
    if !steps.is_empty() {
        errln!("Plan:");
        for (i, s) in steps.iter().enumerate() {
            errln!("  {}. {s}", i + 1);
        }
    }
}

/// Asks "go ahead?" in a terminal; `--yes` skips it; without a terminal `--yes` is required.
fn confirm(a: &UpdateArgs, json: bool, question: &str) -> Result<(), Fail> {
    if a.yes {
        return Ok(());
    }
    if json || a.pw.password_stdin || !std::io::stdin().is_terminal() {
        return Err(Fail::new(
            EXIT_USAGE,
            "bad_request",
            "pass --yes to go ahead without a question",
        ));
    }
    {
        use std::io::Write as _;
        let mut e = std::io::stderr();
        let _ = write!(e, "{question} [y/N] ");
        let _ = e.flush();
    }
    let mut s = String::new();
    let _ = std::io::stdin().lock().read_line(&mut s);
    if matches!(s.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
        Ok(())
    } else {
        Err(Fail::new(EXIT_FAIL, "cancelled", "nothing was changed"))
    }
}

/// The owner authorizes through the daemon (password, or an owner session; in a terminal without a session, the
/// password is asked). `Ok(None)`: no daemon answers (allowed for a rollback only).
fn authorize(
    rt: &tokio::runtime::Runtime,
    socket: &Path,
    a: &UpdateArgs,
    action: &str,
    version: Option<&str>,
    allow_no_daemon: bool,
) -> Result<Option<RunningDaemon>, Fail> {
    let req = |password: Option<String>| Request::UpdateAuthorize {
        action: action.into(),
        version: version.map(str::to_string),
        password,
    };
    let password: Option<Zeroizing<String>> = if a.pw.password_stdin {
        Some(crate::read_line_stdin()?)
    } else {
        None
    };
    // `--touch-id` (the window's install, D-131): one touch, the password only if it does not go through
    let mut r = if a.pw.touch_id {
        rt.block_on(crate::owner::touch::call_pw(socket, &a.pw, |p| {
            req(Some(p))
        }))
    } else {
        rt.block_on(call_owner(
            socket,
            req(password.as_ref().map(|p| p.to_string())),
        ))
        .map(|(_, r)| r)
    };
    if let Err(f) = &r
        && f.code == "login_required"
        && password.is_none()
        && std::io::stdin().is_terminal()
    {
        // No owner session in this terminal: one touch when Touch ID is on here, otherwise the password
        r = rt.block_on(crate::owner::touch::call_pw(socket, &a.pw, |p| {
            req(Some(p))
        }));
    }
    match r {
        Ok(Reply::UpdateAuthorized(u)) => Ok(Some(RunningDaemon {
            pid: u.pid,
            exe: u.exe.map(PathBuf::from),
            version: u.daemon,
            args: vec![],
            cwd: None,
        })),
        Ok(_) => Err(Fail::new(
            EXIT_FAIL,
            "protocol",
            "unexpected reply to update_authorize",
        )),
        Err(f) if f.code == "daemon_unavailable" && allow_no_daemon => Ok(None),
        Err(f) if f.code == "daemon_unavailable" => Err(Fail::new(
            EXIT_TEMPFAIL,
            "daemon_unavailable",
            format!(
                "{}. The owner password is checked by the daemon: start it (or open Antenna) and unlock, then run \
                 antenna update again",
                f.message
            ),
        )),
        Err(f) if f.code == "unknown_command" || f.code == "bad_request" => Err(Fail::new(
            EXIT_NOPERM,
            f.code.as_str(),
            format!(
                "the running daemon cannot authorize updates ({}): it is older than this antenna",
                f.message
            ),
        )),
        Err(f) => Err(f),
    }
}

fn from(
    json: bool,
    rt: &tokio::runtime::Runtime,
    socket: &Path,
    inst: &mut Installer<'_>,
    a: &UpdateArgs,
    log_path: &Path,
) -> Result<(), Fail> {
    if let Some(r) = recover(inst)? {
        errln!("note: {r}");
    }
    let v = verify(inst, a)?;
    let steps = if a.manifest_only {
        vec![]
    } else {
        inst.plan_install(&v.rel)
    };
    if a.dry_run || a.manifest_only {
        print_verified(json, &v, inst, &steps, log_path);
        return Ok(());
    }
    if let Target::Unsupported { reason, .. } = &inst.target {
        return Err(Fail::new(
            EXIT_FAIL,
            up::code::UNSUPPORTED_INSTALL,
            reason.clone(),
        ));
    }
    if !json {
        print_verified(false, &v, inst, &steps, log_path);
    }
    confirm(
        a,
        json,
        &format!("Install Antenna {}?", v.rel.manifest.version),
    )?;
    inst.running = authorize(
        rt,
        socket,
        a,
        "install",
        Some(&v.rel.manifest.version),
        false,
    )?;
    let (asset, path) = v.asset.as_ref().expect("a full verification has the asset");
    let out = inst.install(&v.rel, asset, path).map_err(up_fail)?;
    finish(json, &out, inst.log);
    Ok(())
}

fn finish(json: bool, out: &Outcome, log: &Log) {
    if json {
        out!(outcome_json(out, log));
        return;
    }
    let verb = if out.action == "rollback" {
        "Rolled back"
    } else {
        "Installed"
    };
    out!(format!("{verb}: {} (was {}).", out.to, out.from));
    if let Some(p) = &out.previous {
        out!(format!(
            "The replaced version is kept at {} (antenna update --rollback).",
            p.display()
        ));
    }
    if out.keys_locked {
        out!(
            "The daemon was restarted: its keys are locked, as after a reboot. Unlock with your password (antenna unlock, or in the window)."
        );
    }
    if let Some(n) = &out.daemon.note {
        out!(format!("Note: {n}."));
    }
    if let Some(p) = log.path() {
        out!(format!("Log: {}", p.display()));
    }
}

fn rollback(
    json: bool,
    rt: &tokio::runtime::Runtime,
    socket: &Path,
    inst: &mut Installer<'_>,
    a: &UpdateArgs,
) -> Result<(), Fail> {
    if let Some(r) = recover(inst)? {
        errln!("note: {r}");
    }
    if let Target::Unsupported { reason, .. } = &inst.target {
        return Err(Fail::new(
            EXIT_FAIL,
            up::code::UNSUPPORTED_INSTALL,
            reason.clone(),
        ));
    }
    let (prev, steps) = inst.plan_rollback().map_err(up_fail)?;
    if !json {
        errln!("Roll back to {} ({})", prev.version, prev.commit);
        for (i, s) in steps.iter().enumerate() {
            errln!("  {}. {s}", i + 1);
        }
    }
    confirm(a, json, &format!("Roll back to {}?", prev.version))?;
    // A rollback is often needed because the new daemon does not start: without a daemon it goes ahead (it restores a
    // version that was installed before, nothing new).
    inst.running = authorize(rt, socket, a, "rollback", Some(&prev.version), true)?;
    if inst.running.is_none() {
        inst.log
            .step("no daemon answers: rolling back without the owner check through the daemon");
    }
    let out = inst.rollback().map_err(up_fail)?;
    finish(json, &out, inst.log);
    Ok(())
}

/// Fetches a URL over HTTPS (`curl`, HTTPS only, also for redirects), at most `max` bytes, into memory or a file.
fn fetch(url: &str, max: u64, to: Option<&Path>) -> Result<Vec<u8>, Fail> {
    up::fetch::https(url, max, to).map_err(up_fail)
}

fn check(json: bool, inst: &Installer<'_>, a: &UpdateArgs) -> Result<(), Fail> {
    let Some(url) = update_url(a.url.as_deref()) else {
        return Err(Fail::new(
            EXIT_USAGE,
            "no_update_url",
            "no update URL (a development build, or turned off with `off`): pass --url, set ANTENNA_UPDATE_URL, or put it into ~/.config/antenna/update-url",
        ));
    };
    let bytes = fetch(&url, manifest::MAX_BYTES as u64, None)?;
    let sig_bytes = fetch(&format!("{url}.sig"), sig::MAX_BYTES as u64, None)?;
    let verified = sig::verify(&bytes, &sig_bytes, &KeySet::pinned()).map_err(up_fail)?;
    let (m, version): (Manifest, Version) = Manifest::parse(&bytes).map_err(up_fail)?;
    let cur: Version = current()
        .version
        .parse()
        .map_err(|e| Fail::new(EXIT_FAIL, up::code::BAD_MANIFEST, format!("{e}")))?;
    let newer = version > cur;
    let base = url
        .rsplit_once('/')
        .map(|(b, _)| b.to_string())
        .unwrap_or_default();
    let asset = m.asset_for(&platform_of(&inst.target)).ok().cloned();
    let mut downloaded = None;
    if let (Some(dir), Some(asset)) = (&a.download, &asset) {
        std::fs::create_dir_all(dir)
            .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("{}: {e}", dir.display())))?;
        let mp = dir.join(manifest::manifest_name(&m.version));
        let write = |p: &Path, b: &[u8]| {
            std::fs::write(p, b)
                .map_err(|e| Fail::new(EXIT_FAIL, "io", format!("{}: {e}", p.display())))
        };
        write(&mp, &bytes)?;
        write(&dir.join(manifest::signature_name(&m.version)), &sig_bytes)?;
        let ap = dir.join(&asset.name);
        fetch(&format!("{base}/{}", asset.name), asset.size, Some(&ap))?;
        let (size, sha, b3) = manifest::hash_file(&ap).map_err(up_fail)?;
        if size != asset.size || sha != asset.sha256 || b3 != asset.blake3 {
            let _ = std::fs::remove_file(&ap);
            return Err(Fail::new(
                EXIT_FAIL,
                up::code::HASH_MISMATCH,
                format!(
                    "the downloaded {} does not match the signed manifest",
                    asset.name
                ),
            ));
        }
        downloaded = Some(dir.display().to_string());
    }
    let rel = Release {
        manifest: m.clone(),
        version,
        sig: verified,
        path: PathBuf::from(&url),
    };
    if json {
        let mut u = update_json(&rel);
        u["manifest"] = url.clone().into();
        out!(json!({
            "ok": true,
            "action": "check",
            "url": url,
            "current": line_json(&current()),
            "update": u,
            "newer": newer,
            "signature": sig_json(&rel.sig),
            "asset": asset.as_ref().map(|x| asset_json(x, None, Some(&format!("{base}/{}", x.name)))),
            "downloaded": downloaded,
        }));
        return Ok(());
    }
    if newer {
        out!(format!(
            "Antenna {} is available ({} channel, signed by release key {}); you have {}.",
            m.version,
            m.channel,
            rel.sig.key_ids.join(", "),
            current().version
        ));
        match (&asset, &downloaded) {
            (Some(_), Some(d)) => out!(format!(
                "Downloaded and checked. Install with: antenna update --from {d}"
            )),
            (Some(x), None) => out!(format!(
                "File for this installation: {base}/{} ({}). Download it with: antenna update --check --download <folder>",
                x.name,
                human_size(x.size)
            )),
            (None, _) => out!("The release has no file for this installation."),
        }
    } else {
        out!(format!(
            "Up to date: {} is installed, the latest is {}.",
            current().version,
            m.version
        ));
    }
    Ok(())
}
