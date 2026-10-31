// SPDX-License-Identifier: AGPL-3.0-only
//! The headless waker of `antenna session` (D-108): the window's Code mode wake (D-UI-23, D-UI-25) without a window.
//!
//! What may cause a line: the facts the agent itself gets (`agent_watch`, CONTROL §23: a new message it may read, an
//! approval of one of its own requests); no text, no taint. What is typed: an [`AllowedLine`], nothing else. When: the
//! agent CLI's own state first (Claude Code's hooks; Codex's `notify` after a turn), and the screen must agree: an
//! empty prompt, the cursor right after it, no dialog, tmux not in a mode of its own, the pane quiet for 5 s and no key
//! from a person attached to the session for 5 s. The waker cannot see a person's keys the way the window does, so it
//! types only where the screen check confirms the empty prompt, even when the hooks say "idle". A line for a running
//! Claude Code turn is left for the turn's Stop hook instead of being typed. At most one line per 30 s; what arrives
//! meanwhile is coalesced into the next one. Anything not recognised types nothing (fail closed).

use std::{
    collections::{BTreeSet, VecDeque},
    time::{Duration, Instant},
};

use super::{
    hooks::HookEvent,
    keys::{Hold, Key, may_interrupt},
    lines::{AllowedLine, LineKind, sanitize_label},
    screen::{Screen, claude_layout_known, claude_ready, codex_layout_known, codex_ready},
};

/// Which agent CLI runs in the session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Cli {
    /// Claude Code: hooks for the state, the Stop hook for a running turn.
    Claude,
    /// Codex: its `notify` program after a turn; no way into a running turn, so lines wait for its idle composer.
    Codex,
}

impl Cli {
    /// The name in the session's record.
    pub fn word(self) -> &'static str {
        match self {
            Cli::Claude => "claude",
            Cli::Codex => "codex",
        }
    }

    /// From the record.
    pub fn parse(s: &str) -> Option<Cli> {
        match s {
            "claude" => Some(Cli::Claude),
            "codex" => Some(Cli::Codex),
            _ => None,
        }
    }
}

/// The agent CLI's state as its own interfaces report it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum State {
    /// Nothing reported yet, or no longer trustworthy: only the screen may decide.
    Unknown,
    /// At its prompt.
    Idle,
    /// A turn runs.
    Working,
    /// A permission dialog is open (Enter there answers "Yes").
    Dialog,
    /// The session ended.
    Ended,
}

impl State {
    /// The word in the session's status.
    pub fn word(self) -> &'static str {
        match self {
            State::Unknown => "unknown",
            State::Idle => "idle",
            State::Working => "working",
            State::Dialog => "dialog",
            State::Ended => "ended",
        }
    }
}

/// The state machine of one session.
#[derive(Debug, Clone)]
pub(crate) struct Tracker {
    /// Which CLI.
    pub cli: Cli,
    /// The state.
    pub state: State,
    /// When the waker last typed a line (Codex: working until `notify` says the turn completed).
    typed_at: Option<Instant>,
    /// `notify` (Codex) or a hook was seen in this session.
    pub reported: bool,
    /// A hook (not only `notify`) was seen: the hooks say the state, and a Codex turn can be continued by its Stop
    /// hook.
    pub hooks_seen: bool,
}

/// Without a `notify` after a typed line within this time, a Codex session's state is the screen's to decide again.
const CODEX_NO_NOTIFY: Duration = Duration::from_secs(20);

impl Tracker {
    /// A new session.
    pub fn new(cli: Cli) -> Self {
        Tracker {
            cli,
            state: State::Unknown,
            typed_at: None,
            reported: false,
            hooks_seen: false,
        }
    }

