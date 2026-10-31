// SPDX-License-Identifier: AGPL-3.0-only
//! Addressing and topics (`docs/PROTOCOL.md` §23, `docs/CONTROL.md` §20, DECISIONS D-90…D-92).
//!
//! A message names who it is for: the other side's person (its owner), one of its agents by the name that agent
//! announced (§21), or everyone; and it may belong to a topic. Both are fields of the signed `envelope-core`, sent
//! only to a node with the feature `addr/0`. Topics are local organization carried in the signed message, not a
//! separate cryptographic channel.
//!
//! The daemon decides what an agent reads ([`visible`]): the agent never gets a message addressed to another agent or
//! to the person (except the link's wake agent, which answers the contact for the owner).

use antenna_proto::{LinkId, To, Topic};

use crate::{
    error::{Error, Result},
    store::Db,
};

/// The address and topic of a message being sent, resolved.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Addr {
    /// Who it is for; `None`: no address (files, receipts, announcements).
    pub to: Option<To>,
    /// The topic.
    pub topic: Option<Topic>,
    /// The owner's "interrupt now" (PG-58): only on the owner's text to one agent of an own computer; in `core` only for
    /// a node with `urgent/0`.
    pub urgent: bool,
}

/// The addressing fields of a `send` / `send_stream` request, as the client gave them (`docs/CONTROL.md` §20).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AddrReq {
    /// `person` / `everyone` / `agent`.
    pub to: Option<String>,
    /// With `to: "agent"`: the contact's agent.
    pub to_agent: Option<String>,
    /// A topic title (`""`: no topic).
    pub topic: Option<String>,
    /// A topic ID (32 hex).
    pub topic_id: Option<String>,
    /// v7 (`docs/CONTROL.md` §32, D-132): an agent of this computer, over the local route, instead of a contact.
    pub local: Option<String>,
}

impl AddrReq {
    /// From the four request fields.
    pub fn new(
        to: Option<String>,
        to_agent: Option<String>,
        topic: Option<String>,
        topic_id: Option<String>,
    ) -> Self {
        Self {
            to,
            to_agent,
            topic,
            topic_id,
            local: None,
        }
    }

    /// With the agent `send`'s `local` (D-132).
    pub fn local(mut self, local: Option<String>) -> Self {
        self.local = local;
        self
    }

    /// The address the client asked for: `None` if it gave none (the default applies).
    pub fn parse_to(&self) -> Result<Option<To>> {
        match (self.to.as_deref(), self.to_agent.as_deref()) {
            (None, None) => Ok(None),
            // `to_agent` alone means an agent
            (None | Some("agent"), Some(a)) => To::from_parts("agent", Some(a))
                .map(Some)
                .ok_or_else(|| Error::bad_request("to_agent: 1–64 characters of [A-Za-z0-9._-]")),
            (Some("agent"), None) => Err(Error::bad_request("to: \"agent\" needs to_agent")),
            (Some(k @ ("person" | "everyone")), None) => Ok(To::from_parts(k, None)),
            (Some("person" | "everyone"), Some(_)) => {
                Err(Error::bad_request("to_agent goes only with to: \"agent\""))
            }
            (Some(other), _) => Err(Error::bad_request(format!(
                "to: {other:?} (person, everyone or agent)"
            ))),
        }
    }

    /// The topic the client asked for: `None` if it said nothing (a reply inherits), `Some(None)` for "no topic".
    /// A title continues the link's topic with exactly that title or starts a new one; an ID must exist.
    pub fn resolve_topic(&self, db: &Db, link: &LinkId) -> Result<Option<Option<Topic>>> {
        if let Some(hex) = self.topic_id.as_deref() {
            let id = data_encoding::HEXLOWER_PERMISSIVE
                .decode(hex.as_bytes())
                .ok()
                .and_then(|v| <[u8; 16]>::try_from(v).ok())
                .ok_or_else(|| Error::bad_request("topic_id: 32 hex characters"))?;
            let title = db.topic_title(link, &id)?.ok_or_else(|| {
                Error::new(
                    antenna_proto::control::code::NOT_FOUND,
                    "no such topic on this link",
                )
            })?;
            return Ok(Some(Some(Topic { id, title })));
        }
        match self.topic.as_deref() {
            None => Ok(None),
            Some("") => Ok(Some(None)),
            Some(t) => {
                if !Topic::valid_title(t) {
                    return Err(Error::bad_request(
                        "topic: 1–120 bytes, no control characters",
                    ));
                }
                let id = match db.topic_by_title(link, t)? {
                    Some(id) => id,
                    None => crate::crypto::random::<16>(),
                };
                Ok(Some(Some(Topic {
                    id,
                    title: t.to_string(),
                })))
            }
        }
    }
}

