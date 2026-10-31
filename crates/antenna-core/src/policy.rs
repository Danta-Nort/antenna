// SPDX-License-Identifier: AGPL-3.0-only
//! Policy engine (SPEC §9): levels 1–3 of the MVP (4 behaves like 3 plus the deferred sandbox; 5 is the owner's own
//! computer, D-99), taint, "no write down", link isolation, secret scanner, limits, approval requests bound to the
//! request hash, and what the daemon did with an approved request it carries out itself (D-100).
//!
//! Permissions are checked by the daemon, not by an LLM: this module holds only deterministic functions of the session
//! state and the request. All time is passed as the `now` parameter (Unix ms), so the deadlines (10 minutes for an
//! approval, limit windows) are checked by unit tests without waiting.
//!
//! What the daemon **knows** and what it **does not** (SPEC §11 "two sandboxes"), see DECISIONS D-29:
//! - it knows everything the agent got through the daemon (`read_inbox` → taint by contact) and everything the agent
//!   sends through it;
//! - it does not know which local files the agent read bypassing the daemon. For that there is a base session label
//!   from the owner (`antenna agent add --local-level`) and declarations (`mark_read`, agent hooks); the label only
//!   grows.

use std::collections::{BTreeMap, HashMap, VecDeque};

use antenna_proto::{
    LinkId,
    control::{ApprovalInfo, DecidedBy, DelegateNote, Grants, Reply, Rights, code},
};

use crate::{
    crypto,
    error::{Error, Result},
};

// Levels and permissions (SPEC §9)

/// Message limit per minute by level (SPEC §9; level 5 is "configurable", 600 for now).
pub fn msgs_per_min(level: u8) -> u32 {
    match level {
        0 | 1 => 10,
        2 => 30,
        3 => 60,
        4 => 120,
        _ => 600,
    }
}

/// Level permissions (SPEC §9, table), structured: for the agent (`get_trust`) and the approval screen.
pub fn rights(level: u8) -> Rights {
    let (name, messages, files, tasks, commands) = match level {
        0 | 1 => (
            "observer",
            "text; incoming marked untrusted",
            "none",
            "none: the agent only replies with words",
            "none",
        ),
        2 => (
            "acquaintance",
            "text",
            "incoming into quarantine inbox/ (slice 4)",
            "only after the owner approves",
            "none",
        ),
        3 => (
            "colleague",
            "text",
            "read-only shared/ of the link; exchange in shared/ (slice 4)",
            "read-only tools; writes after approve",
            "none",
        ),
        4 => (
            "partner",
            "text",
            "read/write shared/ (slice 4)",
            "without confirmation",
            "allowlist in sandbox (v0.2; until then: owner approve)",
        ),
        // D-99: the owner's own computer
        _ => (
            "own",
            "text; secrets too, without approval (the owner's own computer)",
            "project folder set by the owner (without one: shared/); files with secrets and suspicious files too, \
             without approval; incoming clean and suspicious files are accepted automatically",
            "without confirmation within scope",
            "any, without confirmation (each one in the audit log; no command sandbox yet)",
        ),
    };
    Rights {
        level,
        name: name.into(),
        messages: messages.into(),
        files: files.into(),
        tasks: tasks.into(),
        commands: commands.into(),
        msgs_per_min: msgs_per_min(level),
    }
}

/// Trust level 5, "Self": the owner's own computer (D-99, a SPEC §9 amendment by the maintainer, 2026-10-05). The owner
/// chose it after a warning, so what protects against another person does not wait for approval here.
pub const OWN_COMPUTER: u8 = 5;

/// Approval reasons that trust level 5 waives (D-99): secrets in a message, a stream, a file's content or name, a file
/// from outside the link folder, the sender-side check's verdict, a "suspicious" verdict or a dot-file name on
/// accept. Everything else stays: taint from lower-level data (the session ceiling), the flow between links, level
/// limits, and a threat found by the receiver's check (it stays in quarantine for the owner).
pub fn waived_at_level_5(reason: &str) -> bool {
    reason.starts_with("secret")
        || reason == "file_outside_link_folder"
        || reason.starts_with("sender_check:")
        || reason == "check:suspicious"
        || reason.starts_with("special_name:")
}

/// Split approval reasons for an action toward a contact at `level` into those that still need the owner and those
/// waived at trust level 5 (which the caller writes to the audit log). Below level 5 nothing is waived.
pub fn split_level_5(level: u8, reasons: Vec<String>) -> (Vec<String>, Vec<String>) {
    if level < OWN_COMPUTER {
        return (reasons, Vec::new());
    }
    reasons.into_iter().partition(|r| !waived_at_level_5(r))
}

/// Policy verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Allowed.
    Allow,
    /// Allowed only after owner approval; machine-readable reasons.
    Approve(Vec<String>),
    /// Not allowed at this level (approval does not help).
    Deny(String),
}

impl Verdict {
    /// Combine: deny beats approval, approval beats "allowed"; approval reasons add up.
    pub fn and(self, other: Verdict) -> Verdict {
        match (self, other) {
            (Verdict::Deny(r), _) | (_, Verdict::Deny(r)) => Verdict::Deny(r),
            (Verdict::Approve(mut a), Verdict::Approve(b)) => {
                a.extend(b);
                Verdict::Approve(a)
            }
            (Verdict::Approve(a), Verdict::Allow) | (Verdict::Allow, Verdict::Approve(a)) => {
                Verdict::Approve(a)
            }
            (Verdict::Allow, Verdict::Allow) => Verdict::Allow,
        }
    }
}

/// Class of an agent action that the daemon does not perform itself but is asked about by the agent's hook
/// (`antenna check`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Read-only tools (reading files, search).
    Read,
    /// Writing local files.
    Write,
    /// Running commands.
    Exec,
}

impl Action {
    /// Parse `read` / `write` / `exec`.
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "read" => Ok(Action::Read),
            "write" => Ok(Action::Write),
            "exec" => Ok(Action::Exec),
            _ => Err(Error::bad_request(
                "action must be one of: read, write, exec",
            )),
        }
    }

    /// Name.
    pub fn as_str(&self) -> &'static str {
        match self {
            Action::Read => "read",
            Action::Write => "write",
            Action::Exec => "exec",
        }
    }
}

/// An action under the session's permission ceiling (taint, "no read up"): SPEC §9, the "Tasks for the agent" and
/// "Commands" columns. `ceiling = None` means the session has not read contact data and acts on the owner's behalf.
pub fn check_action(ceiling: Option<u8>, action: Action) -> Verdict {
    check_action_on(ceiling, action, "")
}

/// Paths a tainted session does not change without approval at any level: agent memory and instructions, tool and
/// shell configs, keys (SPEC §9 "Taint outlives the session").
const PROTECTED_PATHS: &[&str] = &[
    "claude.md",
    "agents.md",
    "gemini.md",
    ".claude/",
    ".codex/",
    ".cursor/",
    ".gemini/",
    ".git/",
    ".github/",
    ".vscode/",
    ".envrc",
    ".bashrc",
    ".zshrc",
    ".profile",
    ".bash_profile",
    ".ssh/",
    ".gnupg/",
    ".config/",
    ".local/share/antenna/",
    // Data directory of pre-release `x` builds (if it was never migrated)
    ".local/share/x/",
    // macOS (PORTABILITY M-17): MCP host configs with tokens, autostart, zsh files
    "library/application support/claude/",
    "library/application support/code/user/",
    "library/application support/cursor/user/",
    "library/launchagents/",
    ".zprofile",
    ".zshenv",
    ".zlogin",
    "makefile",
    "package.json",
    "cargo.toml",
    "build.rs",
];

