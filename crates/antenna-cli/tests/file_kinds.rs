// SPDX-License-Identifier: AGPL-3.0-only
//! What holds a received file (maintainer decision D-130, amending SPEC §10–§11): from trust level 3 the check's
//! heuristics are labels and the file is accepted the normal way for its level; native programs, installers and disk
//! images, archives holding them and antivirus hits wait for the owner's keep-anyway, at every level from 3; levels
//! 1–2 are unchanged. The sender learns each file's fate (`file-fate/0`), and a held file never reads "declined".
//! Real `antennad` and `antenna`.

// The file check needs the worker sandbox (D-P-12); on other OSes it fails closed and files never reach "checked".
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::{
    path::Path,
    time::{Duration, Instant},
};

use common::*;
use serde_json::Value;

fn nodes_on(net: Net, root: &Path, names: &[&str], extra: &[&[&str]]) -> Vec<Node> {
    names
        .iter()
        .enumerate()
        .map(|(i, n)| {
            let mut x = Node::new(root, n, net.clone());
            if let Some(args) = extra.get(i) {
                x.extra_args = args.iter().map(|s| s.to_string()).collect();
            }
            x.start();
            x.init();
            x
        })
        .collect()
}

fn nodes(root: &Path, names: &[&str], extra: &[&[&str]]) -> Vec<Node> {
    nodes_on(Net::Local, root, names, extra)
}

/// CRC-32 (ISO-HDLC, as PNG and ZIP use it), bit by bit: test data only.
fn crc32(data: &[u8]) -> u32 {
    let mut c = !0u32;
    for b in data {
        c ^= *b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 {
                (c >> 1) ^ 0xEDB8_8320
            } else {
                c >> 1
            };
        }
    }
    !c
}

