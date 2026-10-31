// SPDX-License-Identifier: AGPL-3.0-only
//! Agent wake, v0.2 (SPEC §11): two real `antennad` daemons; the agent is a fake script that prints
//! `claude -p --output-format stream-json` events in chunks with delays (the real `claude` is never called in tests: it
//! would use the owner's subscription). A contact writes → the daemon wakes the agent in a sandbox → the agent reads
//! the inbox with its token → the reply reaches the contact in chunks → the final message is in history, verification
//! is green. Also: level 2 gets the final message only; a secret cuts the stream; an agent crash gives "interrupted";
//! forbidden flags; time limit; an agent that replies itself; the sandbox does not allow writes outside what is
//! allowed.
//!
//! Run: `cargo test -p antenna-cli --test wake -- --nocapture` (from the workspace root). The sandbox needs Linux
//! (bwrap, Landlock) or macOS (Seatbelt, D-P-13); "Landlock only" tests skip themselves outside Linux.

#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

/// The fake agent: the first argument is the scenario, the last is the daemon's prompt.
const FAKE_AGENT: &str = r#"#!/bin/bash
mode="$1"
prompt="${@: -1}"
emit() { printf '%s\n' "$1"; }
delta() {
  local t="${1//\\/\\\\}"; t="${t//\"/\\\"}"
  emit "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$t\"}},\"parent_tool_use_id\":null}"
}
if [ "$mode" = mcp ]; then
  # Like Claude Code: `antenna mcp` is a child of the agent (bound to the parent inside the sandbox tree), reading via MCP
  inbox=$( { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_inbox","arguments":{}}}'; sleep 2; } | antenna mcp 2>&1 )
  text=$(printf '%s' "$inbox" | grep -o 'You asked over MCP' | head -n1)
else
  inbox=$(antenna --json inbox 2>&1)
  text=$(printf '%s' "$inbox" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p' | head -n1)
fi
who=$(antenna --json session 2>/dev/null | sed -n 's/.*"agent":"\([^"]*\)".*/\1/p' | head -n1)
leak=no
case "$prompt" in *"$text"*) [ -n "$text" ] && leak=yes;; esac
if [ "$mode" = plain ]; then
  antenna --json send "$ANTENNA_WAKE_CONTACT" "plain reply to: $text" >/dev/null 2>&1
  exit 0
fi
if [ "$mode" = escape ]; then
  r1=denied; ( echo pwned > "$2/CLAUDE.md" ) 2>/dev/null && r1=ALLOWED
  r2=denied; cat "$3/keystore.cbor" >/dev/null 2>&1 && r2=ALLOWED
  r3=ok; ( echo x > "$HOME/ok" && echo y > "$PWD/ok" && echo z > "$TMPDIR/ok" ) 2>/dev/null || r3=FAILED
  r4=denied; ( exec 3<>/dev/tcp/127.0.0.1/"$4" ) 2>/dev/null && r4=ALLOWED
  emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"e1"}},"parent_tool_use_id":null}'
  delta "escape report: claude-md-write=$r1 keystore-read=$r2 own-dirs-write=$r3 direct-tcp=$r4 home=$HOME end of report."
  exit 0
fi
if [ "$mode" = own ]; then
  w=denied; ( mkdir -p "$PWD/target" && echo built > "$PWD/target/out.txt" ) 2>/dev/null && w=ok
  t=$(cat "$TOOL_DIR/tool.txt" 2>/dev/null || echo none)
  tw=denied; ( echo x > "$TOOL_DIR/pwned" ) 2>/dev/null && tw=ALLOWED
  onpath=no; command -v mytool >/dev/null 2>&1 && onpath=yes
  emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"o1"}},"parent_tool_use_id":null}'
  delta "own report: cwd=$PWD write=$w tool=$t tool-write=$tw tool-on-path=$onpath end of report."
  exit 0
fi
emit '{"type":"system","subtype":"init","session_id":"fake"}'
emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}},"parent_tool_use_id":null}'
emit '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"mcp__antenna__read_inbox"}},"parent_tool_use_id":null}'
if [ "$mode" = activity ]; then
  sleep 0.3
  emit '{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"ghp_0123456789abcdefghij0123456789abcdef"}},"parent_tool_use_id":null}'
  sleep 0.3
fi
delta "Hello! I am $who. You wrote: $text. Prompt leak: $leak. Token: ${#MY_TOKEN}. "
for w in This answer is written word by word with a small pause between the words so that the contact sees it grow; do
  delta "$w "
  sleep 0.12
