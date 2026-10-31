// SPDX-License-Identifier: AGPL-3.0-only
//! Agents of a link side: sub-identities signed by its link-root (SPEC §5, `docs/PROTOCOL.md` §21, DECISIONS D-75).
//!
//! A side's agent writes to the link with its own Ed25519 key, **its own for every link** (nothing shared between
//! links, SPEC §5). The key is announced to the contact by a `control` message with body `agent {name, key, state}`,
//! whose author is the side's link-root: the signature of that message (§12) is the link-root's signature over the
//! agent key. After the announcement, the side's messages with `author` = the agent key (and an `n` greater than the
//! announcement's) come from that agent; the contact sees "Bob / name".
//!
//! A side has one counter `n` shared by the owner and all of its agents: history verification chains (§16), rollback
//! (§17) and the divergence point are computed per side (`messages.author` = the side's link-root), while the agent
//! key is stored separately (`messages.agent_key`), so history verification does not change.
//!
//! No custom cryptography: an agent key is Ed25519 from 32 random OS bytes (`ed25519-dalek`), the message signature is
//! the same construction as in §12, verification is `verify_strict`.

use antenna_proto::{AgentAnnounce, Body, Envelope, EnvelopeCore, LinkId, control::code};
use ed25519_dalek::{SigningKey, VerifyingKey};
use rusqlite::{Connection, OptionalExtension, params};
use zeroize::Zeroizing;

use crate::{
    crypto::Secret32,
    error::{Error, Result},
    history,
};

/// Who signed a link message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signer {
    /// A message of our own side (otherwise of the contact's side).
    pub mine: bool,
    /// The side's link-root (what is stored in `messages.author` and goes into the verification chains).
    pub side_root: [u8; 32],
    /// The side's agent: the name from the announcement and its key (`core.author`); `None` means link-root (the owner)
    /// signed.
    pub agent: Option<(String, [u8; 32])>,
}

/// An agent key in a link (a `link_agents` row).
pub struct AgentKey {
    /// Our own side.
    pub mine: bool,
    /// Public key.
    pub key: [u8; 32],
    /// Name (ours: the local agent name shown to the contact; the contact's: from its announcement).
    pub name: String,
    /// Signing secret (only for our own keys created by this node).
    pub seed: Option<Secret32>,
    /// `n` of the announcement (the side's counter).
    pub announced_n: u64,
    /// When the announcement was recorded, Unix ms.
    pub announced_ms: u64,
    /// `n` of the revocation, if the key is revoked.
    pub revoked_n: Option<u64>,
}

impl std::fmt::Debug for AgentKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "AgentKey({}, {}, n {}, seed {})",
            if self.mine { "me" } else { "peer" },
            self.name,
            self.announced_n,
            if self.seed.is_some() {
                "<redacted>"
            } else {
                "none"
            }
        )
    }
}

impl AgentKey {
    /// The key is valid for the side's message with this `n`: announced earlier and not revoked before it.
    pub fn active_at(&self, n: u64) -> bool {
        self.announced_n < n && self.revoked_n.is_none_or(|r| n < r)
    }
}

const SELECT: &str =
    "SELECT side, key, name, seed, announced_n, announced_ms, revoked_n FROM link_agents";

/// A `link_agents` row as is: side, key, name, secret, announcement `n`, when, revocation `n`.
type RawKey = (
    String,
    Vec<u8>,
    String,
    Option<Vec<u8>>,
    i64,
    i64,
    Option<i64>,
);

fn row(r: &rusqlite::Row<'_>) -> rusqlite::Result<RawKey> {
    Ok((
        r.get(0)?,
        r.get(1)?,
        r.get(2)?,
        r.get(3)?,
        r.get(4)?,
        r.get(5)?,
        r.get(6)?,
    ))
}

fn into_key((side, key, name, seed, n, ms, rev): RawKey) -> Result<AgentKey> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| Error::internal("db: agent key is not 32 bytes"))?;
    let seed = match seed.map(Zeroizing::new) {
        Some(s) if s.len() == 32 => {
            let mut out = Zeroizing::new([0u8; 32]);
            out.copy_from_slice(&s);
            Some(out)
        }
        Some(_) => return Err(Error::internal("db: agent seed is not 32 bytes")),
        None => None,
    };
    Ok(AgentKey {
        mine: side == "me",
        key,
        name,
        seed,
        announced_n: n.max(0) as u64,
        announced_ms: ms.max(0) as u64,
        revoked_n: rev.map(|r| r.max(0) as u64),
    })
}

