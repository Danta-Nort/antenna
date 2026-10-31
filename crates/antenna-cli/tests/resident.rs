// SPDX-License-Identifier: AGPL-3.0-only
//! Resident agents (D-93): two real `antennad` daemons; the agent is a fake script that speaks Claude Code's
//! stream-json on stdin and stdout and keeps a turn counter per session in its HOME, the way Claude Code keeps a
//! transcript (`--session-id` starts a session, `--resume` continues it, a reused or missing ID is an error). The real
//! `claude` is never called here: it would use the owner's subscription.
//!
//! Covered: several messages reach the same process and the context (the counter) carries on; an idle process uses
//! no CPU; a crash and a daemon restart resume the same session; messages during a turn wait and arrive as one turn;
//! the owner interrupts a turn; owner turns are labelled and stay with the owner unless sent to the contact; the
//! sandbox still holds; the agent has no owner commands; compacting before the cache goes cold, the idle stop, and a
//! reset to a clean session.
//!
//! Run: `cargo test -p antenna-cli --test resident -- --nocapture` (from the workspace root).

#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

/// The fake resident agent. The first argument is a scenario word, the next three are paths and a port for the
/// sandbox probe; the daemon adds `--input-format stream-json` and `--session-id`/`--resume`. Written for bash 3.2
/// (macOS) too: no fractional `read -t`, no `${x,,}`.
const FAKE_RESIDENT: &str = r#"#!/bin/bash
sid=""; how=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id) sid="$a"; how=new;; --resume) sid="$a"; how=resume;; esac
  prev="$a"
done
state="$HOME/.fake-resident"
mkdir -p "$state"
[ -n "$sid" ] || { echo "no session id" >&2; exit 2; }
f="$state/$sid"
if [ "$how" = new ] && [ -e "$f" ]; then echo "Session ID $sid is already in use" >&2; exit 1; fi
if [ "$how" = resume ] && [ ! -e "$f" ]; then echo "No conversation found with session ID: $sid" >&2; exit 1; fi
[ -e "$f" ] || echo 0 > "$f"
s=$(cat "$state/$sid.starts" 2>/dev/null || echo 0); s=$((s+1)); echo $s > "$state/$sid.starts"
emit() { printf '%s\n' "$1"; }
delta() {
  local t="${1//\\/\\\\}"; t="${t//\"/\\\"}"
  emit "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$t\"}},\"parent_tool_use_id\":null}"
}
usage() { echo "{\"input_tokens\":3,\"output_tokens\":20,\"cache_read_input_tokens\":$(( $1 * 2000 )),\"cache_creation_input_tokens\":500}"; }
emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\"}"
unexpected=no
k=0
while IFS= read -r line; do
  case "$line" in
    *'"type":"control_request"'*) emit '{"type":"control_response","response":{"subtype":"success","request_id":"r"}}'; continue;;
    *'"type":"user"'*) ;;
    *) continue;;
  esac
  case "$line" in
    *'"content":"/compact"'*)
      echo x >> "$state/$sid.compactions"
      emit '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":50000,"post_tokens":1200}}'
      emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$sid\",\"usage\":{\"input_tokens\":0,\"output_tokens\":300,\"cache_read_input_tokens\":50000,\"cache_creation_input_tokens\":0}}"
      continue;;
  esac
  n=$(cat "$f"); n=$((n+1)); echo $n > "$f"
  kind=contact
  case "$line" in *'[Antenna] Your owner writes'*) kind=owner;; esac
  case "$line" in *'Your owner interrupted your previous turn'*) delta "urgent-turn=yes ";; esac
  emit "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\",\"message\":{\"id\":\"m$n\"}},\"parent_tool_use_id\":null}"
  delta "turn=$n session=${sid:0:8} kind=$kind pid=$$ starts=$s how=$how. "
  case "$line" in
    *CRASH-NOW*) delta "crashing now "; exit 3;;
    *SLOW-TURN*)
      i=0; interrupted=no
      while [ $i -lt 6 ]; do
        delta "slow$i "
        if IFS= read -r -t 1 more; then
          case "$more" in
            *'"subtype":"interrupt"'*) emit '{"type":"control_response","response":{"subtype":"success","request_id":"r"}}'; interrupted=yes; break;;
            *'"type":"user"'*) unexpected=yes;;
          esac
        fi
        i=$((i+1))
      done
      if [ $interrupted = yes ]; then
        emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"session_id\":\"$sid\",\"usage\":$(usage $n)}"
        continue
      fi;;
    *PROBE*)
      r1=denied; ( echo pwned > "$2/CLAUDE.md" ) 2>/dev/null && r1=ALLOWED
      r2=denied; cat "$3/keystore.cbor" >/dev/null 2>&1 && r2=ALLOWED
      r3=ok; ( echo x > "$HOME/ok" && echo y > "$PWD/ok" && echo z > "$TMPDIR/ok" ) 2>/dev/null || r3=FAILED
      r4=denied; ( exec 3<>/dev/tcp/127.0.0.1/"$4" ) 2>/dev/null && r4=ALLOWED
      r5=$(env | grep -cE '^(CLAUDECODE|CLAUDE_CODE_|CODEX_|ANTENNA_TEST_MARK)')
      delta "escape report: claude-md-write=$r1 keystore-read=$r2 own-dirs-write=$r3 direct-tcp=$r4 inherited-env=$r5. ";;
    *TRY-OWNER*)
      e() { "$@" 2>/dev/null | sed -n 's/.*"error":"\([a-z_]*\)".*/\1/p' | head -n1; }
      c1=$(e antenna --json wake say "$ANTENNA_WAKE_CONTACT" hello)
      c2=$(e antenna --json wake session "$ANTENNA_WAKE_CONTACT" reset)
      c3=$(e antenna --json trust "$ANTENNA_WAKE_CONTACT" 5)
      c4=$(e env -u ANTENNA_AGENT_TOKEN antenna --json wake session "$ANTENNA_WAKE_CONTACT" stop)
      delta "owner commands: say=$c1 session=$c2 trust=$c3 tokenless=$c4. ";;
  esac
  if [ $kind = contact ]; then
    texts=$(antenna --json inbox 2>&1 | grep -o '"text":"[^"]*"' | sed 's/"text":"//; s/"$//' | tr '\n' '|')
    # Like Claude Code's transcript: what the agent read stays in its HOME
    printf '%s\n' "$texts" >> "$state/$sid.jsonl"
    delta "You wrote: $texts "
  else
    said=$(printf '%s' "$line" | sed 's/.*\\n\\n//; s/".*//')
    delta "Owner said: $said. "
  fi
  delta "unexpected-input=$unexpected. Done."
  emit "{\"type\":\"assistant\",\"message\":{\"id\":\"m$n\",\"usage\":$(usage $n)},\"parent_tool_use_id\":null}"
  # Like Claude Code: `usage` is the turn's own, `total_cost_usd` adds up over the process.
  k=$((k+1))
  emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"$sid\",\"usage\":$(usage $n),\"total_cost_usd\":$(printf '0.%06d' $((k*12500)))}"
