// SPDX-License-Identifier: AGPL-3.0-only
//! The team tables of the node's encrypted database (schema 8, `store.rs`): teams, their members, tasks and the
//! audit log. A task is one JSON record (`rec`) with its state and assignee also in columns for queries; the board a
//! window shows is derived from these rows, and the rows are the source of truth (D-111 item 9).

use std::path::PathBuf;

use rusqlite::{OptionalExtension, params};

use super::{MemberRow, MemberSpec, Task, TeamCfg, TeamRow};
use crate::{
    error::{Error, Result},
    store::Db,
};
use antenna_proto::control::{ApplyRequest, TeamLogEntry, code};

fn json<T: serde::Serialize>(v: &T) -> Result<String> {
    serde_json::to_string(v).map_err(|e| Error::internal(format!("teams: {e}")))
}

fn parse<T: serde::de::DeserializeOwned>(s: &str) -> Result<T> {
    serde_json::from_str(s).map_err(|e| Error::internal(format!("teams: stored record: {e}")))
}

const TEAM_COLS: &str = "id, name, project, git_dir, lead_id, target, integration, cfg, state, apply_request, \
                         created_ms";

fn team_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<(TeamRow, String, Option<String>)> {
    Ok((
        TeamRow {
            id: r.get(0)?,
            name: r.get(1)?,
            project: PathBuf::from(r.get::<_, String>(2)?),
            git_dir: PathBuf::from(r.get::<_, String>(3)?),
            lead_id: r.get(4)?,
            target: r.get(5)?,
            integration: r.get(6)?,
            cfg: TeamCfg::default(),
            state: r.get(8)?,
            apply_request: None,
            created_ms: r.get::<_, i64>(10)? as u64,
        },
        r.get(7)?,
        r.get(9)?,
    ))
}

fn finish_team((mut t, cfg, apply): (TeamRow, String, Option<String>)) -> Result<TeamRow> {
    t.cfg = parse(&cfg)?;
    t.apply_request = apply.map(|a| parse::<ApplyRequest>(&a)).transpose()?;
    Ok(t)
}

/// A new team; its ID.
pub(crate) fn team_insert(db: &Db, t: &TeamRow) -> Result<i64> {
    db.conn().execute(
        "INSERT INTO teams(name, project, git_dir, lead_id, target, integration, cfg, state, apply_request, created_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, ?9)",
        params![
            t.name,
            t.project.to_string_lossy(),
            t.git_dir.to_string_lossy(),
            t.lead_id,
            t.target,
            t.integration,
            json(&t.cfg)?,
            t.state,
            t.created_ms as i64
        ],
    )?;
    Ok(db.conn().last_insert_rowid())
}

/// Save the parts of a team that change: lead, budget and template, state, the pending apply request.
pub(crate) fn team_save(db: &Db, t: &TeamRow) -> Result<()> {
    let apply = t.apply_request.as_ref().map(json).transpose()?;
    db.conn().execute(
        "UPDATE teams SET lead_id = ?2, cfg = ?3, state = ?4, apply_request = ?5 WHERE id = ?1",
        params![t.id, t.lead_id, json(&t.cfg)?, t.state, apply],
    )?;
    Ok(())
}

pub(crate) fn team_delete(db: &Db, id: i64) -> Result<()> {
    db.conn()
        .execute("DELETE FROM teams WHERE id = ?1", params![id])?;
    Ok(())
}

pub(crate) fn teams(db: &Db) -> Result<Vec<TeamRow>> {
    let mut st = db.conn().prepare(&format!(
        "SELECT {TEAM_COLS} FROM teams ORDER BY created_ms, id"
    ))?;
    let rows = st
        .query_map([], team_of)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    rows.into_iter().map(finish_team).collect()
}

pub(crate) fn team(db: &Db, id: i64) -> Result<TeamRow> {
    let row = db
        .conn()
        .query_row(
            &format!("SELECT {TEAM_COLS} FROM teams WHERE id = ?1"),
            params![id],
            team_of,
        )
        .optional()?
        .ok_or_else(|| Error::new(code::NOT_FOUND, "the team is gone"))?;
    finish_team(row)
}

