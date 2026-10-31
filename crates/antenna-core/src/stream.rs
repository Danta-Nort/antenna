// SPDX-License-Identifier: AGPL-3.0-only
//! Streaming messages (v0.2: an agent's reply shown as it is being written; `docs/PROTOCOL.md` §20,
//! `docs/CONTROL.md` §15).
//!
//! A stream is a "live" display of a message that is still being written. Only the final message goes into the history,
//! the hash-DAG, signatures and verification: an ordinary signed `text` message that goes through the ordinary queue;
//! the chunks are ephemeral.
//!
//! - **Established cryptography only** (SPEC §7, §15): the stream secret (32 random bytes) is passed inside a Triple
//!   Ratchet message (like a file secret, D-F-2); chunks are encrypted with the STREAM construction (`aead-stream`,
//!   ChaCha20-Poly1305, `StreamBE32`) under an HKDF-SHA256 key from the secret; the final message's salt is also HKDF
//!   from the secret.
//! - **SPEC bounds**: live display only to a contact of level 3+ (typing indicator, SPEC §4) and only if the recipient
//!   also trusts the sender at 3+; a message that needs approval is not streamed; the secret scanner
//!   ([`policy::SecretStream`]) checks every chunk while holding back the tail: when a secret is found, the stream is
//!   cut and the whole message goes to approval; "what the agent is doing" (`activity`) only to contacts of levels 4–5.
//! - A **source interruption** (the agent crashed, input was cut, a limit was exceeded) gives an "interrupted" final
//!   message: the text received so far plus the [`INTERRUPTED_MARK`]. A link interruption gives the recipient an
//!   `interrupted` event; the final message arrives through the ordinary queue and is recognized by its salt.

use std::{
    collections::HashMap,
    sync::{Arc, PoisonError, atomic::Ordering},
    time::{Duration, Instant},
};

use aead_stream::{DecryptorBE32, EncryptorBE32, StreamBE32};
use antenna_proto::{
    LinkId, MessageId, RoutingBlob,
    control::{SentReply, StreamEventBody, StreamView, code},
    link::{LinkRequest, LinkResponse, MAX_TEXT},
    stream::{
        AAD_LABEL, FINAL_SALT_INFO, INTERRUPTED_MARK, KEY_INFO, MAX_ACTIVITY, MAX_FRAME,
        MAX_PIECES, STREAM_VERSION, StreamEnd, StreamFrame, StreamOpen, StreamPiece,
    },
};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit};
use iroh::endpoint::{RecvStream, SendStream};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

use crate::{
    addressing::{Addr, AddrReq},
    agents::AgentCtx,
    crypto, e2e,
    error::{Error, Result},
    events::NodeEvent,
    history,
    node::{LinkShared, Session},
    now_ms, policy,
    store::{Db, LinkRow},
    transport,
};

/// Stream text limit: the final message must fit into a message together with the "interrupted" mark.
pub(crate) const MAX_STREAM_TEXT: usize = MAX_TEXT - 64;
/// Text limit of one chunk (more becomes several chunks).
const PIECE_TEXT: usize = 16 * 1024;
/// Frames no more often than this (chunks are merged): the first chunk goes out immediately.
const MIN_GAP: Duration = Duration::from_millis(30);
/// "Alive": an empty chunk if the source is silent (the agent is thinking, a tool is running).
const HEARTBEAT: Duration = Duration::from_secs(15);
/// The recipient waits for the next frame no longer than this.
const RECV_IDLE: Duration = Duration::from_secs(60);
/// The whole stream lasts no longer than this.
pub(crate) const MAX_DURATION: Duration = Duration::from_secs(30 * 60);
/// Simultaneous incoming streams per link.
const MAX_IN_PER_LINK: usize = 4;
/// How long to remember a cut stream in order to recognize its final message by salt.
const RECENT_MS: u64 = 15 * 60 * 1000;
/// How long the sender waits for the final message's delivery before closing the stream (the final message must
/// arrive before the stream ends).
const FINAL_ORDER_WAIT: Duration = Duration::from_secs(5);
/// The recipient's reply to the stream open and to the stream end.
const ACK_WAIT: Duration = Duration::from_secs(10);
/// How long the recipient waits for a final message announced by the last chunk before showing "interrupted".
const FINAL_LATE: Duration = Duration::from_secs(30);
/// How long the stream start waits for the contact's reply to the open (after that, live display counts as started).
const OPEN_WAIT: Duration = Duration::from_secs(3);

type Enc = EncryptorBE32<ChaCha20Poly1305>;
type Dec = DecryptorBE32<ChaCha20Poly1305>;

fn hex(b: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(b)
}

fn piece_cipher(open: &StreamOpen) -> ChaCha20Poly1305 {
    let k = crypto::hkdf32(&open.id, &open.secret, &[KEY_INFO]);
    ChaCha20Poly1305::new(&(*k).into())
}

fn piece_aad(link: &LinkId, id: &[u8; 16]) -> Vec<u8> {
    let mut a = Vec::with_capacity(AAD_LABEL.len() + 48);
    a.extend_from_slice(AAD_LABEL);
    a.extend_from_slice(&link.0);
    a.extend_from_slice(id);
    a
}

fn zero_prefix() -> aead_stream::Nonce<ChaCha20Poly1305, StreamBE32<ChaCha20Poly1305>> {
    Default::default()
}

/// Salt of the stream's final message: `HKDF-SHA256(salt = stream_id, ikm = secret, info = "x/stream/v0/final-salt")`.
pub(crate) fn final_salt(open: &StreamOpen) -> [u8; 32] {
    *crypto::hkdf32(&open.id, &open.secret, &[FINAL_SALT_INFO])
}

/// Chunk sealer (STREAM).
pub(crate) struct Sealer {
    enc: Option<Enc>,
    aad: Vec<u8>,
    count: u32,
}

impl Sealer {
    /// New stream sealer.
    pub(crate) fn new(link: &LinkId, open: &StreamOpen) -> Self {
        Self {
            enc: Some(Enc::from_aead(piece_cipher(open), &zero_prefix())),
            aad: piece_aad(link, &open.id),
            count: 0,
        }
    }

