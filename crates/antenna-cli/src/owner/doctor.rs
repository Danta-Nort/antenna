// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna doctor` (D-96 phase 1, `docs/LOCAL-ASSISTANT.md` §4): read-only checks built only from existing owner
//! requests, `status`, then `contacts` and `agent_list` when the node is unlocked. It changes nothing and runs no fix:
//! each finding says what to do (the window offers the fixes). The codes are stable: `daemon_down`, `not_initialized`,
//! `keys_locked`, `relay_disabled`, `relay_unreachable`, `token_bound_elsewhere`.

use std::{
    io::{IsTerminal, Write},
    path::Path,
    process::ExitCode,
};

use antenna_proto::control::{AgentInfo, ContactInfo, Reply, Request, StatusReply};
use serde::Serialize;
use serde_json::{Value, json};

use super::Owner;
use crate::client::{
    CliResult, EXIT_FAIL, EXIT_NOPERM, EXIT_TEMPFAIL, Fail, call_owner, socket_path,
};
use crate::output::{ago, clean, print_json};
use crate::{Cli, login_from_terminal, print_fail};

/// A refused MCP host is reported while it runs, or for this long after the refusal (its app may have been closed
/// after showing "couldn't start", and the owner wants to know why).
const REFUSED_RECENT_MS: u64 = 10 * 60 * 1000;

/// Why the link and agent checks did not run without an owner session, and what to do.
const LOGIN_FIRST: &str =
    "link and agent checks need an owner session: run antenna login, then antenna doctor again";

/// What `antenna doctor --json` prints.
#[derive(Debug, Serialize)]
struct Report {
    /// The daemon's state (`uninitialized` / `locked` / `unlocked`), or `unreachable`.
    state: String,
    /// The daemon's version, when it answered.
    daemon: Option<String>,
    /// The relay setting (`n0`, `disabled` or a URL), when the daemon answered.
    relay: Option<String>,
    /// What is wrong, most serious first.
    findings: Vec<Finding>,
    /// Checks that did not run, and why.
    #[serde(skip_serializing_if = "Option::is_none")]
    skipped: Option<Skipped>,
    /// When the checks ran, Unix ms.
    checked_ms: u64,
}

/// One problem.
#[derive(Debug, Serialize)]
struct Finding {
    /// Stable code.
    code: &'static str,
    /// `error` (something does not work), `warning` (works partly or will fail), `info`.
    severity: &'static str,
    /// The contact it is about.
    #[serde(skip_serializing_if = "Option::is_none")]
    contact: Option<String>,
    /// The agent it is about.
    #[serde(skip_serializing_if = "Option::is_none")]
    agent: Option<String>,
    /// What is wrong, in words.
    detail: String,
    /// What to do.
    fix: String,
    /// The facts behind it.
    #[serde(skip_serializing_if = "Value::is_null")]
    facts: Value,
}

impl Finding {
    fn new(code: &'static str, severity: &'static str, detail: String, fix: String) -> Self {
        Self {
            code,
            severity,
            contact: None,
            agent: None,
            detail,
            fix,
            facts: Value::Null,
        }
    }
}

/// Checks that did not run.
#[derive(Debug, Serialize)]
struct Skipped {
    /// Why: the error code (`login_required`, `agent_process`, …).
    code: String,
    /// In words, with what to do.
    detail: String,
}

