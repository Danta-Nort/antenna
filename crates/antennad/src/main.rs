// SPDX-License-Identifier: AGPL-3.0-only
//! `antennad`: the node daemon (SPEC §3). It holds the keys, the database, the links' pairwise endpoints and the `0600`
//! control socket (on Windows a named pipe for the user alone, D-135).
//!
//! After startup the keystore is locked: `antenna init` (the first time) or `antenna unlock` (Q-4), except right after an
//! automatic update (D-103): the old daemon replaced itself with this one and handed the root key over a pipe
//! (`handover`).
//! Data of the `x` preview build (from before the rename) is migrated on the first start: see `migrate`.
//!
//! Windows (WP-28): a release `antennad.exe` is a GUI-subsystem program, so the window that starts it opens no console
//! window; its stderr still goes where the starter sends it (the window's log). A debug build keeps its console.

// The cfg_attr form: debug builds stay console programs for development.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod handover;
mod migrate;

use std::{net::IpAddr, path::PathBuf, process::ExitCode, time::Duration};

use antenna_core::{
    node::{Node, NodeConfig},
    transport::{NetConfig, RelayConfig},
};
use clap::Parser;

/// Version for `--version` and `status`: the package version and the build commit (`build.rs`).
const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), " (", env!("ANTENNA_COMMIT"), ")");

