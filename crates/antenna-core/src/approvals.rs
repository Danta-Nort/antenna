// SPDX-License-Identifier: AGPL-3.0-only
//! Approval requests (SPEC §9): going through approval, the owner's decisions (one and many), requests that close
//! by themselves (D-84), and the events about them.
//!
//! After the owner approves a request an agent made (`send_message`, `share_file`, `share_file_content`,
//! `file_accept`, `request_file`, a stream's final message), the daemon carries out exactly that request itself, once,
//! under the same binding (the request hash with its nonce), and tells the agent: the `approval_resolved` event and
//! its next `wait`/`inbox` (D-100). A repeat of the call by the agent gets the same result instead of a second run.
//! Trust level 5, the owner's own computer, waives the prompts that guard against another person (D-99).

use std::io::{Seek, SeekFrom};
use std::sync::{Arc, PoisonError};
use std::time::Duration;

use antenna_proto::{
    LinkId,
    control::{ApprovalInfo, ApprovalResolution, BatchResult, Reply, code},
};

use crate::{
    addressing::Addr,
    agents::AgentCtx,
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
    now_ms, policy,
    store::LinkRow,
};

/// How often expired approval requests are closed (D-84): the window's card goes away at most this late.
const APPROVALS_SWEEP: Duration = Duration::from_secs(1);
/// How long a repeat of a request waits for the daemon's run of it (D-100).
const COMPLETING_WAIT: Duration = Duration::from_secs(120);
/// How long the daemon's run of an approved send waits for the delivery (D-100).
const COMPLETION_DELIVERY_WAIT: Duration = Duration::from_secs(5);
/// Resolutions kept per agent until its next `wait`/`inbox`; the oldest go first (D-100).
const MAX_RESOLVED: usize = 32;
/// The audit log's decision for what trust level 5 let through without approval (D-99).
pub(crate) const ALLOWED_AT_5: &str = "allowed_at_trust_5";

tokio::task_local! {
    /// The approval the daemon is carrying out in this task (D-100): its own run uses the approval up; anyone else's
    /// repeat of the request waits for that run and gets its result.
    static COMPLETING: String;
}

/// Whether this call is the daemon's own run of approval `approval_id`.
fn by_daemon(approval_id: Option<&str>) -> bool {
    approval_id.is_some_and(|id| COMPLETING.try_with(|c| c == id).unwrap_or(false))
}

/// What going through approval gave (D-100).
#[derive(Debug)]
pub(crate) enum Pass {
    /// Go ahead: no approval was needed, or this approval was used up.
    Go(Option<String>),
    /// The daemon already carried out exactly this approved request: its result, instead of a second run.
    Done(policy::Outcome),
}

/// One pass of the approval check.
enum Step {
    Pass(Pass),
    /// The daemon is carrying out exactly this approved request right now.
    Completing,
}

/// A request the daemon carries out itself once the owner approves it (D-70, D-100). It holds exactly what the
/// requester gave; carrying it out goes through the same policy and the same approval binding as the original call, so
/// a request that changed meanwhile (a file edited after the approval) fails with `approval_mismatch`, and a contact
/// whose level dropped meanwhile is refused as it would be for a new call.
pub(crate) enum Continuation {
    /// An agent's `send_message`, with the address resolved when it asked.
    Send {
        /// The agent.
        ctx: AgentCtx,
        /// The recipient's link.
        link: LinkId,
        /// The text.
        text: String,
        /// How long to wait for delivery.
        wait: Duration,
        /// Address and topic (v6).
        addr: Addr,
    },
    /// A stream's final message (the owner's or an agent's, D-70).
    Stream(crate::stream::Pending),
    /// An agent's `share_file`: the file is read again and must hash the same.
    ShareFile {
        /// The agent.
        ctx: AgentCtx,
        /// The contact's link ID (hex).
        contact: String,
        /// The absolute path.
        path: String,
        /// The name for the contact.
        name: Option<String>,
        /// Who the offer is for (PG-19).
        addr: Addr,
    },
    /// An agent's `share_file_content`: the staging file, which has no name on disk, stays open until then.
    ShareContent {
        /// The agent.
        ctx: AgentCtx,
        /// The contact's link.
        link: LinkId,
        /// The staging file.
        file: std::fs::File,
        /// The name for the contact.
        name: String,
        /// Who the offer is for (PG-19).
        addr: Addr,
    },
    /// An agent's `file_accept`.
    FileAccept {
        /// The agent.
        ctx: AgentCtx,
        /// The file ID.
        id: String,
        /// Another name to save it under.
        name: Option<String>,
    },
    /// An agent's `request_file`.
    RequestFile {
        /// The agent.
        ctx: AgentCtx,
        /// The contact's link ID (hex).
        contact: String,
        /// The path inside the contact's `shared/`.
        path: String,
    },
    /// The other side of a connection an own computer asked for (CONTROL §30): applied here once the owner approves.
    Connect {
        /// The own computer's link.
        link: LinkId,
        /// This node's agent.
        agent_id: i64,
        /// What it asked.
        ask: antenna_proto::device::ConnectAsk,
        /// What the request's binding was salted with (a new request for an ask carried out before).
        salt: u64,
    },
}