    /// Encrypt a chunk; `last` marks the last one (nothing can be encrypted after it).
    pub(crate) fn seal(&mut self, piece: &StreamPiece, last: bool) -> Result<StreamFrame> {
        if self.count >= MAX_PIECES {
            return Err(Error::bad_request("stream: too many pieces"));
        }
        let mut buf = antenna_proto::padding::pad(&antenna_proto::to_cbor(piece)?)
            .map_err(|e| Error::internal(e.to_string()))?;
        if last {
            let enc = self
                .enc
                .take()
                .ok_or_else(|| Error::internal("stream already finished"))?;
            enc.encrypt_last_in_place(&self.aad, &mut buf)
                .map_err(|_| Error::internal("STREAM encryption failed"))?;
        } else {
            let enc = self
                .enc
                .as_mut()
                .ok_or_else(|| Error::internal("stream already finished"))?;
            enc.encrypt_next_in_place(&self.aad, &mut buf)
                .map_err(|_| Error::internal("STREAM counter exhausted"))?;
        }
        self.count += 1;
        Ok(StreamFrame { c: buf, last })
    }
}

/// Chunk opener (STREAM): reordering, substitution, truncation and appending after the last chunk are errors.
pub(crate) struct Opener {
    dec: Option<Dec>,
    aad: Vec<u8>,
    count: u32,
}

impl Opener {
    /// New stream opener.
    pub(crate) fn new(link: &LinkId, open: &StreamOpen) -> Self {
        Self {
            dec: Some(Dec::from_aead(piece_cipher(open), &zero_prefix())),
            aad: piece_aad(link, &open.id),
            count: 0,
        }
    }

    /// Decrypt a frame.
    pub(crate) fn open(&mut self, f: &StreamFrame) -> Result<StreamPiece> {
        if self.count >= MAX_PIECES {
            return Err(Error::bad_request("stream: too many pieces"));
        }
        let mut buf = f.c.clone();
        let ok = if f.last {
            match self.dec.take() {
                Some(d) => d.decrypt_last_in_place(&self.aad, &mut buf).is_ok(),
                None => false,
            }
        } else {
            match self.dec.as_mut() {
                Some(d) => d.decrypt_next_in_place(&self.aad, &mut buf).is_ok(),
                None => false,
            }
        };
        if !ok {
            self.dec = None;
            return Err(Error::bad_request(
                "stream piece authentication failed (reordered, forged or after the last piece)",
            ));
        }
        self.count += 1;
        let body =
            antenna_proto::padding::unpad(&buf).map_err(|e| Error::bad_request(e.to_string()))?;
        Ok(antenna_proto::from_cbor(body)?)
    }
}

/// Splits text into pieces of at most `max` bytes at character boundaries.
fn split_text(text: &str, max: usize) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = text;
    while rest.len() > max {
        let cut = policy::floor_boundary(rest, max).max(1);
        let cut = if rest.is_char_boundary(cut) {
            cut
        } else {
            rest.char_indices().nth(1).map_or(rest.len(), |(i, _)| i)
        };
        out.push(&rest[..cut]);
        rest = &rest[cut..];
    }
    out.push(rest);
    out
}

/// `activity` from a contact or an agent: visible characters only, no longer than [`MAX_ACTIVITY`].
fn clean_activity(a: &str) -> String {
    a.chars()
        .filter(|c| !c.is_control() && !policy::is_invisible(*c))
        .take(MAX_ACTIVITY)
        .collect()
}

// Sender

/// Who writes the stream.
#[derive(Debug, Clone)]
pub(crate) enum Author {
    /// The owner (`antenna send --stream`).
    Owner,
    /// An agent (its own token, the MCP host tree or a wake launch).
    Agent(AgentCtx),
}

enum Live {
    Text(String, Option<String>),
    End(StreamEnd, Option<MessageId>),
}

/// An outgoing stream in the registry (for `streams`).
pub(crate) struct OutEntry {
    link: LinkId,
    contact: String,
    /// Our own agent that writes (its local name), for the owner's view.
    agent: Option<String>,
    text: String,
    activity: Option<String>,
    live: bool,
    seq: u64,
    started_ms: u64,
}

/// A final message waiting for the owner's decision: after `approve` the daemon sends it itself (a stream has no
/// repeated input).
pub(crate) struct Pending {
    link: LinkId,
    author: Author,
    text: String,
    salt: [u8; 32],
    /// The final message's address and topic (v6), decided when the stream began.
    addr: Addr,
    /// The stream whose final message awaits approval: after sending, subscribers get `final` with this `stream_id`
    /// (as in the ordinary case), and the window replaces the "awaiting approval" bubble with the final message.
    stream_id: [u8; 16],
    /// Next event number of this stream.
    seq: u64,
    /// How the source ended (`done` / `interrupted`).
    end: StreamEnd,
}

/// Incoming streams of a link.
#[derive(Default)]
pub(crate) struct InStreams {
    live: HashMap<[u8; 16], InLive>,
    recent: Vec<Recent>,
}

struct InLive {
    /// The contact's agent that writes, as its node named it in the opening (`stream-agent/0`).
    agent: Option<String>,
    text: String,
    activity: Option<String>,
    seq: u64,
    started_ms: u64,
    salt: [u8; 32],
}

struct Recent {
    id: [u8; 16],
    agent: Option<String>,
    salt: [u8; 32],
    seq: u64,
    text_len: u64,
    until_ms: u64,
    finalized: bool,
    /// The end announced by the last chunk (`done`/`interrupted`); `None` means a dropped connection or `cut`.
    end: Option<StreamEnd>,
}

/// A stream being written.
pub(crate) struct StreamWriter {
    s: Arc<Session>,
    row: LinkRow,
    author: Author,
    open: StreamOpen,
    salt: [u8; 32],
    /// The final message's address and topic (v6, PROTOCOL §23).
    addr: Addr,
    text: String,
    scanner: policy::SecretStream,
    live_tx: Option<mpsc::UnboundedSender<Live>>,
    live: bool,
    no_live: Option<&'static str>,
    show_activity: bool,
    activity: Option<String>,
    seq: u64,
    truncated: bool,
    label_gen: u64,
    finished: bool,
    /// The link, for its current trust level: at level 5, the owner's own computer, a secret does not cut the stream
    /// (D-99); the final message's audit entry records it.
    shared: Arc<LinkShared>,
    /// How many bytes of `text` went out to the display so far (the scanner holds back the rest).
    released: usize,
}

