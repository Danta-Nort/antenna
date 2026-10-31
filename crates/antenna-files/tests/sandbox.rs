// SPDX-License-Identifier: AGPL-3.0-only
//! The worker sandbox (SPEC §10 step 3 "a separate process without network and without access to keys", §13): probes
//! from inside the isolated process, refusal without isolation, timeout, memory limit, external antivirus. Linux:
//! Landlock + seccomp; macOS: Seatbelt (D-P-12); expectations that differ (a seccomp kill versus an `EPERM` refusal)
//! are per OS.

// The file check needs the worker sandbox: Linux, Landlock + seccomp; macOS, Seatbelt (D-P-12). On other OSes the check
// fails closed (verdict failed), and there is nothing for these tests to run.
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use antenna_files::report::Verdict;
use antenna_files::sandbox::{AvHook, Checker, CheckerConfig};

/// System directories for the external "antivirus" in the tests (on macOS the system paths are already in the Seatbelt
/// profile).
fn av_ro_paths() -> Vec<std::path::PathBuf> {
    if cfg!(target_os = "macos") {
        vec!["/usr".into(), "/bin".into()]
    } else {
        vec![
            "/usr".into(),
            "/lib".into(),
            "/lib64".into(),
            "/bin".into(),
            "/etc/ld.so.cache".into(),
        ]
    }
}

/// `cat`: `/bin/cat` on macOS, `/usr/bin/cat` on Linux.
fn cat() -> &'static str {
    if cfg!(target_os = "macos") {
        "/bin/cat"
    } else {
        "/usr/bin/cat"
    }
}

/// Runs a probe; `None` means the process was killed by a signal (the number is in `Err`).
fn probe(mode: &str, name: &str) -> Result<String, i32> {
    probe_with(mode, name, None)
}

