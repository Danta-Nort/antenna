// SPDX-License-Identifier: AGPL-3.0-only
//! The agent map's connections (`docs/CONTROL.md` §30, `docs/PROTOCOL.md` §24, D-123; experimental) against real
//! daemons: an agent's default counterpart routes its messages without an address; task authority comes with the
//! line when the owner ticks it; the other side of a line to an own computer is an approval request there, applied only
//! when approved (there, or from this computer through D-106); a contact that is not an own computer is never asked
//! and nothing changes on its side; an agent has no way to set its own counterpart.
//!
//! Run: `cargo build -p antennad -p antenna-cli && cargo test -p antenna-cli --test connections`.

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::time::{Duration, Instant};

use common::*;
use serde_json::{Value, json};

fn nodes(root: &std::path::Path, names: &[&str]) -> Vec<Node> {
    names
        .iter()
        .map(|n| {
            let mut x = Node::new(root, n, Net::Local);
            x.start();
            x.init();
            x
        })
        .collect()
}

fn wait_until<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let t = Instant::now();
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(
            t.elapsed() < Duration::from_secs(30),
            "timeout waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(150));
    }
}

/// A raw agent request with its token: (ok, the ok body or the err body).
fn agent_raw(n: &Node, token: &str, req: Value) -> (bool, Value) {
    use std::io::{BufRead, BufReader, Write};
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = json!({"hello": {"proto": "x-control/7", "role": "agent", "token": token}});
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", json!({ "req": req })).unwrap();
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if let Some(e) = v.get("err") {
            return (false, e.clone());
        }
        if let Some(o) = v.get("ok") {
            return (true, o.clone());
        }
    }
    panic!("no reply");
}

/// The owner's view of one agent.
fn agent_info(n: &Node, name: &str) -> Value {
    n.json(&["agent", "list"])["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["name"] == name)
        .cloned()
        .unwrap_or_else(|| panic!("{}: no agent {name}", n.name))
}

fn counterpart(n: &Node, name: &str) -> Value {
    agent_info(n, name)["session"]["counterpart"].clone()
}

fn tasks_from(n: &Node, name: &str) -> Vec<String> {
    agent_info(n, name)["session"]["tasks_from"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c.as_str().unwrap().to_string())
        .collect()
}

/// The pending approval requests of `n`.
fn pending(n: &Node) -> Vec<Value> {
    n.json(&["approvals"])["approvals"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|a| a["state"] == "pending")
        .cloned()
        .collect()
}

/// What `agent`'s inbox on `n` has now: (from, via_agent, to_agent, authority, text).
fn inbox(n: &Node, token: &str) -> Vec<(String, String, String, String, String)> {
    let (ok, v) = agent_raw(
        n,
        token,
        json!({"cmd": "inbox", "wait": true, "timeout_ms": 5000}),
    );
    assert!(ok, "{v}");
    v["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| {
            let s = |k: &str| m[k].as_str().unwrap_or("").to_string();
            (
                s("from"),
                s("via_agent"),
                s("to_agent"),
                s("authority"),
                s("text"),
            )
        })
        .collect()
}

/// The status `n` keeps of its own computer `contact`: that computer's agent `agent`.
fn device_agent(n: &Node, contact: &str, agent: &str) -> Option<Value> {
    n.json(&["devices"])["devices"]
        .as_array()?
        .iter()
        .find(|d| d["contact"] == contact)?["status"]["agents"]
        .as_array()?
        .iter()
        .find(|a| a["name"] == agent)
        .cloned()
}

