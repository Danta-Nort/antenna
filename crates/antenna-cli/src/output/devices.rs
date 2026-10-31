// SPDX-License-Identifier: AGPL-3.0-only
//! My devices (x-control/7, CONTROL §27) for humans. What another computer said about itself is its word: every
//! string is escaped like everything in `output`.

use antenna_proto::control::{
    AgentConnected, AgentTraffic, DeviceDecided, DeviceInfo, DevicesReply, other_side,
};

use super::clean;

fn ago(at_ms: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let s = now.saturating_sub(at_ms) / 1000;
    match s {
        0..=59 => "just now".into(),
        60..=7199 => format!("{} min ago", s / 60),
        _ => format!("{} h ago", s / 3600),
    }
}

fn keys(k: &[antenna_proto::control::DeviceKeyInfo]) -> String {
    k.iter()
        .map(|k| format!("{} ({}, {})", k.key_id, clean(&k.kind), clean(&k.label)))
        .collect::<Vec<_>>()
        .join(", ")
}

fn device(d: &DeviceInfo) {
    outln!(
        "{}  {}{}",
        clean(&d.contact),
        d.presence,
        d.received_ms
            .map(|t| format!(", told this computer {}", ago(t)))
            .unwrap_or_default()
    );
    if !d.supported && d.status.is_none() {
        outln!("  its Antenna does not report itself yet (update it there)");
    }
    if let Some(r) = &d.lost_by {
        outln!(
            "  REPORTED LOST by {} ({}): its keys are no longer accepted here; `antenna devices revoke {}` ends the link",
            clean(&r.contact),
            ago(r.at_ms),
            clean(&d.contact)
        );
    }
    if let Some(s) = &d.status {
        outln!(
            "  {} · {} {} {} · {}",
            clean(&s.name),
            clean(&s.os),
            clean(&s.os_version),
            clean(&s.arch),
            clean(&s.version)
        );
        let u = &s.update;
        let mut line = format!("  updates by itself: {}", if u.auto { "on" } else { "off" });
        if let Some(v) = &u.staged {
            line += &format!(
                "; {} ready ({})",
                clean(v),
                clean(u.staged_state.as_deref().unwrap_or(""))
            );
        }
        if let (Some(v), Some(r)) = (&u.last, &u.last_result) {
            line += &format!("; last: {} {}", clean(r), clean(v));
        }
        outln!("{line}");
        if s.health.is_empty() {
            outln!("  health: no problems it can see");
        }
        for h in &s.health {
            outln!(
                "  health: {} {}{}",
                clean(&h.severity),
                clean(&h.code),
                h.count.map(|c| format!(" ({c})")).unwrap_or_default()
            );
        }
        for a in &s.agents {
            outln!(
                "  agent {} — {}{}{}{}",
                clean(&a.name),
                clean(&a.state),
                a.app
                    .as_deref()
                    .map(|x| format!(" ({})", clean(x)))
                    .unwrap_or_default(),
                match a.counterpart.as_deref() {
                    Some("") => " · connected to you".to_string(),
                    Some(c) => format!(" · connected to your {}", clean(c)),
                    None => String::new(),
                },
                if a.takes_tasks {
                    " · takes your tasks"
                } else {
                    ""
                }
            );
        }
        if s.lend {
            outln!("  lends itself to your teams");
        }
        if s.pending_approvals > 0 {
            outln!("  approval requests: {}", s.pending_approvals);
        }
        for a in &s.approvals {
            // Its clock, not ours: the time left when it sent the status, less the time since this computer got it
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            let since = d.received_ms.map_or(0, |r| now.saturating_sub(r));
            let left = a.expires_ms.saturating_sub(s.at_ms).saturating_sub(since) / 1000;
            outln!(
                "    {}  {} by {} for {}{}  [{}]  expires in {}m{:02}s",
                a.id,
                clean(&a.action),
                clean(&a.requester),
                clean(&a.contact),
                a.target
                    .as_deref()
                    .map(|t| format!(" → {}", clean(t)))
                    .unwrap_or_default(),
                a.reasons
                    .iter()
                    .map(|r| clean(r))
                    .collect::<Vec<_>>()
                    .join(", "),
                left / 60,
                left % 60
            );
            if a.quote_withheld {
                outln!("      (text withheld: it contains a secret; read it on that computer)");
            } else if !a.quote.is_empty() {
                outln!("      > {}", clean(&a.quote.replace('\n', " ")));
            }
        }
    }
    if !d.confirmed.is_empty() {
        outln!("  approvals from it accepted with: {}", keys(&d.confirmed));
    }
    if !d.offered.is_empty() {
        outln!(
            "  offers keys not confirmed here: {} (`antenna devices confirm {}`)",
            keys(&d.offered),
            clean(&d.contact)
        );
    }
}

