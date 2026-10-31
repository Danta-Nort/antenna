// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna window-bridge` (`docs/CONTROL.md` §34, D-135) against a real `antennad`: two connections at once through one
//! bridge process, each with its own hello and reply, passed through unchanged; a connection the bridge cannot make;
//! the end of stdin; a framing error, which ends the bridge without showing the frame's content.
//!
//! Run: `cargo test -p antenna-cli --test window_bridge` (from the workspace root, so that `antennad` is built).

// The bridge reaches the daemon over the unix socket here. On Windows it goes through the control pipe with the CLI's
// own client (D-135), and this test runs there once the daemon starts on Windows.
#![cfg(unix)]

mod common;

use std::{
    collections::HashMap,
    io::{Read, Write},
    process::{Child, ChildStdin, Command, ExitStatus, Stdio},
    sync::mpsc,
    time::Duration,
};

use common::*;
use serde_json::{Value, json};

const OPEN: u8 = 1;
const DATA: u8 = 2;
const CLOSE: u8 = 3;
const ERROR: u8 = 4;

fn frame(id: u32, kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut b = id.to_le_bytes().to_vec();
    b.push(kind);
    b.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    b.extend_from_slice(payload);
    b
}

/// A running bridge: frames are read from its stdout by a thread.
struct Bridge {
    child: Child,
    stdin: Option<ChildStdin>,
    frames: mpsc::Receiver<(u32, u8, Vec<u8>)>,
    /// Bytes of each connection not yet taken as lines.
    pending: HashMap<u32, Vec<u8>>,
}

impl Bridge {
    /// `cmd` is the CLI with its global options; `window-bridge` is added here.
    fn start(mut cmd: Command) -> Self {
        let mut child = cmd
            .arg("window-bridge")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("start antenna window-bridge");
        let mut out = child.stdout.take().expect("stdout");
        let (tx, frames) = mpsc::channel();
        std::thread::spawn(move || {
            loop {
                let mut head = [0u8; 9];
                if out.read_exact(&mut head).is_err() {
                    return;
                }
                let id = u32::from_le_bytes(head[..4].try_into().unwrap());
                let len = u32::from_le_bytes(head[5..].try_into().unwrap()) as usize;
                assert!(len <= 256 * 1024 + 1, "a frame of {len} bytes");
                let mut payload = vec![0u8; len];
                out.read_exact(&mut payload).expect("a whole frame");
                if tx.send((id, head[4], payload)).is_err() {
                    return;
                }
            }
        });
        Self {
            stdin: child.stdin.take(),
            child,
            frames,
            pending: HashMap::new(),
        }
    }

    fn send(&mut self, id: u32, kind: u8, payload: &[u8]) {
        let stdin = self.stdin.as_mut().expect("stdin open");
        stdin.write_all(&frame(id, kind, payload)).unwrap();
        stdin.flush().unwrap();
    }

    fn send_json(&mut self, id: u32, v: &Value) {
        self.send(id, DATA, format!("{v}\n").as_bytes());
    }

    fn next(&self) -> (u32, u8, Vec<u8>) {
        self.frames
            .recv_timeout(Duration::from_secs(20))
            .expect("a frame from the bridge")
    }

    /// The next frame of `id` that is not data; data of any id goes to its connection's bytes.
    fn next_of(&mut self, id: u32) -> (u8, Vec<u8>) {
        loop {
            let (i, kind, payload) = self.next();
            if kind == DATA {
                self.pending
                    .entry(i)
                    .or_default()
                    .extend_from_slice(&payload);
                if i == id {
                    return (DATA, Vec::new());
                }
            } else if i == id {
                return (kind, payload);
            } else {
                panic!("an unexpected frame of type {kind} for connection {i}");
            }
        }
    }

