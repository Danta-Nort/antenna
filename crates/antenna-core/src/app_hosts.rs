// SPDX-License-Identifier: AGPL-3.0-only
//! One agent token, several MCP processes of the same running app (D-97).
//!
//! An agent token is bound to the process that started `antenna mcp`, the MCP host (D-28): the token is accepted only
//! from that process's tree, so another program that got hold of the token cannot use it. Claude Desktop starts several
//! `antenna mcp` processes from one config: one for its chats and a pool for its Cowork and Code sessions, each under a
//! different process of the app. With the binding to the first host, every other one was refused (`token_bound`).
//!
//! The rule here: a second MCP host is accepted for the same agent when it belongs to **the same running app** as the
//! bound one. Their nearest common ancestor must be an app, not something that many programs share:
//! - it is a valid anchor (not PID 1, launchd or systemd, not a session leader except a GUI app's main process on macOS,
//!   not an ancestor of the daemon: [`procinfo::valid_anchor`]);
//! - no process between it and either host leads a session (`login`, a terminal's shell, `tmux`, `setsid`: two programs
//!   started from two terminals are two programs, even under one Terminal.app);
//! - it is a GUI app's main process (macOS, D-P-3: the `.app` main executable started by launchd, no terminal, the same
//!   uid), or it runs the same executable as both hosts (an Electron app's helpers on Linux run its main binary).
//!
//! The extra hosts live in memory only: they are live processes of one app, and every `antenna mcp` request binds
//! again, so after a daemon restart they come back with the next call (the database keeps the first host, D-P-9). All
//! hosts of an agent share one agent session and one taint (D-29: a new process is not a new context, and an app's
//! chats can share memory and projects the daemon does not see), so a second process never launders the taint of the
//! first.
//!
//! A host refused because the token is bound to another app is remembered too (memory only, the newest per agent): the
//! owner's `agent_list` shows it (`refused_*`) and the doctor reports `token_bound_elsewhere` (D-96), since the refused
//! app itself only says "couldn't start".

use std::{collections::HashMap, path::PathBuf};

use crate::procinfo::{self, Anchor, ProcStat};

/// MCP hosts and `antenna mcp` processes of agents, beyond the host in the database.
#[derive(Debug, Default)]
pub(crate) struct AppHosts {
    /// Agent ID → further MCP hosts of the same app (anchor, command name).
    extra: HashMap<i64, Vec<(Anchor, String)>>,
    /// Agent ID → `antenna mcp` processes that logged in with `bind_parent` (live ones are counted).
    clients: HashMap<i64, Vec<Anchor>>,
    /// Agent ID → the last MCP host refused because the token is bound to another app (the newest wins).
    refused: HashMap<i64, Refused>,
}

/// An MCP host that was refused an agent's token because the token is bound to another app: what the owner's
/// `agent_list` shows (`refused_*`) and the doctor reports as `token_bound_elsewhere` (D-96).
#[derive(Debug, Clone)]
pub(crate) struct Refused {
    /// The refused host (PID and start time: whether it still runs is checked like the binding).
    pub(crate) host: Anchor,
    /// Its command name.
    pub(crate) comm: String,
    /// When, Unix ms.
    pub(crate) at_ms: u64,
    /// When the owner's subscriptions last heard of a refusal of this host.
    told_ms: u64,
}

/// A host that keeps retrying is announced to the owner at most this often.
const REFUSED_EVENT_EVERY_MS: u64 = 60_000;

impl AppHosts {
    /// The live extra hosts of an agent (dead ones are dropped).
    pub(crate) fn hosts(&mut self, id: i64) -> Vec<(Anchor, String)> {
        let Some(v) = self.extra.get_mut(&id) else {
            return Vec::new();
        };
        v.retain(|(a, _)| procinfo::is_alive(a));
        v.clone()
    }

    /// Another MCP host of the same app.
    pub(crate) fn add_host(&mut self, id: i64, a: Anchor, comm: &str) {
        let v = self.extra.entry(id).or_default();
        if !v.iter().any(|(x, _)| *x == a) {
            v.push((a, comm.to_string()));
        }
    }

    /// An `antenna mcp` process of this agent.
    pub(crate) fn note_client(&mut self, id: i64, a: Anchor) {
        let v = self.clients.entry(id).or_default();
        v.retain(procinfo::is_alive);
        if !v.contains(&a) {
            v.push(a);
        }
    }

    /// How many `antenna mcp` processes of this agent are running.
    pub(crate) fn live_clients(&mut self, id: i64) -> usize {
        let Some(v) = self.clients.get_mut(&id) else {
            return 0;
        };
        v.retain(procinfo::is_alive);
        v.len()
    }

    /// A host was refused this agent's token. Returns whether to tell the owner's subscriptions now: a new host, or the
    /// same one again after [`REFUSED_EVENT_EVERY_MS`] (an app that retries in a loop does not flood the window).
    pub(crate) fn note_refused(&mut self, id: i64, host: Anchor, comm: &str, at_ms: u64) -> bool {
        let prev = self.refused.get(&id);
        let tell = prev.is_none_or(|r| {
            r.host != host || at_ms.saturating_sub(r.told_ms) >= REFUSED_EVENT_EVERY_MS
        });
        let told_ms = match prev {
            Some(r) if !tell => r.told_ms,
            _ => at_ms,
        };
        self.refused.insert(
            id,
            Refused {
                host,
                comm: comm.to_string(),
                at_ms,
                told_ms,
            },
        );
        tell
    }

