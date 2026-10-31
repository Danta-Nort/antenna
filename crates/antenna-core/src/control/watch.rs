// SPDX-License-Identifier: AGPL-3.0-only
//! `team_watch` (v7, CONTROL §25, D-111): the owner watches a team's workers live on one long-lived connection: a
//! snapshot of the turns in progress, then `worker_output` events until the client closes the connection. Like the
//! owner's subscription, it ends when the owner session ends (`login_required`) or the keys lock (`locked`), and also
//! when the team is removed (`not_found`). A slow client gets `lagged` and goes on.

use std::{
    sync::{Arc, PoisonError},
    time::Duration,
};

use antenna_proto::control::{Event, ServerMsg, code};
use tokio::sync::broadcast::error::RecvError;

use super::{Lines, Out, OwnerCtx, login_required, read_line};
use crate::{
    error::{Error, Result},
    events::NodeEvent,
    node::{Node, Session},
    now_ms,
    teams::Next,
};

fn gone(team: &str) -> Error {
    Error::new(code::NOT_FOUND, format!("the team {team} was removed"))
}

/// The dialog: the checks of `owner` (an owner session) have passed.
pub(super) async fn team_watch(
    s: Arc<Session>,
    team: String,
    node: &Node,
    ctx: OwnerCtx,
    mut lines: Lines,
    mut out: Out,
) -> Result<()> {
    let mut events = s.events.subscribe();
    let mut w = match s.team_watch(&team) {
        Ok(w) => w,
        Err(e) => return out.err(&e).await,
    };
    for o in std::mem::take(&mut w.snapshot) {
        out.send(&ServerMsg::Event(Event::WorkerOutput(o))).await?;
    }
    // The client closed the connection: the watch is over.
    let mut reader =
        tokio::spawn(async move { while let Ok(Some(_)) = read_line(&mut lines).await {} });
    let mut tick = tokio::time::interval(Duration::from_secs(5));
    let end = loop {
        tokio::select! {
            p = w.next() => match p {
                Next::Piece(o) => {
                    if out.send(&ServerMsg::Event(Event::WorkerOutput(o))).await.is_err() {
                        break None;
                    }
                }
                Next::Lagged(missed) => {
                    if out.send(&ServerMsg::Event(Event::Lagged { missed })).await.is_err() {
                        break None;
                    }
                }
                Next::Closed => break None,
            },
            ev = events.recv() => match ev {
                Ok(NodeEvent::Team(t)) if t.team == team && t.change == "removed" => break Some(gone(&team)),
                Err(RecvError::Closed) => break None,
                // Other events, or missed ones: the tick checks the team too.
                _ => {}
            },
            // Long-lived like a subscription: the session is rechecked without extending it.
            _ = tick.tick() => {
                let held = node
                    .owner_sessions
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .peek(ctx.chain.as_deref(), ctx.token.as_deref(), now_ms())
                    .is_some();
                if !held {
                    break Some(login_required());
                }
                if !s.team_exists(&team) {
                    break Some(gone(&team));
                }
            }
            _ = &mut reader => break None,
            _ = s.closed_wait() => break Some(Error::new(code::LOCKED, "keystore was locked")),
        }
    };
    reader.abort();
    if let Some(e) = end {
        let _ = out.err(&e).await;
    }
    Ok(())
}