/// The links folder (SPEC §10: `~/Antenna/links/<contact>/`) is the only place a tainted session writes to without
/// approval. Default path; when the daemon has files enabled, the folder comes from `--links-dir` (`check_action_at`).
pub fn in_link_folder(path: &str) -> bool {
    let p = path.replace('\\', "/");
    if p.contains("..") || p.contains("/./") {
        return false;
    }
    // Only the owner's real links folder: `~/Antenna/links/…` or `$HOME/Antenna/links/…` (symbolic links inside are
    // not canonicalized: the path may not exist yet; `check` is advisory, CONTROL §11)
    let home = std::env::var("HOME").unwrap_or_default();
    p.starts_with("~/Antenna/links/")
        || (!home.is_empty() && p.starts_with(&format!("{home}/Antenna/links/")))
}

fn protected(path: &str) -> bool {
    let p = path.replace('\\', "/").to_lowercase();
    PROTECTED_PATHS.iter().any(|m| {
        p.ends_with(m.trim_end_matches('/')) || p.contains(&format!("/{m}")) || p.starts_with(m)
    })
}

/// [`check_action`] taking the path (`detail`) into account for writes: a tainted session writes without approval
/// only to the links folder; agent memory, CLAUDE.md, configs and project files need owner approval.
pub fn check_action_on(ceiling: Option<u8>, action: Action, detail: &str) -> Verdict {
    check_action_at(ceiling, action, detail, in_link_folder(detail))
}

/// [`check_action_on`] when the daemon itself knows whether the path is in the links folder (`--links-dir`, D-F-19).
pub fn check_action_at(
    ceiling: Option<u8>,
    action: Action,
    detail: &str,
    in_links: bool,
) -> Verdict {
    let Some(l) = ceiling else {
        return Verdict::Allow;
    };
    if action == Action::Write && l >= 2 && !in_links {
        let protected = protected(detail);
        // Level 5 (D-99): tasks from the owner's own computer run without confirmation within the scope; agent memory,
        // instructions, configs and keys still need the owner
        if l >= OWN_COMPUTER && !protected {
            return Verdict::Allow;
        }
        let why = if protected {
            "tainted:protected_path"
        } else {
            "tainted:writes_outside_link_folder"
        };
        return match l {
            2 | 3 => Verdict::Approve(vec![
                format!("tainted:level_{l}:writes_need_approve"),
                why.into(),
            ]),
            _ => Verdict::Approve(vec![why.into()]),
        };
    }
    match action {
        Action::Read => match l {
            0 | 1 => Verdict::Deny(format!("tainted:level_{l}:only_words")),
            2 => Verdict::Approve(vec![format!("tainted:level_{l}:tasks_need_approve")]),
            _ => Verdict::Allow,
        },
        Action::Write => match l {
            0 | 1 => Verdict::Deny(format!("tainted:level_{l}:only_words")),
            2 | 3 => Verdict::Approve(vec![format!("tainted:level_{l}:writes_need_approve")]),
            _ => Verdict::Allow,
        },
        Action::Exec => match l {
            0..=3 => Verdict::Deny(format!("tainted:level_{l}:no_commands_below_4")),
            4 => Verdict::Approve(vec![format!(
                "tainted:level_{l}:commands_need_sandbox_v0.2"
            )]),
            // Level 5 (D-99): SPEC §9 "tasks without confirmation"; the daemon writes each one to the audit log
            _ => Verdict::Allow,
        },
    }
}

/// Agent session label.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Label {
    /// Taint (integrity): links whose **incoming** messages the session has read, and their level at the time of
    /// reading.
    pub taint: BTreeMap<LinkId, u8>,
    /// Confidentiality: all links whose data the session has read (incoming or the owner's outgoing).
    pub read: std::collections::BTreeSet<LinkId>,
    /// Local data label (0: has read nothing local beyond its own links).
    pub local_level: u8,
}

impl Label {
    /// Permission ceiling: the minimum of the level at reading time and the current one (`current`) over all read
    /// links.
    pub fn ceiling(&self, current: impl Fn(&LinkId) -> Option<u8>) -> Option<u8> {
        self.taint
            .iter()
            .map(|(l, at_read)| current(l).map_or(*at_read, |c| c.min(*at_read)))
            .min()
    }
}

/// Reasons why an outgoing message from the session to link `target` (of level `target_level`) needs approval:
/// link isolation, "no write down", secrets. An empty list means allowed.
pub fn outflow_reasons(
    label: &Label,
    target: &LinkId,
    target_level: u8,
    payload: &str,
    names: impl Fn(&LinkId) -> String,
) -> Vec<String> {
    let mut r = Vec::new();
    let others: Vec<String> = label
        .read
        .iter()
        .chain(label.taint.keys())
        .filter(|l| *l != target)
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .map(&names)
        .collect();
    if !others.is_empty() {
        r.push(format!("cross_link:{}", others.join(",")));
    }
    if label.local_level > target_level {
        r.push(format!(
            "no_write_down:local_{}>contact_{target_level}",
            label.local_level
        ));
    }
    for k in scan_secrets(payload) {
        r.push(format!("secret:{k}"));
    }
    r
}

/// Sending a file to a contact: level 1 no, level 2 owner approval; the session ceiling as for reading.
pub fn share_file(ceiling: Option<u8>, target_level: u8) -> Verdict {
    let to = match target_level {
        0 | 1 => Verdict::Deny("level_1_gets_no_files".into()),
        2 => Verdict::Approve(vec!["files_to_level_2_need_approve".into()]),
        _ => Verdict::Allow,
    };
    to.and(check_action(ceiling, Action::Read))
}

/// Requesting a file from the contact's `shared/`: read-only access to `shared/` from level 3.
pub fn request_file(ceiling: Option<u8>, target_level: u8) -> Verdict {
    let to = if target_level < 3 {
        Verdict::Deny("shared_is_readable_from_level_3".into())
    } else {
        Verdict::Allow
    };
    to.and(check_action(ceiling, Action::Read))
}

// Secret scanner (SPEC §9: "outgoing messages are scanned for secrets and blocked until approval at any level")

// The scanner moved to `antenna_files::secrets` (slice 4): the same code checks both messages and files (sandbox
// worker).
pub use antenna_files::secrets::{SecretStream, StreamStep, floor_boundary, scan_secrets};
pub use antenna_files::text::is_invisible;

// Limits (sliding window)

/// Message limit window.
pub const RATE_WINDOW_MS: u64 = 60_000;

/// Sliding window "at most N events per window" by key.
#[derive(Debug, Default)]
pub struct RateLimiter {
    hits: HashMap<LinkId, VecDeque<u64>>,
}

impl RateLimiter {
    /// Whether there is room (without counting the event). Otherwise, in how many ms it frees up.
    pub fn check(&mut self, key: LinkId, limit: u32, now: u64) -> std::result::Result<(), u64> {
        let q = self.hits.entry(key).or_default();
        while q
            .front()
            .is_some_and(|t| now.saturating_sub(*t) >= RATE_WINDOW_MS)
        {
            q.pop_front();
        }
        match q.front() {
            Some(oldest) if q.len() as u32 >= limit => {
                Err((oldest + RATE_WINDOW_MS).saturating_sub(now).max(1))
            }
            _ => Ok(()),
        }
    }

    /// Return the last counted event (the action did not happen).
    pub fn refund(&mut self, key: LinkId) {
        if let Some(q) = self.hits.get_mut(&key) {
            q.pop_back();
        }
    }

    /// Count the event if the limit allows. Otherwise, in how many ms room frees up.
    pub fn try_acquire(
        &mut self,
        key: LinkId,
        limit: u32,
        now: u64,
    ) -> std::result::Result<(), u64> {
        let q = self.hits.entry(key).or_default();
        while q
            .front()
            .is_some_and(|t| now.saturating_sub(*t) >= RATE_WINDOW_MS)
        {
            q.pop_front();
        }
        if q.len() as u32 >= limit {
            let oldest = *q.front().expect("limit > 0 means non-empty");
            return Err((oldest + RATE_WINDOW_MS).saturating_sub(now).max(1));
        }
        q.push_back(now);
        Ok(())
    }
}

// Approval requests (SPEC §9): request hash + nonce + 10 minutes, single use, ≤ 3 notifications from a contact per 10
// minutes