/// Runs the checks and prints the report. Exit 0 when the checks ran (with findings or not), 75 when the daemon does
/// not answer (D-23), with the report printed either way.
pub(crate) fn run(cli: &Cli, rt: &tokio::runtime::Runtime) -> ExitCode {
    let o = Owner {
        path: socket_path(&cli.socket, &cli.data_dir),
        json: cli.json,
    };
    let now = now_ms();
    let mut report = Report {
        state: String::new(),
        daemon: None,
        relay: None,
        findings: Vec::new(),
        skipped: None,
        checked_ms: now,
    };
    let status = match rt.block_on(o.call(Request::Status {})) {
        Ok(Reply::Status(s)) => s,
        Ok(_) => {
            let f = Fail::new(EXIT_FAIL, "protocol", "unexpected reply to status");
            return print_fail(&f, o.json, "doctor");
        }
        Err(f) if f.code == "daemon_unavailable" => {
            report.state = "unreachable".into();
            report.findings.push(Finding::new(
                "daemon_down",
                "error",
                f.message,
                daemon_down_fix().into(),
            ));
            print(&report, o.json);
            return ExitCode::from(EXIT_TEMPFAIL);
        }
        Err(f) => return print_fail(&f, o.json, "doctor"),
    };
    report.state = status.state.clone();
    report.daemon = Some(status.daemon.clone());
    report.relay = Some(status.relay.clone());
    match status.state.as_str() {
        "uninitialized" => report.findings.push(Finding::new(
            "not_initialized",
            "error",
            "this node has no keys yet".into(),
            "Create them: antenna init (or open the Antenna window).".into(),
        )),
        "locked" => report.findings.push(Finding::new(
            "keys_locked",
            "error",
            "the node is locked: its links are down and agents get no answers until it is unlocked"
                .into(),
            "Unlock it: antenna unlock (or sign in in the Antenna window).".into(),
        )),
        _ => match lists(rt, cli, &o.path) {
            Ok((contacts, agents)) => {
                relay_findings(&status, &contacts, &mut report.findings);
                token_findings(&agents, now, &mut report.findings);
            }
            Err(f) => {
                let detail = if f.code == "login_required" {
                    String::from(LOGIN_FIRST)
                } else {
                    format!("link and agent checks did not run: {}", f.message)
                };
                report.skipped = Some(Skipped {
                    code: f.code,
                    detail,
                });
            }
        },
    }
    print(&report, o.json);
    ExitCode::SUCCESS
}

/// What to do when no daemon answers: the way to start one on this system. On Windows the window starts antennad
/// (there is no service), and the window is the Antenna shortcut.
fn daemon_down_fix() -> &'static str {
    if cfg!(windows) {
        "Start Antenna: open the Antenna window (the Antenna shortcut in the Start menu or on the desktop), which \
         starts antennad; then run antenna doctor again."
    } else {
        "Start Antenna: open the Antenna window, or run antennad (Linux, installed as a user service: \
         systemctl --user start antennad); then run antenna doctor again."
    }
}

/// `contacts` and `agent_list`. They need an owner session: in a terminal without one the password is asked once, as
/// for every owner command; without a terminal the caller reports what `status` gave.
fn lists(
    rt: &tokio::runtime::Runtime,
    cli: &Cli,
    path: &Path,
) -> CliResult<(Vec<ContactInfo>, Vec<AgentInfo>)> {
    let r = rt.block_on(fetch(path));
    match r {
        Err(f) if f.code == "login_required" && std::io::stdin().is_terminal() => {
            login_from_terminal(rt, cli)?;
            rt.block_on(fetch(path))
        }
        r => r,
    }
}

async fn fetch(path: &Path) -> CliResult<(Vec<ContactInfo>, Vec<AgentInfo>)> {
    let (hello, reply) = call_owner(path, Request::Contacts {}).await?;
    // Inside an agent's process tree the daemon answers as that agent (D-28): no links, no agents to check.
    if hello.forced {
        return Err(Fail::new(
            EXIT_NOPERM,
            "agent_process",
            format!(
                "this terminal runs inside the process tree of agent {:?}, which sees no link or agent details; run \
                 antenna doctor from a separate terminal",
                hello.agent.as_deref().unwrap_or("?")
            ),
        ));
    }
    let Reply::Contacts(c) = reply else {
        return Err(Fail::new(
            EXIT_FAIL,
            "protocol",
            "unexpected reply to contacts",
        ));
    };
    let Reply::Agents { agents } = call_owner(path, Request::AgentList {}).await?.1 else {
        return Err(Fail::new(
            EXIT_FAIL,
            "protocol",
            "unexpected reply to agent list",
        ));
    };
    Ok((c.contacts, agents))
}

/// Levels 1–2 connect only through the relay (SPEC §4, Q-1).
fn relay_only(c: &ContactInfo) -> bool {
    c.net_mode == "relay_only" || c.trust <= 2
}

