// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna chats` for humans (CONTROL §26): one line per chat.

use antenna_proto::control::{ChatInfo, ChatsReply};

use super::{ago, clean};

/// `chats`.
pub(super) fn chats(r: &ChatsReply) {
    if r.chats.is_empty() {
        outln!("no contacts yet: `antenna invite` or `antenna join <link>`");
    }
    for c in &r.chats {
        outln!("{}", line(c));
    }
}

/// `chat_set`.
pub(super) fn chat(c: &ChatInfo) {
    outln!("{}", line(c));
}

/// `bob · lead "Payments API"  2 unread  14 messages, last 3 min ago  notify asks  archived`.
pub(super) fn line(c: &ChatInfo) -> String {
    let who = match &c.agent {
        Some(a) => format!("{} · {}", clean(&c.contact), clean(a)),
        None => format!("{} (person)", clean(&c.contact)),
    };
    let mut out = format!("{who:<28}");
    if let Some(n) = &c.name {
        out += &format!(" \"{}\"", clean(n));
    }
    if c.unread > 0 {
        out += &format!("  {} unread", c.unread);
    }
    out += &match c.last_ms {
        Some(ms) => format!("  {} message(s), last {}", c.count, ago(ms)),
        None => "  no messages yet".into(),
    };
    out += &format!(
        "  notify {}{}",
        c.notify,
        if c.notify_set { "" } else { " (default)" }
    );
    if c.archived {
        out += "  archived";
    }
    out
}
