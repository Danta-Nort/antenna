// SPDX-License-Identifier: AGPL-3.0-only
//! A local agent's conversation (D-104, CONTROL §24): one actor per (agent, counterpart), like a resident session
//! (D-93) without a link. The owner is the only counterpart in this release.
//!
//! - **The process** is our loop, `antenna local-agent`, in the agent sandbox (D-71, D-P-13) with no network at all:
//!   no proxy, no daemon socket, only the runtime's run folder read-only, so the runtime's socket is the one thing it
//!   can reach. It is bound to the agent like any agent's process tree (D-28), with a token nobody is shown, so a
//!   process in its tree that found the daemon socket (Landlock mode) would be this agent, never the owner.
//! - **A turn**: the owner's message is stored first (the encrypted database is the conversation's only copy); the
//!   actor takes a lease on the model's runtime (loading it, or waiting for memory), starts the loop if needed with the
//!   conversation so far (`antenna_context`), writes the turn as a stream-json user line, and streams the loop's text
//!   to the owner's connection; the reply is stored with its outcome and the runtime's numbers.
//! - **Model text is data**: control characters (but line breaks and tabs) are removed before it is stored or shown
//!   (design §6.2, R9).

use std::{
    sync::{Arc, Mutex as StdMutex, PoisonError},
    time::Duration,
};

use antenna_proto::control::{LocalAgentInfo, LocalTurn};
use tokio::sync::mpsc;

use super::OWNER;
use crate::{
    error::{Error, Result},
    node::Session,
};

/// The owner's text in one turn.
const MAX_TEXT: usize = 64 * 1024;

/// What the owner's `local_say` connection receives.
pub enum LocalOut {
    /// A piece of the reply, or an activity (`loading`, `waiting`).
    Delta {
        /// Turn number.
        turn: u64,
        /// Text.
        delta: String,
        /// What the agent waits for.
        activity: Option<String>,
    },
    /// The end of the turn.
    Done(LocalTurn),
}

#[derive(Clone)]
pub(crate) struct Handle {
    pub(super) tx: mpsc::UnboundedSender<Cmd>,
    pub(super) view: Arc<StdMutex<View>>,
}

impl Handle {
    pub(crate) fn shutdown(&self) {
        let _ = self.tx.send(Cmd::Shutdown);
    }
}

#[derive(Clone, Default)]
pub(super) struct View {
    pub(super) state: &'static str,
    pub(super) detail: String,
}

pub(super) enum Cmd {
    Say(SayReq),
    Interrupt,
    Stop,
    Reset(tokio::sync::oneshot::Sender<()>),
    Shutdown,
}

pub(super) struct SayReq {
    pub(super) text: String,
    pub(super) interrupt: bool,
    pub(super) out: mpsc::UnboundedSender<LocalOut>,
}

impl Session {
    fn local_handle(self: &Arc<Self>, agent_id: i64, counterpart: &str) -> Handle {
        let key = (agent_id, counterpart.to_string());
        let mut g = self
            .local
            .sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(h) = g.get(&key)
            && !h.tx.is_closed()
        {
            return h.clone();
        }
        let (tx, rx) = mpsc::unbounded_channel();
        let view = Arc::new(StdMutex::new(View {
            state: "sleeping",
            detail: String::new(),
        }));
        let h = Handle {
            tx,
            view: view.clone(),
        };
        g.insert(key, h.clone());
        super::actor::spawn(self.clone(), agent_id, counterpart, rx, view);
        h
    }

    /// The live state of a local agent's conversation with the owner, if its actor runs.
    pub(crate) fn local_session_state(&self, agent_id: i64) -> Option<(&'static str, String)> {
        let g = self
            .local
            .sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let h = g.get(&(agent_id, OWNER.to_string()))?;
        if h.tx.is_closed() {
            return None;
        }
        let v = h
            .view
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        Some((v.state, v.detail))
    }

