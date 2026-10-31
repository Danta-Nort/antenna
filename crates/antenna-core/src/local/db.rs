// SPDX-License-Identifier: AGPL-3.0-only
//! The local model tables of the node's encrypted database (schema 7, `store.rs`): installed model files with the
//! facts of their last check, local agents and their conversations. The conversation text lives only here: nothing of
//! it is written in plain text (D-96 §3.5).

use antenna_proto::control::{LocalItem, LocalUsage};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::{error::Result, store::Db};

/// What a model file looked like when its hash was checked: any change means checking again before the next load.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct FileStamp {
    pub dev: u64,
    pub ino: u64,
    pub size: u64,
    pub mtime_ns: i128,
}

impl FileStamp {
    #[cfg(unix)]
    pub(crate) fn of(path: &std::path::Path) -> std::io::Result<FileStamp> {
        use std::os::unix::fs::MetadataExt;
        let m = std::fs::metadata(path)?;
        Ok(FileStamp {
            dev: m.dev(),
            ino: m.ino(),
            size: m.len(),
            mtime_ns: i128::from(m.mtime()) * 1_000_000_000 + i128::from(m.mtime_nsec()),
        })
    }

    /// Windows: the volume serial number and file index need `GetFileInformationByHandle` (std's are unstable), which
    /// comes with the built-in runtime there (D-134, WP-27, phase W5). Without an identity a model is never taken for
    /// checked: refused.
    #[cfg(windows)]
    pub(crate) fn of(_path: &std::path::Path) -> std::io::Result<FileStamp> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "local models are not available on Windows yet",
        ))
    }
}

/// An installed (or downloading) model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ModelRow {
    pub id: String,
    /// `downloading` or `ready`.
    pub state: String,
    pub size: u64,
    pub sha256: String,
    /// `ready`: the file as it was checked.
    pub verified: Option<FileStamp>,
}

pub(crate) fn models(db: &Db) -> Result<Vec<ModelRow>> {
    let mut st = db
        .conn()
        .prepare("SELECT id, state, size, sha256, verified FROM local_models ORDER BY id")?;
    let rows = st.query_map([], |r| {
        Ok(ModelRow {
            id: r.get(0)?,
            state: r.get(1)?,
            size: r.get::<_, i64>(2)? as u64,
            sha256: r.get(3)?,
            verified: r
                .get::<_, Option<String>>(4)?
                .and_then(|j| serde_json::from_str(&j).ok()),
        })
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

pub(crate) fn model_set(db: &Db, row: &ModelRow, now_ms: u64) -> Result<()> {
    let verified = row
        .verified
        .map(|v| serde_json::to_string(&v).unwrap_or_default());
    db.conn().execute(
        "INSERT INTO local_models(id, state, size, sha256, verified, added_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(id) DO UPDATE SET state = excluded.state, size = excluded.size, sha256 = excluded.sha256,
           verified = excluded.verified",
        params![
            row.id,
            row.state,
            row.size as i64,
            row.sha256,
            verified,
            now_ms as i64
        ],
    )?;
    Ok(())
}

pub(crate) fn model_delete(db: &Db, id: &str) -> Result<()> {
    db.conn()
        .execute("DELETE FROM local_models WHERE id = ?1", params![id])?;
    Ok(())
}

/// Local agents: (agent ID, name, model, created).
pub(crate) fn agents(db: &Db) -> Result<Vec<(i64, String, String, u64)>> {
    let mut st = db.conn().prepare(
        "SELECT l.agent_id, a.name, l.model, l.created_ms FROM local_agents l JOIN agents a ON a.id = l.agent_id
         ORDER BY l.created_ms, l.agent_id",
    )?;
    let rows = st.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, i64>(3)? as u64,
        ))
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

pub(crate) fn agent_insert(db: &Db, agent_id: i64, model: &str, now_ms: u64) -> Result<()> {
    db.conn().execute(
        "INSERT INTO local_agents(agent_id, model, created_ms) VALUES (?1, ?2, ?3)",
        params![agent_id, model, now_ms as i64],
    )?;
    Ok(())
}

/// The model of a local agent; `None` for any other agent.
pub(crate) fn agent_model(db: &Db, agent_id: i64) -> Result<Option<String>> {
    Ok(db
        .conn()
        .query_row(
            "SELECT model FROM local_agents WHERE agent_id = ?1",
            params![agent_id],
            |r| r.get(0),
        )
        .optional()?)
}

/// One message of a conversation.
pub(crate) struct NewItem<'a> {
    pub agent_id: i64,
    pub counterpart: &'a str,
    pub turn: u64,
    pub role: &'a str,
    pub text: &'a str,
    pub ts_ms: u64,
    pub outcome: Option<&'a str>,
    /// Why a turn failed or was interrupted.
    pub detail: Option<&'a str>,
    pub usage: Option<&'a LocalUsage>,
}

pub(crate) fn item_insert(db: &Db, it: &NewItem<'_>) -> Result<i64> {
    let usage = it
        .usage
        .map(|u| serde_json::to_string(u).unwrap_or_default());
    db.conn().execute(
        "INSERT INTO local_turns(agent_id, counterpart, turn, role, text, ts, outcome, detail, usage)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            it.agent_id,
            it.counterpart,
            it.turn as i64,
            it.role,
            it.text,
            it.ts_ms as i64,
            it.outcome,
            it.detail.filter(|d| !d.is_empty()),
            usage
        ],
    )?;
    Ok(db.conn().last_insert_rowid())
}