/// A probe with an argument (`read_path`, `write_path`, `connect`).
fn probe_with(mode: &str, name: &str, arg: Option<&str>) -> Result<String, i32> {
    let out = Command::new(common::worker())
        .args([mode, name])
        .args(arg)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped()) // not a file: RLIMIT_FSIZE = 0 forbids writing to files
        .stderr(Stdio::piped())
        .output()
        .unwrap();
    use std::os::unix::process::ExitStatusExt;
    if let Some(sig) = out.status.signal() {
        return Err(sig);
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[cfg(target_os = "linux")]
#[test]
fn files_keys_and_network_are_unreachable_from_the_worker() {
    // File system: it can neither read (keys, the daemon DB), nor list, nor write.
    for p in ["read_file", "list_dir", "write_file"] {
        let r = probe("selftest", p).unwrap();
        assert!(r.contains("result=blocked"), "{p}: {r}");
        // And Landlock on its own (without seccomp) holds the file system.
        let r = probe("selftest-landlock-only", p).unwrap();
        assert!(
            r.contains("result=blocked") && r.contains("Permission denied"),
            "landlock {p}: {r}"
        );
    }
    // The daemon's environment (it could hold secrets) is not passed on: not a single variable.
    let r = probe("selftest", "env").unwrap();
    assert!(
        r.ends_with(
            "result=blocked detail=0 environment variables []; set by the system in this process: []"
        ),
        "{r}"
    );
    // Network, starting programs, threads: seccomp kills the process (SIGSYS).
    for p in ["udp", "tcp", "exec", "thread"] {
        assert_eq!(
            probe("selftest", p),
            Err(31),
            "{p} must be killed by SIGSYS"
        );
    }
    // TCP is closed by Landlock too (ABI ≥ 4).
    let r = probe("selftest-landlock-only", "tcp").unwrap();
    assert!(r.contains("result=blocked"), "landlock tcp: {r}");
}

/// macOS (Seatbelt, D-P-12): the file system, the network and starting programs are closed with an `EPERM` refusal
/// (Seatbelt does not kill the process the way seccomp does); the daemon's environment is not passed on.
#[cfg(target_os = "macos")]
#[test]
fn files_and_network_are_unreachable_from_the_worker() {
    for p in ["read_file", "list_dir", "write_file", "udp", "tcp", "exec"] {
        let r = probe("selftest", p).unwrap();
        assert!(
            r.contains("result=blocked") && r.contains("Operation not permitted"),
            "{p}: {r}"
        );
    }
    // Nothing from the parent. CoreFoundation sets `__CF_USER_TEXT_ENCODING` (uid, text encoding, region) in the worker
    // itself at startup; that one name, in that shape, is all the system may add.
    let r = probe("selftest", "env").unwrap();
    println!("FACT worker environment: {r}");
    assert!(
        r.ends_with("result=blocked detail=0 environment variables []; set by the system in this process: []")
            || r.ends_with(
                "result=blocked detail=0 environment variables []; set by the system in this process: \
                 [__CF_USER_TEXT_ENCODING]"
            ),
        "{r}"
    );
}

/// Negative control for the environment probe: a variable the parent passes in is reported by name (and its value is
/// not printed), so the probe is not blind and the system's own variable does not hide anything else.
#[test]
fn a_variable_passed_to_the_worker_is_reported() {
    let out = Command::new(common::worker())
        .args(["selftest", "env"])
        .env_clear()
        .env("ANTENNA_TEST_PASSED_IN", "s3cr3t-value")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .unwrap();
    let r = String::from_utf8_lossy(&out.stdout).trim().to_string();
    assert!(
        r.contains("result=ALLOWED detail=1 environment variables [ANTENNA_TEST_PASSED_IN];"),
        "{r}"
    );
    assert!(!r.contains("s3cr3t"), "{r}");
}

/// Facts for the CI log (`FACT …`): the isolated worker does not read a secret in `~/.ssh` (or an owner file if there
/// is no `~/.ssh`), does not write outside the sandbox (the worker has no temporary directory of its own at all) and
/// does not connect to a local server. Without the sandbox the test process manages all of this, so the refusal comes
/// from the isolation.
#[test]
fn worker_cannot_read_secrets_write_outside_or_connect() {
    let t = tempfile::tempdir().unwrap();
    // The secret: a real file in ~/.ssh if there is one (read only, nothing is changed), otherwise an owner file
    // nearby.
    let ssh = std::env::var_os("HOME")
        .map(|h| std::path::Path::new(&h).join(".ssh"))
        .and_then(|d| std::fs::read_dir(d).ok())
        .and_then(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .find(|p| p.is_file() && std::fs::read(p).is_ok())
        });
    let secret = ssh.unwrap_or_else(|| {
        let p = t.path().join("id_ed25519");
        std::fs::write(&p, "-----BEGIN OPENSSH PRIVATE KEY-----\n").unwrap();
        p
    });
    assert!(
        std::fs::read(&secret).is_ok(),
        "control: the test itself reads {secret:?}"
    );
    let outside = t.path().join("written-by-worker");
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap().to_string();
    assert!(
        std::net::TcpStream::connect(&addr).is_ok(),
        "control: the test itself connects"
    );
    let denied = |r: Result<String, i32>| match r {
        Ok(s) => s.contains("result=blocked"),
        // seccomp (Linux) kills the process on `socket`; that is a refusal too.
        Err(sig) => sig == 31,
    };
    let read = probe_with("selftest", "read_path", secret.to_str());
    let write = probe_with("selftest", "write_path", outside.to_str());
    let net = probe_with("selftest", "connect", Some(&addr));
    println!(
        "FACT file worker ({}): read {} → {read:?}; write {} → {write:?}; connect {addr} → {net:?}",
        if cfg!(target_os = "macos") {
            "seatbelt"
        } else {
            "landlock+seccomp"
        },
        if secret.starts_with(t.path()) {
            "owner file"
        } else {
            "~/.ssh file"
        },
        outside.display(),
    );
    assert!(denied(read.clone()), "read: {read:?}");
    assert!(denied(write.clone()), "write: {write:?}");
    assert!(!outside.exists(), "the worker wrote outside");
    assert!(denied(net.clone()), "connect: {net:?}");
}

#[tokio::test]
async fn library_selftest_reports_every_probe_blocked() {
    let r = antenna_files::sandbox::selftest(std::path::Path::new(common::worker()), &[]).await;
    assert_eq!(r.len(), antenna_files::sandbox::PROBES.len());
    for p in &r {
        assert!(p.blocked, "{p:?}");
    }
}

#[test]
fn memory_and_cpu_limits_kill_the_worker() {
    // 2 GiB with a 512 MiB limit: the allocator gets a refusal → SIGABRT, the machine's memory is not eaten (on macOS
    // `RLIMIT_DATA` does not hold `mmap` memory; there the daemon's watchdog enforces the limit,
    // `a_worker_over_the_memory_limit_is_stopped`).
    #[cfg(target_os = "linux")]
    assert_eq!(probe("selftest", "big_alloc"), Err(6));
    // Infinite loop: RLIMIT_CPU 10 s → SIGXCPU.
    let t = Instant::now();
    assert_eq!(probe("selftest", "cpu_loop"), Err(24));
    assert!(t.elapsed() < Duration::from_secs(20));
}

