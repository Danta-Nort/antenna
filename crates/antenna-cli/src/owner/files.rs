// SPDX-License-Identifier: AGPL-3.0-only
//! Files: sending, requesting, and the quarantine (SPEC §10).

use std::path::PathBuf;

use antenna_proto::control::{Reply, Request};

use super::Owner;
use crate::client::CliResult;
use crate::{FileAcceptArgs, ShareArgs, absolute_path, save_preview_images};

/// `antenna share`.
pub(super) async fn share(o: &Owner, a: &ShareArgs) -> CliResult<Reply> {
    o.call(Request::ShareFile {
        contact: a.contact.clone(),
        path: absolute_path(&a.file)?,
        name: a.name.clone(),
        approval_id: a.approval.clone(),
        to: a.to.clone(),
        to_agent: a.to_agent.clone(),
    })
    .await
}

/// `antenna request`.
pub(super) async fn request(o: &Owner, contact: &str, path: &str) -> CliResult<Reply> {
    o.call(Request::RequestFile {
        contact: contact.to_string(),
        path: path.to_string(),
    })
    .await
}

/// `antenna files pending`.
pub(super) async fn pending(o: &Owner, contact: &Option<String>, all: bool) -> CliResult<Reply> {
    o.call(Request::FilesPending {
        contact: contact.clone(),
        all,
    })
    .await
}

/// `antenna files preview`.
pub(super) async fn preview(o: &Owner, id: &str, images: &Option<PathBuf>) -> CliResult<Reply> {
    let r = o.call(Request::FilePreview { id: id.to_string() }).await?;
    save_preview_images(&r, images.as_deref())?;
    Ok(r)
}

/// `antenna files accept`.
pub(super) async fn accept(o: &Owner, a: &FileAcceptArgs) -> CliResult<Reply> {
    let accept = |password: Option<String>| Request::FileAccept {
        id: a.id.clone(),
        name: a.name.clone(),
        force: a.force,
        allow_special: a.allow_special,
        approval_id: None,
        password,
    };
    if a.force {
        o.call_pw(&a.pw, |p| accept(Some(p))).await
    } else {
        o.call(accept(None)).await
    }
}

/// `antenna files reject`.
pub(super) async fn reject(o: &Owner, id: &str) -> CliResult<Reply> {
    o.call(Request::FileReject { id: id.to_string() }).await
}

/// `antenna files withdraw`.
pub(super) async fn withdraw(o: &Owner, id: &str) -> CliResult<Reply> {
    o.call(Request::FileWithdraw { id: id.to_string() }).await
}

/// `antenna files allow` (D-130): the password every time.
pub(super) async fn allow(
    o: &Owner,
    contact: &str,
    entries: &[String],
    pw: &crate::Pw,
) -> CliResult<Reply> {
    o.call_pw(pw, |password| Request::FileAllow {
        contact: contact.to_string(),
        entries: entries.to_vec(),
        password,
    })
    .await
}

/// `antenna files disallow` (D-130): no password.
pub(super) async fn disallow(o: &Owner, contact: &str, entries: &[String]) -> CliResult<Reply> {
    o.call(Request::FileDisallow {
        contact: contact.to_string(),
        entries: entries.to_vec(),
    })
    .await
}

/// `antenna files save-to` (D-130): setting a folder takes the password, `--clear` none.
pub(super) async fn save_to(
    o: &Owner,
    contact: &str,
    folder: Option<&str>,
    agent: &Option<String>,
    clear: bool,
    pw: &crate::Pw,
) -> CliResult<Reply> {
    let save = |path: Option<String>, password: Option<String>| Request::FileSaveDir {
        contact: contact.to_string(),
        agent: agent.clone(),
        path,
        password,
    };
    if clear {
        o.call(save(None, None)).await
    } else {
        o.call_pw(pw, |p| save(folder.map(str::to_string), Some(p)))
            .await
    }
}
