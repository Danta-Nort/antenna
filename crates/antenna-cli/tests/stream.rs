// SPDX-License-Identifier: AGPL-3.0-only
//! Streaming messages, v0.2 (`docs/PROTOCOL.md` §20, `docs/CONTROL.md` §15): two real `antennad` daemons.
//! The owner writes with `antenna send --stream`; a level 3+ contact sees the text in chunks (`message_stream` events),
//! only the final message goes into both sides' history, history verification is green; level 2 gets only the final
//! message; a secret in the middle cuts the stream (the final message follows the owner's approval and is matched by
//! salt); a broken source gives an "interrupted" final message.
//!
//! Run: `cargo test -p antenna-cli --test stream -- --nocapture` (from the workspace root).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::{
    io::Write,
    process::Stdio,
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

fn two(root: &std::path::Path, net: Net) -> (Node, Node) {
    let mut a = Node::new(root, "alice", net.clone());
    let mut b = Node::new(root, "bob", net);
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

/// `antenna send --stream <to>` with an open stdin: the test writes the chunks.
struct Streamer {
    child: std::process::Child,
}

impl Streamer {
    fn start(n: &Node, to: &str) -> Self {
        Self::start_as(n, to, None)
    }

    /// The same as the agent with this token.
    fn start_as(n: &Node, to: &str, token: Option<&str>) -> Self {
        let mut c = match token {
            Some(t) => n.agent_cmd(t),
            None => n.cmd(),
        };
        let child = c
            .args(["--json", "send", "--stream", to, "--wait", "5s"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        Self { child }
    }

    fn write(&mut self, s: &str) {
        let w = self.child.stdin.as_mut().unwrap();
        w.write_all(s.as_bytes()).unwrap();
        w.flush().unwrap();
    }

    /// (exit code, last JSON, stderr, the `stream_started` event).
    fn finish(self) -> (i32, Value, String) {
        let (c, v, e, _) = self.finish_all();
        (c, v, e)
    }

    fn finish_all(mut self) -> (i32, Value, String, Value) {
        drop(self.child.stdin.take());
        let out = self.child.wait_with_output().unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout).to_string();
        let lines: Vec<Value> = stdout
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();
        let started = lines
            .iter()
            .find(|v| v["kind"] == "stream_started")
            .cloned()
            .unwrap_or(Value::Null);
        (
            out.status.code().unwrap_or(-1),
            lines.last().cloned().unwrap_or(Value::Null),
            String::from_utf8_lossy(&out.stderr).to_string(),
            started,
        )
    }
}

fn is_stream(v: &Value, state: &str) -> bool {
    v["kind"] == "message_stream" && v["state"] == state
}

fn texts(n: &Node, contact: &str) -> Vec<String> {
    n.json(&["history", contact, "--limit", "500"])["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"] == "text")
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

const P1: &str =
    "Streaming answers arrive piece by piece, like in a chat with a model: first this sentence, ";
const P2: &str =
    "then a second part after a short pause, while the writer is still thinking about the ending, ";
const P3: &str = "and finally the last words.\n";

/// Level 3: the contact sees the text in chunks as it is written; the final message is one message in both sides'
/// history; history verification is green. Measurement: latency of the first chunk at the recipient from the sender's
/// write to stdin.
#[test]
fn level_3_contact_sees_the_text_as_it_comes_and_history_gets_the_final() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ev = events(&b);
    let mut s = Streamer::start(&a, "bob");
    // Opening: "typing…" (an empty first chunk) before the first text.
    let opened = ev.wait_for("stream opened", T, |v| is_stream(v, "streaming"));
    assert_eq!(opened["direction"], "in");
    assert_eq!(opened["seq"], 0);
    let sid = opened["stream_id"].as_str().unwrap().to_string();
    let t0 = Instant::now();
    s.write(P1);
    ev.wait_for("first chunk", T, |v| {
        is_stream(v, "streaming") && v["delta"].as_str().is_some_and(|d| !d.is_empty())
    });
    let first_ms = t0.elapsed().as_millis();
    std::thread::sleep(Duration::from_millis(400));
    s.write(P2);
    std::thread::sleep(Duration::from_millis(400));
    s.write(P3);
    let (code, r, err) = s.finish();
    assert_eq!(code, 0, "send --stream: {r} {err}");
    assert_eq!(r["type"], "sent");
    let full = format!("{P1}{P2}{P3}");
    let fin = ev.wait_for("final", T, |v| is_stream(v, "final"));
    assert_eq!(fin["stream_id"], sid.as_str());
    assert_eq!(fin["end"], "done");
    assert_eq!(fin["message_id"], r["id"]);
    // Chunks: several events before the final message, in seq order; concatenated they give the whole text.
    let chunks: Vec<&Value> = ev
        .seen
        .iter()
        .filter(|v| is_stream(v, "streaming") && v["stream_id"] == sid.as_str())
        .collect();
    let joined: String = chunks.iter().filter_map(|v| v["delta"].as_str()).collect();
    assert_eq!(joined, full);
    let nonempty = chunks
        .iter()
        .filter(|v| v["delta"].as_str().is_some_and(|d| !d.is_empty()))
        .count();
    assert!(nonempty >= 3, "the text came in {nonempty} pieces");
    let seqs: Vec<u64> = chunks.iter().map(|v| v["seq"].as_u64().unwrap()).collect();
    assert!(seqs.windows(2).all(|w| w[1] == w[0] + 1), "{seqs:?}");
    // The final message is a regular message: in both sides' history; the recipient gets a `message` event with the
    // same ID.
    ev.wait_for("final message", T, |v| {
        v["kind"] == "message" && v["message"]["id"] == r["id"]
    });
    assert_eq!(texts(&b, "alice").last().unwrap(), &full);
    assert_eq!(texts(&a, "bob").last().unwrap(), &full);
    // No chunks in history, only the final message (and the warm-up).
    assert_eq!(texts(&b, "alice").len(), 2);
    let va = a.json(&["verify", "bob"])["status"].clone();
    let vb = b.json(&["verify", "alice"])["status"].clone();
    assert_eq!(va["state"], "verified", "{va}");
    assert_eq!(vb["state"], "verified", "{vb}");
    assert_eq!(va["fingerprint"], vb["fingerprint"]);
    println!(
        "STREAM level 3: first chunk at the contact {first_ms} ms after the writer's first write; {nonempty} live pieces"
    );
    // No streams left.
    assert!(
        b.json(&["streams"])["streams"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

/// PG-20: an agent's stream names the agent in the live display on both sides before the final message, which carries
/// the same name; the owner's own stream names nobody.
#[test]
fn the_live_display_names_the_agent_that_writes() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let tok = a.agent_add("claude", &["--local-level", "0"]);
    let mut ev_b = events(&b);
    let mut ev_a = events(&a);
    let mut s = Streamer::start_as(&a, "bob", Some(&tok));
    let opened = ev_b.wait_for("stream opened", T, |v| is_stream(v, "streaming"));
    assert_eq!(opened["via_agent"], "claude", "{opened}");
    s.write(P1);
    ev_b.wait_for("first chunk", T, |v| {
        is_stream(v, "streaming") && v["delta"].as_str().is_some_and(|d| !d.is_empty())
    });
    let listed = b.json(&["streams"]);
    assert_eq!(listed["streams"][0]["via_agent"], "claude", "{listed}");
    let mine = ev_a.wait_for("own stream", T, |v| is_stream(v, "streaming"));
    assert_eq!(
        (&mine["direction"], &mine["via_agent"]),
        (&Value::from("out"), &Value::from("claude")),
        "{mine}"
    );
    let (code, r, err) = s.finish();
    assert_eq!(code, 0, "send --stream: {r} {err}");
    let fin = ev_b.wait_for("final", T, |v| is_stream(v, "final"));
    assert_eq!(fin["via_agent"], "claude", "{fin}");
    let m = ev_b.wait_for("final message", T, |v| {
        v["kind"] == "message" && v["message"]["id"] == r["id"]
    });
    assert_eq!(m["message"]["via_agent"], "claude", "{m}");
    // The owner's own stream: nobody named
    let mut s = Streamer::start(&a, "bob");
    s.write(P3);
    let (code, r, err) = s.finish();
    assert_eq!(code, 0, "send --stream: {r} {err}");
    let fin = ev_b.wait_for("the owner's final", T, |v| {
        is_stream(v, "final") && v["message_id"] == r["id"]
    });
    assert!(fin.get("via_agent").is_none(), "{fin}");
}

/// Level 2 (SPEC §4: typing indicator for 3+ only): the contact gets only the final message and no stream events.
#[test]
fn level_2_contact_gets_only_the_final_message() {
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::LocalRelay(relay.url.clone()));
    pair(&a, &b, 2);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ev = events(&b);
    let mut s = Streamer::start(&a, "bob");
    s.write(P1);
    std::thread::sleep(Duration::from_millis(300));
    s.write(P2);
    let (code, r, err, started) = s.finish_all();
    assert_eq!(code, 0, "{r} {err}");
    assert_eq!(started["live"], false, "{started}");
    assert_eq!(started["reason"], "trust_below_3", "{started}");
    ev.wait_for("final message", T, |v| {
        v["kind"] == "message" && v["message"]["id"] == r["id"]
    });
    assert!(
        !ev.seen.iter().any(|v| v["kind"] == "message_stream"),
        "level 2 must not see the stream: {:?}",
        ev.seen
    );
    assert_eq!(texts(&b, "alice").last().unwrap(), &format!("{P1}{P2}"));
}

/// The recipient trusts the sender at 2, the sender trusts the recipient at 3: the recipient refuses the stream, and
/// the sender learns this before the first chunk and sends only the final message.
#[test]
fn receiver_below_level_3_refuses_the_stream() {
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::LocalRelay(relay.url.clone()));
    pair(&a, &b, 3);
    assert_eq!(b.owner_json(&["trust", "alice", "2"])["type"], "contacts");
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ev = events(&b);
    let mut s = Streamer::start(&a, "bob");
    s.write(P1);
    let (code, r, err, started) = s.finish_all();
    assert_eq!(code, 0, "{r} {err}");
    assert_eq!(started["live"], false, "{started}");
    assert_eq!(started["reason"], "contact_refused", "{started}");
    ev.wait_for("final message", T, |v| {
        v["kind"] == "message" && v["message"]["id"] == r["id"]
    });
    assert!(!ev.seen.iter().any(|v| v["kind"] == "message_stream"));
}

/// A secret in the middle of a stream (D-40): the stream is cut at the contact (`interrupted`, `cut`) and the secret
/// never reaches it; the whole message goes to approval. After `antenna approve` the daemon sends the final message
/// itself, and the contact matches it by the stream salt.
#[test]
fn a_secret_in_the_middle_cuts_the_stream_and_the_final_waits_for_approval() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ev = events(&b);
    // The sender's own window (subscriber A) must also get the `final` of the deferred final message.
    let mut own = events(&a);
    let mut s = Streamer::start(&a, "bob");
    s.write(P1);
    ev.wait_for("first chunk", T, |v| {
        is_stream(v, "streaming") && v["delta"].as_str().is_some_and(|d| !d.is_empty())
    });
    let secret = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----\n";
    s.write("here is my key: ");
    s.write(secret);
    std::thread::sleep(Duration::from_millis(300));
    s.write("and some more text after it.\n");
    let cut = ev.wait_for("stream cut", T, |v| is_stream(v, "interrupted"));
    assert_eq!(cut["reason"], "cut");
    let (code, r, err) = s.finish();
    assert_eq!(code, 77, "approval needed: {r} {err}");
    let approval = r["approval"]["id"].as_str().unwrap().to_string();
    // Neither a chunk nor history carries the secret.
    let live: String = ev
        .seen
        .iter()
        .filter(|v| is_stream(v, "streaming"))
        .filter_map(|v| v["delta"].as_str())
        .collect();
    assert!(!live.contains("PRIVATE KEY"), "{live}");
    assert!(!live.contains("b3BlbnNzaC1rZXkt"), "{live}");
    std::thread::sleep(Duration::from_millis(500));
    assert!(!texts(&b, "alice").iter().any(|t| t.contains("PRIVATE KEY")));
    // The owner approves: the final message goes out by itself and matches the cut stream by salt at the contact.
    assert_eq!(a.owner_json(&["approve", &approval])["type"], "approval");
    let fin = ev.wait_for("final after approval", T, |v| is_stream(v, "final"));
    assert_eq!(fin["stream_id"], cut["stream_id"]);
    wait_until("approved final in history", T, || {
        texts(&b, "alice").iter().any(|t| t.contains("PRIVATE KEY"))
    });
    // The sender: `interrupted{cut}`, then after approval the `final` of the same stream with the final message ID
    // (matched by ID, not by text).
    let own_cut = own.wait_for("own cut", T, |v| {
        is_stream(v, "interrupted") && v["direction"] == "out"
    });
    assert_eq!(own_cut["reason"], "cut");
    let own_fin = own.wait_for("own final after approval", T, |v| {
        is_stream(v, "final") && v["direction"] == "out"
    });
    assert_eq!(own_fin["stream_id"], own_cut["stream_id"]);
    assert_eq!(own_fin["stream_id"], cut["stream_id"]);
    assert_eq!(own_fin["end"], "done");
    assert!(own_fin["seq"].as_u64().unwrap() > own_cut["seq"].as_u64().unwrap());
    let mid = own_fin["message_id"].as_str().unwrap();
    let h = a.json(&["history", "bob"]);
    let last = h["messages"].as_array().unwrap().last().unwrap().clone();
    assert_eq!(last["id"], mid, "{last}");
    assert!(last["text"].as_str().unwrap().contains("PRIVATE KEY"));
}