/// Who reads what on one link, for one agent (`docs/CONTROL.md` §20 "What an agent can read").
#[derive(Debug, Clone)]
pub struct Reader<'a> {
    /// The agent's name in this link, as the contact sees it (`wake` for the link's default wake agent).
    pub public_name: &'a str,
    /// The owner allows it messages to everyone (and unaddressed ones).
    pub everyone: bool,
    /// It is this link's wake agent: it answers the contact for the owner.
    pub wake: bool,
}

/// Whether an incoming message with address `to` (read from its signed `core`) is visible to the agent.
pub fn visible(r: &Reader<'_>, to: Option<&To>) -> bool {
    match to {
        Some(To::Agent(name)) => name == r.public_name,
        Some(To::Everyone) | None => r.everyone,
        Some(To::Person) => r.wake,
    }
}

/// Whether one of this node's agents answers to `name` on `link` (PROTOCOL §23, `no-agent/0`): it has the link in its
/// scope and the contact sees it under that name (the link's wake agent with the default name as `wake`, §21). The
/// visibility rule (CONTROL §20) gives a message addressed by name exactly to such an agent.
pub(crate) fn agent_here(db: &Db, link: &LinkId, name: &str) -> Result<bool> {
    let wake = db.wake_rule(link)?.map(|(id, _, _)| id);
    Ok(db.agents()?.into_iter().any(|a| {
        let in_scope = a.links.as_ref().is_none_or(|ls| ls.contains(link));
        let public = if wake == Some(a.id) && a.name.starts_with("wake-") {
            "wake"
        } else {
            a.name.as_str()
        };
        in_scope && public == name
    }))
}

/// The address of a file offer from a request's `to` / `to_agent` (PG-19): none unless the client gave one (an
/// unaddressed offer is seen by every agent with the link, as before); never a topic.
pub fn file_addr(to: Option<String>, to_agent: Option<String>) -> Result<Addr> {
    Ok(Addr {
        urgent: false,
        to: AddrReq::new(to, to_agent, None, None).parse_to()?,
        topic: None,
    })
}

/// The text form of an address for the control protocol: `(to, to_agent)`.
pub fn to_view(to: Option<&To>) -> (Option<String>, Option<String>) {
    match to {
        None => (None, None),
        Some(t) => (Some(t.kind().into()), t.agent().map(str::to_string)),
    }
}

/// A topic for the control protocol.
pub fn topic_view(t: Option<&Topic>) -> Option<antenna_proto::control::TopicView> {
    t.map(|t| antenna_proto::control::TopicView {
        id: t.id_hex(),
        title: t.title.clone(),
    })
}

/// A stored `(kind, agent)` address → [`To`] (a malformed row reads as no address).
pub fn to_from_row(row: Option<&(String, Option<String>)>) -> Option<To> {
    row.and_then(|(k, a)| To::from_parts(k, a.as_deref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reader(everyone: bool, wake: bool) -> Reader<'static> {
        Reader {
            public_name: "builder",
            everyone,
            wake,
        }
    }

    #[test]
    fn the_visibility_rule() {
        let me = To::Agent("builder".into());
        let other = To::Agent("chatgpt".into());
        for everyone in [false, true] {
            for wake in [false, true] {
                let r = reader(everyone, wake);
                assert!(visible(&r, Some(&me)), "addressed to it");
                assert!(!visible(&r, Some(&other)), "never another agent's");
                assert_eq!(visible(&r, Some(&To::Everyone)), everyone);
                assert_eq!(
                    visible(&r, None),
                    everyone,
                    "unaddressed counts as everyone"
                );
                assert_eq!(
                    visible(&r, Some(&To::Person)),
                    wake,
                    "the person's only for the wake agent"
                );
            }
        }
        // The name is compared exactly
        assert!(!visible(
            &reader(true, true),
            Some(&To::Agent("Builder".into()))
        ));
    }

    #[test]
    fn request_fields() {
        let a = |to: Option<&str>, ag: Option<&str>| {
            AddrReq::new(to.map(Into::into), ag.map(Into::into), None, None).parse_to()
        };
        assert_eq!(a(None, None).unwrap(), None);
        assert_eq!(a(Some("person"), None).unwrap(), Some(To::Person));
        assert_eq!(a(Some("everyone"), None).unwrap(), Some(To::Everyone));
        assert_eq!(
            a(Some("agent"), Some("lead")).unwrap(),
            Some(To::Agent("lead".into()))
        );
        assert_eq!(
            a(None, Some("lead")).unwrap(),
            Some(To::Agent("lead".into()))
        );
        for (to, ag) in [
            (Some("agent"), None),
            (Some("person"), Some("lead")),
            (Some("nobody"), None),
            (Some("agent"), Some("a b")),
            (None, Some("owner")),
        ] {
            assert!(a(to, ag).is_err(), "{to:?} {ag:?}");
        }
    }
}
