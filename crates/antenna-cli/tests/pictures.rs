// SPDX-License-Identifier: AGPL-3.0-only
//! Profile pictures (`docs/PROTOCOL.md` §25, `docs/CONTROL.md` §28) between real daemons: a drawn picture reaches the
//! contact as its id and follows changes; an own photo is checked, cropped and encoded again on this side, checked and
//! rebuilt again on the contact's side, and nobody ever gets the original bytes; a malformed image is refused; an
//! agent's picture is revealed only once the agent wrote on the link; level 1 shows drawn pictures but no photos; an
//! older node (preview.7) gets no picture message and its history stays verified.
//!
//! Run: `cargo test -p antenna-cli --test pictures` (from the workspace root; `cargo build -p antennad -p antenna-cli`
//! first when running a single package).

// Live daemons over the control socket: on Windows the daemon does not start before W1 (D-134, WP-4, WP-5).
#![cfg(unix)]

mod common;

use std::time::{Duration, Instant};

use common::*;
use serde_json::Value;

const T: Duration = Duration::from_secs(20);

fn nodes(root: &std::path::Path, names: &[&str], net: &Net) -> Vec<Node> {
    names
        .iter()
        .map(|n| {
            let mut x = Node::new(root, n, net.clone());
            x.start();
            x.init();
            x
        })
        .collect()
}

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < timeout, "timeout waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `antenna picture --json`: the entries.
fn pictures(n: &Node) -> Vec<Value> {
    n.json(&["picture"])["pictures"].as_array().unwrap().clone()
}

/// The entry for `contact` (and its `agent`), or for this node's own picture when `contact` is `None`.
fn entry(n: &Node, contact: Option<&str>, agent: Option<&str>) -> Option<Value> {
    pictures(n)
        .into_iter()
        .find(|p| p["contact"].as_str() == contact && p["agent"].as_str() == agent)
}

/// The bytes of a rebuilt photo, as the window gets them (`picture_photo`, through `antenna picture save`).
fn photo_bytes(n: &Node, id: &str) -> Vec<u8> {
    let f = n.dir.join(format!("{id}.jpg"));
    let v = n.json(&["picture", "save", id, f.to_str().unwrap()]);
    assert_eq!(
        (v["type"].as_str(), v["mime"].as_str()),
        (Some("picture_photo"), Some("image/jpeg")),
        "{v}"
    );
    std::fs::read(&f).unwrap()
}

fn verified(n: &Node, contact: &str) -> Value {
    n.json(&["verify", contact])["status"].clone()
}

fn has(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// A 900×600 PNG with a text chunk that says where it was taken: what a picture must never carry on.
fn photo_file(dir: &std::path::Path, name: &str) -> (std::path::PathBuf, Vec<u8>) {
    let (w, h) = (900u32, 600u32);
    let mut px = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            px.extend_from_slice(&[(x * 255 / w) as u8, (y * 255 / h) as u8, 160]);
        }
    }
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        enc.add_text_chunk("Comment".into(), "SECRET-LOCATION 55.75N 37.61E".into())
            .unwrap();
        let mut wr = enc.write_header().unwrap();
        wr.write_image_data(&px).unwrap();
    }
    let path = dir.join(name);
    std::fs::write(&path, &out).unwrap();
    (path, out)
}

/// A JPEG this daemon made: SOI, then JFIF only (no EXIF/XMP segment, no comment), and none of the file's text.
fn assert_rebuilt_jpeg(bytes: &[u8], original: &[u8]) {
    assert_eq!(&bytes[..3], &[0xff, 0xd8, 0xff], "a JPEG");
    assert_eq!(bytes[3], 0xe0, "JFIF first");
    assert!(!has(bytes, b"SECRET"), "no metadata text survives");
    assert!(!has(bytes, b"Exif"), "no EXIF segment");
    assert_ne!(bytes, original, "never the original bytes");
    assert!(bytes.len() <= 64 * 1024, "{}", bytes.len());
}

