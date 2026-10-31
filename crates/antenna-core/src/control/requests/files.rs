// SPDX-License-Identifier: AGPL-3.0-only
//! Files (CONTROL §14, SPEC §10): sending, requesting, the quarantine.

use antenna_proto::control::Reply;

use super::{Answer, b, session};
use crate::node::Node;

/// `share_file`.
pub(crate) async fn share(
    node: &Node,
    contact: String,
    path: String,
    name: Option<String>,
    approval_id: Option<String>,
    addr: crate::addressing::Addr,
) -> Answer {
    Ok(Reply::File(
        session(node)
            .await?
            .owner_share_file(
                &contact,
                &path,
                name.as_deref(),
                approval_id.as_deref(),
                &addr,
            )
            .await
            .map_err(b)?,
    ))
}

/// `request_file`.
pub(crate) async fn request(node: &Node, contact: String, path: String) -> Answer {
    let (contact, id, status) = session(node)
        .await?
        .owner_request_file(&contact, &path)
        .await
        .map_err(b)?;
    Ok(Reply::FileRequested {
        contact,
        id,
        status,
    })
}

/// `files_pending`.
pub(crate) async fn pending(node: &Node, contact: Option<String>, all: bool) -> Answer {
    let s = session(node).await?;
    let only = contact
        .as_deref()
        .map(|c| s.find_link(c))
        .transpose()
        .map_err(b)?
        .map(|r| r.link_id);
    Ok(Reply::Files {
        files: s
            .files_list(None, only.as_ref(), all)
            .map_err(b)?
            .into_iter()
            .map(|(i, _, _)| i)
            .collect(),
    })
}

/// `file_preview`.
pub(crate) async fn preview(node: &Node, id: String) -> Answer {
    let s = session(node).await?;
    let (item, row) = s.find_file(&id, None).map_err(b)?;
    let preview = s.preview_of(&item).map_err(b)?;
    Ok(Reply::FilePreview {
        file: s.file_info(&item, &row.label),
        preview,
    })
}

/// `file_accept` (with `force`, the password was checked in `owner`).
pub(crate) async fn accept(
    node: &Node,
    id: String,
    name: Option<String>,
    force: bool,
    allow_special: bool,
) -> Answer {
    Ok(Reply::File(
        session(node)
            .await?
            .owner_file_accept(&id, name.as_deref(), force, allow_special)
            .await
            .map_err(b)?,
    ))
}

/// `file_name_check` (preview.8): whether a received file can be accepted under a name.
pub(crate) async fn name_check(node: &Node, id: String, name: Option<String>) -> Answer {
    Ok(Reply::FileName(
        session(node)
            .await?
            .owner_file_name_check(&id, name.as_deref())
            .await
            .map_err(b)?,
    ))
}

/// `file_reject`.
pub(crate) async fn reject(node: &Node, id: String) -> Answer {
    Ok(Reply::File(
        session(node)
            .await?
            .owner_file_reject(&id)
            .await
            .map_err(b)?,
    ))
}

/// `file_withdraw` (PROTOCOL §19): a sent file the contact has not answered yet.
pub(crate) async fn withdraw(node: &Node, id: String) -> Answer {
    Ok(Reply::File(
        session(node)
            .await?
            .owner_file_withdraw(&id)
            .await
            .map_err(b)?,
    ))
}

/// `file_allow` (D-130; the password was checked in `owner`).
pub(crate) async fn allow(node: &Node, contact: String, entries: Vec<String>) -> Answer {
    Ok(Reply::FileAllow(
        session(node)
            .await?
            .owner_file_allow(&contact, &entries)
            .await
            .map_err(b)?,
    ))
}

/// `file_disallow` (D-130): an owner session, no password.
pub(crate) async fn disallow(node: &Node, contact: String, entries: Vec<String>) -> Answer {
    Ok(Reply::FileAllow(
        session(node)
            .await?
            .owner_file_disallow(&contact, &entries)
            .await
            .map_err(b)?,
    ))
}

/// `file_save_dir` (D-130; setting one: the password was checked in `owner`).
pub(crate) async fn save_dir(
    node: &Node,
    contact: String,
    agent: Option<String>,
    path: Option<String>,
) -> Answer {
    Ok(Reply::FileSaveDirs(
        session(node)
            .await?
            .owner_file_save_dir(&contact, agent.as_deref(), path.as_deref())
            .await
            .map_err(b)?,
    ))
}
