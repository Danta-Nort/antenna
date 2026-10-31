// SPDX-License-Identifier: AGPL-3.0-only
//! `agent_watch` (D-103, CONTROL §23): after an unattended update nobody has signed in to the window, yet the window must
//! learn that a Code mode agent it restored has something to read. The daemon gives the app that started the agent
//! (a strict ancestor of the agent's bound process) that agent's own facts, without an owner session, and nothing else;
//! any other process is refused. Real `antennad` and `antenna`; the test process plays the window (it starts the agent's
//! process tree).
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    io::{BufRead, BufReader, Write},
    os::unix::{net::UnixStream, process::CommandExt},
    path::Path,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

use common::*;
use serde_json::{Value, json};

const CLIENT: &str = r#"
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall((json.dumps({"hello": {"proto": "x-control/7", "role": "owner"}}) + "\n" +
           json.dumps({"req": {"cmd": "agent_watch", "agent": sys.argv[2]}}) + "\n").encode())
f = s.makefile()
print(f.readline().strip())
print(f.readline().strip())
"#;

/// The agent's MCP host: `sh`, with `antenna mcp` as its child bound to it (D-28); `sh` stays alive. Inside its tree, a
/// process that asks to watch the agent writes what it got to `inside_out`.
fn agent_tree(n: &Node, token: &str, inside_out: &Path) -> Child {
    let script = r#"
        sleep 60 | ANTENNA_AGENT_TOKEN="$TOK" "$X_BIN" --data-dir "$X_DIR" mcp >/dev/null 2>&1 &
        sleep 2
        python3 -c "$CLIENT" "$X_DIR/antennad.sock" claude > "$INSIDE" 2>&1
        wait
    "#;
    Command::new("sh")
        .clean_env()
        .arg("-c")
        .arg(script)
        .env("X_BIN", x_bin())
        .env("X_DIR", &n.dir)
        .env("TOK", token)
        .env("CLIENT", CLIENT)
        .env("INSIDE", inside_out)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        // Its own process group: the test ends the whole tree by its PID, never by a pattern.
        .process_group(0)
        .spawn()
        .unwrap()
}

fn end_tree(c: &mut Child) {
    if let Some(p) = rustix::process::Pid::from_raw(c.id() as i32) {
        let _ = rustix::process::kill_process_group(p, rustix::process::Signal::KILL);
    }
    let _ = c.wait();
}

struct Watch {
    lines: BufReader<UnixStream>,
}

impl Watch {
    /// The test process (the agent tree's parent: the "window") watches the agent: hello and the first reply.
    fn open(n: &Node, agent: &str) -> (Self, Value, Value) {
        let mut s = UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        writeln!(
            s,
            "{}",
            json!({"hello": {"proto": "x-control/7", "role": "owner"}})
        )
        .unwrap();
        writeln!(
            s,
            "{}",
            json!({"req": {"cmd": "agent_watch", "agent": agent}})
        )
        .unwrap();
        let mut w = Watch {
            lines: BufReader::new(s),
        };
        let hello = w.next(Duration::from_secs(10)).unwrap();
        let first = w.next(Duration::from_secs(10)).unwrap();
        (w, hello, first)
    }

    fn next(&mut self, within: Duration) -> Option<Value> {
        let t = Instant::now();
        let mut l = String::new();
        while t.elapsed() < within {
            match self.lines.read_line(&mut l) {
                Ok(0) => return None,
                Ok(_) => return serde_json::from_str(&l).ok(),
                Err(_) => continue,
            }
        }
        None
    }

    /// Every event within `within`.
    fn drain(&mut self, within: Duration) -> Vec<Value> {
        let t = Instant::now();
        let mut out = Vec::new();
        while t.elapsed() < within {
            if let Some(v) = self.next(Duration::from_millis(500)) {
                out.push(v);
            }
        }
        out
    }
}

fn bound(n: &Node, agent: &str) -> bool {
    n.json(&["agent", "list"])["agents"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a["name"] == agent && a["session"]["bound_alive"] == true)
}

