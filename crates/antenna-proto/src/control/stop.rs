// SPDX-License-Identifier: Apache-2.0
//! The owner's stop switch (v7, `docs/CONTROL.md` §33, PG-58; experimental): stop an agent and the processes it
//! started, on this computer or on an own computer over the link, and the terminal session a client started an agent
//! in. Owner commands only: an agent has none of them.

use serde::{Deserialize, Serialize};

/// `agent_terminal`: the agent runs in the terminal session that process `pid` leads, a process this client started
/// (the window's Code mode wrapper, its own child) or is (`antenna session`'s pane process). The daemon checks both and
/// keeps it in memory; a later `agent_stop` sweeps that session whole. Allowed without an owner session: it only
/// narrows what a stop takes to the client's own processes. Reply: `done` with `state: "noted"`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentTerminal {
    /// Agent name.
    pub agent: String,
    /// The session leader's PID.
    pub pid: i32,
}

/// `agent_stop`: stop the agent and the processes it started. An owner session, no password: stopping only makes
/// things safer (D-84). Reply: `agent_stopped`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentStop {
    /// Agent name.
    pub agent: String,
}

/// `device_agent_stop`: ask an own computer (a contact at level 5 both ways whose node announced `agent-stop/0`) to
/// stop one of its agents and the processes it started (`docs/PROTOCOL.md` §24). An owner session, no password.
/// Reply: `agent_stopped` with `contact`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceAgentStop {
    /// The own computer (label or link ID prefix).
    pub contact: String,
    /// Its agent, by the name its status gives.
    pub agent: String,
}

/// What a stop took (`agent_stopped`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentStopped {
    /// The agent.
    pub agent: String,
    /// The own computer that stopped it (`device_agent_stop`); absent: this one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// `terminal` (the terminal session Antenna started it in, swept whole), `process` (an agent CLI the owner started
    /// in a terminal of their own: that process and everything under it), `app` (an AI app the owner runs: not quit;
    /// the agent is disconnected, its token replaced), `resident` / `wake` (the link's wake agent: its sandbox),
    /// `worker` (a team worker: its sandbox), `local` (a local model's agent: its turn ended), `none` (nothing ran).
    pub how: String,
    /// How many processes got a signal.
    pub processes: u32,
    /// How many were still alive afterwards (normally 0).
    pub left: u32,
    /// Their distinct names (at most 16).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub names: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_shapes() {
        let r: AgentTerminal = serde_json::from_str(r#"{"agent":"helper","pid":4101}"#).unwrap();
        assert_eq!(r.pid, 4101);
        assert!(serde_json::from_str::<AgentStop>(r#"{"agent":"helper","pid":1}"#).is_err());
        let s = AgentStopped {
            agent: "helper".into(),
            contact: None,
            how: "terminal".into(),
            processes: 3,
            left: 0,
            names: vec!["claude".into(), "sleep".into()],
        };
        assert_eq!(
            serde_json::to_value(&s).unwrap(),
            serde_json::json!({"agent":"helper","how":"terminal","processes":3,"left":0,"names":["claude","sleep"]})
        );
    }
}