/// `devices`.
pub(super) fn devices(r: &DevicesReply) {
    let t = &r.this;
    outln!(
        "this computer: {} · {} {} {} · {}{}",
        clean(&t.name),
        clean(&t.os),
        clean(&t.os_version),
        clean(&t.arch),
        clean(&t.version),
        if t.lend { " · lent to your teams" } else { "" }
    );
    for l in &t.lost {
        outln!(
            "  revoked as lost: {} ({}); your other computers are told",
            clean(&l.contact),
            ago(l.at_ms)
        );
    }
    if r.devices.is_empty() {
        outln!("no other own computers: pair one with \"This is my own computer (∞)\" (trust 5)");
    }
    for d in &r.devices {
        device(d);
    }
}

/// `devices approve` / `devices deny`.
pub(super) fn decided(d: &DeviceDecided) {
    outln!(
        "{}: request {} {}",
        clean(&d.contact),
        d.id,
        clean(&d.state)
    );
}

/// `agent connect` / `agent disconnect`: this side as it is now, then the other side.
pub(super) fn connected(c: &AgentConnected) {
    let s = &c.agent.session;
    match &s.counterpart {
        Some(cp) => outln!(
            "{}: messages without an address go to {}",
            clean(&s.agent),
            super::counterpart_text(cp)
        ),
        None => outln!("{}: no default counterpart", clean(&s.agent)),
    }
    if s.tasks_from.is_empty() {
        outln!("  takes no tasks (every message is data)");
    } else {
        outln!("  takes tasks from {}", clean(&s.tasks_from.join(", ")));
    }
    for r in &s.local_routes {
        outln!(
            "  connected on this computer with {}: its messages are {}",
            clean(&r.agent),
            if r.tasks { "tasks" } else { "data" }
        );
    }
    let o = &c.other_side;
    let words = match o.state.as_str() {
        other_side::LOCAL => "other side: on this computer, set too".into(),
        other_side::REQUESTED => format!(
            "other side: an approval request there ({}): approve it there, or here with `antenna devices approve`",
            clean(o.id.as_deref().unwrap_or("?"))
        ),
        other_side::UNCHANGED => "other side: already so there".into(),
        other_side::CONTACT_DECIDES => {
            "other side: the contact's decision; nothing changed on their computer".into()
        }
        other_side::PERSON => "other side: a person, nothing to set there".into(),
        other_side::NOT_ASKED => "other side: not asked".into(),
        other_side::UNSUPPORTED => {
            "other side: that computer's Antenna does not know connections yet; update it".into()
        }
        other_side::UNREACHABLE | other_side::REFUSED => format!(
            "other side: {} ({})",
            clean(&o.state),
            clean(o.message.as_deref().unwrap_or(""))
        ),
        other => format!("other side: {}", clean(other)),
    };
    outln!("  {words}");
}

/// `agent traffic`.
pub(super) fn traffic(t: &AgentTraffic) {
    if t.pairs.is_empty() {
        outln!("no messages in the period");
    }
    for p in &t.pairs {
        if p.local {
            outln!(
                "{} ↔ {} on this computer: {} and {} messages, last {}",
                clean(&p.agent),
                clean(&p.peer_agent),
                p.sent,
                p.received,
                super::ago(p.last_ms)
            );
            continue;
        }
        outln!(
            "{} ↔ {} at {}: {} sent, {} received, last {}",
            if p.agent.is_empty() {
                "you".to_string()
            } else {
                clean(&p.agent)
            },
            if p.peer_agent.is_empty() {
                "the person".to_string()
            } else {
                clean(&p.peer_agent)
            },
            clean(&p.contact),
            p.sent,
            p.received,
            ago(p.last_ms)
        );
    }
}