    /// `local_say`: the owner's turn; the receiver gets the deltas and the end.
    pub fn local_say(
        self: &Arc<Self>,
        agent: &str,
        text: String,
        interrupt: bool,
    ) -> Result<mpsc::UnboundedReceiver<LocalOut>> {
        if text.trim().is_empty() {
            return Err(Error::bad_request("the text must be 1..65536 bytes"));
        }
        crate::node::check_text_len(text.len(), MAX_TEXT)?;
        let (id, _) = self.local_agent(agent)?;
        let (out, rx) = mpsc::unbounded_channel();
        self.local_handle(id, OWNER)
            .tx
            .send(Cmd::Say(SayReq {
                text,
                interrupt,
                out,
            }))
            .map_err(|_| Error::internal("the local agent's session has ended"))?;
        Ok(rx)
    }

    /// `local_session`: `status`, `interrupt`, `stop`, `reset`.
    pub async fn local_session(
        self: &Arc<Self>,
        agent: &str,
        action: &str,
    ) -> Result<LocalAgentInfo> {
        let (id, _) = self.local_agent(agent)?;
        let running = || {
            self.local
                .sessions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(&(id, OWNER.to_string()))
                .cloned()
        };
        match action {
            "status" => {}
            "interrupt" => {
                if let Some(h) = running() {
                    let _ = h.tx.send(Cmd::Interrupt);
                }
            }
            "stop" => {
                if let Some(h) = running() {
                    let _ = h.tx.send(Cmd::Stop);
                }
            }
            "reset" => {
                let (tx, rx) = tokio::sync::oneshot::channel();
                let _ = self.local_handle(id, OWNER).tx.send(Cmd::Reset(tx));
                let _ = tokio::time::timeout(Duration::from_secs(30), rx).await;
            }
            _ => {
                return Err(Error::bad_request(
                    "the action is one of status, interrupt, stop, reset",
                ));
            }
        }
        // Let the actor publish its new state.
        tokio::time::sleep(Duration::from_millis(20)).await;
        self.local_agent_info(id)
    }

    /// A turn of a local agent that works for a team (D-111): its own conversation, `team:<name>`, apart from the
    /// owner's. The receiver gets the deltas and the end, as for `local_say`.
    pub(crate) fn local_team_say(
        self: &Arc<Self>,
        agent_id: i64,
        team: &str,
        text: String,
    ) -> Result<mpsc::UnboundedReceiver<LocalOut>> {
        if text.trim().is_empty() {
            return Err(Error::bad_request("the text must be 1..65536 bytes"));
        }
        crate::node::check_text_len(text.len(), MAX_TEXT)?;
        let counterpart = format!("{}{team}", super::actor::TEAM_PREFIX);
        let (out, rx) = mpsc::unbounded_channel();
        self.local_handle(agent_id, &counterpart)
            .tx
            .send(Cmd::Say(SayReq {
                text,
                interrupt: false,
                out,
            }))
            .map_err(|_| Error::internal("the local agent's session has ended"))?;
        Ok(rx)
    }

    /// The state of a local agent's conversation for a team, if its actor runs; `stop` ends its process too.
    pub(crate) fn local_team_conversation(
        &self,
        agent_id: i64,
        team: &str,
        stop: bool,
    ) -> Option<&'static str> {
        let key = (agent_id, format!("{}{team}", super::actor::TEAM_PREFIX));
        let h = self
            .local
            .sessions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&key)
            .cloned()?;
        if h.tx.is_closed() {
            return None;
        }
        if stop {
            let _ = h.tx.send(Cmd::Stop);
        }
        let state = h.view.lock().unwrap_or_else(PoisonError::into_inner).state;
        Some(state)
    }

    /// The model is going away: its agents' processes stop (their conversations stay).
    pub(crate) async fn local_stop_agents_of(&self, model: &str) {
        let ids: Vec<i64> = self
            .local_agent_infos()
            .unwrap_or_default()
            .into_iter()
            .filter(|a| a.model == model)
            .filter_map(|a| self.local_agent(&a.name).ok().map(|(id, _)| id))
            .collect();
        let hs: Vec<Handle> = {
            let g = self
                .local
                .sessions
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            g.iter()
                .filter(|(k, _)| ids.contains(&k.0))
                .map(|(_, h)| h.clone())
                .collect()
        };
        for h in hs {
            let _ = h.tx.send(Cmd::Stop);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    /// Send the states of the agents on a model (its file came or went).
    pub(crate) fn publish_local_agents_of(&self, model: &str) {
        for a in self.local_agent_infos().unwrap_or_default() {
            if a.model == model {
                self.emit_local_agent(a);
            }
        }
    }
}
