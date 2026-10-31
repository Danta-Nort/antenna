// SPDX-License-Identifier: AGPL-3.0-only
//! Link history verification (SPEC §8, `docs/PROTOCOL.md` §16): author chains, the own copy check, the summary for
//! the contact, summary comparison and locating the divergence point. Networking is in `node.rs`; this is socket-free
//! logic.
//!
//! **Author chain.** On each side of a link, messages are numbered by a counter `n` (1, 2, 3…, SPEC §7). The value
//! `chain(n) = BLAKE3-DK(ctx, chain(n−1) ‖ id(n))` commits to all of the author's IDs in order, and an ID commits to
//! all content (and to the parents). So two copies of the history are equal if both authors' counters and chain values
//! are equal; this is checked with a summary in a single exchange (`sync`), without sending messages.
//!
//! **Own copy check** (once after unlock and on `antenna verify`): for every message the ID is recomputed from the
//! `core` bytes, the columns (author, `n`, lamport, time, type, text) are checked against `core`, the chains are
//! rebuilt, the heads are recomputed. A manual edit of a text in the DB (with the same ID) shows up here, with its
//! exact place.
//!
//! **Divergence point** (IDs changed, messages re-signed, etc.): the chains did not match at an equal counter → a
//! search over the chain checkpoints every [`BLOCK`] messages (in memory), then over IDs inside the block: 2 exchanges
//! and ≤ 64 KiB per 1 million messages. A full binary search over a Merkle tree (SPEC §8 item 3, ~20 rounds) is v0.2.

use std::collections::{HashMap, HashSet};

use antenna_proto::{
    EnvelopeCore, LinkId, MessageId,
    link::{
        AuditState, AuthorChain, ChainPoint, ChainQuery, LinkState, MAX_CHAIN_POINTS, Place,
        SyncSummary,
    },
};
use rusqlite::Connection;

use crate::{
    error::{Error, Result},
    history,
    store::{Db, StoredMsg},
};

/// A chain checkpoint every this many messages of an author (kept in daemon memory).
pub const BLOCK: u64 = 1024;

/// One author's chain in our own copy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chain {
    /// Consecutive messages of the author (1…count).
    pub count: u64,
    /// `chain(count)`.
    pub tip: [u8; 32],
    /// `chain(k · BLOCK)` for k = 1, 2, …
    pub checkpoints: Vec<[u8; 32]>,
    /// After `count` there is a gap, followed by more messages (the resend is not finished).
    pub gap: bool,
}

impl Default for Chain {
    fn default() -> Self {
        Self {
            count: 0,
            tip: history::CHAIN_ZERO,
            checkpoints: Vec::new(),
            gap: false,
        }
    }
}

impl Chain {
    fn push(&mut self, id: &MessageId) {
        self.tip = history::chain_step(&self.tip, id);
        self.count += 1;
        if self.count.is_multiple_of(BLOCK) {
            self.checkpoints.push(self.tip);
        }
    }

    /// `chain(n)` for `n ≤ count`: a checkpoint from memory + IDs inside the block from the DB (≤ [`BLOCK`] − 1).
    pub fn at(
        &self,
        conn: &Connection,
        link: &LinkId,
        author: &[u8; 32],
        n: u64,
    ) -> Result<[u8; 32]> {
        if n > self.count {
            return Err(Error::internal("chain position beyond the counter"));
        }
        if n == self.count {
            return Ok(self.tip);
        }
        let k = n / BLOCK;
        let mut c = if k == 0 {
            history::CHAIN_ZERO
        } else {
            self.checkpoints[(k - 1) as usize]
        };
        let from = k * BLOCK + 1;
        if from > n {
            return Ok(c);
        }
        let ids = Db::ids_by_n(conn, link, author, from, n)?;
        if ids.len() as u64 != n - from + 1 {
            return Err(Error::internal("history changed under the chain index"));
        }
        for (_, id) in ids {
            c = history::chain_step(&c, &id);
        }
        Ok(c)
    }
}

