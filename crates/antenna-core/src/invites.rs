// SPDX-License-Identifier: AGPL-3.0-only
//! Invites in the daemon (Q-7, `docs/PROTOCOL.md` §4).
//!
//! An invite lives in the daemon until its TTL, not while `antenna invite` is open: side A runs as a background task,
//! the client (`antenna invite`) only watches events. Closing the client keeps the invite alive; the owner sees it in
//! `antenna pairing` (together with the SAS code once B has connected), confirms the link with a separate command,
//! `antenna pairing confirm <id>` with the password, or burns it with `antenna pairing cancel <id>`. `antenna lock`
//! aborts all invites.

use std::sync::PoisonError;
use std::{sync::Arc, sync::Mutex as StdMutex, time::Duration};

use antenna_proto::control::{ErrorBody, Event, Input, InviteInfo, LinkedReply, code};
use tokio::sync::{broadcast, mpsc, watch};

use crate::{
    crypto,
    error::{Error, Result},
    events::NodeEvent,
    node::Session,
    now_ms,
    pairing::{self, Persist, Ui},
    store::NetMode,
    transport::NetConfig,
};

/// How long a finished invite stays visible in `antenna pairing`.
const KEEP_FINISHED: Duration = Duration::from_secs(600);

type Outcome = std::result::Result<LinkedReply, ErrorBody>;

#[derive(Debug, Clone)]
struct State {
    phase: &'static str,
    sas: Option<String>,
    sas_emoji: Option<String>,
    attempts: u32,
    result: Option<String>,
    /// A code is on the owner's screen now: from the `sas` event until the invite ends.
    code_shown: bool,
    /// Another invite of this node showed a code while this one was open (D-95). Then a spoken "it matched" may be
    /// about the other invite, so the confirmation must carry the code again (formal model F-4, `neg_nocode`). Never
    /// reset: an invite that showed a code and then ended (an attacker can make it fail) still counts.
    overlap: bool,
}

/// A live invite.
pub struct InviteEntry {
    /// ID (`antenna pairing confirm <id>`).
    pub id: String,
    link: String,
    link_app: String,
    trust: u8,
    label: Option<String>,
    created_ms: u64,
    expires_ms: u64,
    state: StdMutex<State>,
    events: broadcast::Sender<Event>,
    input: mpsc::UnboundedSender<Input>,
    done: watch::Sender<Option<Outcome>>,
}

impl std::fmt::Debug for InviteEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Invite({})", self.id)
    }
}

impl InviteEntry {
    /// Details without secrets (link and code): for subscriptions and for requests without the password.
    pub fn public_info(&self) -> InviteInfo {
        let mut i = self.info();
        i.link = String::new();
        i.link_app = String::new();
        i.sas = None;
        i.sas_emoji = None;
        i
    }

    /// Details for the owner (with the link and code; only after the password check).
    pub fn info(&self) -> InviteInfo {
        let s = self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        InviteInfo {
            id: self.id.clone(),
            link: self.link.clone(),
            link_app: self.link_app.clone(),
            trust: self.trust,
            label: self.label.clone(),
            net_mode: NetMode::for_trust(self.trust).as_str().into(),
            created_ms: self.created_ms,
            expires_ms: self.expires_ms,
            phase: s.phase.into(),
            sas: s.sas,
            sas_emoji: s.sas_emoji,
            attempts: s.attempts,
            confirm_without_code: s.phase == "needs_confirm" && !s.overlap,
            result: s.result,
        }
    }

    /// The daemon accepts the owner's "yes" without the code now (D-95).
    pub fn confirm_without_code(&self) -> bool {
        let s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        s.phase == "needs_confirm" && !s.overlap
    }

    /// A code is on the owner's screen now (the invite showed it and has not ended).
    fn code_shown(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .code_shown
    }

    /// Another invite of this node showed a code while this one was open.
    fn mark_overlap(&self) {
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .overlap = true;
    }