impl Continuation {
    fn kind(&self) -> &'static str {
        match self {
            Continuation::Send { .. } => "send_message",
            Continuation::Stream(_) => "stream_final",
            Continuation::ShareFile { .. } => "share_file",
            Continuation::ShareContent { .. } => "share_file_content",
            Continuation::FileAccept { .. } => "accept_file",
            Continuation::RequestFile { .. } => "request_file",
            Continuation::Connect { .. } => "connect_agent",
        }
    }
}

/// The result the daemon's run of a send returned, for a repeat of the call (D-100).
pub(crate) fn replayed_sent(
    o: policy::Outcome,
) -> Result<(antenna_proto::MessageId, antenna_proto::control::SentReply)> {
    match *o? {
        Reply::Sent(s) => {
            let id = data_encoding::HEXLOWER
                .decode(s.id.as_bytes())
                .ok()
                .and_then(|b| <[u8; 32]>::try_from(b).ok())
                .map(antenna_proto::MessageId)
                .ok_or_else(|| Error::internal("a stored send result without a message ID"))?;
            Ok((id, s))
        }
        _ => Err(Error::internal("a stored result of another action")),
    }
}

/// The result the daemon's run of a file action returned, for a repeat of the call (D-100).
pub(crate) fn replayed_file(o: policy::Outcome) -> Result<antenna_proto::control::FileInfo> {
    match *o? {
        Reply::File(f) => Ok(f),
        _ => Err(Error::internal("a stored result of another action")),
    }
}

/// The result the daemon's run of a file request returned, for a repeat of the call (D-100).
pub(crate) fn replayed_request(o: policy::Outcome) -> Result<(String, String, String)> {
    match *o? {
        Reply::FileRequested {
            contact,
            id,
            status,
        } => Ok((contact, id, status)),
        _ => Err(Error::internal("a stored result of another action")),
    }
}

impl Session {
    /// The approval request for sending `text` to `target` (the binding is the requester, the target link and the
    /// text), attributed to the contact whose data caused it.
    pub(crate) fn send_approval(
        requester_id: &str,
        requester: &str,
        target: &LinkRow,
        attributed: &LinkRow,
        reasons: Vec<String>,
        text: &str,
    ) -> policy::NewApproval {
        policy::NewApproval {
            requester_id: requester_id.into(),
            requester: requester.into(),
            contact: attributed.link_id,
            contact_label: attributed.label.clone(),
            contact_trust: attributed.trust,
            action: "send_message".into(),
            target: Some(target.label.clone()),
            target_link: Some(target.link_id),
            reasons,
            grants: antenna_proto::control::Grants {
                read: "none".into(),
                write: "none".into(),
                commands: "none".into(),
                send: format!(
                    "one text message ({} chars) to {} (trust {})",
                    text.chars().count(),
                    target.label,
                    target.trust
                ),
            },
            quote: text.into(),
            request_hash: policy::request_hash(
                requester_id,
                "send_message",
                Some(&target.link_id),
                text.as_bytes(),
            ),
            // An agent's message (and a stream's final message, D-70) goes out by the daemon after approval; the
            // owner's own message is sent again by the owner's client
            completes: requester_id != "owner",
        }
    }

