// SPDX-License-Identifier: AGPL-3.0-only
//! Final replies for humans: one formatter per reply kind, called from [`super::human`]. What came from a contact or an
//! agent is escaped or quoted here as everywhere in `output` (SPEC §9).

use antenna_proto::control::{
    AgentContact, AgentInboxReply, AgentInfo, ApprovalInfo, ApprovalResolution, BatchResult,
    ContactsReply, FileInfo, FilePreviewView, HistoryReply, InboxReply, InviteInfo, LanReply,
    LinkedReply, MessageFact, OwnerKeys, OwnerSession, ReceiptInfo, ResidentInfo, ResidentTurn,
    SecretString, SentReply, StatusReply, StreamView, TopicInfo, TrustInfo, WakeRuleInfo,
};

use super::{
    SasView, addressed, approval, clean, file_details, file_line, invite, invite_extras, quote,
    quote_whole, session, via,
};

/// `status`.
pub(super) fn status(s: &StatusReply) {
    outln!("state: {}", s.state);
    outln!(
        "daemon: {}  protocol: {}  relay: {}",
        s.daemon,
        s.protocol,
        s.relay
    );
    if let Some(n) = s.links {
        outln!("links: {n}");
    }
    if let Some(u) = &s.updated {
        super::updates::updated(u);
    }
}

/// `invite`, `join` and `pairing confirm`: the link is up.
pub(super) fn linked(l: &LinkedReply) {
    outln!(
        "linked with {} (trust {}, {}), link {}…",
        clean(&l.contact),
        l.trust,
        l.net_mode,
        &l.link_id[..12]
    );
    outln!(
        "TLS group at pairing: {}; pairing took {} ms",
        l.kx_group,
        l.pairing_ms
    );
}

/// `invite --detach`: the link and how to go on.
pub(super) fn invite_created(i: &InviteInfo) {
    outln!("{}", i.link);
    invite_extras(&i.link, &i.link_app);
    eprintln!(
        "Invite {} created (trust {}, {}). It lives in the daemon until it expires: `antenna pairing` shows \
         the code when the other side connects, `antenna pairing confirm {}` links.",
        i.id, i.trust, i.net_mode, i.id
    );
}

/// `pairing`: the invites in the daemon.
pub(super) fn pairings(invites: &[InviteInfo], view: SasView) {
    if invites.is_empty() {
        outln!("no invites");
    }
    for i in invites {
        outln!("{}", invite(i, view));
    }
}

/// `contacts` (owner).
pub(super) fn contacts(c: &ContactsReply) {
    if c.contacts.is_empty() {
        outln!("no contacts yet: `antenna invite` or `antenna join <link>`");
    }
    for k in &c.contacts {
        outln!(
            "{:<20} trust {}  {:<10}  e2e v{} {}  tls {}  outbox {}  link {}…",
            clean(&k.label),
            k.trust,
            k.net_mode,
            k.e2e
                .session_version
                .map(|v| v.to_string())
                .unwrap_or("-".into()),
            pq_state(k.e2e.pq_ratchet.as_deref()),
            k.transport
                .last_kx_group
                .as_deref()
                .unwrap_or(&k.transport.pairing_kx_group),
            k.outbox,
            &k.link_id[..12]
        );
        if !k.agents.is_empty() {
            let names: Vec<String> = k
                .agents
                .iter()
                .map(|a| {
                    if a.state == "active" {
                        clean(&a.name)
                    } else {
                        format!("{} ({})", clean(&a.name), a.state)
                    }
                })
                .collect();
            outln!("    their agents: {}", names.join(", "));
        }
    }
}

/// `contacts` (agent).
pub(super) fn agent_contacts(contacts: &[AgentContact]) {
    for c in contacts {
        outln!(
            "{:<20} trust {} ({})  link {}…{}",
            clean(&c.contact),
            c.trust,
            c.rights.name,
            c.link,
            c.folder
                .as_deref()
                .map(|f| format!("  folder {}", clean(f)))
                .unwrap_or_default()
        );
    }
}