impl Session {
    /// Start an outgoing stream to a contact. The policy that does not depend on the text (level, link isolation,
    /// no-write-down) is decided here: if approval is needed, there is no live display and the final message goes to
    /// approval.
    pub(crate) async fn stream_begin(
        self: &Arc<Self>,
        author: Author,
        contact: &str,
        req: &AddrReq,
    ) -> Result<StreamWriter> {
        let row = match &author {
            Author::Owner => self.find_link(contact)?,
            Author::Agent(ctx) => self.agent_link(ctx, contact)?,
        };
        // The final message's address: the owner's goes to the person by default, an agent's answers what it read
        let addr = match &author {
            Author::Owner => self.owner_addr(&row, req)?,
            Author::Agent(ctx) => self.agent_addr(ctx, &row, req)?,
        };
        self.ensure_running(&row.link_id)?;
        let rt = self.rt(&row.link_id)?;
        if let Some(e) = rt.shared.send_block() {
            return Err(e);
        }
        // The live display names the agent that writes (PG-20), by the name the contact knows it by, only to a node
        // that parses the field; an older one gets the opening it always got
        let agent = match &author {
            Author::Agent(ctx) if rt.shared.peer_supports_stream_agent() => {
                Some(self.agent_public_name(&ctx.name, &row.link_id))
            }
            _ => None,
        };
        let open = StreamOpen {
            v: STREAM_VERSION,
            id: crypto::random::<16>(),
            secret: crypto::random::<32>(),
            ts: now_ms(),
            agent,
        };
        let salt = final_salt(&open);
        let trust = rt.shared.trust.load(Ordering::SeqCst);
        let label_gen = crate::store::LABEL_GEN.load(Ordering::SeqCst);
        let mut no_live = if trust < 3 {
            Some("trust_below_3")
        } else {
            None
        };
        if no_live.is_none()
            && let Author::Agent(ctx) = &author
            && !self.agent_outflow_reasons(ctx, &row, "")?.is_empty()
        {
            no_live = Some("approval_needed");
        }
        let mut w = StreamWriter {
            s: self.clone(),
            row,
            author,
            salt,
            addr,
            text: String::new(),
            scanner: policy::SecretStream::new(),
            live_tx: None,
            live: false,
            no_live,
            show_activity: trust >= 4,
            activity: None,
            seq: 0,
            truncated: false,
            label_gen,
            finished: false,
            shared: rt.shared.clone(),
            released: 0,
            open,
        };
        if w.no_live.is_none() {
            let (tx, rx) = mpsc::unbounded_channel();
            let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
            tokio::spawn(live_task(rt.shared.clone(), w.open.clone(), rx, ack_tx));
            // The contact's reply to the open (usually milliseconds): `live` in `stream_started` is the truth, not a
            // hope. The source text meanwhile waits in the channel (or in its output): nothing is lost.
            match tokio::time::timeout(OPEN_WAIT, ack_rx).await {
                Ok(Ok(Ok(()))) | Err(_) => {
                    w.live_tx = Some(tx);
                    w.live = true;
                }
                Ok(Ok(Err(reason))) => w.no_live = Some(reason),
                Ok(Err(_)) => w.no_live = Some("offline"),
            }
        }
        self.streams_out
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(
                w.open.id,
                OutEntry {
                    link: w.row.link_id,
                    contact: w.row.label.clone(),
                    agent: author_agent(&w.author),
                    text: String::new(),
                    activity: None,
                    live: w.live,
                    seq: 0,
                    started_ms: w.open.ts,
                },
            );
        w.emit_out("streaming", Some(String::new()), None, None, None, None);
        Ok(w)
    }

    /// Running streams (incoming ones of all links and our own outgoing ones) with their text at this moment
    /// (`streams`).
    pub fn streams(&self) -> Vec<StreamView> {
        let mut out = Vec::new();
        for rt in self.running_links() {
            let sh = &rt.shared;
            let g = sh.streams_in.lock().unwrap_or_else(PoisonError::into_inner);
            for (id, l) in &g.live {
                out.push(StreamView {
                    contact: sh.label.clone(),
                    link_id: sh.link_id.to_hex(),
                    stream_id: hex(id),
                    direction: "in".into(),
                    text: l.text.clone(),
                    activity: l.activity.clone(),
                    live: true,
                    seq: l.seq,
                    started_ms: l.started_ms,
                    via_agent: l.agent.clone(),
                });
            }
        }
        for (id, e) in self
            .streams_out
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
        {
            out.push(StreamView {
                contact: e.contact.clone(),
                link_id: e.link.to_hex(),
                stream_id: hex(id),
                direction: "out".into(),
                text: e.text.clone(),
                activity: e.activity.clone(),
                live: e.live,
                seq: e.seq,
                started_ms: e.started_ms,
                via_agent: e.agent.clone(),
            });
        }
        out.sort_by_key(|v| v.started_ms);
        out
    }
}

/// Our own agent that writes a stream (its local name), for the owner's view.
fn author_agent(a: &Author) -> Option<String> {
    match a {
        Author::Agent(ctx) => Some(ctx.name.clone()),
        Author::Owner => None,
    }
}

/// The owner approved the final message of a cut stream: the daemon sends it itself under that approval, with the
/// stream's salt (a stream has no repeated input, D-70), and subscribers get the same `final` event as without approval
/// (D-76).
pub(crate) async fn send_kept_final(
    s: &Arc<Session>,
    p: Pending,
    approval_id: &str,
) -> Result<SentReply> {
    let row =
        s.db.lock()
            .unwrap_or_else(PoisonError::into_inner)
            .link(&p.link)?;
    let (id, sent) = send_final(
        s,
        &p.author,
        &row,
        &p.text,
        Duration::ZERO,
        Some(approval_id),
        p.salt,
        &p.addr,
    )
    .await?;
    let _ = s.events.send(NodeEvent::Stream {
        link: row.link_id,
        body: Box::new(StreamEventBody {
            contact: row.label.clone(),
            link_id: row.link_id.to_hex(),
            stream_id: hex(&p.stream_id),
            direction: "out".into(),
            state: "final".into(),
            seq: p.seq,
            delta: None,
            text_len: p.text.len() as u64,
            activity: None,
            live: false,
            message_id: Some(id.to_hex()),
            end: Some(p.end.as_str().into()),
            reason: None,
            text: None,
            via_agent: author_agent(&p.author),
        }),
    });
    Ok(sent)
}