    /// The common part of approval for a request the daemon does not carry out itself: `Ok(Some(id))` means allowed
    /// by an approval; otherwise an error with a request.
    pub(crate) fn gate(
        &self,
        req: policy::NewApproval,
        approval_id: Option<&str>,
        log_link: &LinkId,
        actor: &str,
    ) -> Result<Option<String>> {
        match self.gate_step(req, approval_id, log_link, actor)? {
            Step::Pass(Pass::Go(used)) => Ok(used),
            // Only requests the daemon carries out get these, and those go through `gate_pass`
            Step::Pass(Pass::Done(_)) => Err(Error::new(
                code::APPROVAL_USED,
                "the daemon already carried out this approved request",
            )),
            Step::Completing => Err(Error::new(
                code::APPROVAL_PENDING,
                "the daemon is carrying out this approved request now",
            )),
        }
    }

    /// Approval for a request the daemon carries out itself once the owner approves it (D-100). A repeat of a request
    /// the daemon is carrying out waits for it, and a repeat of one it carried out gets [`Pass::Done`] with the same
    /// result, so nothing runs twice. With no reasons left (for example the contact is now at level 5), only a
    /// repeat that names its approval is answered from the daemon's run; anything else goes ahead.
    pub(crate) async fn gate_pass(
        &self,
        req: policy::NewApproval,
        approval_id: Option<&str>,
        log_link: &LinkId,
        actor: &str,
    ) -> Result<Pass> {
        let deadline = tokio::time::Instant::now() + COMPLETING_WAIT;
        loop {
            // Registered before the check, so a run that ends between the check and the wait is not missed
            let changed = self.approvals_changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            match self.gate_step(req.clone(), approval_id, log_link, actor)? {
                Step::Pass(p) => return Ok(p),
                Step::Completing => {}
            }
            if tokio::time::timeout_at(deadline, changed).await.is_err() {
                return Err(Error::new(
                    code::APPROVAL_PENDING,
                    "the owner approved this request and the daemon is still carrying it out; wait_for_message \
                     reports approval_resolved with the result",
                ));
            }
        }
    }

    /// A repeat of a request the daemon carried out or is carrying out (D-100), naming its approval `id` or (without
    /// it) within the approval's lifetime: its result, after waiting for a run in progress; `None` when the daemon has
    /// nothing for it, and the call goes on as usual.
    pub(crate) async fn replay_of(
        &self,
        id: Option<&str>,
        requester_id: &str,
        request_hash: &[u8; 32],
    ) -> Result<Option<policy::Outcome>> {
        let deadline = tokio::time::Instant::now() + COMPLETING_WAIT;
        loop {
            let changed = self.approvals_changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let replay = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .replayed(id, requester_id, request_hash, by_daemon(id), now_ms());
            match replay {
                Some(policy::Gate::Done(o)) => return Ok(Some(o)),
                Some(policy::Gate::Completing) => {}
                _ => return Ok(None),
            }
            if tokio::time::timeout_at(deadline, changed).await.is_err() {
                return Err(Error::new(
                    code::APPROVAL_PENDING,
                    "the owner approved this request and the daemon is still carrying it out; wait_for_message \
                     reports approval_resolved with the result",
                ));
            }
        }
    }

