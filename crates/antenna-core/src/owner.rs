// SPDX-License-Identifier: AGPL-3.0-only
//! Owner session (Q-14b, `docs/CONTROL.md` §3): without an open session, a process with the same uid is **not** the
//! owner. A session is opened with the owner password and comes in three kinds:
//!
//! - **terminal** (`tty`), like `sudo` (`timestamp_type=tty`): the key is the client's controlling terminal, its
//!   session (`setsid`) and the session leader's start time; it lives 15 minutes after the last command;
//! - **parent** (`parent`), a client without a terminal (a script): the key is the client's parent process (PID +
//!   start time), like `sudo` with `timestamp_type=ppid`; it also lives 15 minutes after the last command. It never
//!   binds to PID 1 or `systemd` (the parent of orphans and user services);
//! - **connection** (`held`): the window or TUI holds a `login {hold: true}` connection, and the session lives while
//!   it is open; other connections present the token (`hello.session`), on Linux and macOS only from the same process.
//!
//! A process in the tree of a bound agent gets the agent role before any session check (D-28): an owner session in a
//! terminal does not make an agent launched from that terminal via MCP the owner. Limits: CONTROL §11.

use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use antenna_proto::control::{OWNER_SESSION_PREFIX, code};
use zeroize::Zeroizing;

use crate::{
    crypto,
    error::{Error, Result},
    procinfo::{self, ProcStat},
};

/// A terminal or parent session lives this long after the last command (like `sudo`).
pub const TTL: Duration = Duration::from_secs(15 * 60);

/// Session key derived from the client process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TimedKey {
    /// Terminal: `tty_nr`, session ID, start time of the session leader.
    Tty {
        /// Controlling terminal.
        tty: i32,
        /// Session.
        sid: i32,
        /// Start time of the session leader.
        leader_start: u64,
    },
    /// The client's parent process.
    Parent {
        /// PID.
        pid: i32,
        /// Start time.
        start: u64,
    },
}

impl TimedKey {
    /// `tty` / `parent`.
    pub fn kind(&self) -> &'static str {
        match self {
            TimedKey::Tty { .. } => "tty",
            TimedKey::Parent { .. } => "parent",
        }
    }
}

/// Client key from its process chain (`chain[0]` is the client itself). `None` if it cannot be determined (no `/proc`,
/// the session leader has exited, the parent is PID 1 or `systemd`).
pub fn timed_key(chain: Option<&[ProcStat]>) -> Option<TimedKey> {
    let chain = chain?;
    let me = chain.first()?;
    if me.tty != 0 && me.sid > 0 {
        let leader_start = chain
            .iter()
            .find(|p| p.pid == me.sid)
            .map(|p| p.start)
            .or_else(|| procinfo::stat(me.sid).map(|p| p.start))?;
        return Some(TimedKey::Tty {
            tty: me.tty,
            sid: me.sid,
            leader_start,
        });
    }
    let parent = chain.get(1)?;
    if parent.pid <= 1 || parent.comm == "systemd" {
        return None;
    }
    Some(TimedKey::Parent {
        pid: parent.pid,
        start: parent.start,
    })
}

struct Held {
    /// The process holding the session (PID, start time); `None` where no process is read. On Windows the PID is the
    /// client's word (D-135): there the token's secrecy protects the session, and the holder is a consistency check.
    holder: Option<(i32, u64)>,
    alive: Arc<AtomicBool>,
}

/// Open owner sessions (in daemon memory; `antenna lock` and a restart close them).
#[derive(Default)]
pub struct OwnerSessions {
    timed: HashMap<TimedKey, u64>,
    held: HashMap<[u8; 32], Held>,
}

impl std::fmt::Debug for OwnerSessions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "OwnerSessions(timed {}, held {})",
            self.timed.len(),
            self.held.len()
        )
    }
}

fn token_hash(token: &str) -> [u8; 32] {
    crypto::sha256(&[b"x/owner-session/v0", token.as_bytes()])
}

/// A session held by a connection: the token (shown to the client) and the connection's liveness flag.
pub struct HeldGuard {
    /// Token.
    pub token: Zeroizing<String>,
    hash: [u8; 32],
    alive: Arc<AtomicBool>,
}

impl HeldGuard {
    /// Token hash (to remove the entry).
    pub fn hash(&self) -> [u8; 32] {
        self.hash
    }
}

impl Drop for HeldGuard {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::SeqCst);
    }
}

