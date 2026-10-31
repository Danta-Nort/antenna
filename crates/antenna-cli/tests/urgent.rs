// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's urgent message and the stop switch (PG-58, D-133), with real daemons, a real tmux and a stand-in for
//! Claude Code in `antenna session` (the stand-in of `session.rs`, plus what Claude Code does on Escape: the turn ends
//! at once, without its Stop hook, and the prompt comes back).
//!
//! What must hold:
//! - an urgent message from the owner of an own computer (level 5 here) interrupts a running turn with one Escape,
//!   then the urgent line is typed at the prompt; a normal message in the same turn waits for the turn's Stop hook;
//! - a contact below level 5 here cannot interrupt, even when its node sends the flag (it has this node at level 5):
//!   the daemon decides, and the flag is in the link's audit log as refused;
//! - the stop switch ends the agent's terminal session with everything it started (a child, an orphan in the same
//!   session, on Linux a daemon in its own session held by the subreaper) and leaves an unrelated process alive, on
//!   this computer and when an own computer asks over the link;
//! - only a computer this one has at level 5 may ask.
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

/// The stand-in (see the module comment). `work<N>` is a turn of N seconds that Escape interrupts, `spawn` starts the
/// processes the stop must take and records their PIDs in `spawned.log`.
const FAKE_CLAUDE: &str = r#"#!/usr/bin/env python3
import json, os, select, signal, subprocess, sys, termios, time
args = sys.argv[1:]
def log(name, text):
    with open(name, 'a') as f:
        f.write(text + '\n')
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
def turn(seconds):
    # Claude Code reads its keys while it works: Escape ends the turn at once (no Stop hook)
    fd = 0
    old = termios.tcgetattr(fd)
    new = termios.tcgetattr(fd)
    new[3] &= ~(termios.ICANON | termios.ECHO)
    new[6][termios.VMIN] = 0
    new[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, new)
    try:
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], max(0.0, min(0.1, end - time.time())))
            if r and b'\x1b' in os.read(fd, 64):
                return True
        return False
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old)
def daemon():
    # A server that daemonizes: its own session, its parent gone
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        os.setsid()
        g = os.fork()
        if g == 0:
            os.close(w)
            os.execvp('sleep', ['sleep', '1002'])
        os.write(w, str(g).encode())
        os._exit(0)
    os.close(w)
    os.waitpid(pid, 0)
    g = int(os.read(r, 32))
    os.close(r)
    return g
def spawn():
    child = subprocess.Popen(['sleep', '1000'])
    orphan = subprocess.run(['/bin/sh', '-c', 'sleep 1001 >/dev/null 2>&1 & echo $!'], capture_output=True,
                            text=True)
    log('spawned.log', json.dumps({'child': child.pid, 'orphan': int(orphan.stdout.strip()), 'daemon': daemon(),
                                   'cli': os.getpid()}))
run('SessionStart', {'source': 'startup'})
idle()
while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.rstrip('\n')
    log('typed.log', line)
    if line == 'spawn':
        spawn()
        idle()
        continue
    run('UserPromptSubmit', {'prompt': line})
    busy()
    secs = int(line[4:]) if line.startswith('work') and line[4:].isdigit() else 1
    if turn(secs):
        log('interrupted.log', line)
        idle()
        continue
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

const URGENT_BOB: &str = "Urgent Antenna message from bob: read your inbox now.";
const WAKE_BOB: &str = "New Antenna messages from bob: read your inbox and continue.";
/// The marker in every message bob sends: it never reaches the terminal, the hook files or the logs.
const MARK: &str = "URGENT-MARK-58";

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

/// A process is gone: no such PID, or a zombie waiting for its parent.
fn gone(pid: i64) -> bool {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .map(|s| {
                s.rfind(')')
                    .and_then(|i| s.get(i + 2..i + 3))
                    .is_some_and(|st| st == "Z" || st == "X")
            })
            .unwrap_or(true)
    }
    #[cfg(not(target_os = "linux"))]
    {
        !Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }
}