    /// One pass of the approval check.
    fn gate_step(
        &self,
        req: policy::NewApproval,
        approval_id: Option<&str>,
        log_link: &LinkId,
        actor: &str,
    ) -> Result<Step> {
        let by_daemon = by_daemon(approval_id);
        if req.reasons.is_empty() {
            let replay = approval_id.and_then(|id| {
                self.approvals
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .replayed(
                        Some(id),
                        &req.requester_id,
                        &req.request_hash,
                        by_daemon,
                        now_ms(),
                    )
            });
            return Ok(match replay {
                Some(policy::Gate::Completing) => Step::Completing,
                Some(policy::Gate::Done(o)) => Step::Pass(Pass::Done(o)),
                _ => Step::Pass(Pass::Go(None)),
            });
        }
        let action = req.action.clone();
        let reasons = req.reasons.join(" ");
        let requester_id = req.requester_id.clone();
        // The contact whose data (or whose request) caused the request
        let source_link = req.contact;
        let g = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .gate(req, approval_id, by_daemon, now_ms());
        match g {
            Ok(policy::Gate::Allowed { approval_id }) => {
                if let Some(id) = &approval_id {
                    self.emit_approval(id);
                }
                Ok(Step::Pass(Pass::Go(approval_id)))
            }
            Ok(policy::Gate::Completing) => Ok(Step::Completing),
            Ok(policy::Gate::Done(o)) => Ok(Step::Pass(Pass::Done(o))),
            Ok(policy::Gate::Required(info, new)) => {
                // A repeat of a pending request creates neither an event nor audit log entries
                if new {
                    // "Quiet" ones (above 3 per 10 minutes) accumulate without a notification (SPEC §9)
                    if !info.quiet {
                        let _ = self.events.send(NodeEvent::Approval {
                            requester_id,
                            info: Box::new(self.with_answerers((*info).clone())),
                        });
                    }
                    // An approver the owner named may answer it in the owner's place (PG-57): it hears of it
                    self.offer_to_approvers(&info);
                    self.receipt(
                        log_link,
                        actor,
                        &action,
                        "approval_required",
                        &reasons,
                        None,
                        Some(&info.id),
                    );
                    // A receipt in the shared history only for actions at the contact's request (agent tool checks
                    // after reading its data, files), to the source contact, without reasons or text. Send approvals
                    // (secret scanner, no-write-down, flow between links) stay in the local log: otherwise the
                    // recipient or the source would learn about another link's data.
                    if actor != "owner" && crate::linksync::receipt_worthy(&action) {
                        self.dag_receipt(&source_link, actor, &action, "approval_required", &[]);
                    }
                }
                Err(Error::approval(*info))
            }
            Err(e) => {
                if e.code != code::RATE_LIMITED || self.receipt_due(log_link) {
                    self.receipt(
                        log_link,
                        actor,
                        &action,
                        e.code,
                        &reasons,
                        None,
                        approval_id,
                    );
                }
                Err(e)
            }
        }
    }

    /// Trust level 5 is the owner's own computer (D-99): the reasons it waives (secrets, a file from outside the link
    /// folder, check verdicts short of a threat, dot-file names) do not wait for approval. What the scanner and the
    /// checks found still goes into the link's audit log: what (the reasons, such as `secret:token`), where (this
    /// link) and who (`actor`). Returns the reasons that still need the owner.
    pub(crate) fn waive_level_5(
        &self,
        row: &LinkRow,
        level: u8,
        actor: &str,
        action: &str,
        reasons: Vec<String>,
    ) -> Vec<String> {
        let (kept, waived) = policy::split_level_5(level, reasons);
        if !waived.is_empty() {
            self.receipt(
                &row.link_id,
                actor,
                action,
                ALLOWED_AT_5,
                &waived.join(" "),
                None,
                None,
            );
        }
        kept
    }

    /// Event about an approval request's state for subscribers.
    pub(crate) fn emit_approval(&self, id: &str) {
        let (info, requester_id) = {
            let a = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            (a.get(id, now_ms()), a.requester_of(id))
        };
        if let (Some(info), Some(requester_id)) = (info, requester_id) {
            let info = if info.state == "pending" {
                self.with_answerers(info)
            } else {
                info
            };
            let _ = self.events.send(NodeEvent::Approval {
                requester_id,
                info: Box::new(info),
            });
        }
    }

    /// `antenna approvals`.
    pub fn approvals_list(&self, all: bool) -> (Vec<ApprovalInfo>, u32) {
        self.approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .list(all, now_ms())
    }

    /// The owner's `approvals`: each pending request also says which approvers may answer it now (PG-57).
    pub fn approvals_for_owner(&self, all: bool) -> (Vec<ApprovalInfo>, u32) {
        let (list, hidden) = self.approvals_list(all);
        (
            list.into_iter()
                .map(|i| {
                    if i.state == "pending" {
                        self.with_answerers(i)
                    } else {
                        i
                    }
                })
                .collect(),
            hidden,
        )
    }

    /// `antenna approve <id>` (the caller has checked the password).
    pub fn approve(&self, id: &str) -> Result<ApprovalInfo> {
        self.approve_checked(id, None)
    }

    /// The same, checking that the request is the one the owner was shown (`approve {fingerprint}`, v7): a mismatch
    /// is `approval_mismatch`, as for an item of `approve_many`.
    pub fn approve_checked(&self, id: &str, fingerprint: Option<&str>) -> Result<ApprovalInfo> {
        self.approve_checked_as(id, fingerprint, "approved_by_owner")
    }

