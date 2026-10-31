// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's stop switch (PG-58, D-133; experimental): stop an agent and the processes it started, on this computer
//! or at the request of an own computer (`docs/PROTOCOL.md` §24, `agent-stop/0`).
//!
//! What is stopped depends on how the agent runs, and only what can be attributed to it reliably is ever signalled:
//! - **its terminal session** (`terminal`): the window's Code mode tab and `antenna session` start the agent CLI in a
//!   terminal session of its own (a pseudo-terminal whose wrapper, or tmux pane process, is the session leader) and
//!   tell the daemon so (`agent_terminal`, checked against the client's own process tree). Everything in that session
//!   (by session ID) and everything under its leader or under the agent's bound process (by parent) is stopped, the
//!   leader last, so orphans that hang off it (on Linux the pane process is a child subreaper) are still found;
//! - **an agent CLI the owner started in a terminal of their own** (`process`): the bound process and everything under
//!   it, never the rest of that terminal's session, which is the owner's shell and its other jobs;
//! - **an AI app the owner runs** (`app`: a GUI app, or a process without a terminal, or several hosts of one app,
//!   D-97): the agent's processes cannot be told apart from the app's own, so nothing is signalled; the agent is cut off
//!   instead (its token replaced, its binding removed) until the owner connects the app again;
//! - **the daemon's own sandboxes** (`resident`, `wake`, `worker`): their supervisor kills the whole tree (D-71), as a
//!   stop of the session or the worker does today; `local`: a local model's turn ends (it runs no tools).
//!
//! Processes are matched by PID together with their start time (Linux: field 22 of `/proc/<pid>/stat`, signalled
//! through a pidfd; macOS: `p_uniqueid`), never by name. SIGTERM first, SIGKILL after [`GRACE`] for what is left, while
//! new members keep appearing for at most [`SWEEP`]. Never the daemon or its ancestors, never the client that asked
//! or its ancestors, never PID 1. What cannot be covered: a process that left both the session and the tree (it called
//! `setsid` and its parent exited; on Linux under `antenna session` the subreaper still holds it), and on macOS anything
//! started through LaunchServices (`open`, Finder, `osascript`): launchd is its parent, so it is the owner's to quit.

use std::{
    collections::{BTreeSet, HashMap, VecDeque},
    sync::{Arc, Mutex as StdMutex, PoisonError},
    time::{Duration, Instant},
};

use antenna_proto::control::{AgentStopped, code};

use crate::{
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
    procinfo::{self, Anchor, ProcStat},
};

/// How long the processes get to end after SIGTERM.
const GRACE: Duration = Duration::from_secs(3);
/// After that, SIGKILL while members keep appearing, for at most this long.
const SWEEP: Duration = Duration::from_secs(2);
/// The session leader's own wait for SIGTERM, and then for SIGKILL.
#[cfg(unix)]
const LEADER_WAIT: Duration = Duration::from_secs(1);
/// Windows: what [`Swept::left`] says when the processes could not be looked at (D-134, WP-7, WP-14): never 0, so no
/// caller reads a stop as done.
#[cfg(windows)]
const LEFT_UNKNOWN: u32 = u32::MAX;
/// The most process names a reply carries.
const MAX_NAMES: usize = antenna_proto::device::MAX_STOPPED_NAMES;

/// At most this many stops an own computer asks for in [`REMOTE_WINDOW`].
const REMOTE_MAX: usize = 6;
/// The window of [`REMOTE_MAX`].
const REMOTE_WINDOW: Duration = Duration::from_secs(60);

/// The stop switch's state (in memory): the terminal sessions clients started agents in (`agent_terminal`: agent ID →
/// the session leader; after a daemon restart the window and `antenna session` say it again when they reconnect), and
/// the stops each own computer asked for lately.
#[derive(Debug, Default)]
pub(crate) struct StopState {
    terminals: StdMutex<HashMap<i64, Anchor>>,
    remote: StdMutex<HashMap<antenna_proto::LinkId, VecDeque<Instant>>>,
}

impl StopState {
    fn note(&self, agent: i64, leader: Anchor) {
        let mut g = self
            .terminals
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        g.retain(|_, a| procinfo::is_alive(a));
        g.insert(agent, leader);
    }

