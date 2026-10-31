// SPDX-License-Identifier: AGPL-3.0-only
//! Chats per agent (`docs/CONTROL.md` §26, DECISIONS D-113): a link's messages fall into chats by the counterpart on
//! the contact's side (the person, or one of the contact's agents), derived by the daemon from the stored messages;
//! the owner's local settings of a chat (name, notifications, archive) stay on the node and are never sent; one agent
//! session of a node never reads another session's chat, through the CLI or MCP; `antenna connect` makes a session its
//! own agent that reads only what is addressed to it.
//!
//! Run: `cargo test -p antenna-cli --test chats` (from the workspace root; `cargo build -p antennad -p antenna-cli`
//! first when running a single package).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::time::{Duration, Instant};

use common::*;
use serde_json::{Value, json};

const T: Duration = Duration::from_secs(20);

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

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `antenna chats --contact <c>`.
fn chats(n: &Node, contact: &str) -> Vec<Value> {
    n.json(&["chats", "--contact", contact])["chats"]
        .as_array()
        .unwrap()
        .clone()
}

/// The chat with `agent` (`None`: the person chat).
fn chat(n: &Node, contact: &str, agent: Option<&str>) -> Value {
    chats(n, contact)
        .into_iter()
        .find(|c| c["agent"].as_str() == agent)
        .unwrap_or_else(|| panic!("{}: no chat {agent:?} with {contact}", n.name))
}

/// The texts of one chat's history page (`--chat <agent>` or `--person`).
fn chat_texts(n: &Node, contact: &str, which: &[&str]) -> Vec<String> {
    let mut a = vec!["history", contact, "--limit", "500"];
    a.extend_from_slice(which);
    n.json(&a)["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"] == "text")
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect()
}

fn texts(v: &Value) -> Vec<String> {
    v["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["kind"].is_null() || m["kind"] == "text")
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect()
}

/// One owner request on a fresh connection with a held session and the given protocol version: the final line.
fn raw_owner(n: &Node, proto: &str, req: Value) -> Value {
    use std::io::{BufRead, BufReader, Write};
    let held = n.held_session();
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = json!({"hello": {"proto": proto, "role": "owner", "session": held.token}});
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", json!({ "req": req })).unwrap();
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if v.get("ok").is_some() || v.get("err").is_some() {
            drop(held);
            return v;
        }
    }
    panic!("no reply");
}

/// One agent request over a raw connection with the token: the final line.
fn raw_agent(n: &Node, token: &str, req: Value) -> Value {
    use std::io::{BufRead, BufReader, Write};
    let mut s = std::os::unix::net::UnixStream::connect(n.dir.join("antennad.sock")).unwrap();
    let hello = json!({"hello": {"proto": "x-control/7", "role": "agent", "token": token}});
    writeln!(s, "{hello}").unwrap();
    writeln!(s, "{}", json!({ "req": req })).unwrap();
    for l in BufReader::new(s.try_clone().unwrap()).lines() {
        let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
        if v.get("ok").is_some() || v.get("err").is_some() {
            return v;
        }
    }
    panic!("no reply");
}