    /// A hook or `notify` event.
    pub fn on_hook(&mut self, e: HookEvent) {
        self.reported = true;
        if e == HookEvent::TurnComplete {
            // Codex runs `notify` for its helper threads too (a title for a new conversation, while the person's turn
            // still runs): with hooks it says nothing the hooks do not say better.
            if !self.hooks_seen {
                self.state = State::Idle;
            }
            return;
        }
        self.hooks_seen = true;
        self.state = match e {
            HookEvent::Start
            | HookEvent::Stop
            | HookEvent::NotifyIdle
            | HookEvent::TurnComplete
            | HookEvent::Interrupt => State::Idle,
            HookEvent::Prompt | HookEvent::Tool | HookEvent::ToolDone | HookEvent::Continued => {
                State::Working
            }
            HookEvent::Permission | HookEvent::NotifyPermission => State::Dialog,
            HookEvent::End => State::Ended,
        };
    }

    /// The waker typed a line and pressed Enter: a turn starts (Claude Code's hook will confirm it).
    pub fn typed(&mut self, now: Instant) {
        self.typed_at = Some(now);
        if self.state != State::Ended {
            self.state = State::Working;
        }
    }

    /// Codex never reported after a typed line: forget what the waker assumed.
    fn settle(&mut self, now: Instant) {
        if self.cli == Cli::Codex
            && self.state == State::Working
            && !self.reported
            && self
                .typed_at
                .is_some_and(|t| now.duration_since(t) > CODEX_NO_NOTIFY)
        {
            self.state = State::Unknown;
        }
    }
}

/// How a waiting line can reach the agent now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Route {
    /// Type it at the prompt (still subject to the quiet check).
    Type,
    /// A Claude Code turn runs: leave it for the turn's Stop hook.
    Continue,
    /// Not now.
    Wait,
}

/// The route for a line in the tracker's state on this screen.
pub(crate) fn route(t: &Tracker, s: &Screen) -> Route {
    let ready = match t.cli {
        Cli::Claude => claude_ready(s),
        Cli::Codex => codex_ready(s),
    };
    match (t.cli, t.state) {
        (_, State::Dialog | State::Ended) => Route::Wait,
        (Cli::Claude, State::Working) => Route::Continue,
        // Codex with its hooks (0.160 and later, once the owner trusted them): its Stop hook continues a turn too
        (Cli::Codex, State::Working) if t.hooks_seen => Route::Continue,
        // Codex with `notify` only: wait for the turn to complete
        (Cli::Codex, State::Working) => Route::Wait,
        (_, State::Idle | State::Unknown) => {
            if ready {
                Route::Type
            } else {
                Route::Wait
            }
        }
    }
}

/// A fact from the agent's own subscription.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Fact {
    /// A new message the agent reads, from this contact (the owner's local label).
    Message(String),
    /// The owner approved this request of the agent's.
    Approved(String),
    /// The owner answered or set aside this question of the agent's (D-118).
    Answered(String),
    /// An approval request waits for this approver's answer (PG-57).
    ToAnswer(String),
    /// The owner's urgent message from this own computer (the owner's local label), honoured by the daemon (PG-58):
    /// interrupt the turn, then the urgent line.
    Urgent {
        /// The contact's label.
        contact: String,
        /// The message ID (each counts once).
        id: String,
    },
}

/// One line given to the agent, for the log (never a message's text).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LogEntry {
    /// What kind.
    pub kind: LineKind,
    /// The contact named in a wake line (sanitized; `None`: several, or not printable).
    pub contact: Option<String>,
    /// The Stop hook continued with it; nothing was typed.
    pub continued: bool,
}

/// What the loop should do now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Action {
    /// Nothing.
    None,
    /// Write this continuation for the Stop hook (replacing one left before).
    Offer(AllowedLine),
    /// Take back what was left for the Stop hook (if it is still there), then type this line and press Enter.
    Type(AllowedLine),
    /// The owner's urgent message (PG-58): take back what was left for the Stop hook (an interrupted turn does not
    /// stop through it), then press this key, nothing else.
    Interrupt(Key),
}

/// The timing of the waker.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Timing {
    /// The pane must not change for this long before a line is typed.
    pub quiet: Duration,
    /// At most one line in this time.
    pub every: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Timing {
            quiet: Duration::from_secs(5),
            every: Duration::from_secs(30),
        }
    }
}