/// Approval lifetime.
pub const APPROVAL_TTL_MS: u64 = 10 * 60 * 1000;
/// Notification limit window.
pub const APPROVAL_WINDOW_MS: u64 = 10 * 60 * 1000;
/// Notifications from one contact per window.
pub const APPROVALS_PER_WINDOW: usize = 3;
/// "Reject everything from the contact for an hour".
pub const DENY_HOUR_MS: u64 = 3600 * 1000;
/// How long to keep decided requests (for `antenna approvals --all`).
const KEEP_MS: u64 = 3600 * 1000;

const REQUEST_LABEL: &[u8] = b"x/approve/v0/request";
const BINDING_LABEL: &[u8] = b"x/approve/v0/binding";

/// Request hash: who asks, which action, on which link, what exactly (text / command / path).
pub fn request_hash(
    requester_id: &str,
    action: &str,
    target: Option<&LinkId>,
    payload: &[u8],
) -> [u8; 32] {
    let t = target.map(|l| l.0.to_vec()).unwrap_or_default();
    crypto::sha256(&[
        REQUEST_LABEL,
        &crypto::lp(requester_id.as_bytes()),
        &crypto::lp(action.as_bytes()),
        &crypto::lp(&t),
        &crypto::lp(payload),
    ])
}

fn binding(nonce: &[u8; 16], request_hash: &[u8; 32]) -> [u8; 32] {
    crypto::sha256(&[BINDING_LABEL, nonce, request_hash])
}

/// New approval request.
#[derive(Debug, Clone)]
pub struct NewApproval {
    /// Stable ID of the requester (`agent:<id>` or `owner`).
    pub requester_id: String,
    /// Display name.
    pub requester: String,
    /// The contact the request relates to (for the limit and "reject for an hour").
    pub contact: LinkId,
    /// Its label.
    pub contact_label: String,
    /// Its level.
    pub contact_trust: u8,
    /// Action.
    pub action: String,
    /// To whom (label), if this is a send.
    pub target: Option<String>,
    /// The recipient's link, if this is a send (where the window shows the request).
    pub target_link: Option<LinkId>,
    /// Reasons.
    pub reasons: Vec<String>,
    /// What will be allowed.
    pub grants: Grants,
    /// Text/details, only as a quote.
    pub quote: String,
    /// [`request_hash`].
    pub request_hash: [u8; 32],
    /// After approval the daemon carries out the request itself (D-100; [`ApprovalInfo::completes`]).
    pub completes: bool,
}

/// What an approved request the daemon carried out itself returned: the reply of the action or its error (D-100).
pub type Outcome = std::result::Result<Box<Reply>, Error>;

/// The daemon's part in an approved request (D-100).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Completion {
    /// The daemon does not carry it out (or has not started).
    Idle,
    /// The daemon is carrying it out now.
    Running,
    /// The daemon carried it out: a repeat of exactly this request gets this result instead of running again.
    Done(Outcome),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Pending,
    Approved,
    Denied,
    Used,
    /// Pending or approved, and its 10 minutes ran out: closed by [`Approvals::expire_due`] (D-84).
    Expired,
}

#[derive(Debug, Clone)]
struct Approval {
    id: String,
    nonce: [u8; 16],
    binding: [u8; 32],
    req: NewApproval,
    created: u64,
    expires: u64,
    state: State,
    quiet: bool,
    completion: Completion,
    /// An approver decided it in the owner's place (PG-57).
    decided_by: Option<DecidedBy>,
    /// The latest answer of an agent that did not count (PG-57).
    refused: Option<DelegateNote>,
}

impl Approval {
    fn info(&self, now: u64) -> ApprovalInfo {
        let state = match self.state {
            State::Pending | State::Approved if now >= self.expires => "expired",
            State::Pending => "pending",
            State::Approved => "approved",
            State::Denied => "denied",
            State::Used => "used",
            State::Expired => "expired",
        };
        ApprovalInfo {
            id: self.id.clone(),
            state: state.into(),
            quiet: self.quiet,
            requester: self.req.requester.clone(),
            contact: self.req.contact_label.clone(),
            contact_trust: self.req.contact_trust,
            action: self.req.action.clone(),
            target: self.req.target.clone(),
            reasons: self.req.reasons.clone(),
            grants: self.req.grants.clone(),
            quote: self.req.quote.clone(),
            fingerprint: data_encoding::HEXLOWER.encode(&self.binding[..8]),
            created_ms: self.created,
            expires_ms: self.expires,
            link_id: Some(self.req.contact.to_hex()),
            target_link_id: self.req.target_link.map(|l| l.to_hex()),
            completes: self.req.completes,
            decided_by: self.decided_by.clone(),
            delegate_refused: self.refused.clone(),
            answerable_by: Vec::new(),
        }
    }

    fn matches(&self, requester_id: &str, request_hash: &[u8; 32]) -> bool {
        self.req.requester_id == requester_id
            && crypto::ct_eq(&binding(&self.nonce, request_hash), &self.binding)
    }
}

/// Outcome of a check through approval.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Gate {
    /// Allowed: the approval (if one was needed) is used up.
    Allowed {
        /// Which approval was used up.
        approval_id: Option<String>,
    },
    /// Owner approval is needed: the request, and `true` if it was created now (rather than waiting from before).
    Required(Box<ApprovalInfo>, bool),
    /// The owner approved exactly this request and the daemon is carrying it out now (D-100): wait for it, do not
    /// run it a second time.
    Completing,
    /// The daemon already carried out exactly this approved request (D-100): its result, instead of running again.
    Done(Outcome),
}

/// Maximum number of pending requests per requester (daemon memory).
pub const MAX_PENDING_PER_REQUESTER: usize = 16;
/// Maximum number of pending requests per contact.
pub const MAX_PENDING_PER_CONTACT: usize = 32;
/// Maximum quote length in a request, characters.
pub const MAX_QUOTE: usize = 4096;

/// Approval request store (in daemon memory: a restart = all pending requests burn, which is the safe side).
#[derive(Debug)]
pub struct Approvals {
    items: Vec<Approval>,
    deny_until: HashMap<LinkId, u64>,
    /// Request lifetime: [`APPROVAL_TTL_MS`]; tests may only shorten it ([`Approvals::with_ttl`]).
    ttl_ms: u64,
}

impl Default for Approvals {
    fn default() -> Self {
        Self::with_ttl(APPROVAL_TTL_MS)
    }
}

/// A request closed by [`Approvals::expire_due`]: its contact's link, who asked (`agent:<id>` / `owner`), the request.
#[derive(Debug, Clone)]
pub struct Expired {
    /// The link of the contact the request is about (where the audit log keeps it).
    pub link: LinkId,
    /// Stable ID of the requester.
    pub requester_id: String,
    /// The request, `state: "expired"`.
    pub info: ApprovalInfo,
}

impl Approvals {
    /// A store whose requests live `ttl_ms` (at most [`APPROVAL_TTL_MS`]: a longer lifetime would weaken SPEC §9).
    pub fn with_ttl(ttl_ms: u64) -> Self {
        Self {
            items: Vec::new(),
            deny_until: HashMap::new(),
            ttl_ms: ttl_ms.clamp(1, APPROVAL_TTL_MS),
        }
    }

    fn gc(&mut self, now: u64) {
        self.items
            .retain(|a| now < a.expires.saturating_add(KEEP_MS));
        self.deny_until.retain(|_, t| *t > now);
    }

    fn find(&mut self, id: &str) -> Result<&mut Approval> {
        self.items
            .iter_mut()
            .find(|a| a.id == id)
            .ok_or_else(|| Error::new(code::NOT_FOUND, format!("no approval request {id:?}")))
    }

