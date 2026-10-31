// SPDX-License-Identifier: AGPL-3.0-only
//! Basic checks of the `antennad` binary: version, permissions of the socket and the data directory, the agent role
//! without a token; on Windows the pipe, the data folder and their refusals. Full two-node scenarios are in
//! `crates/antenna-cli/tests/`.

use std::process::Command;
#[cfg(unix)]
use std::{
    fs::File,
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::Path,
    process::{Child, Stdio},
    time::{Duration, Instant},
};

#[cfg(unix)]
struct Daemon(Child);

#[cfg(unix)]
impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The command that starts a daemon on `dir`, with `extra` arguments after the usual ones.
#[cfg(unix)]
fn command(dir: &Path, extra: &[&str]) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_antennad"));
    // A test run inside an agent session must not reach that session's daemon or token.
    c.env_remove("ANTENNA_SOCKET")
        .env_remove("ANTENNA_DATA_DIR")
        .env_remove("ANTENNA_AGENT_TOKEN")
        .env_remove("ANTENNA_AGENT_TOKEN_FILE")
        .args([
            "--data-dir",
            dir.to_str().unwrap(),
            // Link folders go into the test's temporary directory, not into $HOME/Antenna/links.
            "--links-dir",
            dir.join("links").to_str().unwrap(),
            "--relay",
            "disabled",
            "--bind-ip",
            "127.0.0.1",
        ])
        .args(extra);
    c
}

#[cfg(unix)]
fn start(dir: &Path) -> Daemon {
    let child = command(dir, &[])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let sock = dir.join("antennad.sock");
    let t = Instant::now();
    while !sock.exists() {
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "antennad did not start"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    Daemon(child)
}

#[test]
fn version() {
    let out = Command::new(env!("CARGO_BIN_EXE_antennad"))
        // A test run inside an agent session must not reach that session's daemon or token.
        .env_remove("ANTENNA_SOCKET")
        .env_remove("ANTENNA_DATA_DIR")
        .env_remove("ANTENNA_AGENT_TOKEN")
        .env_remove("ANTENNA_AGENT_TOKEN_FILE")
        .arg("--version")
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).starts_with("antennad "));
}

