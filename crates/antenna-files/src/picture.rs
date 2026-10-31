// SPDX-License-Identifier: AGPL-3.0-only
//! Profile picture photos (`docs/PROTOCOL.md` §25): the owner's own photo before it is announced, and a contact's
//! photo before it is shown, take the same path as any received image (SPEC §10 steps 3–4): the sandboxed check
//! decodes it in isolation and hands back pixels only; the daemon assembled them into a PNG ([`crate::cdr::finalize`]).
//! Here those pixels, and nothing else, become the picture: cropped to a square from the middle, resized to at most
//! [`SIDE`] pixels, flattened onto white and encoded as a JPEG of at most [`MAX_BYTES`].
//!
//! So nothing of the original file survives: no EXIF (location, camera), no XMP, no comments, no trailing data or a
//! second format hidden after the image. The output is decoded again only by the window, and it is bytes this daemon
//! made from pixels.

use std::io::Cursor;

use antenna_proto::picture::{MAX_PHOTO, PHOTO_SIDE};
use image::{ImageEncoder, RgbImage, RgbaImage, codecs::jpeg::JpegEncoder, imageops};

use crate::report::{CheckReport, PreviewKind, Verdict};
use crate::sandbox::Checker;

/// The largest side of a picture photo.
pub const SIDE: u32 = PHOTO_SIDE;
/// The largest picture photo, in bytes.
pub const MAX_BYTES: usize = MAX_PHOTO;
/// The largest image file the owner may choose as a photo (it is checked whole in the sandbox).
pub const MAX_SOURCE: u64 = 32 << 20;
/// The type of every photo this module makes.
pub const MIME: &str = "image/jpeg";

/// Why a photo is not used. The code is what the owner or the window sees; the detail is for the log.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused {
    /// `not_an_image`, `check_failed` (the check found something or could not run), `sandbox_unavailable`,
    /// `too_large`.
    pub code: &'static str,
    /// What happened, safe to log (finding codes, sizes).
    pub detail: String,
}

impl Refused {
    fn new(code: &'static str, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }
}

/// Image types a picture may be made from, by content (the check's `mime`).
const IMAGE_MIMES: &[&str] = &[
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
    "image/bmp",
];

/// Checks `data` in the sandbox and makes the picture from the pixels it returns. `name` is the file name the check
/// compares with the content (a contact's photo: `picture.<ext>` from its declared type, so a PNG declared as JPEG
/// fails); `allowed` limits the detected types (a contact's photo: the declared type only).
pub async fn rebuild(
    checker: &Checker,
    data: &[u8],
    name: &str,
    allowed: &[&str],
) -> Result<Vec<u8>, Refused> {
    if data.is_empty() || data.len() as u64 > MAX_SOURCE {
        return Err(Refused::new(
            "too_large",
            format!("{} bytes (1…{MAX_SOURCE})", data.len()),
        ));
    }
    let out = checker.check(data, data.len() as u64, name, true).await;
    let png = accepted(&out.report, out.preview.as_ref(), allowed)?;
    from_preview(png)
}

/// The check's verdict on a picture: clean, an image of an allowed type, one rebuilt image. Anything else is refused:
/// a picture is decoration, so "could not verify" and "suspicious" both mean no picture (CONTRIBUTING.md principle 4).
pub fn accepted<'a>(
    report: &CheckReport,
    preview: Option<&'a crate::report::Preview>,
    allowed: &[&str],
) -> Result<&'a [u8], Refused> {
    let codes = || {
        report
            .findings
            .iter()
            .map(|f| f.code.as_str())
            .collect::<Vec<_>>()
            .join(",")
    };
    if report.verdict == Verdict::Failed
        && report
            .findings
            .iter()
            .any(|f| f.code == "sandbox_unavailable")
    {
        return Err(Refused::new("sandbox_unavailable", codes()));
    }
    if report.verdict != Verdict::Clean {
        return Err(Refused::new(
            "check_failed",
            format!("{:?}: {}", report.verdict, codes()),
        ));
    }
    if !IMAGE_MIMES.contains(&report.mime.as_str()) || !allowed.contains(&report.mime.as_str()) {
        return Err(Refused::new("not_an_image", report.mime.clone()));
    }
    match preview {
        Some(p) if p.kind == PreviewKind::Image && p.images.len() == 1 => Ok(&p.images[0]),
        _ => Err(Refused::new("not_an_image", "no rebuilt image")),
    }
}

