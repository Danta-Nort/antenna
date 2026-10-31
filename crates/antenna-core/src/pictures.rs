// SPDX-License-Identifier: AGPL-3.0-only
//! Profile pictures (`docs/PROTOCOL.md` §25, `docs/CONTROL.md` §28): the owner chooses a drawn picture or an own photo
//! for themselves and for each of their agents; the node tells every contact whose node has `picture/0` with a signed
//! `control` / `picture` message from its link-root, and keeps the newest picture each contact announced.
//!
//! - **What is sent, and when.** The history is the record: on a link, the owner's picture and the picture of each of
//!   the owner's agents the contact already knows (announced in that link, §21; an agent the contact never heard of is
//!   not revealed by its picture) are compared with the latest picture message of this side in the link's history,
//!   and a new message goes out when they differ. This runs when the owner changes a picture, when the contact's
//!   features are learned on a connection, and right after an agent's first message in a link. A message displaced by
//!   a rollback is gone from the history, so it is simply sent again. A node without `picture/0` gets nothing.
//! - **A drawn picture** travels as its id only; the receiving window draws it from its own assets.
//! - **A photo** is made by [`antenna_files::picture::rebuild`]: the file is checked in the sandbox, and only its
//!   rebuilt pixels, cropped, resized and encoded again, are kept and sent (no metadata survives). A contact's photo is
//!   kept as received but never shown: it goes through the same check before the window gets anything, and the window
//!   gets only the JPEG this daemon made from the rebuilt pixels. Photos from a contact at trust level 1 are not
//!   checked or shown (no files at level 1, SPEC §9); drawn ids are shown at every level (nothing is decoded).
//! - Pictures are display, not permission: an owner session is enough to change one, and nothing an agent may do
//!   depends on them. The agent role has no picture command.

use std::collections::HashMap;
use std::path::Path;
use std::sync::PoisonError;

use antenna_proto::{
    Body, EnvelopeCore, LinkId, MessageType,
    control::{PictureEntry, WITHHELD_LEVEL, WITHHELD_REFUSED, WITHHELD_UNAVAILABLE, code},
    picture::{PHOTO_MIMES, PictureBody, PicturePhoto, valid_drawn_id},
};
use rusqlite::{Connection, OptionalExtension, params};

use crate::error::{Error, Result};
use crate::events::NodeEvent;
use crate::node::{LinkShared, Session};
use crate::store::Db;

/// The subject of the owner's own picture and of a contact's picture in person (an agent's is its name).
const PERSON: &str = "";

/// What the owner chose for a picture (`picture_set`).
#[derive(Debug, Clone)]
pub enum Choice {
    /// A drawn picture by id (`set1/fox`).
    Drawn(String),
    /// An image file the daemon reads and rebuilds.
    Photo(String),
    /// Back to initials.
    Remove,
}

/// One of this node's own pictures (`own_pictures`).
struct Own {
    subject: String,
    drawn: Option<String>,
    photo: Option<Vec<u8>>,
    updated_ms: u64,
}

/// A contact's picture as received (`peer_pictures`).
struct Peer {
    link: LinkId,
    subject: String,
    n: i64,
    drawn: Option<String>,
    photo: Option<Vec<u8>>,
    mime: Option<String>,
    shown: Option<Vec<u8>>,
    state: Option<String>,
    updated_ms: u64,
}

/// Checks run one at a time: a contact's photo is checked once, however many windows ask at the same moment.
static CHECKS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A photo's id in `pictures`: the first 8 bytes of the BLAKE3 of the bytes the window will get, in hex.
fn photo_id(bytes: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(&blake3::hash(bytes).as_bytes()[..8])
}