/// The waker's decisions for one session (no I/O: the loop in `pane.rs` feeds it and carries out its actions).
pub(crate) struct Waker {
    /// The CLI's state.
    pub tracker: Tracker,
    timing: Timing,
    from: BTreeSet<String>,
    approved: bool,
    answered: bool,
    to_answer: bool,
    seen_approvals: VecDeque<String>,
    offered: Option<(AllowedLine, LogEntry)>,
    cooldown_until: Option<Instant>,
    last_fp: Option<u64>,
    quiet_since: Instant,
    /// The owner's switch ("wake on new messages", on by default).
    pub on: bool,
    started: Instant,
    pending_since: Option<Instant>,
    /// The owner's urgent messages that wait, by contact (PG-58).
    urgent: BTreeSet<String>,
    /// An urgent message came and its turn has not been interrupted yet.
    interrupt_due: bool,
    /// When the waker last pressed Escape.
    interrupted_at: Option<Instant>,
    /// Why the last urgent interrupt was held back (for `session list`).
    pub hold: Option<Hold>,
}

/// Without any hook or `notify` event this long after the start, and with a screen the checks do not know, the wake
/// says it is unavailable for this CLI version (D-UI-25 item 5).
const HOOKS_LATE: Duration = Duration::from_secs(20);

impl Waker {
    /// A waker for a new session.
    pub fn new(cli: Cli, timing: Timing, now: Instant) -> Self {
        Waker {
            tracker: Tracker::new(cli),
            timing,
            from: BTreeSet::new(),
            approved: false,
            answered: false,
            to_answer: false,
            seen_approvals: VecDeque::new(),
            offered: None,
            cooldown_until: None,
            last_fp: None,
            quiet_since: now,
            on: true,
            started: now,
            pending_since: None,
            urgent: BTreeSet::new(),
            interrupt_due: false,
            interrupted_at: None,
            hold: None,
        }
    }

    /// A line waits, but neither the CLI's own interfaces nor its screen say when it may be typed: no hook (Claude
    /// Code) or `notify` (Codex) since the start, and a screen layout the checks do not know. Nothing is typed;
    /// `session list` says so.
    pub fn unavailable(&self, now: Instant, s: &Screen) -> bool {
        let known = match self.tracker.cli {
            Cli::Claude => claude_layout_known(s),
            Cli::Codex => codex_layout_known(s),
        };
        self.pending_since
            .is_some_and(|t| now.duration_since(t) > HOOKS_LATE)
            && now.duration_since(self.started) > HOOKS_LATE
            && !self.tracker.reported
            && !known
    }

    /// Something waits.
    pub fn pending(&self) -> bool {
        !self.from.is_empty()
            || self.approved
            || self.answered
            || self.to_answer
            || !self.urgent.is_empty()
    }

    /// Everything that waits is given (typed, or taken by the Stop hook).
    fn clear(&mut self) {
        self.from.clear();
        self.approved = false;
        self.answered = false;
        self.to_answer = false;
        self.urgent.clear();
        self.interrupt_due = false;
        self.hold = None;
    }

    /// A line is left for the Stop hook.
    pub fn offered(&self) -> bool {
        self.offered.is_some()
    }

    /// A fact arrived. Each approval counts once.
    pub fn on_fact(&mut self, f: Fact) {
        if !self.on {
            return;
        }
        match f {
            Fact::Message(contact) => {
                self.from.insert(contact);
            }
            Fact::Approved(id) => {
                if self.seen_approvals.contains(&id) {
                    return;
                }
                self.seen_approvals.push_back(id);
                if self.seen_approvals.len() > 512 {
                    self.seen_approvals.pop_front();
                }
                self.approved = true;
            }
            Fact::Answered(id) => {
                if self.seen_approvals.contains(&id) {
                    return;
                }
                self.seen_approvals.push_back(id);
                self.answered = true;
            }
            Fact::ToAnswer(id) => {
                let key = format!("to-answer:{id}");
                if self.seen_approvals.contains(&key) {
                    return;
                }
                self.seen_approvals.push_back(key);
                if self.seen_approvals.len() > 512 {
                    self.seen_approvals.pop_front();
                }
                self.to_answer = true;
            }
            Fact::Urgent { contact, id } => {
                let key = format!("urgent:{id}");
                if self.seen_approvals.contains(&key) {
                    return;
                }
                self.seen_approvals.push_back(key);
                if self.seen_approvals.len() > 512 {
                    self.seen_approvals.pop_front();
                }
                self.urgent.insert(contact);
                self.interrupt_due = true;
            }
        }
    }

