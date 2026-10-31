// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna agent-run` (Windows; D-134, Code mode on Windows): the terminal host, driven by its frames
//! as the window drives it, with a stand-in agent. The stand-in is this test binary run again as an ignored test
//! (`stand_in`), so it can report what it got: its folder, its arguments, a variable, Ctrl+C, its children.
//!
//! - T4: the window's end (stdin closed) ends the run and everything it started; so does the host's own end (killed).
//!   The control: while stdin stays open, they run.
//! - T5: a folder, arguments and a variable with spaces, quotes, backslashes and non-ASCII reach the agent unchanged.
//! - T6: the agent's exit code is the last frame; its output comes through the console; a missing folder is 126; Stop
//!   ends everything, and the run never reads as a success.
//! - T7: Ctrl+C reaches the agent, and the inner lives through it to report the agent's code. The control: a program
//!   without a handler of its own dies of it.
//! - T8: a resize reaches the console. The control: without it the size stays.
//! - T10: frames outside the format end the host before anything runs, or end the run; a spec that is not valid is
//!   refused without quoting it.

#![cfg(windows)]

use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

use serde_json::{Value, json};

const SPEC: u8 = 1;
const DATA: u8 = 2;
const STOP: u8 = 3;
const ERROR: u8 = 4;
const RESIZE: u8 = 5;
const EXIT: u8 = 6;
const STOPPED: u32 = 1;
const STATUS_CONTROL_C_EXIT: u32 = 0xC000_013A;

const MODE: &str = "AGENT_RUN_TEST_MODE";
const OUT: &str = "AGENT_RUN_TEST_OUT";
const PROBE: &str = "AGENT_RUN_TEST_PROBE";
const CODE: &str = "AGENT_RUN_TEST_CODE";
const TOKEN: &str = "xat_agent_run_test_token";

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut b = 0u32.to_le_bytes().to_vec();
    b.push(kind);
    b.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_le_bytes());
    b.extend_from_slice(payload);
    b
}

/// A running host: its frames are read from its stdout by a thread.
struct Host {
    child: Child,
    stdin: Option<ChildStdin>,
    frames: mpsc::Receiver<(u8, Vec<u8>)>,
    screen: Vec<u8>,
}

impl Host {
    fn start() -> Host {
        let mut child = Command::new(env!("CARGO_BIN_EXE_antenna"))
            .arg("agent-run")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("start antenna agent-run");
        let mut out = child.stdout.take().unwrap();
        let (tx, frames) = mpsc::channel();
        std::thread::spawn(move || {
            loop {
                let mut head = [0u8; 9];
                if out.read_exact(&mut head).is_err() {
                    return;
                }
                assert_eq!(&head[..4], &[0, 0, 0, 0], "the id is always 0");
                let len = u32::from_le_bytes(head[5..].try_into().unwrap()) as usize;
                let mut payload = vec![0u8; len];
                out.read_exact(&mut payload).expect("a whole frame");
                if tx.send((head[4], payload)).is_err() {
                    return;
                }
            }
        });
        Host {
            stdin: child.stdin.take(),
            child,
            frames,
            screen: Vec::new(),
        }
    }

    fn send(&mut self, kind: u8, payload: &[u8]) {
        let w = self.stdin.as_mut().expect("stdin is open");
        w.write_all(&frame(kind, payload)).unwrap();
        w.flush().unwrap();
    }

    fn send_raw(&mut self, bytes: &[u8]) {
        let w = self.stdin.as_mut().expect("stdin is open");
        let _ = w.write_all(bytes);
        let _ = w.flush();
    }

    fn spec(&mut self, spec: &Value) {
        self.send(SPEC, spec.to_string().as_bytes());
    }