    fn get(&self, agent: i64) -> Option<Anchor> {
        self.terminals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&agent)
            .copied()
            .filter(procinfo::is_alive)
    }

    /// Whether an own computer may ask for another stop now.
    fn admit_remote(&self, link: &antenna_proto::LinkId, now: Instant) -> bool {
        let mut g = self.remote.lock().unwrap_or_else(PoisonError::into_inner);
        let q = g.entry(*link).or_default();
        while q
            .front()
            .is_some_and(|t| now.saturating_duration_since(*t) >= REMOTE_WINDOW)
        {
            q.pop_front();
        }
        if q.len() >= REMOTE_MAX {
            return false;
        }
        q.push_back(now);
        true
    }
}

/// What a stop takes, fixed when it starts: the session stays the target by its ID after its leader has gone.
#[derive(Debug, Clone, Default)]
pub(crate) struct Target {
    /// The agent's own processes (its bound hosts, a sandbox's direct child): each and everything under it.
    pub roots: Vec<Anchor>,
    /// The terminal session that is the agent's own: its leader. Every member and everything under the leader.
    pub session: Option<Anchor>,
}

/// The processes of `table` that `t` takes, never a PID in `keep` nor PID 1 (pure; unit-tested). With `leader`
/// false the session leader itself is left for last.
pub(crate) fn scope(table: &[ProcStat], t: &Target, keep: &[i32], leader: bool) -> Vec<ProcStat> {
    let mut taken: Vec<ProcStat> = Vec::new();
    // A kept process is never taken, so nothing under it is reached through it either
    let add = |p: &ProcStat, taken: &mut Vec<ProcStat>| {
        if p.pid > 1 && !keep.contains(&p.pid) && !taken.iter().any(|q| q.pid == p.pid) {
            taken.push(p.clone());
        }
    };
    let same = |p: &ProcStat, a: &Anchor| p.pid == a.pid && p.start == a.start;
    for r in &t.roots {
        if let Some(p) = table.iter().find(|p| same(p, r)) {
            add(p, &mut taken);
        }
    }
    if let Some(s) = &t.session {
        for p in table.iter().filter(|p| p.sid == s.pid || same(p, s)) {
            add(p, &mut taken);
        }
    }
    // Everything under what was taken, by parent, until nothing new turns up
    loop {
        let before = taken.len();
        for p in table {
            if taken.iter().any(|q| q.pid == p.ppid) {
                add(p, &mut taken);
            }
        }
        if taken.len() == before {
            break;
        }
    }
    taken.retain(|p| leader || !t.session.as_ref().is_some_and(|s| same(p, s)));
    taken
}

/// What a sweep sends.
#[cfg(unix)]
#[derive(Debug, Clone, Copy)]
enum Sig {
    Term,
    Kill,
}

/// A signal to exactly this process (the same start time): through a pidfd on Linux (no race with PID reuse), after a
/// fresh check on macOS. `true` when it was sent.
#[cfg(unix)]
fn signal(p: &ProcStat, sig: Sig) -> bool {
    let sig = match sig {
        Sig::Term => rustix::process::Signal::TERM,
        Sig::Kill => rustix::process::Signal::KILL,
    };
    let Some(pid) = rustix::process::Pid::from_raw(p.pid) else {
        return false;
    };
    #[cfg(target_os = "linux")]
    {
        use rustix::process::{PidfdFlags, pidfd_open, pidfd_send_signal};
        match pidfd_open(pid, PidfdFlags::empty()) {
            Ok(fd) => {
                return procinfo::stat(p.pid).is_some_and(|n| n.start == p.start)
                    && pidfd_send_signal(&fd, sig).is_ok();
            }
            Err(rustix::io::Errno::NOSYS) => {}
            Err(_) => return false,
        }
    }
    procinfo::stat(p.pid).is_some_and(|n| n.start == p.start)
        && rustix::process::kill_process(pid, sig).is_ok()
}

/// What a sweep did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Swept {
    /// How many processes got a signal.
    pub processes: u32,
    /// How many were still alive afterwards.
    pub left: u32,
    /// Their distinct names, at most [`MAX_NAMES`].
    pub names: Vec<String>,
}

/// The processes `t` takes, now (for counting before a sandbox stops itself).
pub(crate) fn census(t: &Target, keep: &[i32]) -> Vec<ProcStat> {
    scope(&procinfo::all_mine(), t, keep, true)
}