/// The stream's final message under the ordinary `send` policy (owner: secret scanner; agent: level, link isolation,
/// no-write-down, secrets, limit) with the stream's salt.
#[allow(
    clippy::too_many_arguments,
    reason = "the `send` inputs plus the stream's own salt, approval and address"
)]
async fn send_final(
    s: &Arc<Session>,
    author: &Author,
    row: &LinkRow,
    text: &str,
    wait: Duration,
    approval_id: Option<&str>,
    salt: [u8; 32],
    addr: &Addr,
) -> Result<(MessageId, SentReply)> {
    match author {
        Author::Owner => {
            s.owner_send_row(row, text, wait, approval_id, Some(salt), addr)
                .await
        }
        Author::Agent(ctx) => {
            s.agent_send_row(ctx, row, text, wait, approval_id, Some(salt), addr)
                .await
        }
    }
}

impl StreamWriter {
    /// Stream ID (32 hex).
    pub(crate) fn id_hex(&self) -> String {
        hex(&self.open.id)
    }

    /// The contact sees the stream as it is written (at this moment).
    pub(crate) fn is_live(&self) -> bool {
        self.live
    }

    /// Why there is no live display.
    pub(crate) fn no_live_reason(&self) -> Option<&'static str> {
        self.no_live
    }

    #[allow(
        clippy::too_many_arguments,
        reason = "one optional value per field of the stream event; each caller names the ones it sets"
    )]
    fn emit_out(
        &mut self,
        state: &str,
        delta: Option<String>,
        message_id: Option<String>,
        end: Option<&str>,
        reason: Option<&str>,
        text: Option<String>,
    ) {
        let seq = self.seq;
        self.seq += 1;
        let body = StreamEventBody {
            contact: self.row.label.clone(),
            link_id: self.row.link_id.to_hex(),
            stream_id: self.id_hex(),
            direction: "out".into(),
            state: state.into(),
            seq,
            delta: delta.clone(),
            text_len: self.text.len() as u64,
            activity: self.activity.clone(),
            live: self.live,
            message_id,
            end: end.map(Into::into),
            reason: reason.map(Into::into),
            text,
            via_agent: author_agent(&self.author),
        };
        if let Some(e) = self
            .s
            .streams_out
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&self.open.id)
        {
            if let Some(d) = &delta {
                e.text.push_str(d);
            }
            e.activity = self.activity.clone();
            e.live = self.live;
            e.seq = seq;
        }
        let _ = self.s.events.send(NodeEvent::Stream {
            link: self.row.link_id,
            body: Box::new(body),
        });
    }

    /// Cut the live display: the contact sees "interrupted", the final message comes later (approval) or via `finish`.
    fn cut_live(&mut self, why: &'static str) {
        if let Some(tx) = self.live_tx.take() {
            let _ = tx.send(Live::End(StreamEnd::Cut, None));
        }
        if self.live {
            self.live = false;
            self.no_live = Some(why);
        }
    }

    /// Whether the agent's session label has changed so that sending to this contact now needs approval.
    fn agent_label_still_clear(&mut self) -> bool {
        let Author::Agent(ctx) = &self.author else {
            return true;
        };
        let g = crate::store::LABEL_GEN.load(Ordering::SeqCst);
        if g == self.label_gen {
            return true;
        }
        self.label_gen = g;
        matches!(self.s.agent_outflow_reasons(ctx, &self.row, ""), Ok(r) if r.is_empty())
    }

    /// Continuation of the text.
    pub(crate) fn push(&mut self, chunk: &str) {
        if chunk.is_empty() || self.finished {
            return;
        }
        let room = MAX_STREAM_TEXT.saturating_sub(self.text.len());
        let chunk = if chunk.len() > room {
            self.truncated = true;
            &chunk[..policy::floor_boundary(chunk, room)]
        } else {
            chunk
        };
        if chunk.is_empty() {
            return;
        }
        self.text.push_str(chunk);
        // The agent may have read another link's data during the stream: from here on, only through approval
        if self.live && !self.agent_label_still_clear() {
            self.cut_live("approval_needed");
        }
        let step = if self.shared.trust.load(Ordering::SeqCst) >= policy::OWN_COMPUTER {
            // Level 5, the owner's own computer (D-99): nothing is held back for the scanner; the final message's
            // audit entry records what it finds. Whatever an earlier, lower level held back goes out first.
            self.scanner = policy::SecretStream::new();
            antenna_files::secrets::StreamStep {
                release: self.text[self.released..].to_string(),
                findings: Vec::new(),
            }
        } else {
            self.scanner.push(chunk)
        };
        if !step.findings.is_empty() {
            // A secret was found: the stream is cut, the whole message goes to approval (D-40)
            self.cut_live("approval_needed");
            return;
        }
        if step.release.is_empty() {
            return;
        }
        self.released += step.release.len();
        if let Some(tx) = &self.live_tx {
            let _ = tx.send(Live::Text(step.release.clone(), None));
        }
        self.emit_out("streaming", Some(step.release), None, None, None, None);
    }

    /// What the source is doing (`tool:Read`); `None` clears it. Only to contacts of levels 4–5.
    pub(crate) fn set_activity(&mut self, a: Option<&str>) {
        // This string goes to the contact too: through the secret scanner
        let a = a
            .map(clean_activity)
            .filter(|s| !s.is_empty() && policy::scan_secrets(s).is_empty());
        if a == self.activity || self.finished {
            return;
        }
        self.activity = a;
        if self.show_activity
            && let Some(tx) = &self.live_tx
        {
            let _ = tx.send(Live::Text(
                String::new(),
                Some(self.activity.clone().unwrap_or_default()),
            ));
        }
        self.emit_out("streaming", Some(String::new()), None, None, None, None);
    }

    /// Finish the stream: the final message is an ordinary message under the `send` policy. `Interrupted` (or text
    /// longer than the limit) gives the text received so far with the "interrupted" mark. If approval is needed, the
    /// result is `approval_required` and the final message is sent after approval.
    pub(crate) async fn finish(mut self, end: StreamEnd, wait: Duration) -> Result<SentReply> {
        self.finished = true;
        // The tail held by the scanner (no secret: it is released)
        let tail = self.scanner.finish();
        if step_ok(&tail) && !tail.release.is_empty() {
            self.released += tail.release.len();
            if let Some(tx) = &self.live_tx {
                let _ = tx.send(Live::Text(tail.release.clone(), None));
            }
            self.emit_out("streaming", Some(tail.release), None, None, None, None);
        }
        let end = if self.truncated {
            StreamEnd::Interrupted
        } else {
            end
        };
        let mut text = self.text.trim_end_matches('\u{0}').to_string();
        if text.trim().is_empty() {
            self.close_live(StreamEnd::Interrupted, None);
            self.emit_out(
                "interrupted",
                None,
                None,
                None,
                Some("empty"),
                Some(String::new()),
            );
            return Err(Error::bad_request(
                "the stream produced no text: nothing was sent",
            ));
        }
        if end != StreamEnd::Done {
            text.push_str(INTERRUPTED_MARK);
        }
        // The final message is delivered before the live stream ends: the recipient's `final` event already finds the
        // message
        let wait = if self.live_tx.is_some() {
            wait.max(FINAL_ORDER_WAIT)
        } else {
            wait
        };
        let r = send_final(
            &self.s,
            &self.author,
            &self.row,
            &text,
            wait,
            None,
            self.salt,
            &self.addr,
        )
        .await;
        match r {
            Ok((id, sent)) => {
                self.close_live(end, Some(id));
                self.emit_out(
                    "final",
                    None,
                    Some(id.to_hex()),
                    Some(end.as_str()),
                    None,
                    None,
                );
                Ok(sent)
            }
            Err(e) => {
                if e.code == code::APPROVAL_REQUIRED
                    && let Some(a) = &e.approval
                {
                    self.s
                        .continuations
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .entry(a.id.clone())
                        .or_insert_with(|| {
                            crate::approvals::Continuation::Stream(Pending {
                                link: self.row.link_id,
                                author: self.author.clone(),
                                text: text.clone(),
                                salt: self.salt,
                                addr: self.addr.clone(),
                                stream_id: self.open.id,
                                // The one following `interrupted{cut}` below
                                seq: self.seq + 1,
                                end,
                            })
                        });
                }
                let reason = if e.code == code::APPROVAL_REQUIRED {
                    "cut"
                } else {
                    e.code
                };
                self.close_live(
                    if e.code == code::APPROVAL_REQUIRED {
                        StreamEnd::Cut
                    } else {
                        StreamEnd::Interrupted
                    },
                    None,
                );
                let full = self.text.clone();
                self.emit_out("interrupted", None, None, None, Some(reason), Some(full));
                Err(e)
            }
        }
    }

    fn close_live(&mut self, end: StreamEnd, final_id: Option<MessageId>) {
        if let Some(tx) = self.live_tx.take() {
            let _ = tx.send(Live::End(end, final_id));
        }
    }
}