/// Worker memory limit through a whole check (daemon → worker): 256 MiB of content with a 160 MiB limit gives a
/// `failed` check and the machine's memory is not eaten. Linux: `RLIMIT_DATA` (the allocator gets a refusal); macOS:
/// the daemon's watchdog from the memory footprint.
#[tokio::test]
async fn a_worker_over_the_memory_limit_is_stopped() {
    let mut cfg = CheckerConfig::new(common::worker());
    cfg.av = None;
    cfg.mem_bytes = 160 << 20;
    let data = vec![b'a'; 256 << 20];
    let t = Instant::now();
    let o = Checker::new(cfg)
        .check(&data[..], data.len() as u64, "big.txt", true)
        .await;
    println!(
        "FACT memory limit: {:?} {:?} in {:?}",
        o.report.verdict,
        o.report
            .findings
            .iter()
            .map(|f| &f.detail)
            .collect::<Vec<_>>(),
        t.elapsed()
    );
    assert_eq!(o.report.verdict, Verdict::Failed, "{:?}", o.report.findings);
    assert_eq!(o.report.findings[0].code, "worker_crashed");
    #[cfg(target_os = "macos")]
    assert!(
        o.report.findings[0].detail.contains("memory watchdog"),
        "{:?}",
        o.report.findings
    );
}

#[tokio::test]
async fn report_says_how_the_worker_was_isolated() {
    let o = common::checker()
        .check(&b"hi\n"[..], 3, "a.txt", true)
        .await;
    assert_eq!(o.report.verdict, Verdict::Clean);
    let s = &o.report.sandbox;
    println!("FACT worker isolation: {s}");
    if cfg!(target_os = "macos") {
        assert!(
            s.contains("seatbelt=true") && s.contains("rlimits=true") && s.contains("extra_fds=0"),
            "{s}"
        );
    } else {
        assert!(
            s.contains("seccomp=true") && s.contains("rlimits=true") && s.contains("extra_fds=0"),
            "{s}"
        );
        assert!(!s.contains("abi=0") && !s.contains("landlock=none"), "{s}");
    }
}

#[tokio::test]
async fn a_worker_that_does_not_confirm_isolation_gets_no_content() {
    // The "worker" is cat: it echoes the request instead of confirming isolation → refusal, the content is not sent.
    let mut cfg = CheckerConfig::new("/bin/cat");
    cfg.worker_args = vec![];
    cfg.av = None;
    let o = Checker::new(cfg)
        .check(&b"secret content"[..], 14, "a.txt", true)
        .await;
    assert_eq!(o.report.verdict, Verdict::Failed);
    assert_eq!(o.report.findings[0].code, "sandbox_unavailable");
    // A missing worker is a refusal too, not "clean".
    let mut cfg = CheckerConfig::new("/nonexistent/antenna-files-sandbox");
    cfg.av = None;
    let o = Checker::new(cfg).check(&b"x"[..], 1, "a.txt", true).await;
    assert_eq!(o.report.verdict, Verdict::Failed);
}

#[tokio::test]
async fn a_hanging_check_times_out_as_failed() {
    let mut cfg = CheckerConfig::new("/bin/sleep");
    cfg.worker_args = vec!["30".into()];
    cfg.timeout = Duration::from_secs(2);
    cfg.av = None;
    let t = Instant::now();
    let o = Checker::new(cfg).check(&b"x"[..], 1, "a.txt", true).await;
    assert!(t.elapsed() < Duration::from_secs(5));
    assert_eq!(o.report.verdict, Verdict::Failed);
    assert_eq!(o.report.findings[0].code, "check_timeout");
}