/// Stop what `t` takes (blocking: call it off the async threads): SIGTERM, [`GRACE`], then SIGKILL for whatever is
/// left or appears, for at most [`SWEEP`]; the session leader last.
#[cfg(unix)]
pub(crate) fn sweep(t: &Target, keep: &[i32]) -> Swept {
    let mut seen: Vec<ProcStat> = Vec::new();
    let mut names: BTreeSet<String> = BTreeSet::new();
    let mut note = |ps: &[ProcStat], seen: &mut Vec<ProcStat>| {
        for p in ps {
            if !seen.iter().any(|q| q.pid == p.pid && q.start == p.start) {
                seen.push(p.clone());
                names.insert(p.comm.clone());
            }
        }
    };
    // The leader last: once its children are gone it usually ends by itself (the wrapper and the pane process exit
    // with the CLI), so its own wait is short; the whole stop stays within the 10 s an own computer waits for it
    for (leader, grace, sweep_for) in [(false, GRACE, SWEEP), (true, LEADER_WAIT, LEADER_WAIT)] {
        let first = scope(&procinfo::all_mine(), t, keep, leader);
        if first.is_empty() {
            continue;
        }
        note(&first, &mut seen);
        for p in &first {
            signal(p, Sig::Term);
        }
        let until = Instant::now() + grace;
        while Instant::now() < until {
            std::thread::sleep(Duration::from_millis(100));
            if scope(&procinfo::all_mine(), t, keep, leader).is_empty() {
                break;
            }
        }
        let until = Instant::now() + sweep_for;
        loop {
            let now = scope(&procinfo::all_mine(), t, keep, leader);
            if now.is_empty() || Instant::now() >= until {
                break;
            }
            note(&now, &mut seen);
            for p in &now {
                signal(p, Sig::Kill);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    std::thread::sleep(Duration::from_millis(100));
    let left = scope(&procinfo::all_mine(), t, keep, true).len();
    Swept {
        processes: u32::try_from(seen.len()).unwrap_or(u32::MAX),
        left: u32::try_from(left).unwrap_or(u32::MAX),
        names: names.into_iter().take(MAX_NAMES).collect(),
    }
}

/// Windows: processes are not read or signalled yet (a toolhelp snapshot by user SID, handles and job objects: D-134,
/// WP-7, WP-14, phases W1–W2). Nothing is sent, and what is left is unknown: [`LEFT_UNKNOWN`], never "all stopped".
#[cfg(windows)]
pub(crate) fn sweep(_t: &Target, _keep: &[i32]) -> Swept {
    Swept {
        processes: 0,
        left: LEFT_UNKNOWN,
        names: Vec::new(),
    }
}

/// The PIDs a stop never touches: the daemon and its ancestors, and the client that asked with its ancestors.
fn keep_of(client: Option<&[ProcStat]>) -> Vec<i32> {
    let mut keep: Vec<i32> = procinfo::daemon_ancestors().iter().map(|a| a.pid).collect();
    keep.push(std::process::id() as i32);
    keep.extend(client.unwrap_or_default().iter().map(|p| p.pid));
    keep
}

/// Run a sweep off the async threads.
async fn sweep_async(t: Target, keep: Vec<i32>) -> Swept {
    tokio::task::spawn_blocking(move || sweep(&t, &keep))
        .await
        .unwrap_or_default()
}

/// Wait up to [`GRACE`] + [`SWEEP`] for a sandbox to take its tree down, then sweep what is left ourselves.
async fn after_sandbox(t: Target, keep: Vec<i32>, before: Vec<ProcStat>) -> Swept {
    let until = Instant::now() + GRACE + SWEEP;
    loop {
        let (t2, k2) = (t.clone(), keep.clone());
        let left = tokio::task::spawn_blocking(move || census(&t2, &k2).len())
            .await
            .unwrap_or(0);
        if left == 0 || Instant::now() >= until {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let mut s = sweep_async(t, keep).await;
    let mut names: BTreeSet<String> = s.names.into_iter().collect();
    names.extend(before.iter().map(|p| p.comm.clone()));
    s.names = names.into_iter().take(MAX_NAMES).collect();
    s.processes = s
        .processes
        .max(u32::try_from(before.len()).unwrap_or(u32::MAX));
    s
}

impl Session {
    /// `agent_terminal` (CONTROL §33): the agent runs in the terminal session `pid` leads, a process the client is or
    /// started (its own child). Checked here; kept in memory. Fails closed: an unreadable chain is a refusal.
    pub fn agent_terminal(&self, name: &str, pid: i32, client: Option<&[ProcStat]>) -> Result<()> {
        let row = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agent_by_name(name)?;
        let Some(me) = client.and_then(|c| c.first()) else {
            return Err(Error::new(
                code::FORBIDDEN,
                "cannot read the client process: only the app that started the agent's terminal may say so",
            ));
        };
        if self.agent_for_process(client)?.is_some() {
            return Err(Error::new(
                code::FORBIDDEN,
                "a process in an agent's tree cannot name an agent's terminal",
            ));
        }
        let Some(s) = procinfo::stat(pid) else {
            return Err(Error::new(code::NOT_FOUND, "no such process"));
        };
        if s.pid <= 1 || s.sid != s.pid {
            return Err(Error::bad_request(
                "that process does not lead a terminal session",
            ));
        }
        if s.pid != me.pid && s.ppid != me.pid {
            return Err(Error::new(
                code::FORBIDDEN,
                "only the terminal session this client started (its own child) or leads",
            ));
        }
        self.stops.note(
            row.id,
            Anchor {
                pid: s.pid,
                start: s.start,
            },
        );
        Ok(())
    }

    /// `agent_stop` (CONTROL §33): stop the agent and the processes it started. `by` is `owner` or the label of the own
    /// computer that asked; `client` the requester's process chain (never touched).
    pub async fn agent_stop(
        self: &Arc<Self>,
        name: &str,
        by: &str,
        client: Option<&[ProcStat]>,
    ) -> Result<AgentStopped> {
        // Windows: the agent's processes are found and stopped through handles and job objects (D-134, WP-7, WP-14);
        // until then a stop that cannot look is refused, never reported as done.
        if cfg!(windows) {
            return Err(Error::new(
                code::NOT_IMPLEMENTED,
                "stopping agents is not available on Windows yet",
            ));
        }
        let row = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .agent_by_name(name)?;
        let keep = keep_of(client);
        let anchor = row
            .anchor
            .as_ref()
            .map(|(pid, start, _)| Anchor {
                pid: *pid,
                start: *start,
            })
            .filter(procinfo::is_alive);
        let sandboxed = Target {
            roots: anchor.into_iter().collect(),
            session: None,
        };
        let (how, swept) = if let Some((link, resident)) = self.wake_rule_of_agent(row.id) {
            let before = census(&sandboxed, &keep);
            if resident {
                self.resident_stop(&link);
            } else {
                self.wake_stop_run(&link);
            }
            let how = if resident { "resident" } else { "wake" };
            (how, after_sandbox(sandboxed, keep, before).await)
        } else if self.team_member(row.id).is_some() {
            let before = census(&sandboxed, &keep);
            self.team_stop_worker_of(row.id).await?;
            ("worker", after_sandbox(sandboxed, keep, before).await)
        } else if self.local_agent(name).is_ok() {
            self.local_session(name, "stop").await?;
            ("local", Swept::default())
        } else {
            let hosts: Vec<Anchor> = self.live_hosts(&row).into_iter().map(|(a, _)| a).collect();
            let terminal = self.stops.get(row.id).filter(|leader| {
                hosts.iter().all(|h| {
                    procinfo::stat(h.pid).is_some_and(|s| s.sid == leader.pid)
                        || procinfo::is_descendant_or_self(h.pid, leader)
                })
            });
            if let Some(leader) = terminal {
                let t = Target {
                    roots: hosts,
                    session: Some(leader),
                };
                ("terminal", sweep_async(t, keep).await)
            } else if hosts.is_empty() {
                ("none", Swept::default())
            } else if hosts.len() > 1 || hosts.iter().any(is_app_host) {
                self.agent_cut_off(row.id)?;
                ("app", Swept::default())
            } else {
                let t = Target {
                    roots: hosts,
                    session: None,
                };
                ("process", sweep_async(t, keep).await)
            }
        };
        let _ = self.events.send(NodeEvent::Agent {
            name: row.name.clone(),
            change: "stopped".into(),
            by: Some(by.to_string()),
        });
        tracing::info!(
            "agent {}: stopped by {by} ({how}, {} processes, {} left)",
            row.name,
            swept.processes,
            swept.left
        );
        Ok(AgentStopped {
            agent: row.name,
            contact: None,
            how: how.into(),
            processes: swept.processes,
            left: swept.left,
            names: swept.names,
        })
    }

    /// `device_agent_stop` (CONTROL §33): ask an own computer to stop one of its agents (`docs/PROTOCOL.md` §24,
    /// `agent-stop/0`). Both sides check level 5; the other computer decides and does it.
    pub async fn device_agent_stop(&self, contact: &str, agent: &str) -> Result<AgentStopped> {
        let row = self.find_link(contact)?;
        if row.trust != 5 {
            return Err(Error::new(
                code::FORBIDDEN,
                "only an own computer (level 5, ∞) can be asked to stop its agents",
            ));
        }
        if !antenna_proto::AgentAnnounce::valid_name(agent) {
            return Err(Error::bad_request("not an agent name"));
        }
        let rt = self.rt(&row.link_id)?;
        if rt
            .shared
            .peer_feat
            .load(std::sync::atomic::Ordering::SeqCst)
            == 0
        {
            let _ = tokio::time::timeout(Duration::from_secs(3), rt.shared.connect_raw()).await;
        }
        if !rt.shared.peer_supports_agent_stop() {
            return Err(Error::new(
                code::UNKNOWN_COMMAND,
                "that computer's Antenna cannot stop its agents on request yet: update it",
            ));
        }
        let msg = antenna_proto::device::DeviceMsg::StopAgent {
            agent: agent.to_string(),
        };
        match rt.shared.device_send(&msg).await? {
            Some(r @ antenna_proto::device::DeviceReply::Stopped { .. }) => {
                r.check()
                    .map_err(|_| Error::network("device stop: a malformed answer"))?;
                let antenna_proto::device::DeviceReply::Stopped {
                    agent,
                    how,
                    processes,
                    left,
                    names,
                } = r
                else {
                    return Err(Error::internal("device stop: not a stop answer"));
                };
                self.receipt(
                    &row.link_id,
                    "owner",
                    "agent_stop",
                    "requested",
                    &format!("{agent}: {how}, {processes} processes, {left} left"),
                    None,
                    None,
                );
                Ok(AgentStopped {
                    agent,
                    contact: Some(row.label),
                    how,
                    processes,
                    left,
                    names,
                })
            }
            other => Err(Error::network(format!("device stop: {other:?}"))),
        }
    }

    /// An own computer asks this one to stop agent `agent` (`docs/PROTOCOL.md` §24): level 5 here (checked again: it may
    /// have changed since the link served the request), at most [`REMOTE_MAX`] a minute, then exactly the owner's
    /// `agent_stop`, logged on that link.
    pub(crate) async fn stop_agent_in(
        self: &Arc<Self>,
        link: antenna_proto::LinkId,
        agent: &str,
    ) -> Result<antenna_proto::device::DeviceReply> {
        if self.link_trust(&link) != 5 {
            return Err(Error::new(code::FORBIDDEN, "not an own computer"));
        }
        if !antenna_proto::AgentAnnounce::valid_name(agent) {
            return Err(Error::bad_request("not an agent name"));
        }
        if !self.stops.admit_remote(&link, Instant::now()) {
            return Err(Error::new(
                code::RATE_LIMITED,
                "too many stops: wait a minute",
            ));
        }
        let label = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&link)?
            .label;
        let r = self.agent_stop(agent, &label, None).await?;
        self.receipt(
            &link,
            agent,
            "agent_stop",
            "allowed",
            &format!(
                "stopped at the request of {label}: {}, {} processes, {} left",
                r.how, r.processes, r.left
            ),
            None,
            None,
        );
        Ok(antenna_proto::device::DeviceReply::Stopped {
            agent: r.agent,
            how: r.how,
            processes: r.processes,
            left: r.left,
            names: r
                .names
                .into_iter()
                .map(|n| n.chars().filter(|c| !c.is_control()).take(64).collect())
                .collect(),
        })
    }

    /// An AI app's agent is cut off (`app`): a new token nobody holds, no binding, so its next call is refused until
    /// the owner connects the app again (a new token through Agents → AI apps).
    fn agent_cut_off(&self, id: i64) -> Result<()> {
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db.agent_set_token(id, &crate::agents::token_hash(&crate::agents::new_token()))?;
            db.agent_set_anchor(id, None)?;
        }
        self.app_hosts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .forget(id);
        Ok(())
    }

    /// The link whose wake rule this agent serves, and whether the rule is resident.
    fn wake_rule_of_agent(&self, id: i64) -> Option<(antenna_proto::LinkId, bool)> {
        let rules = self
            .db
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .wake_rules()
            .ok()?;
        rules
            .into_iter()
            .find(|r| r.1 == id)
            .map(|(link, _, json, _)| {
                let resident = serde_json::from_str::<serde_json::Value>(&json)
                    .ok()
                    .is_some_and(|v| v.get("resident").is_some_and(|r| !r.is_null()));
                (link, resident)
            })
    }
}

/// An AI app's MCP host rather than an agent CLI in a terminal: no controlling terminal, or (macOS) an app's main
/// process started by launchd.
fn is_app_host(a: &Anchor) -> bool {
    let Some(s) = procinfo::stat(a.pid) else {
        return false;
    };
    #[cfg(target_os = "macos")]
    if procinfo::darwin::gui_host(&s) {
        return true;
    }
    s.tty == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: i32, ppid: i32, sid: i32) -> ProcStat {
        ProcStat {
            pid,
            comm: format!("p{pid}"),
            ppid,
            sid,
            tty: 1,
            start: pid as u64 * 10,
        }
    }

    fn a(pid: i32) -> Anchor {
        Anchor {
            pid,
            start: pid as u64 * 10,
        }
    }

    fn pids(v: &[ProcStat]) -> Vec<i32> {
        let mut x: Vec<i32> = v.iter().map(|p| p.pid).collect();
        x.sort_unstable();
        x
    }

    /// A window (10) started a terminal session (20, the leader) with the agent CLI (21) that runs a tool (22) and a
    /// server that left its parent (30, same session, parent 1) and one that left the session too (40, its own
    /// session, under the leader as a subreaper would hold it); the owner's shell elsewhere (50, 51) and an unrelated
    /// process (60) under PID 1.
    fn table() -> Vec<ProcStat> {
        vec![
            p(1, 0, 1),
            p(10, 1, 10),
            p(20, 10, 20),
            p(21, 20, 20),
            p(22, 21, 20),
            p(30, 1, 20),
            p(40, 20, 40),
            p(41, 40, 40),
            p(50, 1, 50),
            p(51, 50, 50),
            p(60, 1, 60),
        ]
    }

    #[test]
    fn a_terminal_session_is_taken_whole_and_nothing_else() {
        let t = Target {
            roots: vec![a(21)],
            session: Some(a(20)),
        };
        assert_eq!(
            pids(&scope(&table(), &t, &[10], true)),
            [20, 21, 22, 30, 40, 41]
        );
        // The leader last
        assert_eq!(
            pids(&scope(&table(), &t, &[10], false)),
            [21, 22, 30, 40, 41]
        );
        // Never what is kept (the daemon, the client), nor what hangs under it, never PID 1
        assert_eq!(
            pids(&scope(&table(), &t, &[10, 22], true)),
            [20, 21, 30, 40, 41]
        );
        assert_eq!(
            pids(&scope(&table(), &t, &[10, 40], true)),
            [20, 21, 22, 30]
        );
    }

    #[test]
    fn an_agent_in_the_owners_own_terminal_takes_only_its_tree() {
        // The owner's shell 50 leads the session; the agent CLI 51 is the bound process: its session is not taken
        let mut tb = table();
        tb.push(p(52, 51, 50));
        tb.push(p(53, 50, 50));
        let t = Target {
            roots: vec![a(51)],
            session: None,
        };
        assert_eq!(pids(&scope(&tb, &t, &[], true)), [51, 52]);
    }

    #[test]
    fn a_reused_pid_is_not_the_same_process() {
        let t = Target {
            roots: vec![Anchor {
                pid: 21,
                start: 999,
            }],
            session: Some(Anchor {
                pid: 70,
                start: 700,
            }),
        };
        assert!(scope(&table(), &t, &[], true).is_empty());
    }

    /// Windows reads no processes yet (WP-7, WP-14): an empty census is not "nothing left", a sweep and the wait after
    /// a sandbox never report everything stopped.
    #[cfg(windows)]
    #[tokio::test]
    async fn on_windows_a_stop_never_reads_as_done() {
        let t = Target {
            roots: vec![a(21)],
            session: Some(a(20)),
        };
        assert!(census(&t, &[]).is_empty());
        let s = sweep(&t, &[]);
        assert_eq!((s.processes, s.left), (0, LEFT_UNKNOWN));
        let s = after_sandbox(t, Vec::new(), vec![p(21, 20, 20)]).await;
        assert_ne!(s.left, 0);
    }
}