/// `send`.
/// `agent_stopped` (PG-58): what the stop took, in words.
pub(super) fn agent_stopped(s: &antenna_proto::control::AgentStopped) {
    let agent = clean(&s.agent);
    let on = s
        .contact
        .as_deref()
        .map(|c| format!(" on {}", clean(c)))
        .unwrap_or_default();
    let names = if s.names.is_empty() {
        String::new()
    } else {
        format!(
            " ({})",
            s.names
                .iter()
                .map(|n| clean(n))
                .collect::<Vec<_>>()
                .join(", ")
        )
    };
    match s.how.as_str() {
        "none" => outln!("agent {agent}{on} was not running"),
        "app" => outln!(
            "agent {agent}{on} is an AI app's: the app was not quit; the agent is disconnected until you connect the \
             app again"
        ),
        "local" => outln!("agent {agent}{on}: its turn was stopped"),
        how => outln!(
            "stopped agent {agent}{on} ({how}): {} processes{names}",
            s.processes
        ),
    }
    if s.left > 0 {
        eprintln!(
            "note: {} processes did not stop; look for them with ps and end them yourself",
            s.left
        );
    }
}

pub(super) fn sent(s: &SentReply) {
    // The contact's node answered that it has no agent by this name (PROTOCOL §23, `no-agent/0`): not "delivered"
    if s.no_agent {
        outln!(
            "no agent named {} at the contact ({}): nobody there reads this message",
            clean(s.to_agent.as_deref().unwrap_or("")),
            &s.id[..16]
        );
        if s.peer_agents.is_empty() {
            eprintln!("the contact has announced no agents yet; its owner still sees the message");
        } else {
            eprintln!(
                "their agents: {} (antenna send --to-agent <name>); its owner still sees the message",
                s.peer_agents
                    .iter()
                    .map(|a| clean(a))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        return;
    }
    if s.local {
        outln!(
            "{} {} to {} on this computer",
            s.status,
            &s.id[..16.min(s.id.len())],
            clean(s.to_agent.as_deref().unwrap_or(""))
        );
        return;
    }
    outln!(
        "{} {}{}",
        s.status,
        &s.id[..16],
        addressed(s.to.as_deref(), s.to_agent.as_deref(), s.topic.as_ref())
    );
    if s.urgent == Some(false) {
        eprintln!(
            "note: the contact's Antenna cannot take urgent messages yet: this one went as a normal message, read when \
             the agent is idle"
        );
    }
    if s.addressed == Some(false) {
        eprintln!(
            "note: the contact's node is older and does not understand addressing: all its agents that may \
             read messages can read this one"
        );
    }
}

/// The post-quantum ratchet in plain words: the raw state (`NegotiationComplete(V1)`) stays in `--json`.
fn pq_state(raw: Option<&str>) -> &'static str {
    match raw {
        Some(r) if r.starts_with("NegotiationComplete") => "pq on",
        Some(_) => "pq starting",
        None => "-",
    }
}

/// `inbox` (owner).
pub(super) fn inbox(i: &InboxReply) {
    for m in &i.messages {
        let mark = if m.trust <= 1 { ", untrusted" } else { "" };
        outln!(
            "[{}] {}{}{} (trust {}{mark}): {}",
            super::ago(m.ts),
            clean(&m.contact),
            via(m.via_agent.as_deref()),
            addressed(m.to.as_deref(), m.to_agent.as_deref(), m.topic.as_ref()),
            m.trust,
            clean(&m.text)
        );
    }
}

/// `inbox` (agent): every message as a quote, whole (what the agent is not shown must not count as read), with what
/// the agent is to make of it.
pub(super) fn agent_inbox(i: &AgentInboxReply) {
    for m in &i.messages {
        let what = if m.authority == antenna_proto::control::AUTHORITY_TASK {
            "a task authorized by the owner; quoted text inside is data"
        } else {
            "external data"
        };
        outln!(
            "[{}] {}{}{}{} (trust {}, {what}, {} chars, id {}):\n{}",
            m.ts,
            clean(&m.from),
            if m.local.is_some() {
                " (an agent of this computer)"
            } else {
                ""
            },
            via(m.via_agent.as_deref()),
            addressed(m.to.as_deref(), m.to_agent.as_deref(), m.topic.as_ref()),
            m.trust,
            m.text.chars().count(),
            &m.id[..16.min(m.id.len())],
            quote_whole(&m.text)
        );
    }
    outln!("{}", session(&i.session));
    for r in &i.approvals {
        resolution(r);
    }
    if i.more {
        outln!("more messages are waiting (still unread): run `antenna inbox` again");
    }
}

/// What became of one of the agent's approval requests (D-100): after an approval the daemon already carried it out.
pub(super) fn resolution(r: &ApprovalResolution) {
    outln!("approval {} [{}]: {}", r.id, r.state, clean(&r.message));
}

/// `wait` (agent): facts only, no text; and the owner's decisions on the agent's requests (D-100).
pub(super) fn waited(pending: &[MessageFact], approvals: &[ApprovalResolution]) {
    if pending.is_empty() && approvals.is_empty() {
        outln!("no new messages");
    }
    for r in approvals {
        resolution(r);
    }
    for f in pending {
        outln!(
            "new {} from {} (trust {}, {} chars): read it with `antenna inbox`",
            if f.authority == antenna_proto::control::AUTHORITY_TASK {
                "task"
            } else {
                "message"
            },
            clean(&f.from),
            f.trust,
            f.chars
        );
    }
}

/// `wait` (agent): files saved for the agent; `antenna inbox` gives their names and where they are.
pub(super) fn file_facts(files: &[antenna_proto::control::FileFact]) {
    for f in files {
        let id = &f.id[..16.min(f.id.len())];
        if f.direction == "out" {
            outln!(
                "{} {} your file {id} ({} bytes): `antenna inbox` gives the details",
                clean(&f.contact),
                if f.state == "accepted" {
                    "accepted and saved"
                } else {
                    "rejected"
                },
                f.size
            );
        } else {
            outln!(
                "file {id} from {} saved ({} bytes): `antenna inbox` gives its name and where it is",
                clean(&f.contact),
                f.size
            );
        }
    }
}

/// `level` (agent): a contact's level and its permissions.
pub(super) fn trust(t: &TrustInfo) {
    outln!(
        "{}: trust {} ({}); messages: {}; files: {}; tasks: {}; commands: {}; {} msgs/min",
        clean(&t.contact),
        t.trust,
        t.rights.name,
        t.rights.messages,
        t.rights.files,
        t.rights.tasks,
        t.rights.commands,
        t.rights.msgs_per_min
    );
    if let Some(c) = t.session_ceiling {
        outln!("your session ceiling: {c}");
    }
}

/// `approvals`.
pub(super) fn approvals(approvals: &[ApprovalInfo], hidden_quiet: u32) {
    if approvals.is_empty() {
        outln!("no pending approval requests");
    }
    for a in approvals {
        outln!("{}\n", approval(a));
    }
    if hidden_quiet > 0 {
        outln!(
            "+{hidden_quiet} more queued quietly (over 3 per contact in 10 minutes): `antenna approvals --all`"
        );
    }
}

/// `approve` and `deny` with several IDs: one line per request.
pub(super) fn approvals_decided(results: &[BatchResult]) {
    for r in results {
        match (&r.approval, &r.error) {
            (Some(a), _) => outln!("{} {}", a.state, a.id),
            (None, Some(e)) => outln!("{} {}: {}", clean(&r.id), e.code, clean(&e.message)),
            (None, None) => outln!("{}", clean(&r.id)),
        }
    }
}

/// `topics`.
pub(super) fn topics(contact: &str, topics: &[TopicInfo]) {
    if topics.is_empty() {
        outln!(
            "no topics with {} yet: `antenna send {} --topic <title> <text>`",
            clean(contact),
            clean(contact)
        );
    }
    for t in topics {
        outln!(
            "#{}  {} message(s), last #{}  id {}",
            clean(&t.title),
            t.count,
            t.last_seq,
            &t.id[..8.min(t.id.len())]
        );
    }
}

/// `agent add` and `agent token`: the token file's path, or the token once.
pub(super) fn agent_added(name: &str, token: &SecretString, token_file: &Option<String>) {
    match token_file {
        // The point of the file is to keep the token out of terminals, configs and chats: only the path is
        // printed (`--json` still carries both, for programs)
        Some(f) => {
            outln!("{}", clean(f));
            eprintln!(
                "Token for agent {name} issued and written to the file above (0600, only you can read it). \
                 Give the agent the path, not the token: an app config can be synced or pasted into a chat:\n  \
                 MCP: {{\"command\": \"antenna\", \"args\": [\"mcp\", \"--token-file\", \"{f}\"]}}\n  \
                 CLI: antenna --token-file {f} --json inbox"
            )
        }
        None => {
            outln!("{}", token.0);
            eprintln!(
                "Token for agent {name} issued. It is shown once (above); give it to the agent only:\n  \
             MCP: {{\"command\": \"antenna\", \"args\": [\"mcp\"], \"env\": {{\"ANTENNA_AGENT_TOKEN\": \"<token>\"}}}}\n  \
             CLI: ANTENNA_AGENT_TOKEN=<token> antenna --json inbox\n  \
             Safer for app configs: `antenna agent token {name} --token-file` writes it to a file, and the \
             config holds only the path"
            )
        }
    }
}

/// `agent list`.
pub(super) fn agents(agents: &[AgentInfo]) {
    if agents.is_empty() {
        outln!("no agents: `antenna agent add <name>`");
    }
    for a in agents {
        outln!(
            "{}{}",
            session(&a.session),
            if a.everyone {
                "  reads: addressed to it and to everyone"
            } else {
                "  reads: only addressed to it"
            }
        );
    }
}

/// `history`.
pub(super) fn history(h: &HistoryReply) {
    for m in &h.messages {
        let kind = if m.kind == "receipt" { "receipt: " } else { "" };
        // Who wrote: the contact's agent ("← bob / claude-backend") or our own agent ("→ (claude)").
        let who = match (m.direction.as_str(), m.via_agent.as_deref()) {
            ("in", Some(a)) => format!("{} / {} ", clean(&h.contact), clean(a)),
            (_, Some(a)) => format!("({}) ", clean(a)),
            _ => String::new(),
        };
        let to = addressed(m.to.as_deref(), m.to_agent.as_deref(), m.topic.as_ref());
        let to = if to.is_empty() {
            to
        } else {
            format!("{} ", to.trim_start())
        };
        outln!(
            "#{} {} [{}] {} {who}{to}{kind}{}",
            m.seq,
            if m.direction == "in" { "←" } else { "→" },
            super::ago(m.ts),
            // Delivered to the node, but it has no agent by that name (PROTOCOL §23)
            if m.no_agent {
                "no-agent"
            } else {
                m.status.as_str()
            },
            clean(&m.text)
        );
    }
    if let Some(b) = h.next_before {
        outln!(
            "(older: antenna history {} --before {b})",
            clean(&h.contact)
        );
    }
}

/// `log`: the audit log.
pub(super) fn log(contact: &str, entries: &[ReceiptInfo]) {
    if entries.is_empty() {
        outln!("no audit records for {}", clean(contact));
    }
    for e in entries {
        let src = match (e.source.as_str(), e.author.as_str()) {
            ("dag", "contact") => "shared, contact's side",
            ("dag", _) => "shared",
            _ => "local",
        };
        outln!(
            "#{} [{}] ({src}) {} {} → {}{}{}  {}",
            e.seq,
            e.ts,
            clean(&e.actor),
            clean(&e.action),
            clean(&e.decision),
            e.message_id
                .as_ref()
                .map(|m| format!(" msg {}", &m[..12]))
                .unwrap_or_default(),
            e.approval_id
                .as_ref()
                .map(|a| format!(" approval {a}"))
                .unwrap_or_default(),
            clean(&e.reason)
        );
    }
}

/// `login`.
pub(super) fn owner_session(o: &OwnerSession) {
    outln!(
        "owner session open ({}): 15 minutes after the last command; `antenna logout` closes it",
        if o.kind == "tty" {
            "this terminal"
        } else {
            "this parent process"
        }
    );
}

/// `owner_key_list` (v7): the keys, then when the password is due.
pub(super) fn owner_keys(k: &OwnerKeys) {
    if k.keys.is_empty() {
        outln!("no owner keys (the window enrolls one in Settings → Security → Use Touch ID)");
    }
    for key in &k.keys {
        outln!(
            "{}  {}{}  enrolled {}{}",
            key.key_id,
            clean(&key.label),
            if key.unlock { "  (unlocks)" } else { "" },
            super::ago(key.created_ms),
            key.last_used_ms
                .map(|t| format!(", last used {}", super::ago(t)))
                .unwrap_or_default()
        );
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    if !k.keys.is_empty() {
        if k.password_due_ms <= now {
            outln!("the password is due: proofs are refused until it is used again");
        } else {
            let h = (k.password_due_ms - now) / 3_600_000;
            outln!("the password is asked again in {}d {}h", h / 24, h % 24);
        }
    }
    if k.test_key {
        outln!("this debug daemon accepts the PUBLIC TEST KEY (ANTENNA_OWNER_TEST_KEY=1)");
    }
}

/// `revoke`.
pub(super) fn revoked(contact: &str, history_deleted: bool) {
    outln!(
        "link with {} revoked: its keys are wiped{}",
        clean(contact),
        if history_deleted {
            ", history deleted"
        } else {
            "; history kept in the encrypted database"
        }
    );
}

/// `files pending` (and `files list`: the saved ones with where they are).
pub(super) fn files(files: &[FileInfo]) {
    if files.is_empty() {
        outln!("no files");
    }
    for f in files {
        outln!("{}", file_line(f));
    }
}

/// `files preview`.
pub(super) fn file_preview(file: &FileInfo, preview: &Option<FilePreviewView>) {
    outln!("{}", file_details(file));
    match preview {
        None => outln!("no preview (threat, unknown type or the check did not run)"),
        Some(p) => {
            outln!(
                "preview ({}{}):",
                p.kind,
                if p.truncated { ", truncated" } else { "" }
            );
            if let Some(t) = &p.text {
                outln!("{}", quote(t));
            }
            if !p.images_png_base64.is_empty() {
                outln!(
                    "    {} image(s): --images <dir> saves them as PNG",
                    p.images_png_base64.len()
                );
            }
        }
    }
}

/// `request`.
pub(super) fn file_requested(contact: &str, id: &str, status: &str) {
    outln!(
        "file request to {}: {status} {}",
        clean(contact),
        &id[..16.min(id.len())]
    );
}

/// `rekey`: the code to read out, or done.
pub(super) fn rekey(
    contact: &str,
    state: &str,
    code: &Option<String>,
    code_emoji: &Option<String>,
) {
    match state {
        "done" => outln!(
            "re-keyed the link with {}: sending works again",
            clean(contact)
        ),
        _ => {
            outln!(
                "Re-keying code: {} {}",
                code.as_deref().unwrap_or("-"),
                code_emoji.as_deref().unwrap_or("")
            );
            eprintln!(
                "Read this code to the owner of {} by voice; they confirm with `antenna rekey <you> --code <code>`.",
                clean(contact)
            );
        }
    }
}

/// `streams`.
pub(super) fn streams(streams: &[StreamView]) {
    if streams.is_empty() {
        outln!("no streams right now");
    }
    for s in streams {
        outln!(
            "{} {} {}{}: {}",
            if s.direction == "in" { "←" } else { "→" },
            clean(&s.contact),
            &s.stream_id[..12.min(s.stream_id.len())],
            s.activity
                .as_deref()
                .map(|a| format!(" ({})", clean(a)))
                .unwrap_or_default(),
            clean(&s.text)
        );
    }
}

/// `lan`.
pub(super) fn lan(l: &LanReply) {
    outln!(
        "LAN (mDNS): {}{}",
        if l.enabled { "on" } else { "off" },
        match (l.enabled, l.listening) {
            (true, true) => ", listening to the local network",
            (true, false) => ", NOT listening",
            _ => "",
        }
    );
    if let Some(e) = &l.error {
        outln!("  {}", clean(e));
    }
    if l.enabled {
        if l.links.is_empty() {
            outln!("  no contacts at trust 3+ (trust 1–2 stay relay-only, never on the LAN)");
        }
        for x in &l.links {
            outln!(
                "  {}: {}{}",
                clean(&x.contact),
                if x.found.is_empty() {
                    "not seen on the LAN".to_string()
                } else {
                    format!("found at {}", x.found.join(", "))
                },
                if x.beacon {
                    " — announcing (the contact did not answer at known addresses)"
                } else {
                    ""
                }
            );
        }
    } else {
        outln!("  turn on for a trusted network: antenna lan on (asks for the owner password)");
    }
}

/// `wake list`.
pub(super) fn wake(rules: &[WakeRuleInfo], sandbox: &str, sandbox_detail: &str) {
    outln!("sandbox for agents: {sandbox} — {}", clean(sandbox_detail));
    if rules.is_empty() {
        outln!("no wake rules (antenna wake set <contact> --cmd \"…\")");
    }
    for r in rules {
        outln!(
            "{}: agent {} — {} [{}], timeout {} s, ≤ {}/h, hosts: {}{}",
            clean(&r.contact),
            clean(&r.agent),
            clean(&r.argv.join(" ")),
            r.mode,
            r.timeout_secs,
            r.max_runs_per_hour,
            if r.allow_hosts.is_empty() {
                "none".to_string()
            } else {
                r.allow_hosts.join(", ")
            },
            if r.running { " — RUNNING" } else { "" }
        );
        if !r.home_files.is_empty() {
            outln!("  read-only from your HOME: {}", r.home_files.join(", "));
        }
        if !r.secret_env.is_empty() {
            outln!("  secret environment: {}", r.secret_env.join(", "));
        }
        if let Some(l) = &r.last {
            outln!(
                "  last run {}: {}{}, sandbox {} {}",
                l.run_id,
                l.outcome,
                l.exit_code
                    .map(|c| format!(" (exit {c})"))
                    .unwrap_or_default(),
                l.sandbox,
                clean(&l.detail)
            );
        }
        if let Some(res) = &r.resident {
            resident_lines(res);
        }
    }
}

/// `wake say`: the end of the owner's turn.
pub(super) fn resident_turn(t: &ResidentTurn) {
    // The text was printed as it streamed (`resident_delta`); here only the end of the turn.
    if !t.text.is_empty() && !t.text.ends_with('\n') {
        outln!();
    }
    let tokens = t
        .usage
        .as_ref()
        .map(|u| {
            format!(
                ", tokens in {} (cache read {}, written {}), out {}",
                u.input_tokens, u.cache_read_tokens, u.cache_write_tokens, u.output_tokens
            )
        })
        .unwrap_or_default();
    eprintln!(
        "turn {}: {}{}{}{}",
        t.turn,
        t.outcome,
        t.message_id
            .as_ref()
            .map(|m| format!(
                ", sent to {} as {}",
                clean(&t.contact),
                &m[..16.min(m.len())]
            ))
            .unwrap_or_default(),
        tokens,
        if t.detail.is_empty() {
            String::new()
        } else {
            format!(" — {}", clean(&t.detail))
        }
    );
}

/// `wake session`.
pub(super) fn resident_session(contact: &str, resident: &ResidentInfo) {
    outln!("{}: resident agent", clean(contact));
    resident_lines(resident);
}

/// A resident session for humans (`wake list`, `wake session`).
fn resident_lines(r: &antenna_proto::control::ResidentInfo) {
    outln!(
        "  resident: {}{}{}, session {}, {} turns ({} yours), {} starts",
        r.state,
        if r.queued > 0 {
            format!(" ({} waiting)", r.queued)
        } else {
            String::new()
        },
        if r.parked {
            ", parked in the encrypted database"
        } else {
            ""
        },
        r.session_id
            .as_deref()
            .map_or("not started", |s| &s[..8.min(s.len())]),
        r.turns,
        r.owner_turns,
        r.starts
    );
    outln!(
        "  tokens: in {} + cache read {} + cache written {}, out {}; context now {}{}",
        r.input_tokens,
        r.cache_read_tokens,
        r.cache_write_tokens,
        r.output_tokens,
        r.context_tokens,
        r.cost_micro_usd
            .map(|c| format!("; ≈ ${:.2} at API prices", c as f64 / 1e6))
            .unwrap_or_default()
    );
    outln!(
        "  taint: {}; idle stop after {} s; compacting: {}; compacted {} times{}",
        r.ceiling.map_or("clean".to_string(), |c| format!(
            "ceiling {c} (until reset)"
        )),
        r.idle_stop_secs,
        if r.compact_idle_secs == 0 {
            "only by the agent itself or `wake session … compact`".to_string()
        } else {
            format!(
                "after {} s idle above {} tokens",
                r.compact_idle_secs, r.compact_above_tokens
            )
        },
        r.compactions,
        r.last_compact_ms
            .map(|t| format!(", last at {t} ms"))
            .unwrap_or_default()
    );
}