/// Chains of both sides of a link in our own copy.
#[derive(Debug, Clone)]
pub struct Index {
    /// Our own link-root.
    pub own: [u8; 32],
    /// The contact's link-root.
    pub peer: [u8; 32],
    /// Our own messages.
    pub mine: Chain,
    /// The contact's messages.
    pub theirs: Chain,
}

impl Index {
    /// The author's chain.
    pub fn chain(&self, author: &[u8; 32]) -> Option<&Chain> {
        if *author == self.own {
            Some(&self.mine)
        } else if *author == self.peer {
            Some(&self.theirs)
        } else {
            None
        }
    }

    fn chain_mut(&mut self, author: &[u8; 32]) -> Option<&mut Chain> {
        if *author == self.own {
            Some(&mut self.mine)
        } else if *author == self.peer {
            Some(&mut self.theirs)
        } else {
            None
        }
    }

    /// A new message was recorded: the author's chain is extended (also across a gap, if it got filled).
    pub fn on_insert(
        &mut self,
        conn: &Connection,
        link: &LinkId,
        author: &[u8; 32],
        n: u64,
        id: &MessageId,
    ) -> Result<()> {
        let Some(ch) = self.chain_mut(author) else {
            return Ok(());
        };
        if n != ch.count + 1 {
            if n > ch.count + 1 {
                ch.gap = true;
            }
            return Ok(());
        }
        ch.push(id);
        if ch.gap {
            // The gap got filled: extend the chain over the messages already recorded
            loop {
                let next = ch.count + 1;
                let ids = Db::ids_by_n(conn, link, author, next, next + 255)?;
                let mut advanced = false;
                for (k, id) in ids {
                    if k != ch.count + 1 {
                        break;
                    }
                    ch.push(&id);
                    advanced = true;
                }
                if !advanced {
                    break;
                }
            }
            let rest = Db::ids_by_n(conn, link, author, ch.count + 1, u64::MAX)?;
            ch.gap = !rest.is_empty();
        }
        Ok(())
    }

    /// Counters `[ours, the contact's]`.
    pub fn counts(&self) -> [u64; 2] {
        [self.mine.count, self.theirs.count]
    }
}

/// Damage to our own copy found by the check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Damage {
    /// Place.
    pub place: Place,
    /// Record ID.
    pub id: MessageId,
    /// Local `seq`.
    pub seq: i64,
    /// What is wrong: `content_changed` (the ID did not match `core`), `fields_changed`, `text_changed`, `unreadable`,
    /// `foreign_author`, `duplicate_counter`.
    pub what: &'static str,
}

/// Result of the own copy check.
#[derive(Debug, Clone)]
pub struct Audit {
    /// Chains.
    pub index: Index,
    /// The first damage found.
    pub damage: Option<Damage>,
    /// The heads table did not match the recomputed one and was fixed.
    pub heads_fixed: bool,
    /// How many messages were checked.
    pub checked: u64,
    /// How many v0 format messages (without a signature and counter) were skipped.
    pub legacy: u64,
}