done
"#;

fn fake(root: &Path) -> PathBuf {
    let dir = root.join("agent-bin");
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("fake-resident");
    std::fs::write(&p, FAKE_RESIDENT).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p
}

fn two(root: &Path) -> (Node, Node) {
    let mut a = Node::new(root, "alice", Net::Local);
    let mut b = Node::new(root, "bob", Net::Local);
    a.start();
    b.start();
    a.init();
    b.init();
    pair(&a, &b, 3);
    (a, b)
}

fn events(n: &Node) -> Proc {
    let mut c = n.cmd();
    c.args(["--json", "events"]);
    let mut p = Proc::spawn(c);
    p.event("subscribed", T);
    p
}

/// Incoming texts (from the contact) in the history, oldest first.
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

/// `wake set alice --resident --cmd "<fake> <args> --output-format stream-json" <extra>` at Bob's.
fn set_resident(b: &Node, script: &Path, args: &str, extra: &[&str]) -> Value {
    let cmd = format!("{} {args} --output-format stream-json", script.display());
    let mut a = vec!["wake", "set", "alice", "--resident", "--cmd", &cmd];
    a.extend_from_slice(extra);
    let v = b.owner_json(&a);
    assert_eq!(v["rules"][0]["resident"]["state"], "sleeping", "{v}");
    v
}

/// Alice writes and waits for the agent's next reply (a new incoming text containing `marker`).
fn ask(a: &Node, text: &str, marker: &str) -> String {
    let before = texts(a, "bob").len();
    assert_eq!(a.send("bob", text)["status"], "delivered");
    let mut reply = String::new();
    wait_until(
        &format!("reply to {text:?}"),
        Duration::from_secs(60),
        || {
            let t = texts(a, "bob");
            if let Some(r) = t.iter().skip(before).find(|r| r.contains(marker)) {
                reply = r.clone();
                true
            } else {
                false
            }
        },
    );
    reply
}

/// A field `key=value` from the fake agent's reply.
fn field(reply: &str, key: &str) -> String {
    let k = format!("{key}=");
    let i = reply.find(&k).unwrap_or_else(|| panic!("{key} in {reply}"));
    reply[i + k.len()..]
        .split([' ', '.'])
        .next()
        .unwrap()
        .to_string()
}

fn resident(b: &Node) -> Value {
    b.json(&["wake", "list"])["rules"][0]["resident"].clone()
}

/// `antenna wake say alice <text>` at Bob's: the final `resident_turn`.
fn say(b: &Node, args: &[&str]) -> Value {
    let mut a = vec!["wake", "say", "alice"];
    a.extend_from_slice(args);
    let v = b.json(&a);
    assert_eq!(v["type"], "resident_turn", "{v}");
    v
}

