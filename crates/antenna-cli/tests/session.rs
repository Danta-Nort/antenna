// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna session` (D-108): an agent CLI session in tmux, woken by Antenna like the window's Code mode. Real
//! `antennad` (two nodes: bob writes to alice's agent `helper`), the real `antenna`, a real tmux on the session's
//! private socket, and a stand-in for Claude Code that reads the `--settings` it is given and runs the hook commands
//! the way Claude Code does (the event's JSON on standard input, Stop's answer read from standard output), draws
//! Claude Code's prompt box, and records every line it reads. The stand-in starts `antenna mcp` from its
//! `--mcp-config`, so the daemon binds the agent's token to it (D-28) and the waker reads the agent's facts through
//! `agent_watch`.
//!
//! What must hold: only a message the agent reads causes a line (not one to the person, not one to everyone); the line
//! is the fixed one, typed once, Enter on its own; a running turn gets it through its Stop hook, nothing typed; never
//! into a permission dialog or over a person's draft; the switch; the log holds no message text; the CLI gets the token
//! file's path and no token, no other descriptors; a process in the agent's tree cannot start a session. With
//! `ANTENNA_REAL_CLAUDE=1`, `real_claude_code_in_a_session_is_woken` runs the real Claude Code (the canary).
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

/// The stand-in for Claude Code (see the module comment). A line `work<N>` is a turn of N seconds, `ask` opens a
/// permission dialog that the next line answers, `nested` runs `antenna session start` from inside the agent's tree.
const FAKE_CLAUDE: &str = r#"#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
def fd_open(n):
    try:
        os.fstat(n)
        return True
    except OSError:
        return False
early_fds = [n for n in range(3, 64) if fd_open(n)]
args = sys.argv[1:]
def log(name, text):
    with open(name, 'a') as f:
        f.write(text + '\n')
log('started.log', json.dumps({
    'fds': early_fds, 'env_token': 'ANTENNA_AGENT_TOKEN' in os.environ,
    'token_file': os.environ.get('ANTENNA_AGENT_TOKEN_FILE'), 'socket': os.environ.get('ANTENNA_SOCKET'),
    'claudecode': 'CLAUDECODE' in os.environ, 'resume': args[args.index('--resume') + 1] if '--resume' in args else None,
    'last_arg': args[-1]}))
def on_hup(*_):
    log('signals.log', 'hup')
    os._exit(129)
signal.signal(signal.SIGHUP, on_hup)
hooks = json.loads(args[args.index('--settings') + 1]).get('hooks', {})
mcp = json.loads(args[args.index('--mcp-config') + 1])['mcpServers']['antenna']
srv = subprocess.Popen([mcp['command']] + mcp['args'], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                       stderr=open('mcp.log', 'a'))
SID = '0f8fad5b-d9cb-469f-a165-70867728950e'
def run(event, payload):
    outs = []
    payload = dict(payload, session_id=SID, hook_event_name=event)
    for entry in hooks.get(event, []):
        for h in entry.get('hooks', []):
            p = subprocess.run(['/bin/sh', '-c', h['command']], input=json.dumps(payload, separators=(',', ':')),
                               capture_output=True, text=True)
            outs.append(p.stdout)
    return outs
rule = '─' * 40
def draw(top, status):
    sys.stdout.write('\x1b[2J\x1b[H\x1b[?25h' + top + '\r\n\r\n' + rule + '\r\n❯ \r\n' + rule + '\r\n  ' + status + '\x1b[4;3H')
    sys.stdout.flush()
def idle():
    draw('● ready', '? for shortcuts')
def busy():
    draw('✻ Working… (esc to interrupt)', 'esc to interrupt')
def dialog():
    sys.stdout.write('\x1b[2J\x1b[H\x1b[?25l● Bash(touch notes.txt)\r\n\r\n Do you want to proceed?\r\n ❯ 1. Yes\r\n   2. No\r\n\r\n Esc to cancel')
    sys.stdout.flush()
def nested():
    x = mcp['command']
    sock = os.environ['ANTENNA_SOCKET']
    cmd = [x, '--json', '--socket', sock, 'session', 'start', 'other', '--program', sys.argv[0], '--dir', '.']
    with_file = subprocess.run(cmd, capture_output=True, text=True)
    env = {k: v for k, v in os.environ.items() if k != 'ANTENNA_AGENT_TOKEN_FILE'}
    without = subprocess.run(cmd, capture_output=True, text=True, env=env)
    log('nested.log', json.dumps({'with_token_file': [with_file.returncode, with_file.stdout],
                                  'without': [without.returncode, without.stdout]}))