#[tokio::test]
async fn external_antivirus_hook_runs_isolated() {
    // The hook is off by default and is never taken from PATH; this test uses a stub script instead of ClamAV.
    assert!(CheckerConfig::new(common::worker()).av.is_none());
    // A "daemon key" outside the allowed directories: the antivirus must not read it.
    let t = tempfile::tempdir().unwrap();
    let key = t.path().join("daemon-key");
    std::fs::write(&key, "TOPSECRET").unwrap();
    // The hook follows the clamscan convention: 0 is clean, 1 is found; 2 means "could read the key" (isolation
    // failure).
    let script = format!(
        "if {cat} \"$1\" 2>/dev/null | /usr/bin/grep -q TOPSECRET; then exit 2; fi; \
         if /usr/bin/grep -q EICAR-STANDARD; then exit 1; else exit 0; fi",
        cat = cat()
    );
    let hook = |program: &str| AvHook {
        name: "fake-av".into(),
        program: program.into(),
        args: vec![
            "-c".into(),
            script.clone().into(),
            "sh".into(),
            key.clone().into(),
        ],
        ro_paths: av_ro_paths(),
        mem_bytes: 1 << 30,
        timeout: Duration::from_secs(20),
    };
    let mut cfg = CheckerConfig::new(common::worker());
    cfg.av = Some(hook("/bin/sh"));
    let c = Checker::new(cfg);
    let e = common::samples::eicar();
    let o = c.check(&e[..], e.len() as u64, "x.txt", true).await;
    assert_eq!(o.report.verdict, Verdict::Threat);
    assert!(
        o.report.findings.iter().any(|f| f.code == "av:fake-av"),
        "{:?}",
        o.report.findings
    );
    let o = c.check(&b"clean text\n"[..], 11, "x.txt", true).await;
    assert_eq!(o.report.verdict, Verdict::Clean, "{:?}", o.report.findings);
    assert!(o.report.engines.contains(&"av:fake-av".to_string()));
    // The antivirus's copy of the content is in memory (/dev/shm), not on disk (macOS has no /dev/shm, so the user's
    // temporary directory is used); leftovers after a crash are removed.
    assert_eq!(
        antenna_files::sandbox::av_scratch_root(),
        if cfg!(target_os = "macos") {
            std::env::temp_dir()
        } else {
            std::path::PathBuf::from("/dev/shm")
        }
    );
    let stale = antenna_files::sandbox::av_scratch_root().join("x-av-stale-test");
    std::fs::create_dir_all(&stale).unwrap();
    assert!(antenna_files::sandbox::remove_stale_av_scratch() >= 1);
    assert!(!stale.exists());
    // A relative path (planted in PATH) is not run.
    let mut cfg = CheckerConfig::new(common::worker());
    cfg.av = Some(hook("sh"));
    let o = Checker::new(cfg)
        .check(&b"clean text\n"[..], 11, "x.txt", true)
        .await;
    assert!(
        o.report.findings.iter().any(|f| f.code == "av_failed"),
        "{:?}",
        o.report.findings
    );
}

/// The antivirus under av-exec does not send signals to other processes, and ordinary programs (NSS, /dev/null) work
/// under it.
#[tokio::test]
async fn av_exec_cannot_signal_others_but_runs_ordinary_tools() {
    let mut victim = Command::new("/bin/sleep").arg("30").spawn().unwrap();
    let script = format!(
        "/usr/bin/id >/dev/null 2>&1 || exit 3; echo x >/dev/null || exit 4; kill -TERM {} ; exit 0",
        victim.id()
    );
    let mut cfg = CheckerConfig::new(common::worker());
    cfg.av = Some(AvHook {
        name: "probe-av".into(),
        program: "/bin/bash".into(),
        args: vec!["-c".into(), script.into()],
        ro_paths: av_ro_paths(),
        mem_bytes: 1 << 30,
        timeout: Duration::from_secs(20),
    });
    let o = Checker::new(cfg)
        .check(&b"text\n"[..], 5, "x.txt", true)
        .await;
    if cfg!(target_os = "macos") {
        // Seatbelt: a signal outside its sandbox is refused with `EPERM`, the antivirus itself keeps running.
        assert!(
            o.report.engines.contains(&"av:probe-av".to_string()),
            "{:?}",
            o.report.findings
        );
    } else {
        // An attempt to kill another process kills the antivirus itself (SIGSYS): it gives no verdict.
        let f = o
            .report
            .findings
            .iter()
            .find(|f| f.code == "av_failed")
            .expect("av must be killed");
        assert!(f.detail.contains("SIGSYS"), "{}", f.detail);
    }
    assert!(
        victim.try_wait().unwrap().is_none(),
        "the victim must still be alive"
    );
    victim.kill().unwrap();
    // Without the signal attempt, id (Linux: NSS over AF_UNIX → EPERM; macOS: opendirectoryd) and /dev/null work.
    let mut cfg = CheckerConfig::new(common::worker());
    cfg.av = Some(AvHook {
        name: "probe-av".into(),
        program: "/bin/bash".into(),
        args: vec![
            "-c".into(),
            "/usr/bin/id >/dev/null 2>&1 || exit 3; echo x >/dev/null || exit 4; exit 0".into(),
        ],
        ro_paths: av_ro_paths(),
        mem_bytes: 1 << 30,
        timeout: Duration::from_secs(20),
    });
    let o = Checker::new(cfg)
        .check(&b"text\n"[..], 5, "x.txt", true)
        .await;
    assert!(
        o.report.engines.contains(&"av:probe-av".to_string()),
        "{:?}",
        o.report.findings
    );
}