#[derive(Debug, Parser)]
#[command(
    name = "antennad",
    version = VERSION,
    about = "Antenna daemon (P2P messenger for people and AI agents)"
)]
struct Args {
    /// Data directory (default ~/.local/share/antenna, on Windows %LOCALAPPDATA%\Antenna; the old `X_DATA_DIR` is a
    /// fallback).
    #[arg(long, env = "ANTENNA_DATA_DIR")]
    data_dir: Option<PathBuf>,
    /// Control socket path (default <data-dir>/antennad.sock; the old `X_SOCKET` is a fallback). On Windows a local
    /// pipe name, `\\.\pipe\…` (by default from the user and the data folder, D-135).
    #[arg(long, env = "ANTENNA_SOCKET")]
    socket: Option<PathBuf>,
    /// Relay: `n0` (default), `disabled` (direct addresses only: tests, LAN) or the URL of your own relay.
    #[arg(long, default_value = "n0")]
    relay: String,
    /// IP for direct sockets (for example 127.0.0.1); all interfaces by default.
    #[arg(long)]
    bind_ip: Option<IpAddr>,
    /// Maximum pause between delivery retries, ms.
    #[arg(long, default_value_t = 30_000)]
    retry_max_ms: u64,
    /// Timeout for connecting to a link, ms.
    #[arg(long, default_value_t = 10_000)]
    dial_timeout_ms: u64,
    /// Link folders (`<contact>/inbox`, `<contact>/shared`; default ~/Antenna/links; the old `X_LINKS_DIR` is a
    /// fallback).
    #[arg(long, env = "ANTENNA_LINKS_DIR")]
    links_dir: Option<PathBuf>,
    /// Project folder that receives files from level-5 contacts (the old `X_PROJECT_DIR` is a fallback).
    #[arg(long, env = "ANTENNA_PROJECT_DIR")]
    project_dir: Option<PathBuf>,
    /// External antivirus: absolute path to `clamscan` (optional, Q-F-2; runs in the sandbox).
    #[arg(long)]
    clamscan: Option<PathBuf>,
    /// ClamAV databases for `--clamscan`.
    #[arg(long, default_value = "/var/lib/clamav")]
    clamav_db: PathBuf,
    /// Largest file an agent may send by content (the MCP tool `share_file_content`), MiB of decoded bytes; 0 turns
    /// the tool off. Files sent by path (`share_file`) are not limited by this.
    #[arg(long, env = "ANTENNA_SHARE_CONTENT_MAX_MIB", default_value_t = 25)]
    share_content_max_mib: u64,
    /// TESTS ONLY: allow `antenna invite --confirm` (A confirms without asking the owner, which removes the
    /// SPEC §6 item 9 protection).
    #[arg(long, hide = true)]
    allow_auto_confirm: bool,
    /// TESTS ONLY: the agent wake sandbox uses only Landlock, even if bubblewrap is available.
    #[arg(long, hide = true)]
    wake_landlock_only: bool,
    /// TESTS ONLY: approval requests expire after this many ms (only shorter than the 10 minutes of SPEC §9).
    #[arg(long, hide = true)]
    approval_ttl_ms: Option<u64>,
    /// The local model runtime (llama.cpp's `llama-server`) to run models with (default
    /// `<directory of antennad>/llama/llama-server`; its chat templates in `templates/` next to it).
    #[arg(long, hide = true)]
    local_runtime: Option<PathBuf>,
    /// Stop an idle local agent and unload an idle local model after this many seconds (default 1800).
    #[arg(long, hide = true)]
    local_idle_secs: Option<u64>,
    /// Local models may use at most this many bytes (only lowers the limit the daemon computes).
    #[arg(long, hide = true)]
    local_memory_budget: Option<u64>,
    /// Threads of a local model runtime (default: the physical cores; a shared server may want fewer).
    #[arg(long, hide = true)]
    local_threads: Option<u32>,
    /// TESTS ONLY (debug builds): a model catalog file instead of this release's.
    #[arg(long, hide = true)]
    local_catalog: Option<PathBuf>,
    /// TESTS ONLY (debug builds): download models from this https:// address (a loopback test server) instead of the
    /// hub.
    #[arg(long, hide = true)]
    local_hub: Option<String>,
    /// TESTS ONLY (debug builds): the CA certificate of `--local-hub`.
    #[arg(long, hide = true)]
    local_hub_cacert: Option<PathBuf>,
    /// TESTS ONLY: an automatic update waits this many ms without agent activity (only shorter than 10 minutes), looks
    /// every `--update-tick-ms` and warns the owner's window this long before (only shorter than 5 minutes).
    #[arg(long, hide = true)]
    update_quiet_ms: Option<u64>,
    /// TESTS ONLY: see `--update-quiet-ms` (only shorter than 30 s).
    #[arg(long, hide = true)]
    update_tick_ms: Option<u64>,
    /// TESTS ONLY: see `--update-quiet-ms`.
    #[arg(long, hide = true)]
    update_notice_ms: Option<u64>,
    /// The handover of an automatic update (D-103): the old daemon left the root key in this inherited pipe. Not for
    /// people: without the pipe the daemon starts locked, as always.
    #[arg(long, hide = true)]
    handover_fd: Option<i32>,
    /// The lifeline of a daemon the window starts as its child (D-UI-10): the window holds the daemon's stdin open for
    /// as long as it lives. At end of file (the window closed or was killed) the daemon locks and exits as on SIGTERM,
    /// so no daemon outlives the window that started it. Kept across an automatic update's re-exec, as stdin is.
    #[arg(long, hide = true)]
    exit_with_stdin: bool,
    /// TESTS ONLY: owner challenges expire after this many ms (only shorter than 60 s, CONTROL §22).
    #[arg(long, hide = true)]
    owner_challenge_ttl_ms: Option<u64>,
    /// TESTS ONLY: owner proofs ask for the password this many ms after the last one (only shorter than 14 days,
    /// D-102).
    #[arg(long, hide = true)]
    owner_password_every_ms: Option<u64>,
}

