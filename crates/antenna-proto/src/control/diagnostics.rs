// SPDX-License-Identifier: Apache-2.0
//! Facts for the doctor (D-96, `docs/LOCAL-ASSISTANT.md` §4) carried in existing owner replies: the home relay of a
//! link's endpoint in `contacts` ([`super::TransportInfo::relay`]) and the last refused MCP host in `agent_list`
//! (`refused_*` in [`super::SessionInfo`]). Both are optional fields an older client ignores (preview.6).

use serde::{Deserialize, Serialize};

/// A link endpoint's home relay as iroh reports it (preview.6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HomeRelayInfo {
    /// The relay's URL; empty while the endpoint has not chosen a home relay yet (it chooses one once a relay has
    /// answered, and keeps it while the relay is unreachable).
    pub url: String,
    /// Whether the endpoint is connected to that relay now.
    pub connected: bool,
    /// The most recent connection error, as text (at most 200 characters, control characters removed); only when not
    /// connected, and absent until a connection attempt has failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{AgentInfo, SessionInfo, TransportInfo};

    /// `transport` of a preview.5 daemon: no `relay`.
    const TRANSPORT_PREVIEW5: &str = r#"{"pairing_kx_group":"X25519MLKEM768","last_kx_group":"X25519MLKEM768",
        "connected":true,"last_paths":["relay:https://relay.example/"]}"#;

    /// An `agent_list` entry of a preview.5 daemon: no `refused_*`.
    const AGENT_PREVIEW5: &str = r#"{"name":"claude","created_ms":1,"everyone":false,"session":{"agent":"claude",
        "started_ms":1,"ceiling":null,"tainted_by":[],"read_links":[],"local_level":0,"baseline_level":0,
        "declared":[],"links":null,"bound_to":"4242 claude","bound_pid":4242,"bound_comm":"claude",
        "bound_alive":true,"mcp_processes":2,"tasks_from":[],"tasks_from_default":true}}"#;

    #[test]
    fn replies_of_an_older_daemon_still_parse() {
        let t: TransportInfo = serde_json::from_str(TRANSPORT_PREVIEW5).unwrap();
        assert_eq!(t.relay, None);
        assert!(t.connected);
        let a: AgentInfo = serde_json::from_str(AGENT_PREVIEW5).unwrap();
        let s = &a.session;
        assert_eq!(
            (
                s.refused_pid,
                &s.refused_comm,
                s.refused_ms,
                s.refused_alive
            ),
            (None, &None, None, None)
        );
        assert_eq!(s.mcp_processes, Some(2));
    }

    #[test]
    fn absent_facts_are_not_serialized() {
        let t: TransportInfo = serde_json::from_str(TRANSPORT_PREVIEW5).unwrap();
        let line = serde_json::to_string(&t).unwrap();
        assert!(!line.contains("relay\":"), "{line}");
        let a: AgentInfo = serde_json::from_str(AGENT_PREVIEW5).unwrap();
        let line = serde_json::to_string(&a).unwrap();
        assert!(!line.contains("refused"), "{line}");
        // A connected relay has no error, and the error is left out rather than written as null.
        let r = HomeRelayInfo {
            url: "https://relay.example/".into(),
            connected: true,
            error: None,
        };
        assert_eq!(
            serde_json::to_string(&r).unwrap(),
            r#"{"url":"https://relay.example/","connected":true}"#
        );
    }

    #[test]
    fn the_new_facts_round_trip() {
        let mut t: TransportInfo = serde_json::from_str(TRANSPORT_PREVIEW5).unwrap();
        t.connected = false;
        t.relay = Some(HomeRelayInfo {
            url: "https://relay.example/".into(),
            connected: false,
            error: Some("Connection refused (os error 111)".into()),
        });
        let v = serde_json::to_value(&t).unwrap();
        assert_eq!(v["relay"]["url"], "https://relay.example/");
        assert_eq!(v["relay"]["connected"], false);
        assert_eq!(v["relay"]["error"], "Connection refused (os error 111)");
        assert_eq!(serde_json::from_value::<TransportInfo>(v).unwrap(), t);

        let mut s: SessionInfo = serde_json::from_str::<AgentInfo>(AGENT_PREVIEW5)
            .unwrap()
            .session;
        s.refused_pid = Some(5151);
        s.refused_comm = Some("Code Helper".into());
        s.refused_ms = Some(1_790_000_000_000);
        s.refused_alive = Some(true);
        let v = serde_json::to_value(&s).unwrap();
        assert_eq!(v["refused_pid"], 5151);
        assert_eq!(v["refused_comm"], "Code Helper");
        assert_eq!(v["refused_ms"], 1_790_000_000_000u64);
        assert_eq!(v["refused_alive"], true);
        assert_eq!(serde_json::from_value::<SessionInfo>(v).unwrap(), s);
    }
}
