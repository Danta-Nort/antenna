// SPDX-License-Identifier: AGPL-3.0-only
//! `antenna picture` for humans (CONTROL §28): one line per picture.

use antenna_proto::control::{PictureEntry, PicturePhotoReply, PicturesReply};

use super::clean;

/// `pictures`, `picture_set`.
pub(super) fn pictures(r: &PicturesReply) {
    if !r
        .pictures
        .iter()
        .any(|p| p.contact.is_none() && p.agent.is_none())
    {
        outln!(
            "{:<28}initials (`antenna picture set set1/fox` or `antenna picture photo <file>`)",
            "you"
        );
    }
    for p in &r.pictures {
        outln!("{}", line(p));
    }
}

/// `picture_photo`.
pub(super) fn photo(r: &PicturePhotoReply) {
    outln!(
        "photo {} ({}, {} base64 characters; `--json` for the bytes)",
        r.id,
        r.mime,
        r.data_base64.len()
    );
}

/// `you · lead              set1/fox`, `bob                     photo 0123456789abcdef`, `bob · desk  photo not
/// shown (refused)`.
pub(super) fn line(p: &PictureEntry) -> String {
    let who = match (&p.contact, &p.agent) {
        (None, None) => "you".to_string(),
        (None, Some(a)) => format!("you · {}", clean(a)),
        (Some(c), None) => clean(c),
        (Some(c), Some(a)) => format!("{} · {}", clean(c), clean(a)),
    };
    let what = match (&p.drawn, &p.photo, &p.withheld) {
        (Some(d), _, _) => clean(d),
        (None, Some(id), _) => format!("photo {id}"),
        (None, None, Some(w)) => format!("photo not shown ({})", clean(w)),
        (None, None, None) => "initials".into(),
    };
    format!("{who:<28}{what}")
}
