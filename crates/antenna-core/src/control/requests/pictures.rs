// SPDX-License-Identifier: AGPL-3.0-only
//! Profile pictures (CONTROL §28): the list, the owner's choice, a rebuilt photo's bytes.

use antenna_proto::control::{PicturePhotoReply, PicturesReply, Reply, Request};
use data_encoding::BASE64;

use super::{Answer, b, session};
use crate::error::Error;
use crate::node::Node;
use crate::pictures::Choice;

/// `pictures`.
pub(crate) async fn list(node: &Node) -> Answer {
    let s = session(node).await?;
    s.pictures()
        .await
        .map(|pictures| Reply::Pictures(PicturesReply { pictures }))
        .map_err(b)
}

/// `picture_set`: exactly one of `drawn`, `photo` or `remove`.
pub(crate) async fn set(node: &Node, req: Request) -> Answer {
    let Request::PictureSet {
        agent,
        drawn,
        photo,
        remove,
    } = req
    else {
        return Err(Error::internal("not a picture_set").body());
    };
    let choice = match (drawn, photo, remove) {
        (Some(id), None, false) => Choice::Drawn(id),
        (None, Some(path), false) => Choice::Photo(path),
        (None, None, true) => Choice::Remove,
        _ => {
            return Err(Error::bad_request("give exactly one of drawn, photo or remove").body());
        }
    };
    let s = session(node).await?;
    s.picture_set(agent, choice)
        .await
        .map(|pictures| Reply::Pictures(PicturesReply { pictures }))
        .map_err(b)
}

/// `picture_photo`.
pub(crate) async fn photo(node: &Node, id: String) -> Answer {
    let s = session(node).await?;
    s.picture_photo(&id)
        .map(|bytes| {
            Reply::PicturePhoto(PicturePhotoReply {
                id,
                mime: antenna_files::picture::MIME.into(),
                data_base64: BASE64.encode(&bytes),
            })
        })
        .map_err(b)
}