done
if [ "$mode" = secret ]; then
  delta "my key is -----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW -----END OPENSSH PRIVATE KEY----- "
  delta "and more text after the key. "
fi
if [ "$mode" = crash ]; then exit 3; fi
if [ "$mode" = slow ]; then sleep 60; fi
delta "Done."
emit '{"type":"result","subtype":"success","is_error":false,"result":"ignored"}'
"#;

fn agent_script(root: &Path) -> PathBuf {
    let dir = root.join("agent-bin");
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("fake-agent");
    std::fs::write(&p, FAKE_AGENT).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p
}

fn two(root: &Path, net: Net) -> (Node, Node) {
    two_with(root, net, false)
}

/// `landlock_only`: Bob (the agent's node) gets a Landlock-only sandbox (a test flag of the daemon), the fallback mode
/// on a machine that has bwrap.
fn two_with(root: &Path, net: Net, landlock_only: bool) -> (Node, Node) {
    let mut a = Node::new(root, "alice", net.clone());
    let mut b = Node::new(root, "bob", net);
    if landlock_only {
        b.extra_args.push("--wake-landlock-only".into());
    }
    a.start();
    b.start();
    a.init();
    b.init();
    (a, b)
}

fn events(n: &Node) -> Proc {
    let mut c = n.cmd();
    c.args(["--json", "events"]);
    let mut p = Proc::spawn(c);
    p.event("subscribed", T);
    p
}

fn is_stream(v: &Value, state: &str) -> bool {
    v["kind"] == "message_stream" && v["state"] == state
}

fn texts(n: &Node, contact: &str) -> Vec<String> {
    n.json(&["history", contact, "--limit", "500"])["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"] == "text" && m["direction"] == "in")
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect()
}

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `antenna wake set <contact> --cmd …` for owner `n`.
fn wake_set(n: &Node, contact: &str, cmd: &str, extra: &[&str]) -> std::process::Output {
    let mut a = vec!["wake", "set", contact, "--cmd", cmd];
    a.extend_from_slice(extra);
    n.owner(&a)
}

fn wake_set_ok(n: &Node, contact: &str, cmd: &str, extra: &[&str]) -> Value {
    let out = wake_set(n, contact, cmd, extra);
    assert!(out.status.success(), "wake set: {out:?}");
    last_json(&out.stdout)
}

fn sandbox_kind(n: &Node) -> String {
    n.json(&["wake", "list"])["sandbox"]
        .as_str()
        .unwrap()
        .to_string()
}

/// The main scenario: a contact writes → the sandboxed agent reads with its token → reply in chunks → final,
/// verification.
#[test]
fn contact_writes_agent_wakes_and_the_reply_streams_back() {
    main_scenario(false);
}

/// The same in the fallback sandbox mode (Landlock only, no bwrap), as users without bubblewrap will have it.
#[test]
fn contact_writes_agent_wakes_and_the_reply_streams_back_landlock_only() {
    if !landlock_available() {
        println!("SKIP: Landlock ABI >= 4 is not available");
        return;
    }
    main_scenario(true);
}

fn landlock_available() -> bool {
    antenna_core::sandbox::probe().landlock_abi >= 4
}