    /// The invite has not ended (linked, failed).
    fn open(&self) -> bool {
        !matches!(
            self.state
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .phase,
            "linked" | "failed"
        )
    }

    /// Event subscription (for `antenna invite`, which watches the invite).
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    /// Outcome (once there is one).
    pub fn done(&self) -> watch::Receiver<Option<Outcome>> {
        self.done.subscribe()
    }

    /// Whether the owner's attention is needed: read out the code or confirm the link.
    pub fn needs_owner(&self) -> bool {
        matches!(
            self.state
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .phase,
            "code_ready" | "needs_confirm"
        )
    }

    /// Decision of owner A. Confirmation is possible only after B has typed the correct code (a "yes" sent in advance
    /// does not count, PROTOCOL §9). `code`, when given, is the code the owner saw: the "yes" applies only to the invite
    /// with that code (a spoken "it matches" does not name the session, PROTOCOL §15).
    ///
    /// Without a code (D-95) the "yes" is the owner's click on this invite, after the joiner's node reported the correct
    /// code (`mac_B` in M5): accepted only while no other invite of this node showed a code during this one's life,
    /// because only then can the spoken "it matched" be about no other invite (formal model F-4: `neg_nocode` needs two
    /// invites with codes at once). Otherwise `code_required`: the owner types the code as before.
    pub fn decide(&self, yes: bool, code: Option<&str>) -> Result<()> {
        let (phase, sas, overlap) = {
            let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            (st.phase, st.sas.clone(), st.overlap)
        };
        let code = code.filter(|c| !c.trim().is_empty());
        if yes && code.is_none() && phase == "needs_confirm" && overlap {
            return Err(Error::new(
                code::CODE_REQUIRED,
                format!(
                    "another invite of this node showed a code while invite {} was open: type the code you read out \
                     and the other person confirmed, so that the confirmation names this invite",
                    self.id
                ),
            ));
        }
        if yes && let Some(c) = code {
            let want = sas.unwrap_or_default();
            let got = antenna_proto::sas::parse_input(c).unwrap_or_default();
            if want.is_empty() || !crypto::ct_eq(got.as_bytes(), want.as_bytes()) {
                return Err(Error::new(
                    code::SAS_MISMATCH,
                    format!(
                        "this is not the code of invite {}: confirm the invite whose code you read out",
                        self.id
                    ),
                ));
            }
        }
        if matches!(phase, "linked" | "failed") {
            return Err(Error::new(
                code::INVITE_UNAVAILABLE,
                format!("invite {} is already {phase}", self.id),
            ));
        }
        if yes && phase != "needs_confirm" {
            return Err(Error::bad_request(format!(
                "nothing to confirm yet (phase {phase}): the other side must type the code first"
            )));
        }
        self.input
            .send(Input::Confirm { yes, code: None })
            .map_err(|_| Error::new(code::INVITE_UNAVAILABLE, "invite is finished"))
    }

    fn on_event(&self, ev: &Event) {
        let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        match ev {
            Event::AttemptFailed { attempts, .. } => {
                // A failed attempt before the secret check: the previous code (if any) is no longer valid
                s.attempts = *attempts;
                s.phase = "waiting";
                s.sas = None;
                s.sas_emoji = None;
            }
            Event::Sas { code, emoji } => {
                s.phase = "code_ready";
                s.sas = Some(code.clone());
                s.sas_emoji = Some(emoji.clone());
                s.code_shown = true;
            }
            Event::PeerEnteredCode => s.phase = "peer_entered_code",
            Event::NeedInput { what, .. } if what == "confirm" => s.phase = "needs_confirm",
            Event::Waiting { what } if what == "session_init" => s.phase = "finishing",
            _ => {}
        }
    }

