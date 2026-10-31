// SPDX-License-Identifier: AGPL-3.0-only
//! Signed updates that install by themselves (D-103) end to end with real daemons: a node in the `install.sh` layout
//! (`antenna` and `antennad` hard-linked into a temporary `bin/`, told to call itself `0.0.1`, the debug-only
//! `ANTENNA_UPDATE_CURRENT_VERSION`) with "Install signed updates by itself" on, and its own computer at level 5 that
//! sends it release files signed with the public test key (trusted by debug builds with `ANTENNA_UPDATE_TEST_KEY=1`).
//!
//! - the newer release from the level-5 contact installs itself: the daemon replaces itself (the same PID), comes back
//!   unlocked on the new version without the password, the link works, the key is nowhere on disk and no extra
//!   descriptor stays open;
//! - older, same, other-platform, unsigned and test-key (without the variable) releases are refused or ignored and
//!   nothing changes; files from level 4 start nothing; with the setting off nothing happens;
//! - a busy agent delays the install; a new binary that exits brings the old version back, locked, and that version is
//!   not tried again; without the handover pipe the new version comes up locked (the control for the pipe);
//! - a test that ends during an install leaves no process behind (the installer and the old version it would start
//!   again are ended with the world).
//!
//! The process checks read `/proc`: Linux only.
#![cfg(target_os = "linux")]

mod common;

