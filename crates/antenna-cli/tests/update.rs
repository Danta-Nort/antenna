// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna update` end to end on this machine (D-82): two versions of the `install.sh` layout signed with the public
//! test key, a real daemon, the owner password checked by it.
//!
//! - version A is the built `antenna`/`antennad` hard-linked into a temporary `bin/`, told to call itself `0.0.1`
//!   (`ANTENNA_UPDATE_CURRENT_VERSION`, debug builds only);
//! - version B is a `.tar.gz` like the release one, with a copy of `antenna` and an `antennad` that runs the built
//!   daemon, listed in a test-signed manifest;
//!
//! then: refusals that change nothing (agent token, test key not trusted, same version, wrong password, a tampered
//! archive), a dry run, the install (the old files kept as `.previous`), the daemon restarted from the new files,
//! a rollback, and two interruptions in the middle (an error, and a process that dies) that leave A in place.
//!
//! Run: `cargo test -p antenna-cli --test update -- --nocapture` (from the workspace root, so that `antennad` is built).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};

use antenna_update::{
    keys::test_signing_key,
    manifest::{self, Platform},
    sig, signing,
};
use common::*;
use serde_json::Value;

fn ident(p: &Path) -> (u64, u64) {
    let m = std::fs::symlink_metadata(p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    (m.dev(), m.ino())
}

fn link_or_copy(from: &Path, to: &Path) {
    if std::fs::hard_link(from, to).is_err() {
        std::fs::copy(from, to).unwrap();
    }
}

/// Version and commit of the built binaries.
fn built() -> (String, String) {
    let o = Command::new(x_bin())
        .clean_env()
        .arg("--version")
        .output()
        .unwrap();
    let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
    let (_, rest) = s.split_once(' ').unwrap();
    let (v, c) = rest.split_once(" (").unwrap();
    let d = Command::new(xd_bin())
        .clean_env()
        .arg("--version")
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8_lossy(&d.stdout).trim(),
        format!("antennad {rest}"),
        "antennad and antenna were built from different commits: cargo build -p antennad (TROUBLESHOOTING N.7)"
    );
    (v.to_string(), c.trim_end_matches(')').to_string())
}

/// The release file name of the CLI archive for this OS and architecture.
fn cli_asset_name(version: &str) -> (String, String) {
    let p = Platform::this("cli");
    let top = if p.os == "macos" {
        format!("antenna-{version}-macos-{}-cli", p.arch)
    } else {
        format!("antenna-{version}-linux-{}", p.arch)
    };
    (format!("{top}.tar.gz"), top)
}