/// A contact's agent (not an own computer): only this side changes. The agent writes to it without naming it; the
/// owner's tick makes the contact's messages tasks; nothing is asked of or changed on the contact's computer; with a
/// contact named and nothing read there, the message still goes to the counterpart; an agent cannot set its own
/// counterpart (no agent command, no MCP tool); disconnecting needs no password and takes the routing away.
///
/// Negative controls (each run once, 2026-10-06, each seen failing this test): `ask_other_side` without its level
/// check (bob got a `device` request and refused it with `level`, so `other_side` was `refused`, not
/// `contact_decides`); the `contact.is_empty()` branch of `agent_send` removed (`send` without contact was
/// `not_found`).
#[test]
fn a_line_to_a_contacts_agent_changes_only_this_side() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"]);
    let (alice, bob) = (&ns[0], &ns[1]);
    pair(alice, bob, 3);
    let volna = alice.agent_add("volna", &["--local-level", "0"]);
    let builder = bob.agent_add("builder", &["--local-level", "0"]);
    // bob's agent writes once, so alice's node knows it (announced on the link, PROTOCOL §21)
    bob.agent_ok(&builder, &["send", "alice", "hello from builder"]);
    wait_until("builder announced", || {
        alice.contact("bob")["agents"]
            .as_array()
            .filter(|a| a.iter().any(|x| x == "builder" || x["name"] == "builder"))
            .map(|_| ())
    });

    // Without a counterpart, a send without a contact is refused with what to do
    let (ok, e) = agent_raw(
        alice,
        &volna,
        json!({"cmd": "send", "text": "x", "wait_ms": 0}),
    );
    assert!(!ok, "{e}");
    assert_eq!(e["code"], "bad_request", "{e}");
    assert!(
        e["message"]
            .as_str()
            .unwrap()
            .contains("default counterpart"),
        "{e}"
    );

    // Connecting needs the password
    let out = alice.x(&[
        "--json", "agent", "connect", "volna", "bob", "--agent", "builder",
    ]);
    assert!(!out.status.success(), "{out:?}");
    // An agent bob never announced is not a counterpart
    let out = alice.owner(&["agent", "connect", "volna", "bob", "--agent", "ghost"]);
    assert!(!out.status.success(), "{out:?}");
    assert_eq!(last_json(&out.stdout)["error"], "not_found", "{out:?}");

    let r = alice.owner_json(&[
        "agent", "connect", "volna", "bob", "--agent", "builder", "--tasks",
    ]);
    assert_eq!(r["type"], "agent_connected", "{r}");
    assert_eq!(r["other_side"]["state"], "contact_decides", "{r}");
    assert_eq!(
        r["agent"]["session"]["counterpart"],
        json!({"contact": "bob", "agent": "builder"})
    );
    assert_eq!(
        tasks_from(alice, "volna"),
        ["bob"],
        "the tick made bob's messages tasks"
    );
    // The agent sees it in its own session, read-only
    let s = alice.agent_ok(&volna, &["session"]);
    assert_eq!(s["counterpart"]["agent"], "builder", "{s}");

    // Nothing on bob's side: no request, its agent has no counterpart, its tasks unchanged
    assert!(pending(bob).is_empty(), "{:?}", pending(bob));
    assert!(counterpart(bob, "builder").is_null());

    // volna writes without naming anyone: it goes to bob's builder, and only builder reads it there
    let (ok, sent) = agent_raw(
        alice,
        &volna,
        json!({"cmd": "send", "text": "ping without an address", "wait_ms": 3000}),
    );
    assert!(ok, "{sent}");
    assert_eq!(sent["to_agent"], "builder", "{sent}");
    let got = wait_until("builder gets it", || {
        let m = inbox(bob, &builder);
        m.into_iter().find(|m| m.4 == "ping without an address")
    });
    assert_eq!(
        (got.0.as_str(), got.1.as_str()),
        ("alice", "volna"),
        "{got:?}"
    );
    assert_eq!(got.2, "builder");

    // builder answers by reply; volna reads it as a task (alice ticked it)
    bob.agent_ok(&builder, &["send", "alice", "pong"]);
    let got = wait_until("volna gets the reply", || {
        inbox(alice, &volna).into_iter().find(|m| m.4 == "pong")
    });
    assert_eq!(got.3, "task", "{got:?}");

    // MCP: get_session shows the counterpart, the instructions name it, send_message works without contact; there is no
    // tool to change it
    let mut m = Mcp::start(alice, &volna);
    assert!(
        m.instructions()
            .contains("the agent \"builder\" at \"bob\": send_message without contact goes there"),
        "{}",
        m.instructions()
    );
    let (failed, s) = m.call("get_session", json!({}));
    assert!(!failed, "{s}");
    assert_eq!(s["counterpart"]["contact"], "bob", "{s}");
    let (failed, sent) = m.call("send_message", json!({"text": "from MCP without contact"}));
    assert!(!failed, "{sent}");
    assert_eq!(sent["to_agent"], "builder", "{sent}");
    let names = m.tool_names();
    assert!(
        !names
            .iter()
            .any(|n| n.contains("connect") || n.contains("counterpart")),
        "{names:?}"
    );
    m.stop();
    // The agent role has no such command: "no such command", not "forbidden"
    for req in [
        json!({"cmd": "agent_connect", "name": "volna", "contact": "bob", "agent": "builder", "password": "x"}),
        json!({"cmd": "agent_disconnect", "name": "volna"}),
        json!({"cmd": "agent_traffic"}),
    ] {
        let (ok, e) = agent_raw(alice, &volna, req.clone());
        assert!(!ok, "{req}: {e}");
        assert_eq!(e["code"], "unknown_command", "{req}: {e}");
    }

    // Traffic: the pair with its counts, both ways
    let t = alice.json(&["agent", "traffic"]);
    let p = t["pairs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["agent"] == "volna" && p["peer_agent"] == "builder")
        .cloned()
        .unwrap_or_else(|| panic!("{t}"));
    assert_eq!(
        (p["sent"].as_u64(), p["contact"].as_str()),
        (Some(2), Some("bob")),
        "{p}"
    );
    assert_eq!(p["received"].as_u64(), Some(1), "builder's reply: {p}");

    // Disconnect: no password, the routing goes, `--no-tasks` takes the authority away too
    let out = alice.x(&["--json", "agent", "disconnect", "volna", "--no-tasks"]);
    assert!(out.status.success(), "no password needed: {out:?}");
    let r = last_json(&out.stdout);
    assert_eq!(r["other_side"]["state"], "contact_decides", "{r}");
    assert!(counterpart(alice, "volna").is_null());
    assert!(tasks_from(alice, "volna").is_empty());
    let (ok, e) = agent_raw(
        alice,
        &volna,
        json!({"cmd": "send", "text": "x", "wait_ms": 0}),
    );
    assert!(!ok && e["code"] == "bad_request", "{e}");

    // With a contact named and nothing read there yet, the message goes to the counterpart, not to the person
    let carol = alice.agent_add("carol-bot", &["--local-level", "0"]);
    alice.owner_json(&["agent", "connect", "carol-bot", "bob", "--agent", "builder"]);
    let (ok, sent) = agent_raw(
        alice,
        &carol,
        json!({"cmd": "send", "contact": "bob", "text": "named contact", "wait_ms": 3000}),
    );
    assert!(ok, "{sent}");
    assert_eq!(sent["to_agent"], "builder", "{sent}");
    // A person as the counterpart
    let r = alice.owner_json(&["agent", "connect", "carol-bot", "bob"]);
    assert_eq!(r["other_side"]["state"], "person", "{r}");
    let (ok, sent) = agent_raw(
        alice,
        &carol,
        json!({"cmd": "send", "text": "to the person", "wait_ms": 3000}),
    );
    assert!(ok, "{sent}");
    assert_eq!(sent["to"], "person", "{sent}");
}

