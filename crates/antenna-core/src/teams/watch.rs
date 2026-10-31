// SPDX-License-Identifier: AGPL-3.0-only
//! The live output of a team's workers for the owner (`team_watch`, CONTROL §25, D-111): every turn a worker runs, as
//! pieces: its start, the reply text as the parser produces it, the tools it uses, its end. The text is the worker's
//! output: data, never instructions. It goes only to the owner's watching connections: an agent's subscription reads
//! `Session::events`, which never carries it, and nothing of it is logged.
//!
//! One bounded broadcast per session carries the pieces of every team; a watch keeps its own team's. The pieces of a
//! turn are numbered, and a watch opened in the middle of a turn starts with a snapshot of the text so far: it drops the
//! pieces the snapshot already holds, so nothing is shown twice and nothing in between is lost.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex as StdMutex, PoisonError},
};

use antenna_proto::control::{WorkerOutput, worker_part};
use tokio::sync::broadcast;

/// Pieces a watching connection may fall behind by before it gets `lagged`.
const BACKLOG: usize = 1024;
/// A snapshot's text: the last 16 KiB of the turn's reply.
const SNAPSHOT_BYTES: usize = 16 * 1024;
/// The reply text kept per turn for snapshots grows to this, then is cut to the last [`SNAPSHOT_BYTES`].
const KEEP_BYTES: usize = 2 * SNAPSHOT_BYTES;
/// The longest end text.
const END_CHARS: usize = 200;

/// One piece on the broadcast: the worker's agent ID and the piece's number within its turn travel with it.
pub(crate) struct Piece {
    agent: i64,
    seq: u64,
    out: WorkerOutput,
}

/// A turn in progress.
struct Live {
    team: String,
    worker: String,
    task: Option<String>,
    turn: u64,
    /// The number of the latest piece (the start is 0).
    seq: u64,
    /// The reply text so far (its tail).
    text: String,
}

#[derive(Default)]
struct Turns {
    live: HashMap<i64, Live>,
    /// The last turn that ended, per worker.
    ended: HashMap<i64, u64>,
}

/// The session's live worker output.
pub(crate) struct Output {
    tx: broadcast::Sender<Arc<Piece>>,
    turns: StdMutex<Turns>,
}

impl Default for Output {
    fn default() -> Self {
        Self {
            tx: broadcast::channel(BACKLOG).0,
            turns: StdMutex::default(),
        }
    }
}

/// The text of a piece: no control characters but line breaks and tabs (no terminal sequences reach the owner).
fn clean(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect()
}

/// The last `max` bytes of `s`, starting at a character boundary.
pub(crate) fn tail(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut cut = s.len() - max;
    while !s.is_char_boundary(cut) {
        cut += 1;
    }
    &s[cut..]
}

/// How a turn ended, for its `end` piece: a time limit, an interrupt (the task was cancelled or reassigned, the worker
/// stopped), the agent's own error, its result, or none of these (the process ended without one).
pub(crate) fn end_text(
    result: bool,
    timed_out: bool,
    interrupted: bool,
    error: Option<&str>,
) -> String {
    if timed_out {
        return "timeout".into();
    }
    if interrupted {
        return "interrupted".into();
    }
    if let Some(e) = error {
        return format!("error: {e}").chars().take(END_CHARS).collect();
    }
    if result { "done" } else { "failed" }.into()
}

impl Output {
    fn send(&self, agent: i64, seq: u64, out: impl FnOnce() -> WorkerOutput) {
        // Nobody watches: no copy of the text.
        if self.tx.receiver_count() > 0 {
            let _ = self.tx.send(Arc::new(Piece {
                agent,
                seq,
                out: out(),
            }));
        }
    }

    /// A worker's turn began.
    pub(crate) fn start(
        &self,
        agent: i64,
        team: &str,
        worker: &str,
        task: Option<&str>,
        turn: u64,
    ) {
        self.turns
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .live
            .insert(
                agent,
                Live {
                    team: team.into(),
                    worker: worker.into(),
                    task: task.map(str::to_string),
                    turn,
                    seq: 0,
                    text: String::new(),
                },
            );
        self.send(agent, 0, || WorkerOutput {
            team: team.into(),
            worker: worker.into(),
            task: task.map(str::to_string),
            turn,
            part: worker_part::START.into(),
            text: String::new(),
        });
    }