    /// Reads frames until the screen holds `text`.
    fn wait_screen(&mut self, text: &str) {
        let end = Instant::now() + Duration::from_secs(30);
        while !String::from_utf8_lossy(&self.screen).contains(text) {
            let left = end.saturating_duration_since(Instant::now());
            match self.frames.recv_timeout(left) {
                Ok((DATA, p)) => self.screen.extend_from_slice(&p),
                Ok((kind, p)) => panic!(
                    "frame {kind} ({:?}) before {text:?} on the screen: {}",
                    String::from_utf8_lossy(&p),
                    self.screen_text()
                ),
                Err(_) => panic!("{text:?} never came; the screen: {}", self.screen_text()),
            }
        }
    }

    /// Reads frames to the last one: EXIT's code, or ERROR's reason.
    fn last(&mut self) -> Result<u32, String> {
        loop {
            match self.frames.recv_timeout(Duration::from_secs(30)) {
                Ok((DATA, p)) => self.screen.extend_from_slice(&p),
                Ok((EXIT, p)) => {
                    assert_eq!(p.len(), 4);
                    let code = u32::from_le_bytes(p.try_into().unwrap());
                    assert!(
                        self.frames.recv_timeout(Duration::from_secs(5)).is_err(),
                        "EXIT is the last frame"
                    );
                    return Ok(code);
                }
                Ok((ERROR, p)) => return Err(String::from_utf8(p).unwrap()),
                Ok((kind, _)) => panic!("an unexpected frame {kind}"),
                Err(_) => panic!("no last frame; the screen: {}", self.screen_text()),
            }
        }
    }

