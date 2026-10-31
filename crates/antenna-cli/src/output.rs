// SPDX-License-Identifier: AGPL-3.0-only
//! Output for humans. Everything that came from a contact or an agent is escaped ([`clean`]) and shown separately, as a
//! quote: a contact's text cannot change how the screen looks (SPEC §9, protection against UI injection).

use antenna_proto::control::{ApprovalInfo, Event, FileInfo, InviteInfo, Reply, SessionInfo};

/// `println!` that does not panic when stdout is closed (`antenna … | head`).
macro_rules! outln {
    ($($t:tt)*) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stdout(), $($t)*);
    }};
}

// After the macro: the reply formatters use `outln!`.
mod approvers;
mod chats;
mod devices;
mod escalations;
mod local;
mod pictures;
mod reply;
mod teams;
mod updates;

pub use teams::WatchView;

/// How to show the SAS code (Q-6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum SasView {
    /// 6 digits (default).
    Digits,
    /// 6 emoji (the same code).
    Emoji,
    /// Both.
    Both,
}

/// A string from a contact or the daemon, for the terminal: control characters are escaped.
pub fn clean(s: &str) -> String {
    s.chars()
        .flat_map(|c| {
            if c.is_control() || invisible(c) {
                c.escape_unicode().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .collect()
}

/// Multi-line text for the terminal (an agent's reply): like [`clean`], but line breaks and tabs stay.
pub fn clean_text(s: &str) -> String {
    s.split('\n')
        .map(|l| l.split('\t').map(clean).collect::<Vec<_>>().join("\t"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Characters that change how text looks without being visible: writing direction (U+202A–202E, U+2066–2069, U+061C,
/// U+200E/200F), zero width (U+200B–200D, U+2060–2064, U+FEFF, U+180E), soft hyphen, line and paragraph separators
/// (U+2028/2029); categories Cf/Zl/Zp (otherwise the approval screen could be forged).
fn invisible(c: char) -> bool {
    // Spaces other than the plain one (category Zs): U+00A0, U+1680, U+2000–200A, U+202F, U+205F, U+3000.
    matches!(
        c,
        '\u{00A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    ) || matches!(c,
        '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{200B}'..='\u{200F}' | '\u{2028}'..='\u{202E}'
        | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{206F}' | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}'
        | '\u{E0000}'..='\u{E007F}')
}

/// Quote line width **in terminal columns** when the terminal's own width is unknown: with the `    │ ` prefix (6) it
/// fits in 80 columns.
const QUOTE_WIDTH: usize = 72;

/// Character width in columns (an East Asian Width approximation without dependencies): wide is 2, the rest is 1.
fn width(c: char) -> usize {
    match c as u32 {
        0x1100..=0x115F
        | 0x2E80..=0x303E
        | 0x3041..=0x33FF
        | 0x3400..=0x4DBF
        | 0x4E00..=0x9FFF
        | 0xA000..=0xA4CF
        | 0xAC00..=0xD7A3
        | 0xF900..=0xFAFF
        | 0xFE30..=0xFE4F
        | 0xFF00..=0xFF60
        | 0xFFE0..=0xFFE6
        | 0x1F300..=0x1F64F
        | 0x1F900..=0x1F9FF
        | 0x20000..=0x3FFFD => 2,
        _ => 1,
    }
}
/// How many quote characters a terminal shows of a quote on the owner's screens (an approval, a preview).
const QUOTE_MAX: usize = 4000;

/// Where the output goes: a person's terminal (its width less the frame, for wrapping) or a pipe or a file (`None`:
/// an agent's tool call, a script).
fn terminal_width() -> Option<usize> {
    use std::io::IsTerminal as _;
    if !std::io::stdout().is_terminal() {
        return None;
    }
    #[cfg(unix)]
    let cols = rustix::termios::tcgetwinsize(std::io::stdout())
        .map(|w| w.ws_col as usize)
        .unwrap_or(0);
    // Windows: the console's width comes with the console helpers of `antenna-sys` (D-134, WP-35); the default until
    // then.
    #[cfg(windows)]
    let cols = 0;
    Some(if cols > 26 { cols - 6 } else { QUOTE_WIDTH })
}

/// Quote on the owner's screens: every visible line has the `│ ` prefix and control and invisible characters are
/// escaped. In a terminal, long lines wrap at its width so that every line on the screen starts with `│`, and a quote
/// longer than [`QUOTE_MAX`] is cut with a note; into a pipe or a file (an agent, a script) nothing wraps and nothing
/// is cut, so a command in the text can be copied as it is.
pub fn quote(s: &str) -> String {
    let width = terminal_width();
    quote_with(s, width.map(|_| QUOTE_MAX), width)
}

/// A quote that is never cut, for text whose reading is recorded (an agent's inbox: what is not shown must not count
/// as read). It wraps in a terminal like [`quote`].
pub fn quote_whole(s: &str) -> String {
    quote_with(s, None, terminal_width())
}

/// [`quote`] with its limits given: at most `max` characters (`None`: all), lines wrapped at `wrap` columns (`None`:
/// each line whole).
fn quote_with(s: &str, max: Option<usize>, wrap: Option<usize>) -> String {
    let total = s.chars().count();
    let shown: String = match max {
        Some(m) => s.chars().take(m).collect(),
        None => s.to_string(),
    };
    let mut out = Vec::new();
    for line in shown.split('\n') {
        let cleaned = clean(line);
        if cleaned.is_empty() {
            out.push("    │".to_string());
            continue;
        }
        let Some(max_w) = wrap else {
            out.push(format!("    │ {cleaned}"));
            continue;
        };
        let mut cur = String::new();
        let mut w = 0;
        for c in cleaned.chars() {
            if w + width(c) > max_w {
                out.push(format!("    │ {cur}"));
                cur.clear();
                w = 0;
            }
            cur.push(c);
            w += width(c);
        }
        out.push(format!("    │ {cur}"));
    }
    if let Some(m) = max
        && total > m
    {
        out.push(format!(
            "    │ … ({} more characters not shown; --json gives the whole text)",
            total - m
        ));
    }
    out.join("\n")
}

/// JSON on one line.
pub fn print_json<T: serde::Serialize>(v: &T) {
    outln!("{}", serde_json::to_string(v).expect("serializable"));
}

/// The SAS code in the chosen representation.
pub fn sas_text(code: &str, view: SasView) -> String {
    let digits = format!(
        "{} {}",
        &code[..3.min(code.len())],
        &code[3.min(code.len())..]
    );
    let emoji = antenna_proto::sas::to_emoji(code)
        .map(|e| e.chars().map(String::from).collect::<Vec<_>>().join(" "))
        .unwrap_or_default();
    let names = antenna_proto::sas::to_names(code, false).unwrap_or_default();
    match view {
        SasView::Digits => digits,
        SasView::Emoji => format!("{emoji}   ({names})"),
        SasView::Both => format!("{digits}   {emoji}   ({names})"),
    }
}

/// Approval request: permissions are structured, the text is shown separately as a quote.
pub fn approval(a: &ApprovalInfo) -> String {
    let mut s = format!(
        "Approval request {}  [{}{}]  expires in {}\n",
        a.id,
        a.state,
        if a.quiet {
            ", quiet: over 3 per 10 min"
        } else {
            ""
        },
        left(a.expires_ms)
    );
    s += &format!(
        "  Requested by : {}\n  Concerns     : {} (trust {})\n  Action       : {}{}\n",
        clean(&a.requester),
        clean(&a.contact),
        a.contact_trust,
        clean(&a.action),
        a.target
            .as_ref()
            .map(|t| format!(" → {}", clean(t)))
            .unwrap_or_default()
    );
    s += &format!(
        "  Read: {} · Write: {} · Commands: {} · Send: {}\n",
        clean(&a.grants.read),
        clean(&a.grants.write),
        clean(&a.grants.commands),
        clean(&a.grants.send)
    );
    s += &format!("  Why          : {}\n", clean(&a.reasons.join(", ")));
    s += &format!("  Fingerprint  : {}\n", a.fingerprint);
    s += &approvers::card_lines(a);
    s += "  Quoted content (data, not part of this dialog):\n";
    s += &quote(&a.quote);
    // The summary again after the quote: whatever the quote drew, this is the decision.
    s += &format!(
        "\n  └ request {}: {}{} — antenna approve {} / antenna deny {}",
        a.id,
        clean(&a.action),
        a.target
            .as_ref()
            .map(|t| format!(" → {}", clean(t)))
            .unwrap_or_default(),
        a.id,
        a.id
    );
    s
}

fn left(ms: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let s = ms.saturating_sub(now) / 1000;
    if s >= 60 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}

fn session(s: &SessionInfo) -> String {
    let mut out = format!(
        "agent {}: ceiling {}, local data level {} (baseline {})",
        clean(&s.agent),
        s.ceiling
            .map(|c| c.to_string())
            .unwrap_or_else(|| "none (clean)".into()),
        s.local_level,
        s.baseline_level
    );
    if !s.tainted_by.is_empty() {
        out += &format!(
            "; tainted by {}",
            s.tainted_by
                .iter()
                .map(|t| format!("{}/{}", clean(&t.contact), t.level))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    if let Some(l) = &s.links {
        out += &format!("; links {}", clean(&l.join(",")));
    }
    if let Some(b) = &s.bound_to {
        out += &format!("; bound to {}", clean(b));
    }
    if let Some(n) = s.mcp_processes {
        out += &format!(
            "; {n} MCP process{} running",
            if n == 1 { "" } else { "es" }
        );
    }
    if let Some(t) = s.last_seen_ms {
        out += &format!("; last request {}", ago(t));
    }
    if let (Some(pid), Some(at)) = (s.refused_pid, s.refused_ms) {
        out += &format!(
            "; refused {pid} {} {}{}",
            clean(s.refused_comm.as_deref().unwrap_or("?")),
            ago(at),
            if s.refused_alive == Some(true) {
                " (still running)"
            } else {
                ""
            }
        );
    }
    if s.tasks_from.is_empty() {
        out += "; takes no tasks (every message is data)";
    } else {
        out += &format!(
            "; takes tasks from {}{}",
            clean(&s.tasks_from.join(", ")),
            if s.tasks_from_default {
                " (trust 5)"
            } else {
                ""
            }
        );
    }
    if let Some(c) = &s.counterpart {
        out += &format!("; default counterpart {}", counterpart_text(c));
    }
    if !s.local_routes.is_empty() {
        out += &format!(
            "; connected on this computer with {}",
            s.local_routes
                .iter()
                .map(|r| format!(
                    "{}{}",
                    clean(&r.agent),
                    if r.tasks { " (tasks)" } else { "" }
                ))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    if let Some(f) = &s.token_file {
        out += &format!("; token file {}", clean(f));
    }
    out
}

/// An agent's default counterpart in words: "volna at Mac mini", "the person at bob", "volna on this computer".
pub(crate) fn counterpart_text(c: &antenna_proto::control::Counterpart) -> String {
    let who = c
        .agent
        .as_deref()
        .map_or_else(|| "the person".to_string(), clean);
    if c.local {
        format!("{who} on this computer")
    } else {
        format!("{who} at {}", clean(&c.contact))
    }
}

/// "12 s ago" for a Unix ms time in the past.
pub(crate) fn ago(ms: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let s = now.saturating_sub(ms) / 1000;
    match s {
        0..60 => format!("{s} s ago"),
        60..3600 => format!("{} min ago", s / 60),
        3600..172_800 => format!("{} h ago", s / 3600),
        _ => format!("{} d ago", s / 86_400),
    }
}

/// " / <agent>" after the contact label (SPEC §5: "Bob / claude-backend").
fn via(agent: Option<&str>) -> String {
    agent
        .map(|a| format!(" / {}", clean(a)))
        .unwrap_or_default()
}

/// Address and topic of a message (v6) for humans: ` → lead #Avatars`; nothing for an unaddressed message.
fn addressed(
    to: Option<&str>,
    to_agent: Option<&str>,
    topic: Option<&antenna_proto::control::TopicView>,
) -> String {
    let mut s = match (to, to_agent) {
        (Some("agent"), Some(a)) => format!(" → {}", clean(a)),
        (Some("everyone"), _) => " → everyone".into(),
        // To the person is the ordinary case: not repeated on every line
        _ => String::new(),
    };
    if let Some(t) = topic {
        s.push_str(&format!(" #{}", clean(&t.title)));
    }
    s
}

/// Next to the invite link (on stderr, so that stdout stays a single link for scripts), when stderr is a terminal:
/// the same link for the app (`antenna://pair#…`) and a QR code of the web link.
fn invite_extras(link: &str, link_app: &str) {
    use std::io::IsTerminal as _;
    // Only for a human at a terminal: under systemd/cron stderr goes to a log, and the link carries a secret (D-78);
    // scripts use `--json` (`link_app` in the `invite_created` event).
    if !std::io::stderr().is_terminal() {
        return;
    }
    if !link_app.is_empty() {
        eprintln!("The same invite as an app link: {link_app}");
    }
    if let Some(qr) = qr_text(link) {
        eprintln!("{qr}");
    }
}

/// QR code of the link as text (Unicode half blocks, light quiet zone, for dark and light terminals).
pub fn qr_text(link: &str) -> Option<String> {
    use qrcode::render::unicode::Dense1x2;
    let code =
        qrcode::QrCode::with_error_correction_level(link.as_bytes(), qrcode::EcLevel::L).ok()?;
    Some(
        code.render::<Dense1x2>()
            .dark_color(Dense1x2::Light)
            .light_color(Dense1x2::Dark)
            .quiet_zone(true)
            .build(),
    )
}

fn invite(i: &InviteInfo, view: SasView) -> String {
    let mut s = format!(
        "{}  {:<17} trust {} {}  label {}  expires in {}",
        i.id,
        i.phase,
        i.trust,
        i.net_mode,
        clean(i.label.as_deref().unwrap_or("-")),
        left(i.expires_ms)
    );
    if let Some(c) = &i.sas {
        s += &format!("\n    code: {}", sas_text(c, view));
    }
    match i.phase.as_str() {
        "waiting" => s += "\n    waiting for the other side to open the link",
        "code_ready" | "peer_entered_code" => {
            s += "\n    read the code to the other person by voice; they type it on their side"
        }
        "needs_confirm" if i.confirm_without_code => {
            s += &format!(
                "\n    the other side typed the code correctly. If they told you by voice that it matched: antenna pairing confirm {}",
                i.id
            )
        }
        "needs_confirm" => {
            s += &format!(
                "\n    the other side typed the code correctly, but another invite showed a code at the same time: \
                 antenna pairing confirm {} --code <the code you read out>",
                i.id
            )
        }
        _ => {}
    }
    if let Some(r) = &i.result {
        s += &format!("\n    result: {}", clean(r));
    }
    s
}

/// Size for humans.
fn size(n: u64) -> String {
    const U: [&str; 4] = ["KiB", "MiB", "GiB", "TiB"];
    if n < 1024 {
        return format!("{n} B");
    }
    let mut v = n as f64 / 1024.0;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!("{v:.1} {}", U[i])
}

/// The reasons the rules hold a received file for its owner (D-130), as `held.code` says them.
const HOLD_CODES: &[&str] = &[
    "threat",
    "executable",
    "installer",
    "uninspected",
    "check_failed",
];

/// File line: ID, contact, state, verdict, size, name (contact data is escaped).
fn file_line(f: &FileInfo) -> String {
    let out = f.direction == "out";
    let arrow = if out { "→" } else { "←" };
    // A sent file's own check only labels it: the state says what the contact's node did (D-130); a received file's
    // verdict shows only where it decides (the labels say the rest)
    let state = match (out, f.state.as_str()) {
        (true, "sent") => "sent, waiting for the contact's check".to_string(),
        (true, "held") => "waiting for the contact to decide".to_string(),
        (true, "blocked") => "held by the contact's check".to_string(),
        (true, "rejected") => "declined by the contact".to_string(),
        (true, "accepted") => "saved by the contact".to_string(),
        (_, s) => s.to_string(),
    };
    let verdict = if out || !f.labels.is_empty() && f.held.is_none() {
        String::new()
    } else {
        f.verdict
            .as_deref()
            .map(|v| format!(" [{v}]"))
            .unwrap_or_default()
    };
    let mut s = format!(
        "{} {arrow} {}  {state}{verdict}  {}  {}",
        &f.id[..16.min(f.id.len())],
        clean(&f.contact),
        size(f.size),
        clean(&f.name)
    );
    if f.class.as_deref() == Some("code") {
        s += "  (code: Antenna does not run it)";
    }
    if !f.labels.is_empty() {
        s += &format!(
            "  ({}: {})",
            if out {
                "this computer's check"
            } else {
                "labels"
            },
            f.labels
                .iter()
                .map(|l| clean(l))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    match (&f.saved_path, &f.dest, &f.saved_as) {
        (Some(p), _, _) => s += &format!("  → {}", clean(p)),
        (None, Some(d), Some(n)) => s += &format!("  → {d}/{}", clean(n)),
        _ => {}
    }
    if let Some(r) = &f.reason {
        s += &format!("  ({})", clean(r));
    }
    // Why a file waits (D-128, D-130): a received one for this owner's keep-anyway, a sent one at the contact
    if let Some(h) = &f.held {
        let rules = if h.rules.is_empty() {
            String::new()
        } else {
            format!(
                " [{}]",
                h.rules
                    .iter()
                    .map(|r| clean(r))
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        if out {
            s += &format!("  ({}: {}{rules})", clean(&h.code), clean(&h.message));
        } else if HOLD_CODES.contains(&h.code.as_str()) {
            s += &format!(
                "  (held for you: {}{rules}; keep it anyway: antenna files accept {} --force)",
                clean(&h.message),
                &f.id[..16.min(f.id.len())]
            );
        } else {
            s += &format!(
                "  (not saved by itself: {}: {})",
                clean(&h.code),
                clean(&h.message)
            );
        }
    }
    match f.withdrawal.as_deref() {
        Some("contact_notified") => s += "  (the contact's copy is deleted)",
        Some("contact_cannot_withdraw") => {
            s += "  (no longer served; the contact's older Antenna keeps a copy it already downloaded)"
        }
        _ => {}
    }
    s
}

/// File details: the line, MIME, findings, check isolation, how long a threat is kept.
fn file_details(f: &FileInfo) -> String {
    let mut s = file_line(f);
    s += &format!(
        "\n    sender says: {} ({})",
        clean(&f.sender_mime),
        f.sender_verdict
    );
    s += &hashes(f);
    if let Some(m) = &f.mime {
        s += &format!("\n    detected: {}", clean(m));
    }
    if let Some(sb) = &f.sandbox {
        s += &format!("  (checked in: {})", clean(sb));
    }
    for x in &f.findings {
        s += &format!(
            "\n    {} {}: {}",
            x.severity,
            clean(&x.code),
            clean(&x.detail)
        );
    }
    if let Some(e) = f.expires_ms {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let h = e.saturating_sub(now) / 3_600_000;
        s += &format!(
            "\n    kept for the owner's decision {}d {}h more, then deleted (antenna files accept {} --force)",
            h / 24,
            h % 24,
            &f.id[..16.min(f.id.len())]
        );
    }
    s
}

/// A file's hashes, whole, on their own lines: SHA-256 first (`shasum -a 256` on macOS, `sha256sum` on Linux check
/// it), then BLAKE3 (the one the link history records; `b3sum`). SHA-256 is absent until this computer has read the
/// content.
fn hashes(f: &FileInfo) -> String {
    let mut s = String::new();
    if let Some(h) = &f.sha256 {
        s += &format!("\n    sha256 {}", clean(h));
    }
    if !f.blake3.is_empty() {
        s += &format!("\n    blake3 {}", clean(&f.blake3));
    }
    s
}

/// Why the contact's node holds or blocked a sent file, when it says (D-130): the reason and the rules.
fn fate_why(f: &FileInfo) -> String {
    f.held
        .as_ref()
        .map(|h| {
            let rules = if h.rules.is_empty() {
                String::new()
            } else {
                format!(
                    " [{}]",
                    h.rules
                        .iter()
                        .map(|r| clean(r))
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            };
            format!("\n    why: {}{rules}", clean(&h.message))
        })
        .unwrap_or_default()
}

/// A file saved for the agent (CONTROL §14, in its inbox): a received file with where it is and its hashes, or the
/// contact's answer about a file it sent.
fn saved_file(f: &FileInfo) -> String {
    let id = &f.id[..16.min(f.id.len())];
    // Another file had the name, so it was saved under a number (D-128)
    let renamed = f
        .saved_as
        .as_deref()
        .filter(|s| *s != f.name)
        .map(|s| format!(" as {} (another file had its name)", clean(s)))
        .unwrap_or_default();
    let head = match (f.direction.as_str(), f.state.as_str()) {
        ("out", "accepted") => format!(
            "file {id} you sent: {} accepted and saved it: {} ({}){renamed}",
            clean(&f.contact),
            clean(&f.name),
            size(f.size)
        ),
        // Held is never "declined": the contact's owner has not decided yet (D-130)
        ("out", "held") => format!(
            "file {id} you sent: {} holds it for its owner to decide: {} ({}){}",
            clean(&f.contact),
            clean(&f.name),
            size(f.size),
            fate_why(f)
        ),
        ("out", "blocked") => format!(
            "file {id} you sent: {}'s check held it: {} ({}){}",
            clean(&f.contact),
            clean(&f.name),
            size(f.size),
            fate_why(f)
        ),
        ("out", _) => format!(
            "file {id} you sent: {} declined it: {} ({})",
            clean(&f.contact),
            clean(&f.name),
            size(f.size)
        ),
        _ => format!(
            "file {id} saved: {} from {} ({}){renamed}{}",
            clean(&f.name),
            clean(&f.contact),
            size(f.size),
            f.saved_path
                .as_deref()
                .map(|p| format!("\n    at {}", clean(p)))
                .unwrap_or_default()
        ),
    };
    head + &hashes(f)
}

/// Final reply for humans.
pub fn human(r: &Reply, view: SasView) {
    match r {
        Reply::Status(s) => reply::status(s),
        Reply::Done { state } => outln!("ok: {}", clean(state)),
        Reply::Linked(l) => reply::linked(l),
        Reply::InviteCreated(i) => reply::invite_created(i),
        Reply::Pairings { invites } => reply::pairings(invites, view),
        Reply::Contacts(c) => reply::contacts(c),
        Reply::AgentContacts { contacts } => reply::agent_contacts(contacts),
        Reply::Sent(s) => reply::sent(s),
        Reply::Inbox(i) => reply::inbox(i),
        Reply::AgentInbox(i) => {
            reply::agent_inbox(i);
            escalations::answers(&i.escalations);
            approvers::facts(&i.to_answer);
            for f in &i.files {
                outln!("{}", saved_file(f));
            }
        }
        Reply::Waited {
            pending,
            approvals,
            tasks,
            escalations: answered,
            to_answer,
            files,
        } => {
            reply::waited(pending, approvals);
            teams::facts(tasks);
            escalations::answers(answered);
            approvers::facts(to_answer);
            reply::file_facts(files);
        }
        Reply::Trust(t) => reply::trust(t),
        Reply::Session(s) => outln!("{}", session(s)),
        Reply::Check(c) => outln!("{}: {} ({})", c.action, c.decision, clean(&c.reason)),
        Reply::Approvals {
            approvals,
            hidden_quiet,
        } => reply::approvals(approvals, *hidden_quiet),
        Reply::Approval(a) => outln!("{} {}", a.state, a.id),
        Reply::ApprovalsDecided { results } => reply::approvals_decided(results),
        Reply::Topics {
            contact, topics, ..
        } => reply::topics(contact, topics),
        Reply::AgentAdded {
            name,
            token,
            token_file,
        } => reply::agent_added(name, token, token_file),
        Reply::Agents { agents } => reply::agents(agents),
        Reply::History(h) => reply::history(h),
        Reply::Log { contact, entries } => reply::log(contact, entries),
        Reply::OwnerSession(o) => reply::owner_session(o),
        Reply::HistoryStatus(h) => outln!("{}", history_status(&h.contact, &h.status)),
        Reply::Revoked {
            contact,
            history_deleted,
            ..
        } => reply::revoked(contact, *history_deleted),
        Reply::Files { files } => reply::files(files),
        Reply::File(f) => outln!("{}", file_details(f)),
        Reply::FilePreview { file, preview } => reply::file_preview(file, preview),
        Reply::FileRequested {
            contact,
            id,
            status,
        } => reply::file_requested(contact, id, status),
        Reply::Rekey {
            contact,
            state,
            code,
            code_emoji,
        } => reply::rekey(contact, state, code, code_emoji),
        Reply::Streams { streams } => reply::streams(streams),
        Reply::UpdateAuthorized(u) => outln!("update authorized by {} (pid {})", u.daemon, u.pid),
        Reply::Lan(l) => reply::lan(l),
        Reply::Wake {
            rules,
            sandbox,
            sandbox_detail,
        } => reply::wake(rules, sandbox, sandbox_detail),
        Reply::ResidentTurn(t) => reply::resident_turn(t),
        Reply::ResidentSession { contact, resident } => reply::resident_session(contact, resident),
        Reply::Chats(c) => chats::chats(c),
        Reply::Escalations(e) => escalations::list(e),
        Reply::Escalation(e) => escalations::one(e),
        Reply::Chat(c) => chats::chat(c),
        Reply::Pictures(p) => pictures::pictures(p),
        Reply::PicturePhoto(p) => pictures::photo(p),
        Reply::LocalModels(m) => local::models(m),
        Reply::LocalModel(m) => local::model(m),
        Reply::LocalAgent(a) => local::agent(a),
        Reply::LocalTurn(t) => local::turn(t),
        Reply::LocalHistory(h) => local::history(h),
        Reply::UpdateAuto(u) => updates::update_auto(u),
        Reply::FileName(f) => updates::file_name(f),
        Reply::FileAllow(a) => outln!(
            "{}: allowed from this computer: {}",
            clean(&a.contact),
            if a.entries.is_empty() {
                "nothing beyond the rules (programs and installers wait for you)".to_string()
            } else {
                a.entries
                    .iter()
                    .map(|e| clean(e))
                    .collect::<Vec<_>>()
                    .join(", ")
            }
        ),
        Reply::FileSaveDirs(d) => {
            if d.dirs.is_empty() {
                outln!("{}: files are saved in the link folder", clean(&d.contact));
            }
            for x in &d.dirs {
                outln!(
                    "{}{}: files are saved to {}",
                    clean(&d.contact),
                    x.agent
                        .as_deref()
                        .map(|a| format!(" / {}", clean(a)))
                        .unwrap_or_default(),
                    clean(&x.path)
                );
            }
        }
        Reply::OwnerChallenge(c) => outln!("challenge {} (60 s)", c.nonce),
        Reply::OwnerKeys(k) => reply::owner_keys(k),
        Reply::OwnerKeyAdded(a) => outln!("owner key {} enrolled", a.key.key_id),
        Reply::Devices(d) => devices::devices(d),
        Reply::DeviceChallenge(c) => outln!("challenge of {}: {}", clean(&c.contact), c.nonce),
        Reply::DeviceDecided(d) => devices::decided(d),
        Reply::AgentConnected(c) => devices::connected(c),
        Reply::AgentTraffic(t) => devices::traffic(t),
        Reply::Approvers(r) => approvers::list(r),
        Reply::AgentStopped(s) => reply::agent_stopped(s),
        Reply::ToAnswer(r) => approvers::to_answer(r),
        Reply::Answered(r) => approvers::answered(r),
        Reply::Team(t) => teams::team(t),
        Reply::Teams { teams: ts } => teams::teams(ts),
        Reply::TeamWorker(w) => teams::worker(w),
        Reply::Task(t) => teams::task(t),
        Reply::Tasks { tasks } => teams::tasks(tasks),
        Reply::TaskDiff(d) => teams::diff(d),
        Reply::CheckRun(c) => teams::check_run(c),
        Reply::Capacity(c) => teams::capacity(c),
        Reply::TeamLog { entries } => teams::log(entries),
    }
}

/// History verification state for humans.
pub fn history_status(contact: &str, s: &antenna_proto::control::HistoryStatus) -> String {
    let mut out = match s.state.as_str() {
        "verified" => format!(
            "{}: history verified {} ({})",
            clean(contact),
            s.fingerprint.as_deref().unwrap_or(""),
            s.fingerprint_digits.as_deref().unwrap_or("")
        ),
        "mismatch" => format!(
            "{}: HISTORY MISMATCH — {}",
            clean(contact),
            clean(&s.detail)
        ),
        "rolled_back" => format!(
            "{}: STATE ROLLED BACK — {}",
            clean(contact),
            clean(&s.detail)
        ),
        other => format!("{}: {other} — {}", clean(contact), clean(&s.detail)),
    };
    if let Some(p) = &s.place {
        out += &format!(
            "\n  where: {} message #{}{}{}",
            if p.author == "me" {
                "my"
            } else {
                "the contact's"
            },
            p.n,
            p.seq.map(|q| format!(", local #{q}")).unwrap_or_default(),
            p.message_id
                .as_ref()
                .map(|m| format!(", id {}…", &m[..16.min(m.len())]))
                .unwrap_or_default()
        );
        if let Some(w) = &s.who_changed {
            out += &format!(
                "\n  changed copy: {w} ({})",
                s.reason.as_deref().unwrap_or("")
            );
        }
    }
    out += &format!(
        "\n  messages: mine {}, contact's {}{}",
        s.counts[0],
        s.counts[1],
        if s.send_blocked {
            "; sending is blocked"
        } else {
            ""
        }
    );
    out
}

/// Subscription event (`antenna events`) for humans.
pub fn human_stream_event(e: &Event) {
    match e {
        Event::Subscribed { proto, role } => {
            eprintln!("subscribed ({proto}, {role:?}); Ctrl-C to stop")
        }
        Event::Message {
            contact, message, ..
        } => outln!(
            "{} {} #{} [{}] {}",
            if message.direction == "in" {
                "←"
            } else {
                "→"
            },
            clean(contact),
            message.seq,
            message.status,
            clean(&message.text)
        ),
        Event::MessageFact {
            contact,
            trust,
            chars,
            local,
            ..
        } => {
            outln!(
                "← {}{} (trust {trust}): new message, {chars} chars",
                clean(contact),
                if local.is_some() {
                    " (an agent of this computer)"
                } else {
                    ""
                }
            )
        }
        Event::MessageStatus {
            contact,
            id,
            status,
            ..
        } => {
            outln!(
                "→ {} {}…: {status}",
                clean(contact),
                &id[..12.min(id.len())]
            )
        }
        Event::Contact { contact } => outln!(
            "contact {}: trust {}, {}, {}",
            clean(&contact.contact),
            contact.trust,
            contact.net_mode,
            contact.presence
        ),
        Event::Invite { invite: i } => outln!("invite {}: {}", i.id, i.phase),
        Event::Approval { approval: a } => outln!(
            "approval {} [{}]: {} by {}",
            a.id,
            a.state,
            clean(&a.action),
            clean(&a.requester)
        ),
        Event::Lagged { missed } => outln!("(missed {missed} events: re-read contacts/history)"),
        Event::History {
            contact, status, ..
        } => outln!("{}", history_status(contact, status)),
        Event::Rekey { contact, state } => {
            let c = clean(contact);
            match state.as_str() {
                "requested_by_contact" => outln!(
                    "re-keying with {c}: they ask to re-key the link — type the code they read out: \
                     antenna rekey {c} --code <code>"
                ),
                "confirm_contact_code" => outln!(
                    "re-keying with {c}: they accepted — type the code they read out: antenna rekey {c} --code <code>"
                ),
                "conflicting_offers" => outln!(
                    "re-keying with {c}: two different requests or answers came from their keys — both discarded; \
                     somebody else may hold the keys of this link, check with the contact by voice"
                ),
                _ => outln!("re-keying with {c}: {}", clean(state)),
            }
        }
        Event::File { file, .. } => outln!("file {}", file_line(file)),
        Event::MessageStream(s) => match s.state.as_str() {
            "streaming" => {
                if let Some(d) = s.delta.as_deref().filter(|d| !d.is_empty()) {
                    outln!(
                        "{} {} …{}",
                        if s.direction == "in" { "←" } else { "→" },
                        clean(&s.contact),
                        clean(d)
                    );
                } else if s.seq == 0 {
                    outln!(
                        "{} {} is writing…",
                        if s.direction == "in" { "←" } else { "→" },
                        clean(&s.contact)
                    );
                }
            }
            "final" => outln!(
                "{} {}: stream finished ({}), message {}",
                if s.direction == "in" { "←" } else { "→" },
                clean(&s.contact),
                s.end.as_deref().unwrap_or("done"),
                s.message_id
                    .as_deref()
                    .map(|m| &m[..16.min(m.len())])
                    .unwrap_or("-")
            ),
            _ => outln!(
                "{} {}: stream interrupted ({})",
                if s.direction == "in" { "←" } else { "→" },
                clean(&s.contact),
                s.reason.as_deref().unwrap_or("-")
            ),
        },
        Event::Wake(w) => outln!(
            "wake {} for {}: {} {}",
            clean(&w.agent),
            clean(&w.contact),
            w.state,
            clean(&w.detail)
        ),
        Event::StreamStarted { live, .. } => eprintln!("stream started (live: {live})"),
        Event::Agent { name, change, by } => match by {
            Some(by) => outln!("agent {}: {} by {}", clean(name), clean(change), clean(by)),
            None => outln!("agent {}: {}", clean(name), clean(change)),
        },
        Event::ApprovalResolved(r) => reply::resolution(r),
        Event::Session { mode, .. } => eprintln!("owner session held by this connection ({mode})"),
        Event::InputRejected { what, message, .. } => {
            eprintln!("input rejected ({what}): {}", clean(message))
        }
        Event::Team(t) => outln!(
            "team {}: {}{}{}{}{}",
            clean(&t.team),
            clean(&t.change),
            t.worker
                .as_deref()
                .map(|w| format!(" {}", clean(w)))
                .unwrap_or_default(),
            t.task
                .as_deref()
                .map(|k| format!(" task {}", clean(k)))
                .unwrap_or_default(),
            t.state
                .as_deref()
                .map(|s| format!(" {}", clean(s)))
                .unwrap_or_default(),
            t.by.as_deref()
                .map(|b| format!(" by {}", clean(b)))
                .unwrap_or_default()
        ),
        Event::WorkerOutput(w) => outln!(
            "{} {} (turn {}): {}",
            clean(&w.worker),
            clean(&w.part),
            w.turn,
            clean(&w.text)
        ),
        Event::LocalModel(m) => local::model(m),
        Event::LocalAgent(a) => local::agent(a),
        Event::UpdateAuto(u) => outln!(
            "automatic update {}: {}{}",
            clean(&u.version),
            clean(&u.state),
            u.reason
                .as_deref()
                .map(|r| format!(" ({})", clean(r)))
                .unwrap_or_default()
        ),
        // Pieces of a reply come only on the dialog that asked (`wake say`, `local say`), which prints them itself
        Event::LocalDelta { .. } | Event::ResidentDelta { .. } => {}
        Event::Device {
            contact, change, ..
        } => outln!("own device {}: {}", clean(contact), clean(change)),
        Event::Chat(c) => outln!("chat changed: {}", chats::line(c)),
        Event::Picture(p) => outln!("picture changed: {}", pictures::line(p)),
        Event::ApprovalToAnswer(f) => approvers::fact(f),
        // The pairing events, and anything else as its JSON line (escaped): never back to `human_event`, which hands
        // unknown kinds here (the two used to recurse until the stack overflowed on `update_auto`)
        other => {
            if !pairing_event(other, SasView::Digits) {
                print_json(other);
            }
        }
    }
}

/// Pairing event for humans; any other event as `antenna events` prints it.
pub fn human_event(e: &Event, view: SasView) {
    if !pairing_event(e, view) {
        human_stream_event(e);
    }
}

/// The pairing events (invite, code, waiting); `false` for any other event. Kept apart from
/// [`human_stream_event`] so that neither printer hands an event it does not know back to the other: they used to
/// call each other for every unknown kind, and an `x-control/7` event such as `local_model` or `update_auto` recursed
/// until the stack overflowed.
fn pairing_event(e: &Event, view: SasView) -> bool {
    match e {
        Event::InviteCreated {
            id,
            link,
            link_app,
            trust,
            net_mode,
            ..
        } => {
            outln!("{link}");
            invite_extras(link, link_app);
            eprintln!(
                "Invite {id} created (trust {trust}, {net_mode}). Send this one-time link to the contact. \
                 The invite lives in the daemon until it expires: closing this command does not burn it \
                 (`antenna pairing`, `antenna pairing confirm {id}`, `antenna pairing cancel {id}`)."
            );
        }
        Event::AttemptFailed {
            attempts,
            max,
            reason,
        } => eprintln!("failed attempt {attempts}/{max}: {}", clean(reason)),
        Event::Sas { code, .. } => {
            outln!("Verification code: {}", sas_text(code, view));
            eprintln!(
                "Read this code to the other person by voice; they must type it on their side."
            );
        }
        Event::PeerEnteredCode => eprintln!("The other side typed the code correctly."),
        Event::NeedInput { .. } => {}
        Event::Waiting { what } => match what.as_str() {
            "peer_code_entry" => eprintln!("Waiting for the other side to type the code…"),
            "owner_a_confirm" => eprintln!("Code accepted. Waiting for the inviter to confirm…"),
            _ => {}
        },
        _ => return false,
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `antenna events` prints every event kind: one neither formatter knows ends as its JSON line instead of going back
    /// and forth between `human_stream_event` and `human_event` until the stack overflows (it did for `update_auto`).
    #[test]
    fn every_event_kind_is_printed_without_a_loop() {
        human_stream_event(&Event::UpdateAuto(
            antenna_proto::control::UpdateAutoEvent {
                state: "staged".into(),
                version: "0.1.0-preview.8".into(),
                source: "url".into(),
                contact: None,
                at_ms: None,
                reason: None,
            },
        ));
        human_stream_event(&Event::Chat(antenna_proto::control::ChatInfo {
            contact: "bob".into(),
            link_id: "ab".repeat(32),
            agent: Some("lead".into()),
            name: Some("Payments API".into()),
            notify: "asks".into(),
            notify_set: false,
            archived: false,
            archived_ms: None,
            count: 0,
            unread: 0,
            last_seq: None,
            last_ms: None,
            last: None,
            saved: true,
        }));
        human_stream_event(&Event::Picture(antenna_proto::control::PictureEntry {
            contact: Some("bob".into()),
            agent: Some("lead".into()),
            drawn: Some("set1/fox".into()),
            ..Default::default()
        }));
        human_stream_event(&Event::PeerEnteredCode);
    }

    /// QR code of the invite web link: a square of half blocks with equal line widths; a long link (≈ 200 characters
    /// with the n0 relay) fits in 80 terminal columns.
    #[test]
    fn invite_qr_fits_a_terminal() {
        let link = format!(
            "https://antenna.contact/#{}.{}.{}",
            "a".repeat(52),
            "b".repeat(52),
            "aHR0cHM6Ly9ldWMxLTEucmVsYXkubjAuaXJvaC1jYW5hcnkuaXJvaC5saW5rLi8"
        );
        let qr = qr_text(&link).unwrap();
        let lines: Vec<&str> = qr.lines().collect();
        let w = lines[0].chars().count();
        assert!(w <= 80, "{w} columns");
        assert!(lines.iter().all(|l| l.chars().count() == w));
        assert!(
            qr.chars()
                .all(|c| matches!(c, ' ' | '\u{2580}' | '\u{2584}' | '\u{2588}' | '\n'))
        );
    }

    /// Every event kind has a line in `antenna events`: the v6 and v7 kinds once fell between the stream and the
    /// pairing formatters, each handing them to the other until the stack overflowed.
    #[test]
    fn every_event_kind_prints() {
        use antenna_proto::control::{TeamEvent, WorkerOutput};
        let team = TeamEvent {
            team: "web".into(),
            change: "worker".into(),
            task: None,
            state: Some("busy".into()),
            worker: Some("web.coder-1".into()),
            by: Some("daemon".into()),
        };
        for e in [
            Event::Team(team),
            Event::WorkerOutput(WorkerOutput {
                team: "web".into(),
                worker: "web.coder-1".into(),
                task: None,
                turn: 1,
                part: "text".into(),
                text: "hi".into(),
            }),
            Event::ResidentDelta {
                contact: "bob".into(),
                turn: 1,
                delta: "hi".into(),
                activity: None,
            },
            Event::LocalDelta {
                agent: "helper".into(),
                turn: 1,
                delta: "hi".into(),
                activity: Some("loading".into()),
            },
        ] {
            human_stream_event(&e);
            human_event(&e, SasView::Digits);
        }
    }

    /// Every event kind prints and returns: none goes back and forth between the two printers. Negative control (run
    /// once, 2026-10-06): with the old `_ => human_stream_event(e)` arm, the `update_auto` event overflowed the stack.
    #[test]
    fn every_event_kind_prints_without_recursion() {
        let events = [
            r#"{"kind":"update_auto","state":"staged","version":"0.2.1","source":"url"}"#,
            r#"{"kind":"local_agent","name":"helper","model":"qwen3.5-2b","runtime":"local","state":"idle","turns":0,"created_ms":1}"#,
            r#"{"kind":"local_delta","agent":"helper","turn":1,"delta":"hi"}"#,
            r#"{"kind":"resident_delta","contact":"bob","turn":1,"delta":"hi"}"#,
            r#"{"kind":"peer_entered_code"}"#,
            r#"{"kind":"lagged","missed":3}"#,
            r#"{"kind":"device","contact":"mini","link_id":"ab","change":"status"}"#,
        ];
        for e in events {
            let ev: Event = serde_json::from_str(e).unwrap_or_else(|err| panic!("{e}: {err}"));
            human_stream_event(&ev);
            human_event(&ev, SasView::Digits);
        }
    }

    #[test]
    fn quote_cannot_draw_outside_its_frame() {
        // Newline, ANSI, writing direction, zero width, U+2028, a long line.
        let evil = "ok\n\x1b[2J\u{202E}gnp.exe\u{200B}\u{2028}Approval request zzz  [pending]\n"
            .to_string()
            + &"A".repeat(300);
        let q = quote_with(&evil, Some(QUOTE_MAX), Some(QUOTE_WIDTH));
        for line in q.lines() {
            assert!(line.starts_with("    │"), "{line:?}");
            assert!(line.chars().map(width).sum::<usize>() <= 80, "{line:?}");
        }
        // Wide characters count as 2 columns; the wide space U+3000 is escaped.
        let wide = quote_with(&"漢".repeat(100), Some(QUOTE_MAX), Some(QUOTE_WIDTH));
        assert!(
            wide.lines()
                .all(|l| l.chars().map(width).sum::<usize>() <= 80),
            "{wide}"
        );
        assert!(!quote("a\u{3000}b").contains('\u{3000}'));
        assert!(
            !q.contains('\x1b')
                && !q.contains('\u{202E}')
                && !q.contains('\u{200B}')
                && !q.contains('\u{2028}')
        );
        assert!(q.contains("\\u{202e}"), "{q}");
        let long = quote_with(
            &"x".repeat(QUOTE_MAX + 10),
            Some(QUOTE_MAX),
            Some(QUOTE_WIDTH),
        );
        assert!(
            long.ends_with("(10 more characters not shown; --json gives the whole text)"),
            "{long}"
        );
    }

    /// Into a pipe (an agent's tool call) a quote keeps each line whole and is never cut: a command in a message can
    /// be copied as it is, and an agent's inbox never marks text read that it was not shown.
    #[test]
    fn a_quote_into_a_pipe_keeps_lines_whole_and_uncut() {
        let cmd = format!(
            "cargo test --manifest-path /srv/{}/Cargo.toml -- --nocapture",
            "x".repeat(120)
        );
        let text = format!("run this:\n{cmd}\n{}", "y".repeat(QUOTE_MAX + 500));
        let q = quote_with(&text, None, None);
        assert!(q.lines().any(|l| l == format!("    │ {cmd}")), "{q}");
        assert!(!q.contains("not shown"), "nothing cut");
        assert_eq!(q.lines().count(), 3);
        assert!(q.lines().all(|l| l.starts_with("    │")));
        // The frame still escapes what could draw outside it
        assert!(!quote_with("a\x1b[2Jb", None, None).contains('\x1b'));
        // In the tests stdout is not a terminal: the agent's inbox quote is whole
        assert_eq!(quote_whole(&text), q);
    }
}