fn main() -> ExitCode {
    // Windows, release (WP-28): a GUI-subsystem program started from a terminal prints there (`--version`, `--help`,
    // a refusal); a standard error the window gave stays its log.
    #[cfg(all(windows, not(debug_assertions)))]
    antenna_sys::windows::console::attach_parent_console();
    // The file check worker process (`antennad --antenna-files-worker check`, antenna-files) comes before everything
    // else, without clap, tokio or logs; it sets up its own isolation (Landlock + seccomp + rlimits) before reading the
    // file. The agent supervisor on wake (`antennad --antenna-wake-exec`, antenna_core::sandbox) also comes before
    // everything else: the spec arrives on stdin, stdin is the lifeline, and the exit code is the agent's.
    // Windows (D-134): both run what is not trusted, and neither sandbox is built there yet (the file check's WP-19,
    // the agent's WP-20): refused before anything runs, never unsandboxed.
    #[cfg(windows)]
    if let Some(mode) = std::env::args_os().nth(1).filter(|a| {
        [
            antenna_core::sandbox::SUPERVISOR_ARG,
            antenna_core::files::WORKER_ARG,
        ]
        .iter()
        .any(|m| a == m)
    }) {
        eprintln!(
            "{} error: {}: {} does not run on Windows yet: its sandbox is not built (WP-19, WP-20)",
            antenna_core::sandbox::NOTE_PREFIX,
            antenna_proto::control::code::SANDBOX_UNAVAILABLE,
            mode.to_string_lossy()
        );
        std::process::exit(antenna_core::sandbox::EXIT_SANDBOX_FAILED);
    }
    if std::env::args_os().nth(1).as_deref()
        == Some(std::ffi::OsStr::new(antenna_core::sandbox::SUPERVISOR_ARG))
    {
        std::process::exit(antenna_core::sandbox::supervisor_main());
    }
    let mut argv = std::env::args_os();
    if argv.nth(1).as_deref() == Some(std::ffi::OsStr::new(antenna_core::files::WORKER_ARG)) {
        let rest: Vec<String> = argv.map(|a| a.to_string_lossy().into_owned()).collect();
        std::process::exit(antenna_files::worker::dispatch(&rest).unwrap_or_else(|| {
            eprintln!("antennad: unknown worker mode");
            2
        }));
    }
    // Descriptors the parent left without CLOEXEC (the desktop app, a script) must not reach the file check worker:
    // without isolation it rightly refuses to run (D-F-24, D-P-8). They stay open themselves, only marked CLOEXEC.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let fds = antenna_sys::fds::cloexec_inherited_fds();
    // Who this process is, read before anything can move its binary: an automatic update executes the binary at this
    // path again after the swap (D-103).
    let me = handover::Me::now();
    let mut args = Args::parse();
    // Windows (D-135): never elevated, checked before anything is touched (the data folder, the database).
    #[cfg(windows)]
    if let Err(e) = refuse_elevated() {
        eprintln!("antennad: {e}");
        return ExitCode::FAILURE;
    }
    // All daemon files (database, WAL, keystore, socket) are accessible only to the owner. (Windows: the data folder's
    // DACL, WP-4.)
    #[cfg(unix)]
    rustix::process::umask(rustix::fs::Mode::from_raw_mode(0o077));
    // SPEC §13: no core dumps and no ptrace from other processes of the same user. On Linux this also comes before the
    // handover pipe is read: after `execve` the process is dumpable again until here (D-103).
    if let Err(e) = harden() {
        eprintln!("antennad: warning: cannot disable core dumps / debugger attach: {e}");
    }
    let handed = args.handover_fd.take().map(handover::take);
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("ANTENNAD_LOG")
                .or_else(|_| tracing_subscriber::EnvFilter::try_from_env("XD_LOG"))
                // mDNS (LAN): replies from strangers on the network must not flood the log.
                .unwrap_or_else(|_| {
                    "warn,antenna_core=info,antennad=info,iroh_mdns_address_lookup=error,swarm_discovery=error"
                        .into()
                }),
        )
        .with_writer(std::io::stderr)
        .init();
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    match fds {
        Ok(m) => tracing::debug!("inherited descriptors marked CLOEXEC ({m:?})"),
        // The file check will then rightly refuse (`failed`, "inherited descriptors"); the daemon keeps running.
        Err(e) => tracing::warn!("cannot mark inherited descriptors CLOEXEC: {e}"),
    }
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("antennad: runtime: {e}");
            return ExitCode::FAILURE;
        }
    };
    let handed = match handed {
        Some(Err(e)) => {
            tracing::warn!("automatic update: no keys from the handover ({e}); starting locked");
            None
        }
        Some(Ok(h)) => {
            tracing::info!("automatic update: the keys came over the handover pipe");
            Some(h)
        }
        None => None,
    };
    let r = rt.block_on(run(args, me.clone(), handed));
    // Shut down as on SIGTERM: every task ends and the database closes before the process is replaced.
    rt.shutdown_timeout(Duration::from_secs(10));
    match r {
        Ok(None) => ExitCode::SUCCESS,
        Ok(Some(h)) => handover::exec(&me, h),
        Err(e) => {
            eprintln!("antennad: {e}");
            ExitCode::FAILURE
        }
    }
}