/// A ZIP with stored (uncompressed) entries, as Python's `zipfile` writes by default: the first page's markup lies in
/// the archive's first KiB, which is what the check flagged as `polyglot_html` in the field report.
fn stored_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let (mut out, mut central) = (Vec::new(), Vec::new());
    for (name, data) in entries {
        let off = out.len() as u32;
        let crc = crc32(data);
        let head = |sig: &[u8], central: bool| {
            let mut h = sig.to_vec();
            if central {
                h.extend_from_slice(&20u16.to_le_bytes());
            }
            h.extend_from_slice(&20u16.to_le_bytes());
            h.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]);
            h.extend_from_slice(&crc.to_le_bytes());
            h.extend_from_slice(&(data.len() as u32).to_le_bytes());
            h.extend_from_slice(&(data.len() as u32).to_le_bytes());
            h.extend_from_slice(&(name.len() as u16).to_le_bytes());
            h.extend_from_slice(&0u16.to_le_bytes());
            if central {
                h.extend_from_slice(&[0; 6]);
                h.extend_from_slice(&0o100644u32.wrapping_shl(16).to_le_bytes());
                h.extend_from_slice(&off.to_le_bytes());
            }
            h.extend_from_slice(name.as_bytes());
            h
        };
        out.extend(head(b"PK\x03\x04", false));
        out.extend_from_slice(data);
        central.extend(head(b"PK\x01\x02", true));
    }
    let (cd_off, cd_len) = (out.len() as u32, central.len() as u32);
    out.extend(central);
    out.extend_from_slice(b"PK\x05\x06\0\0\0\0");
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&cd_len.to_le_bytes());
    out.extend_from_slice(&cd_off.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

/// An icon as an image generator writes it: XMP in `iTXt` and content credentials (C2PA) in `caBX`, both before the
/// pixels, both carrying markup (D-129).
fn generated_png() -> Vec<u8> {
    let mut buf = Vec::new();
    {
        let mut e = png::Encoder::new(&mut buf, 2, 2);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        e.add_itxt_chunk(
            "XML:com.adobe.xmp".into(),
            "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF><svg viewBox='0 0 1 1'/></rdf:RDF></x:xmpmeta>".into(),
        )
        .unwrap();
        let mut w = e.write_header().unwrap();
        let mut c2pa = b"\0\0\0\x20jumb\0\0\0\x18jumdc2pa".to_vec();
        c2pa.extend_from_slice(b"{\"title\":\"AppIcon\",\"note\":\"<html><body>\"}");
        w.write_chunk(png::chunk::ChunkType(*b"caBX"), &c2pa)
            .unwrap();
        w.write_image_data(&[0u8; 16]).unwrap();
    }
    buf
}

const PANEL: &str = "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>Panel</title></head>\
    <body><div id=\"panel\"><button onclick=\"add()\">Add agent</button></div>\
    <script>const agents=[\"claude-code\"];function add(){agents.push(\"x\")}</script></body></html>\n";

fn elf() -> Vec<u8> {
    let mut v = b"\x7FELF\x02\x01\x01\0\0\0\0\0\0\0\0\0".to_vec();
    v.resize(700, 0x41);
    v
}

fn macho() -> Vec<u8> {
    let mut v = b"\xCF\xFA\xED\xFE\x0C\0\0\x01".to_vec();
    v.resize(700, 0x42);
    v
}

/// A UDIF disk image: compressed blocks, then the `koly` trailer macOS reads it by.
fn dmg() -> Vec<u8> {
    let mut v = b"x\xda\x01\x02\x03\x04".to_vec();
    v.extend_from_slice(&[0x5A; 2048]);
    let mut k = vec![0u8; 512];
    k[..4].copy_from_slice(b"koly");
    k[4..8].copy_from_slice(&4u32.to_be_bytes());
    k[8..12].copy_from_slice(&512u32.to_be_bytes());
    v.extend(k);
    v
}

const SECRET_TEXT: &str = "notes for the deploy\npassword: hunter2hunter2\n";

/// The files the field reports were about, and what each must show as labels.
fn ordinary() -> Vec<(&'static str, Vec<u8>, &'static [&'static str], &'static str)> {
    vec![
        ("AppIcon-transparent.png", generated_png(), &[], "other"),
        (
            "panel-1.html",
            PANEL.as_bytes().to_vec(),
            &["active_content"],
            "code",
        ),
        (
            "panel-1.txt",
            PANEL.as_bytes().to_vec(),
            &["active_content"],
            "code",
        ),
        (
            "panel-prototypes.zip",
            stored_zip(&[
                ("panel-prototypes/panel-1.html", PANEL.as_bytes()),
                ("panel-prototypes/app.js", b"export const x = 1;\n"),
            ]),
            &["polyglot_html", "executable_entry"],
            "code",
        ),
        (
            "notes.txt",
            SECRET_TEXT.as_bytes().to_vec(),
            &["secret:password"],
            "text",
        ),
    ]
}

/// What runs or installs: held at every level from 3, with this reason.
fn programs() -> Vec<(&'static str, Vec<u8>, &'static str)> {
    vec![
        ("antennad", elf(), "executable"),
        ("antenna-macos", macho(), "executable"),
        (
            "build.zip",
            stored_zip(&[("bin/antennad", &elf()), ("README.md", b"# build\n")]),
            "executable",
        ),
        ("Antenna.dmg", dmg(), "installer"),
    ]
}

fn files(n: &Node) -> Vec<Value> {
    n.json(&["files", "pending", "--all"])["files"]
        .as_array()
        .unwrap()
        .clone()
}

fn wait_file(n: &Node, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    let t = Instant::now();
    loop {
        let all = files(n);
        if let Some(x) = all.iter().find(|x| f(x)) {
            return x.clone();
        }
        assert!(
            t.elapsed() < Duration::from_secs(60),
            "{}: {what}: {all:?}",
            n.name
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn labels(f: &Value) -> Vec<String> {
    f["labels"]
        .as_array()
        .map(|a| a.iter().map(|x| x.as_str().unwrap().to_string()).collect())
        .unwrap_or_default()
}

/// The sending agent's notices of its files' fates, until every one of `ids` has one in a state of `want`.
fn fates(n: &Node, tok: &str, ids: &[String], want: &[&str]) -> Vec<Value> {
    let t = Instant::now();
    let mut seen: Vec<Value> = Vec::new();
    while !ids.iter().all(|id| {
        seen.iter()
            .any(|f| f["id"] == id.as_str() && want.contains(&f["state"].as_str().unwrap_or("")))
    }) {
        let v = n.agent_ok(tok, &["inbox", "--wait", "--timeout", "3s"]);
        seen.extend(
            v["files"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|f| f["direction"] == "out"),
        );
        assert!(t.elapsed() < Duration::from_secs(60), "fates: {seen:?}");
    }
    seen
}

fn share(a: &Node, tok: &str, dir: &Path, name: &str, data: &[u8]) -> String {
    let p = dir.join(name);
    std::fs::write(&p, data).unwrap();
    let r = a.agent_ok(tok, &["share", "bob", p.to_str().unwrap()]);
    r["file"]["id"]
        .as_str()
        .or(r["id"].as_str())
        .unwrap()
        .to_string()
}

/// At ∞ (both sides the owner's own computers): the generated PNG, HTML, a stored ZIP of HTML and JavaScript and a
/// text with a secret-like line are saved by the daemon with their labels; an ELF, a Mach-O, a ZIP holding an ELF and
/// a disk image wait for the owner, who keeps one anyway with the password (not without it, not as an agent). The
/// sending agent is told saved or held, never declined.
#[test]
fn at_infinity_ordinary_files_are_saved_with_labels_and_programs_wait() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"], &[]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let tok = a.agent_add("builder", &["--local-level", "0"]);
    let btok = b.agent_add("reader", &["--local-level", "0"]);
    let src = root.path().join("src");
    std::fs::create_dir_all(&src).unwrap();

    let mut saved_ids = Vec::new();
    for (name, data, want, class) in ordinary() {
        let id = share(a, &tok, &src, name, &data);
        let f = wait_file(b, name, |x| {
            x["id"] == id.as_str() && x["state"] == "accepted"
        });
        assert_eq!(labels(&f), want, "{name}: {f}");
        assert_eq!(f["class"], class, "{name}: {f}");
        assert!(f["held"].is_null(), "{name}: {f}");
        assert_eq!(
            std::fs::read(b.links().join("alice/shared").join(name)).unwrap(),
            data,
            "{name}"
        );
        saved_ids.push(id);
    }
    let mut held_ids = Vec::new();
    for (name, data, why) in programs() {
        let id = share(a, &tok, &src, name, &data);
        let f = wait_file(b, name, |x| {
            x["id"] == id.as_str() && x["state"] == "checked"
        });
        assert_eq!(f["held"]["code"], why, "{name}: {f}");
        assert!(
            !f["held"]["rules"].as_array().unwrap().is_empty(),
            "{name}: {f}"
        );
        assert!(
            !b.links().join("alice/shared").join(name).exists(),
            "{name}"
        );
        held_ids.push((id, name));
    }

    // The sender's fates: saved, or waiting for the owner there with the reason; never declined. An inbox gives a
    // notice once, so one wait collects them all.
    let mut all: Vec<String> = saved_ids.clone();
    all.extend(held_ids.iter().map(|(i, _)| i.clone()));
    let seen = fates(a, &tok, &all, &["accepted", "held"]);
    for id in &saved_ids {
        assert!(
            seen.iter()
                .any(|f| f["id"] == id.as_str() && f["state"] == "accepted")
        );
    }
    for (id, name) in &held_ids {
        let f = seen.iter().find(|f| f["id"] == id.as_str()).unwrap();
        assert_eq!(f["state"], "held", "{name}: {f}");
        assert!(f["held"]["code"].is_string(), "{name}: {f}");
    }
    let out = a.agent_cmd(&tok).args(["inbox"]).output().unwrap();
    assert!(!String::from_utf8_lossy(&out.stdout).contains("declined"));

    // Keep anyway: the owner with the password; not an agent, not the owner without it
    let (elf_id, _) = &held_ids[0];
    let (code, v) = b.agent(&btok, &["files", "accept", elf_id]);
    assert_ne!(code, 0, "an agent cannot keep a program: {v}");
    let out = b.x(&["--json", "files", "accept", elf_id]);
    assert!(
        !out.status.success(),
        "the owner without the password: {out:?}"
    );
    let v = b.owner_json(&["files", "accept", elf_id, "--force"]);
    assert_eq!(v["state"], "accepted", "{v}");
    assert_eq!(
        std::fs::read(b.links().join("alice/shared/antennad")).unwrap(),
        elf()
    );
    let seen = fates(a, &tok, std::slice::from_ref(elf_id), &["accepted"]);
    assert!(
        seen.iter()
            .any(|f| f["id"] == elf_id.as_str() && f["state"] == "accepted")
    );
}

/// At level 3 the same ordinary files wait for an accept as before, but only their labels are left: an agent of the
/// receiving computer accepts each without the owner. The programs wait for the owner's keep-anyway as at ∞.
#[test]
fn at_level_3_heuristics_are_labels_and_an_agent_accepts() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"], &[]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 3);
    // The sender treats the receiver as its own computer so that nothing asks on the sending side
    a.owner_json(&["trust", "bob", "5", "--yes"]);
    let tok = a.agent_add("builder", &["--local-level", "0"]);
    let btok = b.agent_add("reader", &["--local-level", "0"]);
    let src = root.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    for (name, data, want, _) in ordinary() {
        let id = share(a, &tok, &src, name, &data);
        let f = wait_file(b, name, |x| {
            x["id"] == id.as_str() && x["state"] == "checked"
        });
        assert_eq!(labels(&f), want, "{name}: {f}");
        assert!(f["held"].is_null(), "{name}: {f}");
        let v = b.agent_ok(&btok, &["files", "accept", &id]);
        assert_eq!(v["state"], "accepted", "{name}: {v}");
        assert_eq!(
            std::fs::read(b.links().join("alice/shared").join(name)).unwrap(),
            data
        );
    }
    let mut ids = Vec::new();
    for (name, data, why) in programs() {
        let id = share(a, &tok, &src, name, &data);
        let f = wait_file(b, name, |x| {
            x["id"] == id.as_str() && x["state"] == "checked"
        });
        assert_eq!(f["held"]["code"], why, "{name}: {f}");
        let (code, v) = b.agent(&btok, &["files", "accept", &id]);
        assert_ne!(code, 0, "{name}: {v}");
        assert!(
            v["message"]
                .as_str()
                .unwrap_or("")
                .contains("held for the owner"),
            "{name}: {v}"
        );
        ids.push(id);
    }
    let seen = fates(a, &tok, &ids, &["held"]);
    assert!(seen.iter().all(|f| f["state"] != "rejected"));
    let v = b.owner_json(&["files", "accept", &ids[3], "--force"]);
    assert_eq!(v["state"], "accepted", "{v}");
}

/// Level 2 is unchanged: the owner accepts every file into `inbox/`, an agent none; the verdict decides, no labels;
/// a stored ZIP of HTML is still a threat the sender is told was refused, and only `--force` keeps it.
#[test]
fn at_level_2_nothing_changes() {
    // Levels 1–2 go only through a relay
    let relay = LocalRelay::start();
    let root = tempfile::tempdir().unwrap();
    let ns = nodes_on(
        Net::LocalRelay(relay.url.clone()),
        root.path(),
        &["alice", "bob"],
        &[],
    );
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 2);
    a.owner_json(&["trust", "bob", "5", "--yes"]);
    let tok = a.agent_add("builder", &["--local-level", "0"]);
    let btok = b.agent_add("reader", &["--local-level", "0"]);
    let src = root.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    let html = share(a, &tok, &src, "panel-1.html", PANEL.as_bytes());
    let f = wait_file(b, "html", |x| {
        x["id"] == html.as_str() && x["state"] == "checked"
    });
    assert_eq!(f["verdict"], "suspicious", "{f}");
    assert!(labels(&f).is_empty() && f["held"].is_null(), "{f}");
    let (code, _) = b.agent(&btok, &["files", "accept", &html]);
    assert_ne!(code, 0);
    let (_, zip, _, _) = ordinary().remove(3);
    let z = share(a, &tok, &src, "panel-prototypes.zip", &zip);
    let f = wait_file(b, "zip", |x| {
        x["id"] == z.as_str() && x["state"] == "checked"
    });
    assert_eq!(f["verdict"], "threat", "{f}");
    assert!(labels(&f).is_empty(), "{f}");
    let seen = fates(a, &tok, std::slice::from_ref(&z), &["blocked"]);
    assert!(
        seen.iter()
            .any(|f| f["id"] == z.as_str() && f["state"] == "blocked")
    );
    let out = b.x(&["--json", "files", "accept", &z]);
    assert!(!out.status.success(), "{out:?}");
    let v = b.owner_json(&["files", "accept", &html]);
    assert_eq!(v["state"], "accepted", "{v}");
    assert!(b.links().join("alice/inbox/panel-1.html").exists());
}

/// An antivirus hit holds a file at ∞ too (here a stub `clamscan` that flags a marker): the hook the owner turned on
/// is a signature, not a heuristic.
#[cfg(target_os = "linux")]
#[test]
fn an_antivirus_hit_is_held_at_infinity() {
    let root = tempfile::tempdir().unwrap();
    let db = root.path().join("clamav");
    std::fs::create_dir_all(&db).unwrap();
    let av = db.join("clamscan");
    std::fs::write(
        &av,
        "#!/bin/sh\nif /usr/bin/grep -q FAKE-AV-SIGNATURE; then exit 1; fi\nexit 0\n",
    )
    .unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&av, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let (av_s, db_s) = (av.to_str().unwrap(), db.to_str().unwrap());
    let ns = nodes(
        root.path(),
        &["alice", "bob"],
        &[&[], &["--clamscan", av_s, "--clamav-db", db_s]],
    );
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let tok = a.agent_add("builder", &["--local-level", "0"]);
    let src = root.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    let clean = share(a, &tok, &src, "readme.txt", b"just text\n");
    let f = wait_file(b, "clean", |x| {
        x["id"] == clean.as_str() && x["state"] == "accepted"
    });
    assert!(f["held"].is_null(), "{f}");
    let hit = share(
        a,
        &tok,
        &src,
        "report.txt",
        b"quarterly numbers FAKE-AV-SIGNATURE\n",
    );
    let f = wait_file(b, "hit", |x| {
        x["id"] == hit.as_str() && x["state"] == "checked"
    });
    assert_eq!(f["held"]["code"], "threat", "{f}");
    assert_eq!(f["held"]["rules"][0], "av:clamscan", "{f}");
    let seen = fates(a, &tok, std::slice::from_ref(&hit), &["held"]);
    let f = seen.iter().find(|f| f["id"] == hit.as_str()).unwrap();
    assert_eq!(
        f["held"]["rules"][0], "av",
        "the recipient's rule names stay its own: {f}"
    );
}

/// Save folders (D-130): files from an own computer go to the folder the owner chose for it, and those an agent of it
/// signed go to that agent's folder; the person's file and another agent's go to the contact's folder. A folder that
/// does not exist, is outside the home folder, hidden, or in Antenna's link folders is refused, and so is any folder
/// for a contact below ∞; clearing needs no password and goes back to the link folder.
#[test]
fn save_folders_per_own_computer_and_per_agent() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    for d in ["Desktop/Antenna", "Desktop/Volna", ".ssh"] {
        std::fs::create_dir_all(home.join(d)).unwrap();
    }
    let mut ns: Vec<Node> = ["alice", "bob"]
        .iter()
        .map(|n| Node::new(root.path(), n, Net::Local))
        .collect();
    ns[1].extra_env = vec![("HOME".into(), home.to_string_lossy().into_owned())];
    for n in ns.iter_mut() {
        n.start();
        n.init();
    }
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    // An agent signs with its own key only once alice knows bob's features (PROTOCOL §21); before that the link-root
    // signs and the file is the person's. A slower machine (a Mac) shared before the exchange and failed here.
    let t = std::time::Instant::now();
    while a.contact("bob")["peer_addressing"] != true {
        assert!(
            t.elapsed() < std::time::Duration::from_secs(30),
            "bob's features never arrived"
        );
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    let voice = a.agent_add("voice-lead", &["--local-level", "0"]);
    let other = a.agent_add("other", &["--local-level", "0"]);
    let src = root.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    // The owner of bob chooses the folders (the password), the contact's and voice-lead's
    let v = b.owner_json(&["files", "save-to", "alice", "~/Desktop/Antenna"]);
    assert_eq!(
        v["dirs"][0]["path"],
        home.join("Desktop/Antenna")
            .canonicalize()
            .unwrap()
            .to_str()
            .unwrap()
    );
    b.owner_json(&[
        "files",
        "save-to",
        "alice",
        "~/Desktop/Volna",
        "--agent",
        "voice-lead",
    ]);
    let c = b.json(&["contacts"]);
    let alice = c["contacts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["label"] == "alice")
        .unwrap()
        .clone();
    assert_eq!(alice["save_dirs"].as_array().unwrap().len(), 2, "{alice}");
    // Refused: no such folder, outside the home, hidden, the link folders
    let links = b.links();
    std::fs::create_dir_all(links.join("x")).unwrap();
    for bad in [
        home.join("Desktop/missing").to_str().unwrap().to_string(),
        root.path().to_str().unwrap().to_string(),
        "~/.ssh".to_string(),
        "~".to_string(),
        links.join("x").to_str().unwrap().to_string(),
    ] {
        let out = b.owner(&["files", "save-to", "alice", &bad]);
        assert!(!out.status.success(), "{bad}: {out:?}");
    }

    let share_as = |tok: &str, name: &str| {
        let p = src.join(name);
        std::fs::write(&p, format!("{name}\n")).unwrap();
        let r = a.agent_ok(tok, &["share", "bob", p.to_str().unwrap()]);
        r["file"]["id"]
            .as_str()
            .or(r["id"].as_str())
            .unwrap()
            .to_string()
    };
    let by_voice = share_as(&voice, "voice-notes.md");
    let by_other = share_as(&other, "other-notes.md");
    let p = src.join("owner-notes.md");
    std::fs::write(&p, "owner\n").unwrap();
    let by_owner = a.json(&["share", "bob", p.to_str().unwrap()])["id"]
        .as_str()
        .unwrap()
        .to_string();
    for (id, dir, name) in [
        (&by_voice, "Desktop/Volna", "voice-notes.md"),
        (&by_other, "Desktop/Antenna", "other-notes.md"),
        (&by_owner, "Desktop/Antenna", "owner-notes.md"),
    ] {
        let f = wait_file(b, name, |x| {
            x["id"] == id.as_str() && x["state"] == "accepted"
        });
        let want = home.join(dir).canonicalize().unwrap().join(name);
        assert_eq!(f["saved_path"], want.to_str().unwrap(), "{f}");
        assert_eq!(f["dest"], "project", "{f}");
        assert!(want.is_file(), "{name}");
        assert!(!links.join("alice/shared").join(name).exists(), "{name}");
    }

    // Clearing needs no password; the next file goes to the link folder again
    let out = b.x(&["--json", "files", "save-to", "alice", "--clear"]);
    assert!(out.status.success(), "{out:?}");
    b.x(&[
        "--json",
        "files",
        "save-to",
        "alice",
        "--clear",
        "--agent",
        "voice-lead",
    ]);
    let again = share_as(&voice, "after-clear.md");
    wait_file(b, "after-clear.md", |x| {
        x["id"] == again.as_str() && x["state"] == "accepted"
    });
    assert!(links.join("alice/shared/after-clear.md").is_file());

    // Below ∞ no folder is taken
    b.owner_json(&["trust", "alice", "4"]);
    let out = b.owner(&["files", "save-to", "alice", "~/Desktop/Antenna"]);
    assert!(!out.status.success(), "{out:?}");
}

/// The allowlist of an own computer (D-130): with `executables` allowed, its programs are saved by themselves; taken
/// off without a password, they wait again; for a contact below ∞ the list cannot be set.
#[test]
fn an_own_computer_allowlist_lets_programs_through_and_is_revocable() {
    let root = tempfile::tempdir().unwrap();
    let ns = nodes(root.path(), &["alice", "bob"], &[]);
    let (a, b) = (&ns[0], &ns[1]);
    pair(a, b, 5);
    let tok = a.agent_add("builder", &["--local-level", "0"]);
    let src = root.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    let held = share(a, &tok, &src, "antennad", &elf());
    wait_file(b, "held", |x| {
        x["id"] == held.as_str() && x["held"]["code"] == "executable"
    });
    let v = b.owner_json(&["files", "allow", "alice", "executables"]);
    assert_eq!(v["entries"][0], "executables", "{v}");
    // The program that waited is saved once the owner allows its kind
    wait_file(b, "released", |x| {
        x["id"] == held.as_str() && x["state"] == "accepted"
    });
    let next = share(a, &tok, &src, "antenna-cli", &elf());
    wait_file(b, "next", |x| {
        x["id"] == next.as_str() && x["state"] == "accepted"
    });
    let c = b.json(&["contacts"]);
    assert!(
        c.to_string().contains("\"file_allow\":[\"executables\"]"),
        "{c}"
    );
    let out = b.x(&["--json", "files", "disallow", "alice", "executables"]);
    assert!(out.status.success(), "no password to take it off: {out:?}");
    let third = share(a, &tok, &src, "antenna-other", &elf());
    wait_file(b, "third", |x| {
        x["id"] == third.as_str() && x["held"]["code"] == "executable"
    });
    b.owner_json(&["trust", "alice", "4"]);
    let out = b.owner(&["files", "allow", "alice", "executables"]);
    assert!(
        !out.status.success(),
        "below ∞ there is no allowlist: {out:?}"
    );
}
