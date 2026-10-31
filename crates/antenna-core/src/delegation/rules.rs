// SPDX-License-Identifier: AGPL-3.0-only
//! The rules of a delegated answer (PG-57), as pure functions over facts the session gathers: whether an approver may
//! answer a request at all (its scope, itself, chains) and whether the request stays inside the level-5 circle at the
//! moment of the answer. Nothing here reads the database or the clock, so every refusal is unit-tested.

use antenna_proto::{
    LinkId,
    control::{DELEGABLE_KINDS, why},
};

/// The level of an own computer (D-99): the only level a delegated answer works at.
pub const CIRCLE: u8 = 5;

/// What a delegated answer is about, from the approval request.
#[derive(Debug, Clone)]
pub struct Request<'a> {
    /// The requester's agent ID on this computer; `None`: the owner or another computer asked.
    pub requester: Option<i64>,
    /// Its action.
    pub action: &'a str,
    /// The contact whose data or request it is about, and its level when the request was made.
    pub contact: (LinkId, u8),
    /// The recipient's link, for a send.
    pub target: Option<LinkId>,
    /// When it was made (this computer's clock).
    pub created_ms: u64,
    /// The links the requester's session read, with the level each had when it read them.
    pub requester_read: Vec<(LinkId, u8)>,
}

/// Who answers.
#[derive(Debug, Clone)]
pub struct Answerer {
    /// Its agent ID on this computer; `None` for an approver on another computer.
    pub local: Option<i64>,
    /// For an approver on another computer: that computer's link.
    pub device: Option<LinkId>,
    /// The links its session read, with the level each had when it read them (an approver on another computer: that
    /// computer's word that there is none below 5 travels in its answer and is checked before).
    pub read: Vec<(LinkId, u8)>,
}

/// The scope the owner set.
#[derive(Debug, Clone)]
pub struct Scope<'a> {
    /// Whose requests: agent IDs of this computer; `None`: all.
    pub agents: Option<&'a [i64]>,
    /// Which kinds; `None`: all of [`DELEGABLE_KINDS`].
    pub kinds: Option<&'a [String]>,
}

/// Why an answer does not count: one of [`why`], in words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    /// Machine-readable.
    pub why: &'static str,
    /// For the approver and the owner.
    pub message: String,
}

fn no(why: &'static str, message: impl Into<String>) -> Refusal {
    Refusal {
        why,
        message: message.into(),
    }
}

/// Whether the approver may answer this request at all: an agent's request (not the owner's, not another computer's),
/// not its own, not an approver's (no chains), of an agent and a kind within the scope. `is_approver` says whether an
/// agent of this computer is an approver itself (here or for another own computer).
pub fn in_scope(
    req: &Request<'_>,
    by: &Answerer,
    scope: &Scope<'_>,
    is_approver: impl Fn(i64) -> bool,
) -> Result<(), Refusal> {
    let Some(requester) = req.requester else {
        return Err(no(
            why::SCOPE,
            "only the owner answers this request: it is not an agent's request of this computer",
        ));
    };
    if by.local == Some(requester) {
        return Err(no(
            why::SELF,
            "an approver never answers its own requests: the owner answers this one",
        ));
    }
    if is_approver(requester) {
        return Err(no(
            why::CHAIN,
            "the agent that asked is an approver itself: its requests go to the owner",
        ));
    }
    if scope.agents.is_some_and(|a| !a.contains(&requester)) {
        return Err(no(
            why::SCOPE,
            "the owner did not make this approver answer that agent's requests",
        ));
    }
    if !DELEGABLE_KINDS.contains(&req.action) {
        return Err(no(
            why::SCOPE,
            format!("only the owner answers a request of kind {}", req.action),
        ));
    }
    if scope
        .kinds
        .is_some_and(|k| !k.iter().any(|x| x == req.action))
    {
        return Err(no(
            why::SCOPE,
            format!(
                "the owner did not make this approver answer requests of kind {}",
                req.action
            ),
        ));
    }
    Ok(())
}