/// A rebuilt preview PNG (made by this daemon from the worker's RGBA, [`crate::cdr::finalize`]) → the picture.
pub fn from_preview(png_bytes: &[u8]) -> Result<Vec<u8>, Refused> {
    let rgba = decode_own_png(png_bytes)?;
    let square = center_square(&rgba);
    let side = square.width().min(SIDE);
    let small = if square.width() == side {
        square
    } else {
        imageops::resize(&square, side, side, imageops::FilterType::Lanczos3)
    };
    let rgb = flatten(&small);
    // The best quality that fits; a busy photo that does not fit at 512 px goes down in size.
    for side in [side, side * 3 / 4, side / 2] {
        let img = if side == rgb.width() {
            rgb.clone()
        } else {
            imageops::resize(&rgb, side, side, imageops::FilterType::Lanczos3)
        };
        for q in [88u8, 82, 76, 70, 62, 54, 46] {
            let jpeg = encode_jpeg(&img, q)?;
            if jpeg.len() <= MAX_BYTES {
                return Ok(jpeg);
            }
        }
    }
    Err(Refused::new(
        "too_large",
        "the photo does not fit 64 KiB as a JPEG",
    ))
}

/// The PNG [`crate::cdr::finalize`] wrote: 8-bit RGBA, nothing else. Anything else is refused, not converted.
fn decode_own_png(bytes: &[u8]) -> Result<RgbaImage, Refused> {
    let bad = |e: String| Refused::new("not_an_image", e);
    let mut dec = png::Decoder::new(Cursor::new(bytes));
    dec.set_transformations(png::Transformations::IDENTITY);
    let mut reader = dec.read_info().map_err(|e| bad(format!("png: {e}")))?;
    let (w, h) = {
        let info = reader.info();
        if info.color_type != png::ColorType::Rgba || info.bit_depth != png::BitDepth::Eight {
            return Err(bad("not 8-bit RGBA".into()));
        }
        (info.width, info.height)
    };
    let size = reader
        .output_buffer_size()
        .ok_or_else(|| bad("png: size".into()))?;
    let mut buf = vec![0u8; size];
    let frame = reader
        .next_frame(&mut buf)
        .map_err(|e| bad(format!("png: {e}")))?;
    buf.truncate(frame.buffer_size());
    RgbaImage::from_raw(w, h, buf).ok_or_else(|| bad("png: geometry".into()))
}

/// The largest square from the middle (the window sends a square crop already; the CLI's photo is cropped here).
fn center_square(img: &RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let s = w.min(h);
    imageops::crop_imm(img, (w - s) / 2, (h - s) / 2, s, s).to_image()
}

/// Transparency over white: a picture is always drawn on a full tile, and JPEG has no alpha.
fn flatten(img: &RgbaImage) -> RgbImage {
    RgbImage::from_fn(img.width(), img.height(), |x, y| {
        let p = img.get_pixel(x, y).0;
        let a = u32::from(p[3]);
        let mix = |c: u8| ((u32::from(c) * a + 255 * (255 - a) + 127) / 255) as u8;
        image::Rgb([mix(p[0]), mix(p[1]), mix(p[2])])
    })
}

/// A baseline JPEG with only the JFIF header: the encoder is given pixels and a quality, no metadata.
fn encode_jpeg(img: &RgbImage, quality: u8) -> Result<Vec<u8>, Refused> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality)
        .write_image(
            img.as_raw(),
            img.width(),
            img.height(),
            image::ExtendedColorType::Rgb8,
        )
        .map_err(|e| Refused::new("not_an_image", format!("jpeg: {e}")))?;
    Ok(out)
}