    /// Go through approval: use up an approval for **this** request or create a request to the owner.
    /// `approval_id`: when the requester refers to a specific approval (otherwise it is looked up by the request hash).
    /// `by_daemon`: the daemon itself is carrying out approval `approval_id` after the owner approved it (D-100); every
    /// other caller that repeats a request the daemon carries out or carried out gets [`Gate::Completing`] or
    /// [`Gate::Done`] instead of running it again.
    pub fn gate(
        &mut self,
        req: NewApproval,
        approval_id: Option<&str>,
        by_daemon: bool,
        now: u64,
    ) -> Result<Gate> {
        self.gc(now);
        if let Some(id) = approval_id {
            let a = self.find(id)?;
            if !a.matches(&req.requester_id, &req.request_hash) {
                return Err(Error::new(
                    code::APPROVAL_MISMATCH,
                    "this approval was given for a different request (text, target or action differ)",
                ));
            }
            if !by_daemon {
                match &a.completion {
                    Completion::Running => return Ok(Gate::Completing),
                    Completion::Done(o) => return Ok(Gate::Done(o.clone())),
                    Completion::Idle => {}
                }
            }
            return match a.state {
                State::Used => Err(Error::new(
                    code::APPROVAL_USED,
                    "this approval was already used; an approved request cannot be replayed",
                )),
                State::Denied => Err(Error::new(
                    code::APPROVAL_DENIED,
                    "the owner denied this request",
                )),
                State::Expired => Err(Error::new(
                    code::APPROVAL_EXPIRED,
                    "the approval expired (10 minutes)",
                )),
                _ if now >= a.expires => Err(Error::new(
                    code::APPROVAL_EXPIRED,
                    "the approval expired (10 minutes)",
                )),
                State::Pending => Err(Error::new(
                    code::APPROVAL_PENDING,
                    "the owner has not answered yet",
                )),
                State::Approved => {
                    a.state = State::Used;
                    Ok(Gate::Allowed {
                        approval_id: Some(a.id.clone()),
                    })
                }
            };
        }
        // The same request again, without the ID, while or after the daemon carried it out: the same answer, not a
        // second run and not a second request to the owner
        if let Some(g) = self.items.iter().find_map(|a| {
            (now < a.expires && a.matches(&req.requester_id, &req.request_hash))
                .then(|| match &a.completion {
                    Completion::Running => Some(Gate::Completing),
                    Completion::Done(o) => Some(Gate::Done(o.clone())),
                    Completion::Idle => None,
                })
                .flatten()
        }) {
            return Ok(g);
        }
        if let Some(a) = self.items.iter_mut().find(|a| {
            a.state == State::Approved
                && now < a.expires
                && a.matches(&req.requester_id, &req.request_hash)
        }) {
            a.state = State::Used;
            return Ok(Gate::Allowed {
                approval_id: Some(a.id.clone()),
            });
        }
        if self.deny_until.get(&req.contact).is_some_and(|t| *t > now) {
            return Err(Error::new(
                code::APPROVAL_DENIED,
                format!(
                    "the owner denies all requests related to {} for an hour",
                    req.contact_label
                ),
            ));
        }
        if let Some(a) = self.items.iter().find(|a| {
            a.state == State::Pending
                && now < a.expires
                && a.matches(&req.requester_id, &req.request_hash)
        }) {
            return Ok(Gate::Required(Box::new(a.info(now)), false));
        }
        let pending = |f: &dyn Fn(&Approval) -> bool| {
            self.items
                .iter()
                .filter(|a| a.state == State::Pending && now < a.expires && f(a))
                .count()
        };
        if pending(&|a| a.req.requester_id == req.requester_id) >= MAX_PENDING_PER_REQUESTER
            || (req.requester_id != "owner"
                && pending(&|a| a.req.contact == req.contact && a.req.requester_id != "owner")
                    >= MAX_PENDING_PER_CONTACT)
        {
            return Err(Error::new(
                code::RATE_LIMITED,
                "too many approval requests are waiting for the owner; retry after they are answered",
            ));
        }
        // ≤ 3 notifications per 10 minutes, both per contact (SPEC §9) and per requester (the agent itself chooses
        // which contact its request relates to)
        let recent = |f: &dyn Fn(&Approval) -> bool| {
            self.items
                .iter()
                .filter(|a| now.saturating_sub(a.created) < APPROVAL_WINDOW_MS && f(a))
                .count()
        };
        let quiet = recent(&|a| a.req.contact == req.contact) >= APPROVALS_PER_WINDOW
            || recent(&|a| a.req.requester_id == req.requester_id) >= APPROVALS_PER_WINDOW;
        let mut req = req;
        if req.quote.chars().count() > MAX_QUOTE {
            req.quote = req.quote.chars().take(MAX_QUOTE).collect::<String>() + " …[truncated]";
        }
        let nonce = crypto::random::<16>();
        let a = Approval {
            id: data_encoding::BASE32_NOPAD
                .encode(&crypto::random::<5>())
                .to_ascii_lowercase(),
            nonce,
            binding: binding(&nonce, &req.request_hash),
            req,
            created: now,
            expires: now + self.ttl_ms,
            state: State::Pending,
            quiet,
            completion: Completion::Idle,
            decided_by: None,
            refused: None,
        };
        let info = a.info(now);
        self.items.push(a);
        Ok(Gate::Required(Box::new(info), true))
    }

    /// A request that no longer needs approval but names one (`approval_id`), D-100: when the daemon carries out or
    /// carried out exactly this request under that approval, the same answer as [`Self::gate`] gives; otherwise
    /// `None` (the ID is ignored, as before).
    pub fn replayed(
        &self,
        id: Option<&str>,
        requester_id: &str,
        request_hash: &[u8; 32],
        by_daemon: bool,
        now: u64,
    ) -> Option<Gate> {
        if by_daemon {
            return None;
        }
        // Without the ID: exactly this request within its approval's lifetime, as in `gate`
        let a = self.items.iter().find(|a| match id {
            Some(id) => a.id == id,
            None => now < a.expires && a.completion != Completion::Idle,
        } && a.matches(requester_id, request_hash))?;
        match &a.completion {
            Completion::Running => Some(Gate::Completing),
            Completion::Done(o) => Some(Gate::Done(o.clone())),
            Completion::Idle => None,
        }
    }

    /// The daemon starts carrying out approved request `id` (D-100): only once, only while it is approved and alive.
    /// From here on every other caller that repeats it waits for the daemon's result.
    pub fn start_completion(&mut self, id: &str, now: u64) -> bool {
        match self.items.iter_mut().find(|a| a.id == id) {
            Some(a)
                if a.state == State::Approved
                    && now < a.expires
                    && a.completion == Completion::Idle =>
            {
                a.completion = Completion::Running;
                true
            }
            _ => false,
        }
    }

    /// Whether the daemon is carrying out an approved request right now (an automatic update waits for it, D-103).
    pub fn any_completing(&self) -> bool {
        self.items
            .iter()
            .any(|a| a.completion == Completion::Running)
    }

    /// The daemon's run of request `id` ended with `outcome`. If the run used the approval up, repeats of the request
    /// get this outcome; if it failed before that (the request no longer matches, the link is down), the approval
    /// stays as it was and the requester may still use it. Returns whether the approval was used up.
    pub fn finish_completion(&mut self, id: &str, outcome: Outcome) -> bool {
        let Some(a) = self.items.iter_mut().find(|a| a.id == id) else {
            return false;
        };
        if a.state == State::Used {
            a.completion = Completion::Done(outcome);
            true
        } else {
            a.completion = Completion::Idle;
            false
        }
    }

    /// An approver decided request `id` in the owner's place (PG-57): who, for the card and the requester.
    pub fn mark_delegated(&mut self, id: &str, by: DecidedBy) {
        if let Some(a) = self.items.iter_mut().find(|a| a.id == id) {
            a.decided_by = Some(by);
        }
    }

    /// An agent's answer to pending request `id` did not count (PG-57): the card says why.
    pub fn note_refused(&mut self, id: &str, note: DelegateNote) {
        if let Some(a) = self
            .items
            .iter_mut()
            .find(|a| a.id == id && a.state == State::Pending)
        {
            a.refused = Some(note);
        }
    }

    /// Current state of a request.
    pub fn get(&self, id: &str, now: u64) -> Option<ApprovalInfo> {
        self.items.iter().find(|a| a.id == id).map(|a| a.info(now))
    }

