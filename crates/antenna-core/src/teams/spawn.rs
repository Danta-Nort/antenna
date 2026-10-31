// SPDX-License-Identifier: AGPL-3.0-only
//! Workers of a team (D-111): filling a slot of the budget and stopping a worker. A spawn is checked against the
//! budget, the team's and this machine's limits ([`super::rules::choose_slot`]), and the worker starts with the lead's
//! taint: its rights are the template's, the lead's ceiling and this machine's, whichever is lowest.

use std::sync::PoisonError;

use antenna_proto::control::code;

use super::{Actor, MemberRow, MemberSpec, TeamRow, db, rules, valid_role};
use crate::{
    error::{Error, Result},
    node::Session,
    now_ms,
};

impl Session {
    /// Why a slot's kind cannot start a worker on this machine now, if it cannot.
    pub(super) fn slot_unavailable(
        &self,
        team: &TeamRow,
        slot: &antenna_proto::control::TeamSlot,
    ) -> Option<String> {
        if self.wake_support().kind.is_none() {
            return Some("this computer has no sandbox for agents".into());
        }
        match slot.kind.as_str() {
            "claude" | "program" => {
                let prog = slot.argv.first().map_or("claude", String::as_str);
                crate::wake::resolve_program(prog).err().map(|e| e.message)
            }
            "codex" => Some(
                "Codex workers need the Codex app-server adapter of D-93, which is not built yet"
                    .into(),
            ),
            "local" => {
                let model = slot.model.as_deref()?;
                if let Err(e) = self.runtime_ready() {
                    return Some(format!(
                        "the local model runtime is not available: {}",
                        e.message
                    ));
                }
                match self.model_info(model) {
                    Ok(m) if m.state == "ready" => None,
                    Ok(m) => Some(format!("the model {model} is {} on this computer", m.state)),
                    Err(e) => Some(e.message),
                }
            }
            k => Some(format!("unknown worker kind {k:?}")),
        }
        .filter(|_| team.state == "active")
    }