/// CPU time (clock ticks) of the fake agent's processes and their sandbox (bwrap, the supervisor): the processes whose
/// command line holds `marker`, and their ancestors up to the daemon.
#[cfg(target_os = "linux")]
fn sandbox_cpu_ticks(marker: &str) -> (usize, u64) {
    let read = |pid: i32| -> Option<(String, i32, u64)> {
        let cmd = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        let cmd = String::from_utf8_lossy(&cmd).replace('\0', " ");
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let rest = &stat[stat.rfind(')')? + 2..];
        let f: Vec<&str> = rest.split_whitespace().collect();
        let ppid = f[1].parse().ok()?;
        let ticks = f[11].parse::<u64>().ok()? + f[12].parse::<u64>().ok()?;
        Some((cmd, ppid, ticks))
    };
    let mut seen = std::collections::BTreeSet::new();
    let mut total = 0;
    for e in std::fs::read_dir("/proc").unwrap().flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        let Some((cmd, _, _)) = read(pid) else {
            continue;
        };
        if !cmd.contains(marker) {
            continue;
        }
        let mut p = pid;
        while let Some((cmd, ppid, ticks)) = read(p) {
            let ours = cmd.contains(marker)
                || cmd.contains("--antenna-wake-exec")
                || cmd.contains("bwrap");
            if !ours {
                break;
            }
            if seen.insert(p) {
                total += ticks;
            }
            p = ppid;
        }
    }
    (seen.len(), total)
}

/// The main scenario: several messages go to one process and the session's context carries on; the idle process uses
/// no CPU; the counters show up in `wake list`.
#[test]
fn messages_reach_one_process_and_the_context_carries_on() {
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let (a, b) = two(root.path());
    let rule = set_resident(&b, &script, "chat", &[]);
    assert_eq!(rule["rules"][0]["mode"], "claude_stream");
    // Defaults of a resident rule: no compacting by the daemon, 60 turns an hour from the contact.
    assert_eq!(rule["rules"][0]["resident"]["compact_idle_secs"], 0);
    assert_eq!(rule["rules"][0]["max_runs_per_hour"], 60);
    let t0 = Instant::now();
    let r1 = ask(&a, "first message", "turn=1");
    let first_ms = t0.elapsed().as_millis();
    let t1 = Instant::now();
    let r2 = ask(&a, "second message", "turn=2");
    let second_ms = t1.elapsed().as_millis();
    let r3 = ask(&a, "third message", "turn=3");
    println!("RESIDENT replies:\n  {r1}\n  {r2}\n  {r3}");
    // One process, one session, one start: the counter is the agent's own context.
    assert_eq!(field(&r1, "pid"), field(&r3, "pid"));
    assert_eq!(field(&r1, "session"), field(&r3, "session"));
    assert_eq!(field(&r3, "starts"), "1");
    assert_eq!(field(&r1, "how"), "new");
    assert_eq!(field(&r1, "kind"), "contact");
    // The turn carried a reference; the agent read the text itself with its token.
    assert!(r1.contains("You wrote: first message|"), "{r1}");
    assert!(r3.contains("You wrote: third message|"), "{r3}");
    assert!(r3.contains("unexpected-input=no"), "{r3}");
    // The reply reaches Alice before Bob's daemon closes the turn: wait for it to be counted (seen busy on a Mac).
    wait_until("the third turn counted", Duration::from_secs(15), || {
        resident(&b)["state"] == "idle"
    });
    let res = resident(&b);
    assert_eq!(res["turns"], 3, "{res}");
    assert_eq!(res["owner_turns"], 0, "{res}");
    assert_eq!(res["starts"], 1, "{res}");
    assert_eq!(res["state"], "idle", "{res}");
    assert_eq!(res["output_tokens"], 60, "{res}");
    assert_eq!(res["cache_read_tokens"], 2000 + 4000 + 6000, "{res}");
    assert_eq!(res["context_tokens"], 3 + 6000 + 500, "{res}");
    assert_eq!(res["cost_micro_usd"], 3 * 12_500, "{res}");
    assert_eq!(
        res["session_id"].as_str().unwrap()[..8],
        field(&r1, "session")
    );
    // The contact's level is the session's ceiling (taint from reading), and it stays.
    assert_eq!(res["ceiling"], 3, "{res}");
    // Idle: the process sleeps in `read` and its sandbox waits; nothing polls.
    #[cfg(target_os = "linux")]
    {
        let marker = script.to_string_lossy().into_owned();
        let (n0, c0) = sandbox_cpu_ticks(&marker);
        std::thread::sleep(Duration::from_secs(3));
        let (n1, c1) = sandbox_cpu_ticks(&marker);
        println!("RESIDENT idle: {n1} processes, CPU ticks {c0} → {c1} over 3 s");
        assert!(n0 >= 1 && n0 == n1, "the process stays: {n0} → {n1}");
        assert!(
            c1 - c0 <= 1,
            "an idle resident agent must not use CPU: {c0} → {c1}"
        );
    }
    // The log has one record per turn; the history verifies on both sides.
    let log = b.json(&["log", "alice"]).to_string();
    assert!(log.contains("turn 3: done"), "{log}");
    let va = a.json(&["verify", "bob"])["status"].clone();
    let vb = b.json(&["verify", "alice"])["status"].clone();
    assert_eq!(va["state"], "verified");
    assert_eq!(va["fingerprint"], vb["fingerprint"]);
    println!(
        "RESIDENT: first reply (process start) {first_ms} ms after the send, second (warm process) {second_ms} ms"
    );
    // What the agent may read (D-91): a message Alice addresses to another of Bob's agents starts no turn, and the
    // resident agent does not read it in the next one.
    a.json(&[
        "send",
        "--to-agent",
        "builder",
        "bob",
        "for the builder only",
    ]);
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(
        resident(&b)["turns"],
        3,
        "no turn for another agent's message"
    );
    let r4 = ask(&a, "fourth message", "turn=4");
    assert!(r4.contains("You wrote: fourth message|"), "{r4}");
    assert!(!r4.contains("builder"), "{r4}");
}