fn main_scenario(landlock_only: bool) {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two_with(root.path(), Net::Local, landlock_only);
    pair(&a, &b, 3);
    let rule = wake_set_ok(
        &b,
        "alice",
        &format!("{} reply --output-format stream-json", script.display()),
        &["--timeout", "60s"],
    );
    assert_eq!(rule["type"], "wake");
    let r0 = &rule["rules"][0];
    assert_eq!(r0["agent"], "wake-alice");
    assert_eq!(r0["mode"], "claude_stream");
    let kind = sandbox_kind(&b);
    println!("WAKE sandbox: {kind} — {}", rule["sandbox_detail"]);
    let mut ev = events(&a);
    let mut bev = events(&b);
    let t0 = Instant::now();
    assert_eq!(a.send("bob", "what is two plus two")["status"], "delivered");
    let first = ev.wait_for("first reply chunk", Duration::from_secs(60), |v| {
        is_stream(v, "streaming")
            && v["direction"] == "in"
            && v["delta"].as_str().is_some_and(|d| !d.is_empty())
    });
    let first_ms = t0.elapsed().as_millis();
    let sid = first["stream_id"].as_str().unwrap().to_string();
    let fin = ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    let total_ms = t0.elapsed().as_millis();
    assert_eq!(fin["stream_id"], sid.as_str());
    assert_eq!(fin["end"], "done");
    let chunks: Vec<&Value> = ev
        .seen
        .iter()
        .filter(|v| {
            is_stream(v, "streaming")
                && v["stream_id"] == sid.as_str()
                && v["delta"].as_str().is_some_and(|d| !d.is_empty())
        })
        .collect();
    assert!(chunks.len() >= 5, "reply came in {} pieces", chunks.len());
    let live: String = chunks.iter().filter_map(|v| v["delta"].as_str()).collect();
    let n_chunks = chunks.len();
    ev.wait_for("final message", T, |v| {
        v["kind"] == "message" && v["message"]["id"] == fin["message_id"]
    });
    let reply = texts(&a, "bob").last().unwrap().clone();
    assert!(
        reply.starts_with(&live),
        "live text is the start of the final: {live:?} / {reply:?}"
    );
    assert!(reply.contains("I am wake-alice"), "{reply}");
    assert!(reply.contains("You wrote: what is two plus two"), "{reply}");
    // The contact sees the wake agent as "bob / wake", without the label Bob saved Alice under (PROTOCOL §21);
    // receipts in the shared history carry the same name.
    let h = a.json(&["history", "bob", "--limit", "500"]);
    let msgs = h["messages"].as_array().unwrap();
    let fin_msg = msgs.iter().find(|m| m["id"] == fin["message_id"]).unwrap();
    assert_eq!(fin_msg["via_agent"], "wake", "{fin_msg}");
    for m in msgs {
        if let Some(actor) = m["receipt"]["actor"].as_str() {
            assert!(
                !actor.contains("alice"),
                "receipt actor leaks the label: {m}"
            );
        }
    }
    assert!(
        reply.contains("Prompt leak: no"),
        "the contact's text must not be in the prompt: {reply}"
    );
    assert!(
        reply.contains("Token: 0."),
        "no secret env unless set: {reply}"
    );
    assert!(reply.ends_with("Done."), "{reply}");
    // At the agent's owner: the wake event, its own stream (`out`), the run in the log.
    bev.wait_for("wake finished", T, |v| {
        v["kind"] == "wake" && v["state"] == "finished"
    });
    assert!(
        bev.seen
            .iter()
            .any(|v| is_stream(v, "streaming") && v["direction"] == "out")
    );
    let list = b.json(&["wake", "list"]);
    let last = &list["rules"][0]["last"];
    assert_eq!(last["outcome"], "ok", "{list}");
    assert_eq!(last["exit_code"], 0);
    let log = b.json(&["log", "alice"]);
    assert!(log.to_string().contains("\"action\":\"wake\""), "{log}");
    // History verification is green on both sides.
    let va = a.json(&["verify", "bob"])["status"].clone();
    let vb = b.json(&["verify", "alice"])["status"].clone();
    assert_eq!(va["state"], "verified", "{va}");
    assert_eq!(vb["state"], "verified", "{vb}");
    assert_eq!(va["fingerprint"], vb["fingerprint"]);
    println!(
        "WAKE: first reply chunk at the contact {first_ms} ms after its send; final {total_ms} ms; {n_chunks} live pieces; sandbox {kind}"
    );
}

/// A secret environment variable (`--secret-env`, e.g. `CLAUDE_CODE_OAUTH_TOKEN`) reaches only the agent; `wake list`
/// shows only the name; reserved names (`PATH`, `ANTENNA_*`, `*_PROXY`) are refused.
#[test]
fn secret_env_reaches_the_agent_and_is_not_shown() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    let cmd = format!("{} reply --output-format stream-json", script.display());
    let bad = b.x_stdin(
        &[
            "--json",
            "wake",
            "set",
            "alice",
            "--cmd",
            &cmd,
            "--secret-env",
            "HTTPS_PROXY",
            "--password-stdin",
        ],
        &format!("{}\nhttp://evil\n", b.password),
    );
    assert!(!bad.status.success(), "{bad:?}");
    let out = b.x_stdin(
        &[
            "--json",
            "wake",
            "set",
            "alice",
            "--cmd",
            &cmd,
            "--secret-env",
            "MY_TOKEN",
            "--password-stdin",
        ],
        &format!("{}\nsk-test-123\n", b.password),
    );
    assert!(out.status.success(), "{out:?}");
    let list = b.json(&["wake", "list"]);
    assert_eq!(
        list["rules"][0]["secret_env"],
        serde_json::json!(["MY_TOKEN"])
    );
    assert!(!list.to_string().contains("sk-test-123"));
    let mut ev = events(&a);
    a.send("bob", "hi");
    ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    let reply = texts(&a, "bob").last().unwrap().clone();
    assert!(reply.contains("Token: 11."), "{reply}");
}