/// `relay_disabled` (the node runs without a relay and has links that need one) and `relay_unreachable` (a running
/// link endpoint is not connected to its home relay: `contacts[].transport.relay`). A link whose relay is down but
/// which is connected anyway (`contacts[].transport.connected`, over LAN or a direct path, PG-32) is not a finding:
/// "LAN only" is a state the owner chose, not a fault, and the link works.
fn relay_findings(status: &StatusReply, contacts: &[ContactInfo], out: &mut Vec<Finding>) {
    if status.relay == "disabled" {
        let names: Vec<&str> = contacts
            .iter()
            .filter(|c| relay_only(c))
            .map(|c| c.label.as_str())
            .collect();
        if !names.is_empty() {
            let mut f = Finding::new(
                "relay_disabled",
                "info",
                format!(
                    "this node runs without a relay, so its {} link(s) at trust 1–2 cannot connect: {}",
                    names.len(),
                    names.join(", ")
                ),
                "Run antennad with a relay (the default, or --relay <url>) to reach them; links at trust 3–5 connect \
                 directly."
                    .into(),
            );
            f.facts = json!({ "contacts": names });
            out.push(f);
        }
        return;
    }
    let mut found: Vec<Finding> = Vec::new();
    for c in contacts {
        let Some(r) = c.transport.relay.as_ref().filter(|r| !r.connected) else {
            continue;
        };
        if c.transport.connected {
            // The link is up over some other path (LAN mDNS, a direct address) despite its relay being down: PG-32,
            // nothing to fix here.
            continue;
        }
        let only = relay_only(c);
        let mode = if only { "relay only" } else { "direct" };
        let which = if r.url.is_empty() {
            format!(
                "has not reached a relay yet (relay setting: {})",
                status.relay
            )
        } else {
            format!("cannot reach its relay {}", r.url)
        };
        let why = r
            .error
            .as_deref()
            .map(|e| format!(": {e}"))
            .unwrap_or_default();
        let effect = if only {
            "; this link connects only through the relay, so it cannot connect at all"
        } else {
            "; direct connections still work where the contact is reachable"
        };
        let mut fix = String::from(
            "Check the internet connection (and, for your own relay, that it runs); Antenna keeps retrying by itself, \
             so the link reconnects once the relay answers.",
        );
        if !only {
            fix.push_str(
                " On the same network, the local network mode helps meanwhile: antenna lan on.",
            );
        }
        let mut f = Finding::new(
            "relay_unreachable",
            if only { "error" } else { "warning" },
            format!(
                "{} (trust {}, {mode}) {which}{why}{effect}",
                c.label, c.trust
            ),
            fix,
        );
        f.contact = Some(c.label.clone());
        f.facts = json!({
            "trust": c.trust,
            "net_mode": c.net_mode,
            "relay_only": only,
            "relay_url": r.url,
            "error": r.error,
        });
        found.push(f);
    }
    // Links that cannot connect at all first.
    found.sort_by_key(|f| f.severity != "error");
    out.extend(found);
}

/// `token_bound_elsewhere`: an MCP host of another app was refused an agent's token (`agent_list`, `refused_*`, D-97),
/// and it still runs or was refused within [`REFUSED_RECENT_MS`].
fn token_findings(agents: &[AgentInfo], now: u64, out: &mut Vec<Finding>) {
    for a in agents {
        let s = &a.session;
        let Some(pid) = s.refused_pid else { continue };
        let alive = s.refused_alive == Some(true);
        let at = s.refused_ms.unwrap_or(0);
        if !alive && now.saturating_sub(at) > REFUSED_RECENT_MS {
            continue;
        }
        let refused = s.refused_comm.as_deref().unwrap_or("?");
        let bound_alive = s.bound_alive == Some(true);
        let bound = match (&s.bound_comm, s.bound_pid) {
            (Some(c), Some(p)) => format!(
                "{c} (pid {p}, {})",
                if bound_alive { "running" } else { "ended" }
            ),
            _ => "another process".into(),
        };
        let detail = format!(
            "agent {}: its token is bound to {bound}; {refused} (pid {pid}) was refused {} and {}",
            a.name,
            ago(at),
            if alive { "still runs" } else { "has ended" }
        );
        let fix = if bound_alive {
            format!(
                "To let {refused} use agent {name}, quit {holder} and restart {refused}; to keep both, give {refused} \
                 its own agent (antenna agent add <new-name> --local-level <0-5> --token-file) and point its MCP \
                 config at that token file.",
                name = a.name,
                holder = s
                    .bound_comm
                    .as_deref()
                    .unwrap_or("the process that holds the token"),
            )
        } else {
            format!("The token is free again: restart {refused} so it connects.")
        };
        let mut f = Finding::new("token_bound_elsewhere", "warning", detail, fix);
        f.agent = Some(a.name.clone());
        f.facts = json!({
            "bound_pid": s.bound_pid,
            "bound_comm": s.bound_comm,
            "bound_alive": s.bound_alive,
            "refused_pid": pid,
            "refused_comm": s.refused_comm,
            "refused_ms": s.refused_ms,
            "refused_alive": s.refused_alive,
        });
        out.push(f);
    }
}