/// Level 5, the owner's own computer (D-99): a secret in the middle of a stream does not cut it; the contact sees the
/// whole text live and in the final message, and the sender's audit log records what the scanner found. Negative
/// control: with the level check in `StreamWriter::push` removed, the stream is cut as at level 3.
#[test]
fn at_level_5_a_secret_does_not_cut_the_stream() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 5);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ev = events(&b);
    let mut s = Streamer::start(&a, "bob");
    s.write(P1);
    let secret = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----\n";
    s.write("here is my key: ");
    s.write(secret);
    std::thread::sleep(Duration::from_millis(300));
    s.write("and some more text after it.\n");
    let (code, r, err) = s.finish();
    assert_eq!(code, 0, "no approval at level 5: {r} {err}");
    let fin = ev.wait_for("final", T, |v| is_stream(v, "final"));
    assert_eq!(fin["end"], "done", "{fin}");
    assert!(
        !ev.seen.iter().any(|v| is_stream(v, "interrupted")),
        "not cut: {:?}",
        ev.seen
    );
    let live: String = ev
        .seen
        .iter()
        .filter(|v| is_stream(v, "streaming"))
        .filter_map(|v| v["delta"].as_str())
        .collect();
    assert!(live.contains("PRIVATE KEY"), "{live}");
    wait_until("final in history", T, || {
        texts(&b, "alice").iter().any(|t| t.contains("PRIVATE KEY"))
    });
    let log = a.json(&["log", "bob"]);
    assert!(
        log["entries"].as_array().unwrap().iter().any(|e| {
            e["decision"] == "allowed_at_trust_5"
                && e["reason"]
                    .as_str()
                    .unwrap_or("")
                    .contains("secret:private_key")
        }),
        "{log}"
    );
}