/// Check our own copy of the link history in full (holds the DB for the duration of the check).
pub fn audit(db: &mut Db, link: &LinkId, own: [u8; 32], peer: [u8; 32]) -> Result<Audit> {
    let tx = db.tx()?;
    let mut index = Index {
        own,
        peer,
        mine: Chain::default(),
        theirs: Chain::default(),
    };
    let mut damage: Option<Damage> = None;
    let mut referenced: HashSet<MessageId> = HashSet::new();
    let mut checked = 0u64;
    let mut legacy = 0u64;
    let mut stopped: HashMap<[u8; 32], bool> = HashMap::new();
    // The sides' agent keys (PROTOCOL §21) come from announcements signed by link-root in the history itself, not
    // from the `link_agents` table (it can be altered in the DB); the table is brought in line with the history later
    let announced = crate::agentid::from_history(&tx, link, &own, &peer)?;
    Db::for_each_message(&tx, link, |m| {
        checked += 1;
        if m.n == 0 {
            legacy += 1;
            return Ok(());
        }
        let place = Place {
            author: m.author,
            n: m.n,
        };
        let mut hurt = |what: &'static str| {
            if damage.is_none() {
                damage = Some(Damage {
                    place,
                    id: m.id,
                    seq: m.seq,
                    what,
                });
            }
        };
        if history::message_id(&m.core) != m.id {
            hurt("content_changed");
        }
        match antenna_proto::from_cbor::<EnvelopeCore>(&m.core) {
            Err(_) => hurt("unreadable"),
            Ok(core) => {
                if !fields_match(&m, &core) {
                    hurt("fields_changed");
                } else if history::display_body(&core).as_deref() != Some(m.body.as_str()) {
                    hurt("text_changed");
                }
                referenced.extend(core.parents.iter().copied());
            }
        }
        if m.author != own && m.author != peer {
            hurt("foreign_author");
            return Ok(());
        }
        // Signed with an agent key: it was announced by this side before this `n` and not revoked before it
        if let Some(k) = &m.agent_key
            && announced.get(k).is_none_or(|(mine, _, an, rev)| {
                (m.author == own) != *mine || *an >= m.n || rev.is_some_and(|r| m.n >= r)
            })
        {
            hurt("foreign_author");
        }
        let ch = index.chain_mut(&m.author).expect("own or peer");
        if stopped.get(&m.author).copied().unwrap_or(false) {
            ch.gap = true;
            return Ok(());
        }
        if m.n == ch.count + 1 {
            ch.push(&m.id);
        } else if m.n <= ch.count {
            hurt("duplicate_counter");
        } else {
            ch.gap = true;
            stopped.insert(m.author, true);
        }
        Ok(())
    })?;
    let repaired = crate::agentid::reconcile(&tx, link, &announced, crate::now_ms())?;
    if repaired > 0 {
        tracing::warn!(
            "link {}: agent keys table differed from the signed announcements in the history ({repaired} rows fixed)",
            &link.to_hex()[..8]
        );
    }
    // Heads: messages not referenced by any `core.parents` (from the verified bytes, not from the index);
    // with a damaged copy, recomputing from it is wrong, so the heads are left alone and the damage is reported
    let mut heads_fixed = false;
    if damage.is_none() {
        let mut heads: Vec<MessageId> = Db::all_ids(&tx, link)?
            .into_iter()
            .filter(|id| !referenced.contains(id))
            .collect();
        heads.sort();
        let stored = Db::heads(&tx, link)?;
        heads_fixed = stored != heads;
        if heads_fixed {
            Db::replace_heads(&tx, link, &heads)?;
        }
    }
    tx.commit()?;
    Ok(Audit {
        index,
        damage,
        heads_fixed,
        checked,
        legacy,
    })
}

fn fields_match(m: &StoredMsg, core: &EnvelopeCore) -> bool {
    core.author == m.signer()
        && core.n == m.n
        && core.lamport == m.lamport
        && core.ts == m.ts
        && core.kind.as_str() == m.kind
}

/// Summary of our own copy for the contact.
pub fn summary(
    index: &Index,
    heads: &[MessageId],
    audit: AuditState,
    state: LinkState,
) -> SyncSummary {
    SyncSummary {
        v: 1,
        heads: heads.to_vec(),
        authors: vec![
            AuthorChain {
                author: index.own,
                count: index.mine.count,
                tip: index.mine.tip,
            },
            AuthorChain {
                author: index.peer,
                count: index.theirs.count,
                tip: index.theirs.tip,
            },
        ],
        audit,
        state,
    }
}

/// What to do after comparing our summary with the contact's.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Comparison {
    /// The contact has more of **my** messages than I do: my state was rolled back.
    pub i_rolled_back: bool,
    /// I have more of the contact's messages than the contact itself (or it reported a rollback itself).
    pub peer_rolled_back: bool,
    /// Resend to the contact: (author, from which `n`, up to which).
    pub push: Vec<([u8; 32], u64, u64)>,
    /// The chains did not match at the common counter `m`: locate the place (author, m).
    pub localize: Vec<([u8; 32], u64)>,
    /// The copies are equal: heads, counters and chains match, and both sides' copy checks are clean.
    pub equal: bool,
}