    /// The next piece of the turn in progress: `text` is kept for snapshots, `activity` only passes.
    fn piece(&self, agent: i64, part: &'static str, text: &str) {
        let text = clean(text);
        if text.is_empty() {
            return;
        }
        let next = {
            let mut g = self.turns.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(t) = g.live.get_mut(&agent) else {
                return;
            };
            t.seq += 1;
            if part == worker_part::TEXT {
                t.text.push_str(&text);
                if t.text.len() > KEEP_BYTES {
                    t.text = tail(&t.text, SNAPSHOT_BYTES).to_string();
                }
            }
            (
                t.seq,
                t.team.clone(),
                t.worker.clone(),
                t.task.clone(),
                t.turn,
            )
        };
        let (seq, team, worker, task, turn) = next;
        self.send(agent, seq, || WorkerOutput {
            team,
            worker,
            task,
            turn,
            part: part.into(),
            text,
        });
    }

    /// A piece of the reply text.
    pub(crate) fn text(&self, agent: i64, text: &str) {
        self.piece(agent, worker_part::TEXT, text);
    }

    /// The worker uses a tool (`tool:Bash`) or waits (`loading`).
    pub(crate) fn activity(&self, agent: i64, what: &str) {
        self.piece(agent, worker_part::ACTIVITY, what);
    }

    /// The turn in progress ended ([`end_text`]).
    pub(crate) fn end(&self, agent: i64, how: &str) {
        let t = {
            let mut g = self.turns.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(t) = g.live.remove(&agent) else {
                return;
            };
            g.ended.insert(agent, t.turn);
            t
        };
        self.send(agent, t.seq + 1, || WorkerOutput {
            team: t.team,
            worker: t.worker,
            task: t.task,
            turn: t.turn,
            part: worker_part::END.into(),
            text: clean(how),
        });
    }

    /// The worker is gone.
    pub(crate) fn forget(&self, agent: i64) {
        let mut g = self.turns.lock().unwrap_or_else(PoisonError::into_inner);
        g.live.remove(&agent);
        g.ended.remove(&agent);
    }

    /// A watch of one team: it subscribes first, then takes the snapshot, so a piece sent in between is either in the
    /// snapshot (and dropped from the stream by its number) or after it.
    pub(crate) fn watch(&self, team: &str) -> Watch {
        let rx = self.tx.subscribe();
        let g = self.turns.lock().unwrap_or_else(PoisonError::into_inner);
        let mut seen = HashMap::new();
        let mut snapshot = Vec::new();
        for (agent, t) in &g.live {
            seen.insert(*agent, (t.turn, t.seq));
            if t.team == team {
                snapshot.push(WorkerOutput {
                    team: t.team.clone(),
                    worker: t.worker.clone(),
                    task: t.task.clone(),
                    turn: t.turn,
                    part: worker_part::SNAPSHOT.into(),
                    text: tail(&t.text, SNAPSHOT_BYTES).to_string(),
                });
            }
        }
        for (agent, turn) in &g.ended {
            seen.entry(*agent).or_insert((*turn, u64::MAX));
        }
        drop(g);
        snapshot.sort_by(|a, b| a.worker.cmp(&b.worker));
        Watch {
            team: team.into(),
            rx,
            seen,
            snapshot,
        }
    }
}

/// What a watch reads next.
pub(crate) enum Next {
    /// A piece of this team's output.
    Piece(WorkerOutput),
    /// The connection fell behind: this many pieces were dropped.
    Lagged(u64),
    /// The session ended.
    Closed,
}

/// One owner connection's watch of a team.
pub(crate) struct Watch {
    team: String,
    rx: broadcast::Receiver<Arc<Piece>>,
    /// Per worker, the last piece the snapshot covers: (turn, piece number); an ended turn covers all its pieces.
    seen: HashMap<i64, (u64, u64)>,
    /// The turns in progress when the watch opened, sent first.
    pub(crate) snapshot: Vec<WorkerOutput>,
}

