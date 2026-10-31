// SPDX-License-Identifier: AGPL-3.0-only
//! What may go into an agent's terminal besides an [`super::lines::AllowedLine`], and when: one place for the rules of
//! a key (PG-58; what lets a person or another own computer answer an agent's terminal builds on it, PG-59).
//!
//! The only key is [`Key::Escape`]: Claude Code documents it as "Interrupt Claude, or close a dialog" and "On a
//! permission prompt, Esc declines the action"; Codex shows "esc to interrupt" while it works, and its `Interrupt`
//! hook runs when a turn is interrupted. So Escape goes only where it can do nothing but interrupt:
//! - the CLI's own screen says a turn runs ("esc to interrupt") and does not show its empty prompt;
//! - no dialog: neither the hooks nor the screen (a numbered choice) say one is open, since Escape would answer it;
//! - no draft in the input, which is the person's;
//! - tmux is not in one of its own modes, and no person attached to the session pressed a key in the last seconds
//!   (their Escape and ours could make a double Escape, which opens Claude Code's rewind menu);
//! - and at most one per [`EVERY`] (the caller's clock).
//!
//! Anything else holds the key back with the reason ([`Hold`]); text then waits for the empty prompt like any line.

use std::time::Duration;

use super::{
    screen::{Screen, busy_hint, claude_ready, codex_ready, input_draft, is_choice_on},
    waker::{Cli, State, Tracker},
};

/// At most one interrupt per session in this time.
pub(crate) const EVERY: Duration = Duration::from_secs(30);

/// A key the waker may press, by its tmux name (never literal text).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Key {
    /// Interrupt the turn in progress (Claude Code, Codex).
    Escape,
}

impl Key {
    /// The key's name for `tmux send-keys`.
    pub fn tmux_name(self) -> &'static str {
        match self {
            Key::Escape => "Escape",
        }
    }
}

/// Why a key is held back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Hold {
    /// No turn runs: nothing to interrupt (the line is typed at the prompt instead).
    NotBusy,
    /// A dialog is open: Escape would answer it.
    Dialog,
    /// The person's draft is in the input.
    Draft,
    /// A person attached to the session pressed a key a moment ago.
    Person,
    /// tmux is in one of its own modes.
    Mode,
    /// An interrupt was sent less than [`EVERY`] ago.
    Rate,
}

impl Hold {
    /// The word in the session's status.
    pub fn word(self) -> &'static str {
        match self {
            Hold::NotBusy => "not_busy",
            Hold::Dialog => "dialog",
            Hold::Draft => "draft",
            Hold::Person => "person",
            Hold::Mode => "mode",
            Hold::Rate => "rate",
        }
    }
}

/// Whether one Escape may interrupt the agent's turn now (see the module comment). `person_quiet`: no key from an
/// attached person for the quiet time; `since_last`: the time since the last interrupt, if any.
pub(crate) fn may_interrupt(
    t: &Tracker,
    s: &Screen,
    person_quiet: bool,
    since_last: Option<Duration>,
) -> Result<Key, Hold> {
    if s.in_mode {
        return Err(Hold::Mode);
    }
    if !person_quiet {
        return Err(Hold::Person);
    }
    if t.state == State::Dialog || is_choice_on(s) {
        return Err(Hold::Dialog);
    }
    let ready = match t.cli {
        Cli::Claude => claude_ready(s),
        Cli::Codex => codex_ready(s),
    };
    if t.state == State::Ended || ready || !busy_hint(s) {
        return Err(Hold::NotBusy);
    }
    if input_draft(s) {
        return Err(Hold::Draft);
    }
    if since_last.is_some_and(|d| d < EVERY) {
        return Err(Hold::Rate);
    }
    Ok(Key::Escape)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::hooks::HookEvent;

    const RULE: &str = "────────────────────────────────────────";

    fn busy(input: &str) -> Screen {
        Screen::from_tmux(
            &format!(
                "✻ Working… (esc to interrupt)\n\n{RULE}\n❯ {input}\n{RULE}\n  esc to interrupt\n"
            ),
            2 + input.chars().count(),
            3,
            true,
            false,
        )
    }

    fn idle() -> Screen {
        Screen::from_tmux(
            &format!("● ready\n\n{RULE}\n❯ \n{RULE}\n  ? for shortcuts\n"),
            2,
            3,
            true,
            false,
        )
    }

    fn dialog() -> Screen {
        Screen::from_tmux(
            " Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel · esc to interrupt",
            0,
            0,
            false,
            false,
        )
    }

    fn working() -> Tracker {
        let mut t = Tracker::new(Cli::Claude);
        t.on_hook(HookEvent::Prompt);
        t
    }

    #[test]
    fn escape_only_into_a_running_turn() {
        assert_eq!(
            may_interrupt(&working(), &busy(""), true, None),
            Ok(Key::Escape)
        );
        // Without hooks the screen alone decides
        assert_eq!(
            may_interrupt(&Tracker::new(Cli::Claude), &busy(""), true, None),
            Ok(Key::Escape)
        );
        assert_eq!(
            may_interrupt(&working(), &idle(), true, None),
            Err(Hold::NotBusy),
            "the hooks may be stale: the empty prompt wins"
        );
        assert_eq!(Key::Escape.tmux_name(), "Escape");
    }

    #[test]
    fn never_into_a_dialog_a_draft_a_mode_or_a_persons_keys() {
        assert_eq!(
            may_interrupt(&working(), &dialog(), true, None),
            Err(Hold::Dialog)
        );
        let mut t = working();
        t.on_hook(HookEvent::Permission);
        assert_eq!(may_interrupt(&t, &busy(""), true, None), Err(Hold::Dialog));
        assert_eq!(
            may_interrupt(&working(), &busy("fix the tests"), true, None),
            Err(Hold::Draft)
        );
        assert_eq!(
            may_interrupt(&working(), &busy(""), false, None),
            Err(Hold::Person)
        );
        let mut m = busy("");
        m.in_mode = true;
        assert_eq!(may_interrupt(&working(), &m, true, None), Err(Hold::Mode));
        assert_eq!(
            may_interrupt(&working(), &busy(""), true, Some(Duration::from_secs(29))),
            Err(Hold::Rate)
        );
        assert_eq!(
            may_interrupt(&working(), &busy(""), true, Some(Duration::from_secs(31))),
            Ok(Key::Escape)
        );
    }
}
