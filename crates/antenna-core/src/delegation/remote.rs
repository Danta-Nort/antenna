// SPDX-License-Identifier: AGPL-3.0-only
//! The check of an approver agent's answer from another own computer (`docs/PROTOCOL.md` §24, PG-57), as a function
//! of what the session knows, so that every refusal is unit-tested with real keys: the text and the link it names, the
//! one-time challenge for that request (taken whatever follows), the delegation's key, that key still announced and
//! not revoked, the Ed25519 signature over [`device::agent_decision_message`]. The scope and the circle come after
//! (`rules`), as for an approver on this computer.

use antenna_proto::{
    LinkId,
    control::code,
    device::{self, AgentDecision, AgentDecisionText},
};
use data_encoding::HEXLOWER;

use crate::{
    error::{Error, Result},
    history,
};

/// What the asking computer knows about an answer's signer.
pub(crate) struct Known<'a> {
    /// Takes the challenge `(nonce, request id)` on this link: once, whatever follows.
    pub(crate) take: &'a dyn Fn(&[u8; 32], &str) -> Result<()>,
    /// The key the owner named for that computer's agent of this name, if the owner named it.
    pub(crate) named: &'a dyn Fn(&str) -> Option<[u8; 32]>,
    /// Whether that computer still announces this key under this name, unrevoked (PROTOCOL §21).
    pub(crate) active: &'a dyn Fn(&[u8; 32], &str) -> bool,
}