/// An agent key in a link (of either side).
pub fn lookup(conn: &Connection, link: &LinkId, key: &[u8; 32]) -> Result<Option<AgentKey>> {
    conn.query_row(
        &format!("{SELECT} WHERE link_id = ?1 AND key = ?2"),
        params![&link.0[..], &key[..]],
        row,
    )
    .optional()?
    .map(into_key)
    .transpose()
}

/// All agent keys of a link (ours and the contact's), in announcement order.
pub fn all(conn: &Connection, link: &LinkId) -> Result<Vec<AgentKey>> {
    let mut st = conn.prepare(&format!(
        "{SELECT} WHERE link_id = ?1 ORDER BY announced_ms, announced_n"
    ))?;
    let rows = st.query_map(params![&link.0[..]], row)?;
    let mut out = Vec::new();
    for r in rows {
        out.push(into_key(r?)?);
    }
    Ok(out)
}

/// Our own valid agent key with this name, which this node can sign with.
pub fn own_signing(conn: &Connection, link: &LinkId, name: &str) -> Result<Option<AgentKey>> {
    let mut st = conn.prepare(&format!(
        "{SELECT} WHERE link_id = ?1 AND side = 'me' AND name = ?2 AND seed IS NOT NULL AND revoked_n IS NULL
         ORDER BY announced_n DESC LIMIT 1"
    ))?;
    let mut rows = st.query_map(params![&link.0[..], name], row)?;
    rows.next().map(|r| into_key(r?)).transpose()
}

#[allow(
    clippy::too_many_arguments,
    reason = "one argument per column of the `link_agents` row"
)]
fn insert(
    conn: &Connection,
    link: &LinkId,
    mine: bool,
    key: &[u8; 32],
    name: &str,
    seed: Option<&Secret32>,
    n: u64,
    now_ms: u64,
) -> Result<()> {
    conn.execute(
        "INSERT INTO link_agents(link_id, side, key, name, seed, announced_n, announced_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            &link.0[..],
            if mine { "me" } else { "peer" },
            &key[..],
            name,
            seed.map(|s| s.to_vec()),
            n as i64,
            now_ms as i64
        ],
    )?;
    Ok(())
}

/// A new agent key of our own for a link: 32 random OS bytes → Ed25519. Recorded together with the announcement (in
/// one transaction of the caller); `n` is the announcement's counter.
pub fn create_own(
    conn: &Connection,
    link: &LinkId,
    name: &str,
    n: u64,
    now_ms: u64,
) -> Result<(Secret32, [u8; 32])> {
    let seed: Secret32 = Zeroizing::new(crate::crypto::random::<32>());
    let key = SigningKey::from_bytes(&seed).verifying_key().to_bytes();
    insert(conn, link, true, &key, name, Some(&seed), n, now_ms)?;
    Ok((seed, key))
}

/// How many of our own agent keys are announced in the link.
pub fn own_count(conn: &Connection, link: &LinkId) -> Result<usize> {
    let n: i64 = conn.query_row(
        "SELECT count(*) FROM link_agents WHERE link_id = ?1 AND side = 'me'",
        params![&link.0[..]],
        |r| r.get(0),
    )?;
    Ok(n as usize)
}

/// Our own agent announcement was taken off the queue as undeliverable (`failed`): the key is forgotten, so the
/// agent's next message comes with a new key and a new announcement rather than `unknown_author` at the contact
/// (D-78, item 10).
pub fn forget_if_announcement(
    conn: &Connection,
    link: &LinkId,
    msg: &antenna_proto::MessageId,
) -> Result<()> {
    let Some(m) = crate::store::Db::message_by_id(conn, link, msg)? else {
        return Ok(());
    };
    if m.kind != "control" {
        return Ok(());
    }
    if let Ok(core) = antenna_proto::from_cbor::<EnvelopeCore>(&m.core)
        && let Body::Agent(a) = core.body
    {
        forget_own(conn, link, &a.key)?;
    }
    Ok(())
}