/// Two own computers (∞ both ways): the line is drawn on one; the other gets an approval request and changes nothing
/// until it is approved there; then both agents write to each other without naming anyone, and each reads the other's
/// messages as tasks. A denial changes nothing. A disconnect is approved from the first computer through D-106 (the
/// password there, its device key).
///
/// Negative controls (each run once, 2026-10-06, each seen failing this test): `connect_ask_in` applying the change at
/// once instead of making a request (session-2 had a counterpart before any approval); the `Connect` continuation not
/// kept (the approval applied nothing).
#[test]
fn own_computers_set_the_other_side_through_an_approval_there() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["mac", "server"]);
    let (mac, server) = (&ns[0], &ns[1]);
    pair(mac, server, 5);
    let volna = mac.agent_add("volna", &["--local-level", "0"]);
    let session2 = server.agent_add("session-2", &["--local-level", "0"]);
    // The server's status lists its agent on the mac (My devices), so the mac may name it
    wait_until("the server's agent in the mac's view", || {
        device_agent(mac, "server", "session-2")
    });

    let r = mac.owner_json(&[
        "agent",
        "connect",
        "volna",
        "server",
        "--agent",
        "session-2",
        "--tasks",
        "--peer-tasks",
    ]);
    assert_eq!(r["other_side"]["state"], "requested", "{r}");
    let id = r["other_side"]["id"].as_str().unwrap().to_string();
    assert_eq!(counterpart(mac, "volna")["agent"], "session-2");

    // On the server: one request, the daemon's own words; nothing changed yet
    let p = pending(server);
    assert_eq!(p.len(), 1, "{p:?}");
    assert_eq!(p[0]["id"], id.as_str());
    assert_eq!(p[0]["action"], "connect_agent", "{}", p[0]);
    assert_eq!(p[0]["reasons"], json!(["agent_connect"]));
    assert_eq!(
        p[0]["quote"],
        "Connect session-2 with volna on mac: messages from session-2 without an address go to volna. Messages \
         from mac become tasks for session-2."
    );
    assert!(
        counterpart(server, "session-2").is_null(),
        "nothing before the approval"
    );
    // The mac sees the request among the server's (My devices)
    wait_until("the request in the mac's view of the server", || {
        mac.json(&["devices"])["devices"][0]["status"]["approvals"]
            .as_array()
            .filter(|a| a.iter().any(|x| x["id"] == id.as_str()))
            .map(|_| ())
    });
    // Asking again does not make a second request
    let again = mac.owner_json(&[
        "agent",
        "connect",
        "volna",
        "server",
        "--agent",
        "session-2",
        "--peer-tasks",
    ]);
    assert_eq!(again["other_side"]["id"], id.as_str(), "{again}");
    assert_eq!(pending(server).len(), 1);

    // Approved there: the server's agent now has the mac's volna as its counterpart
    server.owner_json(&["approve", &id]);
    let cp = wait_until("applied on the server", || {
        let c = counterpart(server, "session-2");
        (!c.is_null()).then_some(c)
    });
    assert_eq!(cp, json!({"contact": "mac", "agent": "volna"}));
    assert!(tasks_from(server, "session-2").contains(&"mac".to_string()));
    // The mac's view of the server shows the line from that side too
    let a = wait_until("the server says its agent is connected to volna", || {
        device_agent(mac, "server", "session-2").filter(|a| a["counterpart"] == "volna")
    });
    assert_eq!(a["takes_tasks"], true, "{a}");

    // Both write without naming anyone; each reads the other as a task
    let (ok, sent) = agent_raw(
        server,
        &session2,
        json!({"cmd": "send", "text": "status?", "wait_ms": 3000}),
    );
    assert!(ok, "{sent}");
    assert_eq!(sent["to_agent"], "volna", "{sent}");
    let got = wait_until("volna reads it", || {
        inbox(mac, &volna).into_iter().find(|m| m.4 == "status?")
    });
    assert_eq!(
        (got.1.as_str(), got.3.as_str()),
        ("session-2", "task"),
        "{got:?}"
    );
    let (ok, sent) = agent_raw(
        mac,
        &volna,
        json!({"cmd": "send", "text": "all green", "wait_ms": 3000}),
    );
    assert!(ok, "{sent}");
    let got = wait_until("session-2 reads it", || {
        inbox(server, &session2)
            .into_iter()
            .find(|m| m.4 == "all green")
    });
    assert_eq!(
        (got.1.as_str(), got.3.as_str()),
        ("volna", "task"),
        "{got:?}"
    );

    // Asked again with nothing new: `unchanged`, no request
    let r = mac.owner_json(&[
        "agent",
        "connect",
        "volna",
        "server",
        "--agent",
        "session-2",
    ]);
    assert_eq!(r["other_side"]["state"], "unchanged", "{r}");
    assert!(pending(server).is_empty());

    // Disconnect from the mac; the server's request is approved from the mac with the password there (the mac's device
    // key, which the server's owner accepts once)
    let r = last_json(&mac.x(&["--json", "agent", "disconnect", "volna"]).stdout);
    assert_eq!(r["other_side"]["state"], "requested", "{r}");
    let id = r["other_side"]["id"].as_str().unwrap().to_string();
    assert!(counterpart(mac, "volna").is_null());
    assert_eq!(pending(server)[0]["action"], "disconnect_agent");
    wait_until("the mac's key offered on the server", || {
        server.json(&["devices"])["devices"][0]["offered"]
            .as_array()
            .filter(|k| !k.is_empty())
            .map(|_| ())
    });
    server.owner_json(&["devices", "confirm", "mac"]);
    wait_until("the request in the mac's view", || {
        mac.json(&["devices"])["devices"][0]["status"]["approvals"]
            .as_array()
            .filter(|a| a.iter().any(|x| x["id"] == id.as_str()))
            .map(|_| ())
    });
    let d = mac.owner_json(&["devices", "approve", "server", &id]);
    assert_eq!(d["state"], "approved", "{d}");
    wait_until("cleared on the server", || {
        counterpart(server, "session-2").is_null().then_some(())
    });

    // The first ask again, exactly (its approval was carried out minutes ago, and the line was removed since): a new
    // request, not the old one's result; a denial of it changes nothing
    let r = mac.owner_json(&[
        "agent",
        "connect",
        "volna",
        "server",
        "--agent",
        "session-2",
        "--tasks",
        "--peer-tasks",
    ]);
    assert_eq!(r["other_side"]["state"], "requested", "{r}");
    let id = r["other_side"]["id"].as_str().unwrap().to_string();
    let out = server.x(&["--json", "deny", &id]);
    assert!(out.status.success(), "{out:?}");
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        counterpart(server, "session-2").is_null(),
        "denied: nothing applied"
    );
}