/// The source broke (the `antenna send --stream` process was killed): the final message is the received text marked
/// `[interrupted]`.
#[test]
fn an_interrupted_source_gives_an_interrupted_final() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ev = events(&b);
    let mut s = Streamer::start(&a, "bob");
    s.write(P1);
    s.write(P2);
    ev.wait_for("chunk", T, |v| {
        is_stream(v, "streaming") && v["delta"].as_str().is_some_and(|d| !d.is_empty())
    });
    // Like Ctrl-C: the process disappears, the connection to the daemon breaks.
    s.child.kill().unwrap();
    let _ = s.child.wait();
    let fin = ev.wait_for("interrupted final", T, |v| is_stream(v, "final"));
    assert_eq!(fin["end"], "interrupted");
    wait_until("interrupted final in history", T, || {
        texts(&b, "alice")
            .last()
            .is_some_and(|t| t.ends_with("[interrupted]") && t.starts_with(P1))
    });
}

/// The `streams` command: a running stream is visible with its text so far (for the window, after `lagged` and a
/// reconnect).
#[test]
fn streams_lists_a_running_stream_on_both_sides() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ev = events(&b);
    let mut s = Streamer::start(&a, "bob");
    s.write(P1);
    s.write(P2);
    ev.wait_for("chunk", T, |v| {
        is_stream(v, "streaming") && v["delta"].as_str().is_some_and(|d| !d.is_empty())
    });
    let bs = b.json(&["streams"])["streams"].as_array().unwrap().clone();
    assert_eq!(bs.len(), 1, "{bs:?}");
    assert_eq!(bs[0]["direction"], "in");
    assert!(
        P1.starts_with(bs[0]["text"].as_str().unwrap())
            || bs[0]["text"].as_str().unwrap().starts_with(P1)
    );
    let as_ = a.json(&["streams"])["streams"].as_array().unwrap().clone();
    assert_eq!(as_.len(), 1);
    assert_eq!(as_[0]["direction"], "out");
    assert_eq!(as_[0]["live"], true);
    let (code, _, err) = s.finish();
    assert_eq!(code, 0, "{err}");
}

