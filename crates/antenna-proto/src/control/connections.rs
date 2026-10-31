// SPDX-License-Identifier: Apache-2.0
//! Connections between agents (v7, `docs/CONTROL.md` §30, the agent map): an agent's **default counterpart** (where
//! its messages without an address go), whose messages it takes as tasks (D-88), the other side of a connection on
//! another own computer (an approval request there, `docs/PROTOCOL.md` §24), and who talked to whom recently. Owner
//! commands only: an agent sees its own counterpart in `session` and has no command to change it.
//!
//! A connection between two agents of this computer (`local`, §32, D-132; experimental) is a local route through the
//! daemon: both may then write to each other, under the rules of §32.

use serde::{Deserialize, Serialize};

use super::AgentInfo;

fn yes() -> bool {
    true
}

fn is_true(b: &bool) -> bool {
    *b
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// An agent's default counterpart: a contact's agent, or the contact's person when `agent` is absent; with `local`
/// (§32), an agent of this computer (`contact` is then `""`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Counterpart {
    /// Contact label; `""` for an agent of this computer.
    pub contact: String,
    /// The contact's agent (the name it announced on the link); absent: the contact's person. With `local`: the name
    /// of the agent of this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// The counterpart is an agent of this computer, over the local route (§32, D-132).
    #[serde(default, skip_serializing_if = "is_false")]
    pub local: bool,
}

/// A local route of an agent (§32, D-132; experimental): another agent of this computer the owner connected it with.
/// Both may write to each other while it exists.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalRoute {
    /// The other agent of this computer.
    pub agent: String,
    /// This agent takes that agent's messages as tasks (otherwise they are data).
    pub tasks: bool,
}

/// `agent_connect` (owner password or proof): set agent `name`'s default counterpart to `contact`'s `agent` (or its
/// person), and optionally whose messages it takes as tasks. For an own computer (trust level 5 whose node announced
/// `agent-connect/0`) with `ask`, that computer is asked for the other side: an approval request there, which its
/// owner (or this computer, through `device_decide` / `device_approve`) approves. A contact that is not an own
/// computer decides its side itself.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentConnect {
    /// Our agent.
    pub name: String,
    /// The counterpart's contact (label or link ID prefix): within the agent's links. Empty (or absent) with `local`.
    #[serde(default)]
    pub contact: String,
    /// v7 (§32, D-132; experimental): connect `name` with this other agent of this computer instead (no `contact`, no
    /// `agent`). `tasks`: `name` takes its messages as tasks; `peer_tasks`: it takes `name`'s messages as tasks; `ask`:
    /// its default counterpart becomes `name` too.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local: Option<String>,
    /// The contact's agent; absent: the contact's person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// Our agent takes the contact's messages as tasks (`true`) or as data (`false`); absent: unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tasks: Option<bool>,
    /// The other side (own computers only): its agent takes this computer's messages as tasks (`true`) or not
    /// (`false`); absent: unchanged there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_tasks: Option<bool>,
    /// Ask an own computer for the other side (default `true`).
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub ask: bool,
    /// Owner password.
    pub password: String,
}

impl std::fmt::Debug for AgentConnect {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.local {
            Some(l) => write!(f, "AgentConnect({} → {l} here)", self.name),
            None => write!(f, "AgentConnect({} → {})", self.name, self.contact),
        }
    }
}

/// `agent_disconnect` (owner session, no password: it only takes away, D-84): clear agent `name`'s default
/// counterpart when it is the line named; with `tasks: false` it also stops taking that contact's messages as tasks;
/// with `ask`, an own computer is asked to clear its side too (an approval request there).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentDisconnect {
    /// Our agent.
    pub name: String,
    /// The line to remove: this contact (label or link ID prefix) and its `agent`; absent: the agent's default
    /// counterpart. Given, it also removes a line only the other side has (an own computer's agent whose counterpart
    /// is ours).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact: Option<String>,
    /// With `contact`: the contact's agent; absent: its person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// v7 (§32, D-132): the local route between `name` and this other agent of this computer (no `contact`). It goes
    /// both ways, and so do the default counterparts along it and the messages between the two not read yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local: Option<String>,
    /// `false`: also stop taking the counterpart contact's messages as tasks; absent: unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tasks: Option<bool>,
    /// The other side (own computers only): `false` also asks that its agent stop taking this computer's messages as
    /// tasks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_tasks: Option<bool>,
    /// Ask an own computer to clear the other side (default `true`).
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub ask: bool,
}

/// `agent_traffic` (owner session): who talked to whom recently, from the stored messages.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentTrafficReq {
    /// How many days back (default 30, at most 365).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub days: Option<u32>,
}