    /// The host's own exit code and its stderr.
    fn ends(&mut self) -> (i32, String) {
        let end = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(s) = self.child.try_wait().unwrap() {
                let mut err = String::new();
                self.child
                    .stderr
                    .take()
                    .unwrap()
                    .read_to_string(&mut err)
                    .unwrap();
                return (s.code().unwrap(), err);
            }
            assert!(Instant::now() < end, "the host did not end");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn screen_text(&self) -> String {
        String::from_utf8_lossy(&self.screen).into_owned()
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

/// The stand-in: this test binary, running only [`stand_in`].
fn stand_in_args(extra: &[&str]) -> Vec<String> {
    let mut a: Vec<String> = [
        "stand_in",
        "--exact",
        "--ignored",
        "--nocapture",
        "--test-threads=1",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    a.extend(extra.iter().map(|s| (*s).to_owned()));
    a
}

/// A spec: the stand-in in `mode`, in `folder`, with our environment, the agent's token and `more`.
fn spec(mode: &str, folder: &Path, extra_args: &[&str], more: &[(&str, &str)]) -> Value {
    let mut env: serde_json::Map<String, Value> = std::env::vars()
        .filter(|(k, _)| {
            !k.starts_with("AGENT_RUN_TEST_") && !k.eq_ignore_ascii_case("ANTENNA_AGENT_RUN")
        })
        .map(|(k, v)| (k, Value::String(v)))
        .collect();
    env.insert(MODE.into(), mode.into());
    env.insert("ANTENNA_AGENT_TOKEN".into(), TOKEN.into());
    for (k, v) in more {
        env.insert((*k).into(), (*v).into());
    }
    json!({
        "program": std::env::current_exe().unwrap(),
        "args": stand_in_args(extra_args),
        "folder": folder,
        "env": env,
        "cols": 100,
        "rows": 30,
    })
}

fn system32(exe: &str) -> PathBuf {
    Path::new(&std::env::var_os("SystemRoot").unwrap())
        .join("System32")
        .join(exe)
}

/// A scratch folder of this test.
fn scratch(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("artest-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Whether a process with this PID runs (Windows' own list).
fn running(pid: u32) -> bool {
    let out = Command::new(system32("tasklist.exe"))
        .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).contains(&format!("\"{pid}\""))
}

fn wait_gone(pids: &[u32]) {
    let end = Instant::now() + Duration::from_secs(20);
    while pids.iter().any(|&p| running(p)) {
        assert!(Instant::now() < end, "still running: {pids:?}");
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// The stand-in's PID and its child's, once it has written them.
fn tree_pids(out: &Path) -> Vec<u32> {
    let end = Instant::now() + Duration::from_secs(30);
    loop {
        if let Ok(s) = std::fs::read_to_string(out)
            && let Ok(p) = s
                .split_whitespace()
                .map(str::parse)
                .collect::<Result<Vec<u32>, _>>()
            && p.len() == 2
        {
            return p;
        }
        assert!(Instant::now() < end, "the stand-in never wrote its PIDs");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The stand-in agent: what it does is in its environment.
#[test]
#[ignore = "the stand-in agent of the other tests, which run it"]
fn stand_in() {
    let Ok(mode) = std::env::var(MODE) else {
        return;
    };
    let out = std::env::var_os(OUT).map(PathBuf::from);
    let hex = |s: &str| {
        s.encode_utf16()
            .map(|c| format!("{c:04x}"))
            .collect::<Vec<_>>()
            .join(" ")
    };
    match mode.as_str() {
        // Its folder, its arguments after the fixed ones and one variable, as UTF-16 hex; then its exit code.
        "report" => {
            let mut lines = vec![hex(&std::env::current_dir().unwrap().to_string_lossy())];
            lines.extend(std::env::args().skip(6).map(|a| hex(&a)));
            lines.push(hex(&std::env::var(PROBE).unwrap_or_default()));
            lines.push(format!(
                "token {} run {}",
                std::env::var("ANTENNA_AGENT_TOKEN").unwrap_or_default(),
                std::env::var_os("ANTENNA_AGENT_RUN").is_some()
            ));
            std::fs::write(out.unwrap(), lines.join("\n")).unwrap();
            println!("standin-ready");
            std::process::exit(std::env::var(CODE).map_or(7, |c| c.parse().unwrap()));
        }
        // A child of its own (a long ping); both PIDs written down; then it waits.
        "tree" => {
            let mut g = Command::new(system32("PING.EXE"))
                .args(["-n", "120", "127.0.0.1"])
                .stdout(Stdio::null())
                .spawn()
                .unwrap();
            std::fs::write(out.unwrap(), format!("{} {}", std::process::id(), g.id())).unwrap();
            println!("standin-ready");
            let _ = g.wait();
        }
        // Waits for Ctrl+C with a handler of its own: 42 when it comes, 3 if it never does.
        "ctrl-c" => {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            let got = rt.block_on(async {
                let mut c = tokio::signal::windows::ctrl_c().unwrap();
                println!("standin-ready");
                tokio::time::timeout(Duration::from_secs(30), c.recv())
                    .await
                    .is_ok()
            });
            std::process::exit(if got { 42 } else { 3 });
        }
        // No handler of its own: Ctrl+C ends it as it ends any program.
        "plain" => {
            println!("standin-ready");
            std::thread::sleep(Duration::from_secs(30));
            std::process::exit(3);
        }
        m => panic!("unknown mode {m}"),
    }
}

/// T5 and T6: everything the agent is given reaches it unchanged; its output comes through the console and its code
/// is the last frame; the run's own variable never reaches it.
#[test]
fn the_agent_gets_its_folder_arguments_and_environment_unchanged() {
    let base = scratch("t5");
    let folder = base.join("a b \u{416}\u{dc}");
    std::fs::create_dir_all(&folder).unwrap();
    let out = base.join("report");
    let args = [
        "two words",
        "a\"quote",
        r"trail\",
        r#"both \"x"#,
        "\u{416}\u{1f600}",
        "",
    ];
    let probe = "\u{416} x\"y\\";
    let mut h = Host::start();
    h.spec(&spec(
        "report",
        &folder,
        &args,
        &[(OUT, out.to_str().unwrap()), (PROBE, probe), (CODE, "7")],
    ));
    assert_eq!(h.last(), Ok(7));
    assert!(
        h.screen_text().contains("standin-ready"),
        "{}",
        h.screen_text()
    );
    assert_eq!(h.ends().0, 0);
    let hex = |s: &str| {
        s.encode_utf16()
            .map(|c| format!("{c:04x}"))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let mut want = vec![hex(folder.to_str().unwrap())];
    want.extend(args.iter().map(|a| hex(a)));
    want.push(hex(probe));
    want.push(format!("token {TOKEN} run false"));
    let got = std::fs::read_to_string(&out).unwrap();
    assert_eq!(got.split('\n').collect::<Vec<_>>(), want);
    // Control: the conversion flutter_pty 0.4.2 makes on Windows (each UTF-8 byte widened on its own) changes the
    // folder's name.
    let widened: Vec<u16> = folder.to_str().unwrap().bytes().map(u16::from).collect();
    assert_ne!(
        widened,
        folder.to_str().unwrap().encode_utf16().collect::<Vec<_>>()
    );
    let _ = std::fs::remove_dir_all(&base);
}

/// T6: a folder that is not there ends the run with 126, said on the screen.
#[test]
fn a_missing_folder_is_126() {
    let base = scratch("t6m");
    let mut h = Host::start();
    h.spec(&spec("report", &base.join("missing"), &[], &[]));
    assert_eq!(h.last(), Ok(126));
    assert!(
        h.screen_text().contains("cannot open the folder"),
        "{}",
        h.screen_text()
    );
    let _ = std::fs::remove_dir_all(&base);
}

/// T4 and T6: Stop, the window's end and the host's end each end the agent and its child. The control: while stdin
/// stays open and nothing is asked, both run.
#[test]
fn stop_the_windows_end_and_the_hosts_end_end_everything() {
    let base = scratch("t4");
    let run = |tag: &str| {
        let out = base.join(tag);
        let mut h = Host::start();
        h.spec(&spec("tree", &base, &[], &[(OUT, out.to_str().unwrap())]));
        h.wait_screen("standin-ready");
        let pids = tree_pids(&out);
        (h, pids)
    };

    // Control: nothing asked, both run.
    let (mut h, pids) = run("control");
    std::thread::sleep(Duration::from_secs(1));
    assert!(
        pids.iter().all(|&p| running(p)),
        "the control: {pids:?} run"
    );
    // Stop: everything ends, and the code is never a success.
    h.send(STOP, b"");
    assert_eq!(h.last(), Ok(STOPPED));
    wait_gone(&pids);
    assert_eq!(h.ends().0, 0);

    // The window's end: stdin closes.
    let (mut h, pids) = run("lifeline");
    drop(h.stdin.take());
    assert_eq!(h.last(), Ok(STOPPED));
    wait_gone(&pids);

    // The host's own end: killed.
    let (mut h, pids) = run("killed");
    h.child.kill().unwrap();
    wait_gone(&pids);
    let _ = std::fs::remove_dir_all(&base);
}

/// T7: Ctrl+C reaches the agent, which answers 42, and the inner lives through it to report that. The control: a
/// stand-in without a handler of its own is ended by it (STATUS_CONTROL_C_EXIT).
#[test]
fn ctrl_c_reaches_the_agent_and_the_run_reports_its_code() {
    let base = scratch("t7");
    let mut h = Host::start();
    h.spec(&spec("ctrl-c", &base, &[], &[]));
    h.wait_screen("standin-ready");
    std::thread::sleep(Duration::from_millis(300));
    h.send(DATA, b"\x03");
    assert_eq!(h.last(), Ok(42));

    // Control.
    let mut h = Host::start();
    h.spec(&spec("plain", &base, &[], &[]));
    h.wait_screen("standin-ready");
    std::thread::sleep(Duration::from_millis(300));
    h.send(DATA, b"\x03");
    assert_eq!(h.last(), Ok(STATUS_CONTROL_C_EXIT), "the control");
    let _ = std::fs::remove_dir_all(&base);
}

/// T8: the console's size changes when the window says so (`mode con` reads it). The control: without a resize it
/// stays.
#[test]
fn a_resize_reaches_the_console() {
    let base = scratch("t8");
    let columns = |screen: &str| -> Vec<u32> {
        screen
            .split("Columns:")
            .skip(1)
            .filter_map(|rest| {
                rest.trim_start()
                    .split(|c: char| !c.is_ascii_digit())
                    .next()?
                    .parse()
                    .ok()
            })
            .collect()
    };
    let run = |resize: bool| -> Vec<u32> {
        let mut h = Host::start();
        let mut s = spec("unused", &base, &[], &[]);
        s["program"] = json!(system32("cmd.exe"));
        s["args"] = json!(["/d", "/c", "mode con & ping -n 4 127.0.0.1 >nul & mode con"]);
        h.spec(&s);
        h.wait_screen("Columns:");
        if resize {
            let mut size = 40u16.to_le_bytes().to_vec();
            size.extend_from_slice(&120u16.to_le_bytes());
            h.send(RESIZE, &size);
        }
        assert_eq!(h.last(), Ok(0));
        columns(&h.screen_text())
    };
    let resized = run(true);
    assert_eq!(resized.first(), Some(&100), "{resized:?}");
    assert_eq!(resized.last(), Some(&120), "{resized:?}");
    let control = run(false);
    assert_eq!(control.last(), Some(&100), "the control: {control:?}");
    let _ = std::fs::remove_dir_all(&base);
}

/// T10: before the spec, anything else ends the host and nothing runs; after it, a frame outside the format ends the
/// run; a spec that is not valid is refused in an error frame that never quotes it.
#[test]
fn frames_outside_the_format_end_the_host() {
    let before = |bytes: Vec<u8>| -> (i32, String) {
        let mut h = Host::start();
        h.send_raw(&bytes);
        drop(h.stdin.take());
        let ended = h.ends();
        assert!(
            h.frames.recv_timeout(Duration::from_secs(1)).is_err(),
            "no frame"
        );
        ended
    };
    // The control: stdin ends before any frame, and the host simply ends.
    assert_eq!(before(vec![]).0, 0, "the control");
    let (code, err) = before(frame(DATA, b"x"));
    assert_ne!(code, 0);
    assert!(err.contains("the first is the spec"), "{err}");
    assert_ne!(before(frame(9, b"x")).0, 0);
    let mut other_id = frame(SPEC, b"{}");
    other_id[0] = 1;
    assert_ne!(before(other_id).0, 0);
    let mut huge = frame(DATA, b"");
    huge[5..9].copy_from_slice(&(2u32 << 20).to_le_bytes());
    let (code, err) = before(huge);
    assert_ne!(code, 0);
    assert!(err.contains("over the limit"), "{err}");

    // After a spec: a second spec, or a resize of the wrong length, ends the run and everything in it.
    let base = scratch("t10");
    for (tag, bad) in [
        ("twice", frame(SPEC, b"{}")),
        ("resize", frame(RESIZE, &[1, 0, 2])),
    ] {
        let out = base.join(tag);
        let mut h = Host::start();
        h.spec(&spec("tree", &base, &[], &[(OUT, out.to_str().unwrap())]));
        h.wait_screen("standin-ready");
        let pids = tree_pids(&out);
        h.send_raw(&bad);
        let (code, err) = h.ends();
        assert_ne!(code, 0, "{tag}: {err}");
        assert!(!err.contains(TOKEN));
        wait_gone(&pids);
    }

    // A spec that is not valid: an error frame naming where, never what.
    let mut h = Host::start();
    let mut s = spec("report", &base, &[], &[]);
    s["cols"] = json!(TOKEN);
    h.spec(&s);
    let why = h.last().unwrap_err();
    assert!(why.contains("not valid") && !why.contains(TOKEN), "{why}");
    let (code, err) = h.ends();
    assert_ne!(code, 0);
    assert!(!err.contains(TOKEN), "{err}");
    // A program that is not a full path.
    let mut h = Host::start();
    let mut s = spec("report", &base, &[], &[]);
    s["program"] = json!("cmd.exe");
    h.spec(&s);
    assert!(h.last().unwrap_err().contains("full paths"));
    let _ = std::fs::remove_dir_all(&base);
}