fn step_ok(s: &antenna_files::secrets::StreamStep) -> bool {
    s.findings.is_empty()
}

impl Drop for StreamWriter {
    fn drop(&mut self) {
        // Not finished (caller error, panic): the contact's stream gets cut (channel closed → "interrupted")
        self.s
            .streams_out
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&self.open.id);
    }
}

/// Network part of an outgoing stream: `stream_open`, chunks as they appear, the end. On any error the live display
/// ends silently (the final message still goes through the ordinary queue).
async fn live_task(
    sh: Arc<LinkShared>,
    open: StreamOpen,
    mut rx: mpsc::UnboundedReceiver<Live>,
    ack: tokio::sync::oneshot::Sender<std::result::Result<(), &'static str>>,
) {
    let mut ack = Some(ack);
    let r = live_run(&sh, &open, &mut rx, &mut ack).await;
    if let Some(a) = ack.take() {
        let _ = a.send(Err(match &r {
            Err(e) if e.code == "contact_refused" => "contact_refused",
            Err(e) if e.code == code::READ_ONLY || e.code == code::REKEY_REQUIRED => "blocked",
            _ => "offline",
        }));
    }
    if let Err(e) = r {
        tracing::debug!("link {}: live stream ended: {e:?}", sh.short());
    }
    // Drain the channel so that the writer does not pile up
    rx.close();
    while rx.recv().await.is_some() {}
}

async fn live_run(
    sh: &Arc<LinkShared>,
    open: &StreamOpen,
    rx: &mut mpsc::UnboundedReceiver<Live>,
    ack: &mut Option<tokio::sync::oneshot::Sender<std::result::Result<(), &'static str>>>,
) -> Result<()> {
    let conn = sh.connect_raw().await?;
    let pt = Zeroizing::new(antenna_proto::to_cbor(open)?);
    let blob = {
        let sh2 = sh.clone();
        tokio::task::spawn_blocking(move || sh2.seal_ephemeral(&pt))
            .await
            .map_err(|e| Error::internal(e.to_string()))??
    };
    let (mut send, mut recv) = conn
        .open_bi()
        .await
        .map_err(|e| Error::network(format!("open stream: {e}")))?;
    sh.touch_pub();
    transport::write_frame(
        &mut send,
        &antenna_proto::to_cbor(&LinkRequest::StreamOpen { blob })?,
    )
    .await?;
    let reply = tokio::time::timeout(ACK_WAIT, transport::read_frame(&mut recv, MAX_FRAME))
        .await
        .map_err(|_| Error::network("stream open: no answer"))??;
    match antenna_proto::from_cbor::<LinkResponse>(&reply)? {
        LinkResponse::Ok => {
            if let Some(a) = ack.take() {
                let _ = a.send(Ok(()));
            }
        }
        LinkResponse::Rejected { reason } => {
            return Err(Error::new(
                "contact_refused",
                format!("contact refused the stream: {reason}"),
            ));
        }
        other => return Err(Error::network(format!("stream open: {other:?}"))),
    }
    let mut sealer = Sealer::new(&sh.link_id, open);
    let mut last_sent = Instant::now() - MIN_GAP;
    loop {
        let first = match tokio::time::timeout(HEARTBEAT, rx.recv()).await {
            Err(_) => {
                // The source is silent: an "alive" chunk so that the recipient does not consider the stream cut
                send_piece(sh, &mut send, &mut sealer, "", None, None, None).await?;
                last_sent = Instant::now();
                continue;
            }
            // The writer disappeared without an end (error, panic): "interrupted" without a final message
            Ok(None) => Live::End(StreamEnd::Interrupted, None),
            Ok(Some(m)) => m,
        };
        let (mut text, mut activity, mut end) = match first {
            Live::Text(t, a) => (t, a, None),
            Live::End(e, f) => (String::new(), None, Some((e, f))),
        };
        if end.is_none() {
            // Merge what has accumulated, but frames no more often than MIN_GAP (the first one immediately)
            let since = last_sent.elapsed();
            if since < MIN_GAP {
                tokio::time::sleep(MIN_GAP - since).await;
            }
            while let Ok(m) = rx.try_recv() {
                match m {
                    Live::Text(t, a) => {
                        text.push_str(&t);
                        if a.is_some() {
                            activity = a;
                        }
                    }
                    Live::End(e, f) => {
                        end = Some((e, f));
                        break;
                    }
                }
            }
        }
        let parts = split_text(&text, PIECE_TEXT);
        let n = parts.len();
        for (i, part) in parts.into_iter().enumerate() {
            let act = if i + 1 == n { activity.take() } else { None };
            match (i + 1 == n, end) {
                (true, Some((e, f))) => {
                    send_piece(sh, &mut send, &mut sealer, part, act, Some(e), f).await?;
                }
                _ => {
                    if part.is_empty() && act.is_none() {
                        continue;
                    }
                    send_piece(sh, &mut send, &mut sealer, part, act, None, None).await?;
                }
            }
        }
        last_sent = Instant::now();
        if end.is_some() {
            let _ = send.finish();
            // The recipient's confirmation (optional: the final message is already in the queue)
            let _ =
                tokio::time::timeout(ACK_WAIT, transport::read_frame(&mut recv, MAX_FRAME)).await;
            return Ok(());
        }
    }
}