    /// Who asked (`agent:<id>` / `owner`).
    pub fn requester_of(&self, id: &str) -> Option<String> {
        self.items
            .iter()
            .find(|a| a.id == id)
            .map(|a| a.req.requester_id.clone())
    }

    /// The owner allowed it (once).
    pub fn approve(&mut self, id: &str, now: u64) -> Result<ApprovalInfo> {
        self.approve_checked(id, None, now)
    }

    /// The same, checking that the request is the one the owner was shown (`approve_many`, v6): `fingerprint` is
    /// [`ApprovalInfo::fingerprint`], the start of this request's binding (its request hash with its own nonce). The
    /// approval itself is the single one of [`Self::approve`]: it stays bound to exactly this request.
    pub fn approve_checked(
        &mut self,
        id: &str,
        fingerprint: Option<&str>,
        now: u64,
    ) -> Result<ApprovalInfo> {
        self.gc(now);
        let a = self.find(id)?;
        if let Some(f) = fingerprint {
            let mine = data_encoding::HEXLOWER.encode(&a.binding[..8]);
            if !crypto::ct_eq(mine.as_bytes(), f.to_ascii_lowercase().as_bytes()) {
                return Err(Error::new(
                    code::APPROVAL_MISMATCH,
                    "this request is not the one shown (fingerprint differs)",
                ));
            }
        }
        if a.state == State::Expired || (a.state == State::Pending && now >= a.expires) {
            return Err(Error::new(
                code::APPROVAL_EXPIRED,
                "the request expired (10 minutes)",
            ));
        }
        if a.state != State::Pending {
            return Err(Error::bad_request(format!(
                "request {id} is not pending ({})",
                a.info(now).state
            )));
        }
        a.state = State::Approved;
        Ok(a.info(now))
    }

    /// The owner refused; `hour`: also reject everything for this contact for an hour. An expired request is already
    /// closed: there is nothing left to refuse.
    pub fn deny(&mut self, id: &str, hour: bool, now: u64) -> Result<ApprovalInfo> {
        self.gc(now);
        let a = self.find(id)?;
        if a.state == State::Expired
            || (matches!(a.state, State::Pending | State::Approved) && now >= a.expires)
        {
            return Err(Error::new(
                code::APPROVAL_EXPIRED,
                "the request expired (10 minutes) and closed by itself",
            ));
        }
        if !matches!(a.state, State::Pending | State::Approved) {
            return Err(Error::bad_request(format!(
                "request {id} is already decided"
            )));
        }
        if a.completion != Completion::Idle {
            return Err(Error::bad_request(format!(
                "request {id} was approved and is being carried out"
            )));
        }
        a.state = State::Denied;
        let info = a.info(now);
        let contact = a.req.contact;
        if hour {
            self.deny_until.insert(contact, now + DENY_HOUR_MS);
        }
        Ok(info)
    }

    /// Close the requests whose lifetime ran out (pending, or approved and not used): each is returned once, for the
    /// `approval` event and the audit log (D-84). An expired request is not deleted at once: `approvals --all` shows it
    /// for another hour, like a decided one.
    pub fn expire_due(&mut self, now: u64) -> Vec<Expired> {
        let mut out = Vec::new();
        for a in &mut self.items {
            // A run of the daemon that already started (D-100) ends on its own and decides the state
            if matches!(a.state, State::Pending | State::Approved)
                && now >= a.expires
                && a.completion != Completion::Running
            {
                a.state = State::Expired;
                out.push(Expired {
                    link: a.req.contact,
                    requester_id: a.req.requester_id.clone(),
                    info: a.info(now),
                });
            }
        }
        self.gc(now);
        out
    }