    /// The next JSON line of connection `id`, with frames of other connections kept for later.
    fn line(&mut self, id: u32) -> Value {
        loop {
            let buf = self.pending.entry(id).or_default();
            if let Some(n) = buf.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = buf.drain(..=n).collect();
                return serde_json::from_slice(&line).expect("a JSON line");
            }
            let (kind, _) = self.next_of(id);
            assert_eq!(kind, DATA, "connection {id} ended before a whole line");
        }
    }

    /// The bridge's close of `id` (after all of its data).
    fn closed(&mut self, id: u32) {
        let (kind, _) = self.next_of(id);
        assert_eq!(kind, CLOSE, "connection {id}");
        assert!(
            self.pending.get(&id).is_none_or(Vec::is_empty),
            "data left on connection {id}"
        );
    }

    /// Close stdin and wait for the exit: its status and stderr.
    fn finish(mut self) -> (ExitStatus, String) {
        drop(self.stdin.take());
        let t = std::time::Instant::now();
        let status = loop {
            if let Some(s) = self.child.try_wait().unwrap() {
                break s;
            }
            assert!(
                t.elapsed() < Duration::from_secs(20),
                "the bridge did not exit"
            );
            std::thread::sleep(Duration::from_millis(20));
        };
        let mut err = String::new();
        self.child
            .stderr
            .take()
            .unwrap()
            .read_to_string(&mut err)
            .unwrap();
        (status, err)
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn hello() -> Value {
    json!({"hello": {"proto": "x-control/7", "role": "owner"}})
}

fn status() -> Value {
    json!({"req": {"cmd": "status"}})
}

/// Two connections at once through one bridge: one waits after its hello while the other has its whole dialog, then
/// the first goes on. Each gets its own `hello_ok` (the owner's, as the window's own connections would) and its own
/// reply, and each ends with the bridge's close once the daemon has closed it. Then the end of stdin is a clean exit.
#[test]
fn two_connections_at_once_through_one_bridge() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    let mut b = Bridge::start(a.cmd());

    b.send(1, OPEN, b"");
    b.send_json(1, &hello());
    let h1 = b.line(1);
    assert_eq!(h1["hello_ok"]["proto"], "x-control/7", "{h1}");
    assert_eq!(h1["hello_ok"]["role"], "owner", "{h1}");

    b.send(2, OPEN, b"");
    b.send_json(2, &hello());
    b.send_json(2, &status());
    let h2 = b.line(2);
    assert_eq!(h2["hello_ok"]["role"], "owner", "{h2}");
    let s2 = b.line(2);
    assert_eq!(s2["ok"]["type"], "status", "{s2}");
    b.closed(2);
    b.send(2, CLOSE, b"");

    b.send_json(1, &status());
    let s1 = b.line(1);
    assert_eq!(s1["ok"]["type"], "status", "{s1}");
    b.closed(1);
    b.send(1, CLOSE, b"");

    // An id is free again after both closes.
    b.send(1, OPEN, b"");
    b.send_json(1, &hello());
    assert_eq!(b.line(1)["hello_ok"]["role"], "owner");
    // Closed by the window first: the bridge answers with its own close.
    b.send(1, CLOSE, b"");
    b.closed(1);

    let (st, err) = b.finish();
    assert_eq!(st.code(), Some(0), "stderr: {err}");
    assert!(err.is_empty(), "the bridge logged: {err}");
    a.stop();
}

/// A daemon that is not there: an error frame with the reason, then the close; the bridge goes on and exits 0 at the
/// end of stdin.
#[test]
fn a_connection_the_bridge_cannot_make_is_an_error_then_a_close() {
    let root = tempfile::tempdir().unwrap();
    let mut cmd = Command::new(x_bin());
    cmd.clean_env()
        .arg("--socket")
        .arg(root.path().join("missing.sock"));
    let mut b = Bridge::start(cmd);
    for id in [7, 8] {
        b.send(id, OPEN, b"");
        b.send_json(id, &hello());
        let (kind, reason) = b.next_of(id);
        assert_eq!(kind, ERROR);
        let reason = String::from_utf8(reason).unwrap();
        assert!(reason.starts_with("daemon_unavailable: "), "{reason}");
        assert!(reason.contains("missing.sock"), "{reason}");
        b.closed(id);
        b.send(id, CLOSE, b"");
    }
    let (st, err) = b.finish();
    assert_eq!(st.code(), Some(0), "stderr: {err}");
    assert!(err.is_empty(), "the bridge logged: {err}");
}

/// A frame outside the format ends the bridge with exit 1. Its one line on stderr names the frame, never its content;
/// the daemon connection it carried is closed.
#[test]
fn a_framing_error_ends_the_bridge_without_showing_content() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    let mut b = Bridge::start(a.cmd());
    b.send(1, OPEN, b"");
    b.send_json(1, &hello());
    assert_eq!(b.line(1)["hello_ok"]["role"], "owner");
    b.send(1, 9, b"secret-password-123");
    let t = std::time::Instant::now();
    while b.child.try_wait().unwrap().is_none() {
        assert!(t.elapsed() < Duration::from_secs(20), "the bridge goes on");
        std::thread::sleep(Duration::from_millis(20));
    }
    let (st, err) = b.finish();
    assert_eq!(st.code(), Some(1), "stderr: {err}");
    assert_eq!(
        err.trim_end(),
        "antenna window-bridge: frame of unknown type 9 for connection 1"
    );
    assert!(!err.contains("secret"), "{err}");

    // Oversized: refused from its header, before any content.
    let mut b = Bridge::start(a.cmd());
    let mut head = 1u32.to_le_bytes().to_vec();
    head.push(DATA);
    head.extend_from_slice(&(256u32 * 1024 + 2).to_le_bytes());
    b.stdin.as_mut().unwrap().write_all(&head).unwrap();
    b.stdin.as_mut().unwrap().flush().unwrap();
    let t = std::time::Instant::now();
    while b.child.try_wait().unwrap().is_none() {
        assert!(t.elapsed() < Duration::from_secs(20), "the bridge goes on");
        std::thread::sleep(Duration::from_millis(20));
    }
    let (st, err) = b.finish();
    assert_eq!(st.code(), Some(1), "stderr: {err}");
    assert!(err.contains("over the limit"), "{err}");
    a.stop();
}