/// Forget our own agent key whose announcement the contact never received (displaced by a resend after a rollback).
pub fn forget_own(conn: &Connection, link: &LinkId, key: &[u8; 32]) -> Result<()> {
    conn.execute(
        "DELETE FROM link_agents WHERE link_id = ?1 AND key = ?2 AND side = 'me'",
        params![&link.0[..], &key[..]],
    )?;
    Ok(())
}

/// The key is usable as an agent key: a valid Ed25519 point not of small order, not the link-root of either side.
fn usable_key(key: &[u8; 32], own_root: &[u8; 32], peer_root: &[u8; 32]) -> bool {
    key != own_root
        && key != peer_root
        && VerifyingKey::from_bytes(key).is_ok_and(|vk| !vk.is_weak())
}

fn bad(msg: &str) -> Error {
    Error::bad_request(format!("agent announcement: {msg}"))
}

/// Checks an agent announcement before the message is recorded (DB reads only): fields, key, consistency with what
/// was already announced. `mine` is an announcement of our own side (it came back with a resend after a rollback).
pub fn check_announce(
    conn: &Connection,
    link: &LinkId,
    mine: bool,
    own_root: &[u8; 32],
    peer_root: &[u8; 32],
    a: &AgentAnnounce,
) -> Result<()> {
    if !AgentAnnounce::valid_name(&a.name) {
        return Err(bad("name must be 1–64 characters of [A-Za-z0-9._-]"));
    }
    if !usable_key(&a.key, own_root, peer_root) {
        return Err(bad("the key is not a usable Ed25519 key"));
    }
    match lookup(conn, link, &a.key)? {
        // The key is already known: only the same side and the same name; a revoked key does not come back to life
        Some(k) => {
            if k.mine != mine || k.name != a.name {
                return Err(bad("this key is already announced for another agent"));
            }
            match a.state.as_str() {
                AgentAnnounce::ACTIVE if k.revoked_n.is_some() => {
                    Err(bad("a revoked key cannot become active again"))
                }
                AgentAnnounce::ACTIVE | AgentAnnounce::REVOKED => Ok(()),
                _ => Err(bad("state must be active or revoked")),
            }
        }
        None => match a.state.as_str() {
            AgentAnnounce::ACTIVE => {
                let count: i64 = conn.query_row(
                    "SELECT count(*) FROM link_agents WHERE link_id = ?1 AND side = ?2",
                    params![&link.0[..], if mine { "me" } else { "peer" }],
                    |r| r.get(0),
                )?;
                if count as usize >= AgentAnnounce::MAX_PER_SIDE {
                    return Err(bad("too many agents announced on this link"));
                }
                Ok(())
            }
            AgentAnnounce::REVOKED => Err(bad("revoking a key that was never announced")),
            _ => Err(bad("state must be active or revoked")),
        },
    }
}