    /// The owner turned the wake off (`true` returned: a continuation was left and must be taken back) or on.
    pub fn set_on(&mut self, on: bool) -> bool {
        self.on = on;
        if !on {
            self.clear();
            return self.offered.take().is_some();
        }
        false
    }

    /// A hook or `notify` event; returns the log entry when the Stop hook used the waker's line (that is the wake).
    pub fn on_hook(&mut self, e: HookEvent, now: Instant) -> Option<LogEntry> {
        self.tracker.on_hook(e);
        if e == HookEvent::Continued
            && let Some((_, entry)) = self.offered.take()
        {
            self.clear();
            self.cooldown_until = Some(now + self.timing.every);
            return Some(entry);
        }
        None
    }

    /// The line that waits and its log entry. A wake covers a waiting "Approved": the inbox carries the outcome of
    /// approved requests (D-100).
    fn line(&self, continued: bool) -> (AllowedLine, LogEntry) {
        // The owner's urgent message first (PG-58): it covers whatever else waits, all of it is in the inbox
        if !self.urgent.is_empty() {
            let one = (self.urgent.len() == 1)
                .then(|| self.urgent.iter().next())
                .flatten();
            let line = one.map_or_else(AllowedLine::urgent_any, |c| AllowedLine::urgent_from(c));
            let named = line != AllowedLine::urgent_any();
            return (
                line,
                LogEntry {
                    kind: LineKind::Urgent,
                    contact: one.filter(|_| named).map(|c| sanitize_label(c)),
                    continued,
                },
            );
        }
        if !self.from.is_empty() {
            if self.from.len() == 1
                && let Some(one) = self.from.iter().next()
            {
                let line = AllowedLine::wake_from(one);
                let named = line != AllowedLine::wake_any();
                return (
                    line,
                    LogEntry {
                        kind: LineKind::Wake,
                        contact: named.then(|| sanitize_label(one)),
                        continued,
                    },
                );
            }
            return (
                AllowedLine::wake_any(),
                LogEntry {
                    kind: LineKind::Wake,
                    contact: None,
                    continued,
                },
            );
        }
        // The answer is in the inbox, and so are decided approvals: the answered line covers both
        if self.answered {
            return (
                AllowedLine::answered(),
                LogEntry {
                    kind: LineKind::Answered,
                    contact: None,
                    continued,
                },
            );
        }
        // An approver's request to answer (PG-57); its own decided requests come in the same inbox
        if self.to_answer {
            return (
                AllowedLine::to_answer(),
                LogEntry {
                    kind: LineKind::ToAnswer,
                    contact: None,
                    continued,
                },
            );
        }
        (
            AllowedLine::approved(),
            LogEntry {
                kind: LineKind::Approved,
                contact: None,
                continued,
            },
        )
    }