#[allow(
    clippy::too_many_arguments,
    reason = "the fields of one stream piece next to the stream's transport and sealing state"
)]
async fn send_piece(
    sh: &LinkShared,
    send: &mut SendStream,
    sealer: &mut Sealer,
    text: &str,
    activity: Option<String>,
    end: Option<StreamEnd>,
    final_id: Option<MessageId>,
) -> Result<()> {
    let piece = StreamPiece {
        text: text.to_string(),
        activity,
        end,
        final_id,
    };
    let frame = sealer.seal(&piece, end.is_some())?;
    transport::write_frame(send, &antenna_proto::to_cbor(&frame)?).await?;
    sh.touch_pub();
    Ok(())
}

// Link: E2E stream open and the recipient

impl LinkShared {
    /// Plaintext → a Triple Ratchet message outside the history (stream open). The ratchet state and the state counter
    /// are committed as for an ordinary send (rollback protection, §17).
    pub(crate) fn seal_ephemeral(&self, plaintext: &[u8]) -> Result<RoutingBlob> {
        if let Some(e) = self.send_block() {
            return Err(e);
        }
        let mut db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let tx = db.tx()?;
        let enc = e2e::encrypt(
            &tx,
            &self.link_id,
            &self.sig_local,
            &self.sig_remote,
            plaintext,
        )?;
        let blob = history::seal_blob(&self.link_id, &enc)?;
        let counter = Db::bump_state(&tx, &self.link_id)?;
        tx.commit()?;
        drop(db);
        self.after_commit(counter);
        Ok(blob)
    }

    /// A Triple Ratchet message outside the history → plaintext (the contact's stream open).
    pub(crate) fn open_ephemeral(&self, blob: &RoutingBlob) -> Result<Zeroizing<Vec<u8>>> {
        if blob.link != self.link_id {
            return Err(Error::bad_request("wrong link"));
        }
        let (kind, bytes) = history::unseal(blob)?;
        if kind != antenna_proto::link::e2e_type::WHISPER {
            return Err(Error::bad_request("unexpected_prekey"));
        }
        let mut db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let tx = db.tx()?;
        let pt = match e2e::decrypt(
            &tx,
            &self.link_id,
            &self.sig_local,
            &self.sig_remote,
            kind,
            &bytes,
        )? {
            e2e::Decrypted::Duplicate => return Err(Error::bad_request("duplicate")),
            e2e::Decrypted::Message { plaintext, .. } => plaintext,
        };
        let counter = Db::bump_state(&tx, &self.link_id)?;
        tx.commit()?;
        drop(db);
        self.after_commit(counter);
        Ok(pt)
    }

    fn emit_in(&self, id: &[u8; 16], body: StreamEventBodyIn) {
        let ev = StreamEventBody {
            contact: self.label.clone(),
            link_id: self.link_id.to_hex(),
            stream_id: hex(id),
            direction: "in".into(),
            state: body.state.into(),
            seq: body.seq,
            delta: body.delta,
            text_len: body.text_len,
            activity: body.activity,
            live: true,
            message_id: body.message_id,
            end: body.end.map(Into::into),
            reason: body.reason.map(Into::into),
            text: body.text,
            via_agent: body.via_agent,
        };
        let _ = self.events.send(NodeEvent::Stream {
            link: self.link_id,
            body: Box::new(ev),
        });
    }