#[test]
fn only_the_app_that_started_the_agent_gets_its_own_facts() {
    let root = tempfile::tempdir().unwrap();
    let mut a = Node::new(root.path(), "alice", Net::Local);
    a.start();
    a.init();
    let mut b = Node::new(root.path(), "bob", Net::Local);
    b.start();
    b.init();
    pair(&a, &b, 3);
    let tok = a.agent_add("claude", &["--local-level", "0", "--everyone"]);
    let inside = root.path().join("inside.txt");
    let mut tree = agent_tree(&a, &tok, &inside);
    let t = Instant::now();
    while !bound(&a, "claude") {
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "the agent never bound"
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    // Before the agent runs another agent's name, and a name that does not exist, are refused.
    let (_, _, r) = Watch::open(&a, "nobody");
    assert_eq!(r["err"]["code"], "not_found", "{r}");

    // The window (an ancestor of the bound process), with no owner session at all.
    let (mut w, hello, first) = Watch::open(&a, "claude");
    assert_eq!(
        hello["hello_ok"]["session"], "none",
        "no owner session: {hello}"
    );
    assert_eq!(first["event"]["kind"], "subscribed", "{first}");
    assert_eq!(first["event"]["role"], "agent", "{first}");

    // A message to the person is not the agent's; one to everyone is: only its fact arrives, without the text.
    b.send("alice", "for the person only");
    b.send_to_everyone("alice", "for everyone, the agent too");
    // An owner-only event meanwhile: another agent is added.
    a.agent_add("other", &["--local-level", "0"]);
    let evs = w.drain(Duration::from_secs(6));
    let kinds: Vec<&str> = evs
        .iter()
        .filter_map(|e| e["event"]["kind"].as_str())
        .collect();
    let facts: Vec<&Value> = evs
        .iter()
        .filter(|e| e["event"]["kind"] == "message_fact")
        .collect();
    assert_eq!(
        facts.len(),
        1,
        "one fact, for the message the agent reads: {evs:?}"
    );
    assert_eq!(facts[0]["event"]["contact"], "bob");
    assert_eq!(
        facts[0]["event"]["chars"],
        "for everyone, the agent too".chars().count()
    );
    let all = serde_json::to_string(&evs).unwrap();
    assert!(
        !all.contains("for everyone") && !all.contains("for the person"),
        "no text: {all}"
    );
    assert!(
        !kinds
            .iter()
            .any(|k| ["message", "agent", "invite", "update_auto"].contains(k)),
        "no owner events: {kinds:?}"
    );

    // A watch that starts after the message arrived gets its fact first, as long as the agent has not read it (D-108:
    // a session started later still wakes its agent); the fact consumes nothing, so the next watch gets it again.
    for _ in 0..2 {
        let (mut w2, _, first) = Watch::open(&a, "claude");
        assert_eq!(first["event"]["kind"], "subscribed", "{first}");
        let backlog: Vec<Value> = w2
            .drain(Duration::from_secs(2))
            .into_iter()
            .filter(|e| e["event"]["kind"] == "message_fact")
            .collect();
        assert_eq!(
            backlog.len(),
            1,
            "the unread message the agent reads: {backlog:?}"
        );
        assert_eq!(backlog[0]["event"]["id"], facts[0]["event"]["id"]);
        assert!(
            !serde_json::to_string(&backlog)
                .unwrap()
                .contains("for everyone"),
            "no text"
        );
    }

    // Any other process of the same user: refused. A sibling (not an ancestor of the agent's process) ...
    let out = Command::new("python3")
        .arg("-c")
        .arg(CLIENT)
        .arg(a.dir.join("antennad.sock"))
        .arg("claude")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let reply: Value =
        serde_json::from_str(text.lines().nth(1).unwrap_or("null")).unwrap_or(Value::Null);
    assert_eq!(
        reply["err"]["code"], "forbidden",
        "an outsider is refused: {text}"
    );
    // ... and a process inside the agent's own tree, which is the agent (D-28): it has no such command.
    let t = Instant::now();
    while std::fs::read_to_string(&inside)
        .unwrap_or_default()
        .lines()
        .count()
        < 2
    {
        assert!(
            t.elapsed() < Duration::from_secs(20),
            "the inside client did not answer"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    let text = std::fs::read_to_string(&inside).unwrap();
    let mut lines = text.lines();
    let hello: Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    let reply: Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    assert_eq!(hello["hello_ok"]["role"], "agent", "{text}");
    assert_eq!(reply["err"]["code"], "unknown_command", "{text}");

    // The agent's process ends: the watch ends with it.
    end_tree(&mut tree);
    let t = Instant::now();
    loop {
        match w.next(Duration::from_secs(1)) {
            Some(v) if v.get("err").is_some() => {
                assert_eq!(v["err"]["code"], "forbidden", "{v}");
                break;
            }
            None if t.elapsed() > Duration::from_secs(20) => panic!("the watch did not end"),
            _ => {}
        }
    }
    let (_, _, r) = Watch::open(&a, "claude");
    assert_eq!(r["err"]["code"], "forbidden", "not running any more: {r}");
}