/// Compare the contact's summary with our own copy.
pub fn compare(
    conn: &Connection,
    link: &LinkId,
    index: &Index,
    my_heads: &[MessageId],
    my_audit: &AuditState,
    peer: &SyncSummary,
) -> Result<Comparison> {
    let mut c = Comparison::default();
    let mut all_equal = true;
    for (author, mine) in [(index.own, &index.mine), (index.peer, &index.theirs)] {
        let theirs = peer
            .authors
            .iter()
            .find(|a| a.author == author)
            .cloned()
            .unwrap_or(AuthorChain {
                author,
                count: 0,
                tip: history::CHAIN_ZERO,
            });
        if author == index.own && theirs.count > mine.count {
            c.i_rolled_back = true;
        }
        if author == index.peer && mine.count > theirs.count {
            c.peer_rolled_back = true;
        }
        if mine.count != theirs.count || mine.tip != theirs.tip {
            all_equal = false;
        }
        if mine.count >= theirs.count {
            let at =
                index
                    .chain(&author)
                    .expect("own or peer")
                    .at(conn, link, &author, theirs.count)?;
            if at != theirs.tip {
                c.localize.push((author, theirs.count));
            } else if mine.count > theirs.count {
                c.push.push((author, theirs.count + 1, mine.count));
            }
        }
    }
    if peer.state == LinkState::RolledBack {
        c.peer_rolled_back = true;
    }
    let mut ph = peer.heads.clone();
    ph.sort();
    let mut mh = my_heads.to_vec();
    mh.sort();
    c.equal = all_equal
        && ph == mh
        && *my_audit == AuditState::Ok
        && peer.audit == AuditState::Ok
        && !c.i_rolled_back
        && !c.peer_rolled_back;
    Ok(c)
}

/// Chain points for the reply to `chain` (from our own copy): all `n ∈ [from, to]` that are multiples of `step` (with
/// `step = 1`, with IDs and a signature check of our own copy; `recipient_of(author)` is the recipient key for the
/// signature check).
pub fn chain_points(
    conn: &Connection,
    link: &LinkId,
    index: &Index,
    q: &ChainQuery,
    recipient_of: impl Fn(&[u8; 32]) -> [u8; 32],
) -> Result<Vec<ChainPoint>> {
    let Some(ch) = index.chain(&q.author) else {
        return Ok(vec![]);
    };
    if q.step == 0 || q.from == 0 {
        return Err(Error::bad_request("chain query: from and step must be ≥ 1"));
    }
    let to = q.to.min(ch.count);
    let mut out = Vec::new();
    if q.step == 1 {
        if to < q.from {
            return Ok(out);
        }
        if to - q.from + 1 > MAX_CHAIN_POINTS as u64 {
            return Err(Error::bad_request("chain query: too many points"));
        }
        let mut c = ch.at(conn, link, &q.author, q.from - 1)?;
        let recipient = recipient_of(&q.author);
        for m in Db::messages_by_n(conn, link, &q.author, q.from, to)? {
            c = history::chain_step(&c, &m.id);
            out.push(ChainPoint {
                n: m.n,
                tip: c,
                id: Some(m.id),
                sig_ok: Some(sig_ok(conn, link, &m, &recipient)),
            });
        }
        return Ok(out);
    }
    // A step greater than 1 must be a multiple of BLOCK: the points are checkpoints, the reply comes from memory
    // (otherwise a contact's request would force reading up to 1023 IDs per point)
    if !q.step.is_multiple_of(BLOCK) {
        return Err(Error::bad_request(
            "chain query: step must be 1 or a multiple of 1024",
        ));
    }
    let Some(mut n) = q.from.div_ceil(q.step).checked_mul(q.step) else {
        return Ok(out);
    };
    while n <= to {
        if out.len() >= MAX_CHAIN_POINTS {
            return Err(Error::bad_request("chain query: too many points"));
        }
        out.push(ChainPoint {
            n,
            tip: ch.at(conn, link, &q.author, n)?,
            id: None,
            sig_ok: None,
        });
        let Some(next) = n.checked_add(q.step) else {
            break;
        };
        n = next;
    }
    Ok(out)
}