    /// The same, with the decision as the audit log records it (`approved_from_own_device` for an approval answered
    /// from another own device, D-106).
    pub(crate) fn approve_checked_as(
        &self,
        id: &str,
        fingerprint: Option<&str>,
        decision: &str,
    ) -> Result<ApprovalInfo> {
        let info = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .approve_checked(id, fingerprint, now_ms())?;
        self.claim_completion(id);
        self.log_decision(&info, decision);
        self.emit_approval(id);
        Ok(info)
    }

    /// Right at the approval, before anything else can use it: when the daemon keeps the request, the approval is
    /// its to carry out (D-100), so a repeat by the requester waits for that run instead of racing it.
    fn claim_completion(&self, id: &str) {
        let kept = self
            .continuations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(id);
        if kept {
            self.approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .start_completion(id, now_ms());
        }
    }

    /// `antenna deny <id> [--hour]`: no password and no session (D-84); agents do not have the command.
    pub fn deny(&self, id: &str, hour: bool) -> Result<ApprovalInfo> {
        self.deny_logged(
            id,
            hour,
            if hour {
                "denied_by_owner_for_an_hour"
            } else {
                "denied_by_owner"
            },
        )
    }

    /// A denial answered from another own device (D-106), logged as such.
    pub(crate) fn deny_as(&self, id: &str, decision: &str) -> Result<ApprovalInfo> {
        self.deny_logged(id, false, decision)
    }