/// Maya's Mac (`mac`) and her server (`server`) with two agent sessions, `antenna-dev` and `volna-dev`, each with its
/// own token and "messages to everyone" off. Every message lands in the right chat on the Mac (and the server's owner
/// sees its own agents' conversations in the Mac's person chat); a chat's history and its unread count are only its
/// own; marking one chat read leaves the other's count; names, notifications and archive stay on the Mac.
#[test]
fn messages_land_in_the_chat_of_their_counterpart_and_settings_stay_local() {
    let root = tempfile::tempdir().unwrap();
    let mut ns = nodes(root.path(), &["mac", "server"]);
    let (mac, server) = (&ns[0], &ns[1]);
    pair(mac, server, 4);
    let dev = server.agent_add("antenna-dev", &["--local-level", "0"]);
    let volna = server.agent_add("volna-dev", &["--local-level", "0"]);

    // The sessions introduce themselves (their chats appear on the Mac), then the owner writes to each
    server.agent_ok(&dev, &["send", "mac", "antenna-dev here"]);
    server.agent_ok(&volna, &["send", "mac", "volna-dev here"]);
    wait_until("both agents known at the mac", T, || {
        mac.contact("server")["agents"]
            .as_array()
            .map_or(0, Vec::len)
            == 2
    });
    mac.send_to_agent("server", "antenna-dev", "build preview.8");
    mac.send_to_agent("server", "volna-dev", "check the Volna release");
    mac.send("server", "dinner at eight?");
    wait_until("three messages at the server", T, || {
        server.json(&["history", "mac", "--limit", "100"])["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["kind"] == "text" && m["direction"] == "in")
            .count()
            == 3
    });
    // Each session reads only its own; then it answers (a reply goes to whoever wrote what it read)
    let v = server.agent_ok(&dev, &["inbox"]);
    assert_eq!(texts(&v), vec!["build preview.8"], "{v}");
    let v = server.agent_ok(&volna, &["inbox"]);
    assert_eq!(texts(&v), vec!["check the Volna release"], "{v}");
    server.agent_ok(&dev, &["send", "mac", "preview.8 builds"]);
    server.agent_ok(&volna, &["send", "mac", "Volna release checked"]);
    wait_until("both replies at the mac", T, || {
        chat(mac, "server", Some("volna-dev"))["count"] == 3
            && chat(mac, "server", Some("antenna-dev"))["count"] == 3
    });

    // The Mac: the person chat first, then each agent's chat, the most recent first
    let cs = chats(mac, "server");
    let order: Vec<Option<&str>> = cs.iter().map(|c| c["agent"].as_str()).collect();
    assert_eq!(
        order,
        vec![None, Some("volna-dev"), Some("antenna-dev")],
        "{cs:?}"
    );
    let dev_chat = chat(mac, "server", Some("antenna-dev"));
    assert_eq!(
        (
            dev_chat["unread"].as_u64(),
            dev_chat["notify"].as_str(),
            dev_chat["notify_set"].as_bool()
        ),
        (Some(2), Some("asks"), None),
        "an agent's chat: 'only when it asks for me' by default: {dev_chat}"
    );
    assert_eq!(dev_chat["last"]["text"], "preview.8 builds", "{dev_chat}");
    assert_eq!(chat(mac, "server", None)["notify"], "all");
    assert_eq!(
        chat_texts(mac, "server", &["--chat", "antenna-dev"]),
        vec!["antenna-dev here", "build preview.8", "preview.8 builds"]
    );
    assert_eq!(
        chat_texts(mac, "server", &["--chat", "volna-dev"]),
        vec![
            "volna-dev here",
            "check the Volna release",
            "Volna release checked"
        ]
    );
    assert_eq!(
        chat_texts(mac, "server", &["--person"]),
        vec!["dinner at eight?"]
    );
    // The whole link is still there, in order
    assert_eq!(chat_texts(mac, "server", &[]).len(), 7);

    // Marking one chat read leaves the other's count and the link's total follows
    let total = mac.contact("server")["unread"].as_u64().unwrap();
    assert_eq!(total, 4);
    let r = raw_owner(
        mac,
        "x-control/7",
        json!({"cmd": "mark_read", "contact": "server", "up_to_seq": i64::MAX, "chat": {"agent": "antenna-dev"}}),
    );
    assert!(r.get("ok").is_some(), "{r}");
    assert_eq!(chat(mac, "server", Some("antenna-dev"))["unread"], 0);
    assert_eq!(chat(mac, "server", Some("volna-dev"))["unread"], 2);
    assert_eq!(mac.contact("server")["unread"], 2);

    // A local name, notifications, archive: on the Mac only
    let v = mac.json(&[
        "chats",
        "rename",
        "server",
        "--agent",
        "antenna-dev",
        "Antenna development",
    ]);
    assert_eq!(
        (v["type"].as_str(), v["name"].as_str()),
        (Some("chat"), Some("Antenna development")),
        "{v}"
    );
    mac.json(&["chats", "notify", "server", "--agent", "volna-dev", "off"]);
    assert_eq!(
        (
            chat(mac, "server", Some("volna-dev"))["notify"].as_str(),
            chat(mac, "server", Some("volna-dev"))["notify_set"].as_bool()
        ),
        (Some("off"), Some(true))
    );
    mac.json(&[
        "chats",
        "notify",
        "server",
        "--agent",
        "volna-dev",
        "default",
    ]);
    assert_eq!(chat(mac, "server", Some("volna-dev"))["notify"], "asks");
    mac.json(&["chats", "archive", "server", "volna-dev"]);
    assert_eq!(chat(mac, "server", Some("volna-dev"))["archived"], true);
    // Something new in it brings it back; its history stayed all along
    std::thread::sleep(Duration::from_millis(5));
    server.agent_ok(&volna, &["send", "mac", "one more thing"]);
    wait_until("the archived chat is back", T, || {
        chat(mac, "server", Some("volna-dev"))["archived"].is_null()
    });
    assert!(
        chat(mac, "server", Some("volna-dev"))["archived_ms"].is_u64(),
        "it remembers when it was archived"
    );
    assert_eq!(chat_texts(mac, "server", &["--chat", "volna-dev"]).len(), 4);
    mac.json(&["chats", "unarchive", "server", "volna-dev"]);
    assert!(chat(mac, "server", Some("volna-dev"))["archived_ms"].is_null());
    // The person chat is the contact itself: not archived
    let r = raw_owner(
        mac,
        "x-control/7",
        json!({"cmd": "chat_set", "contact": "server", "archived": true}),
    );
    assert_eq!(r["err"]["code"], "bad_request", "{r}");
    // Bad settings are refused
    for bad in [
        json!({"cmd": "chat_set", "contact": "server", "agent": "antenna-dev", "notify": "sometimes"}),
        json!({"cmd": "chat_set", "contact": "server", "agent": "antenna-dev", "name": "two\nlines"}),
        json!({"cmd": "chat_set", "contact": "server", "agent": "antenna dev"}),
        json!({"cmd": "history", "contact": "server", "chat": {"agent": "a b"}}),
        json!({"cmd": "history", "contact": "server", "chat": {"agent": "x", "extra": 1}}),
    ] {
        let r = raw_owner(mac, "x-control/7", bad.clone());
        assert_eq!(r["err"]["code"], "bad_request", "{bad} → {r}");
    }
    // Nothing of the Mac's settings reached the server: not in its history, not in its view of the contact
    let everything = format!(
        "{} {} {}",
        server.json(&["history", "mac", "--limit", "500"]),
        server.json(&["contacts"]),
        server.json(&["chats"])
    );
    assert!(
        !everything.contains("Antenna development"),
        "a local name never leaves the node: {everything}"
    );

    // The server's owner sees its agents' conversations in the Mac's person chat, filtered by its own agents
    let srv = chats(server, "mac");
    assert_eq!(
        srv.len(),
        1,
        "the Mac has no agents: one chat there: {srv:?}"
    );
    assert_eq!(srv[0]["count"], 8, "{srv:?}");

    // The name is the Mac's own, kept in its encrypted database across a restart
    ns[0].stop();
    ns[0].start();
    ns[0].unlock();
    ns[0].login();
    assert_eq!(
        chat(&ns[0], "server", Some("antenna-dev"))["name"],
        "Antenna development"
    );
}

/// A chat with a known agent of the contact can be started before anyone writes in it; an agent nobody announced
/// cannot. `chat_set` tells the owner's x-control/7 subscriptions (another window, `antenna events`), never older ones
/// and never an agent's.
#[test]
fn a_new_chat_needs_a_known_agent_and_changes_reach_owner_subscriptions_only() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["mac", "server"]);
    let (mac, server) = (&ns[0], &ns[1]);
    pair(mac, server, 4);
    let dev = server.agent_add("antenna-dev", &["--local-level", "0"]);
    let watcher = mac.agent_add("watcher", &["--local-level", "0", "--everyone"]);
    server.agent_ok(&dev, &["send", "mac", "hello"]);
    wait_until("the agent is known", T, || {
        mac.contact("server")["agents"]
            .as_array()
            .map_or(0, Vec::len)
            == 1
    });

    let out = mac.x(&["--json", "chats", "new", "server", "nobody-here"]);
    assert!(!out.status.success(), "{out:?}");
    assert_eq!(last_json(&out.stdout)["error"], "not_found", "{out:?}");

    // Subscriptions: the owner's v7 and v6, the agent's
    let mut v7 = Proc::spawn({
        let mut c = mac.cmd();
        c.args(["--json", "events"]);
        c
    });
    v7.event("subscribed", T);
    let mut agent_sub = Proc::spawn({
        let mut c = mac.agent_cmd(&watcher);
        c.args(["--json", "events"]);
        c
    });
    agent_sub.event("subscribed", T);
    let held = mac.held_session();
    let v6 = {
        use std::io::Write;
        let mut s = std::os::unix::net::UnixStream::connect(mac.dir.join("antennad.sock")).unwrap();
        writeln!(
            s,
            "{}",
            json!({"hello": {"proto": "x-control/6", "role": "owner", "session": held.token}})
        )
        .unwrap();
        writeln!(s, "{}", json!({"req": {"cmd": "subscribe"}})).unwrap();
        s.set_read_timeout(Some(T)).unwrap();
        std::io::BufReader::new(s)
    };

    let v = mac.json(&["chats", "new", "server", "antenna-dev"]);
    assert_eq!(
        (v["saved"].as_bool(), v["count"].as_u64()),
        (Some(true), Some(1)),
        "{v}"
    );
    let e = v7.event("chat", T);
    assert_eq!(
        (e["agent"].as_str(), e["contact"].as_str()),
        (Some("antenna-dev"), Some("server")),
        "{e}"
    );
    // Events reach each subscription in order: a message after the change tells when the change would have arrived
    server.send_to_everyone("mac", "after the change");
    agent_sub.event("message_fact", T);
    assert!(
        agent_sub.seen.iter().all(|e| e["kind"] != "chat"),
        "an agent never learns the owner's chat settings: {:?}",
        agent_sub.seen
    );
    {
        use std::io::BufRead;
        let mut kinds = Vec::new();
        for l in v6.lines() {
            let v: Value = serde_json::from_str(&l.unwrap()).unwrap();
            let k = v["event"]["kind"].as_str().unwrap_or_default().to_string();
            let done = k == "message";
            kinds.push(k);
            if done {
                break;
            }
        }
        assert!(
            !kinds.iter().any(|k| k == "chat"),
            "a v6 subscription gets no v7 event: {kinds:?}"
        );
    }
    drop(held);
    let _ = agent_sub.child.kill();
    let _ = v7.child.kill();
}