    /// The host became one of this agent's own hosts (the bound app exited and it connected): no longer refused.
    pub(crate) fn accepted(&mut self, id: i64, host: &Anchor) {
        if self.refused.get(&id).is_some_and(|r| r.host == *host) {
            self.refused.remove(&id);
        }
    }

    /// The last host refused this agent's token, if any.
    pub(crate) fn refused(&self, id: i64) -> Option<Refused> {
        self.refused.get(&id).cloned()
    }

    /// The agent was removed (its ID may be reused).
    pub(crate) fn forget(&mut self, id: i64) {
        self.extra.remove(&id);
        self.clients.remove(&id);
        self.refused.remove(&id);
    }
}

/// The executable of a process, if it can be read (Linux `/proc/<pid>/exe`, macOS `proc_pidpath`).
fn exe(pid: i32) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        antenna_sys::darwin::exe_path(pid).ok()
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::fs::read_link(format!("/proc/{pid}/exe")).ok()
    }
}

/// A GUI app's main process (macOS, D-P-3); never on other systems.
fn gui_app(s: &ProcStat) -> bool {
    #[cfg(target_os = "macos")]
    {
        procinfo::darwin::gui_host(s)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = s;
        false
    }
}

/// `pid comm ← pid comm ← …` for the log (command names only, no arguments).
pub(crate) fn describe(chain: &[ProcStat]) -> String {
    chain
        .iter()
        .take(8)
        .map(|s| format!("{} {}", s.pid, s.comm))
        .collect::<Vec<_>>()
        .join(" ← ")
}

/// Whether the client (`antenna mcp`, `client[0]`; its parent `client[1]` is the new MCP host) belongs to the same
/// running app as the bound host `bound`. Returns the app's process (the nearest common ancestor), or why not, in words
/// the owner can read. Anything that cannot be read is a "no".
pub(crate) fn same_app(client: &[ProcStat], bound: &Anchor) -> Result<ProcStat, String> {
    let host = procinfo::ancestry(bound.pid)
        .filter(|c| c.first().is_some_and(|s| s.start == bound.start))
        .ok_or("the bound process cannot be read")?;
    let parent = client.get(1).ok_or("the client has no parent process")?;
    let (ci, hi) = client
        .iter()
        .enumerate()
        .skip(1)
        .find_map(|(i, s)| {
            host.iter()
                .position(|h| h.pid == s.pid && h.start == s.start)
                .map(|j| (i, j))
        })
        .ok_or("the two processes have no common ancestor")?;
    let root = &client[ci];
    if !procinfo::valid_anchor(root) {
        return Err(format!(
            "their common ancestor {:?} (pid {}) is not an app: a terminal, a session leader, init or the daemon's own \
             ancestor",
            root.comm, root.pid
        ));
    }
    // A session leader in between (or a session that cannot be read) separates two programs started from different
    // terminals or sessions under one ancestor.
    if let Some(s) = client[1..ci]
        .iter()
        .chain(&host[..hi])
        .find(|s| s.sid <= 0 || s.sid == s.pid)
    {
        return Err(format!(
            "{:?} (pid {}) between them leads its own session: they are two programs, not one app",
            s.comm, s.pid
        ));
    }
    if !gui_app(root) {
        let e = exe(root.pid).ok_or("the common ancestor's executable cannot be read")?;
        let same = |pid: i32| exe(pid).is_some_and(|x| x == e);
        if !same(parent.pid) || !same(bound.pid) {
            return Err(format!(
                "their common ancestor {:?} (pid {}) runs another program than they do: not one app",
                root.comm, root.pid
            ));
        }
    }
    Ok(root.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(pid: i32) -> Anchor {
        Anchor { pid, start: 7 }
    }

    #[test]
    fn a_refusal_is_kept_per_agent_and_announced_without_flooding() {
        let mut h = AppHosts::default();
        assert!(h.refused(1).is_none());
        assert!(
            h.note_refused(1, host(10), "Code Helper", 1_000),
            "a new host"
        );
        assert!(
            !h.note_refused(1, host(10), "Code Helper", 2_000),
            "the same host retrying"
        );
        let r = h.refused(1).unwrap();
        assert_eq!((r.host, r.at_ms), (host(10), 2_000), "the newest refusal");
        assert!(h.note_refused(1, host(10), "Code Helper", 1_000 + REFUSED_EVENT_EVERY_MS));
        assert!(h.note_refused(1, host(11), "perl", 70_000), "another host");
        assert_eq!(h.refused(1).unwrap().comm, "perl");
        assert!(h.refused(2).is_none(), "per agent");
        h.accepted(1, &host(10));
        assert!(h.refused(1).is_some(), "another host was accepted");
        h.accepted(1, &host(11));
        assert!(
            h.refused(1).is_none(),
            "the refused host itself connected later"
        );
        h.note_refused(1, host(12), "sh", 80_000);
        h.forget(1);
        assert!(h.refused(1).is_none());
    }
}