    /// An approver approved request `id` in the owner's place (PG-57; the caller checked the delegation and the
    /// circle): exactly as the owner's approval, with the fingerprint compared, then carried out by the daemon
    /// (D-100); logged with the approver as the actor.
    pub(crate) fn approve_by_agent(
        self: &Arc<Self>,
        id: &str,
        fingerprint: &str,
        by: antenna_proto::control::DecidedBy,
        actor: &str,
    ) -> Result<ApprovalInfo> {
        let info = {
            let mut a = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let info = a.approve_checked(id, Some(fingerprint), now_ms())?;
            a.mark_delegated(id, by);
            info
        };
        self.claim_completion(id);
        self.log_decision_by(&info, "approved_by_agent", actor);
        self.emit_approval(id);
        let s = self.clone();
        let id2 = id.to_string();
        tokio::spawn(async move { s.complete_approved(&id2).await });
        // With who decided, as the card shows it
        let now = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id, now_ms());
        Ok(now.unwrap_or(info))
    }

    /// An approver denied request `id` in the owner's place (PG-57), with the fingerprint it read compared.
    pub(crate) fn deny_by_agent(
        &self,
        id: &str,
        fingerprint: &str,
        by: antenna_proto::control::DecidedBy,
        actor: &str,
    ) -> Result<ApprovalInfo> {
        let info = {
            let mut a = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let current = a.get(id, now_ms()).ok_or_else(|| {
                Error::new(code::NOT_FOUND, format!("no approval request {id:?}"))
            })?;
            if !crate::crypto::ct_eq(
                current.fingerprint.as_bytes(),
                fingerprint.to_ascii_lowercase().as_bytes(),
            ) {
                return Err(Error::new(
                    code::APPROVAL_MISMATCH,
                    "this request is not the one shown (fingerprint differs)",
                ));
            }
            let info = a.deny(id, false, now_ms())?;
            a.mark_delegated(id, by);
            info
        };
        self.continuations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        self.emit_approval(id);
        self.resolve(id, Resolved::Denied);
        self.log_decision_by(&info, "denied_by_agent", actor);
        Ok(info)
    }

    fn deny_logged(&self, id: &str, hour: bool, decision: &str) -> Result<ApprovalInfo> {
        let info = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .deny(id, hour, now_ms())?;
        // A denied request is never carried out: drop what the daemon kept for it (a stream final's text, an open
        // staging file) now rather than when its time runs out
        self.continuations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        self.emit_approval(id);
        self.resolve(id, Resolved::Denied);
        self.log_decision(&info, decision);
        Ok(info)
    }

    /// Maximum number of items in `approve_many` / `deny_many` (v6).
    pub const MAX_BATCH: usize = 64;

    /// `approve_many` (v6, CONTROL §20; the caller has checked the password once for the call): each request is
    /// approved on its own exactly as by `approve` (its own binding; `fingerprint`, when given, must be the one the
    /// owner was shown), logged on its own and announced with its own `approval` event. An item fails alone.
    pub fn approve_many(&self, items: &[(String, Option<String>)]) -> Result<Vec<BatchResult>> {
        if items.is_empty() || items.len() > Self::MAX_BATCH {
            return Err(Error::bad_request(format!(
                "1–{} requests per call",
                Self::MAX_BATCH
            )));
        }
        let mut out = Vec::with_capacity(items.len());
        for (id, fingerprint) in items {
            let r = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .approve_checked(id, fingerprint.as_deref(), now_ms());
            out.push(match r {
                Ok(info) => {
                    self.claim_completion(id);
                    self.log_decision(&info, "approved_by_owner");
                    self.emit_approval(id);
                    BatchResult {
                        id: id.clone(),
                        approval: Some(info),
                        error: None,
                    }
                }
                Err(e) => BatchResult {
                    id: id.clone(),
                    approval: None,
                    error: Some(e.body()),
                },
            });
        }
        Ok(out)
    }

    /// `deny_many` (v6): like `deny` for each request, no password and no session (D-84).
    pub fn deny_many(&self, ids: &[String], hour: bool) -> Result<Vec<BatchResult>> {
        if ids.is_empty() || ids.len() > Self::MAX_BATCH {
            return Err(Error::bad_request(format!(
                "1–{} requests per call",
                Self::MAX_BATCH
            )));
        }
        Ok(ids
            .iter()
            .map(|id| match self.deny(id, hour) {
                Ok(info) => BatchResult {
                    id: id.clone(),
                    approval: Some(info),
                    error: None,
                },
                Err(e) => BatchResult {
                    id: id.clone(),
                    approval: None,
                    error: Some(e.body()),
                },
            })
            .collect())
    }

    /// Close the approval requests whose time ran out (D-84): the `approval` event with `state: "expired"` (the window
    /// removes the card, the waiting agent learns it), an `approval_expired` record in the link's audit log. Only the
    /// local log: the shared history's receipts keep their closed vocabulary (D-52), so nothing new goes to the
    /// contact. Runs every second until `lock`.
    pub(crate) async fn approvals_maintenance(self: std::sync::Arc<Self>) {
        let mut tick = tokio::time::interval(APPROVALS_SWEEP);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = tick.tick() => {}
                _ = self.closed_wait() => break,
            }
            self.expire_approvals(now_ms());
        }
    }

    /// One sweep of [`Self::approvals_maintenance`].
    pub(crate) fn expire_approvals(&self, now: u64) {
        let expired = self
            .approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .expire_due(now);
        for e in expired {
            self.continuations
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&e.info.id);
            self.receipt(
                &e.link,
                &e.info.requester,
                &e.info.action,
                code::APPROVAL_EXPIRED,
                &e.info.reasons.join(" "),
                None,
                Some(&e.info.id),
            );
            tracing::info!(
                "approval request {} ({}) expired unanswered",
                e.info.id,
                e.info.action
            );
            let id = e.info.id.clone();
            let _ = self.events.send(crate::events::NodeEvent::Approval {
                requester_id: e.requester_id,
                info: Box::new(e.info),
            });
            self.resolve(&id, Resolved::Expired);
        }
    }

    fn log_decision(&self, info: &ApprovalInfo, decision: &str) {
        self.log_decision_by(info, decision, "owner");
    }

    /// The decision on `info` in the audit log of its contact's link, with who decided (`owner`, or an approver in the
    /// owner's place, PG-57), and for a request caused by the contact a receipt in the shared history.
    pub(crate) fn log_decision_by(&self, info: &ApprovalInfo, decision: &str, actor: &str) {
        if let Ok(row) = self.find_link(&info.contact) {
            self.receipt(
                &row.link_id,
                actor,
                &info.action,
                decision,
                &info.reasons.join(" "),
                None,
                Some(&info.id),
            );
            // The owner's decision on a request caused by the contact is a receipt in the shared history (SPEC §9,
            // Q-16)
            if info.requester != "owner" && crate::linksync::receipt_worthy(&info.action) {
                let d = if decision.starts_with("approved") {
                    "approved"
                } else {
                    "denied"
                };
                self.dag_receipt(&row.link_id, &info.requester, &info.action, d, &[]);
            }
        }
    }

    /// Keep what an agent asked for when its call ended in `approval_required` (D-100), so the daemon can carry it out
    /// once the owner approves. The first call of a pending request is kept; a repeat of it changes nothing.
    pub(crate) fn keep_for_approval<T>(&self, r: &Result<T>, make: impl FnOnce() -> Continuation) {
        let Err(Error {
            code: code::APPROVAL_REQUIRED,
            approval: Some(info),
            ..
        }) = r
        else {
            return;
        };
        if !info.completes {
            return;
        }
        let mut g = self
            .continuations
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if !g.contains_key(&info.id) {
            g.insert(info.id.clone(), make());
        }
    }

    /// The owner approved request `id` (alone or in a batch): the daemon carries out the request it keeps for it,
    /// once, and tells the requester the result (D-100). A request it keeps nothing for (a tool check the agent's host
    /// runs) is reported to the agent as approved: its next attempt passes once.
    pub(crate) async fn complete_approved(self: &Arc<Self>, id: &str) {
        let kept = self
            .continuations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(id);
        let Some(kept) = kept else {
            let agent = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .requester_of(id)
                .is_some_and(|r| r.starts_with("agent:"));
            if agent {
                self.resolve(id, Resolved::Approved);
            }
            return;
        };
        // Claimed at the approval (`claim_completion`); the run below is the only one that may use it
        let what = kept.kind();
        let outcome = COMPLETING
            .scope(id.to_string(), self.carry_out(kept, id))
            .await;
        if let Err(e) = &outcome {
            tracing::info!("approval {id}: the approved {what} failed: {}", e.code);
        }
        self.approvals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .finish_completion(id, outcome.clone());
        self.approvals_changed.notify_waiters();
        self.resolve(
            id,
            match outcome {
                Ok(r) => Resolved::Completed(r),
                Err(e) => Resolved::Failed(e),
            },
        );
    }

    /// Carry out a kept request under approval `id`: the same code path as the agent's own call, with the approval
    /// named, so the policy is checked again and the approval binding must match.
    async fn carry_out(self: &Arc<Self>, kept: Continuation, id: &str) -> policy::Outcome {
        let reply = match kept {
            Continuation::Send {
                ctx,
                link,
                text,
                wait,
                addr,
            } => {
                let row = self
                    .db
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .link(&link)?;
                // Nobody waits on this call, so it may wait for the delivery: the result then says `delivered`
                let wait = wait.max(COMPLETION_DELIVERY_WAIT);
                Reply::Sent(
                    self.agent_send_row(&ctx, &row, &text, wait, Some(id), None, &addr)
                        .await?
                        .1,
                )
            }
            Continuation::Stream(p) => {
                Reply::Sent(crate::stream::send_kept_final(self, p, id).await?)
            }
            Continuation::ShareFile {
                ctx,
                contact,
                path,
                name,
                addr,
            } => Reply::File(
                self.agent_share_file(&ctx, &contact, &path, name.as_deref(), Some(id), &addr)
                    .await?,
            ),
            Continuation::ShareContent {
                ctx,
                link,
                mut file,
                name,
                addr,
            } => {
                file.seek(SeekFrom::Start(0))?;
                Reply::File(
                    self.agent_share_content_finish(&ctx, &link, file, &name, Some(id), &addr)
                        .await?,
                )
            }
            Continuation::FileAccept {
                ctx,
                id: file,
                name,
            } => Reply::File(
                self.agent_file_accept(&ctx, &file, name.as_deref(), Some(id))
                    .await?,
            ),
            Continuation::RequestFile { ctx, contact, path } => {
                let (contact, id, status) = self
                    .agent_request_file_as(&ctx, &contact, &path, Some(id))
                    .await?;
                Reply::FileRequested {
                    contact,
                    id,
                    status,
                }
            }
            Continuation::Connect {
                link,
                agent_id,
                ask,
                salt,
            } => self.connect_apply(id, &link, agent_id, &ask, salt)?,
        };
        Ok(Box::new(reply))
    }

    /// Tell the requester (and the owner's subscriptions) what became of request `id` (D-100): the `approval_resolved`
    /// event, and for an agent also its next `wait`/`inbox`.
    pub(crate) fn resolve(&self, id: &str, how: Resolved) {
        let (info, requester_id) = {
            let a = self
                .approvals
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            (a.get(id, now_ms()), a.requester_of(id))
        };
        let (Some(info), Some(requester_id)) = (info, requester_id) else {
            return;
        };
        let r = how.resolution(info);
        // Only an agent reads its resolutions (`wait`/`inbox`); the owner and another own computer do not
        if requester_id.starts_with("agent:") {
            {
                let mut g = self.resolved.lock().unwrap_or_else(PoisonError::into_inner);
                let q = g.entry(requester_id.clone()).or_default();
                if q.len() >= MAX_RESOLVED {
                    q.pop_front();
                }
                q.push_back(r.clone());
            }
            // Wakes an agent waiting in `wait`/`inbox`
            self.inbox.send_modify(|v| *v += 1);
        }
        let _ = self.events.send(NodeEvent::ApprovalResolved {
            requester_id,
            resolution: Box::new(r),
        });
    }

    /// The resolutions agent `requester_id` has not seen yet; taking them marks them seen.
    pub(crate) fn take_resolved(&self, requester_id: &str) -> Vec<ApprovalResolution> {
        self.resolved
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(requester_id)
            .map(Vec::from)
            .unwrap_or_default()
    }

    /// Whether agent `requester_id` has resolutions it has not seen.
    pub(crate) fn has_resolved(&self, requester_id: &str) -> bool {
        self.resolved
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(requester_id)
            .is_some_and(|q| !q.is_empty())
    }
}