/// PG-17: the own-machine profile. For a contact at trust level 5 (the owner's own computer) the agent works in the
/// owner's project folder (writable, its working folder) with a toolchain it reads (its `bin` on the PATH) and plain
/// environment variables; it cannot write into the toolchain. Below level 5 the daemon refuses the profile, and a
/// folder with the daemon's data is never given.
#[test]
fn an_own_computer_agent_works_in_the_project_with_its_toolchain() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    let tools = root.path().join("toolchain");
    std::fs::create_dir_all(tools.join("bin")).unwrap();
    std::fs::write(tools.join("tool.txt"), "TOOLMARK").unwrap();
    std::fs::write(tools.join("bin/mytool"), "#!/bin/sh\necho tool\n").unwrap();
    std::fs::set_permissions(
        tools.join("bin/mytool"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let project = root.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let (tools_s, project_s) = (
        tools.to_str().unwrap().to_string(),
        project.to_str().unwrap().to_string(),
    );
    let env = format!("TOOL_DIR={tools_s}");
    let cmd = format!("{} own --output-format stream-json", script.display());
    let profile = [
        "--project",
        project_s.as_str(),
        "--tool-path",
        tools_s.as_str(),
        "--env",
        env.as_str(),
    ];
    let out = wake_set(&b, "alice", &cmd, &profile);
    assert!(!out.status.success(), "level 3 gets no project: {out:?}");
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("trust level 5"),
        "{out:?}"
    );
    b.owner_json(&["trust", "alice", "5", "--yes"]);
    let data = b.dir.to_str().unwrap().to_string();
    let out = wake_set(&b, "alice", &cmd, &["--project", &data]);
    assert!(
        !out.status.success(),
        "the daemon's data as a project: {out:?}"
    );
    let out = wake_set(&b, "alice", &cmd, &["--env", "LD_PRELOAD=/tmp/x.so"]);
    assert!(!out.status.success(), "a loader variable: {out:?}");
    wake_set_ok(&b, "alice", &cmd, &profile);
    let rule = b.json(&["wake", "list"])["rules"][0].clone();
    let real_project = project.canonicalize().unwrap();
    assert_eq!(rule["project"], real_project.to_str().unwrap(), "{rule}");
    assert_eq!(rule["env"][0], env.as_str(), "{rule}");
    let mut ev = events(&a);
    assert_eq!(a.send("bob", "build it")["status"], "delivered");
    ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    let reply = texts(&a, "bob").last().unwrap().clone();
    println!("OWN MACHINE: {reply}");
    for want in [
        format!("cwd={}", real_project.display()),
        "write=ok".into(),
        "tool=TOOLMARK".into(),
        "tool-write=denied".into(),
        "tool-on-path=yes".into(),
    ] {
        assert!(reply.contains(&want), "{want} in {reply}");
    }
    assert_eq!(
        std::fs::read_to_string(project.join("target/out.txt")).unwrap(),
        "built\n"
    );
    assert!(!tools.join("pwned").exists());
}