/// A crash in the middle of a turn: the turn ends as interrupted, the next message starts the process again with
/// `--resume` and the same session continues. Then the daemon restarts (as after a reboot): the session resumes again.
#[test]
fn a_crash_and_a_daemon_restart_resume_the_same_session() {
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let (a, mut b) = two(root.path());
    set_resident(&b, &script, "chat", &[]);
    let r1 = ask(&a, "hello", "turn=1");
    let crash = say(&b, &["CRASH-NOW"]);
    assert_eq!(crash["outcome"], "interrupted", "{crash}");
    assert!(
        crash["detail"].as_str().unwrap().contains("code 3"),
        "{crash}"
    );
    let r3 = ask(&a, "are you back", "turn=3");
    println!("RESIDENT after crash: {r3}");
    assert_eq!(field(&r3, "session"), field(&r1, "session"));
    assert_eq!(field(&r3, "how"), "resume");
    assert_eq!(field(&r3, "starts"), "2");
    assert_ne!(field(&r3, "pid"), "", "{r3}");
    // Daemon restart: the session record is in the encrypted DB, the transcript in the agent's HOME.
    b.stop();
    b.start();
    b.unlock();
    let res = resident(&b);
    assert_eq!(res["state"], "sleeping", "{res}");
    let r4 = ask(&a, "and after a restart", "turn=4");
    println!("RESIDENT after daemon restart: {r4}");
    assert_eq!(field(&r4, "session"), field(&r1, "session"));
    assert_eq!(field(&r4, "how"), "resume");
    assert_eq!(field(&r4, "starts"), "3");
    // The reply reaches Alice before Bob's daemon closes the turn and counts it: wait for the count, do not read it once
    // (under load the fourth turn was still open, `turns: 3`).
    wait_until("the fourth turn counted", Duration::from_secs(15), || {
        resident(&b)["turns"] == 4
    });
    let res = resident(&b);
    assert_eq!(res["starts"], 3, "{res}");
    assert_eq!(res["turns"], 4, "{res}");
}

/// Whether any file under `dir` (symbolic links not followed) holds `needle`.
#[cfg(target_os = "linux")]
fn on_disk(dir: &Path, needle: &str) -> bool {
    let Ok(items) = std::fs::read_dir(dir) else {
        return false;
    };
    items.flatten().any(|e| {
        let p = e.path();
        match std::fs::symlink_metadata(&p) {
            Ok(m) if m.is_dir() => on_disk(&p, needle),
            Ok(m) if m.is_file() => std::fs::read(&p)
                .is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle.as_bytes())),
            _ => false,
        }
    })
}

/// PG-24: a sleeping session is not on disk in plain text. While the process runs, its transcript (what it read from
/// the contact) is in its HOME; after the idle stop the daemon keeps it in the encrypted database and nothing under
/// the data directory holds the contact's words; the next message resumes the same session from there. A daemon
/// killed with the process running leaves the files, and the next unlock moves them in. A reset forgets the record.
#[cfg(target_os = "linux")]
#[test]
fn a_sleeping_session_lives_in_the_encrypted_database() {
    const MARK: &str = "PARK-MARK-4b7e19";
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let (a, mut b) = two(root.path());
    set_resident(&b, &script, "chat", &["--idle-stop", "3s"]);
    let mut ev = events(&b);
    let r1 = ask(&a, &format!("remember {MARK}"), "turn=1");
    let dir = b
        .dir
        .join("wake")
        .join("resident")
        .join(&b.contact("alice")["link_id"].as_str().unwrap()[..16]);
    assert!(on_disk(&dir, MARK), "the running session's transcript");
    assert!(resident(&b).get("parked").is_none(), "{}", resident(&b));
    ev.wait_for("idle stop", Duration::from_secs(20), |v| {
        v["kind"] == "wake" && v["state"] == "sleeping"
    });
    wait_until("parked", T, || resident(&b)["parked"] == true);
    let human = String::from_utf8_lossy(&b.x(&["wake", "list"]).stdout).to_string();
    assert!(
        human.contains("parked in the encrypted database"),
        "{human}"
    );
    assert!(!dir.join("home").exists() && !dir.join("work").exists());
    assert!(
        !on_disk(&b.dir, MARK),
        "the contact's words are nowhere under the data directory in plain text"
    );
    let r2 = ask(&a, "and now", "turn=2");
    assert_eq!(field(&r2, "session"), field(&r1, "session"));
    assert_eq!(field(&r2, "how"), "resume");
    assert!(resident(&b).get("parked").is_none(), "{}", resident(&b));
    assert!(on_disk(&dir, MARK), "back in the agent's HOME");

    // A crash of the daemon with the process running: the files stay until the next unlock
    let r = ask(&a, "keep going", "turn=3");
    assert_eq!(field(&r, "how"), "resume");
    b.kill();
    assert!(on_disk(&dir, MARK), "a crash leaves them on disk");
    b.start();
    b.unlock();
    wait_until("parked after the unlock", T, || {
        resident(&b)["parked"] == true
    });
    assert!(!on_disk(&b.dir, MARK));
    let r4 = ask(&a, "after the crash", "turn=4");
    assert_eq!(field(&r4, "session"), field(&r1, "session"));
    assert_eq!(field(&r4, "how"), "resume");

    // A reset ends the session: no record, no files
    let reset = b.owner_json(&["wake", "session", "alice", "reset"]);
    assert_eq!(reset["type"], "resident_session", "{reset}");
    assert!(reset["resident"].get("parked").is_none(), "{reset}");
    assert!(!on_disk(&b.dir, MARK));
}

