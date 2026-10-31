// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna picture` (CONTROL §28): the pictures this computer shows, and your own picture or one of your agents': a
//! drawn one by id, a photo (checked, cropped to a square and stripped of metadata by the daemon), or none.

use antenna_proto::control::{Reply, Request};
use clap::{Args, Subcommand};

use super::Owner;
use crate::client::{CliResult, EXIT_FAIL, EXIT_USAGE, Fail};

/// `antenna picture`.
#[derive(Debug, Args)]
pub(crate) struct PictureArgs {
    #[command(subcommand)]
    cmd: Option<PictureCommand>,
}

#[derive(Debug, Subcommand)]
enum PictureCommand {
    /// Use a drawn picture: its id from the window's sets, like `set1/fox` (contacts get the id only).
    Set {
        /// `<set>/<animal>`.
        id: String,
        /// For one of your agents instead of you.
        #[arg(long)]
        agent: Option<String>,
    },
    /// Use a photo: the daemon checks the image, crops the middle square, resizes it to 512 px and encodes it again
    /// without metadata; contacts get that, never your file.
    Photo {
        /// An image file (PNG, JPEG, WebP, GIF, BMP).
        file: std::path::PathBuf,
        /// For one of your agents instead of you.
        #[arg(long)]
        agent: Option<String>,
    },
    /// Back to initials.
    Remove {
        /// For one of your agents instead of you.
        #[arg(long)]
        agent: Option<String>,
    },
    /// Save a photo as this computer shows it (the JPEG the daemon rebuilt, by the id `antenna picture` lists).
    Save {
        /// The photo's id.
        id: String,
        /// Where to write the JPEG.
        file: std::path::PathBuf,
    },
}

/// `antenna picture …`.
pub(crate) async fn run(o: &Owner, a: &PictureArgs) -> CliResult<Reply> {
    let req = match &a.cmd {
        None => Request::Pictures {},
        Some(PictureCommand::Set { id, agent }) => Request::PictureSet {
            agent: agent.clone(),
            drawn: Some(id.clone()),
            photo: None,
            remove: false,
        },
        Some(PictureCommand::Photo { file, agent }) => {
            // The daemon reads the file: give it the full path
            let path = std::path::absolute(file).map_err(|e| {
                Fail::new(
                    EXIT_USAGE,
                    "bad_request",
                    format!("{}: {e}", file.display()),
                )
            })?;
            Request::PictureSet {
                agent: agent.clone(),
                drawn: None,
                photo: Some(path.to_string_lossy().into_owned()),
                remove: false,
            }
        }
        Some(PictureCommand::Remove { agent }) => Request::PictureSet {
            agent: agent.clone(),
            drawn: None,
            photo: None,
            remove: true,
        },
        Some(PictureCommand::Save { id, file }) => return save(o, id, file).await,
    };
    o.call(req).await
}

/// `antenna picture save`: `picture_photo`, then the bytes into the file.
async fn save(o: &Owner, id: &str, file: &std::path::Path) -> CliResult<Reply> {
    let r = o.call(Request::PicturePhoto { id: id.to_string() }).await?;
    if let Reply::PicturePhoto(p) = &r {
        let bytes = data_encoding::BASE64
            .decode(p.data_base64.as_bytes())
            .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("the daemon's photo: {e}")))?;
        std::fs::write(file, bytes)
            .map_err(|e| Fail::new(EXIT_FAIL, "internal", format!("{}: {e}", file.display())))?;
    }
    Ok(r)
}