/// Version B: the archive and a manifest signed with the test key, in `dir`.
fn release_b(root: &Path, dir: &Path) -> PathBuf {
    let (version, commit) = built();
    let (name, top) = cli_asset_name(&version);
    let src = root.join("b-src");
    let bin = src.join(&top).join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::copy(x_bin(), bin.join("antenna")).unwrap();
    // The daemon of B runs the built daemon (its --version is the same); 277 MB less to pack.
    std::fs::write(
        bin.join("antennad"),
        format!("#!/bin/sh\nexec '{}' \"$@\"\n", xd_bin().display()),
    )
    .unwrap();
    std::fs::set_permissions(bin.join("antennad"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::create_dir_all(dir).unwrap();
    let st = Command::new("tar")
        .arg("-czf")
        .arg(dir.join(&name))
        .arg("-C")
        .arg(&src)
        .arg(&top)
        .status()
        .unwrap();
    assert!(st.success());
    let m = signing::build_manifest(
        &version,
        "preview",
        &commit,
        "2026-10-03T12:00:00Z",
        &[dir.join(&name)],
    )
    .unwrap();
    let bytes = m.to_bytes();
    let mp = dir.join(manifest::manifest_name(&version));
    std::fs::write(&mp, &bytes).unwrap();
    let s = sig::SignatureFile::new(sig::sign(&bytes, &test_signing_key()));
    std::fs::write(dir.join(manifest::signature_name(&version)), s.to_bytes()).unwrap();
    mp
}

struct Setup {
    _root: tempfile::TempDir,
    root: PathBuf,
    home: PathBuf,
    bin: PathBuf,
    rel: PathBuf,
    node: Node,
    a: [(u64, u64); 2],
}

impl Setup {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let r = root.path().to_path_buf();
        let home = r.join("home");
        let bin = r.join("prefix/bin");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        link_or_copy(&x_bin(), &bin.join("antenna"));
        link_or_copy(&xd_bin(), &bin.join("antennad"));
        let rel = r.join("release");
        release_b(&r, &rel);
        let mut node = Node::new(&r, "n", Net::Local);
        node.bin_dir = Some(bin.clone());
        node.start();
        node.init();
        let a = [ident(&bin.join("antenna")), ident(&bin.join("antennad"))];
        Self {
            _root: root,
            root: r,
            home,
            bin,
            rel,
            node,
            a,
        }
    }

    /// `<prefix>/bin/antenna --data-dir … update <args>` as the owner, `$HOME` in the test folder.
    fn update(&self, args: &[&str], env: &[(&str, &str)], stdin: Option<&str>) -> Output {
        let mut c = Command::new(self.bin.join("antenna"));
        c.clean_env()
            .arg("--data-dir")
            .arg(&self.node.dir)
            .arg("update")
            .args(args);
        c.env("HOME", &self.home);
        for k in [
            "XDG_STATE_HOME",
            "XDG_CONFIG_HOME",
            "ANTENNA_UPDATE_TEST_KEY",
            "ANTENNA_UPDATE_CURRENT_VERSION",
            "ANTENNA_UPDATE_FAIL_AT",
            "ANTENNA_UPDATE_URL",
            "ANTENNA_AGENT_TOKEN",
        ] {
            c.env_remove(k);
        }
        for (k, v) in env {
            c.env(k, v);
        }
        c.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut ch = c.spawn().unwrap();
        {
            use std::io::Write;
            let mut i = ch.stdin.take().unwrap();
            if let Some(s) = stdin {
                let _ = i.write_all(s.as_bytes());
            }
        }
        ch.wait_with_output().unwrap()
    }

    fn pw(&self) -> String {
        format!("{}\n", self.node.password)
    }

    fn now(&self) -> [(u64, u64); 2] {
        [
            ident(&self.bin.join("antenna")),
            ident(&self.bin.join("antennad")),
        ]
    }
}

/// Test key trusted, version A pretends to be 0.0.1.
const AS_A: &[(&str, &str)] = &[
    ("ANTENNA_UPDATE_TEST_KEY", "1"),
    ("ANTENNA_UPDATE_CURRENT_VERSION", "0.0.1"),
];

fn code_of(o: &Output) -> String {
    let v: Value = last_json(&o.stdout);
    v["error"].as_str().unwrap_or("").to_string()
}

#[test]
fn install_restart_rollback_and_interruptions() {
    let s = Setup::new();
    let from = s.rel.to_str().unwrap();

    // The agent has no `update` at all.
    let mut c = Command::new(s.bin.join("antenna"));
    c.clean_env()
        .args(["update", "--from", from])
        .env("ANTENNA_AGENT_TOKEN", "xat_whatever");
    let o = c.output().unwrap();
    assert_eq!(o.status.code(), Some(2), "{o:?}");
    assert!(
        String::from_utf8_lossy(&o.stderr).contains("no such command"),
        "{o:?}"
    );

    // Without the test key the release is not trusted (this build pins no key, or another one).
    let o = s.update(&["--from", from, "--dry-run", "--json"], &[], None);
    assert!(!o.status.success());
    assert!(
        ["no_release_key", "bad_signature"].contains(&code_of(&o).as_str()),
        "{o:?}"
    );
    // The same version is not an update.
    let o = s.update(
        &["--from", from, "--dry-run", "--json"],
        &[("ANTENNA_UPDATE_TEST_KEY", "1")],
        None,
    );
    assert_eq!(code_of(&o), "not_newer", "{o:?}");
    // A wrong password changes nothing.
    let o = s.update(
        &["--from", from, "--yes", "--password-stdin", "--json"],
        AS_A,
        Some("wrong-password\n"),
    );
    assert_eq!(code_of(&o), "wrong_password", "{o:?}");
    assert_eq!(s.now(), s.a);
    // A tampered archive is refused.
    let bad = s.root.join("tampered");
    std::fs::create_dir_all(&bad).unwrap();
    for e in std::fs::read_dir(&s.rel).unwrap().flatten() {
        std::fs::copy(e.path(), bad.join(e.file_name())).unwrap();
    }
    let (name, _) = cli_asset_name(&built().0);
    let mut t = std::fs::read(bad.join(&name)).unwrap();
    let n = t.len();
    t[n / 2] ^= 1;
    std::fs::write(bad.join(&name), t).unwrap();
    let o = s.update(
        &["--from", bad.to_str().unwrap(), "--dry-run", "--json"],
        AS_A,
        None,
    );
    assert_eq!(code_of(&o), "hash_mismatch", "{o:?}");

    // A dry run: verified, the plan, nothing changed.
    let o = s.update(&["--from", from, "--dry-run", "--json"], AS_A, None);
    assert!(o.status.success(), "{o:?}");
    let v = last_json(&o.stdout);
    assert_eq!(v["action"], "verify");
    assert_eq!(v["signature"]["valid"], true);
    assert_eq!(v["signature"]["test_key"], true);
    assert_eq!(v["newer"], true);
    assert_eq!(v["install"]["kind"], "bin_dir");
    assert_eq!(v["asset"]["name"], name.as_str());
    assert!(
        v["steps"].to_string().contains("restart it yourself"),
        "{v}"
    );
    assert_eq!(s.now(), s.a);

    // Interrupted by an error after the daemon was swapped: the old version is put back at once.
    let o = s.update(
        &["--from", from, "--yes", "--password-stdin", "--json"],
        &[AS_A[0], AS_A[1], ("ANTENNA_UPDATE_FAIL_AT", "swap1")],
        Some(&s.pw()),
    );
    assert_eq!(code_of(&o), "install_failed", "{o:?}");
    assert!(
        last_json(&o.stdout)["message"]
            .as_str()
            .unwrap()
            .contains("was restored"),
        "{o:?}"
    );
    assert_eq!(s.now(), s.a);
    // Interrupted by a crash at the same point: the next `antenna update` undoes it.
    let o = s.update(
        &["--from", from, "--yes", "--password-stdin", "--json"],
        &[AS_A[0], AS_A[1], ("ANTENNA_UPDATE_FAIL_AT", "swap1:abort")],
        Some(&s.pw()),
    );
    assert_eq!(o.status.code(), Some(99), "{o:?}");
    assert_ne!(
        ident(&s.bin.join("antennad")),
        s.a[1],
        "the crash left the new daemon in place"
    );
    let o = s.update(&["--json"], &[], None);
    assert!(o.status.success(), "{o:?}");
    assert!(
        last_json(&o.stdout)["recovered"]
            .as_str()
            .unwrap()
            .contains("undone"),
        "{o:?}"
    );
    assert_eq!(s.now(), s.a);
    assert!(!s.bin.join(".antenna-update/journal.json").exists());

    // The install.
    let o = s.update(
        &["--from", from, "--yes", "--password-stdin", "--json"],
        AS_A,
        Some(&s.pw()),
    );
    assert!(o.status.success(), "{o:?}");
    let v = last_json(&o.stdout);
    assert_eq!(v["action"], "install");
    assert_eq!(v["daemon"]["how"], "manual");
    assert!(
        v["daemon"]["note"]
            .as_str()
            .unwrap()
            .contains("started by hand")
    );
    assert_eq!(v["keys_locked"], false);
    assert_ne!(s.now()[0], s.a[0]);
    assert_eq!(ident(&s.bin.join("antenna.previous")), s.a[0]);
    assert_eq!(ident(&s.bin.join("antennad.previous")), s.a[1]);
    // The log lives where this OS keeps it (macOS: `~/Library/Logs/Antenna`; Linux: the XDG state directory).
    let log_path = antenna_update::install::default_log_path(&s.home, std::env::consts::OS, None);
    let log = std::fs::read_to_string(&log_path)
        .unwrap_or_else(|e| panic!("{}: {e}", log_path.display()));
    assert!(log.contains("installed ") && log.contains("done:"), "{log}");

    // The daemon from the new files.
    let mut node = s.node;
    node.stop();
    node.start();
    node.unlock();
    assert_eq!(node.json(&["status"])["state"], "unlocked");
    let s = Setup { node, ..s };

    // The status shows the previous version; the rollback (by version B, which is the installed CLI now) puts A back.
    let o = s.update(&["--json"], &[], None);
    assert!(!last_json(&o.stdout)["previous"].is_null(), "{o:?}");
    let o = s.update(
        &["--rollback", "--yes", "--password-stdin", "--json"],
        &[],
        Some(&s.pw()),
    );
    assert!(o.status.success(), "{o:?}");
    assert_eq!(last_json(&o.stdout)["action"], "rollback");
    assert_eq!(s.now(), s.a);
    assert_ne!(
        ident(&s.bin.join("antenna.previous")),
        s.a[0],
        "the newer one is kept as .previous"
    );
}
