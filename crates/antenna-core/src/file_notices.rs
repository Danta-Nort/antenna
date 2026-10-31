// SPDX-License-Identifier: AGPL-3.0-only
//! Files saved for an agent (v7, `docs/CONTROL.md` §14): a received file that is accepted into a link folder, and an
//! answer about a file the agent sent, reach the agent in its next `inbox` (the whole record: name, where it is, size,
//! hashes) and as a fact in `wait` (no name, no taint).
//!
//! Before this, a file the daemon accepted by itself at trust level 5 (D-99) was in the link's `shared/` folder and
//! nowhere an agent looks: `files_pending` lists only what still waits, and the agent's history left unaddressed offers
//! out. Who gets the notice is decided the way an offer's visibility is (PG-19, D-120): every agent with the link in
//! scope that may see that offer, except the agent that accepted it itself (its reply already says so). A sent file's
//! answer goes to the agent that sent it, recorded with the outgoing file (an agent's offer is signed by link-root).
//!
//! The notices live in the daemon's memory, at most [`MAX_PER_AGENT`] per agent (the oldest go first): a restart
//! loses the ones not given yet, and `files_pending` with `all` lists every saved file anyway.

use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, PoisonError};

use antenna_proto::{
    LinkId,
    control::{FileFact, FileInfo},
};

use crate::node::Session;

/// How many notices one agent keeps until it reads its inbox.
pub const MAX_PER_AGENT: usize = 64;

/// A notice: the link, its trust level when the notice was made, the file.
#[derive(Debug, Clone)]
pub(crate) struct Notice {
    pub(crate) link: LinkId,
    pub(crate) trust: u8,
    pub(crate) info: FileInfo,
}

/// Agent ID → notices not given yet.
#[derive(Debug, Default)]
pub(crate) struct FileNotices(Mutex<HashMap<i64, VecDeque<Notice>>>);

impl FileNotices {
    fn push(&self, agent_id: i64, n: Notice) {
        let mut g = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        let q = g.entry(agent_id).or_default();
        // The same file twice (an accept repeated after a restart of the pipeline): the newer record replaces it
        q.retain(|o| !(o.info.id == n.info.id && o.info.direction == n.info.direction));
        q.push_back(n);
        while q.len() > MAX_PER_AGENT {
            q.pop_front();
        }
    }
}

impl Session {
    /// A received file was accepted (`actor`: the agent's name or `owner`): every other agent that may see its offer
    /// gets the record.
    pub(crate) fn notice_saved(&self, link: &LinkId, trust: u8, info: &FileInfo, actor: &str) {
        let agents = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db.agents().unwrap_or_default()
        };
        let mut told = false;
        for a in agents {
            if a.name == actor || !a.links.as_ref().is_none_or(|ls| ls.contains(link)) {
                continue;
            }
            if !self.agent_row_sees_offer(&a, link, info.message_id.as_deref()) {
                continue;
            }
            self.file_notices.push(
                a.id,
                Notice {
                    link: *link,
                    trust,
                    info: info.clone(),
                },
            );
            told = true;
        }
        if told {
            self.inbox.send_modify(|v| *v += 1);
        }
    }

    /// The contact answered about a file the agent `agent` sent (`accept_file` / `reject_file` naming its offer): the
    /// agent gets the record with `state` (`accepted`: the contact saved it; `rejected`). A file the owner sent tells
    /// no agent; an agent removed since is not told.
    pub(crate) fn notice_answered(
        &self,
        link: &LinkId,
        agent: &str,
        mut info: FileInfo,
        state: &str,
    ) {
        let (agent, trust) = {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            let trust = db.link(link).map(|r| r.trust).unwrap_or(1);
            let Ok(agents) = db.agents() else { return };
            match agents.into_iter().find(|a| a.name == agent) {
                Some(a) => (a, trust),
                None => return,
            }
        };
        info.state = state.to_string();
        self.file_notices.push(
            agent.id,
            Notice {
                link: *link,
                trust,
                info,
            },
        );
        self.inbox.send_modify(|v| *v += 1);
    }

    /// Whether the agent has file notices waiting.
    pub(crate) fn has_file_notices(&self, agent_id: i64) -> bool {
        self.file_notices
            .0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&agent_id)
            .is_some_and(|q| !q.is_empty())
    }

    /// The agent's file notices as facts, without taking them (`wait`): no names.
    pub(crate) fn file_facts(&self, agent_id: i64) -> Vec<FileFact> {
        self.file_notices
            .0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&agent_id)
            .map(|q| {
                q.iter()
                    .map(|n| FileFact {
                        id: n.info.id.clone(),
                        contact: n.info.contact.clone(),
                        direction: n.info.direction.clone(),
                        state: n.info.state.clone(),
                        size: n.info.size,
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The agent's file notices, taken (`inbox`); the caller taints the session with their links.
    pub(crate) fn take_file_notices(&self, agent_id: i64) -> Vec<Notice> {
        self.file_notices
            .0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&agent_id)
            .map(Vec::from)
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(id: &str) -> FileInfo {
        FileInfo {
            id: id.into(),
            contact: "bob".into(),
            link_id: String::new(),
            direction: "in".into(),
            name: "a.txt".into(),
            size: 1,
            sender_mime: String::new(),
            sender_verdict: String::new(),
            state: "accepted".into(),
            verdict: None,
            mime: None,
            findings: vec![],
            sandbox: None,
            dest: None,
            saved_as: None,
            saved_path: None,
            blake3: String::new(),
            sha256: None,
            message_id: None,
            created_ms: 0,
            expires_ms: None,
            reason: None,
            withdrawal: None,
            duplicate: false,
            held: None,
            class: None,
            labels: vec![],
        }
    }

    #[test]
    fn notices_are_bounded_and_a_repeat_replaces_the_older_one() {
        let n = FileNotices::default();
        let note = |id: &str| Notice {
            link: LinkId([0; 32]),
            trust: 3,
            info: info(id),
        };
        for i in 0..(MAX_PER_AGENT + 5) {
            n.push(1, note(&format!("{i:032x}")));
        }
        n.push(1, note(&format!("{:032x}", MAX_PER_AGENT + 4)));
        let g = n.0.lock().unwrap();
        let q = &g[&1];
        assert_eq!(q.len(), MAX_PER_AGENT);
        assert_eq!(q.front().unwrap().info.id, format!("{:032x}", 5));
        assert_eq!(
            q.iter()
                .filter(|x| x.info.id == format!("{:032x}", MAX_PER_AGENT + 4))
                .count(),
            1
        );
    }
}
