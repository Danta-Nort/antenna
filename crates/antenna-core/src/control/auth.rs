// SPDX-License-Identifier: AGPL-3.0-only
//! What authorizes one owner request (SPEC §9; CONTROL §3, §22): an owner session, the password, or (v7, D-102) an
//! owner proof next to the request. Every owner request passes [`authorize`] before it runs.

use antenna_proto::control::{ClientMsg, OwnerProof, ProvenLine, Request, code};

use super::{OwnerCtx, login_required, open_tty_session, parse};
use crate::{
    crypto,
    error::{Error, Result},
    node::Node,
    owner_keys::{self, Bind},
};

/// A request that came with a proof: the proof and SHA-256 of the request's exact bytes on the line.
pub(super) struct Proven {
    proof: OwnerProof,
    hash: [u8; 32],
}

/// How a request was authorized.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Auth {
    /// No password needed (an owner session, or a command that needs none).
    Session,
    /// The owner password (checked).
    Password,
    /// An owner proof (checked).
    Proof,
}

/// An owner's line: an ordinary message, or (v7) a request with a proof, whose hash covers the request's bytes exactly
/// as they came.
pub(super) fn parse_owner_line(line: &str) -> Result<(ClientMsg, Option<Proven>)> {
    match ProvenLine::parse(line) {
        None => parse::<ClientMsg>(line).map(|m| (m, None)),
        Some(Err(e)) => Err(Error::bad_request(format!("bad message: {e}"))),
        Some(Ok(p)) => {
            let hash = crypto::sha256(&[p.req_bytes()]);
            let req: Request = parse(p.req.get())?;
            Ok((
                ClientMsg::Req(req),
                Some(Proven {
                    proof: p.proof,
                    hash,
                }),
            ))
        }
    }
}

/// Who a challenge is for: the client process, as read from the socket on connect, and its session token. A client
/// whose process cannot be identified gets no challenge (fail closed).
pub(super) fn bind(ctx: &OwnerCtx) -> Result<Bind> {
    let me = ctx.chain.as_deref().and_then(<[_]>::first).ok_or_else(|| {
        Error::new(
            code::CHALLENGE_INVALID,
            "the daemon could not identify the client process: use the password",
        )
    })?;
    Ok(Bind {
        pid: me.pid,
        start: me.start,
        session: ctx
            .token
            .as_deref()
            .map(|t| crypto::sha256(&[t.as_bytes()])),
    })
}

/// The checks every owner request passes before it runs: a proof (v7) in place of the password, the owner session
/// (Q-14b), the password on commands that change trust and links (Q-12a, SPEC §6 item 1, §9).
pub(super) async fn authorize(
    req: &Request,
    proven: Option<&Proven>,
    node: &Node,
    ctx: &OwnerCtx,
) -> Result<Auth> {
    if let Some(p) = proven {
        return authorize_proof(req, p, node, ctx).await;
    }
    if matches!(req, Request::OwnerKeyAdd { .. }) {
        return Err(Error::bad_request(
            "owner_key_add needs a proof by the key it enrolls (docs/CONTROL.md §22.3)",
        ));
    }
    // Without an owner session: only state, keys, login/logout and commands with a password (Q-14b)
    if ctx.session.is_none() && !req.allowed_without_session() {
        // First the honest key state (locked, not created), then "session required"
        node.session().await?;
        return Err(login_required());
    }
    if let Some(pw) = req.owner_password() {
        node.verify_password(pw).await?;
        // A correct password in a terminal works like sudo: the terminal session is opened (extended)
        open_tty_session(node, ctx.chain.as_deref());
        return Ok(Auth::Password);
    }
    Ok(Auth::Session)
}

/// A request with a proof (`docs/CONTROL.md` §22.2): only on the commands that take one, never next to a password,
/// and checked by the daemon. A proof stands in for the session for this one command, as the password does; it opens
/// no terminal session.
async fn authorize_proof(req: &Request, p: &Proven, node: &Node, ctx: &OwnerCtx) -> Result<Auth> {
    if let Request::OwnerKeyAdd {
        public_key,
        password,
        ..
    } = req
    {
        // The password authorizes the enrollment; the proof only shows the new key signs with this client
        let public = owner_keys::parse_public(public_key)?;
        node.verify_password(password).await?;
        node.verify_new_key(&p.proof, &p.hash, &bind(ctx)?, &public)
            .await?;
        return Ok(Auth::Password);
    }
    if !req.accepts_proof() {
        let takes_password = req.owner_password().is_some()
            || matches!(
                req,
                Request::Init { .. } | Request::Unlock { .. } | Request::UpdateAuthorize { .. }
            );
        return Err(if takes_password {
            Error::new(
                code::PASSWORD_REQUIRED,
                format!("{} takes the owner password, not a proof", req.name()),
            )
        } else {
            Error::bad_request(format!("{} takes no proof", req.name()))
        });
    }
    if req.password_given() {
        return Err(Error::bad_request(
            "send the owner password or a proof, not both",
        ));
    }
    node.verify_proof(&p.proof, &p.hash, &bind(ctx)?).await?;
    Ok(Auth::Proof)
}