/// The signature of our own copy of the message is valid (for an agent's message, there must also be an announcement
/// of its key signed by link-root before this `n` in our own history: we do not trust the key table).
pub fn sig_ok(conn: &Connection, link: &LinkId, m: &StoredMsg, recipient: &[u8; 32]) -> bool {
    let env = antenna_proto::Envelope {
        id: m.id,
        core: m.core.clone(),
        auth: Some(antenna_proto::Auth::Sig(m.sig.clone())),
    };
    match history::open_envelope(env) {
        Ok((env, core)) => {
            core.author == m.signer()
                && history::verify_envelope(link, &env, &core, recipient)
                && m.agent_key.is_none_or(|k| {
                    crate::agentid::announced_before(conn, link, &m.author, &k, m.n, recipient)
                })
        }
        Err(_) => false,
    }
}

/// Search step: the next request for the known interval `(lo, hi]` (the chains are equal at `lo` and differ at `hi`).
pub fn next_query(author: [u8; 32], lo: u64, hi: u64) -> ChainQuery {
    let len = hi - lo;
    if len <= MAX_CHAIN_POINTS as u64 {
        return ChainQuery {
            author,
            from: lo + 1,
            to: hi,
            step: 1,
        };
    }
    // The step is a multiple of BLOCK: the points are checkpoints, both sides reply from memory
    let step = BLOCK * len.div_ceil(BLOCK * MAX_CHAIN_POINTS as u64);
    ChainQuery {
        author,
        from: lo + 1,
        to: hi,
        step,
    }
}