impl OwnerSessions {
    /// This connection's session: `held` (by token), `tty` / `parent` (by process) or `None`. A valid terminal or
    /// parent session is extended by [`TTL`].
    pub fn check(
        &mut self,
        chain: Option<&[ProcStat]>,
        token: Option<&str>,
        now_ms: u64,
    ) -> Option<&'static str> {
        self.held.retain(|_, h| h.alive.load(Ordering::SeqCst));
        self.timed.retain(|_, exp| *exp > now_ms);
        if let Some(t) = token {
            let h = self.held.get(&token_hash(t))?;
            let me = chain.and_then(|c| c.first()).map(|p| (p.pid, p.start));
            return match (h.holder, me) {
                (Some(a), Some(b)) if a == b => Some("held"),
                (None, _) => Some("held"),
                _ => None,
            };
        }
        let key = timed_key(chain)?;
        let exp = self.timed.get_mut(&key)?;
        *exp = now_ms + TTL.as_millis() as u64;
        Some(key.kind())
    }

    /// Open (or extend) a terminal or parent session for this client. The password has already been checked.
    pub fn open_timed(
        &mut self,
        chain: Option<&[ProcStat]>,
        now_ms: u64,
    ) -> Result<(&'static str, u64)> {
        let key = timed_key(chain).ok_or_else(|| {
            Error::new(
                code::FORBIDDEN,
                "cannot tie an owner session to this process (no terminal and no suitable parent process); \
                 a window or TUI keeps a session with `login {hold: true}`",
            )
        })?;
        let exp = now_ms + TTL.as_millis() as u64;
        self.timed.insert(key, exp);
        Ok((key.kind(), exp))
    }

    /// Whether this connection's session is valid right now, without extending it (for long-lived connections:
    /// subscriptions).
    pub fn peek(
        &mut self,
        chain: Option<&[ProcStat]>,
        token: Option<&str>,
        now_ms: u64,
    ) -> Option<&'static str> {
        self.held.retain(|_, h| h.alive.load(Ordering::SeqCst));
        self.timed.retain(|_, exp| *exp > now_ms);
        if let Some(t) = token {
            let h = self.held.get(&token_hash(t))?;
            let me = chain.and_then(|c| c.first()).map(|p| (p.pid, p.start));
            return match (h.holder, me) {
                (Some(a), Some(b)) if a == b => Some("held"),
                (None, _) => Some("held"),
                _ => None,
            };
        }
        let key = timed_key(chain)?;
        self.timed.contains_key(&key).then(|| key.kind())
    }

    /// Open a session held by the connection. The session closes when the returned [`HeldGuard`] is dropped.
    /// On Linux, macOS (`procinfo::SUPPORTED`) and Windows only if the client's process was read (otherwise the token
    /// would become a bearer token).
    pub fn open_held(&mut self, chain: Option<&[ProcStat]>) -> Result<HeldGuard> {
        if (procinfo::SUPPORTED || cfg!(windows)) && chain.and_then(|c| c.first()).is_none() {
            return Err(Error::new(
                code::FORBIDDEN,
                "cannot read the client's process; an owner session cannot be held by it",
            ));
        }
        let raw = crypto::random_secret();
        let token = Zeroizing::new(format!(
            "{OWNER_SESSION_PREFIX}{}",
            data_encoding::BASE32_NOPAD
                .encode(raw.as_slice())
                .to_ascii_lowercase()
        ));
        let hash = token_hash(&token);
        let alive = Arc::new(AtomicBool::new(true));
        self.held.insert(
            hash,
            Held {
                holder: chain.and_then(|c| c.first()).map(|p| (p.pid, p.start)),
                alive: alive.clone(),
            },
        );
        Ok(HeldGuard { token, hash, alive })
    }

    /// Close this client's session (`logout`): the token session or the terminal/parent session.
    pub fn close(&mut self, chain: Option<&[ProcStat]>, token: Option<&str>) -> bool {
        if let Some(t) = token {
            return self.held.remove(&token_hash(t)).is_some();
        }
        timed_key(chain).is_some_and(|k| self.timed.remove(&k).is_some())
    }

    /// Remove a session by token hash (the connection closed).
    pub fn drop_held(&mut self, hash: &[u8; 32]) {
        self.held.remove(hash);
    }

    /// Close all (`antenna lock`).
    pub fn clear(&mut self) {
        self.timed.clear();
        self.held.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: i32, ppid: i32, sid: i32, tty: i32, start: u64, comm: &str) -> ProcStat {
        ProcStat {
            pid,
            comm: comm.into(),
            ppid,
            sid,
            tty,
            start,
        }
    }

    #[test]
    fn terminal_session_like_sudo() {
        let mut s = OwnerSessions::default();
        // The CLI in a terminal: tty 34816, session 100 (leader is bash, started at 5)
        let term = vec![
            p(300, 200, 100, 34816, 30, "x"),
            p(200, 100, 100, 34816, 20, "bash"),
            p(100, 1, 100, 34816, 5, "bash"),
            p(1, 0, 1, 0, 1, "systemd"),
        ];
        assert_eq!(s.check(Some(&term), None, 1000), None);
        let (kind, exp) = s.open_timed(Some(&term), 1000).unwrap();
        assert_eq!((kind, exp), ("tty", 1000 + TTL.as_millis() as u64));
        // Another process in the same terminal and session: owner
        let term2 = vec![
            p(301, 100, 100, 34816, 31, "x"),
            term[2].clone(),
            term[3].clone(),
        ];
        assert_eq!(s.check(Some(&term2), None, 2000), Some("tty"));
        // An agent with the same uid and no terminal (Claude Code: setsid, no tty): not the owner
        let agent = vec![
            p(400, 399, 399, 0, 40, "x"),
            p(399, 50, 399, 0, 39, "bash"),
            p(50, 1, 50, 0, 10, "claude"),
            p(1, 0, 1, 0, 1, "systemd"),
        ];
        assert_eq!(s.check(Some(&agent), None, 2000), None);
        // Same terminal but a different session leader (the terminal was reused): not the owner
        let reused = vec![
            p(500, 100, 100, 34816, 50, "x"),
            p(100, 1, 100, 34816, 45, "bash"),
        ];
        assert_eq!(s.check(Some(&reused), None, 2000), None);
        // 15 minutes without commands: the session expired; a command extends it
        let later = 2000 + TTL.as_millis() as u64 - 1;
        assert_eq!(s.check(Some(&term2), None, later), Some("tty"));
        assert_eq!(
            s.check(Some(&term2), None, later + TTL.as_millis() as u64),
            None
        );
        // Without /proc there is no key
        assert_eq!(timed_key(None), None);
    }

    #[test]
    fn parent_session_and_refusals() {
        let mut s = OwnerSessions::default();
        let script = vec![p(600, 590, 580, 0, 60, "x"), p(590, 580, 580, 0, 59, "sh")];
        assert_eq!(s.open_timed(Some(&script), 0).unwrap().0, "parent");
        // Another child of the same script: owner; a child of another process: not
        assert_eq!(
            s.check(
                Some(&[p(601, 590, 580, 0, 61, "x"), script[1].clone()]),
                None,
                1
            ),
            Some("parent")
        );
        assert_eq!(
            s.check(
                Some(&[p(602, 591, 580, 0, 62, "x"), p(591, 580, 580, 0, 58, "sh")]),
                None,
                1
            ),
            None
        );
        // Same parent PID but a different process (start time): not
        assert_eq!(
            s.check(
                Some(&[p(603, 590, 580, 0, 63, "x"), p(590, 1, 580, 0, 99, "sh")]),
                None,
                1
            ),
            None
        );
        // An orphan under PID 1 or a systemd service: no session is opened
        assert!(
            s.open_timed(Some(&[p(700, 1, 700, 0, 70, "x")]), 0)
                .is_err()
        );
        assert!(
            s.open_timed(
                Some(&[
                    p(701, 650, 650, 0, 71, "x"),
                    p(650, 1, 650, 0, 2, "systemd")
                ]),
                0
            )
            .is_err()
        );
    }

    #[test]
    fn held_session_lives_with_the_connection_and_the_process() {
        let mut s = OwnerSessions::default();
        let win = vec![p(800, 1, 800, 0, 80, "x_desktop")];
        let g = s.open_held(Some(&win)).unwrap();
        let tok = g.token.to_string();
        assert!(tok.starts_with("xos_"));
        assert_eq!(s.check(Some(&win), Some(&tok), 0), Some("held"));
        // A token from another process is not accepted
        assert_eq!(
            s.check(Some(&[p(801, 1, 801, 0, 81, "x")]), Some(&tok), 0),
            None
        );
        // Wrong token
        assert_eq!(s.check(Some(&win), Some("xos_nope"), 0), None);
        drop(g);
        assert_eq!(s.check(Some(&win), Some(&tok), 0), None);
        // On Linux, macOS and Windows no connection session is issued without the client's process
        if procinfo::SUPPORTED || cfg!(windows) {
            assert!(s.open_held(None).is_err());
        }
    }
}