pub(crate) fn team_by_name(db: &Db, name: &str) -> Result<TeamRow> {
    let row = db
        .conn()
        .query_row(
            &format!("SELECT {TEAM_COLS} FROM teams WHERE name = ?1"),
            params![name],
            team_of,
        )
        .optional()?
        .ok_or_else(|| Error::new(code::NOT_FOUND, format!("no team {name:?}")))?;
    finish_team(row)
}

/// The team this agent leads, if any.
pub(crate) fn team_led_by(db: &Db, agent_id: i64) -> Result<Option<TeamRow>> {
    let row = db
        .conn()
        .query_row(
            &format!("SELECT {TEAM_COLS} FROM teams WHERE lead_id = ?1"),
            params![agent_id],
            team_of,
        )
        .optional()?;
    row.map(finish_team).transpose()
}

const MEMBER_COLS: &str =
    "m.agent_id, m.team_id, a.name, m.role, m.kind, m.spec, m.spawned_by, m.state, m.created_ms";

fn member_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<(MemberRow, String)> {
    Ok((
        MemberRow {
            agent_id: r.get(0)?,
            team_id: r.get(1)?,
            name: r.get(2)?,
            role: r.get(3)?,
            kind: r.get(4)?,
            spec: MemberSpec::default(),
            spawned_by: r.get(6)?,
            state: r.get(7)?,
            created_ms: r.get::<_, i64>(8)? as u64,
        },
        r.get(5)?,
    ))
}

fn finish_member((mut m, spec): (MemberRow, String)) -> Result<MemberRow> {
    m.spec = parse(&spec)?;
    Ok(m)
}

pub(crate) fn member_insert(db: &Db, m: &MemberRow) -> Result<()> {
    db.conn().execute(
        "INSERT INTO team_members(agent_id, team_id, role, kind, spec, spawned_by, state, created_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            m.agent_id,
            m.team_id,
            m.role,
            m.kind,
            json(&m.spec)?,
            m.spawned_by,
            m.state,
            m.created_ms as i64
        ],
    )?;
    Ok(())
}

pub(crate) fn member_save(db: &Db, m: &MemberRow) -> Result<()> {
    db.conn().execute(
        "UPDATE team_members SET spec = ?2, state = ?3 WHERE agent_id = ?1",
        params![m.agent_id, json(&m.spec)?, m.state],
    )?;
    Ok(())
}

pub(crate) fn members(db: &Db, team_id: i64) -> Result<Vec<MemberRow>> {
    let mut st = db.conn().prepare(&format!(
        "SELECT {MEMBER_COLS} FROM team_members m JOIN agents a ON a.id = m.agent_id WHERE m.team_id = ?1
         ORDER BY m.created_ms, m.agent_id"
    ))?;
    let rows = st
        .query_map(params![team_id], member_of)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    rows.into_iter().map(finish_member).collect()
}

/// The worker row of an agent, if the agent is a team's worker.
pub(crate) fn member(db: &Db, agent_id: i64) -> Result<Option<MemberRow>> {
    let row = db
        .conn()
        .query_row(
            &format!(
                "SELECT {MEMBER_COLS} FROM team_members m JOIN agents a ON a.id = m.agent_id WHERE m.agent_id = ?1"
            ),
            params![agent_id],
            member_of,
        )
        .optional()?;
    row.map(finish_member).transpose()
}

/// Workers of every team that are not stopped (the machine's count).
pub(crate) fn active_workers(db: &Db) -> Result<u32> {
    Ok(db.conn().query_row(
        "SELECT count(*) FROM team_members WHERE state != 'stopped'",
        [],
        |r| r.get::<_, i64>(0),
    )? as u32)
}

pub(crate) fn task_insert(db: &Db, team_id: i64, t: &Task) -> Result<()> {
    db.conn().execute(
        "INSERT INTO team_tasks(id, team_id, state, assignee, rec, created_ms, updated_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            t.id,
            team_id,
            t.state,
            t.assignee,
            json(t)?,
            t.created_ms as i64,
            t.updated_ms as i64
        ],
    )?;
    Ok(())
}