use std::{
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

use antenna_update::{
    keys::test_signing_key,
    manifest::{self, Platform},
    sig, signing,
};
use common::*;
use serde_json::Value;

/// Version and commit of the built binaries (version B).
fn built() -> (String, String) {
    let o = Command::new(x_bin())
        .clean_env()
        .arg("--version")
        .output()
        .unwrap();
    let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
    let (_, rest) = s.split_once(' ').unwrap();
    let (v, c) = rest.split_once(" (").unwrap();
    (v.to_string(), c.trim_end_matches(')').to_string())
}

fn ident(p: &Path) -> (u64, u64) {
    let m = std::fs::symlink_metadata(p).unwrap();
    (m.dev(), m.ino())
}

fn script(p: &Path, body: &str) {
    std::fs::write(p, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// What the release archive's `antennad` is.
#[derive(Clone, Copy, PartialEq)]
enum Daemon {
    /// The built daemon, through a wrapper that drops the "I am 0.0.1" variable (so it answers as version B).
    Real,
    /// A program that answers `--version` correctly and exits at once otherwise (a new version that does not start).
    Exits,
}

/// How the manifest is signed.
#[derive(Clone, Copy, PartialEq)]
enum Signer {
    TestKey,
    /// A key that no build pins.
    Unknown,
}

struct Release {
    asset_name: String,
    files: Vec<PathBuf>,
}

/// A release folder: the CLI archive for this machine (or `arch`), the manifest and its signature.
fn release(
    dir: &Path,
    version: &str,
    daemon: Daemon,
    signer: Signer,
    arch: Option<&str>,
) -> Release {
    let (_, commit) = built();
    let p = Platform::this("cli");
    let arch = arch.unwrap_or(p.arch);
    let top = format!("antenna-{version}-linux-{arch}");
    let src = dir.join("src").join(&top).join("bin");
    std::fs::create_dir_all(&src).unwrap();
    match daemon {
        Daemon::Real => {
            std::fs::copy(x_bin(), src.join("antenna")).unwrap();
            script(
                &src.join("antennad"),
                &format!(
                    "unset ANTENNA_UPDATE_CURRENT_VERSION\nexec '{}' \"$@\"",
                    xd_bin().display()
                ),
            );
        }
        Daemon::Exits => {
            for b in ["antenna", "antennad"] {
                script(
                    &src.join(b),
                    &format!(
                        "if [ \"$1\" = --version ]; then echo '{b} {version} ({commit})'; exit 0; fi\necho 'this version does not start' >&2\nexit 3"
                    ),
                );
            }
        }
    }
    let name = format!("{top}.tar.gz");
    let out = dir.join("out");
    std::fs::create_dir_all(&out).unwrap();
    let st = Command::new("tar")
        .arg("-czf")
        .arg(out.join(&name))
        .arg("-C")
        .arg(dir.join("src"))
        .arg(&top)
        .status()
        .unwrap();
    assert!(st.success());
    let m = signing::build_manifest(
        version,
        "preview",
        &commit,
        "2026-10-06T12:00:00Z",
        &[out.join(&name)],
    )
    .unwrap();
    let bytes = m.to_bytes();
    let mp = out.join(manifest::manifest_name(version));
    std::fs::write(&mp, &bytes).unwrap();
    let key = match signer {
        Signer::TestKey => test_signing_key(),
        Signer::Unknown => ed25519_dalek::SigningKey::from_bytes(&[7u8; 32]),
    };
    let s = sig::SignatureFile::new(sig::sign(&bytes, &key));
    let sp = out.join(manifest::signature_name(version));
    std::fs::write(&sp, s.to_bytes()).unwrap();
    Release {
        asset_name: name.clone(),
        files: vec![out.join(&name), sp, mp],
    }
}

/// The updating node ("own"), its install layout and its own computer ("mac", level 5 both ways).
struct World {
    root: PathBuf,
    bin: PathBuf,
    home: PathBuf,
    own: Node,
    mac: Node,
    // Last: the nodes print their log tails from it when a test fails.
    _tmp: tempfile::TempDir,
}

impl World {
    fn new(trust: u8, env: &[(&str, &str)]) -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_path_buf();
        let bin = root.join("prefix/bin");
        let home = root.join("home");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        for (from, to) in [(x_bin(), "antenna"), (xd_bin(), "antennad")] {
            if std::fs::hard_link(&from, bin.join(to)).is_err() {
                std::fs::copy(&from, bin.join(to)).unwrap();
            }
        }
        let mut own = Node::new(&root, "own", Net::Local);
        own.bin_dir = Some(bin.clone());
        own.extra_args = [
            "--update-quiet-ms",
            "1500",
            "--update-tick-ms",
            "200",
            "--update-notice-ms",
            "1000",
        ]
        .map(String::from)
        .to_vec();
        // The installer logs under $HOME and the daemon reads ~/.config/antenna/update-url: both in the test folder.
        own.extra_env = vec![
            ("HOME".into(), home.display().to_string()),
            (
                "XDG_STATE_HOME".into(),
                home.join(".local/state").display().to_string(),
            ),
            (
                "XDG_CONFIG_HOME".into(),
                home.join(".config").display().to_string(),
            ),
            ("ANTENNA_UPDATE_CURRENT_VERSION".into(), "0.0.1".into()),
        ];
        for (k, v) in env {
            own.extra_env.push(((*k).into(), (*v).into()));
        }
        own.start();
        own.init();
        let mut mac = Node::new(&root, "mac", Net::Local);
        mac.start();
        mac.init();
        pair(&own, &mac, trust);
        Self {
            _tmp: tmp,
            root,
            bin,
            home,
            own,
            mac,
        }
    }

    fn auto(&self, action: &str) -> Value {
        let o = self.own.x_stdin(
            &["--json", "update", "--auto", action, "--password-stdin"],
            &format!("{}\n", self.own.password),
        );
        assert!(o.status.success(), "update --auto {action}: {o:?}");
        last_json(&o.stdout)
    }

    fn status(&self) -> Value {
        self.own.json(&["update", "--auto", "status"])
    }

    fn wait_status(&self, what: &str, secs: u64, f: impl Fn(&Value) -> bool) -> Value {
        let t = Instant::now();
        loop {
            let o = self.own.x(&["--json", "update", "--auto", "status"]);
            if o.status.success() {
                let v = last_json(&o.stdout);
                if f(&v) {
                    return v;
                }
            }
            assert!(
                t.elapsed() < Duration::from_secs(secs),
                "timeout waiting for {what}: {}",
                String::from_utf8_lossy(&o.stdout)
            );
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// The level-5 contact sends the files, one after another (each is checked and accepted by "own" by itself).
    fn deliver(&self, files: &[PathBuf]) {
        for f in files {
            let o = self.mac.x(&["--json", "share", "own", f.to_str().unwrap()]);
            assert!(o.status.success(), "share {}: {o:?}", f.display());
        }
    }

    /// The link folder where "own" accepts the contact's files.
    fn shared(&self) -> PathBuf {
        self.own.links().join("mac").join("shared")
    }

    fn wait_accepted(&self, name: &str) {
        let p = self.shared().join(name);
        let t = Instant::now();
        while !p.exists() {
            assert!(
                t.elapsed() < Duration::from_secs(90),
                "{} never arrived",
                p.display()
            );
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// The daemon's version line and key state; empty while no daemon answers (it is replacing itself).
    fn daemon_line(&self) -> (String, String) {
        let o = self.own.x(&["--json", "status"]);
        if !o.status.success() {
            return (String::new(), String::new());
        }
        let v = last_json(&o.stdout);
        (
            v["daemon"].as_str().unwrap_or("").to_string(),
            v["state"].as_str().unwrap_or("").to_string(),
        )
    }
}

impl World {
    /// Ends every process this world started, by PID: the daemons, the installer the daemon starts in its own process
    /// group, and the old daemon that installer starts again, detached, when the daemon it waits for disappears. Ending
    /// a test is such a disappearance: a test that stops as soon as the new version answers leaves the installer
    /// polling, and killing only the daemon made it put the old version back and start it, an orphan outside the
    /// test's children. So installers go first, the nodes' own children are reaped (a zombie still counts as running
    /// for the installer), and the scan repeats until it finds nothing twice in a row.
    fn end(&mut self) {
        let t = Instant::now();
        let mut quiet = 0;
        while quiet < 2 {
            let mut found = procs_under(&self.root);
            if found.is_empty() {
                quiet += 1;
            } else {
                quiet = 0;
                found.sort_by_key(|(_, daemon)| *daemon);
                for (pid, _) in found {
                    kill(pid);
                }
            }
            self.own.kill();
            self.mac.kill();
            if t.elapsed() > Duration::from_secs(30) {
                eprintln!(
                    "processes of {} still running: {:?}",
                    self.root.display(),
                    procs_under(&self.root)
                );
                return;
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    }
}

impl Drop for World {
    /// Also when the test fails: nothing of the world outlives it (see [`World::end`]).
    fn drop(&mut self) {
        self.end();
    }
}

/// Processes whose command line names a path inside `root`, other than this test process: the world's daemons (also
/// the release's `sh` wrappers), its CLI calls and the installer. Each world has its own temporary folder, so parallel
/// tests never match each other's processes. `(pid, is a daemon)`.
fn procs_under(root: &Path) -> Vec<(u32, bool)> {
    let me = std::process::id();
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir("/proc") else {
        return out;
    };
    for e in rd.flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else {
            continue;
        };
        if pid == me {
            continue;
        }
        let cmd = std::fs::read(e.path().join("cmdline")).unwrap_or_default();
        let args: Vec<String> = cmd
            .split(|b| *b == 0)
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        if args.iter().any(|a| Path::new(a).starts_with(root)) {
            let daemon = args.iter().take(2).any(|a| a.ends_with("/antennad"));
            out.push((pid, daemon));
        }
    }
    out
}

fn daemon_pid(data_dir: &Path) -> Option<u32> {
    let want = data_dir.to_str()?;
    for e in std::fs::read_dir("/proc").ok()?.flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else {
            continue;
        };
        let cmd = std::fs::read(e.path().join("cmdline")).unwrap_or_default();
        let args: Vec<String> = cmd
            .split(|b| *b == 0)
            .map(|a| String::from_utf8_lossy(a).into_owned())
            .collect();
        let is_daemon = args.first().is_some_and(|a| a.ends_with("antennad"));
        if is_daemon
            && args
                .windows(2)
                .any(|w| w[0] == "--data-dir" && w[1] == want)
        {
            return Some(pid);
        }
    }
    None
}

fn kill(pid: u32) {
    if let Some(p) = rustix::process::Pid::from_raw(pid as i32) {
        let _ = rustix::process::kill_process(p, rustix::process::Signal::KILL);
    }
}

fn pipes_of(pid: u32) -> usize {
    std::fs::read_dir(format!("/proc/{pid}/fd"))
        .map(|rd| {
            rd.flatten()
                .filter(|e| {
                    std::fs::read_link(e.path())
                        .is_ok_and(|t| t.to_string_lossy().starts_with("pipe:"))
                })
                .count()
        })
        .unwrap_or(0)
}

/// Every file below `dir`.
fn files_below(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_symlink() {
            continue;
        }
        if p.is_dir() {
            files_below(&p, out);
        } else {
            out.push(p);
        }
    }
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn a_release_from_my_own_computer_installs_itself_and_comes_back_unlocked() {
    let w = World::new(5, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    let (b, commit) = built();
    // Off by default: nothing is staged, and the reply says why it can work here.
    let st = w.status();
    assert_eq!(st["enabled"], false, "{st}");
    assert_eq!(st["supported"], true, "{st}");
    let on = w.auto("on");
    assert_eq!(on["enabled"], true, "{on}");
    assert_eq!(on["keys_kept"], true, "{on}");
    let pid = daemon_pid(&w.own.dir).expect("own's daemon");
    let pipes_before = pipes_of(pid);
    let before = [
        ident(&w.bin.join("antenna")),
        ident(&w.bin.join("antennad")),
    ];

    let rel = release(
        &w.root.join("rel-b"),
        &b,
        Daemon::Real,
        Signer::TestKey,
        None,
    );
    let t0 = Instant::now();
    w.deliver(&rel.files);
    // The new version answers on the same PID, unlocked, without anyone entering the password.
    let t = Instant::now();
    let want = format!("antennad {b} ({commit})");
    loop {
        let o = w.own.x(&["--json", "status"]);
        if o.status.success() {
            let v = last_json(&o.stdout);
            if v["daemon"] == want.as_str() {
                assert_eq!(v["state"], "unlocked", "{v}");
                assert_eq!(v["updated"]["from"], "0.0.1", "{v}");
                assert_eq!(v["updated"]["to"], b.as_str(), "{v}");
                assert_eq!(v["updated"]["unlocked"], true, "{v}");
                break;
            }
        }
        assert!(
            t.elapsed() < Duration::from_secs(120),
            "own never came back as {want}: {o:?}"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    println!(
        "RESULT the release from the level-5 contact installed itself in {} ms",
        t0.elapsed().as_millis()
    );
    assert_eq!(
        daemon_pid(&w.own.dir),
        Some(pid),
        "the same PID after the exec"
    );
    assert_ne!(
        ident(&w.bin.join("antennad")),
        before[1],
        "the daemon was replaced"
    );
    assert_eq!(
        ident(&w.bin.join("antennad.previous")),
        before[1],
        "the old one kept as .previous"
    );
    assert_eq!(ident(&w.bin.join("antenna.previous")), before[0]);
    // The link works both ways, with the keys that came over the pipe. Owner sessions do not cross the restart (they
    // are the old process's memory): the owner signs in again, as after any restart.
    w.own.login();
    let t = Instant::now();
    w.mac.send("own", "after the update");
    let got = w.own.inbox_wait(30);
    assert!(
        got.iter().any(|m| m["text"] == "after the update"),
        "{got:?}"
    );
    let one = t.elapsed().as_millis();
    w.own.send("mac", "back on the new version");
    let got = w.mac.inbox_wait(30);
    assert!(
        got.iter().any(|m| m["text"] == "back on the new version"),
        "{got:?}"
    );
    println!(
        "RESULT after the update: contact → node {one} ms, node → contact {} ms",
        t.elapsed().as_millis() - one
    );
    // The record: installed, from the contact, with the keys kept; the link's audit log has it too.
    let st = w.status();
    assert_eq!(st["last"]["result"], "installed", "{st}");
    assert_eq!(st["last"]["unlocked"], true, "{st}");
    assert_eq!(st["last"]["contact"], "mac", "{st}");
    assert!(st["staged"].is_null(), "{st}");
    let log = w.own.json(&["log", "mac"]).to_string();
    assert!(
        log.contains("update_install") && log.contains("installed"),
        "{log}"
    );
    // No descriptor came along (the handover pipe is closed; the installer's pipes went with the old image).
    let pipes_after = pipes_of(pid);
    assert!(
        pipes_after <= pipes_before,
        "pipes before {pipes_before}, after {pipes_after}"
    );
    let cmd = String::from_utf8_lossy(&std::fs::read(format!("/proc/{pid}/cmdline")).unwrap())
        .replace('\0', " ");
    let fd: i32 = cmd
        .split("--handover-fd ")
        .nth(1)
        .and_then(|r| r.split_whitespace().next())
        .and_then(|n| n.parse().ok())
        .expect("the new daemon was started with --handover-fd");
    assert!(
        !std::fs::read_link(format!("/proc/{pid}/fd/{fd}"))
            .is_ok_and(|t| t.to_string_lossy().starts_with("pipe:")),
        "the handover pipe (fd {fd}) is closed"
    );
    // The key is nowhere on disk: not in the data folder, the link folders, the install folder (the staging folder is
    // gone), the update log or the daemon's log; not in its environment or arguments either.
    let root_key = antenna_core::keystore::unlock(&w.own.dir, w.own.password.as_bytes())
        .unwrap()
        .handover_bytes();
    let hex = data_encoding::HEXLOWER.encode(&root_key[..]);
    let b64 = data_encoding::BASE64.encode(&root_key[..]);
    let mut all = Vec::new();
    for d in [&w.own.dir, &w.own.links(), &w.bin, &w.home] {
        files_below(d, &mut all);
    }
    all.push(w.own.dir.with_extension("log"));
    assert!(
        !w.bin.join(".antenna-update").exists(),
        "the staging folder is removed"
    );
    let mut checked = 0;
    for f in &all {
        // The installed programs themselves (hundreds of MB in a debug build) were built before the key existed.
        if f.parent() == Some(w.bin.as_path())
            && std::fs::metadata(f).is_ok_and(|m| m.len() > 32 << 20)
        {
            continue;
        }
        let data = std::fs::read(f).unwrap_or_default();
        checked += 1;
        assert!(
            !contains(&data, &root_key[..])
                && !contains(&data, hex.as_bytes())
                && !contains(&data, b64.as_bytes()),
            "the root key is in {}",
            f.display()
        );
    }
    for p in ["environ", "cmdline"] {
        let data = std::fs::read(format!("/proc/{pid}/{p}")).unwrap_or_default();
        assert!(
            !contains(&data, &root_key[..]) && !contains(&data, hex.as_bytes()),
            "{p}"
        );
    }
    println!(
        "RESULT the key is in none of {checked} files under the data, link, install and home folders"
    );
    // Re-sent, identical release files are recognised: nothing staged again, nothing recorded.
    w.deliver(&rel.files[2..]);
    std::thread::sleep(Duration::from_secs(3));
    let again = w.status();
    assert!(again["staged"].is_null(), "{again}");
    assert_eq!(
        again["history"].as_array().unwrap().len(),
        st["history"].as_array().unwrap().len(),
        "{again}"
    );
}

#[test]
fn what_is_not_a_newer_signed_release_for_this_computer_is_refused_and_changes_nothing() {
    let w = World::new(5, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    w.auto("on");
    let before = [
        ident(&w.bin.join("antenna")),
        ident(&w.bin.join("antennad")),
    ];
    let other_arch = if Platform::this("cli").arch == "x86_64" {
        "arm64"
    } else {
        "x86_64"
    };
    let cases = [
        ("older", "0.0.0", Signer::TestKey, None, Some("not_newer")),
        ("same", "0.0.1", Signer::TestKey, None, None),
        (
            "other platform",
            "0.0.2",
            Signer::TestKey,
            Some(other_arch),
            Some("wrong_platform"),
        ),
        (
            "unsigned",
            "0.0.3",
            Signer::Unknown,
            None,
            Some("bad_signature"),
        ),
    ];
    for (what, v, signer, arch, refusal) in cases {
        let rel = release(
            &w.root.join(format!("rel-{v}")),
            v,
            Daemon::Exits,
            signer,
            arch,
        );
        w.deliver(&rel.files);
        w.wait_accepted(&manifest::manifest_name(v));
        match refusal {
            Some(code) => {
                let st = w.wait_status(what, 30, |s| {
                    s["history"].as_array().is_some_and(|h| {
                        h.iter()
                            .any(|r| r["version"] == v && r["result"] == "refused")
                    })
                });
                let r = st["history"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|r| r["version"] == v)
                    .unwrap()
                    .clone();
                assert!(
                    r["reason"].as_str().unwrap().starts_with(code),
                    "{what}: {r}"
                );
            }
            None => {
                std::thread::sleep(Duration::from_secs(3));
                let st = w.status();
                assert!(
                    !st["history"].to_string().contains(&format!("\"{v}\"")),
                    "{what}: the same version is ignored without a record: {st}"
                );
            }
        }
        let st = w.status();
        assert!(st["staged"].is_null(), "{what}: nothing staged: {st}");
        assert_eq!(
            [
                ident(&w.bin.join("antenna")),
                ident(&w.bin.join("antennad"))
            ],
            before,
            "{what}"
        );
    }
    let log = w.own.json(&["log", "mac"]).to_string();
    assert!(
        log.contains("update_install") && log.contains("refused"),
        "{log}"
    );
    assert_eq!(w.daemon_line().1, "unlocked");
}

#[test]
fn a_test_key_release_is_refused_where_the_test_key_is_not_trusted() {
    // No ANTENNA_UPDATE_TEST_KEY: what a release build always does.
    let w = World::new(5, &[]);
    w.auto("on");
    let rel = release(
        &w.root.join("rel"),
        "0.0.2",
        Daemon::Exits,
        Signer::TestKey,
        None,
    );
    w.deliver(&rel.files);
    let st = w.wait_status("the refusal", 60, |s| s["last"]["result"] == "refused");
    let reason = st["last"]["reason"].as_str().unwrap();
    assert!(
        reason.starts_with("bad_signature") || reason.starts_with("no_release_key"),
        "{st}"
    );
    assert!(st["staged"].is_null());
}

#[test]
fn files_from_level_4_and_a_setting_that_is_off_start_nothing() {
    // Level 4: the files wait for the owner; the owner accepting them starts nothing either.
    let w = World::new(4, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    w.auto("on");
    let rel = release(
        &w.root.join("rel"),
        "0.0.2",
        Daemon::Exits,
        Signer::TestKey,
        None,
    );
    w.deliver(&rel.files);
    let t = Instant::now();
    let mut ids = Vec::new();
    while ids.len() < 3 {
        assert!(
            t.elapsed() < Duration::from_secs(90),
            "the files never arrived: {ids:?}"
        );
        ids = w.own.json(&["files", "pending"])["files"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|f| f["state"] == "checked")
            .map(|f| f["id"].as_str().unwrap().to_string())
            .collect();
        std::thread::sleep(Duration::from_millis(300));
    }
    for id in &ids {
        let o = w.own.x(&["--json", "files", "accept", id]);
        assert!(o.status.success(), "{o:?}");
    }
    std::thread::sleep(Duration::from_secs(3));
    let st = w.status();
    assert!(
        st["staged"].is_null() && st["history"].is_null(),
        "level 4 starts nothing: {st}"
    );

    // Level 5 with the setting off: the files are accepted, nothing is staged or recorded.
    let w = World::new(5, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    let rel = release(
        &w.root.join("rel"),
        "0.0.2",
        Daemon::Exits,
        Signer::TestKey,
        None,
    );
    w.deliver(&rel.files);
    w.wait_accepted(&rel.asset_name);
    w.wait_accepted(&manifest::manifest_name("0.0.2"));
    std::thread::sleep(Duration::from_secs(3));
    let st = w.status();
    assert!(
        st["staged"].is_null() && st["history"].is_null(),
        "setting off: {st}"
    );
}

#[test]
fn a_busy_agent_delays_it_a_failing_version_comes_back_locked_and_is_not_retried() {
    let w = World::new(5, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    w.auto("on");
    let tok = w.own.agent_add("claude", &["--local-level", "0"]);
    let busy = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let agent = {
        let (busy, cmd) = (busy.clone(), w.own.agent_cmd(&tok));
        let prog = cmd.get_program().to_os_string();
        let args: Vec<_> = cmd.get_args().map(|a| a.to_os_string()).collect();
        let envs: Vec<_> = cmd
            .get_envs()
            .map(|(k, v)| (k.to_os_string(), v.map(|v| v.to_os_string())))
            .collect();
        std::thread::spawn(move || {
            while busy.load(std::sync::atomic::Ordering::SeqCst) {
                let mut c = Command::new(&prog);
                c.args(&args).arg("status");
                for (k, v) in &envs {
                    match v {
                        Some(v) => c.env(k, v),
                        None => c.env_remove(k),
                    };
                }
                let _ = c.output();
                std::thread::sleep(Duration::from_millis(300));
            }
        })
    };
    let before = ident(&w.bin.join("antennad"));
    let rel = release(
        &w.root.join("rel"),
        "0.0.2",
        Daemon::Exits,
        Signer::TestKey,
        None,
    );
    w.deliver(&rel.files);
    w.wait_status("staged", 90, |s| s["staged"]["version"] == "0.0.2");
    // The agent keeps calling: for well over the (shortened) idle time, nothing is installed.
    std::thread::sleep(Duration::from_secs(5));
    let st = w.status();
    assert_eq!(st["staged"]["state"], "waiting", "{st}");
    assert_eq!(
        ident(&w.bin.join("antennad")),
        before,
        "not installed while the agent works"
    );
    busy.store(false, std::sync::atomic::Ordering::SeqCst);
    agent.join().unwrap();
    let pid = daemon_pid(&w.own.dir).unwrap();
    // Idle now: it installs; the new binary exits, the old one is put back and started again, locked.
    let t = Instant::now();
    loop {
        if let Some(p) = daemon_pid(&w.own.dir)
            && p != pid
        {
            let (line, state) = w.daemon_line();
            if line.contains("0.0.1") {
                assert_eq!(state, "locked", "the old version comes back locked");
                break;
            }
        }
        assert!(
            t.elapsed() < Duration::from_secs(90),
            "the old version never came back"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    assert_eq!(
        ident(&w.bin.join("antennad")),
        before,
        "the old binary is back in place"
    );
    let respawned = daemon_pid(&w.own.dir).unwrap();
    w.own.unlock();
    let st = w.status();
    assert_eq!(st["last"]["result"], "failed", "{st}");
    assert_eq!(st["failed"][0], "0.0.2", "{st}");
    // Sent again: it is not tried again by itself.
    w.deliver(&rel.files[2..]);
    std::thread::sleep(Duration::from_secs(4));
    let st = w.status();
    assert!(
        st["staged"].is_null(),
        "a failed version is not retried: {st}"
    );
    assert_eq!(ident(&w.bin.join("antennad")), before);
    kill(respawned);
}

#[test]
fn without_the_handover_pipe_the_new_version_comes_up_locked() {
    let w = World::new(
        5,
        &[
            ("ANTENNA_UPDATE_TEST_KEY", "1"),
            ("ANTENNA_HANDOVER_TEST_DROP_KEY", "1"),
        ],
    );
    w.auto("on");
    let (b, commit) = built();
    let rel = release(
        &w.root.join("rel-b"),
        &b,
        Daemon::Real,
        Signer::TestKey,
        None,
    );
    w.deliver(&rel.files);
    let want = format!("antennad {b} ({commit})");
    let t = Instant::now();
    loop {
        let (line, state) = w.daemon_line();
        if line == want {
            assert_eq!(
                state, "locked",
                "no pipe, no keys: locked as after any restart"
            );
            break;
        }
        assert!(
            t.elapsed() < Duration::from_secs(120),
            "never came back as {want}"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    w.own.unlock();
    let st = w.status();
    assert_eq!(st["last"]["result"], "installed", "{st}");
    assert_eq!(st["last"]["unlocked"], false, "{st}");
}

/// A test that ends in the middle of an install leaves nothing running: the installer is still waiting for the new
/// version when the world is ended, and nothing of it, no old version started again included, outlives the world. The
/// temporary folder is kept for the check, so a restarted daemon would have its files (as it had when it leaked).
#[test]
fn a_test_that_ends_during_an_install_leaves_no_process_behind() {
    let mut w = World::new(5, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    w.auto("on");
    let (b, _) = built();
    let rel = release(
        &w.root.join("rel-b"),
        &b,
        Daemon::Real,
        Signer::TestKey,
        None,
    );
    w.deliver(&rel.files);
    let installer = |w: &World| {
        procs_under(&w.root).into_iter().any(|(pid, _)| {
            std::fs::read(format!("/proc/{pid}/cmdline"))
                .is_ok_and(|c| c.split(|b| *b == 0).any(|a| a == b"--handover"))
        })
    };
    let t = Instant::now();
    while !installer(&w) {
        assert!(
            t.elapsed() < Duration::from_secs(90),
            "the install never started"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    w.end();
    // Longer than the installer needs to notice the daemon is gone, put the old files back and start it again.
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(8) {
        let left = procs_under(&w.root);
        assert!(left.is_empty(), "processes outlived the world: {left:?}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// The setting is the owner's at the computer: the password both ways (a wrong one changes nothing), and only where
/// the installation can replace itself (a development build cannot).
#[test]
fn the_setting_takes_the_password_both_ways() {
    let w = World::new(5, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    let set = |action: &str, pw: &str| {
        w.own.x_stdin(
            &["--json", "update", "--auto", action, "--password-stdin"],
            &format!("{pw}\n"),
        )
    };
    let o = set("on", "wrong-password");
    assert!(!o.status.success());
    assert_eq!(last_json(&o.stdout)["error"], "wrong_password", "{o:?}");
    assert_eq!(w.status()["enabled"], false);
    let on = w.auto("on");
    assert_eq!(
        (on["enabled"].clone(), on["keys_kept"].clone()),
        (true.into(), true.into()),
        "{on}"
    );
    let o = set("off", "wrong-password");
    assert_eq!(last_json(&o.stdout)["error"], "wrong_password", "{o:?}");
    assert_eq!(
        w.status()["enabled"],
        true,
        "a wrong password does not turn it off"
    );
    // Without a terminal and without --password-stdin there is no password to send: refused before the daemon.
    let o = w.own.x(&["--json", "update", "--auto", "off"]);
    assert!(!o.status.success(), "{o:?}");
    let off = w.auto("off");
    assert_eq!(
        (off["enabled"].clone(), off["keys_kept"].clone()),
        (false.into(), false.into()),
        "{off}"
    );

    // A daemon started from the build folder is a development build: it cannot replace itself.
    let mut dev = Node::new(&w.root, "dev", Net::Local);
    dev.start();
    dev.init();
    let st = dev.json(&["update", "--auto", "status"]);
    assert_eq!(st["supported"], false, "{st}");
    assert!(
        st["unsupported_reason"]
            .as_str()
            .unwrap()
            .contains("development build"),
        "{st}"
    );
    let o = dev.x_stdin(
        &["--json", "update", "--auto", "on", "--password-stdin"],
        &format!("{}\n", dev.password),
    );
    assert_eq!(
        last_json(&o.stdout)["error"],
        "unsupported_install",
        "{o:?}"
    );
}

/// A self-signed HTTPS server on 127.0.0.1 serving `dir`, trusted by curl through `CURL_CA_BUNDLE` (the daemon's
/// daily check runs curl, HTTPS only).
struct Https {
    child: std::process::Child,
    port: u16,
    ca: PathBuf,
}

impl Https {
    fn start(dir: &Path, work: &Path) -> Self {
        std::fs::create_dir_all(work).unwrap();
        let (key, ca) = (work.join("key.pem"), work.join("cert.pem"));
        let st = Command::new("openssl")
            .args([
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=127.0.0.1",
            ])
            .args(["-addext", "subjectAltName=IP:127.0.0.1", "-keyout"])
            .arg(&key)
            .arg("-out")
            .arg(&ca)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(st.success(), "openssl");
        let server = r#"
import http.server, ssl, sys, functools
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
s = http.server.HTTPServer(("127.0.0.1", 0), h)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain(sys.argv[2], sys.argv[3])
s.socket = c.wrap_socket(s.socket, server_side=True)
print(s.server_address[1], flush=True)
s.serve_forever()
"#;
        let mut child = Command::new("python3")
            .arg("-c")
            .arg(server)
            .arg(dir)
            .arg(&ca)
            .arg(&key)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufRead::read_line(
            &mut std::io::BufReader::new(child.stdout.take().unwrap()),
            &mut line,
        )
        .unwrap();
        Self {
            port: line.trim().parse().unwrap(),
            child,
            ca,
        }
    }
}

impl Drop for Https {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The daily check of the update URL: a newer signed release there is fetched, verified, staged and installed by
/// itself (no contact involved); the record says it came from the URL.
#[test]
fn the_update_url_is_checked_and_a_newer_release_installs_itself() {
    let (b, commit) = built();
    let tmp = tempfile::tempdir().unwrap();
    let rel = release(
        &tmp.path().join("rel-b"),
        &b,
        Daemon::Real,
        Signer::TestKey,
        None,
    );
    let served = rel.files[0].parent().unwrap().to_path_buf();
    let https = Https::start(&served, &tmp.path().join("tls"));
    let url = format!(
        "https://127.0.0.1:{}/{}",
        https.port,
        manifest::manifest_name(&b)
    );
    let w = World::new(
        3,
        &[
            ("ANTENNA_UPDATE_TEST_KEY", "1"),
            ("ANTENNA_UPDATE_URL", &url),
            ("CURL_CA_BUNDLE", https.ca.to_str().unwrap()),
        ],
    );
    let on = w.auto("on");
    assert_eq!(on["url"], url.as_str(), "{on}");
    let want = format!("antennad {b} ({commit})");
    let t = Instant::now();
    loop {
        let (line, state) = w.daemon_line();
        if line == want {
            assert_eq!(state, "unlocked");
            break;
        }
        assert!(
            t.elapsed() < Duration::from_secs(120),
            "never came back as {want}"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    w.own.login();
    let st = w.status();
    assert_eq!(st["last"]["result"], "installed", "{st}");
    assert_eq!(st["last"]["source"], "url", "{st}");
    assert!(st["last_check_ms"].as_u64().is_some(), "{st}");
}

/// The owner at the window is told first: with a window's session held, a staged release is `soon`; "Later" postpones
/// it (nothing installs), "Install now" starts it at once.
#[test]
fn the_window_is_told_first_and_can_postpone_or_install_now() {
    let w = World::new(5, &[("ANTENNA_UPDATE_TEST_KEY", "1")]);
    w.auto("on");
    let held = w.own.held_session();
    let (b, commit) = built();
    let rel = release(
        &w.root.join("rel-b"),
        &b,
        Daemon::Real,
        Signer::TestKey,
        None,
    );
    let before = ident(&w.bin.join("antennad"));
    w.deliver(&rel.files);
    let st = w.wait_status("soon", 90, |s| s["staged"]["state"] == "soon");
    assert!(st["staged"]["at_ms"].as_u64().is_some(), "{st}");
    let later = w.own.json(&["update", "--auto", "later"]);
    assert_eq!(later["staged"]["state"], "waiting", "{later}");
    let at = later["staged"]["at_ms"].as_u64().unwrap();
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    assert!(
        at > now_ms + 50 * 60 * 1000,
        "postponed by about an hour: {later}"
    );
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(
        ident(&w.bin.join("antennad")),
        before,
        "nothing installed after Later"
    );
    w.own.json(&["update", "--auto", "now"]);
    let want = format!("antennad {b} ({commit})");
    let t = Instant::now();
    while w.daemon_line().0 != want {
        assert!(
            t.elapsed() < Duration::from_secs(120),
            "Install now did not install"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    drop(held);
}

/// With the setting off (D-137) the daily check still runs: a newer signed release on the update URL is fetched,
/// verified and staged, and nothing installs by itself. "Install now" needs the password (none, or a wrong one,
/// changes nothing); with it the new version comes up unlocked, and the setting stays off. A development build never
/// checks at all.
#[test]
fn with_the_setting_off_the_daily_check_stages_and_install_now_takes_the_password() {
    let (b, commit) = built();
    let tmp = tempfile::tempdir().unwrap();
    let rel = release(
        &tmp.path().join("rel-b"),
        &b,
        Daemon::Real,
        Signer::TestKey,
        None,
    );
    let served = rel.files[0].parent().unwrap().to_path_buf();
    let https = Https::start(&served, &tmp.path().join("tls"));
    let url = format!(
        "https://127.0.0.1:{}/{}",
        https.port,
        manifest::manifest_name(&b)
    );
    let ca = https.ca.to_str().unwrap().to_string();
    let w = World::new(
        3,
        &[
            ("ANTENNA_UPDATE_TEST_KEY", "1"),
            ("ANTENNA_UPDATE_URL", &url),
            ("CURL_CA_BUNDLE", &ca),
        ],
    );
    let before = ident(&w.bin.join("antennad"));
    let st = w.wait_status("a release staged with the setting off", 90, |s| {
        s["staged"]["version"] == b.as_str()
    });
    assert_eq!(
        (st["enabled"].clone(), st["keys_kept"].clone()),
        (false.into(), false.into()),
        "{st}"
    );
    assert_eq!(st["staged"]["source"], "url", "{st}");
    assert_eq!(st["url"], url.as_str(), "{st}");
    // However idle the agents are (1.5 s here), nothing installs by itself.
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(
        ident(&w.bin.join("antennad")),
        before,
        "installed with the setting off"
    );

    // Install now: without the password (no terminal here), then with a wrong one: refused, nothing changes.
    let o = w.own.x(&["--json", "update", "--auto", "now"]);
    assert!(!o.status.success(), "{o:?}");
    assert_eq!(last_json(&o.stdout)["error"], "password_required", "{o:?}");
    let o = w.own.x_stdin(
        &["--json", "update", "--auto", "now", "--password-stdin"],
        "wrong-password\n",
    );
    assert_eq!(last_json(&o.stdout)["error"], "wrong_password", "{o:?}");
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(ident(&w.bin.join("antennad")), before);
    assert_eq!(w.status()["keys_kept"], false);

    // With the password: installed, and the key went over the handover pipe for this one restart.
    let o = w.own.x_stdin(
        &["--json", "update", "--auto", "now", "--password-stdin"],
        &format!("{}\n", w.own.password),
    );
    assert!(o.status.success(), "{o:?}");
    let want = format!("antennad {b} ({commit})");
    let t = Instant::now();
    loop {
        let (line, state) = w.daemon_line();
        if line == want {
            assert_eq!(state, "unlocked", "the new version must come up unlocked");
            break;
        }
        assert!(
            t.elapsed() < Duration::from_secs(120),
            "Install now did not install"
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    w.own.login();
    let st = w.status();
    assert_eq!(st["last"]["result"], "installed", "{st}");
    assert_eq!(st["last"]["source"], "url", "{st}");
    assert_eq!(
        (st["enabled"].clone(), st["keys_kept"].clone()),
        (false.into(), false.into()),
        "Install now neither turns the setting on nor keeps the key afterwards: {st}"
    );

    // A development build (started from the build folder) cannot replace itself, so it never downloads a release.
    let mut dev = Node::new(&w.root, "dev", Net::Local);
    dev.extra_env = vec![
        ("ANTENNA_UPDATE_TEST_KEY".into(), "1".into()),
        ("ANTENNA_UPDATE_URL".into(), url.clone()),
        ("CURL_CA_BUNDLE".into(), ca.clone()),
    ];
    dev.extra_args = ["--update-tick-ms", "200"].map(String::from).to_vec();
    dev.start();
    dev.init();
    std::thread::sleep(Duration::from_secs(4));
    let st = dev.json(&["update", "--auto", "status"]);
    assert_eq!(st["supported"], false, "{st}");
    assert!(
        st["last_check_ms"].is_null(),
        "a development build checked: {st}"
    );
    assert!(st["staged"].is_null(), "{st}");
}