/// `agent_connected` reply of `agent_connect` and `agent_disconnect`: our agent as it is now, and what became of the
/// other side.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentConnected {
    /// Our agent (its `session.counterpart` and `session.tasks_from` are the new state).
    pub agent: AgentInfo,
    /// The other side.
    pub other_side: OtherSide,
}

/// What became of the other side of a connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OtherSide {
    /// [`other_side`]: `requested`, `unchanged`, `contact_decides`, `person`, `not_asked`, `unsupported`,
    /// `unreachable`, `refused`.
    pub state: String,
    /// `requested`: the approval request's ID on that computer (it shows in its approvals and in My devices here).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// `unreachable`, `refused`: why, in words; `refused` also has the code.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// `refused`: the other computer's error code.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

/// [`OtherSide::state`] values.
pub mod other_side {
    /// An approval request was made on the other own computer: its owner approves it there, or here from My devices.
    pub const REQUESTED: &str = "requested";
    /// The other own computer already has exactly this: nothing to ask.
    pub const UNCHANGED: &str = "unchanged";
    /// The counterpart is a contact's agent, not an own computer's: its owner decides that side.
    pub const CONTACT_DECIDES: &str = "contact_decides";
    /// The counterpart is a person: there is no agent to set on the other side.
    pub const PERSON: &str = "person";
    /// `ask: false`.
    pub const NOT_ASKED: &str = "not_asked";
    /// The other own computer's Antenna does not know connections (no `agent-connect/0`): update it.
    pub const UNSUPPORTED: &str = "unsupported";
    /// It could not be reached now: this side is set, ask again later.
    pub const UNREACHABLE: &str = "unreachable";
    /// It refused the request (`code`, `message`): for example its agent does not see this computer.
    pub const REFUSED: &str = "refused";
    /// A local route (§32): the other agent is on this computer, and this daemon set its side too.
    pub const LOCAL: &str = "local";
}

/// `agent_traffic` reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTraffic {
    /// Since when (Unix ms).
    pub since_ms: u64,
    /// One entry per (our agent, contact, contact's agent) pair with text messages in the period, newest first.
    pub pairs: Vec<TrafficPair>,
}

