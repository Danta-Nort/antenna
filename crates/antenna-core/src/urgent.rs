// SPDX-License-Identifier: AGPL-3.0-only
//! The owner's urgent message (PG-58, D-133; experimental): "interrupt now" instead of waiting for the agent's turn to
//! end.
//!
//! The flag travels in the signed `core` of a text message (`docs/PROTOCOL.md` §23, `urgent/0`), so the author's
//! signature covers it. Whether this node honours it is decided here, by the recipient, from what it can check itself;
//! the sender's word is never enough: a contact whose node says "urgent" is just as able to say it as the owner's own
//! computer. Honoured means: the contact is at level 5 here (the owner's own computer, D-99), the message is the
//! owner's own (signed by the side's link-root, not by one of its agents), it is addressed to one agent, it arrived
//! as a new message (not history sent again) and it is fresh by its own clock. And at most one honoured message per
//! agent per [`EVERY`]: an interrupt storm from a compromised or buggy own computer costs one interrupt per 30 s.
//! Anything else is delivered as a normal message and waits for the agent to be idle, as before; the refusal is in the
//! link's audit log.

use std::{
    collections::HashMap,
    sync::{Mutex, PoisonError},
    time::{Duration, Instant},
};

/// An urgent flag older than this by the sender's clock is a normal message: the owner wrote "interrupt now", not
/// "interrupt whenever this arrives" (a computer that slept, a message held in a queue).
pub(crate) const FRESH_MS: u64 = 10 * 60_000;
/// A flag dated further ahead than this (a clock that runs fast, or a made-up time) is not honoured either.
pub(crate) const AHEAD_MS: u64 = 2 * 60_000;
/// At most one honoured urgent message per agent in this time.
pub(crate) const EVERY: Duration = Duration::from_secs(30);

/// Why an urgent flag was not honoured (the reason in the audit log).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refused {
    /// The contact is below level 5 here: not the owner's own computer.
    Level(u8),
    /// One of the contact's agents signed it, not its owner.
    NotOwner,
    /// Not new: history sent again during verification.
    NotLive,
    /// Older than [`FRESH_MS`] by its own clock.
    Stale,
    /// Dated more than [`AHEAD_MS`] ahead.
    Ahead,
    /// The agent was interrupted less than [`EVERY`] ago.
    Rate,
}

impl Refused {
    /// The reason as the audit log writes it.
    pub(crate) fn reason(self) -> String {
        match self {
            Refused::Level(l) => format!("level_{l}: urgent only from an own computer at level 5"),
            Refused::NotOwner => "not_owner: urgent only from the owner, not an agent".into(),
            Refused::NotLive => "not_live: history sent again".into(),
            Refused::Stale => "stale: older than 10 minutes".into(),
            Refused::Ahead => "ahead: dated in the future".into(),
            Refused::Rate => "rate: one interrupt per agent per 30 s".into(),
        }
    }
}

/// What the recipient knows about an incoming message with the urgent flag.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Incoming {
    /// This node's trust level for the contact, now.
    pub trust: u8,
    /// The side's link-root signed it (its owner), not one of its agents.
    pub by_owner: bool,
    /// It arrived as a new message (`deliver`), not in a `resend`.
    pub live: bool,
    /// Its own time (`core.ts`, the sender's clock).
    pub ts: u64,
    /// This node's clock.
    pub now: u64,
}

/// The rule without the rate limit (unit-tested on its own).
pub(crate) fn judge(m: Incoming) -> Result<(), Refused> {
    if m.trust < 5 {
        return Err(Refused::Level(m.trust));
    }
    if !m.by_owner {
        return Err(Refused::NotOwner);
    }
    if !m.live {
        return Err(Refused::NotLive);
    }
    if m.ts.saturating_add(FRESH_MS) < m.now {
        return Err(Refused::Stale);
    }
    if m.ts > m.now.saturating_add(AHEAD_MS) {
        return Err(Refused::Ahead);
    }
    Ok(())
}

/// The per-agent rate limit, one for the whole node (an agent may read several links).
#[derive(Debug, Default)]
pub(crate) struct Gate {
    last: Mutex<HashMap<String, Instant>>,
}

impl Gate {
    /// Whether an urgent message for `agent` may be honoured now; if so, the window starts again.
    pub(crate) fn admit(&self, agent: &str, now: Instant) -> bool {
        let mut g = self.last.lock().unwrap_or_else(PoisonError::into_inner);
        if g.get(agent)
            .is_some_and(|t| now.saturating_duration_since(*t) < EVERY)
        {
            return false;
        }
        if g.len() > 1024 {
            g.retain(|_, t| now.saturating_duration_since(*t) < EVERY);
        }
        g.insert(agent.to_string(), now);
        true
    }
}

/// The whole decision: the rule, then the rate limit.
pub(crate) fn decide(gate: &Gate, agent: &str, m: Incoming) -> Result<(), Refused> {
    judge(m)?;
    if !gate.admit(agent, Instant::now()) {
        return Err(Refused::Rate);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok() -> Incoming {
        Incoming {
            trust: 5,
            by_owner: true,
            live: true,
            ts: 1_000_000_000,
            now: 1_000_000_000,
        }
    }

    #[test]
    fn only_the_owners_fresh_live_message_from_an_own_computer_counts() {
        assert_eq!(judge(ok()), Ok(()));
        for l in 0..5 {
            assert_eq!(judge(Incoming { trust: l, ..ok() }), Err(Refused::Level(l)));
        }
        assert_eq!(
            judge(Incoming {
                by_owner: false,
                ..ok()
            }),
            Err(Refused::NotOwner)
        );
        assert_eq!(
            judge(Incoming {
                live: false,
                ..ok()
            }),
            Err(Refused::NotLive)
        );
        let now = ok().now;
        assert_eq!(
            judge(Incoming {
                ts: now - FRESH_MS,
                ..ok()
            }),
            Ok(())
        );
        assert_eq!(
            judge(Incoming {
                ts: now - FRESH_MS - 1,
                ..ok()
            }),
            Err(Refused::Stale)
        );
        assert_eq!(
            judge(Incoming {
                ts: now + AHEAD_MS + 1,
                ..ok()
            }),
            Err(Refused::Ahead)
        );
        assert!(Refused::Level(3).reason().starts_with("level_3"));
    }

    #[test]
    fn one_interrupt_per_agent_per_30_seconds() {
        let g = Gate::default();
        let t0 = Instant::now();
        assert!(g.admit("helper", t0));
        assert!(!g.admit("helper", t0 + Duration::from_secs(29)));
        assert!(g.admit("other", t0 + Duration::from_secs(1)), "per agent");
        assert!(g.admit("helper", t0 + Duration::from_secs(31)));
        assert_eq!(
            decide(&g, "x", Incoming { trust: 3, ..ok() }),
            Err(Refused::Level(3))
        );
        // A refused message does not use up the window
        assert_eq!(decide(&g, "x", ok()), Ok(()));
        assert_eq!(decide(&g, "x", ok()), Err(Refused::Rate));
    }
}