/// The privacy between sessions (D-91, D-113) through MCP: two agent sessions of one node, each an MCP host with its
/// own token. Each reads only what is addressed to it; neither reads the other's chat, the person's or the owner's;
/// the MCP server has no tool that lists chats or reads one, and the agent role has no chat command at all.
#[test]
fn one_session_cannot_read_another_sessions_chat_through_mcp() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["mac", "server"]);
    let (mac, server) = (&ns[0], &ns[1]);
    pair(mac, server, 5);
    let dev = server.agent_add("antenna-dev", &["--local-level", "0"]);
    let volna = server.agent_add("volna-dev", &["--local-level", "0"]);
    let mut m_dev = Mcp::start(server, &dev);
    let mut m_volna = Mcp::start(server, &volna);
    let (e, _) = m_dev.call(
        "send_message",
        json!({"contact": "mac", "text": "antenna-dev here"}),
    );
    assert!(!e);
    let (e, _) = m_volna.call(
        "send_message",
        json!({"contact": "mac", "text": "volna-dev here"}),
    );
    assert!(!e);
    wait_until("both agents known at the mac", T, || {
        mac.contact("server")["agents"]
            .as_array()
            .map_or(0, Vec::len)
            == 2
    });
    mac.send_to_agent("server", "antenna-dev", "secret plan for antenna");
    mac.send_to_agent("server", "volna-dev", "secret plan for volna");
    mac.send("server", "for the owner only");
    wait_until("three messages at the server", T, || {
        server.json(&["history", "mac", "--limit", "100"])["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["direction"] == "in" && m["kind"] == "text")
            .count()
            == 3
    });
    let read = |m: &mut Mcp| {
        let (e, v) = m.call("read_inbox", json!({}));
        assert!(!e, "{v}");
        v["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x["text"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(read(&mut m_dev), vec!["secret plan for antenna"]);
    assert_eq!(read(&mut m_volna), vec!["secret plan for volna"]);
    // Nothing else, ever: not after waiting, not by asking again
    let (_, w) = m_dev.call("wait_for_message", json!({"timeout_secs": 1}));
    assert!(w["pending"].as_array().is_none_or(Vec::is_empty), "{w}");
    assert!(read(&mut m_dev).is_empty());
    assert!(read(&mut m_volna).is_empty());
    // No tool lists chats or reads one by name
    for name in m_dev.tool_names() {
        assert!(
            !name.contains("chat") && !name.contains("history"),
            "an MCP tool over chats: {name}"
        );
    }
    // A session that writes to a name nobody has at the contact is told so, not "delivered" (PROTOCOL §23)
    let (e, s) = m_dev.call(
        "send_message",
        json!({"contact": "mac", "text": "chatgpt, are you there?", "to_agent": "chatgpt"}),
    );
    assert!(!e, "{s}");
    assert_eq!(s["no_agent"], true, "{s}");
    m_dev.stop();
    m_volna.stop();
    // The agent role has no chat command at all, and choosing a chat of the history is the owner's (a third agent:
    // the two tokens above stay bound to their MCP hosts, D-28)
    let other = server.agent_add("other", &["--local-level", "0"]);
    for req in [
        json!({"cmd": "chats"}),
        json!({"cmd": "chat_set", "contact": "mac", "agent": "x", "name": "n"}),
    ] {
        let r = raw_agent(server, &other, req.clone());
        assert_eq!(r["err"]["code"], "unknown_command", "{req} → {r}");
    }
    let r = raw_agent(
        server,
        &other,
        json!({"cmd": "history", "contact": "mac", "chat": {"agent": "volna-dev"}}),
    );
    assert!(r.get("err").is_some(), "{r}");
    let (c, v) = server.agent(&other, &["chats"]);
    assert_eq!(
        (c, v["error"].as_str()),
        (2, Some("unknown_command")),
        "{v}"
    );
    let (c, _) = server.agent(&other, &["history", "mac", "--chat", "volna-dev"]);
    assert_eq!(c, 2, "--chat is the owner's");
    // Its own history: nothing of the two sessions' chats or the owner's
    let v = server.agent_ok(&other, &["history", "mac", "--limit", "100"]);
    assert!(texts(&v).is_empty(), "{v}");
}

/// `antenna connect claude-code --agent <name>`: the session's agent with a token file and "messages to everyone"
/// off; Claude Code's own command for this folder only (here a stand-in `claude` that records its arguments); a hello
/// that makes the chat appear on the other side at once; a second run keeps the token file.
#[test]
fn connect_makes_a_session_its_own_agent() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["mac", "server"]);
    let (mac, server) = (&ns[0], &ns[1]);
    // Own computers (level 5, D-99): what a session writes to the Mac goes without asking
    pair(mac, server, 5);
    let bin = root.path().join("bin");
    let project = root.path().join("volna");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    let calls = root.path().join("claude-calls");
    let fake = bin.join("claude");
    std::fs::write(
        &fake,
        format!(
            "#!/bin/sh\nprintf '%s|' \"$PWD\" \"$@\" >> '{}'\necho >> '{}'\n",
            calls.display(),
            calls.display()
        ),
    )
    .unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let run = |extra: &[&str]| {
        let mut c = server.cmd();
        c.env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .args([
                "--json",
                "connect",
                "claude-code",
                "--agent",
                "volna-dev",
                "--dir",
            ])
            .arg(&project)
            .args(extra)
            .arg("--password-stdin")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let mut ch = c.spawn().unwrap();
        {
            use std::io::Write;
            let _ = writeln!(ch.stdin.take().unwrap(), "{}", server.password);
        }
        let out = ch.wait_with_output().unwrap();
        assert!(out.status.success(), "{out:?}");
        last_json(&out.stdout)
    };
    let v = run(&[
        "--yes",
        "--hello",
        "mac",
        "--instructions",
        "--allow",
        "antenna-tools",
    ]);
    // The folder is set up with the same yes (D-124): the template and the rule the owner chose
    assert_eq!(v["set_up"], true, "{v}");
    let agents_md = std::fs::read_to_string(project.join("AGENTS.md")).unwrap();
    assert!(agents_md.contains("the agent `volna-dev`"), "{agents_md}");
    assert_eq!(
        std::fs::read_to_string(project.join("CLAUDE.md")).unwrap(),
        "@AGENTS.md\n"
    );
    assert!(
        std::fs::read_to_string(project.join(".claude/settings.json"))
            .unwrap()
            .contains("\"mcp__antenna\"")
    );
    assert_eq!(
        (
            v["created"].as_bool(),
            v["hello"].as_str(),
            v["everyone"].as_bool(),
            v["ran"].as_bool()
        ),
        (Some(true), Some("sent"), Some(false), Some(true)),
        "{v}"
    );
    let token_file = v["token_file"].as_str().unwrap().to_string();
    assert!(std::path::Path::new(&token_file).exists());
    let recorded = std::fs::read_to_string(&calls).unwrap();
    let lines: Vec<&str> = recorded.lines().collect();
    assert_eq!(lines.len(), 2, "{recorded}");
    // The fake claude records $PWD, the canonical path (on macOS /private/var/…, not the tempdir's /var/…)
    let project_dir = project.canonicalize().unwrap();
    assert!(
        lines[0].starts_with(&format!(
            "{}|mcp|remove|--scope|local|antenna",
            project_dir.display()
        )),
        "{recorded}"
    );
    assert!(
        lines[1].starts_with(&format!(
            "{}|mcp|add|--scope|local|antenna|--|",
            project_dir.display()
        )) && lines[1].ends_with(&format!("|mcp|--token-file|{token_file}|")),
        "{recorded}"
    );
    // The agent reads only what is addressed to it
    let agents = server.json(&["agent", "list"]);
    let a = agents["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["name"] == "volna-dev")
        .unwrap()
        .clone();
    assert_eq!(a["everyone"], false, "{a}");
    // The hello made the chat appear at the Mac
    wait_until("the chat at the mac", T, || {
        chats(mac, "server")
            .iter()
            .any(|c| c["agent"] == "volna-dev")
    });
    // A second run: the same token file, nothing new to type into Claude Code's settings but the same entry again
    let v = run(&["--print"]);
    assert_eq!(
        (
            v["created"].as_bool(),
            v["new_token"].as_bool(),
            v["ran"].as_bool(),
            v["token_file"].as_str()
        ),
        (
            Some(false),
            Some(false),
            Some(false),
            Some(token_file.as_str())
        ),
        "{v}"
    );
    assert_eq!(
        std::fs::read_to_string(&calls).unwrap().lines().count(),
        2,
        "--print runs nothing"
    );
    // Codex: the session's command line. At level 4 the hello of a level-5 agent waits for the owner (no write down,
    // SPEC §9): reported, not a failure of the connection
    let out = server.owner(&["trust", "mac", "4"]);
    assert!(out.status.success(), "{out:?}");
    let mut c = server.cmd();
    c.args([
        "--json",
        "connect",
        "codex",
        "--agent",
        "codex-dev",
        "--hello",
        "mac",
        "--password-stdin",
    ])
    .stdin(std::process::Stdio::piped())
    .stdout(std::process::Stdio::piped())
    .stderr(std::process::Stdio::piped());
    let mut ch = c.spawn().unwrap();
    {
        use std::io::Write;
        let _ = writeln!(ch.stdin.take().unwrap(), "{}", server.password);
    }
    let out = ch.wait_with_output().unwrap();
    assert!(out.status.success(), "{out:?}");
    let v = last_json(&out.stdout);
    assert_eq!(
        (v["ran"].as_bool(), v["hello"].as_str()),
        (Some(false), Some("approval_required")),
        "{v}"
    );
    let cmd = v["commands"][0].as_array().unwrap();
    assert_eq!(cmd[0], "codex");
    assert!(
        cmd[4]
            .as_str()
            .unwrap()
            .contains(r#"["mcp","--token-file","#),
        "{v}"
    );
}

/// An older-version node: `ANTENNA_PREVIEW7_BIN_DIR` holds `antennad` and `antenna` of release `v0.1.0-preview.7`
/// (the release's Linux CLI archive, `bin/` unpacked).
fn preview7_bin() -> Option<std::path::PathBuf> {
    std::env::var_os("ANTENNA_PREVIEW7_BIN_DIR").map(Into::into)
}

/// Migration from a preview.7 node (D-113): its history, written when the window showed threads, maps into chats as
/// soon as the new daemon runs on the same data: every message is in the chat of its counterpart, the unread counts
/// are what preview.7 counted, nothing is lost, and the old daemon's database takes the new table without a step.
#[test]
#[ignore = "needs ANTENNA_PREVIEW7_BIN_DIR with antennad/antenna of v0.1.0-preview.7"]
fn a_preview7_history_maps_into_chats() {
    let Some(dir) = preview7_bin() else {
        panic!("ANTENNA_PREVIEW7_BIN_DIR is not set");
    };
    let root = tempfile::tempdir().unwrap();
    let mut mac = Node::new(root.path(), "mac", Net::Local);
    mac.bin_dir = Some(dir);
    mac.start();
    mac.init();
    let v = mac.x(&["--version"]);
    assert!(
        String::from_utf8_lossy(&v.stdout).contains("0.1.0-preview.7"),
        "{v:?}"
    );
    let mut server = Node::new(root.path(), "server", Net::Local);
    server.start();
    server.init();
    pair(&mac, &server, 4);
    let dev = server.agent_add("antenna-dev", &["--local-level", "0"]);
    let volna = server.agent_add("volna-dev", &["--local-level", "0"]);
    server.agent_ok(&dev, &["send", "mac", "antenna-dev here"]);
    server.agent_ok(&volna, &["send", "mac", "volna-dev here"]);
    server.send("mac", "from the server's owner");
    wait_until("three messages at the old mac", T, || {
        mac.json(&["history", "server", "--limit", "100"])["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["kind"] == "text")
            .count()
            == 3
    });
    mac.send_to_agent("server", "antenna-dev", "build it");
    mac.send_to_agent("server", "volna-dev", "check it");
    server.agent_ok(&dev, &["inbox", "--wait", "--timeout", "10s"]);
    server.agent_ok(&dev, &["send", "mac", "built"]);
    wait_until("the reply at the old mac", T, || {
        mac.json(&["history", "server", "--limit", "100"])["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["text"] == "built")
    });
    let before = mac.json(&["history", "server", "--limit", "500"]);
    let before_ids: Vec<String> = before["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap().to_string())
        .collect();
    let unread_before = mac.contact("server")["unread"].as_u64().unwrap();
    // The old daemon has no chats
    let out = mac.x(&["--json", "chats"]);
    assert!(!out.status.success(), "preview.7 has no chats: {out:?}");

    // The same data under the new daemon
    mac.stop();
    mac.bin_dir = None;
    mac.start();
    mac.unlock();
    mac.login();
    let after = mac.json(&["history", "server", "--limit", "500"]);
    let after_ids: Vec<String> = after["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(after_ids, before_ids, "nothing lost or reordered");
    let cs = chats(&mac, "server");
    let by = |a: Option<&str>| {
        cs.iter()
            .find(|c| c["agent"].as_str() == a)
            .unwrap()
            .clone()
    };
    assert_eq!(
        (by(None)["count"].as_u64(), by(None)["unread"].as_u64()),
        (Some(1), Some(1)),
        "{cs:?}"
    );
    assert_eq!(
        (
            by(Some("antenna-dev"))["count"].as_u64(),
            by(Some("antenna-dev"))["unread"].as_u64()
        ),
        (Some(3), Some(2)),
        "{cs:?}"
    );
    assert_eq!(
        (
            by(Some("volna-dev"))["count"].as_u64(),
            by(Some("volna-dev"))["unread"].as_u64()
        ),
        (Some(2), Some(1)),
        "{cs:?}"
    );
    let sum: u64 = cs.iter().map(|c| c["unread"].as_u64().unwrap()).sum();
    assert_eq!(
        sum, unread_before,
        "the chats' counts add up to what preview.7 counted"
    );
    assert_eq!(
        chat_texts(&mac, "server", &["--chat", "antenna-dev"]),
        vec!["antenna-dev here", "build it", "built"]
    );
    assert_eq!(
        chat_texts(&mac, "server", &["--person"]),
        vec!["from the server's owner"]
    );
    // And the new settings work on the migrated data
    mac.json(&[
        "chats",
        "rename",
        "server",
        "--agent",
        "volna-dev",
        "Volna development",
    ]);
    assert_eq!(by_name(&mac, "server", "volna-dev"), "Volna development");
}

fn by_name(n: &Node, contact: &str, agent: &str) -> String {
    chat(n, contact, Some(agent))["name"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn verified(n: &Node, contact: &str) -> Value {
    n.json(&["verify", contact])["status"].clone()
}

/// All messages of a link, receipts included.
fn all(n: &Node, contact: &str) -> Vec<Value> {
    n.json(&["history", contact, "--limit", "500"])["messages"]
        .as_array()
        .unwrap()
        .clone()
}

/// A message addressed to an agent the recipient's node does not have (PROTOCOL §23, `no-agent/0`) is answered with
/// a signed `deliver` / `no_such_agent` receipt: the sender is told at once, with the agents the contact announced,
/// instead of seeing "delivered"; the recipient's owner still has the message; history verification holds. An agent
/// that exists gets no such answer, and a contact below level 3 cannot probe which names exist.
#[test]
fn a_message_to_an_agent_nobody_has_is_answered_not_delivered() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["mac", "server"]);
    let (mac, server) = (&ns[0], &ns[1]);
    pair(mac, server, 4);
    let codex = server.agent_add("codex", &["--local-level", "0"]);
    server.agent_ok(&codex, &["send", "mac", "codex here"]);
    wait_until("codex announced", T, || {
        mac.contact("server")["agents"]
            .as_array()
            .map_or(0, Vec::len)
            == 1
    });

    // Nobody there is called chatgpt: the reply says so, with the names one can address
    let s = mac.json(&[
        "send",
        "--to-agent",
        "chatgpt",
        "server",
        "draw three avatars",
    ]);
    assert_eq!(
        (
            s["status"].as_str(),
            s["no_agent"].as_bool(),
            s["peer_agents"].clone()
        ),
        (Some("delivered"), Some(true), json!(["codex"])),
        "{s}"
    );
    let out = mac.x(&["send", "--to-agent", "chatgpt", "server", "again, please"]);
    let text =
        String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    assert!(
        text.contains("no agent named chatgpt") && text.contains("their agents: codex"),
        "{text}"
    );
    // The mark stays in the history; the receipt is in both copies; the server's owner still has the message
    let h = all(mac, "server");
    let mine = h
        .iter()
        .find(|m| m["text"] == "draw three avatars")
        .unwrap();
    assert_eq!(mine["no_agent"], true, "{mine}");
    assert!(
        h.iter().any(|m| m["kind"] == "receipt"
            && m["receipt"]["action"] == "deliver"
            && m["receipt"]["decision"] == "no_such_agent"),
        "{h:?}"
    );
    let sh = all(server, "mac");
    assert!(
        sh.iter().any(|m| m["text"] == "draw three avatars"),
        "{sh:?}"
    );
    // An agent that is there: delivered, no answer; also one that exists and never wrote
    let s = mac.json(&["send", "--to-agent", "codex", "server", "please review"]);
    assert_eq!(
        (s["status"].as_str(), s["no_agent"].as_bool()),
        (Some("delivered"), None),
        "{s}"
    );
    server.agent_add("quiet", &["--local-level", "0"]);
    let s = mac.json(&["send", "--to-agent", "quiet", "server", "are you there?"]);
    assert_eq!(
        s["no_agent"].as_bool(),
        None,
        "an existing agent that never wrote: {s}"
    );
    // Both copies of the history still agree
    wait_until("history verified", T, || {
        verified(mac, "server")["state"] == "verified"
            && verified(server, "mac")["state"] == "verified"
    });
    assert_eq!(
        verified(mac, "server")["fingerprint"],
        verified(server, "mac")["fingerprint"]
    );
}

/// Below level 3 the recipient answers nothing (PROTOCOL §23): a contact it trusts less cannot probe which agent names
/// exist on its node. Levels 1–2 are relay only, so the two nodes talk through a local relay.
#[test]
fn a_contact_below_level_3_cannot_probe_agent_names() {
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let ns: Vec<Node> = ["mac", "server"]
        .iter()
        .map(|n| {
            let mut x = Node::new(root.path(), n, Net::LocalRelay(relay.url.clone()));
            x.start();
            x.init();
            x
        })
        .collect();
    let (mac, server) = (&ns[0], &ns[1]);
    pair(mac, server, 2);
    assert_eq!(mac.send("server", "hello")["status"], "delivered");
    let before = all(server, "mac").len();
    let s = mac.json(&["send", "--to-agent", "nobody", "server", "hello?"]);
    assert_eq!(s["no_agent"].as_bool(), None, "{s}");
    std::thread::sleep(Duration::from_millis(1500));
    let after = all(server, "mac");
    assert_eq!(
        after.len(),
        before + 1,
        "the message, no receipt: {after:?}"
    );
    assert!(
        all(mac, "server").iter().all(|m| m["no_agent"].is_null()),
        "nothing marked"
    );
}

/// A preview.7 node has no `no-agent/0`: it gets no such receipt (it would refuse the unknown action), and a message
/// from it to an unknown agent is not answered; history verification holds both ways.
#[test]
#[ignore = "needs ANTENNA_PREVIEW7_BIN_DIR with antennad/antenna of v0.1.0-preview.7"]
fn a_preview7_node_neither_gets_nor_triggers_the_no_agent_receipt() {
    let Some(dir) = preview7_bin() else {
        panic!("ANTENNA_PREVIEW7_BIN_DIR is not set");
    };
    let root = tempfile::tempdir().unwrap();
    let mut old = Node::new(root.path(), "old", Net::Local);
    old.bin_dir = Some(dir);
    old.start();
    old.init();
    let mut new = Node::new(root.path(), "new", Net::Local);
    new.start();
    new.init();
    pair(&new, &old, 4);
    assert_eq!(
        old.send("new", "hello from preview.7")["status"],
        "delivered"
    );
    let t0 = Instant::now();
    let s = new.json(&["send", "--to-agent", "chatgpt", "old", "to nobody there"]);
    assert_eq!(
        (s["status"].as_str(), s["no_agent"].as_bool()),
        (Some("delivered"), None),
        "{s}"
    );
    assert!(
        t0.elapsed() < Duration::from_millis(1400),
        "no wait for an answer that cannot come"
    );
    assert_eq!(
        old.json(&["send", "--to-agent", "ghost", "new", "to nobody here"])["status"],
        "delivered"
    );
    std::thread::sleep(Duration::from_millis(1500));
    assert!(
        all(&new, "old")
            .iter()
            .all(|m| m["kind"] != "receipt" || m["receipt"]["action"] != "deliver"),
        "no receipt for a node without the feature"
    );
    wait_until("history verified", T, || {
        verified(&new, "old")["state"] == "verified" && verified(&old, "new")["state"] == "verified"
    });
}
