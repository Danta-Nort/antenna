// SPDX-License-Identifier: AGPL-3.0-only
//! Links: trust, removal, the label, rekey and history verification.

use antenna_proto::control::{Reply, Request};

use super::Owner;
use crate::client::CliResult;
use crate::{RekeyArgs, RevokeArgs, TrustArgs, VerifyArgs, confirm_level_5, not_implemented};

/// `antenna trust`.
pub(super) async fn trust(o: &Owner, a: &TrustArgs) -> CliResult<Reply> {
    if a.duration.is_some() {
        return Err(not_implemented(
            "trust --for",
            "temporary trust comes with auto-downgrade (v0.2)",
        ));
    }
    confirm_level_5(a.level, a.yes, &a.pw)?;
    o.call_pw(&a.pw, |password| Request::Trust {
        contact: a.contact.clone(),
        level: a.level,
        password,
    })
    .await
}

/// `antenna revoke`.
pub(super) async fn revoke(o: &Owner, a: &RevokeArgs) -> CliResult<Reply> {
    o.call_pw(&a.pw, |password| Request::Revoke {
        contact: a.contact.clone(),
        delete_history: a.delete_history,
        password,
    })
    .await
}

/// `antenna rename`.
pub(super) async fn rename(o: &Owner, contact: &str, label: &str) -> CliResult<Reply> {
    o.call(Request::Rename {
        contact: contact.to_string(),
        label: label.to_string(),
    })
    .await
}

/// `antenna rekey`.
pub(super) async fn rekey(o: &Owner, a: &RekeyArgs) -> CliResult<Reply> {
    o.call_pw(&a.pw, |password| Request::Rekey {
        contact: a.contact.clone(),
        code: a.code.clone(),
        password,
    })
    .await
}

/// `antenna verify`.
pub(super) async fn verify(o: &Owner, a: &VerifyArgs) -> CliResult<Reply> {
    let verify = |password: Option<String>| Request::Verify {
        contact: a.contact.clone(),
        accept: a.accept,
        repair: a.repair,
        password,
    };
    if a.accept {
        o.call_pw(&a.pw, |p| verify(Some(p))).await
    } else {
        o.call(verify(None)).await
    }
}