    /// Look at the pane (`None`: tmux did not answer) with the last time a person's key reached the session
    /// (`key_s`, Unix seconds; `now_s` the same clock now) and decide.
    pub fn decide(
        &mut self,
        now: Instant,
        screen: Option<&Screen>,
        key_s: u64,
        now_s: u64,
    ) -> Action {
        self.tracker.settle(now);
        let Some(screen) = screen else {
            return Action::None;
        };
        let fp = screen.fingerprint();
        if self.last_fp != Some(fp) {
            self.last_fp = Some(fp);
            self.quiet_since = now;
        }
        if !self.on || !self.pending() {
            self.pending_since = None;
            return Action::None;
        }
        self.pending_since.get_or_insert(now);
        // Seconds from tmux: a key in the same second counts as now.
        let keys_quiet = now_s.saturating_sub(key_s) > self.timing.quiet.as_secs();
        // The owner's urgent message (PG-58): one Escape into a running turn, where `keys` allows it
        if self.interrupt_due {
            let since = self.interrupted_at.map(|t| now.duration_since(t));
            match may_interrupt(&self.tracker, screen, keys_quiet, since) {
                Ok(key) => return Action::Interrupt(key),
                // Nothing to interrupt: the line goes at the prompt like any other
                Err(Hold::NotBusy) => {
                    self.interrupt_due = false;
                    self.hold = None;
                }
                Err(h) => self.hold = Some(h),
            }
        }
        // The urgent line does not wait for the rate limit of ordinary lines: the interrupt has its own
        if self.urgent.is_empty() && self.cooldown_until.is_some_and(|t| now < t) {
            return Action::None;
        }
        self.cooldown_until = None;
        match route(&self.tracker, screen) {
            Route::Continue => {
                let (line, entry) = self.line(true);
                if self.offered.as_ref().is_some_and(|(l, _)| *l == line) {
                    return Action::None;
                }
                self.offered = Some((line.clone(), entry));
                Action::Offer(line)
            }
            Route::Type => {
                if now.duration_since(self.quiet_since) < self.timing.quiet || !keys_quiet {
                    return Action::None;
                }
                let (line, _) = self.line(false);
                Action::Type(line)
            }
            Route::Wait => Action::None,
        }
    }

    /// An offer could not be written: try again at the next look.
    pub fn offer_failed(&mut self) {
        self.offered = None;
    }

    /// The loop typed the line and pressed Enter.
    pub fn typed(&mut self, now: Instant) -> LogEntry {
        let (_, entry) = self.line(false);
        self.offered = None;
        self.clear();
        self.tracker.typed(now);
        self.cooldown_until = Some(now + self.timing.every);
        entry
    }