/// SPEC §13 "no core dumps and no ptrace". Linux: `PR_SET_DUMPABLE=0`, so no core dump and no ptrace/memory reads by
/// processes of the same uid. macOS and other unix (PORTABILITY M-1): `RLIMIT_CORE=0` against core dumps; on macOS in
/// release also `PT_DENY_ATTACH` (M-7, D-P-4), so a debugger cannot attach; memory reads through `task_for_pid` are
/// blocked by signing with the hardened runtime (`packaging/macos/build-dmg.sh`). In a debug build the developer needs
/// the debugger, so there is no `PT_DENY_ATTACH`.
#[cfg(unix)]
fn harden() -> std::io::Result<()> {
    #[cfg(target_os = "linux")]
    rustix::process::set_dumpable_behavior(rustix::process::DumpableBehavior::NotDumpable)?;
    #[cfg(not(target_os = "linux"))]
    rustix::process::setrlimit(
        rustix::process::Resource::Core,
        rustix::process::Rlimit {
            current: Some(0),
            maximum: Some(0),
        },
    )?;
    #[cfg(all(target_os = "macos", not(debug_assertions)))]
    antenna_sys::darwin::deny_debugger_attach()?;
    Ok(())
}

/// Windows: the process DACL that keeps other processes of the user out of its memory, and the error reporting
/// exclusion, are WP-11 (D-134, phase W1). Not done yet: said as a warning at every start, never assumed.
#[cfg(windows)]
fn harden() -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "not implemented on Windows yet (WP-11)",
    ))
}

/// Windows (D-135): an elevated daemon would own its pipe and files as the Administrators, with a high label, and its
/// keys would sit in an administrator's process: worse, not better. It says why and what to do instead.
#[cfg(windows)]
fn refuse_elevated() -> Result<(), String> {
    let t = antenna_sys::windows::process::Process::open(std::process::id())
        .and_then(|p| p.token())
        .map_err(|e| format!("cannot read this process's token: {e}"))?;
    if t.elevated {
        return Err(
            "antennad does not run elevated (as administrator): its pipe and data files would belong to the \
             Administrators, and its keys would sit in an administrator's process. Start it from a normal window, not \
             with \"Run as administrator\" and not from an elevated terminal. If User Account Control is turned off, \
             every program runs elevated: see docs/TROUBLESHOOTING.md, \"antennad runs elevated\"."
                .into(),
        );
    }
    Ok(())
}

/// Unix: the data folder made (`0700`, also when it existed with a wider mode), then locked for this daemon's life (the
/// returned file): one data folder has one daemon, whatever `--socket` says.
#[cfg(unix)]
fn prepare_data_dir(dir: &std::path::Path) -> Result<std::fs::File, String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(dir).map_err(|e| format!("data dir: {e}"))?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("data dir permissions: {e}"))?;
    antenna_core::data_lock::lock(dir).map_err(|e| e.to_string())
}

/// Windows (D-134 WP-4, D-135): the data folder, made for the user alone or checked, then locked for this daemon's
/// life (the returned file). Nothing is fixed silently.
#[cfg(windows)]
fn prepare_data_dir(dir: &std::path::Path) -> Result<std::fs::File, String> {
    use antenna_core::data_folder;
    let p = data_folder::prepare(dir).map_err(|e| e.to_string())?;
    if p.created {
        tracing::info!("made the data folder {} for this user alone", dir.display());
    }
    for n in &p.notes {
        tracing::info!("data folder {}: {n}", dir.display());
    }
    antenna_core::data_lock::lock(dir).map_err(|e| e.to_string())
}