fn item_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<LocalItem> {
    Ok(LocalItem {
        seq: r.get(0)?,
        turn: r.get::<_, i64>(1)? as u64,
        role: r.get(2)?,
        text: r.get(3)?,
        ts_ms: r.get::<_, i64>(4)? as u64,
        outcome: r.get(5)?,
        detail: r.get(6)?,
        usage: r
            .get::<_, Option<String>>(7)?
            .and_then(|j| serde_json::from_str(&j).ok()),
    })
}

/// A page of a conversation, oldest first; the flag says whether older messages exist.
pub(crate) fn items(
    db: &Db,
    agent_id: i64,
    counterpart: &str,
    limit: u32,
    before: Option<i64>,
) -> Result<(Vec<LocalItem>, bool)> {
    let mut st = db.conn().prepare(
        "SELECT seq, turn, role, text, ts, outcome, detail, usage FROM local_turns
         WHERE agent_id = ?1 AND counterpart = ?2 AND seq < ?3 ORDER BY seq DESC LIMIT ?4",
    )?;
    let rows = st.query_map(
        params![
            agent_id,
            counterpart,
            before.unwrap_or(i64::MAX),
            i64::from(limit) + 1
        ],
        item_of,
    )?;
    let mut v = rows.collect::<std::result::Result<Vec<_>, _>>()?;
    let more = v.len() > limit as usize;
    v.truncate(limit as usize);
    v.reverse();
    Ok((v, more))
}

/// The last turn number and how many turns the agent has had (all conversations).
pub(crate) fn turn_counts(db: &Db, agent_id: i64, counterpart: &str) -> Result<(u64, u64)> {
    let last: Option<i64> = db.conn().query_row(
        "SELECT max(turn) FROM local_turns WHERE agent_id = ?1 AND counterpart = ?2",
        params![agent_id, counterpart],
        |r| r.get(0),
    )?;
    let all: i64 = db.conn().query_row(
        "SELECT count(*) FROM local_turns WHERE agent_id = ?1 AND role = 'agent'",
        params![agent_id],
        |r| r.get(0),
    )?;
    Ok((last.unwrap_or(0) as u64, all as u64))
}

/// The last finished turn of the agent: when, and its usage.
pub(crate) fn last_turn(db: &Db, agent_id: i64) -> Result<Option<(u64, Option<LocalUsage>)>> {
    Ok(db
        .conn()
        .query_row(
            "SELECT ts, usage FROM local_turns WHERE agent_id = ?1 AND role = 'agent' ORDER BY seq DESC LIMIT 1",
            params![agent_id],
            |r| {
                Ok((
                    r.get::<_, i64>(0)? as u64,
                    r.get::<_, Option<String>>(1)?
                        .and_then(|j| serde_json::from_str(&j).ok()),
                ))
            },
        )
        .optional()?)
}

pub(crate) fn conversation_delete(db: &Db, agent_id: i64, counterpart: &str) -> Result<()> {
    db.conn().execute(
        "DELETE FROM local_turns WHERE agent_id = ?1 AND counterpart = ?2",
        params![agent_id, counterpart],
    )?;
    Ok(())
}