/// Flags that remove the agent's permission checks or its sandbox, and resuming past sessions, are refused (SPEC §11).
#[test]
fn forbidden_flags_are_rejected() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    for cmd in [
        format!("{} --dangerously-skip-permissions", script.display()),
        format!("{} --permission-mode bypassPermissions", script.display()),
        format!(
            "{} -c sandbox_mode=\"danger-full-access\"",
            script.display()
        ),
        format!("{} --yolo", script.display()),
        format!("{} --resume abc", script.display()),
    ] {
        let out = wake_set(&b, "alice", &cmd, &[]);
        assert_eq!(out.status.code(), Some(77), "{cmd}: {out:?}");
        let v = last_json(&out.stdout);
        assert_eq!(v["error"], "denied", "{cmd}: {v}");
    }
    // Without the owner password the rule is not set.
    let out = b.x(&["--json", "wake", "set", "alice", "--cmd", true_bin()]);
    assert!(!out.status.success());
    assert!(
        b.json(&["wake", "list"])["rules"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

/// The agent crashed in the middle of a reply: the contact gets an "interrupted" final message with the text received.
#[test]
fn agent_crash_gives_an_interrupted_final() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    wake_set_ok(
        &b,
        "alice",
        &format!("{} crash --output-format stream-json", script.display()),
        &[],
    );
    let mut ev = events(&a);
    a.send("bob", "please answer");
    let fin = ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    assert_eq!(fin["end"], "interrupted");
    wait_until("interrupted reply in history", T, || {
        texts(&a, "bob")
            .last()
            .is_some_and(|t| t.ends_with("[interrupted]") && t.contains("You wrote: please answer"))
    });
    let list = b.json(&["wake", "list"]);
    assert_eq!(list["rules"][0]["last"]["outcome"], "failed", "{list}");
    assert_eq!(list["rules"][0]["last"]["exit_code"], 3);
}

/// Time limit: the agent is killed, the started reply becomes an "interrupted" final message.
#[test]
fn timeout_stops_the_agent() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    wake_set_ok(
        &b,
        "alice",
        &format!("{} slow --output-format stream-json", script.display()),
        &["--timeout", "6s"],
    );
    let mut ev = events(&a);
    a.send("bob", "take your time");
    let fin = ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    assert_eq!(fin["end"], "interrupted");
    wait_until("timeout recorded", T, || {
        b.json(&["wake", "list"])["rules"][0]["last"]["outcome"] == "timeout"
    });
}

/// Level 2: the agent's reply arrives as the final message only (no live view).
#[test]
fn level_2_contact_gets_only_the_final_reply() {
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::LocalRelay(relay.url.clone()));
    pair(&a, &b, 2);
    wake_set_ok(
        &b,
        "alice",
        &format!("{} reply --output-format stream-json", script.display()),
        &[],
    );
    let mut ev = events(&a);
    a.send("bob", "hello agent");
    ev.wait_for("reply message", Duration::from_secs(60), |v| {
        v["kind"] == "message"
            && v["message"]["direction"] == "in"
            && v["message"]["text"]
                .as_str()
                .is_some_and(|t| t.contains("You wrote: hello agent"))
    });
    assert!(
        !ev.seen.iter().any(|v| v["kind"] == "message_stream"),
        "level 2 must not see the stream"
    );
}

/// A secret in the agent's reply: the stream is cut at the contact, the final message waits for approval by the agent's
/// owner; once approved it goes out by itself and the contact matches it by the stream salt.
#[test]
fn a_secret_in_the_agent_reply_cuts_the_stream() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    wake_set_ok(
        &b,
        "alice",
        &format!("{} secret --output-format stream-json", script.display()),
        &[],
    );
    let mut ev = events(&a);
    a.send("bob", "show me");
    let cut = ev.wait_for("cut", Duration::from_secs(60), |v| {
        is_stream(v, "interrupted")
    });
    assert_eq!(cut["reason"], "cut");
    let live: String = ev
        .seen
        .iter()
        .filter(|v| is_stream(v, "streaming"))
        .filter_map(|v| v["delta"].as_str())
        .collect();
    assert!(!live.contains("PRIVATE KEY"), "{live}");
    // The agent's owner sees the request and approves it.
    let mut id = None;
    wait_until("approval request", T, || {
        let v = b.json(&["approvals"]);
        id = v["approvals"][0]["id"].as_str().map(String::from);
        id.is_some()
    });
    b.owner_json(&["approve", id.as_deref().unwrap()]);
    let fin = ev.wait_for("final after approval", T, |v| is_stream(v, "final"));
    assert_eq!(fin["stream_id"], cut["stream_id"]);
}