pub(crate) fn task_save(db: &Db, t: &Task) -> Result<()> {
    let n = db.conn().execute(
        "UPDATE team_tasks SET state = ?2, assignee = ?3, rec = ?4, updated_ms = ?5 WHERE id = ?1",
        params![t.id, t.state, t.assignee, json(t)?, t.updated_ms as i64],
    )?;
    if n == 0 {
        return Err(Error::new(code::NOT_FOUND, "the task is gone"));
    }
    Ok(())
}

/// A task of a team by its ID or an unambiguous prefix of at least 6 characters.
pub(crate) fn task(db: &Db, team_id: i64, id: &str) -> Result<Task> {
    let id = id.trim().to_ascii_lowercase();
    if id.len() < 6 || !id.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(Error::bad_request(
            "a task ID is at least 6 hex characters (task_list shows them)",
        ));
    }
    let mut st = db.conn().prepare(
        "SELECT rec FROM team_tasks WHERE team_id = ?1 AND substr(id, 1, ?3) = ?2 LIMIT 2",
    )?;
    let recs = st
        .query_map(params![team_id, id, id.len() as i64], |r| {
            r.get::<_, String>(0)
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    match recs.as_slice() {
        [one] => parse(one),
        [] => Err(Error::new(
            code::NOT_FOUND,
            format!("no task {id} in this team"),
        )),
        _ => Err(Error::bad_request(format!(
            "{id} names more than one task: give more characters"
        ))),
    }
}

/// The team of a task given by ID or prefix, across teams (the owner's commands name only the task).
pub(crate) fn task_team(db: &Db, id: &str) -> Result<i64> {
    let id = id.trim().to_ascii_lowercase();
    if id.len() < 6 || !id.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(Error::bad_request(
            "a task ID is at least 6 hex characters (task_list shows them)",
        ));
    }
    let mut st = db
        .conn()
        .prepare("SELECT team_id FROM team_tasks WHERE substr(id, 1, ?2) = ?1 LIMIT 2")?;
    let ids = st
        .query_map(params![id, id.len() as i64], |r| r.get::<_, i64>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    match ids.as_slice() {
        [one] => Ok(*one),
        [] => Err(Error::new(code::NOT_FOUND, format!("no task {id}"))),
        _ => Err(Error::bad_request(format!(
            "{id} names more than one task: give more characters"
        ))),
    }
}

pub(crate) fn tasks(db: &Db, team_id: i64) -> Result<Vec<Task>> {
    let mut st = db
        .conn()
        .prepare("SELECT rec FROM team_tasks WHERE team_id = ?1 ORDER BY created_ms, id")?;
    let recs = st
        .query_map(params![team_id], |r| r.get::<_, String>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    recs.iter().map(|r| parse(r)).collect()
}

/// One entry of the team's audit log. Details never carry a worker's or a contact's text.
pub(crate) struct Entry<'a> {
    /// `owner`, an agent's name, `daemon`.
    pub actor: &'a str,
    /// What was done.
    pub action: &'a str,
    /// The task, if any.
    pub task: Option<&'a str>,
    /// The decision.
    pub decision: &'a str,
    /// Details.
    pub detail: &'a str,
}

pub(crate) fn log(db: &Db, team_id: i64, ts: u64, e: &Entry<'_>) -> Result<()> {
    let detail: String = e.detail.chars().take(500).collect();
    db.conn().execute(
        "INSERT INTO team_log(team_id, ts, actor, action, task, decision, detail) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![team_id, ts as i64, e.actor, e.action, e.task, e.decision, detail],
    )?;
    Ok(())
}

pub(crate) fn log_entries(db: &Db, team_id: i64, limit: u32) -> Result<Vec<TeamLogEntry>> {
    let mut st = db.conn().prepare(
        "SELECT ts, actor, action, task, decision, detail FROM (
           SELECT * FROM team_log WHERE team_id = ?1 ORDER BY seq DESC LIMIT ?2) ORDER BY seq",
    )?;
    let rows = st.query_map(params![team_id, limit as i64], |r| {
        Ok(TeamLogEntry {
            ts: r.get::<_, i64>(0)? as u64,
            actor: r.get(1)?,
            action: r.get(2)?,
            task: r.get(3)?,
            decision: r.get(4)?,
            detail: r.get(5)?,
        })
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}