/// JPEG segments before the image data, by marker (APP0 = 0xE0, APP1 EXIF/XMP = 0xE1, COM = 0xFE, …): what a
/// picture carries besides pixels. For tests and checks; stops at the start of scan.
pub fn jpeg_markers(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    if data.get(..2) != Some(&[0xff, 0xd8]) {
        return out;
    }
    let mut i = 2;
    while i + 4 <= data.len() && data[i] == 0xff {
        let m = data[i + 1];
        out.push(m);
        if m == 0xda {
            break;
        }
        let len = usize::from(u16::from_be_bytes([data[i + 2], data[i + 3]]));
        i += 2 + len;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cdr::{Limits, finalize};
    use crate::report::{Finding, Preview, RawImage, RawPreview, Severity};

    fn preview_png(w: u32, h: u32, mut f: impl FnMut(u32, u32) -> [u8; 4]) -> Vec<u8> {
        let mut rgba = Vec::with_capacity((w * h * 4) as usize);
        for y in 0..h {
            for x in 0..w {
                rgba.extend_from_slice(&f(x, y));
            }
        }
        let p = finalize(
            RawPreview {
                kind: PreviewKind::Image,
                text: None,
                images: vec![RawImage {
                    width: w,
                    height: h,
                    rgba,
                }],
                truncated: false,
            },
            &Limits::default(),
        )
        .unwrap();
        p.images[0].to_vec()
    }

    fn decode(jpeg: &[u8]) -> image::RgbImage {
        image::load_from_memory_with_format(jpeg, image::ImageFormat::Jpeg)
            .unwrap()
            .to_rgb8()
    }

    #[test]
    fn a_landscape_becomes_a_square_from_the_middle_at_512() {
        // Red on the left and right thirds, blue in the middle: the middle square is blue.
        let png = preview_png(1200, 600, |x, _| {
            if (300..900).contains(&x) {
                [0, 0, 255, 255]
            } else {
                [255, 0, 0, 255]
            }
        });
        let jpeg = from_preview(&png).unwrap();
        assert!(jpeg.len() <= MAX_BYTES);
        assert_eq!(jpeg_markers(&jpeg).first(), Some(&0xe0), "JFIF first");
        assert!(!jpeg_markers(&jpeg).iter().any(|m| *m == 0xe1 || *m == 0xfe));
        let img = decode(&jpeg);
        assert_eq!(img.dimensions(), (512, 512));
        for (x, y) in [(5, 5), (506, 5), (256, 256), (5, 506)] {
            let p = img.get_pixel(x, y).0;
            assert!(
                p[2] > 200 && p[0] < 60,
                "({x},{y}) {p:?}: only the blue middle"
            );
        }
    }

    #[test]
    fn small_stays_small_and_alpha_goes_over_white() {
        let png = preview_png(100, 140, |_, _| [0, 0, 0, 0]);
        let img = decode(&from_preview(&png).unwrap());
        assert_eq!(img.dimensions(), (100, 100), "never enlarged");
        let p = img.get_pixel(50, 50).0;
        assert!(p.iter().all(|c| *c > 245), "transparent is white: {p:?}");
    }

    #[test]
    fn noise_still_fits() {
        // The worst case for JPEG: every pixel different. The size or the quality gives way, never the limit.
        let mut s = 0x1234_5678u32;
        let png = preview_png(512, 512, |_, _| {
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            let b = s.to_le_bytes();
            [b[0], b[1], b[2], 255]
        });
        let jpeg = from_preview(&png).unwrap();
        assert!(jpeg.len() <= MAX_BYTES, "{}", jpeg.len());
    }

    #[test]
    fn only_a_clean_image_of_an_allowed_type_is_accepted() {
        let png = preview_png(8, 8, |_, _| [9, 9, 9, 255]);
        let p = Preview {
            kind: PreviewKind::Image,
            text: None,
            images: vec![serde_bytes::ByteBuf::from(png)],
            truncated: false,
        };
        let mut r = CheckReport {
            verdict: Verdict::Clean,
            kind: crate::detect::Kind::Jpeg,
            mime: "image/jpeg".into(),
            findings: vec![],
            scanned_bytes: 10,
            engines: vec![],
            sandbox: String::new(),
            class: None,
            uninspected: false,
        };
        assert!(accepted(&r, Some(&p), &["image/jpeg"]).is_ok());
        assert_eq!(
            accepted(&r, Some(&p), &["image/png"]).unwrap_err().code,
            "not_an_image",
            "the declared type must be the detected one"
        );
        assert_eq!(
            accepted(&r, None, &["image/jpeg"]).unwrap_err().code,
            "not_an_image"
        );
        r.push(Finding::new(
            "polyglot",
            Severity::Warn,
            "zip after the image",
        ));
        assert_eq!(
            accepted(&r, Some(&p), &["image/jpeg"]).unwrap_err().code,
            "check_failed",
            "suspicious is not good enough for a picture"
        );
        let f = CheckReport::failed("sandbox_unavailable", "no landlock");
        assert_eq!(
            accepted(&f, None, &["image/jpeg"]).unwrap_err().code,
            "sandbox_unavailable"
        );
        let mut svg = CheckReport::failed("x", "y");
        svg.verdict = Verdict::Clean;
        svg.findings.clear();
        svg.mime = "image/svg+xml".into();
        assert_eq!(
            accepted(&svg, Some(&p), &["image/svg+xml"])
                .unwrap_err()
                .code,
            "not_an_image"
        );
    }

    #[test]
    fn a_png_that_this_daemon_did_not_make_is_refused() {
        // Not 8-bit RGBA: the rebuilt preview always is, so anything else did not come from `finalize`.
        let mut gray = Vec::new();
        image::GrayImage::new(4, 4)
            .write_to(&mut Cursor::new(&mut gray), image::ImageFormat::Png)
            .unwrap();
        assert_eq!(from_preview(&gray).unwrap_err().code, "not_an_image");
        assert_eq!(
            from_preview(b"\xff\xd8\xff").unwrap_err().code,
            "not_an_image"
        );
    }
}