/// The lifeline (D-UI-10): a daemon started with `--exit-with-stdin` exits by itself once its stdin closes, as when the
/// window that started it is killed. The control: without the flag, the same daemon stays up after its stdin closes.
#[test]
fn a_daemon_on_a_lifeline_exits_when_its_stdin_closes() {
    use std::io::{BufRead, BufReader};
    use std::process::Stdio;
    use std::time::{Duration, Instant};
    for lifeline in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        let mut child = Command::new(env!("CARGO_BIN_EXE_antennad"))
            .env_remove("ANTENNA_SOCKET")
            .env_remove("ANTENNA_DATA_DIR")
            .env_remove("ANTENNA_AGENT_TOKEN")
            .env_remove("ANTENNA_AGENT_TOKEN_FILE")
            .arg("--data-dir")
            .arg(&data)
            .arg("--links-dir")
            .arg(dir.path().join("links"))
            .args(["--relay", "disabled", "--bind-ip", "127.0.0.1"])
            .args(lifeline.then_some("--exit-with-stdin"))
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let stderr = child.stderr.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if line.contains(" listening on ") {
                    let _ = tx.send(());
                }
            }
        });
        rx.recv_timeout(Duration::from_secs(30))
            .expect("antennad did not start");
        drop(child.stdin.take());
        let t = Instant::now();
        let mut exited = None;
        while t.elapsed() < Duration::from_secs(if lifeline { 15 } else { 3 }) {
            if let Some(status) = child.try_wait().unwrap() {
                exited = Some(status);
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        if lifeline {
            let status = exited.expect("the daemon outlived its lifeline");
            assert!(status.success(), "a clean exit, as on SIGTERM: {status}");
            let _ = child.wait();
        } else {
            assert!(exited.is_none(), "exited without a lifeline: {exited:?}");
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Windows (D-135): the daemon on a named pipe, with its data folder made for the user alone.
#[cfg(windows)]
mod windows {
    use std::{
        fs::{File, OpenOptions},
        io::{BufRead, BufReader, Write},
        os::windows::{fs::OpenOptionsExt, io::AsHandle},
        path::{Path, PathBuf},
        process::{Child, Command, Stdio},
        sync::atomic::{AtomicUsize, Ordering},
        time::{Duration, Instant},
    };

    use antenna_core::data_folder;
    use antenna_sys::windows::security::{
        AceKind, ObjectKind, SecurityDescriptor, Sid, current_user, dir_facts, handle_security,
    };

    /// `SECURITY_IDENTIFICATION` (std adds `SECURITY_SQOS_PRESENT`): what every client of the pipe asks for.
    const IDENTIFICATION: u32 = 0x0001_0000;
    /// `SECURITY_ANONYMOUS`.
    const ANONYMOUS: u32 = 0;

    pub struct Daemon {
        child: Child,
        log: PathBuf,
    }

    impl Daemon {
        /// What the daemon wrote to stderr so far.
        fn log(&self) -> String {
            std::fs::read_to_string(&self.log).unwrap_or_default()
        }
    }

    impl Drop for Daemon {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    fn command(data: &Path, extra: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_antennad"));
        // A test run inside an agent session must not reach that session's daemon or token.
        c.env_remove("ANTENNA_SOCKET")
            .env_remove("ANTENNA_DATA_DIR")
            .env_remove("ANTENNA_AGENT_TOKEN")
            .env_remove("ANTENNA_AGENT_TOKEN_FILE")
            .arg("--data-dir")
            .arg(data)
            .arg("--links-dir")
            .arg(data.with_file_name("links"))
            .args(["--relay", "disabled", "--bind-ip", "127.0.0.1"])
            .args(extra);
        c
    }

    /// Starts the daemon in the background, its stderr in a file of its own next to the data folder.
    fn spawn(data: &Path, extra: &[&str]) -> Daemon {
        static RUNS: AtomicUsize = AtomicUsize::new(0);
        let log = data.with_extension(format!("{}.log", RUNS.fetch_add(1, Ordering::Relaxed)));
        let child = command(data, extra)
            .stdout(Stdio::null())
            .stderr(File::create(&log).unwrap())
            .spawn()
            .unwrap();
        Daemon { child, log }
    }

    /// Runs the daemon, which is expected to refuse and exit, and gives its stderr.
    fn refused(data: &Path, extra: &[&str]) -> String {
        let mut d = spawn(data, extra);
        let t = Instant::now();
        loop {
            if let Some(status) = d.child.try_wait().unwrap() {
                assert!(!status.success(), "{status}: {}", d.log());
                return d.log();
            }
            assert!(
                t.elapsed() < Duration::from_secs(30),
                "antennad did not refuse: {}",
                d.log()
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The pipe the daemon makes by default for this data folder, which must exist.
    fn pipe_of(data: &Path) -> String {
        let me = current_user().unwrap();
        let real = std::fs::canonicalize(data).unwrap();
        antenna_proto::local::control_pipe_name(&me.to_string(), real.to_str().unwrap())
    }

    /// Opens the pipe as a client does: `ERROR_PIPE_BUSY` (the daemon is between handing off one instance and making
    /// the next) is retried for a while.
    fn open(pipe: &str, qos: u32) -> std::io::Result<File> {
        let t = Instant::now();
        loop {
            match OpenOptions::new()
                .read(true)
                .write(true)
                .security_qos_flags(qos)
                .open(pipe)
            {
                Err(e) if e.raw_os_error() == Some(231) && t.elapsed() < Duration::from_secs(5) => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                r => return r,
            }
        }
    }

    /// Waits for the daemon's pipe: the data folder first, then the pipe of it.
    fn wait_pipe(d: &mut Daemon, data: &Path) -> String {
        let t = Instant::now();
        loop {
            if let Some(status) = d.child.try_wait().unwrap() {
                panic!("antennad exited ({status}): {}", d.log());
            }
            if data.is_dir() {
                let pipe = pipe_of(data);
                if open(&pipe, IDENTIFICATION).is_ok() {
                    return pipe;
                }
            }
            assert!(
                t.elapsed() < Duration::from_secs(30),
                "antennad did not start: {}",
                d.log()
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// One connection: these lines, then every line the daemon answers until it closes.
    fn talk(pipe: &str, qos: u32, lines: &[&str]) -> Vec<String> {
        let mut f = open(pipe, qos).unwrap();
        for l in lines {
            f.write_all(l.as_bytes()).unwrap();
            f.write_all(b"\n").unwrap();
        }
        BufReader::new(f).lines().map_while(Result::ok).collect()
    }

    const HELLO: &str = r#"{"hello":{"proto":"x-control/0","role":"owner"}}"#;

    /// The daemon starts as this user: its data folder passes the check with our one entry and is locked; its pipe is
    /// ours alone; it answers the owner role and refuses the agent role without a token, as on unix. After init, every
    /// file in the folder carries only our entry, inherited.
    #[test]
    fn the_daemon_serves_its_user_on_its_pipe() {
        let me = current_user().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        let mut d = spawn(&data, &[]);
        let pipe = wait_pipe(&mut d, &data);
        assert!(
            pipe.starts_with(&format!(r"\\.\pipe\antenna-{me}-")),
            "{pipe}"
        );

        let (findings, notes) = data_folder::check(&me, &dir_facts(&data).unwrap());
        assert_eq!((findings, notes), (vec![], vec![]));
        assert!(data.join(antenna_core::data_lock::LOCK_NAME).is_file());
        let client = open(&pipe, IDENTIFICATION).unwrap();
        let sec = handle_security(client.as_handle(), ObjectKind::Kernel).unwrap();
        drop(client);
        assert_eq!(sec.owner.as_ref(), Some(&me));
        let dacl = sec.dacl.unwrap();
        assert!(dacl.protected);
        assert_eq!(dacl.aces.len(), 1, "{dacl:?}");
        assert_eq!(
            (dacl.aces[0].kind, dacl.aces[0].sid.as_ref()),
            (AceKind::Allow, Some(&me))
        );

        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[HELLO, r#"{"req":{"cmd":"status"}}"#],
        );
        assert!(r[0].contains("hello_ok"), "{r:?}");
        assert!(r[1].contains("\"state\":\"uninitialized\""), "{r:?}");
        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[r#"{"hello":{"proto":"x-control/0","role":"agent"}}"#],
        );
        assert!(r[0].contains("token_invalid"), "{r:?}");
        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[HELLO, r#"{"req":{"cmd":"init","password":"password-123"}}"#],
        );
        assert!(r[1].contains("unlocked"), "{r:?}");
        let mut files = 0;
        for f in std::fs::read_dir(&data).unwrap() {
            let f = f.unwrap();
            let sec = dir_facts(&f.path()).unwrap().security;
            let aces = sec.dacl.unwrap().aces;
            assert!(
                !aces.is_empty()
                    && aces
                        .iter()
                        .all(|a| a.sid.as_ref() == Some(&me) && a.flags & 0x10 != 0),
                "{:?}: {aces:?}",
                f.file_name()
            );
            files += 1;
        }
        assert!(files >= 2, "the database and the lock at least");
    }

    /// On Windows an agent comes by its token alone: `bind_parent`, which `antenna mcp` asks for, binds nothing there
    /// and refuses nothing (D-135, WP-9). The control: a wrong token is refused.
    #[test]
    fn an_agent_comes_by_its_token_alone() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        let mut d = spawn(&data, &[]);
        let pipe = wait_pipe(&mut d, &data);
        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[HELLO, r#"{"req":{"cmd":"init","password":"password-123"}}"#],
        );
        assert!(r[1].contains("unlocked"), "{r:?}");
        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[
                HELLO,
                r#"{"req":{"cmd":"agent_add","name":"bot","links":null,"local_level":5,"password":"password-123"}}"#,
            ],
        );
        let token = r[1]
            .split("\"token\":\"")
            .nth(1)
            .and_then(|t| t.split('"').next())
            .unwrap_or_else(|| panic!("{r:?}"))
            .to_string();
        let hello = |t: &str| {
            format!(
                r#"{{"hello":{{"proto":"x-control/0","role":"agent","token":"{t}","bind_parent":true}}}}"#
            )
        };
        let r = talk(&pipe, IDENTIFICATION, &[&hello(&token)]);
        assert!(
            r[0].contains("hello_ok") && r[0].contains("\"role\":\"agent\""),
            "{r:?}"
        );
        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[&hello(
                "xat_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            )],
        );
        assert!(r[0].contains("token_invalid"), "{r:?}");
    }

    /// A client that opens the pipe at anonymous level cannot be identified and is refused before anything else, and
    /// the next client is served. The control: the same daemon serves an identified client (above, and here after).
    #[test]
    fn an_unidentifiable_client_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        let mut d = spawn(&data, &[]);
        let pipe = wait_pipe(&mut d, &data);
        let r = talk(&pipe, ANONYMOUS, &[HELLO, r#"{"req":{"cmd":"status"}}"#]);
        eprintln!("FACT an anonymous-level client: {r:?}");
        assert_eq!(r.len(), 1, "{r:?}");
        assert!(r[0].contains("forbidden"), "{r:?}");
        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[HELLO, r#"{"req":{"cmd":"status"}}"#],
        );
        assert!(r[0].contains("hello_ok"), "{r:?}");
    }

    /// A pipe name already held stops the daemon, naming who holds it: ours ("another antennad"), or one whose owner
    /// cannot be read (a DACL that lets only SYSTEM in). The control: the same folder with the name free starts.
    #[test]
    fn a_held_pipe_name_stops_the_daemon() {
        let me = current_user().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let _rt = rt.enter();
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        data_folder::prepare(&data).unwrap();
        let pipe = pipe_of(&data);

        let ours =
            SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;;GRGW;;;{me})S:(ML;;NWNR;;;ME)"))
                .unwrap();
        let held = antenna_sys::windows::pipe::create_server(&pipe, true, &ours).unwrap();
        let err = refused(&data, &[]);
        assert!(
            err.contains(&format!("another antennad is already listening on {pipe}")),
            "{err}"
        );
        drop(held);

        let system_only = SecurityDescriptor::from_sddl(&format!("O:{me}D:P(A;;GA;;;SY)")).unwrap();
        let held = antenna_sys::windows::pipe::create_server(&pipe, true, &system_only).unwrap();
        let err = refused(&data, &[]);
        eprintln!("FACT a pipe name held behind a DACL: {err}");
        assert!(
            err.contains(&format!(
                "the pipe {pipe} is already held, and its owner is unreadable"
            )),
            "{err}"
        );
        drop(held);

        let mut d = spawn(&data, &[]);
        assert_eq!(wait_pipe(&mut d, &data), pipe);
    }

    /// A data folder that is not ours alone (made the ordinary way, so it inherits from %TEMP%) stops the daemon before
    /// it writes anything, naming the SIDs and the rights; the folder is left as it was. The control: the folder the
    /// daemon makes itself passes (above).
    #[test]
    fn a_weak_data_folder_is_refused() {
        let me = current_user().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        std::fs::create_dir(&data).unwrap();
        let before = dir_facts(&data).unwrap().security;
        let err = refused(&data, &[]);
        assert!(err.contains("is not yours alone"), "{err}");
        assert!(
            err.contains(&me.to_string()) && err.contains("rights 0x"),
            "{err}"
        );
        assert!(err.contains(&Sid::administrators().to_string()), "{err}");
        assert_eq!(dir_facts(&data).unwrap().security, before);
        assert_eq!(
            std::fs::read_dir(&data).unwrap().count(),
            0,
            "nothing written"
        );
    }

    /// One data folder, one daemon: a second one on the same folder is refused even on another pipe, and a pipe name
    /// that is not a local pipe is refused. The control: the first daemon keeps serving.
    #[test]
    fn a_second_daemon_on_the_same_folder_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        let mut d = spawn(&data, &[]);
        let pipe = wait_pipe(&mut d, &data);
        let other = format!(r"\\.\pipe\antenna-test-{}", std::process::id());
        let err = refused(&data, &["--socket", &other]);
        assert!(
            err.contains("another antennad is using the data folder"),
            "{err}"
        );
        let r = talk(
            &pipe,
            IDENTIFICATION,
            &[HELLO, r#"{"req":{"cmd":"status"}}"#],
        );
        assert!(r[0].contains("hello_ok"), "{r:?}");
        drop(d);

        let data2 = dir.path().join("data2");
        let err = refused(&data2, &["--socket", r"\\host\pipe\antenna"]);
        assert!(err.contains("is not a local pipe name"), "{err}");
    }
}

/// Windows: the agent supervisor and the file check worker refuse to run without their sandboxes (D-134, WP-19,
/// WP-20).
#[cfg(windows)]
#[test]
fn on_windows_the_sandboxed_modes_refuse_to_run() {
    for mode in [
        &["--antenna-wake-exec"][..],
        &["--antenna-files-worker", "check"],
    ] {
        let out = Command::new(env!("CARGO_BIN_EXE_antennad"))
            .args(mode)
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(125), "{mode:?}: {out:?}");
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(err.contains("sandbox_unavailable"), "{mode:?}: {err}");
        assert!(out.stdout.is_empty(), "{mode:?}: {out:?}");
    }
}

// The unix socket and modes; Windows has its own checks (`windows`).
#[cfg(unix)]
#[test]
fn socket_and_data_dir_are_private() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let _d = start(&data);
    let sock = std::fs::metadata(data.join("antennad.sock"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(sock & 0o777, 0o600, "socket must be 0600");
    let d = std::fs::metadata(&data).unwrap().permissions().mode();
    assert_eq!(d & 0o777, 0o700, "data dir must be 0700");
    let lock = std::fs::metadata(data.join("antennad.lock"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(lock & 0o777, 0o600, "the lock file must be 0600");
    // After init all files (keystore, database, WAL) are accessible only to the owner (umask 077).
    let mut s = UnixStream::connect(data.join("antennad.sock")).unwrap();
    s.write_all(b"{\"hello\":{\"proto\":\"x-control/0\",\"role\":\"owner\"}}\n{\"req\":{\"cmd\":\"init\",\"password\":\"password-123\"}}\n").unwrap();
    s.shutdown(std::net::Shutdown::Write).unwrap();
    let lines: Vec<String> = BufReader::new(s).lines().map(|l| l.unwrap()).collect();
    assert!(lines[1].contains("unlocked"), "{lines:?}");
    for f in std::fs::read_dir(&data).unwrap() {
        let f = f.unwrap();
        let mode = f.metadata().unwrap().permissions().mode() & 0o777;
        assert_eq!(mode & 0o077, 0, "{:?} has mode {mode:o}", f.file_name());
    }
}

// The unix socket; Windows has its own checks (`windows`).
#[cfg(unix)]
#[test]
fn agent_role_is_refused_and_status_works_for_owner() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let _d = start(&data);
    let talk = |lines: &[&str]| -> Vec<String> {
        let mut s = UnixStream::connect(data.join("antennad.sock")).unwrap();
        for l in lines {
            s.write_all(l.as_bytes()).unwrap();
            s.write_all(b"\n").unwrap();
        }
        s.shutdown(std::net::Shutdown::Write).unwrap();
        BufReader::new(s).lines().map(|l| l.unwrap()).collect()
    };
    // An agent cannot get in while the node is not unlocked (tokens are stored in the encrypted database).
    let r = talk(&[r#"{"hello":{"proto":"x-control/0","role":"agent","token":"t"}}"#]);
    assert!(r[0].contains("not_initialized"), "{r:?}");
    // The agent role without a token is refused.
    let r = talk(&[r#"{"hello":{"proto":"x-control/0","role":"agent"}}"#]);
    assert!(r[0].contains("token_invalid"), "{r:?}");
    let r = talk(&[
        r#"{"hello":{"proto":"x-control/0","role":"owner"}}"#,
        r#"{"req":{"cmd":"status"}}"#,
    ]);
    assert!(r[0].contains("hello_ok"), "{r:?}");
    assert!(r[1].contains("\"state\":\"uninitialized\""), "{r:?}");
    // An owner command on a node without init gets an honest error.
    let r = talk(&[
        r#"{"hello":{"proto":"x-control/0","role":"owner"}}"#,
        r#"{"req":{"cmd":"contacts"}}"#,
    ]);
    assert!(r[1].contains("not_initialized"), "{r:?}");
}

/// What the daemon at `sock` answers to the owner's `status`, or the error of reaching it.
#[cfg(unix)]
fn owner_status(sock: &Path) -> std::io::Result<String> {
    let mut s = UnixStream::connect(sock)?;
    s.set_read_timeout(Some(Duration::from_secs(10)))?;
    s.write_all(
        b"{\"hello\":{\"proto\":\"x-control/0\",\"role\":\"owner\"}}\n{\"req\":{\"cmd\":\"status\"}}\n",
    )?;
    s.shutdown(std::net::Shutdown::Write)?;
    let lines = BufReader::new(s).lines().collect::<Result<Vec<_>, _>>()?;
    Ok(lines.join("\n"))
}

/// Waits for `child` to exit on its own and gives its status; `None` if it is still running after `limit`.
#[cfg(unix)]
fn exits_within(child: &mut Child, limit: Duration) -> Option<std::process::ExitStatus> {
    let t = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        if t.elapsed() >= limit {
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Waits until the daemon `d` (its stderr in `log`) answers `status` at `sock`; it must not exit meanwhile.
#[cfg(unix)]
fn wait_answers(d: &mut Daemon, sock: &Path, log: &Path) {
    let t = Instant::now();
    loop {
        if let Ok(a) = owner_status(sock)
            && a.contains("\"state\":\"uninitialized\"")
        {
            return;
        }
        if let Some(status) = d.0.try_wait().unwrap() {
            panic!(
                "the daemon exited ({status}): {}",
                std::fs::read_to_string(log).unwrap()
            );
        }
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "the daemon did not answer: {}",
            std::fs::read_to_string(log).unwrap()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Starts a daemon on `data` with its stderr in `log`; the socket may still be a stale file of an earlier daemon.
#[cfg(unix)]
fn start_logged(data: &Path, extra: &[&str], log: &Path) -> Daemon {
    Daemon(
        command(data, extra)
            .stdout(Stdio::null())
            .stderr(File::create(log).unwrap())
            .spawn()
            .unwrap(),
    )
}

/// One data folder, one daemon, on unix too: a second antennad on the same `--data-dir` is refused even with another
/// `--socket` (which is what got around the socket guard), says which folder and which lock, and makes nothing of its
/// own; the first keeps answering. Once the first is gone, a new daemon starts on the folder: after a crash (killed,
/// its socket file stays) and after a clean stop (SIGTERM).
#[cfg(unix)]
#[test]
fn a_second_daemon_on_the_same_data_dir_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let sock = data.join("antennad.sock");
    let first = start(&data);
    let before = owner_status(&sock).unwrap();
    assert!(before.contains("\"state\":\"uninitialized\""), "{before}");

    let other = dir.path().join("other.sock");
    let log = dir.path().join("second.log");
    let mut second = start_logged(&data, &["--socket", other.to_str().unwrap()], &log);
    let status = exits_within(&mut second.0, Duration::from_secs(20))
        .expect("the second daemon on the same data folder must refuse and exit");
    let err = std::fs::read_to_string(&log).unwrap();
    assert_eq!(status.code(), Some(1), "{status}: {err}");
    assert!(
        err.contains(&format!(
            "another antennad is using the data folder {} (it holds antennad.lock): stop it first, or give this one \
             another --data-dir",
            data.display()
        )),
        "{err}"
    );
    assert!(!other.exists(), "the refused daemon made its socket");

    // The control: the first daemon is untouched and answers.
    let after = owner_status(&sock).unwrap();
    assert!(after.contains("\"state\":\"uninitialized\""), "{after}");

    // After a crash: killed, with its socket file left behind.
    drop(first);
    assert!(sock.exists(), "a killed daemon leaves its socket file");
    let log = dir.path().join("third.log");
    let mut third = start_logged(&data, &[], &log);
    wait_answers(&mut third, &sock, &log);

    // After a clean stop.
    let pid = rustix::process::Pid::from_raw(i32::try_from(third.0.id()).unwrap()).unwrap();
    rustix::process::kill_process(pid, rustix::process::Signal::TERM).unwrap();
    let status =
        exits_within(&mut third.0, Duration::from_secs(20)).expect("SIGTERM stops the daemon");
    assert!(status.success(), "{status}");
    assert!(!sock.exists(), "a stopped daemon removes its socket");
    let log = dir.path().join("fourth.log");
    let mut fourth = start_logged(&data, &[], &log);
    wait_answers(&mut fourth, &sock, &log);
}