/// Whether everything the request touches stays among this computer and contacts at level 5 now: the contact it is
/// about (then and now), the recipient, every link the requester's session read (then and now), the approver's own
/// session (then and now) and, for an approver on another computer, that computer's link; and that none of these links
/// changed its level after the request was made. `level` is a link's level now (`None`: no such link);
/// `changed_ms` when its level last changed in this daemon's life.
pub fn in_circle(
    req: &Request<'_>,
    by: &Answerer,
    level: impl Fn(&LinkId) -> Option<u8>,
    changed_ms: impl Fn(&LinkId) -> Option<u64>,
    name: impl Fn(&LinkId) -> String,
) -> Result<(), Refusal> {
    let at5 = |l: &LinkId| level(l) == Some(CIRCLE);
    // The approver first: a prompt injection reaches it through what it read
    if let Some((l, at)) = by.read.iter().find(|(l, at)| *at < CIRCLE || !at5(l)) {
        return Err(no(
            why::TAINTED,
            format!(
                "the approver's session read data of {} (level {}): an injected text could make it approve, so the \
                 owner answers; the owner can start a clean session for it",
                name(l),
                level(l).unwrap_or(*at).min(*at)
            ),
        ));
    }
    if let Some(d) = &by.device
        && !at5(d)
    {
        return Err(no(
            why::OUTSIDE,
            format!(
                "{} is not at ∞ (level 5) here: only an own computer's agent answers",
                name(d)
            ),
        ));
    }
    let (contact, then) = req.contact;
    if then < CIRCLE || !at5(&contact) {
        return Err(no(
            why::OUTSIDE,
            format!(
                "the request is about {}, which is not at ∞ (level 5): the owner answers",
                name(&contact)
            ),
        ));
    }
    if let Some(t) = &req.target
        && !at5(t)
    {
        return Err(no(
            why::OUTSIDE,
            format!(
                "the request sends to {}, which is not at ∞ (level 5): the owner answers",
                name(t)
            ),
        ));
    }
    if let Some((l, _)) = req
        .requester_read
        .iter()
        .find(|(l, at)| *at < CIRCLE || !at5(l))
    {
        return Err(no(
            why::OUTSIDE,
            format!(
                "the agent that asked read data of {}, which is not at ∞ (level 5): the owner answers",
                name(l)
            ),
        ));
    }
    let touched = std::iter::once(contact)
        .chain(req.target)
        .chain(req.requester_read.iter().map(|(l, _)| *l))
        .chain(by.read.iter().map(|(l, _)| *l))
        .chain(by.device);
    for l in touched {
        if changed_ms(&l).is_some_and(|t| t >= req.created_ms) {
            return Err(no(
                why::LEVEL_CHANGED,
                format!(
                    "the level of {} changed after the request was made: the owner answers",
                    name(&l)
                ),
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAC: LinkId = LinkId([1; 32]);
    const SRV: LinkId = LinkId([2; 32]);
    const BOB: LinkId = LinkId([3; 32]);
    const LAP: LinkId = LinkId([4; 32]);

    fn req() -> Request<'static> {
        Request {
            requester: Some(10),
            action: "send_message",
            contact: (MAC, 5),
            target: Some(SRV),
            created_ms: 100,
            requester_read: vec![(MAC, 5)],
        }
    }

    fn local(id: i64) -> Answerer {
        Answerer {
            local: Some(id),
            device: None,
            read: vec![],
        }
    }

    fn levels(l: &LinkId) -> Option<u8> {
        match l {
            l if *l == BOB => Some(3),
            l if [MAC, SRV, LAP].contains(l) => Some(5),
            _ => None,
        }
    }

    fn label(l: &LinkId) -> String {
        format!("link{}", l.0[0])
    }

    fn circle(r: &Request<'_>, by: &Answerer) -> Result<(), Refusal> {
        in_circle(r, by, levels, |_| None, label)
    }

    #[test]
    fn the_scope_the_owner_set() {
        let all = Scope {
            agents: None,
            kinds: None,
        };
        let never = |_| false;
        assert_eq!(in_scope(&req(), &local(20), &all, never), Ok(()));
        let w = |r: Result<(), Refusal>| r.unwrap_err().why;
        assert_eq!(w(in_scope(&req(), &local(10), &all, never)), why::SELF);
        assert_eq!(
            w(in_scope(&req(), &local(20), &all, |id| id == 10)),
            why::CHAIN
        );
        let owner = Request {
            requester: None,
            ..req()
        };
        assert_eq!(w(in_scope(&owner, &local(20), &all, never)), why::SCOPE);
        let others = [11];
        let some = Scope {
            agents: Some(&others),
            kinds: None,
        };
        assert_eq!(w(in_scope(&req(), &local(20), &some, never)), why::SCOPE);
        let files = ["share_file".to_string()];
        let kinds = Scope {
            agents: None,
            kinds: Some(&files),
        };
        assert_eq!(w(in_scope(&req(), &local(20), &kinds, never)), why::SCOPE);
        for action in [
            "check:exec",
            "check:write",
            "connect_agent",
            "disconnect_agent",
        ] {
            let r = Request { action, ..req() };
            assert_eq!(
                w(in_scope(&r, &local(20), &all, never)),
                why::SCOPE,
                "{action}"
            );
        }
    }

    #[test]
    fn the_level_5_circle_now() {
        assert_eq!(circle(&req(), &local(20)), Ok(()));
        let w = |r: Result<(), Refusal>| r.unwrap_err().why;
        // The contact, then or now
        let r = Request {
            contact: (BOB, 3),
            ..req()
        };
        assert_eq!(w(circle(&r, &local(20))), why::OUTSIDE);
        let r = Request {
            contact: (MAC, 4),
            ..req()
        };
        assert_eq!(w(circle(&r, &local(20))), why::OUTSIDE, "lower when asked");
        // The recipient
        let r = Request {
            target: Some(BOB),
            ..req()
        };
        assert_eq!(w(circle(&r, &local(20))), why::OUTSIDE);
        let gone = LinkId([9; 32]);
        let r = Request {
            target: Some(gone),
            ..req()
        };
        assert_eq!(w(circle(&r, &local(20))), why::OUTSIDE, "a revoked link");
        // What the requester read
        let r = Request {
            requester_read: vec![(MAC, 5), (BOB, 3)],
            ..req()
        };
        assert_eq!(w(circle(&r, &local(20))), why::OUTSIDE);
        let r = Request {
            requester_read: vec![(LAP, 4)],
            ..req()
        };
        assert_eq!(
            w(circle(&r, &local(20))),
            why::OUTSIDE,
            "read while lower, raised since"
        );
        // The approver's own session
        let tainted = Answerer {
            read: vec![(BOB, 3)],
            ..local(20)
        };
        let e = circle(&req(), &tainted).unwrap_err();
        assert_eq!(e.why, why::TAINTED);
        assert!(e.message.contains("link3 (level 3)"), "{}", e.message);
        let clean = Answerer {
            read: vec![(LAP, 5), (MAC, 5)],
            ..local(20)
        };
        assert_eq!(circle(&req(), &clean), Ok(()));
        // Another computer's approver: its link at 5 here
        let remote = Answerer {
            local: None,
            device: Some(LAP),
            read: vec![],
        };
        assert_eq!(circle(&req(), &remote), Ok(()));
        let remote_low = Answerer {
            device: Some(BOB),
            ..remote
        };
        assert_eq!(w(circle(&req(), &remote_low)), why::OUTSIDE);
    }

    #[test]
    fn a_level_changed_since_the_request_was_made() {
        let changed = |at: u64| move |l: &LinkId| (*l == SRV).then_some(at);
        assert_eq!(
            in_circle(&req(), &local(20), levels, changed(99), label),
            Ok(()),
            "changed before the request"
        );
        assert_eq!(
            in_circle(&req(), &local(20), levels, changed(100), label)
                .unwrap_err()
                .why,
            why::LEVEL_CHANGED,
            "lowered and raised back after it"
        );
        let remote = Answerer {
            local: None,
            device: Some(LAP),
            read: vec![],
        };
        let lap = |l: &LinkId| (*l == LAP).then_some(500);
        assert_eq!(
            in_circle(&req(), &remote, levels, lap, label)
                .unwrap_err()
                .why,
            why::LEVEL_CHANGED
        );
    }
}