/// alice and bob paired at level 5 both ways (bob is alice's own computer), alice's agent `helper` (links: bob, a token
/// file), announced to bob; a project folder with the stand-in.
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
            eprintln!("SKIP: the urgent tests need tmux and python3 for the stand-in");
            return None;
        };
        let root = tempfile::Builder::new()
            .prefix("ug")
            .tempdir_in("/tmp")
            .unwrap();
        let mut alice = Node::new(root.path(), "alice", Net::Local);
        let mut bob = Node::new(root.path(), "bob", Net::Local);
        alice.start();
        bob.start();
        alice.init();
        bob.init();
        pair(&alice, &bob, 5);
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

    fn session(&self, args: &[&str]) -> (i32, Value) {
        let mut a = vec!["--json", "session"];
        a.extend_from_slice(args);
        let out = self.alice.cmd().args(&a).output().unwrap();
        (out.status.code().unwrap_or(-1), last_json(&out.stdout))
    }

    fn start(&self) {
        let (c, v) = self.session(&[
            "start",
            "helper",
            "--program",
            self.fake.to_str().unwrap(),
            "--dir",
            self.work.to_str().unwrap(),
            "--tmux",
            self.tmux.to_str().unwrap(),
        ]);
        assert_eq!(c, 0, "session start: {v}");
        let events = self.hook_dir().join("events");
        wait_for("SessionStart", T, || {
            lines(&events).contains(&"start".to_string())
        });
        let watch = self.hook_dir().join("watch");
        wait_for("agent_watch", T, || {
            std::fs::read_to_string(&watch).is_ok_and(|s| s == "watching")
        });
    }

    /// The person attached to the session types `text` and Enter, then leaves the keyboard for the quiet time.
    fn keys(&self, text: &str) {
        for k in [vec!["-l", "--", text], vec!["Enter"]] {
            let mut c = Command::new(&self.tmux);
            c.arg("-S")
                .arg(self.sessions().join("tmux.sock"))
                .args(["send-keys", "-t", "=antenna-helper:"])
                .args(k);
            assert!(c.status().unwrap().success());
            std::thread::sleep(Duration::from_millis(300));
        }
        // tmux counts the person's keys in whole seconds: the waker waits 5 s after them
        std::thread::sleep(Duration::from_secs(6));
    }

    fn file(&self, name: &str) -> Vec<String> {
        lines(&self.work.join(name))
    }

    /// bob's owner writes to helper; urgent with `--urgent`.
    fn to_helper(&self, text: &str, urgent: bool) -> Value {
        let text = format!("{text} {MARK}");
        let mut a = vec!["send", "--to", "agent", "--to-agent", "helper"];
        if urgent {
            a.push("--urgent");
        }
        a.extend(["alice", text.as_str()]);
        self.bob.json(&a)
    }

    fn history_of_bob(&self) -> Vec<Value> {
        self.alice.json(&["history", "bob"])["messages"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    fn no_mark_anywhere(&self) {
        for f in ["typed.log", "continued.log", "interrupted.log"] {
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
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = Command::new(&self.tmux)
            .arg("-S")
            .arg(self.sessions().join("tmux.sock"))
            .arg("kill-server")
            .stderr(std::process::Stdio::null())
            .status();
    }
}

#[test]
fn an_urgent_owner_message_interrupts_a_running_turn_where_a_normal_one_waits() {
    let Some(r) = Rig::new() else { return };
    r.start();
    // The person starts a long turn
    r.keys("work60");
    wait_for("the turn runs", T, || {
        r.file("typed.log").contains(&"work60".to_string())
    });

    // A normal message during the turn: nothing typed, no Escape; the line waits for the turn's Stop hook
    let normal = r.to_helper("when you are done", false);
    assert_eq!(normal["urgent"], Value::Null, "{normal}");
    let cont = r.hook_dir().join("continue");
    wait_for("the line is left for the Stop hook", T, || cont.exists());
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(r.file("typed.log"), vec!["work60".to_string()]);
    assert!(r.file("interrupted.log").is_empty());

    // The owner's urgent message: one Escape ends the turn, then the urgent line at the prompt
    let sent = Instant::now();
    let u = r.to_helper("stop that app now", true);
    assert_eq!(u["urgent"], true, "the flag went: {u}");
    wait_for("the turn is interrupted", T, || {
        !r.file("interrupted.log").is_empty()
    });
    let interrupted = sent.elapsed();
    wait_for("the urgent line", T, || {
        r.file("typed.log").contains(&URGENT_BOB.to_string())
    });
    println!(
        "URGENT interrupted {} ms and typed {} ms after the message",
        interrupted.as_millis(),
        sent.elapsed().as_millis()
    );
    assert!(
        sent.elapsed() < Duration::from_secs(20),
        "{:?}",
        sent.elapsed()
    );
    assert_eq!(r.file("interrupted.log"), vec!["work60".to_string()]);
    // The continuation was taken back: the urgent line covers the normal message, nothing else is typed after it
    std::thread::sleep(Duration::from_secs(4));
    assert!(!cont.exists(), "the Stop hook's line was withdrawn");
    assert!(
        r.file("continued.log").is_empty(),
        "{:?}",
        r.file("continued.log")
    );
    assert_eq!(
        r.file("typed.log"),
        vec!["work60".to_string(), URGENT_BOB.to_string()]
    );
    let log: Vec<Value> = lines(&r.hook_dir().join("wake.log"))
        .iter()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let kinds: Vec<&str> = log.iter().map(|e| e["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["interrupt", "urgent"], "{log:?}");

    // The record: the message is urgent on both sides; alice's audit log says the flag was honoured
    let h = r.history_of_bob();
    let last = h
        .iter()
        .rev()
        .find(|i| i["direction"] == "in")
        .expect("bob's message");
    assert_eq!(last["urgent"], true, "{last}");
    let first_in = h
        .iter()
        .find(|i| i["direction"] == "in" && i["kind"] == "text")
        .unwrap();
    assert!(first_in.get("urgent").is_none(), "{first_in}");
    let audit = r.alice.json(&["log", "bob"]);
    assert!(
        audit.to_string().contains("\"action\":\"urgent\"")
            && audit.to_string().contains("\"decision\":\"allowed\""),
        "{audit}"
    );
    r.no_mark_anywhere();
}

#[test]
fn a_contact_below_level_5_cannot_interrupt_even_with_the_flag() {
    let Some(r) = Rig::new() else { return };
    // alice no longer has bob as an own computer; bob still has alice at 5, so its node sends the flag
    r.alice.owner_json(&["trust", "bob", "3"]);
    wait_for("alice has bob at 3", T, || {
        r.alice.contact("bob")["trust"] == 3
    });
    r.start();
    r.keys("work40");
    wait_for("the turn runs", T, || {
        r.file("typed.log").contains(&"work40".to_string())
    });
    let u = r.to_helper("interrupt please", true);
    assert_eq!(u["urgent"], true, "bob's node sent the flag: {u}");
    // No Escape: the line waits for the turn's Stop hook like any message
    let cont = r.hook_dir().join("continue");
    wait_for("the line is left for the Stop hook", T, || cont.exists());
    std::thread::sleep(Duration::from_secs(10));
    assert!(
        r.file("interrupted.log").is_empty(),
        "a contact at level 3 interrupted the agent"
    );
    assert_eq!(r.file("typed.log"), vec!["work40".to_string()]);
    // It is a normal message: the turn's own end gives the ordinary wake line through the Stop hook
    wait_for(
        "the turn's Stop hook takes the wake line",
        Duration::from_secs(45),
        || r.file("continued.log").contains(&WAKE_BOB.to_string()),
    );
    assert!(r.file("interrupted.log").is_empty());
    let h = r.history_of_bob();
    let last = h.iter().rev().find(|i| i["direction"] == "in").unwrap();
    assert!(last.get("urgent").is_none(), "{last}");
    let audit = r.alice.json(&["log", "bob"]).to_string();
    assert!(
        audit.contains("\"action\":\"urgent\"")
            && audit.contains("\"decision\":\"refused\"")
            && audit.contains("level_3"),
        "{audit}"
    );
    // And the owner's own CLI refuses to send one to a contact below 5 here
    let out = r
        .alice
        .cmd()
        .args([
            "--json",
            "send",
            "--to",
            "agent",
            "--to-agent",
            "x",
            "--urgent",
            "bob",
            "hi",
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("forbidden"),
        "{out:?}"
    );
    r.no_mark_anywhere();
}

/// The PIDs the stand-in started (`spawn`) and its own.
fn spawned(r: &Rig) -> Value {
    let p = r.work.join("spawned.log");
    wait_for("the stand-in started its processes", T, || p.exists());
    serde_json::from_str(&lines(&p)[0]).unwrap()
}

#[test]
fn the_stop_switch_ends_the_agents_processes_and_leaves_others_alive() {
    let Some(r) = Rig::new() else { return };
    r.start();
    r.keys("spawn");
    let s = spawned(&r);
    let pids: Vec<(&str, i64)> = ["cli", "child", "orphan", "daemon"]
        .iter()
        .map(|k| (*k, s[k].as_i64().unwrap()))
        .collect();
    for (k, p) in &pids {
        assert!(!gone(*p), "{k} {p} runs before the stop");
    }
    // A process of the same user that has nothing to do with the agent
    let mut unrelated = Command::new("sleep").arg("1003").spawn().unwrap();
    let out = r
        .alice
        .cmd()
        .args(["--json", "agent", "stop", "helper"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    let v = last_json(&out.stdout);
    assert_eq!(
        (v["type"].as_str(), v["how"].as_str()),
        (Some("agent_stopped"), Some("terminal")),
        "{v}"
    );
    assert_eq!(v["left"], 0, "{v}");
    assert!(v["processes"].as_u64().unwrap() >= 5, "{v}");
    for (k, p) in &pids {
        #[cfg(target_os = "macos")]
        if *k == "daemon" {
            // macOS has no subreaper: a daemon in its own session whose parent exited is launchd's
            continue;
        }
        wait_for(&format!("{k} {p} stopped"), Duration::from_secs(5), || {
            gone(*p)
        });
    }
    assert!(
        unrelated.try_wait().unwrap().is_none(),
        "the unrelated process lives"
    );
    let _ = unrelated.kill();
    let _ = unrelated.wait();
    // The session ended with its processes; the agent event says who stopped it
    wait_for("the session's end is recorded", T, || {
        r.hook_dir().join("exit").exists()
    });
    let (_, l) = r.session(&["list"]);
    assert_eq!(l["sessions"][0]["running"], false, "{l}");
    // Nothing runs any more: a second stop says so
    let v = r.alice.json(&["agent", "stop", "helper"]);
    assert_eq!(v["how"], "none", "{v}");
}

#[test]
fn an_own_computer_stops_an_agent_over_the_link() {
    let Some(r) = Rig::new() else { return };
    r.start();
    r.keys("spawn");
    let s = spawned(&r);
    wait_for("bob learns alice can stop agents", T, || {
        r.bob.json(&["devices"])["devices"][0]["stop_agents"] == true
    });
    let v = r.bob.json(&["devices", "stop-agent", "alice", "helper"]);
    assert_eq!(
        (v["type"].as_str(), v["contact"].as_str(), v["how"].as_str()),
        (Some("agent_stopped"), Some("alice"), Some("terminal")),
        "{v}"
    );
    for k in ["cli", "child", "orphan"] {
        let p = s[k].as_i64().unwrap();
        wait_for(&format!("{k} {p} stopped"), Duration::from_secs(5), || {
            gone(p)
        });
    }
    // Both audit logs say it
    assert!(
        r.alice
            .json(&["log", "bob"])
            .to_string()
            .contains("agent_stop")
    );
    assert!(
        r.bob
            .json(&["log", "alice"])
            .to_string()
            .contains("agent_stop")
    );
    // A computer alice does not have at ∞ cannot ask: refused before anything is decrypted
    r.alice.owner_json(&["trust", "bob", "4"]);
    wait_for("alice has bob at 4", T, || {
        r.alice.contact("bob")["trust"] == 4
    });
    let out = r
        .bob
        .cmd()
        .args(["--json", "devices", "stop-agent", "alice", "helper"])
        .output()
        .unwrap();
    assert!(!out.status.success(), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("forbidden"),
        "{out:?}"
    );
}