/// The receiving side's own check: a computer that has the asker at ∞ only one way refuses the request before it
/// reads it, and nothing changes there; a computer that is not an own computer here is never asked.
///
/// Negative control (run once, 2026-10-06, seen failing this test): with the level check of `connect_ask_in` and of
/// `serve_device` off, the server at 4 made an approval request.
#[test]
fn a_computer_not_at_infinity_both_ways_gets_no_request() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["mac", "server"]);
    let (mac, server) = (&ns[0], &ns[1]);
    pair(mac, server, 5);
    mac.agent_add("volna", &["--local-level", "0"]);
    server.agent_add("session-2", &["--local-level", "0"]);
    wait_until("the server's agent in the mac's view", || {
        device_agent(mac, "server", "session-2")
    });
    // The server lowers the mac to 4: the mac still has the server at ∞ and asks
    server.owner_json(&["trust", "mac", "4"]);
    let r = mac.owner_json(&[
        "agent",
        "connect",
        "volna",
        "server",
        "--agent",
        "session-2",
        "--peer-tasks",
    ]);
    assert_eq!(r["other_side"]["state"], "refused", "{r}");
    assert_eq!(r["other_side"]["code"], "forbidden", "{r}");
    assert!(pending(server).is_empty(), "{:?}", pending(server));
    assert!(counterpart(server, "session-2").is_null());
    // This side is set all the same: the line is the owner's here
    assert_eq!(counterpart(mac, "volna")["agent"], "session-2");
}