fn own_rows(conn: &Connection) -> Result<Vec<Own>> {
    let mut st = conn.prepare(
        "SELECT subject, drawn, photo, updated_ms FROM own_pictures ORDER BY subject <> '', subject",
    )?;
    let rows = st.query_map([], |r| {
        Ok(Own {
            subject: r.get(0)?,
            drawn: r.get(1)?,
            photo: r.get(2)?,
            updated_ms: r.get::<_, i64>(3)? as u64,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}

fn peer_rows(conn: &Connection, only: Option<(&LinkId, &str)>) -> Result<Vec<Peer>> {
    let mut st = conn.prepare(
        "SELECT link_id, subject, n, drawn, photo, photo_mime, shown, state, updated_ms FROM peer_pictures
         WHERE (?1 IS NULL OR (link_id = ?1 AND subject = ?2)) ORDER BY link_id, subject <> '', subject",
    )?;
    let (l, s) = match only {
        Some((l, s)) => (Some(l.0.to_vec()), s.to_string()),
        None => (None, String::new()),
    };
    let rows = st.query_map(params![l, s], |r| {
        let link: Vec<u8> = r.get(0)?;
        Ok((
            link,
            Peer {
                link: LinkId([0; 32]),
                subject: r.get(1)?,
                n: r.get(2)?,
                drawn: r.get(3)?,
                photo: r.get(4)?,
                mime: r.get(5)?,
                shown: r.get(6)?,
                state: r.get(7)?,
                updated_ms: r.get::<_, i64>(8)? as u64,
            },
        ))
    })?;
    let mut out = Vec::new();
    for r in rows {
        let (link, mut p) = r?;
        p.link = LinkId(
            link.try_into()
                .map_err(|_| Error::internal("db: picture link is not 32 bytes"))?,
        );
        out.push(p);
    }
    Ok(out)
}

/// The name the contact knows one of the owner's agents by on `link` (the link's default wake agent is `wake`,
/// `Session::agent_public_name`).
fn public_name(db: &Db, link: &LinkId, local: &str) -> String {
    if local.starts_with("wake-")
        && let Ok(Some((id, _, _))) = db.wake_rule(link)
        && db.agent(id).is_ok_and(|a| a.name == local)
    {
        return "wake".into();
    }
    local.to_string()
}

fn body_of(public: &str, own: Option<&Own>) -> PictureBody {
    PictureBody {
        agent: (!public.is_empty()).then(|| public.to_string()),
        drawn: own.and_then(|o| o.drawn.clone()),
        photo: own.and_then(|o| o.photo.clone()).map(|data| PicturePhoto {
            mime: antenna_files::picture::MIME.into(),
            data,
        }),
    }
}

/// This side's latest picture message per subject in the link's history.
fn last_sent(
    conn: &Connection,
    link: &LinkId,
    own_root: &[u8; 32],
) -> Result<HashMap<String, PictureBody>> {
    let mut st = conn.prepare(
        "SELECT core FROM messages WHERE link_id = ?1 AND author = ?2 AND kind = 'control' ORDER BY n",
    )?;
    let rows = st.query_map(params![&link.0[..], &own_root[..]], |r| {
        r.get::<_, Vec<u8>>(0)
    })?;
    let mut out = HashMap::new();
    for core in rows {
        if let Ok(EnvelopeCore {
            body: Body::Picture(p),
            ..
        }) = antenna_proto::from_cbor::<EnvelopeCore>(&core?)
        {
            out.insert(p.agent.clone().unwrap_or_default(), p);
        }
    }
    Ok(out)
}

/// The picture messages a link needs now: for the owner and for each of the owner's agents the contact knows here,
/// the current picture when it differs from the last one sent; a removal only where a picture was sent before.
fn due(db: &Db, link: &LinkId, own_root: &[u8; 32]) -> Result<Vec<PictureBody>> {
    let conn = db.conn();
    let sent = last_sent(conn, link, own_root)?;
    let own = own_rows(conn)?;
    let mut by_public: HashMap<String, &Own> = HashMap::new();
    for o in &own {
        let p = if o.subject.is_empty() {
            String::new()
        } else {
            public_name(db, link, &o.subject)
        };
        by_public.insert(p, o);
    }
    let mut subjects = vec![PERSON.to_string()];
    for k in crate::agentid::all(conn, link)? {
        if k.mine && k.revoked_n.is_none() && !subjects.contains(&k.name) {
            subjects.push(k.name);
        }
    }
    // A removed agent's key is revoked (D-119), but the contact still shows the picture it was sent: it gets the removal
    let mut shown: Vec<&String> = sent
        .iter()
        .filter(|(s, b)| !b.is_removal() && !subjects.contains(s))
        .map(|(s, _)| s)
        .collect();
    shown.sort();
    subjects.extend(shown.into_iter().cloned());
    let mut out = Vec::new();
    for s in subjects {
        let want = body_of(&s, by_public.get(&s).copied());
        let changed = match sent.get(&s) {
            Some(prev) => *prev != want,
            None => !want.is_removal(),
        };
        if changed {
            out.push(want);
        }
    }
    Ok(out)
}

impl LinkShared {
    /// Bring the contact up to date with this node's pictures (only a node with `picture/0`; nothing while sending is
    /// blocked by a rollback or a divergence). Returns how many picture messages were queued; the caller kicks the
    /// delivery.
    pub(crate) fn sync_pictures(&self) -> Result<usize> {
        if !self.peer_supports_picture() || self.send_block().is_some() {
            return Ok(0);
        }
        let due = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            due(&db, &self.link_id, &self.own_root)?
        };
        for body in &due {
            self.append(MessageType::Control, Body::Picture(body.clone()))?;
        }
        if !due.is_empty() {
            tracing::debug!(
                "link {}: {} picture message(s) queued",
                self.short(),
                due.len()
            );
        }
        Ok(due.len())
    }
}

/// A contact's picture message (live or resent, already checked): keep it if it is newer than the one kept for its
/// subject. Returns the subject when what is shown changed.
pub(crate) fn apply_peer(
    conn: &Connection,
    link: &LinkId,
    body: &PictureBody,
    n: u64,
    now_ms: u64,
) -> Result<Option<String>> {
    let subject = body.agent.clone().unwrap_or_default();
    let prev: Option<i64> = conn
        .query_row(
            "SELECT n FROM peer_pictures WHERE link_id = ?1 AND subject = ?2",
            params![&link.0[..], subject],
            |r| r.get(0),
        )
        .optional()?;
    if prev.is_some_and(|p| p >= n as i64) {
        return Ok(None);
    }
    let (photo, mime) = match &body.photo {
        Some(p) => (Some(p.data.clone()), Some(p.mime.clone())),
        None => (None, None),
    };
    conn.execute(
        "INSERT INTO peer_pictures(link_id, subject, n, drawn, photo, photo_mime, shown, state, updated_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, ?8)
         ON CONFLICT(link_id, subject) DO UPDATE SET n = excluded.n, drawn = excluded.drawn, photo = excluded.photo,
           photo_mime = excluded.photo_mime, shown = NULL, state = excluded.state, updated_ms = excluded.updated_ms",
        params![
            &link.0[..],
            subject,
            n as i64,
            body.drawn,
            photo,
            mime,
            body.photo.as_ref().map(|_| "unchecked"),
            now_ms as i64
        ],
    )?;
    Ok(Some(subject))
}

/// Forget the pictures of a revoked link (a contact's photo is personal data).
pub(crate) fn forget_link(conn: &Connection, link: &LinkId) -> Result<()> {
    conn.execute(
        "DELETE FROM peer_pictures WHERE link_id = ?1",
        params![&link.0[..]],
    )?;
    Ok(())
}

/// Forget a removed agent's own picture.
pub(crate) fn forget_own(conn: &Connection, agent: &str) -> Result<()> {
    conn.execute(
        "DELETE FROM own_pictures WHERE subject = ?1",
        params![agent],
    )?;
    Ok(())
}

fn own_entry(o: &Own) -> PictureEntry {
    PictureEntry {
        agent: (!o.subject.is_empty()).then(|| o.subject.clone()),
        drawn: o.drawn.clone(),
        photo: o.photo.as_deref().map(photo_id),
        updated_ms: o.updated_ms,
        ..Default::default()
    }
}

fn peer_entry(p: &Peer, label: &str, trust: u8, checker: bool) -> PictureEntry {
    // Level 1 takes no files (SPEC §9): a photo checked at a higher level is not shown after the level went down
    let shown = (trust >= 2 && p.state.as_deref() == Some("ok"))
        .then_some(p.shown.as_deref())
        .flatten();
    let withheld = match (&p.photo, shown) {
        (Some(_), None) if trust < 2 => Some(WITHHELD_LEVEL),
        (Some(_), None) if p.state.as_deref() == Some("refused") => Some(WITHHELD_REFUSED),
        (Some(_), None) if !checker || p.state.as_deref() == Some("unchecked") => {
            Some(WITHHELD_UNAVAILABLE)
        }
        _ => None,
    };
    PictureEntry {
        contact: Some(label.to_string()),
        link_id: Some(p.link.to_hex()),
        agent: (!p.subject.is_empty()).then(|| p.subject.clone()),
        drawn: p.drawn.clone(),
        photo: shown.map(photo_id),
        withheld: withheld.map(Into::into),
        updated_ms: p.updated_ms,
    }
}

/// The file name the check compares with a contact's photo: the extension of its declared type.
fn check_name(mime: &str) -> &'static str {
    match mime {
        "image/png" => "picture.png",
        "image/webp" => "picture.webp",
        _ => "picture.jpg",
    }
}

impl Session {
    /// `pictures`: the owner's own, then each contact's; contacts' photos waiting for their check are checked first.
    pub async fn pictures(&self) -> Result<Vec<PictureEntry>> {
        self.check_pictures().await?;
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        let mut out: Vec<PictureEntry> = own_rows(db.conn())?.iter().map(own_entry).collect();
        let peers = peer_rows(db.conn(), None)?;
        // Active links only, in the order they were made (a revoked link's pictures are gone with it)
        for l in db.links()? {
            for p in peers.iter().filter(|p| p.link == l.link_id) {
                let e = peer_entry(p, &l.label, l.trust, self.files.is_some());
                if e.drawn.is_some() || e.photo.is_some() || e.withheld.is_some() {
                    out.push(e);
                }
            }
        }
        Ok(out)
    }

    /// Check the contacts' photos that wait for it (trust level 2 and up): only the JPEG made from the rebuilt pixels
    /// is kept for showing. A photo the check refuses stays refused; without a sandbox nothing is checked or shown.
    async fn check_pictures(&self) -> Result<()> {
        let Some(files) = self.files.clone() else {
            return Ok(());
        };
        let _one = CHECKS.lock().await;
        let pending: Vec<(Peer, String, u8)> = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let links: HashMap<LinkId, (String, u8)> = db
                .links()?
                .into_iter()
                .map(|l| (l.link_id, (l.label, l.trust)))
                .collect();
            peer_rows(db.conn(), None)?
                .into_iter()
                .filter(|p| p.state.as_deref() == Some("unchecked") && p.photo.is_some())
                .filter_map(|p| {
                    let (label, trust) = links.get(&p.link)?.clone();
                    (trust >= 2).then_some((p, label, trust))
                })
                .collect()
        };
        for (p, label, trust) in pending {
            let mime = p.mime.clone().unwrap_or_default();
            let photo = p.photo.clone().unwrap_or_default();
            let allowed: Vec<&str> = PHOTO_MIMES.iter().copied().filter(|m| *m == mime).collect();
            let r = antenna_files::picture::rebuild(
                &files.checker,
                &photo,
                check_name(&mime),
                &allowed,
            )
            .await;
            let (state, shown) = match r {
                Ok(jpeg) => ("ok", Some(jpeg)),
                // Retried on the next `pictures`: the sandbox may come back (it is never skipped)
                Err(e) if e.code == code::SANDBOX_UNAVAILABLE => {
                    tracing::warn!("a contact's picture was not checked: {}", e.detail);
                    continue;
                }
                Err(e) => {
                    tracing::info!("a contact's picture was refused: {}: {}", e.code, e.detail);
                    ("refused", None)
                }
            };
            let entry = {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                let changed = db.conn().execute(
                    "UPDATE peer_pictures SET state = ?4, shown = ?5 WHERE link_id = ?1 AND subject = ?2 AND n = ?3",
                    params![&p.link.0[..], p.subject, p.n, state, shown],
                )?;
                if changed == 0 {
                    // A newer picture replaced it meanwhile: that one waits for its own check
                    continue;
                }
                peer_rows(db.conn(), Some((&p.link, &p.subject)))?
                    .first()
                    .map(|row| peer_entry(row, &label, trust, true))
            };
            if let Some(e) = entry {
                let _ = self.events.send(NodeEvent::Picture(Box::new(e)));
            }
        }
        Ok(())
    }

    /// `picture_set`: store the owner's choice for the owner or one of the owner's agents, tell the contacts, and
    /// answer with every picture.
    pub async fn picture_set(
        &self,
        agent: Option<String>,
        choice: Choice,
    ) -> Result<Vec<PictureEntry>> {
        let subject = match &agent {
            Some(name) => {
                let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
                db.agent_by_name(name)?.name
            }
            None => PERSON.to_string(),
        };
        let (drawn, photo) = match choice {
            Choice::Drawn(id) => {
                if !valid_drawn_id(&id) {
                    return Err(Error::bad_request(
                        "a drawn picture id is <set>/<animal>, like set1/fox",
                    ));
                }
                (Some(id), None)
            }
            Choice::Photo(path) => (None, Some(self.own_photo(&path).await?)),
            Choice::Remove => (None, None),
        };
        let now = crate::now_ms();
        let entry = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            if drawn.is_none() && photo.is_none() {
                forget_own(db.conn(), &subject)?;
            } else {
                db.conn().execute(
                    "INSERT INTO own_pictures(subject, drawn, photo, updated_ms) VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT(subject) DO UPDATE SET drawn = excluded.drawn, photo = excluded.photo,
                       updated_ms = excluded.updated_ms",
                    params![subject, drawn, photo, now as i64],
                )?;
            }
            own_entry(&Own {
                subject: subject.clone(),
                drawn,
                photo,
                updated_ms: now,
            })
        };
        let _ = self.events.send(NodeEvent::Picture(Box::new(entry)));
        self.sync_pictures_everywhere().await;
        self.pictures().await
    }

    /// The owner's photo: read the file, check it in the sandbox, keep the picture made from its rebuilt pixels.
    async fn own_photo(&self, path: &str) -> Result<Vec<u8>> {
        let p = Path::new(path);
        if !p.is_absolute() {
            return Err(Error::bad_request("the photo's path must be absolute"));
        }
        let meta = std::fs::metadata(p)
            .map_err(|e| Error::new(code::NOT_FOUND, format!("cannot read the photo: {e}")))?;
        if !meta.is_file() {
            return Err(Error::bad_request("the photo is not a file"));
        }
        if meta.len() > antenna_files::picture::MAX_SOURCE {
            return Err(Error::new(
                code::PICTURE_REFUSED,
                format!(
                    "the image is larger than {} MB",
                    antenna_files::picture::MAX_SOURCE >> 20
                ),
            ));
        }
        let data = tokio::fs::read(p)
            .await
            .map_err(|e| Error::new(code::NOT_FOUND, format!("cannot read the photo: {e}")))?;
        let Some(files) = self.files.clone() else {
            return Err(Error::new(
                code::SANDBOX_UNAVAILABLE,
                "the file check is not available on this computer, so no photo can be used",
            ));
        };
        let name = p
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "photo".into());
        let any = [
            "image/png",
            "image/jpeg",
            "image/webp",
            "image/gif",
            "image/bmp",
        ];
        antenna_files::picture::rebuild(&files.checker, &data, &name, &any)
            .await
            .map_err(|e| match e.code {
                "sandbox_unavailable" => Error::new(
                    code::SANDBOX_UNAVAILABLE,
                    "the file check cannot run on this computer, so no photo can be used",
                ),
                "not_an_image" => Error::new(
                    code::PICTURE_REFUSED,
                    "this file is not an image Antenna can use (PNG, JPEG, WebP, GIF or BMP)",
                ),
                "too_large" => Error::new(code::PICTURE_REFUSED, "the image is too large"),
                _ => Error::new(
                    code::PICTURE_REFUSED,
                    format!("the image did not pass the file check ({})", e.detail),
                ),
            })
    }

    /// [`Session::sync_pictures_everywhere`] on the calling thread (a few database writes per link).
    pub(crate) fn sync_pictures_now(&self) {
        for rt in self.running_links() {
            match rt.shared.sync_pictures() {
                Ok(0) => {}
                Ok(_) => rt.shared.kick.notify_one(),
                Err(e) => tracing::warn!("pictures: {e}"),
            }
        }
    }

    /// Queue the picture messages every running link needs and kick their delivery. A link whose contact's features
    /// are not known yet (no connection since pairing or since an update) connects first: the features exchange
    /// queues the pictures when the contact's node has `picture/0`.
    pub(crate) async fn sync_pictures_everywhere(&self) {
        for rt in self.running_links() {
            let sh = rt.shared.clone();
            if sh.peer_feat.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                tokio::spawn(async move {
                    let _ =
                        tokio::time::timeout(std::time::Duration::from_secs(10), sh.connect_raw())
                            .await;
                });
                continue;
            }
            let r = tokio::task::spawn_blocking(move || {
                let r = sh.sync_pictures();
                sh.kick.notify_one();
                r
            })
            .await;
            if let Ok(Err(e)) = r {
                tracing::warn!("pictures: {e}");
            }
        }
    }

    /// `picture_photo`: a rebuilt photo by its id: the owner's own (made from rebuilt pixels when it was chosen) or a
    /// contact's that passed the check. Never the bytes a contact sent.
    pub fn picture_photo(&self, id: &str) -> Result<Vec<u8>> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(b) = own_rows(db.conn())?
            .into_iter()
            .filter_map(|o| o.photo)
            .find(|b| photo_id(b) == id)
        {
            return Ok(b);
        }
        let trust: HashMap<LinkId, u8> = db
            .links()?
            .into_iter()
            .map(|l| (l.link_id, l.trust))
            .collect();
        peer_rows(db.conn(), None)?
            .into_iter()
            .filter(|p| {
                p.state.as_deref() == Some("ok") && trust.get(&p.link).is_some_and(|t| *t >= 2)
            })
            .filter_map(|p| p.shown)
            .find(|b| photo_id(b) == id)
            .ok_or_else(|| Error::new(code::NOT_FOUND, "no such picture"))
    }
}