impl Watch {
    /// The next piece of this team's output.
    pub(crate) async fn next(&mut self) -> Next {
        loop {
            match self.rx.recv().await {
                Ok(p) => {
                    if let Some(o) = self.keep(&p) {
                        return Next::Piece(o);
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => return Next::Lagged(n),
                Err(broadcast::error::RecvError::Closed) => return Next::Closed,
            }
        }
    }

    /// Only this team's workers, and only what the snapshot did not already hold.
    fn keep(&mut self, p: &Piece) -> Option<WorkerOutput> {
        if p.out.team != self.team {
            return None;
        }
        if let Some(&(turn, seq)) = self.seen.get(&p.agent) {
            if p.out.turn < turn || (p.out.turn == turn && p.seq <= seq) {
                return None;
            }
            // A worker's pieces come in order: everything after this one is new too.
            self.seen.remove(&p.agent);
        }
        Some(p.out.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn next_now(w: &mut Watch) -> Option<WorkerOutput> {
        loop {
            match w.rx.try_recv() {
                Ok(p) => {
                    if let Some(o) = w.keep(&p) {
                        return Some(o);
                    }
                }
                Err(_) => return None,
            }
        }
    }

    #[test]
    fn a_tail_starts_at_a_character_boundary() {
        assert_eq!(tail("abc", 5), "abc");
        assert_eq!(tail("abcdef", 3), "def");
        // "é" is two bytes: a cut inside it moves forward.
        assert_eq!(tail("aéé", 3), "é");
        assert_eq!(tail("ééé", 5), "éé");
        let long = "é".repeat(20_000);
        let t = tail(&long, SNAPSHOT_BYTES);
        assert!(t.len() <= SNAPSHOT_BYTES && t.len() >= SNAPSHOT_BYTES - 1);
        assert!(t.chars().all(|c| c == 'é'));
    }

    #[test]
    fn the_end_says_how_the_turn_ended() {
        assert_eq!(end_text(true, false, false, None), "done");
        assert_eq!(end_text(false, false, false, None), "failed");
        assert_eq!(end_text(true, true, true, Some("x")), "timeout");
        assert_eq!(end_text(false, false, true, Some("x")), "interrupted");
        assert_eq!(end_text(true, false, false, Some("401")), "error: 401");
        let e = end_text(true, false, false, Some(&"e".repeat(300)));
        assert_eq!(e.chars().count(), END_CHARS);
        assert!(e.starts_with("error: eee"));
    }

    /// A watch opened mid-turn gets the text so far once, then only what follows; another team's worker never
    /// appears; a turn that ended before the watch opened sends nothing more; terminal sequences are removed.
    #[test]
    fn a_watch_starts_from_its_snapshot_and_keeps_its_team() {
        let o = Output::default();
        o.start(1, "web", "web.coder-1", Some("t1"), 4);
        o.text(1, "Hello, ");
        o.activity(1, "tool:Bash");
        o.start(2, "api", "api.coder-1", None, 1);
        o.text(2, "other team");
        o.start(3, "web", "web.docs-1", Some("t3"), 2);
        o.end(3, "done");
        let mut w = o.watch("web");
        assert_eq!(w.snapshot.len(), 1);
        let s = &w.snapshot[0];
        assert_eq!(
            (s.worker.as_str(), s.part.as_str(), s.text.as_str(), s.turn),
            ("web.coder-1", "snapshot", "Hello, ", 4)
        );
        assert_eq!(s.task.as_deref(), Some("t1"));
        o.text(1, "world\u{1b}[2J");
        o.text(2, "still the other team");
        o.end(1, "done");
        o.start(3, "web", "web.docs-1", Some("t3"), 3);
        let got: Vec<(String, String)> = std::iter::from_fn(|| next_now(&mut w))
            .map(|p| (p.part, p.text))
            .collect();
        assert_eq!(
            got,
            vec![
                ("text".to_string(), "world[2J".to_string()),
                ("end".to_string(), "done".to_string()),
                ("start".to_string(), String::new()),
            ]
        );
    }

    /// A piece sent after the watch subscribed but before it read the snapshot reaches it twice: in the snapshot and
    /// on the broadcast. Its number drops the second copy, and the start of a turn the snapshot holds too.
    #[test]
    fn pieces_the_snapshot_holds_are_not_sent_again() {
        let o = Output::default();
        o.start(1, "web", "web.coder-1", None, 1);
        o.text(1, "one ");
        let mut w = o.watch("web");
        assert_eq!(w.snapshot[0].text, "one ");
        let piece = |seq: u64, turn: u64, part: &str| Piece {
            agent: 1,
            seq,
            out: WorkerOutput {
                team: "web".into(),
                worker: "web.coder-1".into(),
                task: None,
                turn,
                part: part.into(),
                text: "x".into(),
            },
        };
        assert!(w.keep(&piece(0, 1, "start")).is_none());
        assert!(w.keep(&piece(1, 1, "text")).is_none());
        assert!(w.keep(&piece(5, 0, "end")).is_none(), "an older turn");
        assert!(w.keep(&piece(2, 1, "text")).is_some());
        o.text(1, "two");
        let got: Vec<String> = std::iter::from_fn(|| next_now(&mut w))
            .map(|p| p.text)
            .collect();
        assert_eq!(got, vec!["two".to_string()]);
    }

    #[test]
    fn the_kept_text_stays_bounded() {
        let o = Output::default();
        o.start(1, "web", "w", None, 1);
        for _ in 0..100 {
            o.text(1, &"x".repeat(1000));
        }
        let w = o.watch("web");
        assert_eq!(w.snapshot[0].text.len(), SNAPSHOT_BYTES);
        let g = o.turns.lock().unwrap_or_else(PoisonError::into_inner);
        assert!(g.live[&1].text.len() <= KEEP_BYTES);
    }
}