    /// Fill a slot (the lead's `worker_spawn`, the owner's `team_add_worker`). The worker starts with the lead's
    /// taint: its rights are the template's, the lead's ceiling and this machine's, whichever is lowest.
    pub(super) fn worker_spawn_as(
        &self,
        team: &TeamRow,
        by: &Actor,
        role: &str,
        kind: Option<&str>,
    ) -> Result<MemberRow> {
        valid_role(role)?;
        Self::require_active(team)?;
        let members = self.load_members(team)?;
        let active: Vec<&MemberRow> = members.iter().filter(|m| m.state != "stopped").collect();
        let facts: Vec<rules::SlotFacts> = team
            .cfg
            .slots
            .iter()
            .enumerate()
            .map(|(i, s)| rules::SlotFacts {
                used: active.iter().filter(|m| m.spec.slot == i).count() as u32,
                unavailable: self.slot_unavailable(team, s),
            })
            .collect();
        let machine_workers =
            db::active_workers(&self.db.lock().unwrap_or_else(PoisonError::into_inner))?;
        let i = rules::choose_slot(
            &team.cfg.slots,
            role,
            kind,
            &facts,
            &rules::Limits {
                team_workers: active.len() as u32,
                max_workers: team.cfg.max_workers,
                machine_workers,
                machine: rules::THIS_COMPUTER,
                local_only: team.cfg.template.local_only,
            },
        )
        .map_err(|why| Error::new(code::NO_CAPACITY, why))?;
        let slot = team.cfg.slots[i].clone();
        let (lead_carried, lead_ceiling) = match by {
            Actor::Agent { id, .. } => {
                let c = self.carried_now(*id)?;
                let ceiling = self.ceiling_of(&c);
                (c, ceiling)
            }
            _ => (Vec::new(), None),
        };
        let grant = rules::grant(&team.cfg.template, lead_ceiling, &rules::THIS_COMPUTER);
        let name = self.next_worker_name(team, role)?;
        let (argv, hosts, home_files) = match slot.kind.as_str() {
            "local" => (Vec::new(), Vec::new(), Vec::new()),
            _ => {
                let mut argv = if slot.argv.is_empty() {
                    vec!["claude".to_string()]
                } else {
                    slot.argv.clone()
                };
                argv[0] = crate::wake::resolve_program(&argv[0])?
                    .to_string_lossy()
                    .into_owned();
                let mut hosts = crate::wake::default_hosts(&argv[0]);
                for h in &slot.hosts {
                    if !hosts.contains(h) {
                        hosts.push(h.clone());
                    }
                }
                let home_files: Vec<String> = crate::wake::default_home_files(&argv[0])
                    .into_iter()
                    .filter(|f| crate::wake::owner_home().is_some_and(|h| h.join(f).is_file()))
                    .collect();
                (argv, hosts, home_files)
            }
        };
        let agent_id = if slot.kind == "local" {
            let model = slot
                .model
                .clone()
                .ok_or_else(|| Error::internal("a local slot without a model"))?;
            self.local_agent_add(&name, &model)?;
            self.local_agent(&name)?.0
        } else {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            // The token nobody holds: the daemon makes a new one at every start of the worker's process.
            db.agent_insert(
                &name,
                &crate::agents::token_hash(&crate::agents::new_token()),
                Some(&[]),
                0,
                false,
                now_ms(),
            )?
        };
        let m = MemberRow {
            agent_id,
            team_id: team.id,
            name: name.clone(),
            role: role.into(),
            kind: slot.kind.clone(),
            spec: MemberSpec {
                slot: i,
                argv,
                hosts,
                home_files,
                model: slot.model.clone(),
                commands: grant.commands,
                turn_secs: grant.turn_secs,
                ..Default::default()
            },
            spawned_by: by.name().into(),
            state: "active".into(),
            created_ms: now_ms(),
        };
        let inserted =
            db::member_insert(&self.db.lock().unwrap_or_else(PoisonError::into_inner), &m);
        if let Err(e) = inserted {
            let _ = self
                .db
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .agent_remove(agent_id);
            return Err(e);
        }
        // The worker starts with the lead's taint (its ceiling at spawn time).
        self.carry_into(agent_id, &lead_carried)?;
        self.team_log(
            team.id,
            &db::Entry {
                actor: by.name(),
                action: "worker_spawn",
                task: None,
                decision: "done",
                detail: &format!(
                    "{name}: {role}/{} (commands {}, ceiling {})",
                    slot.kind,
                    if grant.commands { "on" } else { "off" },
                    lead_ceiling.map_or("none".to_string(), |c| c.to_string())
                ),
            },
        );
        self.emit_agent(&name, "added");
        // A new worker has no process yet.
        self.note_worker_state(agent_id, "sleeping");
        self.worker_event(&team.name, &name, "sleeping", by.name());
        Ok(m)
    }

    /// `<team>.<role>-<n>` with the first free `n`.
    fn next_worker_name(&self, team: &TeamRow, role: &str) -> Result<String> {
        let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
        for n in 1..1000 {
            let name = format!("{}.{role}-{n}", team.name);
            if db.agent_by_name(&name).is_err() {
                crate::agents::valid_name(&name)?;
                return Ok(name);
            }
        }
        Err(Error::new(code::NO_CAPACITY, "no free worker name"))
    }

    /// Stop a worker: its process ends, its token stops working, its folder stays (the lead's `worker_stop`, the
    /// owner's `team_stop`).
    pub(super) async fn worker_stop_as(
        &self,
        team: &TeamRow,
        by: &Actor,
        name: &str,
    ) -> Result<MemberRow> {
        let mut m = self
            .load_members(team)?
            .into_iter()
            .find(|m| m.name == name)
            .ok_or_else(|| {
                Error::new(code::NOT_FOUND, format!("no worker {name:?} in this team"))
            })?;
        self.worker_shutdown(m.agent_id);
        if m.kind == "local" {
            self.local_team_stop(m.agent_id, team);
        }
        {
            let db = self.db.lock().unwrap_or_else(PoisonError::into_inner);
            db.agent_set_token(
                m.agent_id,
                &crate::agents::token_hash(&crate::agents::new_token()),
            )?;
            let _ = db.agent_set_anchor(m.agent_id, None);
        }
        m.state = "stopped".into();
        m.spec.detail = format!("stopped by {}", by.name());
        self.save_member(&m)?;
        self.team_log(
            team.id,
            &db::Entry {
                actor: by.name(),
                action: "worker_stop",
                task: None,
                decision: "done",
                detail: name,
            },
        );
        self.note_worker_state(m.agent_id, "stopped");
        self.worker_event(&team.name, name, "stopped", by.name());
        Ok(m)
    }
}