/// Messages between one of our agents (or the owner) and one counterpart of a contact; with `local`, between two agents
/// of this computer (§32).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrafficPair {
    /// Our agent; `""`: the owner in person. With `local`: the first of the two by name.
    pub agent: String,
    /// Contact label; `""` with `local`.
    pub contact: String,
    /// The contact's agent; `""`: the contact's person. With `local`: the other agent of this computer.
    pub peer_agent: String,
    /// The latest message either way (Unix ms, as written or received here).
    pub last_ms: u64,
    /// Messages our side wrote to it.
    pub sent: u64,
    /// Messages it wrote to our side.
    pub received: u64,
    /// Both are agents of this computer (the local route, §32): `sent` went from `agent` to `peer_agent`.
    #[serde(default, skip_serializing_if = "is_false")]
    pub local: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{AgentRequest, Reply, Request};

    #[test]
    fn requests_parse_as_owner_commands_with_their_password_rules() {
        let r: Request = serde_json::from_str(
            r#"{"cmd":"agent_connect","name":"volna","contact":"mini","agent":"session-2","tasks":true,"peer_tasks":true,"password":"pw"}"#,
        )
        .unwrap();
        assert_eq!(r.name(), "agent_connect");
        assert_eq!(r.owner_password(), Some("pw"));
        assert!(r.accepts_proof() && r.allowed_without_session());
        let Request::AgentConnect(c) = &r else {
            panic!("{r:?}")
        };
        assert!(c.ask && c.tasks == Some(true) && c.agent.as_deref() == Some("session-2"));
        assert_eq!(format!("{r:?}"), "Request::agent_connect");
        assert!(!format!("{c:?}").contains("pw"));
        let back = serde_json::to_value(&r).unwrap();
        assert_eq!(back["cmd"], "agent_connect");
        assert!(
            back.get("ask").is_none(),
            "the default is not written: {back}"
        );

        // The person of a contact, without asking; unknown fields refused
        let p: Request = serde_json::from_str(
            r#"{"cmd":"agent_connect","name":"volna","contact":"bob","ask":false,"password":"pw"}"#,
        )
        .unwrap();
        assert!(matches!(&p, Request::AgentConnect(c) if c.agent.is_none() && !c.ask));
        assert!(
            serde_json::from_str::<Request>(
                r#"{"cmd":"agent_connect","name":"v","contact":"b","password":"pw","x":1}"#
            )
            .is_err()
        );
        // The password is required
        assert!(
            serde_json::from_str::<Request>(r#"{"cmd":"agent_connect","name":"v","contact":"b"}"#)
                .is_err()
        );

        // Disconnecting only takes away: a session, no password
        let d: Request =
            serde_json::from_str(r#"{"cmd":"agent_disconnect","name":"volna","tasks":false}"#)
                .unwrap();
        assert_eq!(d.name(), "agent_disconnect");
        assert_eq!(d.owner_password(), None);
        assert!(!d.allowed_without_session());
        let t: Request = serde_json::from_str(r#"{"cmd":"agent_traffic"}"#).unwrap();
        assert_eq!(t.name(), "agent_traffic");
        assert!(!t.allowed_without_session());

        // None of them is an agent command
        for line in [
            r#"{"cmd":"agent_connect","name":"v","contact":"b","password":"pw"}"#,
            r#"{"cmd":"agent_disconnect","name":"v"}"#,
            r#"{"cmd":"agent_traffic"}"#,
        ] {
            assert!(
                serde_json::from_str::<AgentRequest>(line).is_err(),
                "{line}"
            );
            let v: serde_json::Value = serde_json::from_str(line).unwrap();
            assert!(!AgentRequest::NAMES.contains(&v["cmd"].as_str().unwrap()));
        }
    }

    #[test]
    fn replies_and_the_session_field() {
        let line = r#"{"type":"agent_traffic","since_ms":1,"pairs":[{"agent":"volna","contact":"mini","peer_agent":"","last_ms":5,"sent":2,"received":1}]}"#;
        let r: Reply = serde_json::from_str(line).unwrap();
        assert!(matches!(&r, Reply::AgentTraffic(t) if t.pairs[0].sent == 2));
        let c = Counterpart {
            contact: "mini".into(),
            agent: None,
            local: false,
        };
        assert_eq!(serde_json::to_string(&c).unwrap(), r#"{"contact":"mini"}"#);
        let s = OtherSide {
            state: other_side::REQUESTED.into(),
            id: Some("k2".into()),
            message: None,
            code: None,
        };
        assert_eq!(
            serde_json::to_string(&s).unwrap(),
            r#"{"state":"requested","id":"k2"}"#
        );
    }

    /// The local route (§32, D-132): `local` in the owner's commands and the agent's `send`, the counterpart and the
    /// traffic pair marked local; nothing of it changes the shape of what was there before.
    #[test]
    fn the_local_route_fields() {
        let r: Request = serde_json::from_str(
            r#"{"cmd":"agent_connect","name":"volna","local":"builder","tasks":false,"peer_tasks":true,"password":"pw"}"#,
        )
        .unwrap();
        let Request::AgentConnect(c) = &r else {
            panic!("{r:?}")
        };
        assert_eq!(
            (c.contact.as_str(), c.local.as_deref()),
            ("", Some("builder"))
        );
        assert!(!format!("{c:?}").contains("pw"));
        assert_eq!(
            r.owner_password(),
            Some("pw"),
            "connecting needs the password"
        );
        let d: Request =
            serde_json::from_str(r#"{"cmd":"agent_disconnect","name":"volna","local":"builder"}"#)
                .unwrap();
        assert!(matches!(&d, Request::AgentDisconnect(x) if x.local.as_deref() == Some("builder")));
        assert_eq!(d.owner_password(), None);
        // The agent's send over the local route; still no owner command for an agent
        let s: AgentRequest =
            serde_json::from_str(r#"{"cmd":"send","local":"builder","text":"hi","wait_ms":0}"#)
                .unwrap();
        assert!(
            matches!(&s, AgentRequest::Send { local: Some(l), contact, .. } if l == "builder" && contact.is_empty())
        );
        assert!(
            serde_json::from_str::<AgentRequest>(
                r#"{"cmd":"agent_connect","name":"v","local":"b","password":"pw"}"#
            )
            .is_err()
        );
        let c = Counterpart {
            contact: String::new(),
            agent: Some("builder".into()),
            local: true,
        };
        assert_eq!(
            serde_json::to_string(&c).unwrap(),
            r#"{"contact":"","agent":"builder","local":true}"#
        );
        let p: TrafficPair = serde_json::from_str(
            r#"{"agent":"builder","contact":"","peer_agent":"volna","last_ms":5,"sent":2,"received":3,"local":true}"#,
        )
        .unwrap();
        assert!(p.local);
        let old = TrafficPair { local: false, ..p };
        assert!(!serde_json::to_string(&old).unwrap().contains("local"));
    }
}