/// Messages that arrive during a turn wait (nothing is written to the busy agent) and come as one turn; the owner can
/// interrupt a turn, a contact cannot.
#[test]
fn messages_during_a_turn_wait_and_the_owner_can_interrupt() {
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let (a, b) = two(root.path());
    set_resident(&b, &script, "chat", &[]);
    ask(&a, "warm up", "turn=1");
    // A slow owner turn (≈ 6 s); Alice writes twice meanwhile.
    let mut slow = Proc::spawn({
        let mut c = b.cmd();
        c.args(["--json", "wake", "say", "alice", "SLOW-TURN"]);
        c
    });
    slow.wait_for("the slow turn streams", T, |v| {
        v["kind"] == "resident_delta"
    });
    assert_eq!(resident(&b)["state"], "busy");
    a.send("bob", "during one");
    a.send("bob", "during two");
    wait_until("queued", T, || resident(&b)["queued"] == 1);
    let (code, done) = slow.finish(Duration::from_secs(60));
    assert_eq!(code, 0, "{done}");
    assert_eq!(done["outcome"], "done", "{done}");
    assert!(
        done["text"]
            .as_str()
            .unwrap()
            .contains("unexpected-input=no"),
        "nothing reaches the agent during a turn: {done}"
    );
    // Both messages arrive in one turn (turn 3), not two.
    let mut reply = String::new();
    wait_until("one turn for both", Duration::from_secs(60), || {
        reply = texts(&a, "bob").last().cloned().unwrap_or_default();
        reply.contains("turn=3")
    });
    assert!(
        reply.contains("You wrote: during one|during two|"),
        "{reply}"
    );
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(resident(&b)["turns"], 3);
    // Interrupt: a slow turn, then an owner turn with --interrupt.
    let mut slow = Proc::spawn({
        let mut c = b.cmd();
        c.args(["--json", "wake", "say", "alice", "SLOW-TURN"]);
        c
    });
    slow.wait_for("the slow turn streams", T, |v| {
        v["kind"] == "resident_delta"
    });
    let t = Instant::now();
    let next = say(&b, &["--interrupt", "stop that"]);
    let (_, first) = slow.finish(T);
    println!(
        "RESIDENT interrupt: the slow turn ended {}, the next turn done in {} ms",
        first["outcome"],
        t.elapsed().as_millis()
    );
    assert_eq!(first["outcome"], "interrupted", "{first}");
    assert_eq!(next["outcome"], "done", "{next}");
    assert!(
        next["text"]
            .as_str()
            .unwrap()
            .contains("Owner said: stop that"),
        "{next}"
    );
}

/// PG-58: the owner's urgent message from an own computer (level 5 both ways) interrupts the resident agent's turn in
/// progress, and the next turn is on that message, labelled so; a normal message waits (the test above).
#[test]
fn an_urgent_message_from_an_own_computer_interrupts_the_resident_turn() {
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let mut a = Node::new(root.path(), "alice", Net::Local);
    let mut b = Node::new(root.path(), "bob", Net::Local);
    a.start();
    b.start();
    a.init();
    b.init();
    pair(&a, &b, 5);
    set_resident(&b, &script, "chat", &[]);
    ask(&a, "warm up", "turn=1");
    // A slow turn (≈ 6 s; it reads its input between pieces): an owner turn, whose text the fake sees (a contact's
    // turn carries only a reference to the message)
    let mut slow = Proc::spawn({
        let mut c = b.cmd();
        c.args(["--json", "wake", "say", "alice", "SLOW-TURN"]);
        c
    });
    slow.wait_for("the slow turn streams", T, |v| {
        v["kind"] == "resident_delta"
    });
    let t = Instant::now();
    let u = a.json(&[
        "send",
        "--to",
        "agent",
        "--to-agent",
        "wake",
        "--urgent",
        "bob",
        "stop that now",
    ]);
    assert_eq!(u["urgent"], true, "{u}");
    let mut reply = String::new();
    wait_until(
        "a turn on the urgent message",
        Duration::from_secs(60),
        || {
            reply = texts(&a, "bob")
                .into_iter()
                .find(|r| r.contains("turn=3"))
                .unwrap_or_default();
            !reply.is_empty()
        },
    );
    println!(
        "RESIDENT urgent: the next turn answered {} ms after the urgent message",
        t.elapsed().as_millis()
    );
    assert!(reply.contains("urgent-turn=yes"), "labelled: {reply}");
    assert!(reply.contains("stop that now"), "the turn read it: {reply}");
    let (_, first) = slow.finish(T);
    assert_eq!(
        first["outcome"], "interrupted",
        "the slow turn was cut: {first}"
    );
    assert!(t.elapsed() < Duration::from_secs(20), "{:?}", t.elapsed());
    // The audit log of Bob's link says the flag was honoured for the wake agent
    let audit = b.json(&["log", "alice"]).to_string();
    assert!(
        audit.contains("\"action\":\"urgent\"") && audit.contains("allowed"),
        "{audit}"
    );
}