    fn finish(&self, r: Outcome) {
        {
            let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            match &r {
                Ok(l) => {
                    s.phase = "linked";
                    s.result = Some(l.contact.clone());
                }
                Err(e) => {
                    s.phase = "failed";
                    s.result = Some(e.code.clone());
                }
            }
            s.sas = None;
            s.sas_emoji = None;
            s.code_shown = false;
        }
        let _ = self.done.send(Some(r));
    }
}

/// Create an invite and start side A in the background.
pub async fn create(
    session: Arc<Session>,
    net: &NetConfig,
    trust: u8,
    ttl: Duration,
    label: Option<String>,
    auto_confirm: bool,
) -> Result<Arc<InviteEntry>> {
    let inv = pairing::create_invite(net, trust, ttl).await?;
    let id = data_encoding::BASE32_NOPAD
        .encode(&crypto::random::<5>())
        .to_ascii_lowercase();
    let (ev_tx, mut ev_rx) = mpsc::unbounded_channel::<Event>();
    let (in_tx, in_rx) = mpsc::unbounded_channel::<Input>();
    let entry = Arc::new(InviteEntry {
        id: id.clone(),
        link: inv.link.encode(),
        link_app: inv.link.encode_app(),
        trust,
        label: label.clone(),
        created_ms: now_ms(),
        expires_ms: inv.expires_ms,
        state: StdMutex::new(State {
            phase: "waiting",
            sas: None,
            sas_emoji: None,
            attempts: 0,
            result: None,
            code_shown: false,
            overlap: false,
        }),
        events: broadcast::channel(32).0,
        input: in_tx,
        done: watch::channel(None).0,
    });
    session
        .invites
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(id.clone(), entry.clone());
    // An open invite that already shows a code: the owner may be reading it out now (D-95).
    if session.other_invites(&id).iter().any(|o| o.code_shown()) {
        entry.mark_overlap();
    }
    session.invites_changed.send_modify(|v| *v += 1);
    let _ = session
        .events
        .send(NodeEvent::Invite(Box::new(entry.public_info())));
    // Side A events → invite state + subscribers
    {
        let entry = entry.clone();
        let s = session.clone();
        tokio::spawn(async move {
            while let Some(mut ev) = ev_rx.recv().await {
                entry.on_event(&ev);
                if let Event::Sas { .. } = ev {
                    // Two codes on the owner's screen at once: neither invite may be confirmed without its code
                    // (D-95). Marked after `on_event`, and new invites check at creation, so no order of events
                    // between two invites misses the overlap.
                    let others = s.other_invites(&entry.id);
                    for o in &others {
                        o.mark_overlap();
                    }
                    if others.iter().any(|o| o.code_shown()) {
                        entry.mark_overlap();
                    }
                }
                if let Event::NeedInput {
                    what,
                    confirm_without_code,
                } = &mut ev
                    && what == "confirm"
                {
                    *confirm_without_code = entry.confirm_without_code();
                }
                if matches!(ev, Event::Sas { .. } | Event::NeedInput { .. }) {
                    tracing::info!(
                        "invite {}: owner attention needed ({:?}); see `antenna pairing`",
                        entry.id,
                        ev
                    );
                }
                let _ = entry.events.send(ev);
                s.invites_changed.send_modify(|v| *v += 1);
                let _ = s
                    .events
                    .send(NodeEvent::Invite(Box::new(entry.public_info())));
            }
        });
    }
    // Side A itself
    {
        let entry = entry.clone();
        tokio::spawn(async move {
            let mut ui = Ui {
                events: ev_tx,
                inputs: in_rx,
            };
            let s2 = session.clone();
            let persist: Persist<'static> = Box::new(move |rec| s2.persist_link(rec));
            let r = tokio::select! {
                r = pairing::run_inviter(inv, label, auto_confirm, &mut ui, persist) => r,
                _ = session.closed_wait() => Err(Error::new(code::LOCKED, "keystore was locked during pairing")),
            };
            drop(ui);
            let outcome = match r {
                Ok(p) => {
                    let reply = LinkedReply {
                        contact: p.label.clone(),
                        link_id: p.link_id.to_hex(),
                        trust: p.trust,
                        net_mode: p.net_mode.as_str().into(),
                        kx_group: p.kx_group.clone(),
                        pairing_ms: p.pairing_ms,
                    };
                    match session.start_paired_link(p).await {
                        Ok(()) => Ok(reply),
                        Err(e) => Err(e.body()),
                    }
                }
                Err(e) => Err(e.body()),
            };
            match &outcome {
                Ok(l) => tracing::info!("invite {}: linked ({})", entry.id, &l.link_id[..8]),
                Err(e) => tracing::info!("invite {}: finished: {}", entry.id, e.code),
            }
            entry.finish(outcome);
            session.invites_changed.send_modify(|v| *v += 1);
            let _ = session
                .events
                .send(NodeEvent::Invite(Box::new(entry.public_info())));
            tokio::time::sleep(KEEP_FINISHED).await;
            session
                .invites
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&entry.id);
        });
    }
    Ok(entry)
}