    /// Requests for the owner: by default pending and not "quiet"; `all`: all of them. The second value is how many
    /// "quiet" ones are hidden.
    pub fn list(&mut self, all: bool, now: u64) -> (Vec<ApprovalInfo>, u32) {
        self.gc(now);
        let mut hidden = 0;
        let mut out = Vec::new();
        for a in &self.items {
            let i = a.info(now);
            if all {
                out.push(i);
            } else if i.state == "pending" {
                if a.quiet {
                    hidden += 1;
                } else {
                    out.push(i);
                }
            }
        }
        (out, hidden)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use antenna_files::secrets::floor_boundary;

    const BOB: LinkId = LinkId([1; 32]);
    const CAROL: LinkId = LinkId([2; 32]);

    fn new_req(contact: LinkId, text: &str) -> NewApproval {
        NewApproval {
            requester_id: "agent:1".into(),
            requester: "claude".into(),
            contact,
            contact_label: "bob".into(),
            contact_trust: 1,
            action: "send_message".into(),
            target: Some("bob".into()),
            target_link: Some(contact),
            reasons: vec!["no_write_down".into()],
            grants: Grants {
                read: "-".into(),
                write: "-".into(),
                commands: "-".into(),
                send: "text".into(),
            },
            quote: text.into(),
            request_hash: request_hash("agent:1", "send_message", Some(&contact), text.as_bytes()),
            completes: false,
        }
    }

    fn required(g: Gate) -> ApprovalInfo {
        match g {
            Gate::Required(i, _) => *i,
            other => panic!("expected Required, got {other:?}"),
        }
    }

    #[test]
    fn approval_is_bound_to_the_request_single_use_and_expires() {
        let mut s = Approvals::default();
        let t0 = 1_000_000;
        let a = required(s.gate(new_req(BOB, "hello"), None, false, t0).unwrap());
        // A pending request is not created again
        assert_eq!(
            required(s.gate(new_req(BOB, "hello"), None, false, t0 + 1).unwrap()).id,
            a.id
        );
        assert_eq!(
            s.gate(new_req(BOB, "hello"), Some(&a.id), false, t0 + 1)
                .unwrap_err()
                .code,
            code::APPROVAL_PENDING
        );
        s.approve(&a.id, t0 + 2).unwrap();
        // Different text with the same approval: not allowed
        assert_eq!(
            s.gate(new_req(BOB, "hello!"), Some(&a.id), false, t0 + 3)
                .unwrap_err()
                .code,
            code::APPROVAL_MISMATCH
        );
        assert_eq!(
            s.gate(new_req(BOB, "hello"), None, false, t0 + 3).unwrap(),
            Gate::Allowed {
                approval_id: Some(a.id.clone())
            }
        );
        // A repeat: not allowed
        assert_eq!(
            s.gate(new_req(BOB, "hello"), Some(&a.id), false, t0 + 4)
                .unwrap_err()
                .code,
            code::APPROVAL_USED
        );
        let b = required(s.gate(new_req(BOB, "hello"), None, false, t0 + 5).unwrap());
        assert_ne!(b.id, a.id, "the same request needs a fresh approval");
        // Expired: approved, but used more than 10 minutes later
        s.approve(&b.id, t0 + 6).unwrap();
        assert_eq!(
            s.gate(
                new_req(BOB, "hello"),
                Some(&b.id),
                false,
                t0 + 5 + APPROVAL_TTL_MS
            )
            .unwrap_err()
            .code,
            code::APPROVAL_EXPIRED
        );
        // And a lookup by hash does not find the expired one
        assert!(matches!(
            s.gate(new_req(BOB, "hello"), None, false, t0 + 5 + APPROVAL_TTL_MS)
                .unwrap(),
            Gate::Required(..)
        ));
        // An expired request cannot be approved
        let c = required(s.gate(new_req(BOB, "late"), None, false, t0).unwrap());
        assert_eq!(
            s.approve(&c.id, t0 + APPROVAL_TTL_MS).unwrap_err().code,
            code::APPROVAL_EXPIRED
        );
    }

    #[test]
    fn approval_of_another_requester_does_not_apply() {
        let mut s = Approvals::default();
        let a = required(s.gate(new_req(BOB, "x"), None, false, 10).unwrap());
        s.approve(&a.id, 11).unwrap();
        let mut other = new_req(BOB, "x");
        other.requester_id = "agent:2".into();
        assert_eq!(
            s.gate(other, Some(&a.id), false, 12).unwrap_err().code,
            code::APPROVAL_MISMATCH
        );
    }

    #[test]
    fn at_most_three_notifications_per_contact_per_ten_minutes() {
        let mut s = Approvals::default();
        let t = 5_000_000;
        let quiet: Vec<bool> = (0..5)
            .map(|i| {
                required(
                    s.gate(new_req(BOB, &format!("m{i}")), None, false, t + i)
                        .unwrap(),
                )
                .quiet
            })
            .collect();
        assert_eq!(quiet, vec![false, false, false, true, true]);
        // The same requester for another contact: also quiet (the limit is per requester too)
        assert!(required(s.gate(new_req(CAROL, "c"), None, false, t + 10).unwrap()).quiet);
        // Another requester for another contact: with a notification
        let mut other = new_req(CAROL, "d");
        other.requester_id = "agent:2".into();
        other.request_hash = request_hash("agent:2", "send_message", Some(&CAROL), b"d");
        assert!(!required(s.gate(other, None, false, t + 11).unwrap()).quiet);
        let (shown, hidden) = s.list(false, t + 20);
        assert_eq!((shown.len(), hidden), (4, 3));
        // After 10 minutes the window frees up
        assert!(
            !required(
                s.gate(
                    new_req(BOB, "later"),
                    None,
                    false,
                    t + APPROVAL_WINDOW_MS + 10
                )
                .unwrap()
            )
            .quiet
        );
    }

    #[test]
    fn pending_requests_are_capped() {
        let mut s = Approvals::default();
        for i in 0..MAX_PENDING_PER_REQUESTER {
            assert!(matches!(
                s.gate(new_req(BOB, &format!("t{i}")), None, false, 10 + i as u64)
                    .unwrap(),
                Gate::Required(..)
            ));
        }
        assert_eq!(
            s.gate(new_req(BOB, "one more"), None, false, 100)
                .unwrap_err()
                .code,
            code::RATE_LIMITED
        );
        let long = "x".repeat(MAX_QUOTE * 3);
        let mut s = Approvals::default();
        let i = required(s.gate(new_req(BOB, &long), None, false, 1).unwrap());
        assert!(i.quote.chars().count() < MAX_QUOTE + 32);
    }

    #[test]
    fn tainted_writes_go_only_to_the_link_folder() {
        assert_eq!(
            check_action_on(None, Action::Write, "/home/a/CLAUDE.md"),
            Verdict::Allow
        );
        assert_eq!(
            check_action_on(
                Some(4),
                Action::Write,
                "~/Antenna/links/bob/shared/notes.md"
            ),
            Verdict::Allow
        );
        assert!(
            matches!(
                check_action_on(Some(4), Action::Write, "/tmp/evil/Antenna/links/bob/x"),
                Verdict::Approve(_)
            ),
            "only the owner's real link folder"
        );
        for p in [
            "/home/a/project/CLAUDE.md",
            "/home/a/.claude/settings.json",
            "/home/a/.bashrc",
            "src/main.rs",
        ] {
            assert!(
                matches!(
                    check_action_on(Some(4), Action::Write, p),
                    Verdict::Approve(_)
                ),
                "{p}"
            );
            // Level 5 (D-99): the project is the scope; agent memory, instructions and configs still need the owner
            assert_eq!(
                matches!(
                    check_action_on(Some(5), Action::Write, p),
                    Verdict::Approve(_)
                ),
                p != "src/main.rs",
                "{p}"
            );
        }
        assert!(
            check_action_on(Some(4), Action::Write, "/home/a/.claude/x")
                == Verdict::Approve(vec!["tainted:protected_path".into()])
        );
        // macOS (PORTABILITY M-17): case does not matter on APFS, so the comparison is in lowercase
        for p in [
            "/Users/a/Library/Application Support/Claude/claude_desktop_config.json",
            "/Users/a/Library/LaunchAgents/evil.plist",
            "/Users/a/.zshenv",
        ] {
            assert!(
                check_action_on(Some(4), Action::Write, p)
                    == Verdict::Approve(vec!["tainted:protected_path".into()]),
                "{p}"
            );
        }
        assert!(matches!(
            check_action_on(Some(1), Action::Write, "~/Antenna/links/bob/x"),
            Verdict::Deny(_)
        ));
        assert!(matches!(
            check_action_on(Some(4), Action::Write, "~/Antenna/links/../../.ssh/x"),
            Verdict::Approve(_)
        ));
    }

    /// D-84: an unanswered request closes by itself when its time runs out: it is reported once (for the event and
    /// the audit log), leaves the pending list, stays in `--all`, and can no longer be approved, denied or used.
    #[test]
    fn expired_requests_close_by_themselves() {
        let mut s = Approvals::default();
        let a = required(s.gate(new_req(BOB, "a"), None, false, 0).unwrap());
        let b = required(s.gate(new_req(CAROL, "b"), None, false, 0).unwrap());
        let c = required(s.gate(new_req(BOB, "c"), None, false, 1000).unwrap());
        s.approve(&b.id, 10).unwrap(); // approved, never used
        assert!(s.expire_due(APPROVAL_TTL_MS - 1).is_empty(), "not yet");
        let gone = s.expire_due(APPROVAL_TTL_MS);
        let ids: Vec<&str> = gone.iter().map(|e| e.info.id.as_str()).collect();
        assert_eq!(ids, [a.id.as_str(), b.id.as_str()]);
        assert!(gone.iter().all(|e| e.info.state == "expired"));
        assert_eq!(gone[0].link, BOB);
        assert_eq!(gone[0].requester_id, "agent:1");
        assert_eq!(gone[0].info.link_id.as_deref(), Some(BOB.to_hex().as_str()));
        assert_eq!(
            gone[1].info.target_link_id.as_deref(),
            Some(CAROL.to_hex().as_str())
        );
        assert!(
            s.expire_due(APPROVAL_TTL_MS + 5).is_empty(),
            "reported once"
        );
        let (pending, _) = s.list(false, APPROVAL_TTL_MS + 5);
        assert_eq!(
            pending.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            [c.id.as_str()]
        );
        let (all, _) = s.list(true, APPROVAL_TTL_MS + 5);
        assert_eq!(
            all.iter().filter(|i| i.state == "expired").count(),
            2,
            "kept for --all"
        );
        for id in [&a.id, &b.id] {
            assert_eq!(
                s.approve(id, APPROVAL_TTL_MS + 6).unwrap_err().code,
                code::APPROVAL_EXPIRED
            );
            assert_eq!(
                s.deny(id, false, APPROVAL_TTL_MS + 6).unwrap_err().code,
                code::APPROVAL_EXPIRED
            );
        }
        assert_eq!(
            s.gate(new_req(CAROL, "b"), Some(&b.id), false, APPROVAL_TTL_MS + 7)
                .unwrap_err()
                .code,
            code::APPROVAL_EXPIRED
        );
        // The same request again is a fresh one, not the expired one.
        let again = required(
            s.gate(new_req(BOB, "a"), None, false, APPROVAL_TTL_MS + 8)
                .unwrap(),
        );
        assert_ne!(again.id, a.id);
        assert_eq!(again.state, "pending");
        // Between two sweeps a past-due request already reads as expired and cannot be denied.
        let late = APPROVAL_TTL_MS + 1000;
        assert_eq!(s.get(&c.id, late).unwrap().state, "expired");
        assert_eq!(
            s.deny(&c.id, false, late).unwrap_err().code,
            code::APPROVAL_EXPIRED
        );
    }

    /// Tests may shorten the lifetime, never lengthen it (SPEC §9: 10 minutes).
    #[test]
    fn approval_lifetime_only_shortens() {
        let mut s = Approvals::with_ttl(500);
        let a = required(s.gate(new_req(BOB, "a"), None, false, 0).unwrap());
        assert_eq!(a.expires_ms, 500);
        assert_eq!(s.expire_due(500).len(), 1);
        let mut s = Approvals::with_ttl(APPROVAL_TTL_MS * 6);
        let a = required(s.gate(new_req(BOB, "a"), None, false, 0).unwrap());
        assert_eq!(a.expires_ms, APPROVAL_TTL_MS);
    }

    /// D-99: only level 5 waives, and only the reasons that guard against another person; taint, the flow between
    /// links and limits stay.
    #[test]
    fn level_5_waives_secrets_and_file_prompts_only() {
        let reasons = || {
            vec![
                "secret:token".to_string(),
                "secret_in_name:password".into(),
                "file_outside_link_folder".into(),
                "sender_check:threat".into(),
                "check:suspicious".into(),
                "special_name:dot_file_or_auto_executed".into(),
                "cross_link:carol".into(),
                "tainted:level_2:tasks_need_approve".into(),
                "files_to_level_2_need_approve".into(),
            ]
        };
        for level in 1..=4 {
            let (kept, waived) = split_level_5(level, reasons());
            assert_eq!(kept, reasons(), "level {level}");
            assert!(waived.is_empty(), "level {level}");
        }
        let (kept, waived) = split_level_5(5, reasons());
        assert_eq!(
            kept,
            [
                "cross_link:carol",
                "tainted:level_2:tasks_need_approve",
                "files_to_level_2_need_approve"
            ]
        );
        assert_eq!(waived.len(), 6);
    }

    fn sent(id: &str) -> Outcome {
        Ok(Box::new(Reply::Sent(antenna_proto::control::SentReply {
            id: id.into(),
            status: "delivered".into(),
            lamport: 1,
            parents: vec![],
            to: None,
            to_agent: None,
            topic: None,
            addressed: None,
            no_agent: false,
            peer_agents: vec![],
            urgent: None,
            local: false,
        })))
    }

    /// D-100: after approval the daemon runs the request once; a repeat with or without the ID waits while it runs and
    /// then gets the same result; a different request does not; the owner can no longer deny it; a run that failed
    /// before using the approval leaves it to the requester.
    #[test]
    fn the_daemon_carries_out_an_approved_request_once() {
        let mut s = Approvals::default();
        let mut req = new_req(BOB, "hello");
        req.completes = true;
        let a = required(s.gate(req.clone(), None, false, 0).unwrap());
        assert!(a.completes);
        assert!(!s.start_completion(&a.id, 1), "not approved yet");
        s.approve(&a.id, 2).unwrap();
        assert!(s.start_completion(&a.id, 3));
        assert!(!s.start_completion(&a.id, 3), "only once");
        // The requester repeats it meanwhile: it waits, with or without the ID
        assert_eq!(
            s.gate(req.clone(), Some(&a.id), false, 4).unwrap(),
            Gate::Completing
        );
        assert_eq!(
            s.gate(req.clone(), None, false, 4).unwrap(),
            Gate::Completing
        );
        assert_eq!(
            s.deny(&a.id, false, 4).unwrap_err().code,
            code::BAD_REQUEST,
            "approved and running: no longer deniable"
        );
        // The daemon's own run uses the approval
        assert_eq!(
            s.gate(req.clone(), Some(&a.id), true, 5).unwrap(),
            Gate::Allowed {
                approval_id: Some(a.id.clone())
            }
        );
        assert!(s.finish_completion(&a.id, sent("m1")));
        // Repeats get the same result, not a second run
        assert_eq!(
            s.gate(req.clone(), Some(&a.id), false, 6).unwrap(),
            Gate::Done(sent("m1"))
        );
        assert_eq!(
            s.gate(req.clone(), None, false, 6).unwrap(),
            Gate::Done(sent("m1"))
        );
        assert_eq!(
            s.replayed(Some(&a.id), "agent:1", &req.request_hash, false, 6),
            Some(Gate::Done(sent("m1")))
        );
        assert_eq!(
            s.replayed(None, "agent:1", &req.request_hash, false, 6),
            Some(Gate::Done(sent("m1")))
        );
        assert_eq!(
            s.replayed(Some(&a.id), "agent:1", &req.request_hash, true, 6),
            None,
            "the daemon's own run is never answered from the record"
        );
        // A tampered repeat (other text with this ID) is refused, as before
        assert_eq!(
            s.gate(new_req(BOB, "hello!"), Some(&a.id), false, 7)
                .unwrap_err()
                .code,
            code::APPROVAL_MISMATCH
        );
        assert_eq!(
            s.replayed(
                Some(&a.id),
                "agent:1",
                &new_req(BOB, "hello!").request_hash,
                false,
                7
            ),
            None
        );
        // After the approval's lifetime a repeat without the ID is a new request
        assert!(matches!(
            s.gate(req.clone(), None, false, APPROVAL_TTL_MS + 1)
                .unwrap(),
            Gate::Required(..)
        ));

        // A run that fails before it uses the approval leaves it approved for the requester's own repeat
        let b = required(s.gate(new_req(BOB, "two"), None, false, 10).unwrap());
        s.approve(&b.id, 11).unwrap();
        assert!(s.start_completion(&b.id, 12));
        assert!(!s.finish_completion(&b.id, Err(Error::new(code::LOCKED, "x"))));
        assert_eq!(
            s.gate(new_req(BOB, "two"), Some(&b.id), false, 13).unwrap(),
            Gate::Allowed {
                approval_id: Some(b.id.clone())
            }
        );
    }

    /// A run that has started is not expired under it by the sweep; requests the daemon does not carry out expire
    /// as before.
    #[test]
    fn a_running_completion_is_not_expired_by_the_sweep() {
        let mut s = Approvals::default();
        let a = required(s.gate(new_req(BOB, "a"), None, false, 0).unwrap());
        let b = required(s.gate(new_req(BOB, "b"), None, false, 0).unwrap());
        s.approve(&a.id, 1).unwrap();
        s.approve(&b.id, 1).unwrap();
        assert!(s.start_completion(&a.id, 2));
        let gone = s.expire_due(APPROVAL_TTL_MS);
        assert_eq!(
            gone.iter().map(|e| e.info.id.as_str()).collect::<Vec<_>>(),
            [b.id.as_str()]
        );
    }

    #[test]
    fn deny_for_an_hour() {
        let mut s = Approvals::default();
        let a = required(s.gate(new_req(BOB, "x"), None, false, 100).unwrap());
        s.deny(&a.id, true, 200).unwrap();
        assert_eq!(
            s.gate(new_req(BOB, "y"), None, false, 300)
                .unwrap_err()
                .code,
            code::APPROVAL_DENIED
        );
        assert!(matches!(
            s.gate(new_req(BOB, "y"), None, false, 200 + DENY_HOUR_MS)
                .unwrap(),
            Gate::Required(..)
        ));
        assert!(matches!(
            s.gate(new_req(CAROL, "z"), None, false, 300).unwrap(),
            Gate::Required(..)
        ));
    }

    #[test]
    fn taint_ceiling_and_actions() {
        let mut l = Label::default();
        assert_eq!(l.ceiling(|_| Some(5)), None);
        assert_eq!(check_action(None, Action::Exec), Verdict::Allow);
        l.taint.insert(BOB, 2);
        assert_eq!(l.ceiling(|_| Some(4)), Some(2), "level at read time counts");
        assert_eq!(
            l.ceiling(|_| Some(1)),
            Some(1),
            "lowering trust lowers the ceiling"
        );
        let c = l.ceiling(|_| Some(2));
        assert!(matches!(check_action(c, Action::Exec), Verdict::Deny(_)));
        assert!(matches!(
            check_action(c, Action::Write),
            Verdict::Approve(_)
        ));
        assert!(matches!(check_action(c, Action::Read), Verdict::Approve(_)));
        assert!(matches!(
            check_action(Some(1), Action::Read),
            Verdict::Deny(_)
        ));
        assert_eq!(check_action(Some(3), Action::Read), Verdict::Allow);
        assert!(matches!(
            check_action(Some(4), Action::Exec),
            Verdict::Approve(_)
        ));
        // Level 5, the owner's own computer (D-99): commands without confirmation
        assert_eq!(check_action(Some(5), Action::Exec), Verdict::Allow);
        // Files
        assert!(matches!(share_file(None, 1), Verdict::Deny(_)));
        assert!(matches!(share_file(None, 2), Verdict::Approve(_)));
        assert_eq!(share_file(None, 3), Verdict::Allow);
        assert!(matches!(share_file(Some(2), 4), Verdict::Approve(_)));
        assert!(matches!(request_file(None, 2), Verdict::Deny(_)));
        assert_eq!(request_file(None, 3), Verdict::Allow);
    }

    #[test]
    fn outflow_cross_link_no_write_down_and_secrets() {
        let name = |l: &LinkId| {
            if *l == BOB {
                "bob".to_string()
            } else {
                "carol".to_string()
            }
        };
        let mut l = Label::default();
        assert!(outflow_reasons(&l, &BOB, 1, "hi", name).is_empty());
        l.taint.insert(BOB, 2);
        assert!(
            outflow_reasons(&l, &BOB, 2, "reply", name).is_empty(),
            "replying to the same contact is fine"
        );
        assert_eq!(
            outflow_reasons(&l, &CAROL, 4, "fwd", name),
            vec!["cross_link:bob"]
        );
        l.local_level = 5;
        let r = outflow_reasons(&l, &BOB, 1, "x", name);
        assert_eq!(r, vec!["no_write_down:local_5>contact_1"]);
        let r = outflow_reasons(
            &Label::default(),
            &BOB,
            5,
            "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl",
            name,
        );
        assert_eq!(r, vec!["secret:private_key"]);
    }

    #[test]
    fn secret_scanner_finds_secrets_and_ignores_prose() {
        let cases: &[(&str, &[&str])] = &[
            ("-----BEGIN RSA PRIVATE KEY-----\nMIIE", &["private_key"]),
            ("-----BEGIN OPENSSH PRIVATE KEY-----", &["private_key"]),
            ("key: AKIAIOSFODNN7EXAMPLE ok", &["token"]),
            ("ghp_0123456789abcdefghijABCDEFGHIJ012345", &["token"]),
            (
                "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx",
                &["token", "password"],
            ),
            ("xoxb-1234567890-abcdefghij", &["token"]),
            (
                "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
                &["token"],
            ),
            ("123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw1", &["token"]),
            ("password: hunter2hunter2", &["password"]),
            // Intentionally Russian: the scanner also recognizes the Russian word for "password".
            ("пароль = очень-секретный", &["password"]),
            (
                "abandon ability able about above absent absorb abstract absurd abuse access accident",
                &["seed_phrase"],
            ),
            (
                "1. legal 2. winner 3. thank 4. year 5. wave 6. sausage 7. worth 8. useful 9. legal 10. winner 11. thank 12. yellow",
                &["seed_phrase"],
            ),
            ("join me: x://pair#abc.def.ghi", &["token"]),
            ("join me: antenna://pair#abc.def.ghi", &["token"]),
            (
                "join me: https://antenna.contact/#ab2cd3ef4gh5ij6kl7mn2op3qr4st5uv6wx7yz2ab3cd4ef5gh6i.\
                 kl7mn2op3qr4st5uv6wx7yz2ab3cd4ef5gh6ij7kl2mn3op4qr5s.aHR0cHM6Ly9yZWxheS5leGFtcGxlLw",
                &["token"],
            ),
            (
                "xat_abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrst",
                &["token"],
            ),
        ];
        for (t, want) in cases {
            assert_eq!(scan_secrets(t), want.to_vec(), "{t}");
        }
        for t in [
            "Hi Bob, the build is green; see commit 3f2a9c1 and sha256 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08.",
            "The password policy is documented in SECURITY.md.",
            "Join the beta: https://antenna.contact/#beta",
            "Γεια σου! Τι κάνεις; Τα λέμε αύριο στις 10:00.",
            "able about above absent absorb abstract absurd abuse access accident account xyzzy",
            "token: abc",
            "sk-short",
        ] {
            assert!(scan_secrets(t).is_empty(), "{t}: {:?}", scan_secrets(t));
        }
    }

    /// Streaming scanner: for any split into chunks it finds the same secret before its core is released, and it
    /// releases text without secrets in full and unchanged.
    #[test]
    fn stream_scanner_holds_the_tail_at_chunk_boundaries() {
        let run = |text: &str, sizes: &dyn Fn(usize) -> usize| -> (String, Vec<&'static str>) {
            let mut sc = SecretStream::new();
            let mut out = String::new();
            let mut i = 0;
            let mut n = 0;
            while i < text.len() {
                let mut j = floor_boundary(text, i.saturating_add(sizes(n)).min(text.len()));
                if j <= i {
                    j = text[i..]
                        .char_indices()
                        .nth(1)
                        .map_or(text.len(), |(k, _)| i + k);
                }
                let st = sc.push(&text[i..j]);
                out.push_str(&st.release);
                if !st.findings.is_empty() {
                    return (out, st.findings);
                }
                i = j;
                n += 1;
            }
            let st = sc.finish();
            out.push_str(&st.release);
            (out, st.findings)
        };
        let secrets: &[(&str, &str, &str)] = &[
            (
                "Here: -----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE secret body",
                "private_key",
                "b3BlbnNzaC1rZXktdjE",
            ),
            (
                "my key is ghp_0123456789abcdefghijABCDEFGHIJ012345 ok",
                "token",
                "ghp_0123456789abcdefghij",
            ),
            (
                "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx and more",
                "token",
                "sk-proj-abcdefghijklmnop",
            ),
            (
                "words: legal winner thank year wave sausage worth useful legal winner thank yellow done",
                "seed_phrase",
                "thank yellow",
            ),
            (
                "password: hunter2hunter2 then text",
                "password",
                "hunter2hunter2",
            ),
        ];
        for (text, kind, core) in secrets {
            // The stream stops at the first finding (the kind may differ: `KEY=` comes before the token prefix);
            // what matters is that it is found and the secret's core is not released
            for sz in [1usize, 2, 3, 5, 7, 11, 16, 64, 1000] {
                let (released, found) = run(text, &|_| sz);
                assert!(!found.is_empty(), "{text} / {sz}: {found:?}");
                assert!(
                    !released.contains(core),
                    "{text} / {sz}: released {released:?}"
                );
            }
            for split in 1..text.len() {
                if !text.is_char_boundary(split) {
                    continue;
                }
                let (released, found) = run(text, &|n| if n == 0 { split } else { usize::MAX });
                assert!(!found.is_empty(), "{text} @ {split}");
                assert!(!released.contains(core), "{text} @ {split}: {released:?}");
            }
            // In one chunk: the same kinds as the pure function
            assert!(run(text, &|_| usize::MAX).1.contains(kind), "{text}");
        }
        let prose = "Hi Bob, the build is green; commit 3f2a9c1. The password policy is in SECURITY.md. \
                     Γεια σου! able about above absent absorb abstract — and that is all.";
        for sz in [1usize, 4, 13, 100, 10_000] {
            let (out, found) = run(prose, &|_| sz);
            assert!(found.is_empty(), "{sz}: {found:?}");
            assert_eq!(out, prose, "{sz}");
        }
    }

    #[test]
    fn rate_limiter_window() {
        let mut r = RateLimiter::default();
        for i in 0..10 {
            assert!(r.try_acquire(BOB, 10, 1000 + i).is_ok());
        }
        let wait = r.try_acquire(BOB, 10, 2000).unwrap_err();
        assert_eq!(wait, 1000 + RATE_WINDOW_MS - 2000);
        assert!(r.try_acquire(CAROL, 10, 2000).is_ok(), "per contact");
        assert!(
            r.try_acquire(BOB, 10, 1000 + RATE_WINDOW_MS).is_ok(),
            "the window slides"
        );
        assert_eq!(msgs_per_min(1), 10);
        assert_eq!(msgs_per_min(2), 30);
        assert_eq!(msgs_per_min(3), 60);
        assert_eq!(rights(2).msgs_per_min, 30);
    }

    #[test]
    fn bip39_list_is_sorted() {
        assert!(crate::bip39_english::WORDS.windows(2).all(|w| w[0] < w[1]));
    }
}