/// Owner turns are labelled as the owner's; their replies stay with the owner, unless `--to-contact`.
#[test]
fn owner_turns_are_labelled_and_stay_with_the_owner() {
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let (a, b) = two(root.path());
    set_resident(&b, &script, "chat", &[]);
    let before = texts(&a, "bob").len();
    let mine = say(&b, &["what did we decide"]);
    let text = mine["text"].as_str().unwrap();
    assert!(text.contains("kind=owner"), "{mine}");
    assert!(text.contains("Owner said: what did we decide"), "{text}");
    assert_eq!(mine["turn"], 1);
    assert!(
        mine["usage"]["output_tokens"].as_u64().unwrap() > 0,
        "{mine}"
    );
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(texts(&a, "bob").len(), before, "an owner turn stays local");
    // The same session answers the contact, and knows the earlier turn.
    let r = ask(&a, "hi", "turn=2");
    assert_eq!(field(&r, "kind"), "contact");
    // An owner turn whose reply goes to the contact.
    let sent = say(&b, &["--to-contact", "tell alice it is done"]);
    assert_eq!(sent["text"], "", "{sent}");
    assert!(sent["message_id"].is_string(), "{sent}");
    let mut last = String::new();
    wait_until("the reply at the contact", T, || {
        last = texts(&a, "bob").last().cloned().unwrap_or_default();
        last.contains("turn=3")
    });
    assert!(last.contains("kind=owner"), "{last}");
    assert!(last.contains("Owner said: tell alice it is done"), "{last}");
    let res = resident(&b);
    assert_eq!(
        (res["turns"].as_u64(), res["owner_turns"].as_u64()),
        (Some(3), Some(2))
    );
    // The daemon does not compact by default; the owner can at any time.
    assert_eq!(res["compactions"], 0, "{res}");
    let asked = b.json(&["wake", "session", "alice", "compact"]);
    assert_eq!(asked["type"], "resident_session", "{asked}");
    wait_until("the owner's compacting", T, || {
        resident(&b)["compactions"] == 1
    });
    assert_eq!(resident(&b)["context_tokens"], 1200);
}

/// The resident process runs in the same sandbox as a one-shot run, and inside it there are no owner commands: not with
/// its token and not without it (the sandbox tree is the agent, D-28).
#[test]
fn the_resident_agent_stays_in_the_sandbox_and_has_no_owner_commands() {
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let (a, mut b) = two(root.path());
    // A daemon started from inside another agent's session (the window launched from Claude Code): those session
    // markers must not reach the agent the daemon starts (it would think it is a child session).
    b.stop();
    b.extra_env = [
        ("CLAUDECODE", "1"),
        ("CLAUDE_CODE_CHILD_SESSION", "1"),
        ("CLAUDE_CODE_ENTRYPOINT", "cli"),
        ("CODEX_THREAD_ID", "t-1"),
        ("ANTENNA_TEST_MARK", "x"),
    ]
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .to_vec();
    b.start();
    b.unlock();
    let owner_cfg = root.path().join("owner-home").join(".claude");
    std::fs::create_dir_all(&owner_cfg).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    set_resident(
        &b,
        &script,
        &format!("probe {} {} {port}", owner_cfg.display(), b.dir.display()),
        &[],
    );
    let probe = say(&b, &["PROBE"]);
    let report = probe["text"].as_str().unwrap();
    println!(
        "RESIDENT escape report ({}): {report}",
        b.json(&["wake", "list"])["sandbox"]
    );
    assert!(report.contains("claude-md-write=denied"), "{probe}");
    assert!(report.contains("keystore-read=denied"), "{report}");
    assert!(report.contains("own-dirs-write=ok"), "{report}");
    assert!(report.contains("direct-tcp=denied"), "{report}");
    assert!(report.contains("inherited-env=0"), "{report}");
    assert!(!owner_cfg.join("CLAUDE.md").exists());
    let tried = say(&b, &["TRY-OWNER"]);
    let t = tried["text"].as_str().unwrap();
    println!("RESIDENT owner commands from inside: {t}");
    assert!(t.contains("say=unknown_command"), "{t}");
    assert!(t.contains("session=unknown_command"), "{t}");
    assert!(t.contains("trust=unknown_command"), "{t}");
    // Without the token the process is still the agent (its tree is bound, D-28), so still no owner command.
    assert!(t.contains("tokenless=unknown_command"), "{t}");
    assert_eq!(a.contact("bob")["trust"], 3);
    assert_eq!(resident(&b)["turns"], 2);
}