#[test]
fn a_drawn_picture_reaches_the_contact_as_its_id_and_follows_changes() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["ann", "bob"], &Net::Local);
    let (ann, bob) = (&ns[0], &ns[1]);
    pair(ann, bob, 3);
    assert!(entry(bob, Some("ann"), None).is_none(), "initials before");

    let v = ann.json(&["picture", "set", "set1/fox"]);
    assert_eq!(v["type"], "pictures", "{v}");
    assert_eq!(entry(ann, None, None).unwrap()["drawn"], "set1/fox");
    wait_until("bob sees ann's fox", T, || {
        entry(bob, Some("ann"), None).is_some_and(|e| e["drawn"] == "set1/fox")
    });
    // Changed, then an id this build does not know (a later set): it travels as it is, the window draws initials
    ann.json(&["picture", "set", "set2/wolf"]);
    wait_until("bob sees the wolf", T, || {
        entry(bob, Some("ann"), None).is_some_and(|e| e["drawn"] == "set2/wolf")
    });
    ann.json(&["picture", "set", "set9/unicorn"]);
    wait_until("an unknown id travels as it is", T, || {
        entry(bob, Some("ann"), None).is_some_and(|e| e["drawn"] == "set9/unicorn")
    });
    ann.json(&["picture", "remove"]);
    wait_until("initials again", T, || {
        entry(bob, Some("ann"), None).is_none()
    });
    assert!(entry(ann, None, None).is_none());

    // A malformed id is refused; nothing changes
    let out = ann.x(&["--json", "picture", "set", "Set1/../fox"]);
    assert!(!out.status.success(), "{out:?}");
    assert_eq!(last_json(&out.stdout)["error"], "bad_request");

    // Pictures are service messages: not in the conversation, and the history still verifies on both sides
    assert!(
        bob.json(&["history", "ann", "--limit", "50"])["messages"]
            .as_array()
            .unwrap()
            .is_empty(),
        "no picture in the feed"
    );
    ann.send("bob", "hello");
    wait_until("history verified", T, || {
        verified(ann, "bob")["state"] == "verified" && verified(bob, "ann")["state"] == "verified"
    });
}

#[test]
fn a_photo_is_rebuilt_on_both_sides_and_the_original_never_travels() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["ann", "bob"], &Net::Local);
    let (ann, bob) = (&ns[0], &ns[1]);
    pair(ann, bob, 3);
    let (path, original) = photo_file(root.path(), "me.png");
    assert!(has(&original, b"SECRET-LOCATION"));

    ann.json(&["picture", "photo", path.to_str().unwrap()]);
    let own = entry(ann, None, None).unwrap();
    let own_id = own["photo"].as_str().unwrap().to_string();
    assert_eq!(own_id.len(), 16, "{own}");
    let sent = photo_bytes(ann, &own_id);
    assert_rebuilt_jpeg(&sent, &original);

    wait_until("bob has ann's photo, checked", T, || {
        entry(bob, Some("ann"), None).is_some_and(|e| e["photo"].is_string())
    });
    let theirs = entry(bob, Some("ann"), None).unwrap();
    let shown = photo_bytes(bob, theirs["photo"].as_str().unwrap());
    assert_rebuilt_jpeg(&shown, &original);
    assert_ne!(
        shown, sent,
        "the contact shows its own rebuild, not the bytes it received"
    );
    // The id names the bytes the window gets; the bytes ann sent are not served by bob under any id
    assert_ne!(theirs["photo"].as_str().unwrap(), own_id);
    let out = bob.x(&["--json", "picture", "save", &own_id, "/nonexistent/x.jpg"]);
    assert_eq!(last_json(&out.stdout)["error"], "not_found", "{out:?}");

    // A malformed image and a non-image are refused; the picture stays as it was
    let bad = root.path().join("broken.png");
    std::fs::write(&bad, &original[..original.len() / 3]).unwrap();
    let html = root.path().join("page.png");
    std::fs::write(&html, b"<html><script>alert(1)</script></html>").unwrap();
    for f in [&bad, &html] {
        let out = ann.x(&["--json", "picture", "photo", f.to_str().unwrap()]);
        assert!(!out.status.success(), "{out:?}");
        assert_eq!(
            last_json(&out.stdout)["error"],
            "picture_refused",
            "{out:?}"
        );
    }
    assert_eq!(entry(ann, None, None).unwrap()["photo"], own_id.as_str());
}