/// A contact's picture changed (`after_receive`): the entry for subscribers. Its photo, if any, is checked on the next
/// `pictures`.
pub(crate) fn peer_entry_of(
    db: &Db,
    link: &LinkId,
    label: &str,
    trust: u8,
    subject: &str,
) -> Option<PictureEntry> {
    peer_rows(db.conn(), Some((link, subject)))
        .ok()?
        .first()
        .map(|p| peer_entry(p, label, trust, true))
}

/// The history line of a picture message (`history::display_body`): a fixed vocabulary, never shown in the feed.
pub(crate) fn display(p: &PictureBody) -> String {
    let who = p
        .agent
        .as_deref()
        .map(|a| format!(" of {a}"))
        .unwrap_or_default();
    match (&p.drawn, &p.photo) {
        (Some(d), _) => format!("picture{who}: {d}"),
        (None, Some(ph)) => format!("picture{who}: photo ({} bytes)", ph.data.len()),
        (None, None) => format!("picture{who}: removed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> (tempfile::TempDir, Db) {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(
            &dir.path().join("x.db"),
            &zeroize::Zeroizing::new([7u8; 32]),
        )
        .unwrap();
        (dir, db)
    }

    fn drawn(agent: Option<&str>, id: &str) -> PictureBody {
        PictureBody {
            agent: agent.map(Into::into),
            drawn: Some(id.into()),
            photo: None,
        }
    }

    #[test]
    fn a_contact_picture_is_replaced_only_by_a_newer_one() {
        let (_d, db) = db();
        let link = LinkId([1; 32]);
        let c = db.conn();
        c.execute_batch("PRAGMA foreign_keys = OFF").unwrap();
        assert_eq!(
            apply_peer(c, &link, &drawn(None, "set1/fox"), 5, 1).unwrap(),
            Some(String::new())
        );
        assert_eq!(
            apply_peer(c, &link, &drawn(None, "set1/owl"), 4, 2).unwrap(),
            None,
            "older"
        );
        assert_eq!(
            apply_peer(c, &link, &drawn(None, "set1/owl"), 5, 2).unwrap(),
            None,
            "the same n"
        );
        assert_eq!(
            apply_peer(c, &link, &drawn(Some("lead"), "set2/wolf"), 6, 3).unwrap(),
            Some("lead".into()),
            "an agent is its own subject"
        );
        let rows = peer_rows(c, None).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0].drawn.as_deref(),
            Some("set1/fox"),
            "the person first"
        );
        assert_eq!(rows[1].subject, "lead");
        // A photo waits for its check; a newer drawn picture drops it.
        let photo = PictureBody {
            agent: None,
            drawn: None,
            photo: Some(PicturePhoto {
                mime: "image/jpeg".into(),
                data: vec![1, 2, 3],
            }),
        };
        apply_peer(c, &link, &photo, 7, 4).unwrap();
        let p = &peer_rows(c, Some((&link, ""))).unwrap()[0];
        assert_eq!(
            (p.state.as_deref(), p.drawn.as_deref()),
            (Some("unchecked"), None)
        );
        apply_peer(c, &link, &drawn(None, "set3/alien"), 8, 5).unwrap();
        let p = &peer_rows(c, Some((&link, ""))).unwrap()[0];
        assert_eq!((p.state.as_deref(), p.photo.as_ref()), (None, None));
    }

    #[test]
    fn a_photo_is_shown_only_when_checked_and_the_level_allows() {
        let link = LinkId([2; 32]);
        let mut p = Peer {
            link,
            subject: String::new(),
            n: 1,
            drawn: None,
            photo: Some(vec![9; 10]),
            mime: Some("image/jpeg".into()),
            shown: None,
            state: Some("unchecked".into()),
            updated_ms: 1,
        };
        let e = peer_entry(&p, "bob", 3, true);
        assert_eq!(
            (e.photo, e.withheld.as_deref()),
            (None, Some(WITHHELD_UNAVAILABLE))
        );
        let e = peer_entry(&p, "bob", 1, true);
        assert_eq!(
            e.withheld.as_deref(),
            Some(WITHHELD_LEVEL),
            "level 1: no files"
        );
        p.state = Some("ok".into());
        p.shown = Some(vec![7; 20]);
        let e = peer_entry(&p, "bob", 3, true);
        assert_eq!(
            e.photo,
            Some(photo_id(&[7; 20])),
            "the id of the rebuilt bytes"
        );
        assert_ne!(
            e.photo,
            Some(photo_id(&[9; 10])),
            "never the received bytes"
        );
        let e = peer_entry(&p, "bob", 1, true);
        assert_eq!(
            (e.photo, e.withheld.as_deref()),
            (None, Some(WITHHELD_LEVEL)),
            "trust lowered later"
        );
        p.state = Some("refused".into());
        p.shown = None;
        assert_eq!(
            peer_entry(&p, "bob", 3, true).withheld.as_deref(),
            Some(WITHHELD_REFUSED)
        );
    }

    #[test]
    fn display_lines() {
        assert_eq!(display(&drawn(None, "set1/fox")), "picture: set1/fox");
        assert_eq!(
            display(&drawn(Some("lead"), "set1/fox")),
            "picture of lead: set1/fox"
        );
        assert_eq!(
            display(&PictureBody {
                agent: None,
                drawn: None,
                photo: None
            }),
            "picture: removed"
        );
    }
}