/// What became of an approval request (D-100).
pub(crate) enum Resolved {
    /// Approved and carried out by the daemon.
    Completed(Box<Reply>),
    /// Approved, but carrying it out failed.
    Failed(Error),
    /// Approved; the action is the agent's own (a tool check).
    Approved,
    /// Denied by the owner.
    Denied,
    /// Nobody answered in time.
    Expired,
}

impl Resolved {
    fn resolution(self, info: ApprovalInfo) -> ApprovalResolution {
        // An approver the owner named may have decided in the owner's place (PG-57): the agent is told who
        let who = match &info.decided_by {
            Some(d) => format!("{}, an approver the owner named,", d.agent),
            None => "The owner".to_string(),
        };
        let (state, message, result, error) = match self {
            Resolved::Completed(r) => {
                let what = match (&*r, info.action.as_str()) {
                    (Reply::Sent(s), _) => format!(
                        "Antenna sent the message for you (message {}). Do not send it again",
                        short(&s.id)
                    ),
                    (Reply::File(f), "accept_file") => format!(
                        "Antenna accepted the file for you (into {}/)",
                        f.dest.as_deref().unwrap_or("the link folder")
                    ),
                    (Reply::File(f), _) => format!(
                        "Antenna sent the file for you (file {}). Do not send it again",
                        short(&f.id)
                    ),
                    (Reply::FileRequested { .. }, _) => {
                        "Antenna sent the file request for you. Do not send it again".to_string()
                    }
                    _ => "Antenna carried out the request for you".to_string(),
                };
                (
                    "completed",
                    format!("{who} approved request {}. {what}.", info.id),
                    Some(r),
                    None,
                )
            }
            Resolved::Failed(e) => (
                "failed",
                format!(
                    "{who} approved request {}, but Antenna could not carry it out: {}: {}",
                    info.id, e.code, e.message
                ),
                None,
                Some(e.body()),
            ),
            Resolved::Approved => (
                "approved",
                format!(
                    "{who} approved request {} ({}): do the same action once more and it passes.",
                    info.id, info.action
                ),
                None,
                None,
            ),
            Resolved::Denied => (
                "denied",
                format!(
                    "{who} denied request {} ({}): do not repeat it.",
                    info.id, info.action
                ),
                None,
                None,
            ),
            Resolved::Expired => (
                "expired",
                format!(
                    "Nobody answered request {} ({}) within 10 minutes and it closed: ask again only if it is \
                     still needed.",
                    info.id, info.action
                ),
                None,
                None,
            ),
        };
        ApprovalResolution {
            id: info.id,
            action: info.action,
            requester: info.requester,
            contact: info.contact,
            link_id: info.link_id,
            target: info.target,
            target_link_id: info.target_link_id,
            state: state.into(),
            result,
            error,
            message,
            at_ms: now_ms(),
            decided_by: info.decided_by,
        }
    }
}

/// The first 16 characters of a hex ID, as the CLI shows them.
fn short(id: &str) -> &str {
    id.get(..16).unwrap_or(id)
}