/// An agent that replies itself (not stream-json): the daemon only wakes it, the reply is a regular `antenna send`.
#[test]
fn a_plain_agent_replies_by_itself() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    let rule = wake_set_ok(&b, "alice", &format!("{} plain", script.display()), &[]);
    assert_eq!(rule["rules"][0]["mode"], "plain");
    // v6 (CONTROL §20): what Alice addresses to another of Bob's agents neither wakes the wake agent nor reaches it;
    // what she writes to Bob in person does (the wake agent answers him)
    a.json(&[
        "send",
        "--to-agent",
        "builder",
        "bob",
        "for the builder only",
    ]);
    a.send("bob", "ping from alice");
    wait_until("plain reply", Duration::from_secs(60), || {
        texts(&a, "bob")
            .iter()
            .any(|t| t == "plain reply to: ping from alice")
    });
    assert!(
        !texts(&a, "bob")
            .iter()
            .any(|t| t.contains("reply to: for the builder")),
        "{:?}",
        texts(&a, "bob")
    );
    // The reply is the wake agent's, to the person who wrote
    let h = a.json(&["history", "bob", "--limit", "50"]);
    let r = h["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["text"] == "plain reply to: ping from alice")
        .unwrap()
        .clone();
    assert_eq!(
        (r["via_agent"].as_str(), r["to"].as_str()),
        (Some("wake"), Some("person")),
        "{r}"
    );
    // Turned off: no more wakes, the dedicated agent is removed.
    b.json(&["wake", "off", "alice"]);
    assert!(
        b.json(&["wake", "list"])["rules"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let agents = b.json(&["agent", "list"]);
    assert!(!agents.to_string().contains("wake-alice"), "{agents}");
}

/// Sandbox: the agent does not write to the owner's "memory/CLAUDE.md" and does not read the daemon data directory
/// (keystore); it writes only to its own HOME/working folder/TMPDIR; no direct TCP around the proxy.
#[test]
fn the_sandbox_keeps_the_agent_inside() {
    escape_scenario(false);
}

/// The same in the fallback mode (Landlock only).
#[test]
fn the_sandbox_keeps_the_agent_inside_landlock_only() {
    if !landlock_available() {
        println!("SKIP: Landlock ABI >= 4 is not available");
        return;
    }
    escape_scenario(true);
}

fn escape_scenario(landlock_only: bool) {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two_with(root.path(), Net::Local, landlock_only);
    pair(&a, &b, 3);
    let owner_cfg = root.path().join("owner-home").join(".claude");
    std::fs::create_dir_all(&owner_cfg).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    wake_set_ok(
        &b,
        "alice",
        &format!(
            "{} escape {} {} {port} --output-format stream-json",
            script.display(),
            owner_cfg.display(),
            b.dir.display()
        ),
        &[],
    );
    let mut ev = events(&a);
    a.send("bob", "try to escape");
    ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    let mut report = String::new();
    wait_until("escape report", T, || {
        report = texts(&a, "bob").last().cloned().unwrap_or_default();
        report.contains("escape report")
    });
    println!("ESCAPE REPORT ({}): {report}", sandbox_kind(&b));
    assert!(report.contains("claude-md-write=denied"), "{report}");
    assert!(report.contains("keystore-read=denied"), "{report}");
    assert!(report.contains("own-dirs-write=ok"), "{report}");
    assert!(report.contains("direct-tcp=denied"), "{report}");
    assert!(!owner_cfg.join("CLAUDE.md").exists());
}

/// The agent reads through MCP, like Claude Code: `antenna mcp` inside the sandbox binds the run token to its parent.
/// The agent anchor (the sandbox root) is already its ancestor, so there is no rebinding and no refusal.
#[test]
fn the_agent_reads_over_mcp_inside_the_sandbox() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    wake_set_ok(
        &b,
        "alice",
        &format!("{} mcp --output-format stream-json", script.display()),
        &[],
    );
    let mut ev = events(&a);
    a.send("bob", "You asked over MCP");
    ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    let reply = texts(&a, "bob").last().unwrap().clone();
    assert!(reply.contains("You wrote: You asked over MCP"), "{reply}");
}

/// "What the agent is doing" (`activity`) is visible to level 4–5 contacts; the line goes through the secret scanner
/// like text: a "tool" name containing a token does not reach the contact.
#[test]
fn activity_reaches_level_4_and_passes_the_secret_scanner() {
    let root = tempfile::tempdir().unwrap();
    let script = agent_script(root.path());
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 4);
    wake_set_ok(
        &b,
        "alice",
        &format!("{} activity --output-format stream-json", script.display()),
        &[],
    );
    let mut ev = events(&a);
    a.send("bob", "what are you doing");
    ev.wait_for("final", Duration::from_secs(60), |v| is_stream(v, "final"));
    assert!(
        ev.seen
            .iter()
            .any(|v| is_stream(v, "streaming") && v["activity"] == "tool:mcp__antenna__read_inbox"),
        "level 4 sees what the agent is doing: {:?}",
        ev.seen
    );
    assert!(
        !ev.seen.iter().any(|v| v.to_string().contains("ghp_0123")),
        "a secret in the activity must not reach the contact"
    );
}