/// The report: JSON, or one line per fact for a person (strings from the daemon are escaped: they include contact
/// labels and process names).
fn print(r: &Report, json: bool) {
    if json {
        print_json(r);
        return;
    }
    let mut t = String::new();
    match &r.daemon {
        Some(v) => t.push_str(&format!("daemon: {}, {}\n", clean(v), clean(&r.state))),
        None => t.push_str("daemon: not answering\n"),
    }
    if let Some(relay) = &r.relay {
        t.push_str(&format!("relay: {}\n", clean(relay)));
    }
    for f in &r.findings {
        t.push_str(&format!(
            "{} ({}): {}\n  what to do: {}\n",
            f.code,
            f.severity,
            clean(&f.detail),
            clean(&f.fix)
        ));
    }
    if let Some(s) = &r.skipped {
        t.push_str(&format!(
            "not checked ({}): {}\n",
            clean(&s.code),
            clean(&s.detail)
        ));
    }
    if r.findings.is_empty() {
        t.push_str(if r.skipped.is_none() {
            "No problems found.\n"
        } else {
            "No problems found in what was checked.\n"
        });
    }
    let _ = std::io::stdout().write_all(t.as_bytes());
}

/// Unix ms now.
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use antenna_proto::control::HomeRelayInfo;

    fn status(relay: &str) -> StatusReply {
        StatusReply {
            state: "unlocked".into(),
            daemon: "0.1.0".into(),
            protocol: "x/1".into(),
            relay: relay.into(),
            links: Some(2),
            updated: None,
        }
    }

    fn contact(label: &str, trust: u8, relay: Option<HomeRelayInfo>) -> ContactInfo {
        contact_connected(label, trust, relay, false)
    }

    /// [connected]: the link itself (`transport.connected`), independent of the relay (PG-32: a direct/LAN path can
    /// carry the link while its relay is down).
    fn contact_connected(
        label: &str,
        trust: u8,
        relay: Option<HomeRelayInfo>,
        connected: bool,
    ) -> ContactInfo {
        let mut c: ContactInfo = serde_json::from_value(json!({
            "label": label, "link_id": "00", "trust": trust,
            "net_mode": if trust <= 2 { "relay_only" } else { "direct" },
            "role": "inviter", "created_ms": 0, "peer_endpoint": "", "local_endpoint": "", "local_addrs": [],
            "e2e": {"session_version": null, "pq_ratchet": null, "last_rx_version": null, "last_rx_pq_len": null},
            "transport": {"pairing_kx_group": "", "last_kx_group": null, "connected": connected, "last_paths": []},
            "outbox": 0, "failed": 0, "heads": [], "lamport": 0
        }))
        .unwrap();
        c.transport.relay = relay;
        c
    }

    fn down(url: &str) -> Option<HomeRelayInfo> {
        Some(HomeRelayInfo {
            url: url.into(),
            connected: false,
            error: Some("connection refused".into()),
        })
    }

    #[test]
    fn relay_findings_name_the_links_that_cannot_connect() {
        let up = Some(HomeRelayInfo {
            url: "http://relay.example/".into(),
            connected: true,
            error: None,
        });
        let cs = [
            contact("carol", 4, down("http://relay.example/")),
            contact("bob", 2, down("http://relay.example/")),
            contact("dave", 2, up),
            contact("erin", 1, None),
        ];
        let mut out = Vec::new();
        relay_findings(&status("http://relay.example/"), &cs, &mut out);
        let got: Vec<(&str, &str)> = out
            .iter()
            .map(|f| (f.contact.as_deref().unwrap_or(""), f.severity))
            .collect();
        assert_eq!(got, [("bob", "error"), ("carol", "warning")], "{out:?}");
        assert!(
            out[0].detail.contains("relay only") && out[0].detail.contains("cannot connect at all")
        );
        assert_eq!(out[0].facts["error"], "connection refused");
        // bob (trust 2, relay only) has no other way to connect: the relay being down is a real problem for it too,
        // confirming the fix below does not just blanket-suppress every relay finding.
        assert!(!cs[1].transport.connected);
        // Without a relay: one note about the links that need one, and no per-link findings.
        let mut out = Vec::new();
        relay_findings(&status("disabled"), &cs, &mut out);
        assert_eq!(out.len(), 1, "{out:?}");
        assert_eq!(out[0].code, "relay_disabled");
        assert_eq!(out[0].facts["contacts"], json!(["bob", "dave", "erin"]));
        let mut out = Vec::new();
        relay_findings(&status("disabled"), &cs[..1], &mut out);
        assert!(out.is_empty(), "a trust 4 link needs no relay: {out:?}");
    }

    /// PG-32: a field team with no internet for weeks (`SPEC` scenario S13) turns on `antenna lan on`; its trust 3+
    /// contacts reach each other over the local network while the relay stays unreachable. The Check panel must not
    /// call that a fault: the link itself (`transport.connected`) says it works.
    #[test]
    fn a_link_connected_over_lan_without_a_relay_is_not_a_finding() {
        let cs = [
            // Connected despite its relay being down: on the boat, found over mDNS. No finding at all.
            contact_connected("frank", 4, down("http://relay.example/"), true),
            // Same relay trouble, but not actually connected (out of LAN range, or LAN is off): still a finding, and
            // still only a warning (trust 3+ connects directly, so this is not as bad as a relay-only link).
            contact_connected("grace", 4, down("http://relay.example/"), false),
        ];
        let mut out = Vec::new();
        relay_findings(&status("http://relay.example/"), &cs, &mut out);
        let got: Vec<&str> = out
            .iter()
            .map(|f| f.contact.as_deref().unwrap_or(""))
            .collect();
        assert_eq!(
            got,
            ["grace"],
            "frank is connected over LAN and must not be reported: {out:?}"
        );
        assert_eq!(out[0].severity, "warning");
        // Negative control: without the `transport.connected` check, frank would be reported too (seen failing by
        // reverting the `if c.transport.connected { continue; }` guard added for PG-32).
    }

    #[test]
    fn a_refused_host_is_reported_while_it_runs_or_for_ten_minutes() {
        let now = 1_000_000_000;
        let agent = |alive: bool, ago_ms: u64| -> AgentInfo {
            serde_json::from_value(json!({
                "name": "claude", "created_ms": 0,
                "session": {"agent": "claude", "started_ms": 0, "ceiling": null, "tainted_by": [],
                    "local_level": 0, "baseline_level": 0, "declared": [], "links": null, "bound_to": "10 claude",
                    "bound_pid": 10, "bound_comm": "claude", "bound_alive": true,
                    "refused_pid": 20, "refused_comm": "Code Helper", "refused_ms": now - ago_ms,
                    "refused_alive": alive}
            }))
            .unwrap()
        };
        let check = |a: AgentInfo| {
            let mut out = Vec::new();
            token_findings(&[a], now, &mut out);
            out
        };
        let out = check(agent(true, REFUSED_RECENT_MS * 3));
        assert_eq!(out.len(), 1, "still running");
        assert_eq!(out[0].agent.as_deref(), Some("claude"));
        assert!(
            out[0].detail.contains("Code Helper (pid 20)"),
            "{}",
            out[0].detail
        );
        assert!(out[0].fix.contains("quit claude"), "{}", out[0].fix);
        assert_eq!(check(agent(false, 60_000)).len(), 1, "refused a minute ago");
        assert!(
            check(agent(false, REFUSED_RECENT_MS + 1)).is_empty(),
            "long gone"
        );
        let mut quiet = agent(true, 0);
        quiet.session.refused_pid = None;
        assert!(check(quiet).is_empty(), "nothing refused");
    }
}