/// Record a checked announcement (after recording the message itself, in the same transaction). Returns whether
/// anything changed (a new agent or a revocation).
pub fn apply_announce(
    conn: &Connection,
    link: &LinkId,
    mine: bool,
    a: &AgentAnnounce,
    n: u64,
    now_ms: u64,
) -> Result<bool> {
    match (lookup(conn, link, &a.key)?, a.state.as_str()) {
        (None, AgentAnnounce::ACTIVE) => {
            insert(conn, link, mine, &a.key, &a.name, None, n, now_ms)?;
            Ok(true)
        }
        (Some(k), AgentAnnounce::REVOKED) if k.revoked_n.is_none() => {
            conn.execute(
                "UPDATE link_agents SET revoked_n = ?3 WHERE link_id = ?1 AND key = ?2",
                params![&link.0[..], &a.key[..], n as i64],
            )?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

/// Who signed the message: the link-root of one of the sides or an agent key announced by the side before this `n`
/// and not revoked. An unknown key is rejected: without an announcement signed by link-root, nobody can claim to be
/// an "agent".
pub fn resolve(
    conn: &Connection,
    link: &LinkId,
    own_root: &[u8; 32],
    peer_root: &[u8; 32],
    core: &EnvelopeCore,
) -> Result<Signer> {
    if core.author == *own_root || core.author == *peer_root {
        return Ok(Signer {
            mine: core.author == *own_root,
            side_root: core.author,
            agent: None,
        });
    }
    match lookup(conn, link, &core.author)? {
        Some(k) if k.active_at(core.n) => Ok(Signer {
            mine: k.mine,
            side_root: if k.mine { *own_root } else { *peer_root },
            agent: Some((k.name, k.key)),
        }),
        Some(_) => Err(Error::new(
            code::UNKNOWN_AUTHOR,
            "the agent key was not active at this message (announced later or revoked)",
        )),
        None => Err(Error::new(
            code::UNKNOWN_AUTHOR,
            "the author is neither a link-root key nor an agent announced by one",
        )),
    }
}

/// Checks an incoming envelope (live delivery and resend): the author is the side's link-root or an agent it
/// announced, the signature with that key over (link, recipient key, `n`, `core`) is valid, and only link-root may
/// announce agents. An announcement in the message itself is checked here too (before recording); the caller records
/// it ([`apply_announce`]).
pub fn check_incoming(
    conn: &Connection,
    link: &LinkId,
    own_root: &[u8; 32],
    peer_root: &[u8; 32],
    env: &Envelope,
    core: &EnvelopeCore,
) -> Result<Signer> {
    let signer = resolve(conn, link, own_root, peer_root, core)?;
    let recipient = if signer.mine { peer_root } else { own_root };
    if !history::verify_envelope(link, env, core, recipient) {
        return Err(Error::new(
            code::BAD_SIGNATURE,
            "the author's signature over this message is invalid",
        ));
    }
    if let Body::Agent(a) = &core.body {
        if signer.agent.is_some() {
            return Err(bad(
                "only the link-root key of a side can announce its agents",
            ));
        }
        check_announce(conn, link, signer.mine, own_root, peer_root, a)?;
    }
    // A side's profile pictures (PROTOCOL §25), its agents' included, are set by its link-root only: an agent cannot
    // change its own or another agent's picture
    if matches!(core.body, Body::Picture(_)) && signer.agent.is_some() {
        return Err(Error::bad_request(
            "picture: only the link-root key of a side can set pictures",
        ));
    }
    // The urgent flag is the owner's (PG-58, PROTOCOL §23): a side's agent cannot mark a message urgent
    if core.urgent.is_some() && signer.agent.is_some() {
        return Err(Error::bad_request(
            "urgent: only the link-root key of a side marks a message urgent",
        ));
    }
    Ok(signer)
}

/// An agent announcement in our own copy of the history is genuine: a `control`/`agent` message of side `side_root`
/// with this key, signed by that side's link-root for recipient `recipient` (the ID is checked against `core`).
fn verify_announcement(
    link: &LinkId,
    m: &crate::store::StoredMsg,
    side_root: &[u8; 32],
    recipient: &[u8; 32],
) -> Option<(AgentAnnounce, u64)> {
    if m.author != *side_root || m.agent_key.is_some() {
        return None;
    }
    let env = Envelope {
        id: m.id,
        core: m.core.clone(),
        auth: Some(antenna_proto::Auth::Sig(m.sig.clone())),
    };
    let (env, core) = history::open_envelope(env).ok()?;
    if core.author != *side_root
        || core.n != m.n
        || !history::verify_envelope(link, &env, &core, recipient)
    {
        return None;
    }
    match core.body {
        Body::Agent(a) if AgentAnnounce::valid_name(&a.name) => Some((a, core.n)),
        _ => None,
    }
}

/// Agent key `key` of side `side_root` was announced in our own copy of the history before `n`, by an announcement
/// signed by that side's link-root (not by a `link_agents` row: that can be altered in the DB, the history cannot).
/// Used for checking the signatures of our own copy (`sync::sig_ok`): "whose copy was altered" must not trust the
/// table.
pub fn announced_before(
    conn: &Connection,
    link: &LinkId,
    side_root: &[u8; 32],
    key: &[u8; 32],
    n: u64,
    recipient: &[u8; 32],
) -> bool {
    let Ok(Some(row)) = lookup(conn, link, key) else {
        return false;
    };
    if row.announced_n >= n {
        return false;
    }
    let Ok(Some(m)) = crate::store::Db::message_at(conn, link, side_root, row.announced_n) else {
        return false;
    };
    verify_announcement(link, &m, side_root, recipient)
        .is_some_and(|(a, _)| a.key == *key && a.state == AgentAnnounce::ACTIVE)
}

/// Agent keys announced in our own copy of the history (link-root signatures verified): key → (our side, name,
/// announcement `n`, revocation `n`).
pub type Announced = std::collections::HashMap<[u8; 32], (bool, String, u64, Option<u64>)>;

/// Collect agent keys from the link history (own copy check): only announcements signed by the side's link-root.
pub fn from_history(
    conn: &Connection,
    link: &LinkId,
    own_root: &[u8; 32],
    peer_root: &[u8; 32],
) -> Result<Announced> {
    let mut out = Announced::new();
    for m in crate::store::Db::control_messages(conn, link)? {
        let mine = m.author == *own_root;
        let (side, recipient) = if mine {
            (own_root, peer_root)
        } else {
            (peer_root, own_root)
        };
        let Some((a, n)) = verify_announcement(link, &m, side, recipient) else {
            continue;
        };
        match a.state.as_str() {
            AgentAnnounce::ACTIVE => {
                out.entry(a.key).or_insert((mine, a.name, n, None));
            }
            AgentAnnounce::REVOKED => {
                if let Some(e) = out.get_mut(&a.key)
                    && e.0 == mine
                    && e.2 < n
                    && e.3.is_none()
                {
                    e.3 = Some(n);
                }
            }
            _ => {}
        }
    }
    Ok(out)
}

/// Bring the `link_agents` table in line with the history (after the own copy check): extra keys (no signed
/// announcement) are removed, missing ones are added without a secret, revocation follows the history. Returns how
/// many rows were fixed.
pub fn reconcile(
    conn: &Connection,
    link: &LinkId,
    announced: &Announced,
    now_ms: u64,
) -> Result<usize> {
    let mut fixed = 0;
    let table = all(conn, link)?;
    for k in &table {
        match announced.get(&k.key) {
            Some((mine, _, n, rev)) if *mine == k.mine && *n == k.announced_n => {
                if *rev != k.revoked_n {
                    conn.execute(
                        "UPDATE link_agents SET revoked_n = ?3 WHERE link_id = ?1 AND key = ?2",
                        params![&link.0[..], &k.key[..], rev.map(|r| r as i64)],
                    )?;
                    fixed += 1;
                }
            }
            _ => {
                conn.execute(
                    "DELETE FROM link_agents WHERE link_id = ?1 AND key = ?2",
                    params![&link.0[..], &k.key[..]],
                )?;
                fixed += 1;
            }
        }
    }
    for (key, (mine, name, n, rev)) in announced {
        if table
            .iter()
            .any(|k| k.key == *key && k.mine == *mine && k.announced_n == *n)
        {
            continue;
        }
        insert(conn, link, *mine, key, name, None, *n, now_ms)?;
        if let Some(r) = rev {
            conn.execute(
                "UPDATE link_agents SET revoked_n = ?3 WHERE link_id = ?1 AND key = ?2",
                params![&link.0[..], &key[..], *r as i64],
            )?;
        }
        fixed += 1;
    }
    Ok(fixed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Db;
    use antenna_proto::MessageType;

    struct Side {
        seed: Secret32,
        root: [u8; 32],
    }

    fn side(b: u8) -> Side {
        let seed = Zeroizing::new([b; 32]);
        let root = SigningKey::from_bytes(&seed).verifying_key().to_bytes();
        Side { seed, root }
    }

    fn db() -> (tempfile::TempDir, Db) {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("t.db"), &Zeroizing::new([3; 32])).unwrap();
        (dir, db)
    }

    const LINK: LinkId = LinkId([0x33; 32]);

    /// Envelope of side `by` (signed with `seed`, `author` = `author`), addressed to the side with key `to`.
    fn msg(
        seed: &Secret32,
        author: [u8; 32],
        to: [u8; 32],
        n: u64,
        kind: MessageType,
        body: Body,
    ) -> (Envelope, EnvelopeCore) {
        let (_, env, core) = history::build(history::NewMessage {
            link: &LINK,
            seed,
            author,
            recipient: to,
            parents: vec![],
            lamport: n,
            ts: 1,
            n,
            kind,
            body,
        })
        .unwrap();
        (env, core)
    }

    fn announce(name: &str, key: [u8; 32], state: &str) -> Body {
        Body::Agent(AgentAnnounce {
            name: name.into(),
            key,
            state: state.into(),
        })
    }

    fn text(t: &str) -> Body {
        Body::Text(t.into())
    }

    /// The recipient is "me"; the sender is the contact. Accept: check and record the announcement, as receiving does.
    fn receive(
        db: &Db,
        me: &Side,
        peer: &Side,
        env: &Envelope,
        core: &EnvelopeCore,
    ) -> Result<Signer> {
        let s = check_incoming(db.conn(), &LINK, &me.root, &peer.root, env, core)?;
        if let Body::Agent(a) = &core.body {
            apply_announce(db.conn(), &LINK, s.mine, a, core.n, 1)?;
        }
        Ok(s)
    }

    /// Contact's agent: link-root announcement by the contact → messages with the agent key come from "contact / name";
    /// the agent key before the announcement, an unknown key, an announcement on behalf of the agent or without a
    /// link-root signature are rejected.
    #[test]
    fn an_agent_needs_an_announcement_signed_by_the_link_root() {
        let (_d, db) = db();
        let me = side(1);
        let peer = side(2);
        let agent = side(9);
        let forger = side(7);

        // Before the announcement the agent key is not an author in this link
        let (e, c) = msg(
            &agent.seed,
            agent.root,
            me.root,
            1,
            MessageType::Text,
            text("hi"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::UNKNOWN_AUTHOR
        );

        // An announcement NOT signed by the contact's link-root (author = the contact's root, signed by a foreign key)
        let (e, c) = msg(
            &forger.seed,
            peer.root,
            me.root,
            1,
            MessageType::Control,
            announce("claude-backend", agent.root, "active"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::BAD_SIGNATURE
        );
        // An announcement on behalf of an unknown key (the agent announces itself)
        let (e, c) = msg(
            &agent.seed,
            agent.root,
            me.root,
            1,
            MessageType::Control,
            announce("claude-backend", agent.root, "active"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::UNKNOWN_AUTHOR
        );

        // A genuine announcement by the contact's link-root (n = 1)
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            1,
            MessageType::Control,
            announce("claude-backend", agent.root, "active"),
        );
        let s = receive(&db, &me, &peer, &e, &c).unwrap();
        assert_eq!((s.mine, s.agent), (false, None));

        // Agent message with n = 2: from "contact / claude-backend"
        let (e, c) = msg(
            &agent.seed,
            agent.root,
            me.root,
            2,
            MessageType::Text,
            text("hello"),
        );
        let s = receive(&db, &me, &peer, &e, &c).unwrap();
        assert_eq!(s.side_root, peer.root);
        assert_eq!(s.agent, Some(("claude-backend".into(), agent.root)));
        // The same message signed with another key: rejected
        let (e2, c2) = msg(
            &forger.seed,
            agent.root,
            me.root,
            3,
            MessageType::Text,
            text("x"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e2, &c2).unwrap_err().code,
            code::BAD_SIGNATURE
        );
        // A signature for another recipient (forwarding the agent's message to another link/another party): rejected
        let (e3, c3) = msg(
            &agent.seed,
            agent.root,
            peer.root,
            3,
            MessageType::Text,
            text("x"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e3, &c3).unwrap_err().code,
            code::BAD_SIGNATURE
        );
        // A message with n not greater than the announcement's, with the agent key: rejected (the key was not yet
        // valid)
        let (e, c) = msg(
            &agent.seed,
            agent.root,
            me.root,
            1,
            MessageType::Text,
            text("early"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::UNKNOWN_AUTHOR
        );
        // An agent does not announce agents
        let other = side(10);
        let (e, c) = msg(
            &agent.seed,
            agent.root,
            me.root,
            4,
            MessageType::Control,
            announce("sub", other.root, "active"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::BAD_REQUEST
        );
        // The contact cannot announce my link-root or my agent's key as its agent
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            5,
            MessageType::Control,
            announce("mine", me.root, "active"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::BAD_REQUEST
        );
        let (_, own_key) = create_own(db.conn(), &LINK, "claude", 3, 1).unwrap();
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            5,
            MessageType::Control,
            announce("claude", own_key, "active"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::BAD_REQUEST
        );
        // The same key under another name: rejected; a repeat of the same: no change
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            6,
            MessageType::Control,
            announce("renamed", agent.root, "active"),
        );
        assert!(receive(&db, &me, &peer, &e, &c).is_err());

        // Revocation (n = 7): messages after it are rejected, those before it still come from the agent (history
        // resend)
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            7,
            MessageType::Control,
            announce("claude-backend", agent.root, "revoked"),
        );
        receive(&db, &me, &peer, &e, &c).unwrap();
        let (e, c) = msg(
            &agent.seed,
            agent.root,
            me.root,
            8,
            MessageType::Text,
            text("late"),
        );
        assert_eq!(
            receive(&db, &me, &peer, &e, &c).unwrap_err().code,
            code::UNKNOWN_AUTHOR
        );
        let (e, c) = msg(
            &agent.seed,
            agent.root,
            me.root,
            6,
            MessageType::Text,
            text("ok"),
        );
        assert!(receive(&db, &me, &peer, &e, &c).unwrap().agent.is_some());
        // A revoked key does not come back to life
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            9,
            MessageType::Control,
            announce("claude-backend", agent.root, "active"),
        );
        assert!(receive(&db, &me, &peer, &e, &c).is_err());
    }

    /// Record a message of the contact's side into our own copy (as receiving does: the author in the DB is the
    /// side's link-root).
    fn store(
        db: &mut Db,
        env: &Envelope,
        core: &EnvelopeCore,
        side: [u8; 32],
        agent: Option<[u8; 32]>,
    ) {
        let sig = match &env.auth {
            Some(antenna_proto::Auth::Sig(s)) => s.clone(),
            _ => unreachable!(),
        };
        let display = history::display_body(core).unwrap_or_default();
        let tx = db.tx().unwrap();
        crate::store::Db::insert_message(
            &tx,
            &crate::store::MessageRecord {
                id: env.id,
                link_id: LINK,
                incoming: true,
                author: side,
                lamport: core.lamport,
                ts: core.ts,
                kind: core.kind.as_str(),
                body: &display,
                core: &env.core,
                parents: &core.parents,
                n: core.n,
                sig: &sig,
                origin: "live",
                agent: agent.map(|k| ("x", Some(k))),
                to: None,
                topic: None,
            },
            1,
        )
        .unwrap();
        tx.commit().unwrap();
    }

    /// A side's pictures, its agents' included, come from its link-root only (PROTOCOL §25): an announced agent cannot
    /// set its own picture or another's.
    #[test]
    fn only_the_link_root_sets_pictures() {
        let (_d, db) = db();
        let me = side(1);
        let peer = side(2);
        let agent = side(9);
        let pic = |who: Option<&str>| {
            Body::Picture(antenna_proto::picture::PictureBody {
                agent: who.map(Into::into),
                drawn: Some("set1/fox".into()),
                photo: None,
            })
        };
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            1,
            MessageType::Control,
            announce("desk", agent.root, "active"),
        );
        receive(&db, &me, &peer, &e, &c).unwrap();
        for (n, who) in [(2, Some("desk")), (3, None), (4, Some("other"))] {
            let (e, c) = msg(
                &agent.seed,
                agent.root,
                me.root,
                n,
                MessageType::Control,
                pic(who),
            );
            assert_eq!(
                receive(&db, &me, &peer, &e, &c).unwrap_err().code,
                code::BAD_REQUEST,
                "an agent's own picture message ({who:?})"
            );
        }
        let (e, c) = msg(
            &peer.seed,
            peer.root,
            me.root,
            5,
            MessageType::Control,
            pic(Some("desk")),
        );
        let s = receive(&db, &me, &peer, &e, &c).unwrap();
        assert_eq!(
            s.agent, None,
            "the link-root vouches for its agent's picture"
        );
    }

    /// D-78, item 1: what makes someone an "agent" is an announcement signed by link-root in the history, not a table
    /// row. Whoever edits the DB (replaced a contact's message with one signed by their own key and put the key into
    /// `link_agents`) gets "my copy was altered" in the copy check and an invalid signature of our own copy, not a
    /// false "the contact forked the history".
    #[test]
    fn a_key_in_the_table_without_a_signed_announcement_is_not_an_agent() {
        let (_d, mut db) = db();
        db.insert_link(
            &crate::store::NewLink {
                link_id: LINK,
                role: crate::store::PairRole::Inviter,
                label: Some("bob".into()),
                trust: 3,
                transcript_hash: [1; 32],
                pairing_kx: "X25519MLKEM768".into(),
                local_secret: crate::crypto::random_secret(),
                peer_endpoint: [2; 32],
                peer_addrs: Default::default(),
                root_ed25519_seed: crate::crypto::random_secret(),
                root_ed25519_pk: side(1).root,
                root_mldsa_seed: crate::crypto::random_secret(),
                root_mldsa_vk: vec![4; 1952],
                peer_root_ed25519: side(2).root,
                peer_root_mldsa: vec![6; 1952],
                sig_local_addr: "a".into(),
                sig_remote_addr: "b".into(),
                sig_identity_keypair: Zeroizing::new(vec![7; 64]),
                sig_registration_id: 9,
                sig_remote_identity: vec![8; 33],
                sig_session_record: Zeroizing::new(vec![9; 100]),
            },
            1,
        )
        .unwrap();
        let me = side(1);
        let peer = side(2);
        let agent = side(9);
        let forger = side(7);
        // Honest: an announcement by the contact's link-root (n = 1) and an agent message (n = 2)
        let (e1, c1) = msg(
            &peer.seed,
            peer.root,
            me.root,
            1,
            MessageType::Control,
            announce("claude", agent.root, "active"),
        );
        receive(&db, &me, &peer, &e1, &c1).unwrap();
        store(&mut db, &e1, &c1, peer.root, None);
        let (e2, c2) = msg(
            &agent.seed,
            agent.root,
            me.root,
            2,
            MessageType::Text,
            text("hi"),
        );
        store(&mut db, &e2, &c2, peer.root, Some(agent.root));
        // Forgery in the DB: a contact text (n = 3) signed by a foreign key, and that key put into the table as the
        // contact's agent
        let (e3, c3) = msg(
            &forger.seed,
            forger.root,
            me.root,
            3,
            MessageType::Text,
            text("forged"),
        );
        store(&mut db, &e3, &c3, peer.root, Some(forger.root));
        insert(db.conn(), &LINK, false, &forger.root, "evil", None, 1, 1).unwrap();

        let at = |db: &Db, n: u64| {
            crate::store::Db::message_at(db.conn(), &LINK, &peer.root, n)
                .unwrap()
                .unwrap()
        };
        assert!(crate::sync::sig_ok(db.conn(), &LINK, &at(&db, 2), &me.root));
        assert!(
            !crate::sync::sig_ok(db.conn(), &LINK, &at(&db, 3), &me.root),
            "a table row is not an announcement"
        );
        let audit = crate::sync::audit(&mut db, &LINK, me.root, peer.root).unwrap();
        let d = audit.damage.expect("tampering is found");
        assert_eq!((d.place.n, d.what), (3, "foreign_author"));
        // The table is brought in line with the history: the planted key is gone, the honest one stays
        assert!(lookup(db.conn(), &LINK, &forger.root).unwrap().is_none());
        assert!(lookup(db.conn(), &LINK, &agent.root).unwrap().is_some());
    }

    /// Our own agent key: a separate one for every link, the node signs (the secret is in the encrypted DB), found by
    /// name.
    #[test]
    fn own_agent_keys_are_per_link() {
        let (_d, db) = db();
        let (s1, k1) = create_own(db.conn(), &LINK, "claude", 4, 1).unwrap();
        let other = LinkId([0x44; 32]);
        let (_, k2) = create_own(db.conn(), &other, "claude", 2, 1).unwrap();
        assert_ne!(k1, k2, "no common key between links (SPEC §5)");
        let got = own_signing(db.conn(), &LINK, "claude").unwrap().unwrap();
        assert_eq!(got.key, k1);
        assert_eq!(*got.seed.unwrap(), *s1);
        assert!(own_signing(db.conn(), &LINK, "codex").unwrap().is_none());
        let dbg = format!("{:?}", own_signing(db.conn(), &LINK, "claude").unwrap());
        assert!(!dbg.contains(&format!("{:?}", &s1[..4])), "{dbg}");
    }
}