/// Checks answer `d` that came over `link`; the signed text and the agent's key on success.
pub(crate) fn verify(
    link: &LinkId,
    d: &AgentDecision,
    k: &Known<'_>,
) -> Result<(AgentDecisionText, [u8; 32])> {
    d.check()
        .map_err(|f| Error::bad_request(format!("agent decision: bad {f}")))?;
    let text = AgentDecisionText::parse(&d.request)
        .map_err(|e| Error::bad_request(format!("agent decision: {e}")))?;
    if text.link != link.to_hex() {
        return Err(Error::bad_request(
            "the signed answer names another link: it was made for another computer",
        ));
    }
    // Taken by this attempt whatever follows: a replay finds it gone
    (k.take)(&d.nonce, &text.id)?;
    let key: [u8; 32] = HEXLOWER
        .decode(text.key.as_bytes())
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| Error::bad_request("agent decision: key"))?;
    let Some(named) = (k.named)(&text.agent) else {
        return Err(Error::new(
            code::FORBIDDEN,
            "the owner of this computer has not made that agent an approver",
        ));
    };
    if !crate::crypto::ct_eq(&named, &key) {
        return Err(Error::new(
            code::OWNER_KEY_UNKNOWN,
            "that agent's key is not the one the owner named here: the owner names it again",
        ));
    }
    if !(k.active)(&key, &text.agent) {
        return Err(Error::new(
            code::OWNER_KEY_UNKNOWN,
            "that agent's key was revoked on this link",
        ));
    }
    let msg =
        device::agent_decision_message(&d.nonce, &crate::crypto::sha256(&[d.request.as_bytes()]));
    if !history::verify(&key, &msg, &d.sig) {
        return Err(Error::new(
            code::PROOF_INVALID,
            "the answer's signature does not verify with that agent's key",
        ));
    }
    Ok((text, key))
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;
    use crate::delegation::Challenges;

    const LINK: LinkId = LinkId([7; 32]);

    fn seed(b: u8) -> crate::crypto::Secret32 {
        zeroize::Zeroizing::new([b; 32])
    }

    fn public(b: u8) -> [u8; 32] {
        ed25519_dalek::SigningKey::from_bytes(&[b; 32])
            .verifying_key()
            .to_bytes()
    }

    fn text(id: &str, decision: &str, key: &[u8; 32], link: &LinkId) -> String {
        AgentDecisionText {
            cmd: AgentDecisionText::CMD.into(),
            link: link.to_hex(),
            id: id.into(),
            fingerprint: "9c41e07a3b5d0f12".into(),
            decision: decision.into(),
            agent: "volna".into(),
            key: HEXLOWER.encode(key),
            reason: "the build report for the server".into(),
            clean: true,
        }
        .to_text()
    }

    /// What the approver's computer sends: the text signed by the agent's key over the challenge.
    fn signed(signer: u8, nonce: [u8; 32], request: String) -> AgentDecision {
        let msg =
            device::agent_decision_message(&nonce, &crate::crypto::sha256(&[request.as_bytes()]));
        AgentDecision {
            sig: history::sign(&seed(signer), &msg).to_vec(),
            request,
            nonce,
        }
    }

    struct World {
        ch: RefCell<Challenges>,
        named: Option<[u8; 32]>,
        revoked: bool,
    }

    impl World {
        fn new() -> Self {
            Self {
                ch: RefCell::new(Challenges::default()),
                named: Some(public(1)),
                revoked: false,
            }
        }

        fn issue(&self, id: &str) -> [u8; 32] {
            self.ch.borrow_mut().issue(LINK, id, 1000, 60_000).0
        }

        fn check(&self, d: &AgentDecision) -> Result<(AgentDecisionText, [u8; 32])> {
            let take = |n: &[u8; 32], id: &str| self.ch.borrow_mut().take(&LINK, n, id, 1001);
            let named = |_: &str| self.named;
            let active = |_: &[u8; 32], _: &str| !self.revoked;
            verify(
                &LINK,
                d,
                &Known {
                    take: &take,
                    named: &named,
                    active: &active,
                },
            )
        }
    }

    fn code_of(r: Result<(AgentDecisionText, [u8; 32])>) -> &'static str {
        r.err().map_or("ok", |e| e.code)
    }

    /// The answer verifies once; its replay finds the challenge used; a challenge of another request, a signature by
    /// another key (a forged sender), a key the owner did not name, a revoked key, an answer made for another link and
    /// an owner proof's message are each refused.
    #[test]
    fn an_answer_verifies_once_and_only_from_the_named_key() {
        let w = World::new();
        let n = w.issue("k2");
        let d = signed(1, n, text("k2", "approve", &public(1), &LINK));
        let (t, key) = w.check(&d).unwrap();
        assert_eq!((t.id.as_str(), key), ("k2", public(1)));
        assert_eq!(code_of(w.check(&d)), code::CHALLENGE_INVALID, "a replay");

        // A challenge issued for another request
        let n = w.issue("k3");
        let d = signed(1, n, text("k2", "approve", &public(1), &LINK));
        assert_eq!(code_of(w.check(&d)), code::CHALLENGE_INVALID);

        // Another agent signs and claims the named agent's key: the signature does not hold
        let n = w.issue("k2");
        let d = signed(2, n, text("k2", "approve", &public(1), &LINK));
        assert_eq!(code_of(w.check(&d)), code::PROOF_INVALID, "a forged sender");

        // Another agent with its own key: not the one the owner named
        let n = w.issue("k2");
        let d = signed(2, n, text("k2", "approve", &public(2), &LINK));
        assert_eq!(code_of(w.check(&d)), code::OWNER_KEY_UNKNOWN);

        // The text changed after signing (deny made into approve)
        let n = w.issue("k2");
        let mut d = signed(1, n, text("k2", "deny", &public(1), &LINK));
        d.request = text("k2", "approve", &public(1), &LINK);
        assert_eq!(code_of(w.check(&d)), code::PROOF_INVALID);

        // Made for another link (relayed from another computer)
        let n = w.issue("k2");
        let d = signed(1, n, text("k2", "approve", &public(1), &LinkId([8; 32])));
        assert_eq!(code_of(w.check(&d)), code::BAD_REQUEST);

        // An owner proof's message signed by the same key is not an answer
        let n = w.issue("k2");
        let request = text("k2", "approve", &public(1), &LINK);
        let owner = antenna_proto::control::owner_keys::proof_message(
            &n,
            &crate::crypto::sha256(&[request.as_bytes()]),
        );
        let d = AgentDecision {
            sig: history::sign(&seed(1), &owner).to_vec(),
            request,
            nonce: n,
        };
        assert_eq!(code_of(w.check(&d)), code::PROOF_INVALID);

        // Not named, revoked
        let w2 = World {
            named: None,
            ..World::new()
        };
        let n = w2.issue("k2");
        assert_eq!(
            code_of(w2.check(&signed(1, n, text("k2", "approve", &public(1), &LINK)))),
            code::FORBIDDEN
        );
        let w3 = World {
            revoked: true,
            ..World::new()
        };
        let n = w3.issue("k2");
        assert_eq!(
            code_of(w3.check(&signed(1, n, text("k2", "approve", &public(1), &LINK)))),
            code::OWNER_KEY_UNKNOWN
        );
    }
}