/// Whose copy was altered at the divergence point, judged by the signature checks of both copies. Returns
/// `(who, why)`.
pub fn who_changed(
    author_is_me: bool,
    my_sig_ok: bool,
    peer_sig_ok: Option<bool>,
) -> (&'static str, &'static str) {
    match (my_sig_ok, peer_sig_ok) {
        (false, Some(false)) => ("both", "signature_invalid"),
        (false, _) => ("me", "signature_invalid"),
        (true, Some(false)) => ("contact", "signature_invalid"),
        (true, Some(true)) => {
            // Both copies are signed with the author's key: the author's side signed two versions of one message
            if author_is_me {
                ("me", "two_signed_versions")
            } else {
                ("contact", "two_signed_versions")
            }
        }
        (true, None) => ("unknown", "contact_did_not_answer"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        crypto,
        store::{MessageRecord, NewLink, PairRole},
    };
    use antenna_proto::{Body, MessageType, pairing::AddrHints};
    use zeroize::Zeroizing;

    /// Test DB with a link: (directory, DB, link, our link-root seed, our key, the contact's key).
    type TestDb = (
        tempfile::TempDir,
        Db,
        LinkId,
        Zeroizing<[u8; 32]>,
        [u8; 32],
        [u8; 32],
    );

    fn db_with_link() -> TestDb {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Db::open(
            &dir.path().join(crate::store::FILE_NAME),
            &crypto::random_secret(),
        )
        .unwrap();
        let link = LinkId([1; 32]);
        let seed = crypto::random_secret();
        let own = history::public_key(&seed);
        let peer = [7; 32];
        db.insert_link(
            &NewLink {
                link_id: link,
                role: PairRole::Inviter,
                label: Some("bob".into()),
                trust: 3,
                transcript_hash: [1; 32],
                pairing_kx: "X25519MLKEM768".into(),
                local_secret: crypto::random_secret(),
                peer_endpoint: [2; 32],
                peer_addrs: AddrHints::default(),
                root_ed25519_seed: Zeroizing::new(*seed),
                root_ed25519_pk: own,
                root_mldsa_seed: crypto::random_secret(),
                root_mldsa_vk: vec![4; 1952],
                peer_root_ed25519: peer,
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
        (dir, db, link, seed, own, peer)
    }

    /// Add our own message (signed) and return its ID.
    fn add(
        db: &mut Db,
        link: &LinkId,
        seed: &Zeroizing<[u8; 32]>,
        own: [u8; 32],
        peer: [u8; 32],
        text: &str,
    ) -> MessageId {
        let tx = db.tx().unwrap();
        let parents = Db::heads(&tx, link).unwrap();
        let n = Db::next_n(&tx, link, &own).unwrap();
        let lamport = Db::lamport(&tx, link).unwrap() + 1;
        let (_, env, core) = history::build(history::NewMessage {
            link,
            seed,
            author: own,
            recipient: peer,
            parents: parents.clone(),
            lamport,
            ts: 5,
            n,
            kind: MessageType::Text,
            body: Body::Text(text.into()),
        })
        .unwrap();
        let sig = match &env.auth {
            Some(antenna_proto::Auth::Sig(s)) => s.clone(),
            _ => unreachable!(),
        };
        Db::insert_message(
            &tx,
            &MessageRecord {
                id: env.id,
                link_id: *link,
                incoming: false,
                author: own,
                lamport,
                ts: 5,
                kind: "text",
                body: text,
                core: &env.core,
                parents: &core.parents,
                n,
                sig: &sig,
                origin: "live",
                agent: None,
                to: None,
                topic: None,
            },
            1,
        )
        .unwrap();
        tx.commit().unwrap();
        env.id
    }

    #[test]
    fn audit_builds_chains_and_finds_manual_edit_with_place() {
        let (_d, mut db, link, seed, own, peer) = db_with_link();
        let mut ids = vec![];
        for i in 0..5 {
            ids.push(add(&mut db, &link, &seed, own, peer, &format!("m{i}")));
        }
        let a = audit(&mut db, &link, own, peer).unwrap();
        assert_eq!(a.index.mine.count, 5);
        assert!(a.damage.is_none(), "{:?}", a.damage);
        assert!(!a.heads_fixed);
        // The chain matches a manual recomputation
        let mut c = history::CHAIN_ZERO;
        for id in &ids {
            c = history::chain_step(&c, id);
        }
        assert_eq!(a.index.mine.tip, c);
        assert_eq!(a.index.mine.at(db.conn(), &link, &own, 3).unwrap(), {
            let mut c = history::CHAIN_ZERO;
            for id in &ids[..3] {
                c = history::chain_step(&c, id);
            }
            c
        });
        // A manual edit of a text in the DB (same ID) is found, with its place
        db.conn()
            .execute(
                "UPDATE messages SET body = 'forged' WHERE id = ?1",
                rusqlite::params![&ids[2].0[..]],
            )
            .unwrap();
        let a = audit(&mut db, &link, own, peer).unwrap();
        let d = a.damage.unwrap();
        assert_eq!((d.place.n, d.what, d.id), (3, "text_changed", ids[2]));
        // An edit of core without recomputing the ID: likewise
        db.conn()
            .execute(
                "UPDATE messages SET body = 'm1', core = CAST(core || x'00' AS BLOB) WHERE id = ?1",
                rusqlite::params![&ids[1].0[..]],
            )
            .unwrap();
        let a = audit(&mut db, &link, own, peer).unwrap();
        assert_eq!(a.damage.unwrap().place.n, 2);
        // A corrupted heads table is fixed from the verified core (when the messages themselves are intact)
        db.conn()
            .execute(
                "UPDATE messages SET core = CAST(substr(core, 1, length(core) - 1) AS BLOB) WHERE id = ?1",
                rusqlite::params![&ids[1].0[..]],
            )
            .unwrap();
        db.conn()
            .execute(
                "UPDATE messages SET body = 'm2' WHERE id = ?1",
                rusqlite::params![&ids[2].0[..]],
            )
            .unwrap();
        assert!(audit(&mut db, &link, own, peer).unwrap().damage.is_none());
        db.conn().execute("DELETE FROM heads", []).unwrap();
        let a = audit(&mut db, &link, own, peer).unwrap();
        assert!(a.heads_fixed);
        assert_eq!(Db::heads(db.conn(), &link).unwrap(), vec![ids[4]]);
    }

    #[test]
    fn compare_finds_missing_rollback_and_divergence() {
        let (_d, mut db, link, seed, own, peer) = db_with_link();
        for i in 0..4 {
            add(&mut db, &link, &seed, own, peer, &format!("m{i}"));
        }
        let a = audit(&mut db, &link, own, peer).unwrap();
        let heads = Db::heads(db.conn(), &link).unwrap();
        let mine = summary(&a.index, &heads, AuditState::Ok, LinkState::Ok);
        // Equal copies
        let c = compare(db.conn(), &link, &a.index, &heads, &AuditState::Ok, &mine).unwrap();
        assert!(c.equal && c.push.is_empty() && c.localize.is_empty());
        // The contact knows only 2 of my messages → resend 3..4
        let mut short = mine.clone();
        short.authors[0].count = 2;
        short.authors[0].tip = a.index.mine.at(db.conn(), &link, &own, 2).unwrap();
        short.heads = vec![];
        let c = compare(db.conn(), &link, &a.index, &heads, &AuditState::Ok, &short).unwrap();
        assert_eq!(c.push, vec![(own, 3, 4)]);
        assert!(!c.equal && !c.i_rolled_back);
        // The contact has more of my messages than I do: my rollback
        let mut more = mine.clone();
        more.authors[0].count = 6;
        let c = compare(db.conn(), &link, &a.index, &heads, &AuditState::Ok, &more).unwrap();
        assert!(c.i_rolled_back);
        // Same counter, different chain → locate the place
        let mut forked = mine.clone();
        forked.authors[0].tip = [9; 32];
        let c = compare(db.conn(), &link, &a.index, &heads, &AuditState::Ok, &forked).unwrap();
        assert_eq!(c.localize, vec![(own, 4)]);
    }

    /// Reply to `chain` on the contact's numbers: no values lead to a panic.
    #[test]
    fn chain_points_never_panic_on_hostile_queries() {
        let (_d, mut db, link, seed, own, peer) = db_with_link();
        for i in 0..3 {
            add(&mut db, &link, &seed, own, peer, &format!("m{i}"));
        }
        let a = audit(&mut db, &link, own, peer).unwrap();
        let vals = [
            0,
            1,
            2,
            3,
            1023,
            1024,
            1025,
            u64::MAX / 2,
            u64::MAX - 1,
            u64::MAX,
        ];
        let mut answered = 0;
        for &from in &vals {
            for &to in &vals {
                for &step in &vals {
                    for author in [own, peer, [9; 32]] {
                        let q = ChainQuery {
                            author,
                            from,
                            to,
                            step,
                        };
                        if let Ok(p) = chain_points(db.conn(), &link, &a.index, &q, |_| peer) {
                            assert!(p.len() <= MAX_CHAIN_POINTS);
                            answered += 1;
                        }
                    }
                }
            }
        }
        assert!(answered > 0);
        // Garbage instead of a link request: a parse error, not a panic
        for bytes in [
            &[][..],
            &[0xa1, 0x65],
            &[0xff; 64],
            &[0xbf, 0x65, b's', b'y', b'n', b'c', 0x00],
        ] {
            assert!(antenna_proto::from_cbor::<antenna_proto::link::LinkRequest>(bytes).is_err());
        }
    }

    /// Scale measurement (not run by default):
    /// `cargo test -p antenna-core --lib audit_scale -- --ignored --nocapture`.
    /// Copy check and divergence search over N messages of one author.
    #[test]
    #[ignore = "scale measurement, ~1 min"]
    fn audit_scale() {
        let n: u64 = std::env::var("X_AUDIT_N")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(100_000);
        let (_d, mut db, link, seed, own, peer) = db_with_link();
        let t = std::time::Instant::now();
        {
            let tx = db.tx().unwrap();
            let mut parents = vec![];
            for i in 1..=n {
                let (_, env, core) = history::build(history::NewMessage {
                    link: &link,
                    seed: &seed,
                    author: own,
                    recipient: peer,
                    parents: parents.clone(),
                    lamport: i,
                    ts: i,
                    n: i,
                    kind: MessageType::Text,
                    body: Body::Text(format!("message number {i} with some text")),
                })
                .unwrap();
                let sig = match &env.auth {
                    Some(antenna_proto::Auth::Sig(s)) => s.clone(),
                    _ => unreachable!(),
                };
                let body = history::display_body(&core).unwrap();
                Db::insert_message(
                    &tx,
                    &MessageRecord {
                        id: env.id,
                        link_id: link,
                        incoming: false,
                        author: own,
                        lamport: i,
                        ts: i,
                        kind: "text",
                        body: &body,
                        core: &env.core,
                        parents: &core.parents,
                        n: i,
                        sig: &sig,
                        origin: "live",
                        agent: None,
                        to: None,
                        topic: None,
                    },
                    1,
                )
                .unwrap();
                parents = vec![env.id];
            }
            tx.commit().unwrap();
        }
        println!(
            "SCALE: {n} signed messages written in {} ms",
            t.elapsed().as_millis()
        );
        let t = std::time::Instant::now();
        let a = audit(&mut db, &link, own, peer).unwrap();
        println!(
            "SCALE: audit of {n} messages: {} ms (chain checkpoints in memory: {} × 32 B)",
            t.elapsed().as_millis(),
            a.index.mine.checkpoints.len()
        );
        assert_eq!(a.index.mine.count, n);
        // Divergence search: points with a step (from memory) and IDs inside the block (from the DB)
        let t = std::time::Instant::now();
        let q = next_query(own, 0, n);
        let p1 = chain_points(db.conn(), &link, &a.index, &q, |_| peer).unwrap();
        let q2 = next_query(own, n - n.min(1000), n);
        let p2 = chain_points(db.conn(), &link, &a.index, &q2, |_| peer).unwrap();
        println!(
            "SCALE: divergence search answers: {} points (step {}) + {} ids with signature check: {} ms",
            p1.len(),
            q.step,
            p2.len(),
            t.elapsed().as_millis()
        );
    }

    #[test]
    fn localization_queries_and_who_changed() {
        let q = next_query([1; 32], 0, 1_000_000);
        assert_eq!(q.step % BLOCK, 0);
        assert!((q.to - q.from + 1) / q.step <= MAX_CHAIN_POINTS as u64);
        let q2 = next_query([1; 32], 999_424, 1_000_000);
        assert_eq!(q2.step, 1);
        assert_eq!(
            who_changed(false, true, Some(false)),
            ("contact", "signature_invalid")
        );
        assert_eq!(
            who_changed(true, false, Some(true)),
            ("me", "signature_invalid")
        );
        assert_eq!(
            who_changed(true, true, Some(true)),
            ("me", "two_signed_versions")
        );
        assert_eq!(
            who_changed(false, true, Some(true)),
            ("contact", "two_signed_versions")
        );
    }

    #[test]
    fn chain_points_match_between_two_copies() {
        let (_d, mut db, link, seed, own, peer) = db_with_link();
        for i in 0..10 {
            add(&mut db, &link, &seed, own, peer, &format!("m{i}"));
        }
        let a = audit(&mut db, &link, own, peer).unwrap();
        let pts = chain_points(
            db.conn(),
            &link,
            &a.index,
            &ChainQuery {
                author: own,
                from: 1,
                to: 10,
                step: 1,
            },
            |_| peer,
        )
        .unwrap();
        assert_eq!(pts.len(), 10);
        assert!(pts.iter().all(|p| p.sig_ok == Some(true)));
        assert_eq!(pts[9].tip, a.index.mine.tip);
        // A step that is neither 1 nor a multiple of 1024 is rejected (otherwise the contact could force reading IDs
        // in blocks for every point)
        assert!(
            chain_points(
                db.conn(),
                &link,
                &a.index,
                &ChainQuery {
                    author: own,
                    from: 1,
                    to: 10,
                    step: 3,
                },
                |_| peer,
            )
            .is_err()
        );
        // Huge values do not overflow the arithmetic
        let pts = chain_points(
            db.conn(),
            &link,
            &a.index,
            &ChainQuery {
                author: own,
                from: u64::MAX - 5,
                to: u64::MAX,
                step: BLOCK * (u64::MAX / BLOCK / 2),
            },
            |_| peer,
        )
        .unwrap();
        assert!(pts.is_empty());
    }
}