/// Compacting before the provider's cache goes cold, once per turn; the idle stop; a reset to a clean session.
#[test]
fn compaction_idle_stop_and_reset() {
    let root = tempfile::tempdir().unwrap();
    let script = fake(root.path());
    let (a, b) = two(root.path());
    set_resident(
        &b,
        &script,
        "chat",
        &[
            "--compact-idle",
            "2s",
            "--compact-above",
            "1k",
            "--idle-stop",
            "6s",
        ],
    );
    let mut ev = events(&b);
    let r1 = ask(&a, "a big task", "turn=1");
    assert!(resident(&b)["context_tokens"].as_u64().unwrap() >= 1000);
    ev.wait_for("compacted", Duration::from_secs(20), |v| {
        v["kind"] == "wake" && v["state"] == "compacted"
    });
    wait_until("the context after compacting", T, || {
        resident(&b)["context_tokens"] == 1200
    });
    ev.wait_for("idle stop", Duration::from_secs(20), |v| {
        v["kind"] == "wake" && v["state"] == "sleeping"
    });
    let res = resident(&b);
    assert_eq!(res["state"], "sleeping", "{res}");
    assert_eq!(res["turns"], 1, "compacting is not a turn: {res}");
    let compacted = ev
        .seen
        .iter()
        .filter(|v| v["kind"] == "wake" && v["state"] == "compacted")
        .count();
    assert_eq!(compacted, 1, "once per turn");
    assert_eq!(res["compactions"], 1, "{res}");
    assert!(res["last_compact_ms"].as_u64().is_some(), "{res}");
    // The next message resumes the stopped session.
    let r2 = ask(&a, "continue", "turn=2");
    assert_eq!(field(&r2, "session"), field(&r1, "session"));
    assert_eq!(field(&r2, "how"), "resume");
    // Reset (owner password): a new session, clean taint, the old transcript is gone.
    let sid = resident(&b)["session_id"].as_str().unwrap().to_string();
    let dir = b
        .dir
        .join("wake")
        .join("resident")
        .join(&b.contact("alice")["link_id"].as_str().unwrap()[..16]);
    assert!(dir.join("home").join(".fake-resident").join(&sid).exists());
    let out = b.x(&["--json", "wake", "session", "alice", "reset"]);
    assert!(!out.status.success(), "reset needs the password: {out:?}");
    let reset = b.owner_json(&["wake", "session", "alice", "reset"]);
    assert_eq!(reset["type"], "resident_session", "{reset}");
    assert!(reset["resident"]["session_id"].is_null(), "{reset}");
    assert_eq!(reset["resident"]["turns"], 0, "{reset}");
    assert!(
        reset["resident"]["ceiling"].is_null(),
        "taint is clean: {reset}"
    );
    assert!(!dir.join("home").join(".fake-resident").join(&sid).exists());
    let r3 = ask(&a, "who are you now", "turn=1");
    assert_ne!(field(&r3, "session"), field(&r1, "session"));
    assert_eq!(field(&r3, "how"), "new");
    // Turning wake off ends the session and removes its directory.
    b.json(&["wake", "off", "alice"]);
    wait_until("the session directory removed", T, || !dir.exists());
}