    /// Incoming stream (`stream_open` and frames on the same QUIC stream). A refusal is a `rejected` reply; the contact
    /// then sends only the final message.
    pub(crate) async fn serve_stream(
        self: Arc<Self>,
        blob: RoutingBlob,
        mut send: SendStream,
        mut recv: RecvStream,
    ) {
        let reject = |reason: &str| LinkResponse::Rejected {
            reason: reason.into(),
        };
        let early = if self.trust.load(Ordering::SeqCst) < 3 {
            // A stream is a typing indicator: only between contacts of level 3+ (SPEC §4)
            Some(reject("level"))
        } else if self.send_block().is_some() {
            Some(reject(code::READ_ONLY))
        } else if self
            .streams_in
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .live
            .len()
            >= MAX_IN_PER_LINK
        {
            Some(reject("busy"))
        } else if !self.admit_incoming_pub().await {
            Some(reject(code::RATE_LIMITED))
        } else {
            None
        };
        if let Some(r) = early {
            write_resp(&mut send, &r).await;
            return;
        }
        let me = self.clone();
        let open = match tokio::task::spawn_blocking(move || me.open_ephemeral(&blob)).await {
            Ok(Ok(pt)) => antenna_proto::from_cbor::<StreamOpen>(&pt).ok(),
            _ => None,
        };
        // The agent's name follows the announcement rules (PROTOCOL §21); it is the contact's word for the display
        let Some(open) = open.filter(|o| {
            o.v == STREAM_VERSION
                && o.agent
                    .as_deref()
                    .is_none_or(antenna_proto::AgentAnnounce::valid_name)
        }) else {
            write_resp(&mut send, &reject("malformed")).await;
            return;
        };
        let agent = open.agent.clone();
        let id = open.id;
        let salt = final_salt(&open);
        // The limit check and the insertion happen under one lock: otherwise simultaneous opens would all pass the
        // check together while the ratchet decrypts
        let refused = {
            let mut g = self
                .streams_in
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let refused = if g.live.contains_key(&id) || g.recent.iter().any(|r| r.id == id) {
                Some("duplicate")
            } else if g.live.len() >= MAX_IN_PER_LINK {
                Some("busy")
            } else {
                None
            };
            if refused.is_none() {
                g.live.insert(
                    id,
                    InLive {
                        agent: agent.clone(),
                        text: String::new(),
                        activity: None,
                        seq: 0,
                        started_ms: now_ms(),
                        salt,
                    },
                );
            }
            refused
        };
        if let Some(r) = refused {
            write_resp(&mut send, &reject(r)).await;
            return;
        }
        write_resp(&mut send, &LinkResponse::Ok).await;
        self.emit_in(
            &id,
            StreamEventBodyIn {
                via_agent: agent.clone(),
                state: "streaming",
                seq: 0,
                delta: Some(String::new()),
                text_len: 0,
                ..Default::default()
            },
        );
        let outcome = self.read_pieces(&open, &mut recv).await;
        // The end: an event and a "recent" stream record (the final message can be recognized by salt later)
        let (live, now) = {
            let mut g = self
                .streams_in
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let now = now_ms();
            g.recent.retain(|r| r.until_ms > now);
            (g.live.remove(&id), now)
        };
        let Some(live) = live else { return };
        let seq = live.seq + 1;
        let text_len = live.text.len() as u64;
        // The final message can only be the contact's message in this link's history with this stream's salt
        // (otherwise `final_id` from a chunk could point to someone else's message); if it has not arrived yet, it is
        // recognized by salt when it arrives
        let verified = match &outcome {
            Ok((_, Some(fid))) => {
                let me = self.clone();
                let (fid, salt) = (*fid, live.salt);
                tokio::task::spawn_blocking(move || me.final_matches(&fid, &salt))
                    .await
                    .unwrap_or(false)
            }
            _ => false,
        };
        let declared_end = outcome.as_ref().ok().map(|(e, _)| *e);
        let finalized = match outcome {
            Ok((end @ (StreamEnd::Done | StreamEnd::Interrupted), Some(fid))) if verified => {
                self.emit_in(
                    &id,
                    StreamEventBodyIn {
                        via_agent: agent.clone(),
                        state: "final",
                        seq,
                        text_len,
                        message_id: Some(fid.to_hex()),
                        end: Some(end.as_str()),
                        ..Default::default()
                    },
                );
                true
            }
            Ok((StreamEnd::Done | StreamEnd::Interrupted, Some(_))) => {
                // The final message is announced but not yet in the history: the `final` event comes when it arrives
                // (by salt); if it does not arrive within FINAL_LATE, "interrupted"
                let me = self.clone();
                let text = live.text.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(FINAL_LATE).await;
                    me.late_final_missing(&id, text);
                });
                false
            }
            Ok((end, _)) => {
                self.emit_in(
                    &id,
                    StreamEventBodyIn {
                        via_agent: agent.clone(),
                        state: "interrupted",
                        seq,
                        text_len,
                        reason: Some(if end == StreamEnd::Cut {
                            "cut"
                        } else {
                            "sender_aborted"
                        }),
                        text: Some(live.text.clone()),
                        ..Default::default()
                    },
                );
                false
            }
            Err(reason) => {
                self.emit_in(
                    &id,
                    StreamEventBodyIn {
                        via_agent: agent.clone(),
                        state: "interrupted",
                        seq,
                        text_len,
                        reason: Some(reason),
                        text: Some(live.text.clone()),
                        ..Default::default()
                    },
                );
                false
            }
        };
        {
            let mut g = self
                .streams_in
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if g.recent.len() >= 64 {
                g.recent.remove(0);
            }
            g.recent.push(Recent {
                id,
                agent,
                salt: live.salt,
                seq,
                text_len,
                until_ms: now + RECENT_MS,
                finalized,
                end: declared_end.filter(|e| *e != StreamEnd::Cut),
            });
        }
        write_resp(&mut send, &LinkResponse::Ok).await;
    }

    /// Reads frames up to the last one. `Ok((end, final message))` or the reason for the cut.
    async fn read_pieces(
        &self,
        open: &StreamOpen,
        recv: &mut RecvStream,
    ) -> std::result::Result<(StreamEnd, Option<MessageId>), &'static str> {
        let mut opener = Opener::new(&self.link_id, open);
        let started = Instant::now();
        loop {
            let left = MAX_DURATION.saturating_sub(started.elapsed());
            if left.is_zero() {
                return Err("timeout");
            }
            let frame = match tokio::time::timeout(
                RECV_IDLE.min(left),
                transport::read_frame(recv, MAX_FRAME),
            )
            .await
            {
                Err(_) => return Err("timeout"),
                Ok(Err(e)) if e.code == code::BAD_REQUEST => return Err("limit"),
                Ok(Err(_)) => return Err("connection_lost"),
                Ok(Ok(b)) => b,
            };
            self.touch_pub();
            let piece = antenna_proto::from_cbor::<StreamFrame>(&frame)
                .map_err(|_| "bad_frame")
                .and_then(|f| {
                    opener
                        .open(&f)
                        .map(|p| (p, f.last))
                        .map_err(|_| "bad_frame")
                });
            let (piece, last) = piece?;
            if last != piece.end.is_some() {
                return Err("bad_frame");
            }
            let activity = piece.activity.as_deref().map(clean_activity);
            let (seq, text_len, changed) = {
                let mut g = self
                    .streams_in
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner);
                let Some(l) = g.live.get_mut(&open.id) else {
                    return Err("bad_frame");
                };
                if l.text.len() + piece.text.len() > MAX_STREAM_TEXT + 64 {
                    return Err("limit");
                }
                l.text.push_str(&piece.text);
                let mut changed = !piece.text.is_empty();
                if let Some(a) = &activity {
                    let a = (!a.is_empty()).then(|| a.clone());
                    if a != l.activity {
                        l.activity = a;
                        changed = true;
                    }
                }
                if changed {
                    l.seq += 1;
                }
                (l.seq, l.text.len() as u64, changed)
            };
            if changed {
                let act = self
                    .streams_in
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .live
                    .get(&open.id)
                    .and_then(|l| l.activity.clone());
                self.emit_in(
                    &open.id,
                    StreamEventBodyIn {
                        via_agent: open.agent.clone(),
                        state: "streaming",
                        seq,
                        delta: Some(piece.text.clone()),
                        text_len,
                        activity: act,
                        ..Default::default()
                    },
                );
            }
            if let Some(end) = piece.end {
                return Ok((end, piece.final_id));
            }
        }
    }

    /// Message `fid` is an incoming message of this link from the contact with the stream's salt.
    fn final_matches(&self, fid: &MessageId, salt: &[u8; 32]) -> bool {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let Ok(Some(m)) = Db::message_by_id(db.conn(), &self.link_id, fid) else {
            return false;
        };
        if m.author != self.peer_root {
            return false;
        }
        antenna_proto::from_cbor::<antenna_proto::EnvelopeCore>(&m.core)
            .is_ok_and(|c| crypto::ct_eq(&c.salt, salt))
    }

    /// The final message announced by the last chunk never arrived: "interrupted".
    fn late_final_missing(&self, id: &[u8; 16], text: String) {
        let hit = {
            let mut g = self
                .streams_in
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            g.recent
                .iter_mut()
                .find(|r| r.id == *id && !r.finalized)
                .map(|r| {
                    r.seq += 1;
                    (r.seq, r.text_len, r.agent.clone())
                })
        };
        if let Some((seq, text_len, agent)) = hit {
            self.emit_in(
                id,
                StreamEventBodyIn {
                    via_agent: agent,
                    state: "interrupted",
                    seq,
                    text_len,
                    reason: Some("connection_lost"),
                    text: Some(text),
                    ..Default::default()
                },
            );
        }
    }

    /// New texts from the contact: the stream's final message is recognized by salt (link cut, final message after
    /// approval).
    pub(crate) fn stream_finals(&self, salts: &[(MessageId, [u8; 32], bool)]) {
        if salts.is_empty() {
            return;
        }
        let hits: Vec<([u8; 16], StreamEventBodyIn)> = {
            let mut g = self
                .streams_in
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let mut hits = Vec::new();
            for (mid, salt, interrupted) in salts {
                if let Some(r) = g
                    .recent
                    .iter_mut()
                    .find(|r| !r.finalized && crypto::ct_eq(&r.salt, salt))
                {
                    r.finalized = true;
                    r.seq += 1;
                    // The end comes from the last chunk if it arrived; otherwise (cut, final message after approval)
                    // from the mark in the final text (the mark itself is the contact's words; it is only presentation)
                    let interrupted = match r.end {
                        Some(e) => e == StreamEnd::Interrupted,
                        None => *interrupted,
                    };
                    hits.push((
                        r.id,
                        StreamEventBodyIn {
                            via_agent: r.agent.clone(),
                            state: "final",
                            seq: r.seq,
                            text_len: r.text_len,
                            message_id: Some(mid.to_hex()),
                            end: Some(if interrupted { "interrupted" } else { "done" }),
                            ..Default::default()
                        },
                    ));
                }
            }
            hits
        };
        for (id, body) in hits {
            self.emit_in(&id, body);
        }
    }
}