/// Compatibility: a subscriber of an older version (a window on `x-control/3`) gets no stream events at all, only the
/// final message as a regular `message`; a new one (`x-control/4`) gets them.
#[test]
fn old_subscribers_do_not_get_stream_events() {
    use std::io::{BufRead, BufReader};
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let held = b.held_session();
    let mut s = std::os::unix::net::UnixStream::connect(b.dir.join("antennad.sock")).unwrap();
    let hello = serde_json::json!({"hello": {"proto": "x-control/3", "role": "owner", "session": held.token}});
    s.write_all(format!("{hello}\n{{\"req\":{{\"cmd\":\"subscribe\"}}}}\n").as_bytes())
        .unwrap();
    let (tx, rx) = std::sync::mpsc::channel::<Value>();
    let r = s.try_clone().unwrap();
    std::thread::spawn(move || {
        for l in BufReader::new(r).lines() {
            let Ok(l) = l else { break };
            if let Ok(v) = serde_json::from_str::<Value>(&l)
                && tx.send(v).is_err()
            {
                break;
            }
        }
    });
    let mut ev = events(&b);
    let mut st = Streamer::start(&a, "bob");
    st.write(P1);
    let (code, r, _) = st.finish();
    assert_eq!(code, 0);
    ev.wait_for("final", T, |v| is_stream(v, "final"));
    let mut old = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(3);
    while let Ok(v) = rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        old.push(v);
    }
    assert!(
        old.iter()
            .any(|v| v["event"]["kind"] == "message" && v["event"]["message"]["id"] == r["id"]),
        "the old subscriber gets the final message: {old:?}"
    );
    assert!(
        !old.iter().any(|v| v["event"]["kind"] == "message_stream"),
        "no stream events for x-control/3: {old:?}"
    );
    drop(held);
}