    /// The loop pressed Escape for an urgent message (PG-58): the turn ends without a Stop hook (Claude Code fires none
    /// on an interrupt; Codex reports its `Interrupt` hook), so what the hooks said is no longer known and the screen
    /// decides; the urgent line itself waits for the empty prompt.
    pub fn interrupted(&mut self, now: Instant) -> LogEntry {
        self.interrupted_at = Some(now);
        self.interrupt_due = false;
        self.hold = None;
        self.offered = None;
        if self.tracker.state != State::Ended {
            self.tracker.state = State::Unknown;
        }
        self.quiet_since = now;
        let (_, entry) = self.line(false);
        LogEntry {
            kind: LineKind::Interrupt,
            ..entry
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RULE: &str = "────────────────────────────────────────";

    fn idle() -> Screen {
        Screen::from_tmux(
            &format!("● ready\n\n{RULE}\n❯ \n{RULE}\n  ? for shortcuts\n"),
            2,
            3,
            true,
            false,
        )
    }

    fn draft() -> Screen {
        Screen::from_tmux(
            &format!("● ready\n\n{RULE}\n❯ hi\n{RULE}\n\n"),
            4,
            3,
            true,
            false,
        )
    }

    fn dialog() -> Screen {
        Screen::from_tmux(
            " Do you want to proceed?\n ❯ 1. Yes\n   2. No\n",
            0,
            0,
            false,
            false,
        )
    }

    fn t(w: &mut Waker, at: Instant, s: &Screen) -> Action {
        w.decide(at, Some(s), 0, 1_000_000)
    }

    fn busy() -> Screen {
        Screen::from_tmux(
            &format!("✻ Working… (esc to interrupt)\n\n{RULE}\n❯ \n{RULE}\n  esc to interrupt\n"),
            2,
            3,
            true,
            false,
        )
    }

    fn urgent(id: &str) -> Fact {
        Fact::Urgent {
            contact: "Mac mini".into(),
            id: id.into(),
        }
    }

    /// PG-58: the owner's urgent message interrupts a running turn with one Escape, then the urgent line goes at the
    /// prompt (not through the Stop hook, which an interrupted turn does not run); an ordinary message in the same
    /// turn only waits for the Stop hook.
    #[test]
    fn an_urgent_message_interrupts_a_running_turn_and_a_normal_one_waits() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Prompt, t0);
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(
            t(&mut w, t0, &busy()),
            Action::Offer(AllowedLine::wake_from("Bob")),
            "a normal message waits for the turn's end"
        );
        w.on_fact(urgent("m1"));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(1), &busy()),
            Action::Interrupt(Key::Escape)
        );
        let e = w.interrupted(t0 + Duration::from_secs(1));
        assert_eq!(
            (e.kind, e.contact.as_deref()),
            (LineKind::Interrupt, Some("Mac mini"))
        );
        assert!(!w.offered(), "the continuation is taken back");
        assert_eq!(w.tracker.state, State::Unknown, "no hook follows an Escape");
        // Claude Code is back at its prompt: the urgent line after the quiet time, even within the ordinary rate limit
        let s = idle();
        assert_eq!(t(&mut w, t0 + Duration::from_secs(2), &s), Action::None);
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(8), &s),
            Action::Type(AllowedLine::urgent_from("Mac mini"))
        );
        assert_eq!(w.typed(t0 + Duration::from_secs(8)).kind, LineKind::Urgent);
        assert!(!w.pending(), "the urgent line covers the wake");
        // The same message again counts once; a second one within 30 s gets no second Escape
        w.on_fact(urgent("m1"));
        assert!(!w.pending());
        w.on_hook(HookEvent::Prompt, t0 + Duration::from_secs(9));
        w.on_fact(urgent("m2"));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(10), &busy()),
            Action::Offer(AllowedLine::urgent_from("Mac mini")),
            "held back by the rate: the Stop hook may carry it"
        );
        assert_eq!(w.hold, Some(Hold::Rate));
    }

    #[test]
    fn an_urgent_message_never_escapes_into_a_dialog_and_is_typed_at_an_idle_prompt() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Permission, t0);
        w.on_fact(urgent("m1"));
        assert_eq!(t(&mut w, t0, &dialog()), Action::None);
        assert_eq!(w.hold, Some(Hold::Dialog));
        // The person answered: the turn goes on, now it may be interrupted
        w.on_hook(HookEvent::ToolDone, t0 + Duration::from_secs(1));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(2), &busy()),
            Action::Interrupt(Key::Escape)
        );
        // Idle at the prompt: no Escape at all, the line after the quiet time
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Stop, t0);
        w.on_fact(urgent("m1"));
        assert_eq!(t(&mut w, t0, &idle()), Action::None);
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(6), &idle()),
            Action::Type(AllowedLine::urgent_from("Mac mini"))
        );
        // The switch off: nothing
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.set_on(false);
        w.on_fact(urgent("m1"));
        assert!(!w.pending());
    }

    #[test]
    fn a_wake_is_typed_once_after_quiet_and_coalesced_within_the_rate_limit() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Start, t0);
        let s = idle();
        assert_eq!(t(&mut w, t0, &s), Action::None, "nothing waits");
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(1), &s),
            Action::None,
            "the pane has not been quiet for 5 s"
        );
        let a = t(&mut w, t0 + Duration::from_secs(6), &s);
        assert_eq!(a, Action::Type(AllowedLine::wake_from("Bob")));
        let e = w.typed(t0 + Duration::from_secs(6));
        assert_eq!(
            (e.kind, e.contact.as_deref(), e.continued),
            (LineKind::Wake, Some("Bob"), false)
        );
        // two more contacts write within the 30 s: one line naming none, after the cooldown and quiet
        w.on_hook(HookEvent::Prompt, t0 + Duration::from_secs(7));
        w.on_hook(HookEvent::Stop, t0 + Duration::from_secs(9));
        w.on_fact(Fact::Message("Alice".into()));
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(20), &s),
            Action::None,
            "rate limit"
        );
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(37), &s),
            Action::Type(AllowedLine::wake_any())
        );
    }

    #[test]
    fn nothing_over_a_draft_a_dialog_a_busy_turn_or_a_persons_keys() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Stop, t0);
        w.on_fact(Fact::Message("Bob".into()));
        // idle by the hooks, but the screen shows a draft: never typed (the waker cannot see the person's keys)
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(10), &draft()),
            Action::None
        );
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(20), &draft()),
            Action::None
        );
        // a dialog
        w.on_hook(HookEvent::Permission, t0);
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(40), &dialog()),
            Action::None
        );
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(50), &idle()),
            Action::None,
            "the hooks say a dialog is open"
        );
        // a person pressed a key 2 s ago
        w.on_hook(HookEvent::Stop, t0);
        assert_eq!(
            w.decide(
                t0 + Duration::from_secs(60),
                Some(&idle()),
                999_998,
                1_000_000
            ),
            Action::None
        );
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(70), &idle()),
            Action::Type(AllowedLine::wake_from("Bob"))
        );
        // the session ended
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::End, t0);
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(10), &idle()),
            Action::None
        );
    }

    #[test]
    fn a_running_turn_gets_the_line_through_its_stop_hook_once() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Prompt, t0);
        w.on_fact(Fact::Message("Bob".into()));
        let s = idle();
        assert_eq!(
            t(&mut w, t0, &s),
            Action::Offer(AllowedLine::wake_from("Bob"))
        );
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(1), &s),
            Action::None,
            "left once"
        );
        // another contact writes: the continuation is replaced by the line naming none
        w.on_fact(Fact::Message("Alice".into()));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(2), &s),
            Action::Offer(AllowedLine::wake_any())
        );
        let e = w
            .on_hook(HookEvent::Continued, t0 + Duration::from_secs(3))
            .expect("the wake");
        assert!(e.continued && e.contact.is_none());
        assert!(!w.pending());
        // the turn stops; nothing more to type
        w.on_hook(HookEvent::Stop, t0 + Duration::from_secs(5));
        assert_eq!(t(&mut w, t0 + Duration::from_secs(40), &s), Action::None);
        // a line left for a Stop that did not take it (stop_hook_active): typed at the prompt after quiet
        w.on_hook(HookEvent::Prompt, t0 + Duration::from_secs(41));
        w.on_fact(Fact::Approved("r1".into()));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(42), &s),
            Action::Offer(AllowedLine::approved())
        );
        w.on_hook(HookEvent::Stop, t0 + Duration::from_secs(43));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(49), &s),
            Action::Type(AllowedLine::approved())
        );
        // the same approval again counts once
        w.typed(t0 + Duration::from_secs(49));
        w.on_fact(Fact::Approved("r1".into()));
        assert!(!w.pending());
    }

    /// PG-57: a request waiting for an approver has its own line, once per request; a message covers it (the
    /// inbox carries the facts too).
    #[test]
    fn a_request_to_answer_has_its_own_line_once() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_fact(Fact::ToAnswer("k2".into()));
        assert!(w.pending());
        assert_eq!(w.line(false).0, AllowedLine::to_answer());
        assert_eq!(w.line(false).1.kind, LineKind::ToAnswer);
        let _ = w.typed(t0);
        w.on_fact(Fact::ToAnswer("k2".into()));
        assert!(!w.pending(), "the same request does not wake twice");
        w.on_fact(Fact::ToAnswer("k3".into()));
        w.on_fact(Fact::Message("Mac mini".into()));
        assert_eq!(w.line(false).0, AllowedLine::wake_from("Mac mini"));
        assert_eq!(
            AllowedLine::to_answer().text(),
            "An approval request waits for your answer: read approvals_to_answer and answer it."
        );
    }

    #[test]
    fn an_answered_question_has_its_own_line_and_a_message_covers_it() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Stop, t0);
        w.on_fact(Fact::Answered("e1".into()));
        w.on_fact(Fact::Approved("r1".into()));
        assert_eq!(t(&mut w, t0, &idle()), Action::None);
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(6), &idle()),
            Action::Type(AllowedLine::answered())
        );
        assert_eq!(
            w.typed(t0 + Duration::from_secs(6)).kind,
            LineKind::Answered
        );
        // the same question again: once; with a message, the wake line covers it (the answer is in the inbox)
        w.on_fact(Fact::Answered("e1".into()));
        assert!(!w.pending());
        w.on_fact(Fact::Answered("e2".into()));
        w.on_fact(Fact::Message("Bob".into()));
        w.on_hook(HookEvent::Stop, t0 + Duration::from_secs(7));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(40), &idle()),
            Action::Type(AllowedLine::wake_from("Bob"))
        );
    }

    #[test]
    fn the_switch_clears_and_ignores() {
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Claude, Timing::default(), t0);
        w.on_hook(HookEvent::Prompt, t0);
        w.on_fact(Fact::Message("Bob".into()));
        assert!(matches!(t(&mut w, t0, &idle()), Action::Offer(_)));
        assert!(w.set_on(false), "the continuation must be taken back");
        w.on_fact(Fact::Message("Bob".into()));
        assert!(!w.pending());
        w.on_hook(HookEvent::Stop, t0);
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(10), &idle()),
            Action::None
        );
    }

    #[test]
    fn codex_with_hooks_is_continued_and_ignores_helper_threads() {
        let faint = |s: &str| format!("\x1b[2m{s}\x1b[0m");
        let idle = Screen::from_tmux(
            &format!(
                "• Ready.\n\n› {}\n\n  ? for shortcuts\n",
                faint("Ask Codex to do anything")
            ),
            2,
            2,
            true,
            false,
        );
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Codex, Timing::default(), t0);
        w.on_hook(HookEvent::Start, t0);
        w.on_hook(HookEvent::Prompt, t0);
        // the title thread's notify while the person's turn runs: still working
        w.on_hook(HookEvent::TurnComplete, t0);
        assert_eq!(w.tracker.state, State::Working);
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(
            t(&mut w, t0, &idle),
            Action::Offer(AllowedLine::wake_from("Bob"))
        );
        assert!(w.on_hook(HookEvent::Continued, t0).is_some());
        // Esc: back at the prompt
        w.on_hook(HookEvent::Interrupt, t0);
        assert_eq!(w.tracker.state, State::Idle);
    }

    #[test]
    fn codex_waits_for_notify_and_its_idle_composer() {
        let faint = |s: &str| format!("\x1b[2m{s}\x1b[0m");
        let idle = Screen::from_tmux(
            &format!(
                "• Ready.\n\n› {}\n\n  ⏎ send   ? for shortcuts\n",
                faint("Ask Codex to do anything")
            ),
            2,
            2,
            true,
            false,
        );
        let t0 = Instant::now();
        let mut w = Waker::new(Cli::Codex, Timing::default(), t0);
        // an earlier turn completed: this Codex runs its notify program
        w.on_hook(HookEvent::TurnComplete, t0);
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(t(&mut w, t0, &idle), Action::None, "not quiet yet");
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(6), &idle),
            Action::Type(AllowedLine::wake_from("Bob"))
        );
        w.typed(t0 + Duration::from_secs(6));
        // working until notify (the screen may still look idle for a moment); never a continuation for Codex
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(t(&mut w, t0 + Duration::from_secs(40), &idle), Action::None);
        w.on_hook(HookEvent::TurnComplete, t0 + Duration::from_secs(41));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(47), &idle),
            Action::Type(AllowedLine::wake_from("Bob"))
        );
        // a Codex that never ran notify (the person's config overrides it): after a typed line, the screen decides
        // again after 20 s
        let mut w = Waker::new(Cli::Codex, Timing::default(), t0);
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(t(&mut w, t0, &idle), Action::None);
        assert!(matches!(
            t(&mut w, t0 + Duration::from_secs(6), &idle),
            Action::Type(_)
        ));
        w.typed(t0 + Duration::from_secs(6));
        w.on_fact(Fact::Message("Bob".into()));
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(20), &idle),
            Action::None,
            "rate limit, and working"
        );
        assert_eq!(
            t(&mut w, t0 + Duration::from_secs(37), &idle),
            Action::Type(AllowedLine::wake_from("Bob"))
        );
    }
}