/// The calling process inherited descriptors without CLOEXEC (like the test process on a GitHub runner: 2 extra fds;
/// a window, a script, an embedding program), yet the worker does not get them and checks the file (D-61). The test
/// re-runs itself as a child under `sh` with fds 7 and 8 open; with the old code this gave `sandbox_unavailable`
/// "inherited 2 open file descriptor(s)".
#[tokio::test]
async fn caller_with_inherited_descriptors_still_gets_an_isolated_worker() {
    const CHILD: &str = "ANTENNA_FILES_LEAKED_FDS_CHILD";
    if std::env::var_os(CHILD).is_some() {
        let fd_dir = if cfg!(target_os = "macos") {
            "/dev/fd"
        } else {
            "/proc/self/fd"
        };
        let leaked = ["7", "8"]
            .iter()
            .filter(|n| std::path::Path::new(&format!("{fd_dir}/{n}")).exists())
            .count();
        let o = common::checker()
            .check(&b"just a note\n"[..], 12, "note.txt", true)
            .await;
        println!(
            "RESULT leaked_in_caller={leaked} verdict={:?} codes={:?} sandbox={}",
            o.report.verdict,
            o.report
                .findings
                .iter()
                .map(|f| &f.code)
                .collect::<Vec<_>>(),
            o.report.sandbox
        );
        std::process::exit(0);
    }
    let me = std::env::current_exe().unwrap();
    let held = tempfile::NamedTempFile::new().unwrap();
    let out = Command::new("/bin/sh")
        .arg("-c")
        .arg(r#"exec 7<"$1" 8<"$1"; exec "$0" --exact "$2" --nocapture --test-threads=1"#)
        .arg(&me)
        .arg(held.path())
        .arg("caller_with_inherited_descriptors_still_gets_an_isolated_worker")
        .env(CHILD, "1")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    println!("{text}");
    assert!(
        text.contains("RESULT leaked_in_caller=2 verdict=Clean"),
        "{text}"
    );
    assert!(text.contains("extra_fds=0"), "{text}");
    assert!(!text.contains("sandbox_unavailable"), "{text}");
}

/// macOS: a program started under a profile aborts inside dyld before `main` unless the profile lets dyld's loader open
/// `/` (D-P-15). Apple's `dyld-support.sb` and our explicit rule each work on their own, so the profile does not depend on
/// that file; without either, the program dies with SIGABRT on macOS 26 (a fact for the log: older systems may not need
/// the rule).
#[cfg(target_os = "macos")]
#[test]
fn programs_start_under_the_profile_with_either_dyld_rule_set() {
    use antenna_files::seatbelt::{DYLD_SUPPORT, av_exec_profile, exec_support, exec_support_here};
    use std::os::unix::process::ExitStatusExt;
    let t = tempfile::tempdir().unwrap();
    let prog = std::path::Path::new("/usr/bin/true");
    let profile = av_exec_profile(&[], t.path(), prog).unwrap();
    let here = exec_support_here();
    assert!(profile.contains(&here), "{profile}");
    let run = |p: &str| {
        let o = Command::new("/usr/bin/sandbox-exec")
            .arg("-p")
            .arg(p)
            .arg(prog)
            .env_clear()
            .output()
            .unwrap();
        (
            o.status.code(),
            o.status.signal(),
            String::from_utf8_lossy(&o.stderr).trim().to_string(),
        )
    };
    let has_import = std::path::Path::new(DYLD_SUPPORT).is_file();
    let import = has_import.then(|| run(&profile.replace(&here, &exec_support(true))));
    let explicit = run(&profile.replace(&here, &exec_support(false)));
    let neither = run(&profile.replace(&here, ""));
    println!(
        "FACT dyld under a profile ({DYLD_SUPPORT} present: {has_import}): import {import:?}, explicit rule \
         {explicit:?}, neither {neither:?}"
    );
    assert_eq!(explicit.0, Some(0), "explicit rule: {explicit:?}");
    if let Some(i) = import {
        assert_eq!(i.0, Some(0), "import: {i:?}");
    }
}