/// At most 4 incoming streams per link at a time; the limit is checked under the same lock as the insertion: out of 6
/// concurrent streams exactly 4 are live, the rest are refused (`contact_refused`), and all get a final message.
#[test]
fn at_most_four_live_streams_per_link() {
    let root = tempfile::tempdir().unwrap();
    let (a, b) = two(root.path(), Net::Local);
    pair(&a, &b, 3);
    assert_eq!(a.send("bob", "warm up")["status"], "delivered");
    let mut ss: Vec<Streamer> = (0..6).map(|_| Streamer::start(&a, "bob")).collect();
    for (i, s) in ss.iter_mut().enumerate() {
        s.write(&format!("stream number {i}: {P1}"));
    }
    let mut live_at_bob = 0;
    wait_until("streams at bob", T, || {
        live_at_bob = b.json(&["streams"])["streams"].as_array().unwrap().len();
        live_at_bob >= 4
    });
    std::thread::sleep(Duration::from_millis(500));
    live_at_bob = b.json(&["streams"])["streams"].as_array().unwrap().len();
    assert_eq!(live_at_bob, 4, "at most 4 live incoming streams per link");
    let mut live = 0;
    for s in ss {
        let (code, r, err, started) = s.finish_all();
        assert_eq!(code, 0, "{r} {err}");
        if started["live"] == true {
            live += 1;
        } else {
            assert_eq!(started["reason"], "contact_refused", "{started}");
        }
    }
    assert_eq!(live, 4);
    wait_until("all finals", T, || {
        texts(&b, "alice")
            .iter()
            .filter(|t| t.starts_with("stream number"))
            .count()
            == 6
    });
}