#[test]
fn an_agents_picture_is_revealed_only_after_the_agent_wrote() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["ann", "bob"], &Net::Local);
    let (ann, bob) = (&ns[0], &ns[1]);
    pair(ann, bob, 3);
    let tok = ann.agent_add("desk", &["--local-level", "0"]);
    ann.json(&["picture", "set", "set2/eagle", "--agent", "desk"]);
    assert_eq!(
        entry(ann, None, Some("desk")).unwrap()["drawn"],
        "set2/eagle"
    );
    let out = ann.x(&["--json", "picture", "set", "set1/fox", "--agent", "ghost"]);
    assert_eq!(last_json(&out.stdout)["error"], "not_found", "{out:?}");

    // bob has not heard of desk: its picture does not tell bob that it exists
    ann.send("bob", "hi from ann");
    std::thread::sleep(Duration::from_millis(1500));
    assert!(entry(bob, Some("ann"), Some("desk")).is_none());

    ann.agent_ok(&tok, &["send", "bob", "hello from the front desk"]);
    wait_until("bob sees desk's picture", T, || {
        entry(bob, Some("ann"), Some("desk")).is_some_and(|e| e["drawn"] == "set2/eagle")
    });
    // The owner's own picture is separate
    assert!(entry(bob, Some("ann"), None).is_none());

    // The agent removed: its picture goes too
    let out = ann.owner(&["agent", "remove", "desk"]);
    assert!(out.status.success(), "{out:?}");
    wait_until("desk's picture removed at bob", T, || {
        entry(bob, Some("ann"), Some("desk")).is_none()
    });
}

/// Level 1 takes no files (SPEC §9): a contact's photo is neither checked nor shown, a drawn id is; raising the level
/// shows the photo. Levels 1–2 are relay only, so the two nodes talk through a local relay.
#[test]
fn level_one_shows_drawn_pictures_but_no_photos() {
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(
        root.path(),
        &["ann", "bob"],
        &Net::LocalRelay(relay.url.clone()),
    );
    let (ann, bob) = (&ns[0], &ns[1]);
    pair(ann, bob, 1);
    ann.json(&["picture", "set", "set3/robot"]);
    wait_until("a drawn id at level 1", T, || {
        entry(bob, Some("ann"), None).is_some_and(|e| e["drawn"] == "set3/robot")
    });
    let (path, _) = photo_file(root.path(), "me.png");
    ann.json(&["picture", "photo", path.to_str().unwrap()]);
    wait_until("the photo arrives, withheld", T, || {
        entry(bob, Some("ann"), None).is_some_and(|e| e["withheld"] == "level")
    });
    let e = entry(bob, Some("ann"), None).unwrap();
    assert!(e["photo"].is_null() && e["drawn"].is_null(), "{e}");

    let out = bob.owner(&["trust", "ann", "2"]);
    assert!(out.status.success(), "{out:?}");
    wait_until("shown at level 2", T, || {
        entry(bob, Some("ann"), None).is_some_and(|e| e["photo"].is_string())
    });
}

/// An older-version node: `ANTENNA_PREVIEW7_BIN_DIR` holds `antennad` and `antenna` of release `v0.1.0-preview.7`
/// (the release's Linux CLI archive, `bin/` unpacked).
fn preview7_bin() -> Option<std::path::PathBuf> {
    std::env::var_os("ANTENNA_PREVIEW7_BIN_DIR").map(Into::into)
}

/// A node without `picture/0` gets no picture message (it would refuse the unknown body and the histories would
/// differ): its owner keeps seeing initials, messages flow both ways and the history verifies.
#[test]
#[ignore = "needs ANTENNA_PREVIEW7_BIN_DIR with antennad/antenna of v0.1.0-preview.7"]
fn a_preview7_node_gets_no_picture_and_its_history_holds() {
    let Some(dir) = preview7_bin() else {
        panic!("ANTENNA_PREVIEW7_BIN_DIR is not set");
    };
    let root = tempfile::tempdir().unwrap();
    let mut old = Node::new(root.path(), "old", Net::Local);
    old.bin_dir = Some(dir);
    old.start();
    old.init();
    let mut new = Node::new(root.path(), "new", Net::Local);
    new.start();
    new.init();
    pair(&new, &old, 4);
    new.json(&["picture", "set", "set1/owl"]);
    let (path, _) = photo_file(root.path(), "me.png");
    let tok = new.agent_add("desk", &["--local-level", "0"]);
    new.json(&[
        "picture",
        "photo",
        path.to_str().unwrap(),
        "--agent",
        "desk",
    ]);
    new.agent_ok(&tok, &["send", "old", "from the desk"]);
    assert_eq!(new.send("old", "hello")["status"], "delivered");
    assert_eq!(old.send("new", "hello back")["status"], "delivered");
    wait_until("history verified both ways", T, || {
        verified(&new, "old")["state"] == "verified" && verified(&old, "new")["state"] == "verified"
    });
    assert!(
        entry(&new, Some("old"), None).is_none(),
        "the old node announced nothing"
    );
    // No picture message was written on this link: the old node would have refused it, the queue would hold it or
    // mark it failed, and the two copies of the history would differ
    let c = new.contact("old");
    assert_eq!(
        (c["outbox"].as_u64(), c["failed"].as_u64()),
        (Some(0), Some(0)),
        "{c}"
    );
}