/// Windows (D-135): the default control pipe, `\\.\pipe\antenna-<SID>-<h>`, from the user and the data folder's
/// canonical path.
#[cfg(windows)]
fn default_pipe(dir: &std::path::Path) -> Result<PathBuf, String> {
    let me = antenna_sys::windows::security::current_user()
        .map_err(|e| format!("cannot read this process's user: {e}"))?;
    let real = std::fs::canonicalize(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let real = real.to_str().ok_or_else(|| {
        format!(
            "{}: the data folder's path is not valid Unicode",
            real.display()
        )
    })?;
    Ok(PathBuf::from(antenna_proto::local::control_pipe_name(
        &me.to_string(),
        real,
    )))
}

/// macOS (PORTABILITY M-12): the default soft limit on open files is 256, exactly the number of control socket
/// connections, so iroh and SQLite would run out of descriptors. Raise it to `min(hard, 10240)` (`OPEN_MAX`).
#[cfg(target_os = "macos")]
fn raise_fd_limit() {
    use rustix::process::{Resource, Rlimit, getrlimit, setrlimit};
    let cur = getrlimit(Resource::Nofile);
    let want = cur.maximum.unwrap_or(u64::MAX).min(10_240);
    if cur.current.is_some_and(|c| c < want)
        && let Err(e) = setrlimit(
            Resource::Nofile,
            Rlimit {
                current: Some(want),
                maximum: cur.maximum,
            },
        )
    {
        tracing::warn!("cannot raise the open files limit to {want}: {e}");
    }
}

/// macOS (PORTABILITY M-13, SPEC "database outside backups"): Time Machine must not back up the data directory, since
/// restoring from a copy would bring back an old state of the ratchet and the links (a rollback). `tmutil addexclusion`
/// without `-p` sets a "sticky" attribute on the directory itself, without administrator rights. In the background:
/// daemon startup does not wait for `tmutil`; a failure is a warning.
#[cfg(target_os = "macos")]
fn exclude_from_backups(dir: &std::path::Path) {
    let dir = dir.to_path_buf();
    std::thread::spawn(move || {
        match std::process::Command::new("/usr/bin/tmutil")
            .arg("addexclusion")
            .arg(&dir)
            .stdin(std::process::Stdio::null())
            .output()
        {
            Ok(o) if o.status.success() => {
                tracing::debug!("{} excluded from Time Machine", dir.display())
            }
            Ok(o) => tracing::warn!(
                "tmutil addexclusion {}: {} {}",
                dir.display(),
                o.status,
                String::from_utf8_lossy(&o.stderr).trim()
            ),
            Err(e) => tracing::warn!("tmutil addexclusion {}: {e}", dir.display()),
        }
    });
}

/// Resolves when stdin reaches its end, with `--exit-with-stdin`; never without it. Stdin is read on a thread of its
/// own, outside the runtime, so a shutdown never waits for it.
async fn lifeline(on: bool) {
    if !on {
        return std::future::pending().await;
    }
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    std::thread::spawn(move || {
        use std::io::Read as _;
        let mut buf = [0u8; 256];
        let mut stdin = std::io::stdin().lock();
        while matches!(stdin.read(&mut buf), Ok(n) if n > 0) {}
        let _ = tx.send(());
    });
    let _ = rx.await;
}

fn absolute(p: PathBuf) -> Result<PathBuf, String> {
    std::path::absolute(&p).map_err(|e| format!("{}: {e}", p.display()))
}

/// Value from the old `X_*` environment variable (preview build) if the new one is not set; with a warning.
fn legacy_env(var: &antenna_proto::local::EnvVar) -> Option<PathBuf> {
    let v = var.legacy_only()?;
    tracing::warn!("{}", var.deprecation());
    Some(PathBuf::from(v))
}

/// Data directory and link folders: explicit (argument, variable) or default, in which case the `x` preview build is
/// migrated (`migrate`; never on Windows, where it never ran). Returns the data directory and the link folders (`None`
/// means the core's default).
fn resolve_dirs(args: &mut Args) -> Result<(PathBuf, Option<PathBuf>), String> {
    use antenna_proto::local;
    let env = |k: &str| std::env::var_os(k);
    let explicit_data = args
        .data_dir
        .take()
        .or_else(|| legacy_env(&local::ENV_DATA_DIR));
    let data_dir = match explicit_data {
        Some(d) => d,
        None if cfg!(windows) => local::default_data_dir_in(env),
        None => {
            let (new, old) = (
                local::default_data_dir_in(env),
                local::legacy_data_dir_in(env),
            );
            match migrate::data_dir(&new, &old)? {
                migrate::Outcome::Moved { from, to } => tracing::info!(
                    "moved the data of the preview build `x` from {} to {} (once; the product is now Antenna)",
                    from.display(),
                    to.display()
                ),
                migrate::Outcome::BothExist { old } => tracing::warn!(
                    "{} (preview build `x`) is left as is: {} already exists and is used",
                    old.display(),
                    new.display()
                ),
                migrate::Outcome::Nothing => {}
            }
            new
        }
    };
    if !cfg!(windows) && data_dir.is_dir() {
        match migrate::db_file(&data_dir)? {
            migrate::Outcome::Moved { from, to } => {
                tracing::info!("renamed the database {} → {}", from.display(), to.display())
            }
            migrate::Outcome::BothExist { old } => tracing::warn!(
                "{} (preview build `x`) is left as is: {} is used",
                old.display(),
                antenna_core::store::FILE_NAME
            ),
            migrate::Outcome::Nothing => {}
        }
    }
    let links = match args
        .links_dir
        .take()
        .or_else(|| legacy_env(&local::ENV_LINKS_DIR))
    {
        Some(l) => Some(absolute(l)?),
        None if cfg!(windows) => None,
        None => match (
            antenna_core::node::default_links_dir(),
            antenna_core::node::legacy_links_dir(),
        ) {
            (Some(new), Some(old)) => match migrate::links_dir(&new, &old) {
                Ok(migrate::Outcome::Moved { from, to }) => {
                    tracing::info!(
                        "moved the link folders {} → {}",
                        from.display(),
                        to.display()
                    );
                    None
                }
                Ok(migrate::Outcome::BothExist { old }) => {
                    tracing::warn!(
                        "{} (preview build `x`) is left as is: {} is used",
                        old.display(),
                        new.display()
                    );
                    None
                }
                Ok(migrate::Outcome::Nothing) => None,
                Err(e) => {
                    // Nothing is lost: keep working with the old folder.
                    tracing::warn!("{e}; using {}", old.display());
                    Some(old)
                }
            },
            _ => None,
        },
    };
    Ok((data_dir, links))
}

async fn run(
    mut args: Args,
    me: handover::Me,
    handed: Option<antenna_core::autoupdate::Handover>,
) -> Result<Option<antenna_core::autoupdate::Handover>, String> {
    let (data_dir, links_dir) = resolve_dirs(&mut args)?;
    // Before anything reads or writes in it; the lock is held until this function returns.
    let _lock = prepare_data_dir(&data_dir)?;
    #[cfg(target_os = "macos")]
    {
        raise_fd_limit();
        exclude_from_backups(&data_dir);
    }
    let socket = args
        .socket
        .take()
        .or_else(|| legacy_env(&antenna_proto::local::ENV_SOCKET));
    #[cfg(unix)]
    let socket = socket.unwrap_or_else(|| data_dir.join(antenna_proto::local::SOCKET_NAME));
    #[cfg(windows)]
    let socket = match socket {
        Some(s) => s,
        None => default_pipe(&data_dir)?,
    };
    let relay = RelayConfig::parse(&args.relay).map_err(|e| e.to_string())?;
    let mut cfg = NodeConfig::new(
        data_dir.clone(),
        NetConfig {
            relay,
            bind_ip: args.bind_ip,
        },
    );
    cfg.retry_max = Duration::from_millis(args.retry_max_ms.max(cfg.retry_min.as_millis() as u64));
    cfg.dial_timeout = Duration::from_millis(args.dial_timeout_ms.max(500));
    cfg.allow_auto_confirm = args.allow_auto_confirm;
    cfg.wake_landlock_only = args.wake_landlock_only;
    if let Some(ms) = args.approval_ttl_ms {
        cfg.approval_ttl = cfg.approval_ttl.min(Duration::from_millis(ms.max(1)));
    }
    if let Some(ms) = args.owner_challenge_ttl_ms {
        cfg.owner_challenge_ttl = cfg
            .owner_challenge_ttl
            .min(Duration::from_millis(ms.max(1)));
    }
    if let Some(ms) = args.owner_password_every_ms {
        cfg.owner_password_every = cfg
            .owner_password_every
            .min(Duration::from_millis(ms.max(1)));
    }
    cfg.share_content_max = args.share_content_max_mib.saturating_mul(1024 * 1024);
    // A catalog or a hub other than the release's would load models this release did not pin: only in debug builds,
    // like the update test key (D-82).
    if !cfg!(debug_assertions)
        && (args.local_catalog.is_some()
            || args.local_hub.is_some()
            || args.local_hub_cacert.is_some())
    {
        return Err(
            "--local-catalog, --local-hub and --local-hub-cacert exist only in debug builds".into(),
        );
    }
    if let Some(h) = &args.local_hub
        && !h.starts_with("https://")
    {
        return Err("--local-hub must be an https:// address".into());
    }
    cfg.local.runtime = args.local_runtime.take().map(absolute).transpose()?;
    cfg.local.catalog = args.local_catalog.take().map(absolute).transpose()?;
    cfg.local.hub = args.local_hub.take();
    cfg.local.hub_cacert = args.local_hub_cacert.take().map(absolute).transpose()?;
    if let Some(s) = args.local_idle_secs {
        cfg.local.idle = Duration::from_secs(s.max(1));
    }
    cfg.local.memory_cap = args.local_memory_budget;
    cfg.local.threads = args.local_threads;
    cfg.update.version = handover::version();
    cfg.daemon_version = format!(
        "antennad {} ({})",
        cfg.update.version,
        env!("ANTENNA_COMMIT")
    );
    cfg.update.exe = me.exe.clone();
    cfg.update.args = me.args.clone();
    cfg.update.cwd = me.cwd.clone();
    // Test switches only shorten (D-26).
    if let Some(ms) = args.update_quiet_ms {
        cfg.update.quiet = cfg.update.quiet.min(Duration::from_millis(ms));
    }
    if let Some(ms) = args.update_tick_ms {
        cfg.update.tick = cfg.update.tick.min(Duration::from_millis(ms.max(50)));
    }
    if let Some(ms) = args.update_notice_ms {
        cfg.update.notice = cfg.update.notice.min(Duration::from_millis(ms));
    }
    // A pipe name is not a path on disk: as given.
    cfg.control_socket = if cfg!(windows) {
        socket.clone()
    } else {
        absolute(socket.clone())?
    };
    if let Some(d) = links_dir {
        cfg.files.links_dir = d;
    }
    cfg.files.project_dir = args
        .project_dir
        .take()
        .or_else(|| legacy_env(&antenna_proto::local::ENV_PROJECT_DIR))
        .map(absolute)
        .transpose()?;
    if let Some(p) = args.clamscan {
        if !p.is_absolute() {
            return Err("--clamscan needs an absolute path".into());
        }
        cfg.files.av = Some(antenna_files::sandbox::AvHook::clamscan(p, args.clamav_db));
    }
    if cfg.allow_auto_confirm {
        tracing::warn!(
            "--allow-auto-confirm: invites may be confirmed without asking the owner (tests only)"
        );
    }
    let node = Node::new(cfg);
    // After an automatic update: unlocked with the handed-over key before the socket answers, so that the installer's
    // first answer from the new version is already its final state (D-103).
    if let Some(h) = handed {
        handover::reap(h.installer);
        match node.unlock_handover(h.root).await {
            Ok(()) => tracing::info!("automatic update: unlocked with the handed-over keys"),
            Err(e) => tracing::warn!(
                "automatic update: the handed-over keys did not open the database ({e}); locked"
            ),
        }
    }
    let listener = antenna_core::control::bind(&socket)
        .await
        .map_err(|e| e.to_string())?;
    tracing::info!(
        "antennad {} listening on {} (state: {}, relay: {})",
        VERSION,
        socket.display(),
        node.state_name().await,
        args.relay
    );
    let server = tokio::spawn(antenna_core::control::serve(listener, node.clone()));
    #[cfg(unix)]
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .map_err(|e| e.to_string())?;
    // Windows: the console closing; the named stop event the installer sets comes with WP-13 (D-134, phase W1).
    #[cfg(windows)]
    let mut term = tokio::signal::windows::ctrl_close().map_err(|e| e.to_string())?;
    let lifeline = lifeline(args.exit_with_stdin);
    let handover = tokio::select! {
        _ = tokio::signal::ctrl_c() => None,
        _ = term.recv() => None,
        _ = lifeline => {
            tracing::info!("antennad: the window that started it is gone (its stdin closed)");
            None
        }
        h = node.wait_handover() => Some(h),
    };
    tracing::info!(
        "antennad: shutting down{}",
        if handover.is_some() {
            " to replace itself with the new version (D-103)"
        } else {
            ""
        }
    );
    server.abort();
    let _ = node.lock().await; // Close the endpoints and wipe the keys from memory.
    #[cfg(unix)]
    let _ = std::fs::remove_file(&socket);
    Ok(handover)
}