#[derive(Default)]
struct StreamEventBodyIn {
    via_agent: Option<String>,
    state: &'static str,
    seq: u64,
    delta: Option<String>,
    text_len: u64,
    activity: Option<String>,
    message_id: Option<String>,
    end: Option<&'static str>,
    reason: Option<&'static str>,
    text: Option<String>,
}

async fn write_resp(send: &mut SendStream, r: &LinkResponse) {
    if let Ok(b) = antenna_proto::to_cbor(r) {
        let _ = transport::write_frame(send, &b).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open() -> StreamOpen {
        StreamOpen {
            agent: None,
            v: 0,
            id: [3; 16],
            secret: [9; 32],
            ts: 1,
        }
    }

    fn piece(t: &str) -> StreamPiece {
        StreamPiece {
            text: t.into(),
            activity: None,
            end: None,
            final_id: None,
        }
    }

    #[test]
    fn pieces_roundtrip_and_tampering_is_rejected() {
        let link = LinkId([1; 32]);
        let mut s = Sealer::new(&link, &open());
        let f1 = s.seal(&piece("καλη"), false).unwrap();
        let f2 = s.seal(&piece("μέρα"), false).unwrap();
        let mut last = piece("!");
        last.end = Some(StreamEnd::Done);
        let f3 = s.seal(&last, true).unwrap();
        // Padding: the frame length is a bucket, not the text length
        assert_eq!(f1.c.len(), 256 + 16);
        let mut o = Opener::new(&link, &open());
        assert_eq!(o.open(&f1).unwrap().text, "καλη");
        assert_eq!(o.open(&f2).unwrap().text, "μέρα");
        assert_eq!(o.open(&f3).unwrap().end, Some(StreamEnd::Done));
        // Nothing after the last one
        assert!(o.open(&f3).is_err());
        // Reordering
        let mut o = Opener::new(&link, &open());
        assert!(o.open(&f2).is_err());
        // The "last" flag substituted from outside
        let mut o = Opener::new(&link, &open());
        let mut forged = f1.clone();
        forged.last = true;
        assert!(o.open(&forged).is_err());
        // Truncation: a non-last frame passed off as the last
        let mut o = Opener::new(&link, &open());
        o.open(&f1).unwrap();
        let mut cut = f2.clone();
        cut.last = true;
        assert!(o.open(&cut).is_err());
        // A substituted byte
        let mut o = Opener::new(&link, &open());
        let mut bad = f1.clone();
        bad.c[5] ^= 1;
        assert!(o.open(&bad).is_err());
        // Another link (AAD) or another secret
        let mut o = Opener::new(&LinkId([2; 32]), &open());
        assert!(o.open(&f1).is_err());
        let mut other = open();
        other.secret[0] ^= 1;
        let mut o = Opener::new(&link, &other);
        assert!(o.open(&f1).is_err());
    }

    #[test]
    fn final_salt_is_bound_to_the_secret() {
        let a = final_salt(&open());
        let mut o = open();
        assert_eq!(final_salt(&o), a);
        o.secret[31] ^= 1;
        assert_ne!(final_salt(&o), a);
        let mut o = open();
        o.id[0] ^= 1;
        assert_ne!(final_salt(&o), a);
    }

    #[test]
    fn split_keeps_utf8_boundaries() {
        let t = "αααα"; // 2 bytes each
        let parts = split_text(t, 3);
        assert_eq!(parts.concat(), t);
        assert!(parts.iter().all(|p| p.len() <= 3 && !p.is_empty()));
        assert_eq!(split_text("", 5), vec![""]);
        assert_eq!(clean_activity("tool:\u{202e}Read\n"), "tool:Read");
    }
}