run('SessionStart', {'source': 'startup'})
idle()
for line in sys.stdin:
    line = line.rstrip('\n')
    log('typed.log', line)
    if line == 'nested':
        nested()
        idle()
        continue
    run('UserPromptSubmit', {'prompt': line})
    busy()
    if line == 'ask':
        dialog()
        run('PermissionRequest', {'tool_name': 'Bash'})
        log('answers.log', sys.stdin.readline().strip())
        busy()
        time.sleep(1)
    else:
        time.sleep(int(line[4:]) if line.startswith('work') and line[4:].isdigit() else 1)
    active = False
    while True:
        cont = [o for o in run('Stop', {'stop_hook_active': active}) if '"decision"' in o]
        if not cont:
            break
        log('continued.log', json.loads(cont[0])['reason'])
        busy()
        time.sleep(1)
        active = True
    idle()
"#;

/// A stand-in for an OpenAI Responses endpoint on loopback (the same as the window's real-Codex test): every request
/// gets "ok" streamed back after the delay given as its argument; it prints its port first.
const ENDPOINT: &str = r#"
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
DELAY = float(sys.argv[1])
def sse(name, data):
    return ("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def do_GET(self):
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", "0")))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()
        rid, mid = "resp_%d" % (time.time() * 1000), "msg_%d" % (time.time() * 1000)
        item = {"id": mid, "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
        self.wfile.write(sse("response.created", {"type": "response.created", "response": {"id": rid, "object": "response", "status": "in_progress", "output": []}}))
        self.wfile.flush()
        time.sleep(DELAY)
        for e in [sse("response.output_item.added", {"type": "response.output_item.added", "output_index": 0, "item": dict(item, status="in_progress", content=[])}),
                  sse("response.output_text.delta", {"type": "response.output_text.delta", "item_id": mid, "output_index": 0, "content_index": 0, "delta": "ok"}),
                  sse("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}),
                  sse("response.completed", {"type": "response.completed", "response": {"id": rid, "object": "response", "status": "completed", "output": [item],
                      "usage": {"input_tokens": 10, "output_tokens": 1, "total_tokens": 11, "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}}})]:
            self.wfile.write(e)
            self.wfile.flush()
        self.close_connection = True
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
"#;

const WAKE_BOB: &str = "New Antenna messages from bob: read your inbox and continue.";

/// The marker in every message bob sends: it must never reach the agent's terminal, the hook files or the log.
const MARK: &str = "SECRET-MARK-41";

fn tmux_bin() -> Option<PathBuf> {
    [
        "/usr/bin/tmux",
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/bin/tmux",
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|p| p.is_file())
}

fn python() -> Option<&'static str> {
    [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
    ]
    .into_iter()
    .find(|p| Path::new(p).is_file())
}

fn wait_for(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) -> Duration {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout ({timeout:?}): {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
    t.elapsed()
}

fn lines(p: &Path) -> Vec<String> {
    std::fs::read_to_string(p)
        .map(|s| s.lines().map(str::to_string).collect())
        .unwrap_or_default()
}

/// Two nodes, alice's agent `helper` (links: bob, a token file), announced to bob; a project folder with the
/// stand-in.
struct Rig {
    _root: tempfile::TempDir,
    alice: Node,
    bob: Node,
    work: PathBuf,
    fake: PathBuf,
    tmux: PathBuf,
}

impl Rig {
    fn new() -> Option<Rig> {
        let (Some(tmux), Some(py)) = (tmux_bin(), python()) else {
            eprintln!("SKIP: antenna session needs tmux and python3 for the stand-in");
            return None;
        };
        let root = tempfile::Builder::new()
            .prefix("as")
            .tempdir_in("/tmp")
            .unwrap();
        let mut alice = Node::new(root.path(), "alice", Net::Local);
        let mut bob = Node::new(root.path(), "bob", Net::Local);
        alice.start();
        bob.start();
        alice.init();
        bob.init();
        pair(&alice, &bob, 3);
        let tok = alice.agent_add(
            "helper",
            &["--local-level", "0", "--links", "bob", "--token-file"],
        );
        alice.agent_ok(&tok, &["send", "bob", "helper here"]);
        wait_for("bob learns alice's agent", T, || {
            bob.contact("alice")["agents"]
                .as_array()
                .is_some_and(|a| a.iter().any(|x| x["name"] == "helper"))
        });
        let work = root.path().join("project");
        std::fs::create_dir(&work).unwrap();
        let fake = root.path().join("claude");
        std::fs::write(&fake, FAKE_CLAUDE.replacen("/usr/bin/env python3", py, 1)).unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        Some(Rig {
            _root: root,
            alice,
            bob,
            work,
            fake,
            tmux,
        })
    }

    fn sessions(&self) -> PathBuf {
        self.alice.dir.join("sessions")
    }

    fn hook_dir(&self) -> PathBuf {
        self.sessions().join("helper")
    }

    /// `antenna session <args>` on alice's node.
    fn session(&self, args: &[&str]) -> (i32, Value) {
        let mut a = vec!["--json", "session"];
        a.extend_from_slice(args);
        let out = self.alice.cmd().args(&a).output().unwrap();
        (out.status.code().unwrap_or(-1), last_json(&out.stdout))
    }

    fn start(&self, extra: &[&str]) -> Value {
        let mut a = vec![
            "start",
            "helper",
            "--program",
            self.fake.to_str().unwrap(),
            "--dir",
            self.work.to_str().unwrap(),
            "--tmux",
            self.tmux.to_str().unwrap(),
        ];
        a.extend_from_slice(extra);
        let (c, v) = self.session(&a);
        assert_eq!(c, 0, "session start: {v}");
        // SessionStart from the stand-in, and the waker watching the agent's facts (its MCP server bound the token)
        let events = self.hook_dir().join("events");
        wait_for("SessionStart", T, || {
            lines(&events).contains(&"start".to_string())
        });
        let watch = self.hook_dir().join("watch");
        wait_for("agent_watch", T, || {
            std::fs::read_to_string(&watch).is_ok_and(|s| s == "watching")
        });
        v
    }

    /// The person attached to the session types `text` (and Enter).
    fn keys(&self, text: &str, enter: bool) {
        let mut c = Command::new(&self.tmux);
        c.arg("-S").arg(self.sessions().join("tmux.sock")).args([
            "send-keys",
            "-t",
            "=antenna-helper:",
            "-l",
            "--",
            text,
        ]);
        assert!(c.status().unwrap().success());
        if enter {
            std::thread::sleep(Duration::from_millis(300));
            let mut c = Command::new(&self.tmux);
            c.arg("-S").arg(self.sessions().join("tmux.sock")).args([
                "send-keys",
                "-t",
                "=antenna-helper:",
                "Enter",
            ]);
            assert!(c.status().unwrap().success());
        }
    }

    fn key(&self, name: &str) {
        let mut c = Command::new(&self.tmux);
        c.arg("-S").arg(self.sessions().join("tmux.sock")).args([
            "send-keys",
            "-t",
            "=antenna-helper:",
            name,
        ]);
        assert!(c.status().unwrap().success());
    }

    fn typed(&self) -> Vec<String> {
        lines(&self.work.join("typed.log"))
    }

    fn to_helper(&self, text: &str) {
        self.bob
            .send_to_agent("alice", "helper", &format!("{text} {MARK}"));
    }

    fn no_mark_anywhere(&self) {
        for f in ["typed.log", "continued.log"] {
            assert!(
                !std::fs::read_to_string(self.work.join(f))
                    .unwrap_or_default()
                    .contains(MARK),
                "{f}"
            );
        }
        for f in ["events", "wake.log", "status", "watch", "spec.json"] {
            assert!(
                !std::fs::read_to_string(self.hook_dir().join(f))
                    .unwrap_or_default()
                    .contains(MARK),
                "{f}"
            );
        }
    }

    fn stop(&self) {
        let _ = self.session(&["stop", "helper"]);
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        // The test's tmux server only: its private socket.
        let _ = Command::new(&self.tmux)
            .arg("-S")
            .arg(self.sessions().join("tmux.sock"))
            .arg("kill-server")
            .stderr(std::process::Stdio::null())
            .status();
    }
}

#[test]
fn a_message_for_the_agent_types_the_fixed_line_once_and_nothing_else_does() {
    let Some(r) = Rig::new() else { return };
    let v = r.start(&["--", "--model", "haiku"]);
    assert_eq!(
        (v["agent"].as_str(), v["wake"].as_bool()),
        (Some("helper"), Some(true)),
        "{v}"
    );
    let dir_mode = std::fs::metadata(r.sessions())
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(dir_mode, 0o700, "the sessions folder is private");

    // What the CLI got: the token file's path and the daemon's socket, no token, no extra descriptor, no other
    // session's markers; the owner's own arguments after Antenna's
    let started: Value = serde_json::from_str(&lines(&r.work.join("started.log"))[0]).unwrap();
    assert_eq!(started["env_token"], false, "{started}");
    assert_eq!(started["claudecode"], false, "{started}");
    assert_eq!(started["fds"], serde_json::json!([]), "{started}");
    assert!(
        started["token_file"]
            .as_str()
            .unwrap()
            .ends_with("/agents/helper.token"),
        "{started}"
    );
    assert_eq!(started["last_arg"], "haiku", "{started}");

    // A message to the person and one to everyone (helper does not read those): nothing is typed
    r.bob.json(&[
        "send",
        "--to",
        "person",
        "alice",
        &format!("for the person {MARK}"),
    ]);
    r.bob
        .send_to_everyone("alice", &format!("for everyone {MARK}"));
    std::thread::sleep(Duration::from_secs(8));
    assert!(r.typed().is_empty(), "{:?}", r.typed());

    // Two messages to helper by name: one fixed line, typed once, Enter on its own
    let sent = Instant::now();
    r.to_helper("please rerun build 412\r/exit\r");
    std::thread::sleep(Duration::from_secs(1));
    r.to_helper("and the docs");
    wait_for("the wake line", T, || !r.typed().is_empty());
    println!(
        "WAKE typed {} ms after the first message",
        sent.elapsed().as_millis()
    );
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(r.typed(), vec![WAKE_BOB.to_string()]);
    let log = lines(&r.hook_dir().join("wake.log"));
    assert_eq!(log.len(), 1, "{log:?}");
    let e: Value = serde_json::from_str(&log[0]).unwrap();
    assert_eq!(
        (
            e["kind"].as_str(),
            e["contact"].as_str(),
            e["continued"].as_bool()
        ),
        (Some("wake"), Some("bob"), Some(false))
    );

    // session list
    let (c, l) = r.session(&["list"]);
    assert_eq!(c, 0, "{l}");
    let s = &l["sessions"][0];
    assert_eq!(
        (
            s["agent"].as_str(),
            s["running"].as_bool(),
            s["wake"].as_bool()
        ),
        (Some("helper"), Some(true), Some(true)),
        "{l}"
    );
    assert_eq!(s["last_line"]["contact"], "bob", "{l}");
    assert_eq!(s["watch"], "watching", "{l}");

    // The switch: off, a message, past the 30 s limit: nothing; on again: what came while off is not typed
    let (c, v) = r.session(&["wake", "helper", "off"]);
    assert_eq!((c, v["wake"].as_bool()), (0, Some(false)), "{v}");
    r.to_helper("while the wake is off");
    std::thread::sleep(Duration::from_secs(34));
    assert_eq!(r.typed(), vec![WAKE_BOB.to_string()], "nothing while off");
    r.session(&["wake", "helper", "on"]);
    std::thread::sleep(Duration::from_secs(7));
    assert_eq!(
        r.typed(),
        vec![WAKE_BOB.to_string()],
        "a message from while it was off wakes nobody"
    );

    // From inside the agent's process tree: the agent CLI has no `session` command, and without the token file in
    // its environment the daemon still says this process is the agent's, so `session start` is refused
    r.keys("nested", true);
    let nested = r.work.join("nested.log");
    wait_for("the nested starts", T, || nested.exists());
    let n: Value = serde_json::from_str(&lines(&nested)[0]).unwrap();
    assert_eq!(n["with_token_file"][0], 2, "{n}");
    assert!(
        n["with_token_file"][1]
            .as_str()
            .unwrap()
            .contains("unknown_command"),
        "{n}"
    );
    assert_eq!(n["without"][0], 77, "{n}");
    assert!(
        n["without"][1].as_str().unwrap().contains("forbidden"),
        "{n}"
    );
    assert!(!r.sessions().join("other").join("spec.json").exists());

    r.no_mark_anywhere();

    // stop: the CLI gets SIGHUP, the session is gone, its end is recorded
    let (c, v) = r.session(&["stop", "helper"]);
    assert_eq!((c, v["stopped"].as_bool()), (0, Some(true)), "{v}");
    assert_eq!(lines(&r.work.join("signals.log")), vec!["hup".to_string()]);
    assert!(r.hook_dir().join("exit").exists());
    let (_, l) = r.session(&["list"]);
    assert_eq!(l["sessions"][0]["running"], false, "{l}");
}

#[test]
fn a_running_turn_is_continued_by_its_stop_hook_and_nothing_is_typed() {
    let Some(r) = Rig::new() else { return };
    r.start(&[]);
    // The person starts a 12 s turn; bob writes to helper while it runs
    r.keys("work12", true);
    let events = r.hook_dir().join("events");
    wait_for("UserPromptSubmit", T, || {
        lines(&events).contains(&"prompt".to_string())
    });
    let sent = Instant::now();
    r.to_helper("rerun build 412");
    let cont = r.work.join("continued.log");
    wait_for("the Stop hook continues", Duration::from_secs(40), || {
        !lines(&cont).is_empty()
    });
    println!("CONTINUED {} ms after sending", sent.elapsed().as_millis());
    wait_for("idle after the continued turn", T, || {
        lines(&events).last().is_some_and(|l| l == "stop")
    });
    std::thread::sleep(Duration::from_secs(8));
    assert_eq!(lines(&cont), vec![WAKE_BOB.to_string()]);
    assert_eq!(
        r.typed(),
        vec!["work12".to_string()],
        "nothing typed by the waker"
    );
    let log = lines(&r.hook_dir().join("wake.log"));
    let e: Value = serde_json::from_str(log.last().unwrap()).unwrap();
    assert_eq!(e["continued"], true, "{log:?}");
    r.no_mark_anywhere();
    r.stop();
}

#[test]
fn never_into_a_permission_dialog_or_over_a_draft() {
    let Some(r) = Rig::new() else { return };
    r.start(&[]);
    // A draft at the idle prompt: the hooks say idle, the screen shows the text after the prompt: nothing typed
    r.keys("abc", false);
    std::thread::sleep(Duration::from_secs(1));
    r.to_helper("first");
    std::thread::sleep(Duration::from_secs(10));
    assert!(r.typed().is_empty(), "{:?}", r.typed());
    // The person deletes the draft: the prompt is empty again, the line waits and is typed
    for _ in 0..3 {
        r.key("BSpace");
    }
    wait_for("the line after the draft is gone", T, || {
        !r.typed().is_empty()
    });
    assert_eq!(r.typed(), vec![WAKE_BOB.to_string()]);
    wait_for("the turn ends", T, || {
        lines(&r.hook_dir().join("events"))
            .last()
            .is_some_and(|l| l == "stop")
    });

    // A permission dialog (Enter there would answer "Yes"): a message waits, nothing is typed into it
    r.keys("ask", true);
    let events = r.hook_dir().join("events");
    wait_for("PermissionRequest", T, || {
        lines(&events).contains(&"permission".to_string())
    });
    r.to_helper("second");
    std::thread::sleep(Duration::from_secs(40));
    assert_eq!(
        r.typed(),
        vec![WAKE_BOB.to_string(), "ask".to_string()],
        "nothing into the dialog"
    );
    assert!(!r.work.join("answers.log").exists());
    // The person answers; at the prompt again the waiting line is typed
    r.keys("1", true);
    wait_for("the line after the dialog", T, || r.typed().len() == 3);
    assert_eq!(lines(&r.work.join("answers.log")), vec!["1".to_string()]);
    assert_eq!(r.typed()[2], WAKE_BOB);
    r.no_mark_anywhere();
    r.stop();
}

#[test]
fn resume_errors_and_the_agent_cli_has_no_session_command() {
    let Some(r) = Rig::new() else { return };
    // Nothing recorded yet: --resume refuses
    let mut a = vec![
        "start",
        "helper",
        "--resume",
        "--program",
        r.fake.to_str().unwrap(),
        "--dir",
        r.work.to_str().unwrap(),
    ];
    a.extend(["--tmux", r.tmux.to_str().unwrap()]);
    let (c, v) = r.session(&a);
    assert_eq!((c, v["error"].as_str()), (1, Some("not_found")), "{v}");
    // The first session records the CLI's session ID through its hooks; a second start continues it
    r.start(&[]);
    let (c, v) = r.session(&[
        "start",
        "helper",
        "--program",
        r.fake.to_str().unwrap(),
        "--tmux",
        r.tmux.to_str().unwrap(),
    ]);
    assert_eq!(
        (c, v["error"].as_str()),
        (1, Some("already_running")),
        "{v}"
    );
    r.stop();
    let (c, v) = r.session(&a);
    assert_eq!(c, 0, "{v}");
    assert_eq!(v["resumed"], true, "{v}");
    let started = lines(&r.work.join("started.log"));
    let second: Value = serde_json::from_str(started.last().unwrap()).unwrap();
    assert_eq!(
        second["resume"], "0f8fad5b-d9cb-469f-a165-70867728950e",
        "{second}"
    );
    r.stop();

    // No tmux; no token file; a bad name
    let (c, v) = r.session(&[
        "start",
        "helper",
        "--program",
        r.fake.to_str().unwrap(),
        "--tmux",
        "/nonexistent/tmux",
    ]);
    assert_eq!((c, v["error"].as_str()), (1, Some("tmux_missing")), "{v}");
    let (c, v) = r.session(&[
        "start",
        "nobody",
        "--program",
        r.fake.to_str().unwrap(),
        "--tmux",
        r.tmux.to_str().unwrap(),
    ]);
    assert_eq!((c, v["error"].as_str()), (77, Some("token_invalid")), "{v}");
    assert!(
        v["message"]
            .as_str()
            .unwrap()
            .contains("antenna agent add nobody"),
        "{v}"
    );
    let (c, v) = r.session(&["start", "../x", "--program", r.fake.to_str().unwrap()]);
    assert_eq!((c, v["error"].as_str()), (2, Some("bad_request")), "{v}");

    // With an agent token there is no such command at all
    let tok = std::fs::read_to_string(r.alice.dir.join("agents/helper.token")).unwrap();
    for args in [
        &["session", "list"][..],
        &["session", "start", "helper"],
        &["session", "attach", "helper"],
    ] {
        let (c, v) = r.alice.agent(tok.trim(), args);
        assert_eq!(
            (c, v["error"].as_str()),
            (2, Some("unknown_command")),
            "{args:?}: {v}"
        );
    }
}

/// The canary for `antenna session` (tools/claude-canary.sh): the REAL Claude Code installed here, signed in, in a
/// session started by `antenna session start`; bob writes to the agent: the waker types the fixed line at Claude Code's
/// idle prompt and Claude Code runs a turn (its hooks say so); then, during a turn the person started, a message is
/// continued by the Stop hook. Runs only with ANTENNA_REAL_CLAUDE=1; costs a few Haiku turns.
#[test]
#[ignore = "needs a signed-in Claude Code and ANTENNA_REAL_CLAUDE=1 (tools/claude-canary.sh)"]
fn real_claude_code_in_a_session_is_woken() {
    assert_eq!(
        std::env::var("ANTENNA_REAL_CLAUDE").as_deref(),
        Ok("1"),
        "the canary switch is off"
    );
    let r = Rig::new().expect("tmux and python3");
    let claude = ["claude"]
        .iter()
        .find_map(|n| {
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
                .map(|d| d.join(n))
                .find(|p| p.is_file())
        })
        .expect("claude on PATH");
    let version = String::from_utf8_lossy(
        &Command::new(&claude)
            .arg("--version")
            .output()
            .unwrap()
            .stdout,
    )
    .trim()
    .to_string();
    println!("CANARY session claude {version}");
    std::fs::create_dir_all(r.work.join(".claude")).unwrap();
    // The rig's folder (the project's parent, which the model sometimes searches) is a working directory and reads
    // further out are refused: 2.1.306 asks "Read outside the working directories" otherwise, and the canary measures
    // the wake, not that dialog.
    let settings = serde_json::json!({
        "model": "haiku",
        "permissions": {
            "allow": ["mcp__antenna"],
            "deny": ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"],
            "additionalDirectories": [r._root.path()],
            "blockReadsOutsideWorkingDirectories": true,
        },
    });
    std::fs::write(r.work.join(".claude/settings.json"), settings.to_string()).unwrap();
    let (c, v) = r.session(&[
        "start",
        "helper",
        "--program",
        claude.to_str().unwrap(),
        "--dir",
        r.work.to_str().unwrap(),
        "--tmux",
        r.tmux.to_str().unwrap(),
    ]);
    assert_eq!(c, 0, "{v}");
    let sock = r.sessions().join("tmux.sock");
    let screen = || {
        String::from_utf8_lossy(
            &Command::new(&r.tmux)
                .arg("-S")
                .arg(&sock)
                .args(["capture-pane", "-p", "-t", "=antenna-helper:"])
                .output()
                .unwrap()
                .stdout,
        )
        .to_string()
    };
    let events = r.hook_dir().join("events");
    let ev = || lines(&events);
    // The folder trust question, answered as a person would
    let t = Instant::now();
    while ev().is_empty() && t.elapsed() < Duration::from_secs(60) {
        let s = screen();
        if s.contains("Select login method") || s.contains("Choose the text style") {
            panic!("Claude Code is not signed in here:\n{s}");
        }
        if s.contains("trust this folder") {
            if s.contains("❯ No, exit") {
                r.key("Down");
                std::thread::sleep(Duration::from_millis(500));
            }
            r.key("Enter");
            std::thread::sleep(Duration::from_secs(2));
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    wait_for("SessionStart", Duration::from_secs(60), || {
        ev().contains(&"start".to_string())
    });
    wait_for("agent_watch", Duration::from_secs(60), || {
        std::fs::read_to_string(r.hook_dir().join("watch")).is_ok_and(|s| s == "watching")
    });
    std::thread::sleep(Duration::from_secs(3));

    // 1. A message for the agent at the idle prompt: the waker types the fixed line, Claude Code runs a turn
    let from = ev().len();
    let sent = Instant::now();
    r.bob.send_to_agent(
        "alice",
        "helper",
        "Canary check from Bob: nothing to do, no reply needed.",
    );
    wait_for(
        "the typed line starts a turn",
        Duration::from_secs(60),
        || ev()[from..].contains(&"prompt".to_string()),
    );
    println!(
        "CANARY typed line started a turn {} ms after the message",
        sent.elapsed().as_millis()
    );
    wait_for("the turn ends", Duration::from_secs(120), || {
        ev()[from..].contains(&"stop".to_string())
    });
    let log = lines(&r.hook_dir().join("wake.log"));
    assert_eq!(log.len(), 1, "{log:?}\n{}", screen());
    assert!(log[0].contains(r#""continued":false"#), "{log:?}");
    assert!(
        !ev()[from..].iter().any(|e| e == "permission"),
        "a permission dialog: {:?}",
        ev()
    );

    // 2. After the 30 s limit: the person starts a turn, a message during it is continued by the Stop hook
    std::thread::sleep(Duration::from_secs(32));
    let from = ev().len();
    r.keys("Yes, go ahead.", true);
    wait_for("the person's turn", Duration::from_secs(60), || {
        ev()[from..].contains(&"prompt".to_string())
    });
    r.bob.send_to_agent(
        "alice",
        "helper",
        "Second canary check from Bob: nothing to do.",
    );
    wait_for("the Stop hook continues", Duration::from_secs(120), || {
        ev()[from..].contains(&"continued".to_string())
            || ev()[from..].iter().filter(|e| *e == "stop").count() >= 2
    });
    let cont = ev()[from..].contains(&"continued".to_string());
    let log = lines(&r.hook_dir().join("wake.log"));
    println!("CANARY session hook events: {}", ev().join(" "));
    assert!(
        cont || log.len() == 2,
        "the message during the turn neither continued it nor was typed after it: {log:?}\n{}",
        screen()
    );
    println!(
        "CANARY PASS session: typed at the idle prompt, then {}",
        if cont {
            "continued by the Stop hook"
        } else {
            "typed after the turn (the message came after its end)"
        }
    );
    r.stop();
    // Claude Code keeps a transcript per project folder under HOME: the throwaway folder's goes with it.
    let mangled: String = r
        .work
        .to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    if let Some(home) = std::env::var_os("HOME") {
        let _ = std::fs::remove_dir_all(Path::new(&home).join(".claude/projects").join(mangled));
    }
}

/// The real Codex CLI (PG-21) in a session started by `antenna session start --cli codex`, against the endpoint
/// stand-in (no account): Codex asks the owner to trust the session's hooks once (answered here as the owner would);
/// a message at the idle composer is typed once; a message during a turn the person started is continued by Codex's
/// Stop hook. Runs only with ANTENNA_REAL_CODEX=<path to codex> and CODEX_HOME=<a throwaway folder>.
#[test]
#[ignore = "needs ANTENNA_REAL_CODEX=<path to codex> and CODEX_HOME=<a throwaway folder>"]
fn real_codex_in_a_session_is_woken() {
    let codex = PathBuf::from(std::env::var("ANTENNA_REAL_CODEX").expect("ANTENNA_REAL_CODEX"));
    let home = PathBuf::from(std::env::var("CODEX_HOME").expect("CODEX_HOME"));
    assert!(
        !home.join("config.toml").exists(),
        "CODEX_HOME must be a throwaway folder"
    );
    let r = Rig::new().expect("tmux and python3");
    let script = r.work.parent().unwrap().join("endpoint.py");
    std::fs::write(&script, ENDPOINT).unwrap();
    let mut ep = Command::new("python3")
        .arg(&script)
        .arg("4")
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut port = String::new();
    std::io::BufRead::read_line(
        &mut std::io::BufReader::new(ep.stdout.take().unwrap()),
        &mut port,
    )
    .unwrap();
    std::fs::write(
        home.join("config.toml"),
        format!(
            "model_provider = \"fake\"\nmodel = \"fake-model\"\n\n[model_providers.fake]\nname = \"Fake\"\n\
             base_url = \"http://127.0.0.1:{}/v1\"\nwire_api = \"responses\"\nrequires_openai_auth = false\n",
            port.trim()
        ),
    )
    .unwrap();
    let version = String::from_utf8_lossy(
        &Command::new(&codex)
            .arg("--version")
            .output()
            .unwrap()
            .stdout,
    )
    .trim()
    .to_string();
    println!("CODEX session {version}");
    let (c, v) = r.session(&[
        "start",
        "helper",
        "--cli",
        "codex",
        "--program",
        codex.to_str().unwrap(),
        "--dir",
        r.work.to_str().unwrap(),
        "--tmux",
        r.tmux.to_str().unwrap(),
    ]);
    assert_eq!(c, 0, "{v}");
    let sock = r.sessions().join("tmux.sock");
    let screen = || {
        String::from_utf8_lossy(
            &Command::new(&r.tmux)
                .arg("-S")
                .arg(&sock)
                .args(["capture-pane", "-p", "-t", "=antenna-helper:"])
                .output()
                .unwrap()
                .stdout,
        )
        .to_string()
    };
    let events = r.hook_dir().join("events");
    let ev = || lines(&events);
    // The hooks review: nothing is typed into it; the owner trusts the hooks ("2", then Enter)
    wait_for("the hooks review", Duration::from_secs(40), || {
        screen().contains("Hooks need review")
    });
    r.to_helper("early");
    std::thread::sleep(Duration::from_secs(8));
    assert!(
        screen().contains("Hooks need review"),
        "nothing typed into Codex's question:\n{}",
        screen()
    );
    assert!(lines(&r.hook_dir().join("wake.log")).is_empty());
    r.keys("2", false);
    std::thread::sleep(Duration::from_millis(500));
    r.key("Enter");
    // Codex starts its MCP servers after the review: the daemon binds the token, the waker watches. A message that
    // came before that wakes nobody (the watch reports new messages only); the next one does.
    let watch = r.hook_dir().join("watch");
    wait_for("agent_watch", Duration::from_secs(60), || {
        std::fs::read_to_string(&watch).is_ok_and(|s| s == "watching")
    });
    let sent = Instant::now();
    r.to_helper("at the composer");
    wait_for("the wake's turn", Duration::from_secs(60), || {
        ev().contains(&"prompt".to_string())
    });
    println!(
        "CODEX session: typed line started a turn {} ms after the message",
        sent.elapsed().as_millis()
    );
    wait_for("its end", Duration::from_secs(60), || {
        ev().contains(&"stop".to_string())
    });
    let log = lines(&r.hook_dir().join("wake.log"));
    assert_eq!(log.len(), 1, "{log:?}\n{}", screen());
    assert!(log[0].contains(r#""continued":false"#), "{log:?}");
    // After the 30 s limit: the person's turn, a message during it, continued by the Stop hook
    std::thread::sleep(Duration::from_secs(31));
    let from = ev().len();
    r.keys("work8", true);
    wait_for("the person's turn", Duration::from_secs(30), || {
        ev()[from..].contains(&"prompt".to_string())
    });
    r.to_helper("during the turn");
    wait_for("the Stop hook continues", Duration::from_secs(60), || {
        let e = ev();
        assert!(
            !e[from..].contains(&"stop".to_string())
                || e[from..].contains(&"continued".to_string()),
            "the turn ended without the Stop hook continuing it: {e:?}\n{}",
            screen()
        );
        e[from..].contains(&"continued".to_string())
    });
    println!("CODEX session hook events: {}", ev().join(" "));
    println!(
        "CODEX PASS session {version}: hooks trusted once, typed at the idle composer, continued by the Stop hook"
    );
    r.stop();
    let _ = ep.kill();
    let _ = ep.wait();
}