impl Session {
    /// The other invites of this node that have not ended.
    fn other_invites(&self, id: &str) -> Vec<Arc<InviteEntry>> {
        let all: Vec<Arc<InviteEntry>> = self
            .invites
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .filter(|e| e.id != id)
            .cloned()
            .collect();
        all.into_iter().filter(|e| e.open()).collect()
    }

    /// Invite by ID.
    pub fn invite(&self, id: &str) -> Result<Arc<InviteEntry>> {
        self.invites
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned()
            .ok_or_else(|| Error::new(code::NOT_FOUND, format!("no invite {id:?}")))
    }

    /// `antenna pairing [--wait]`: invites; with `wait`, wait until one of them needs the owner's attention.
    pub async fn pairings(
        &self,
        wait: bool,
        timeout: Option<Duration>,
        reveal: bool,
    ) -> Result<Vec<InviteInfo>> {
        let mut rx = self.invites_changed.subscribe();
        let deadline = timeout.map(|t| tokio::time::Instant::now() + t);
        loop {
            if self.is_closed() {
                return Err(Error::new(code::LOCKED, "keystore was locked"));
            }
            rx.mark_unchanged();
            let entries: Vec<Arc<InviteEntry>> = self
                .invites
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .values()
                .cloned()
                .collect();
            let attention = entries.iter().any(|e| e.needs_owner());
            if !wait || attention {
                let mut v: Vec<InviteInfo> = entries
                    .iter()
                    .map(|e| if reveal { e.info() } else { e.public_info() })
                    .collect();
                v.sort_by_key(|i| i.created_ms);
                return Ok(v);
            }
            let ok = match deadline {
                Some(d) => tokio::time::timeout_at(d, rx.changed()).await.is_ok(),
                None => rx.changed().await.is_ok(),
            };
            if !ok {
                let mut v: Vec<InviteInfo> = entries
                    .iter()
                    .map(|e| if reveal { e.info() } else { e.public_info() })
                    .collect();
                v.sort_by_key(|i| i.created_ms);
                return Ok(v);
            }
        }
    }

    /// `antenna pairing confirm|cancel <id>`: decision of owner A, then wait for the outcome (up to 60 s). `code` is
    /// the code the owner read out: if given, it must match this invite's code.
    pub async fn pairing_decide(&self, id: &str, yes: bool, code: Option<&str>) -> Result<Outcome> {
        let e = self.invite(id)?;
        let mut done = e.done();
        e.decide(yes, code)?;
        let r = tokio::time::timeout(Duration::from_secs(60), async {
            done.wait_for(|d| d.is_some()).await.map(|v| v.clone())
        })
        .await;
        match r {
            Ok(Ok(Some(v))) => Ok(v),
            _ => Err(Error::new(
                code::TIMEOUT,
                "pairing did not finish in time; see `antenna pairing`",
            )),
        }
    }
}