/// Manual check with the real Claude Code (it uses the subscription of the token's owner, so it is `#[ignore]`):
/// two messages from the contact, then a question from the owner; the later turns must use what the first one said.
/// Run: `ANTENNA_CLAUDE_TOKEN_FILE=<file with a \`claude setup-token\` token> cargo test -p antenna-cli --test resident
/// real_claude -- --ignored --nocapture`. `ANTENNA_CLAUDE_COMPACT=1` adds a real `/compact` and a question after it;
/// `ANTENNA_CLAUDE_IDLE_PROBE=<seconds>` adds a turn after that much idle time (does the prompt cache survive it?). The
/// token is passed on stdin and never printed.
#[test]
#[ignore]
fn real_claude_code_keeps_its_context_across_messages() {
    let Ok(path) = std::env::var("ANTENNA_CLAUDE_TOKEN_FILE") else {
        println!("SKIP: ANTENNA_CLAUDE_TOKEN_FILE is not set");
        return;
    };
    let token = std::fs::read_to_string(path).unwrap().trim().to_string();
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path());
    let out = b.x_stdin(
        &[
            "--json",
            "wake",
            "set",
            "alice",
            "--resident",
            "--cmd",
            "claude -p --output-format stream-json --model sonnet",
            "--secret-env",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "--no-home-files",
            "--timeout",
            "5m",
            "--password-stdin",
        ],
        &format!("{}\n{token}\n", b.password),
    );
    assert!(out.status.success(), "wake set failed: {:?}", out.status);
    assert!(!String::from_utf8_lossy(&out.stdout).contains(&token));
    let counters = |b: &Node| {
        let r = resident(b);
        format!(
            "turns {} (owner {}), starts {}, in {}, cache read {}, cache written {}, out {}, context {}, ≈ ${:.4}",
            r["turns"],
            r["owner_turns"],
            r["starts"],
            r["input_tokens"],
            r["cache_read_tokens"],
            r["cache_write_tokens"],
            r["output_tokens"],
            r["context_tokens"],
            r["cost_micro_usd"].as_u64().unwrap_or(0) as f64 / 1e6
        )
    };
    let t = Instant::now();
    let r1 = ask(
        &a,
        "Hi! My favourite colour is teal and my cat is called Biscuit. Please just acknowledge in one short sentence.",
        "",
    );
    println!(
        "REAL turn 1 ({} ms): {r1}\n  {}",
        t.elapsed().as_millis(),
        counters(&b)
    );
    let t = Instant::now();
    let r2 = ask(
        &a,
        "What is my cat called, and what is my favourite colour? Answer in one short line.",
        "",
    );
    println!(
        "REAL turn 2 ({} ms): {r2}\n  {}",
        t.elapsed().as_millis(),
        counters(&b)
    );
    let l2 = r2.to_lowercase();
    assert!(
        l2.contains("biscuit") && l2.contains("teal"),
        "the second turn must use the first one's context: {r2}"
    );
    let t = Instant::now();
    let mine = say(
        &b,
        &["In one sentence: what has the contact told you so far, and who am I in this session?"],
    );
    println!(
        "REAL owner turn ({} ms, {}): {}\n  {}",
        t.elapsed().as_millis(),
        mine["outcome"],
        mine["text"],
        counters(&b)
    );
    assert_eq!(mine["outcome"], "done", "{mine}");
    assert!(
        mine["text"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("biscuit"),
        "{mine}"
    );
    // An interrupt: a long answer, then the owner interrupts it.
    let mut long = Proc::spawn({
        let mut c = b.cmd();
        c.args([
            "--json",
            "wake",
            "say",
            "alice",
            "Write the numbers from 1 to 400, one per line, nothing else.",
        ]);
        c
    });
    long.wait_for("the long answer streams", Duration::from_secs(120), |v| {
        v["kind"] == "resident_delta" && v["delta"].as_str().is_some_and(|d| d.contains('5'))
    });
    let t = Instant::now();
    let after = say(&b, &["--interrupt", "Stop. Reply with just the word OK."]);
    let (_, cut) = long.finish(Duration::from_secs(60));
    println!(
        "REAL interrupt: the long turn ended {} ({}), the next turn {} in {} ms: {}\n  {}",
        cut["outcome"],
        cut["detail"],
        after["outcome"],
        t.elapsed().as_millis(),
        after["text"],
        counters(&b)
    );
    // Compacting with the real `/compact`: the context shrinks, the facts survive in the summary.
    if std::env::var("ANTENNA_CLAUDE_COMPACT").is_ok() {
        let mut ev = events(&b);
        let before = resident(&b)["context_tokens"].clone();
        b.json(&["wake", "session", "alice", "compact"]);
        let done = ev.wait_for("compacted", Duration::from_secs(300), |v| {
            v["kind"] == "wake" && (v["state"] == "compacted" || v["state"] == "failed")
        });
        println!(
            "REAL compacting: {} — context {before} → {}\n  {}",
            done["detail"],
            resident(&b)["context_tokens"],
            counters(&b)
        );
        let r = ask(&a, "After all that: what is my cat called? One word.", "");
        println!("REAL after compacting: {r}\n  {}", counters(&b));
        assert!(r.to_lowercase().contains("biscuit"), "{r}");
    }
    if let Some(secs) = std::env::var("ANTENNA_CLAUDE_IDLE_PROBE")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
    {
        let before = resident(&b);
        println!("REAL idle probe: waiting {secs} s");
        std::thread::sleep(Duration::from_secs(secs));
        let t = Instant::now();
        let r = ask(&a, "Remind me of my cat's name in one word.", "");
        let after = resident(&b);
        let d = |k: &str| after[k].as_u64().unwrap_or(0) - before[k].as_u64().unwrap_or(0);
        println!(
            "REAL turn after {secs} s idle ({} ms): {r}\n  this turn: in {}, cache read {}, cache written {}, out {}",
            t.elapsed().as_millis(),
            d("input_tokens"),
            d("cache_read_tokens"),
            d("cache_write_tokens"),
            d("output_tokens")
        );
    }
    let link = b.contact("alice")["link_id"].as_str().unwrap()[..16].to_string();
    let projects = b
        .dir
        .join("wake")
        .join("resident")
        .join(link)
        .join("home")
        .join(".claude")
        .join("projects");
    let transcripts: Vec<String> = walk(&projects)
        .into_iter()
        .filter(|p| p.extension().is_some_and(|e| e == "jsonl"))
        .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    println!("REAL transcripts in the agent's HOME: {transcripts:?}");
    let sid = resident(&b)["session_id"].as_str().unwrap().to_string();
    assert!(
        transcripts.iter().any(|t| t.starts_with(&sid)),
        "Claude Code keeps the session {sid} on disk: {transcripts:?}"
    );
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                out.extend(walk(&p));
            } else {
                out.push(p);
            }
        }
    }
    out
}
