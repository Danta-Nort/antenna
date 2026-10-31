// SPDX-License-Identifier: AGPL-3.0-only
//! Profile picture photos through the real sandboxed check (`antenna_files::picture`, PROTOCOL §25): metadata never
//! survives, the camera's orientation is applied, a malformed image or a file with something hidden after the image is
//! refused, and the output is made from pixels, never the original bytes.

mod common;

use antenna_files::picture::{MAX_BYTES, jpeg_markers, rebuild};
use image::{ImageEncoder, RgbImage, codecs::jpeg::JpegEncoder};

const JPEG: &[&str] = &["image/jpeg"];
const ANY: &[&str] = &[
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
    "image/bmp",
];

fn jpeg_of(img: &RgbImage) -> Vec<u8> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, 92)
        .write_image(
            img.as_raw(),
            img.width(),
            img.height(),
            image::ExtendedColorType::Rgb8,
        )
        .unwrap();
    out
}

/// An EXIF segment (APP1) with the orientation tag and a camera make that says where the photo was taken, and a
/// comment segment (COM), put right after SOI: what a phone photo carries.
fn with_metadata(jpeg: &[u8], orientation: u16) -> Vec<u8> {
    let make = b"SECRET-CAMERA at 55.75N 37.61E\0";
    let mut tiff = Vec::new();
    tiff.extend_from_slice(b"II*\0");
    tiff.extend_from_slice(&8u32.to_le_bytes());
    tiff.extend_from_slice(&2u16.to_le_bytes()); // two entries
    // 0x010F Make, ASCII, count, offset to the string after the IFD
    tiff.extend_from_slice(&0x010fu16.to_le_bytes());
    tiff.extend_from_slice(&2u16.to_le_bytes());
    tiff.extend_from_slice(&(make.len() as u32).to_le_bytes());
    tiff.extend_from_slice(&(8 + 2 + 2 * 12 + 4u32).to_le_bytes());
    // 0x0112 Orientation, SHORT, 1, value in place
    tiff.extend_from_slice(&0x0112u16.to_le_bytes());
    tiff.extend_from_slice(&3u16.to_le_bytes());
    tiff.extend_from_slice(&1u32.to_le_bytes());
    tiff.extend_from_slice(&orientation.to_le_bytes());
    tiff.extend_from_slice(&[0, 0]);
    tiff.extend_from_slice(&0u32.to_le_bytes()); // no next IFD
    tiff.extend_from_slice(make);
    let mut app1 = b"Exif\0\0".to_vec();
    app1.extend_from_slice(&tiff);
    let comment = b"SECRET-COMMENT shot by Alice";
    let mut out = jpeg[..2].to_vec();
    out.extend_from_slice(&[0xff, 0xe1]);
    out.extend_from_slice(&((app1.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(&app1);
    out.extend_from_slice(&[0xff, 0xfe]);
    out.extend_from_slice(&((comment.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(comment);
    out.extend_from_slice(&jpeg[2..]);
    out
}

fn has(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

fn decode(jpeg: &[u8]) -> RgbImage {
    image::load_from_memory_with_format(jpeg, image::ImageFormat::Jpeg)
        .unwrap()
        .to_rgb8()
}

/// A phone-like photo: 1600×1200, red left half, blue right half, EXIF orientation 6 (the camera was held upright, so
/// viewers turn it 90° clockwise: the red half is on top).
fn phone_photo() -> Vec<u8> {
    let img = RgbImage::from_fn(1600, 1200, |x, _| {
        if x < 800 {
            image::Rgb([220, 20, 20])
        } else {
            image::Rgb([20, 20, 220])
        }
    });
    with_metadata(&jpeg_of(&img), 6)
}

#[tokio::test]
#[cfg_attr(windows, ignore = "WP-19 (W3): the file check sandbox")]
async fn an_own_photo_loses_its_metadata_and_keeps_its_orientation() {
    let original = phone_photo();
    assert!(has(&original, b"SECRET-CAMERA") && has(&original, b"SECRET-COMMENT"));
    let pic = rebuild(&common::checker(), &original, "me.jpg", ANY)
        .await
        .expect("a clean photo");
    assert!(pic.len() <= MAX_BYTES, "{}", pic.len());
    assert_ne!(pic, original, "never the original bytes");
    assert!(!has(&pic, b"SECRET"), "no metadata text survives");
    let markers = jpeg_markers(&pic);
    assert!(
        !markers.iter().any(|m| *m == 0xe1 || *m == 0xfe),
        "no EXIF/XMP (APP1) or comment segment: {markers:x?}"
    );
    let img = decode(&pic);
    assert_eq!(img.dimensions(), (512, 512), "square, 512 px");
    // Turned upright, then the middle square: red on top, blue at the bottom (not red left, blue right).
    let top = img.get_pixel(470, 40).0;
    let bottom = img.get_pixel(40, 470).0;
    assert!(top[0] > 150 && top[2] < 90, "top right is red: {top:?}");
    assert!(
        bottom[2] > 150 && bottom[0] < 90,
        "bottom left is blue: {bottom:?}"
    );
}

#[tokio::test]
#[cfg_attr(windows, ignore = "WP-19 (W3): the file check sandbox")]
async fn a_malformed_image_is_refused() {
    let mut cut = jpeg_of(&RgbImage::from_pixel(64, 64, image::Rgb([1, 2, 3])));
    cut.truncate(cut.len() / 2);
    let e = rebuild(&common::checker(), &cut, "picture.jpg", JPEG)
        .await
        .unwrap_err();
    assert_eq!(e.code, "check_failed", "{e:?}");
    let e = rebuild(
        &common::checker(),
        b"\x89PNG\r\n\x1a\n not really",
        "picture.png",
        ANY,
    )
    .await
    .unwrap_err();
    assert_eq!(e.code, "check_failed", "{e:?}");
}

#[tokio::test]
#[cfg_attr(windows, ignore = "WP-19 (W3): the file check sandbox")]
async fn something_hidden_after_the_image_is_refused() {
    // A JPEG with a ZIP after its end: an image viewer shows the picture, an unzip tool finds the payload.
    let mut poly = jpeg_of(&RgbImage::from_pixel(64, 64, image::Rgb([1, 2, 3])));
    poly.extend_from_slice(b"PK\x03\x04\x14\x00\x00\x00\x00\x00payload.sh");
    poly.extend_from_slice(&[0u8; 64]);
    let e = rebuild(&common::checker(), &poly, "picture.jpg", JPEG)
        .await
        .unwrap_err();
    assert_eq!(e.code, "check_failed", "{e:?}");
}

/// Windows has no file check sandbox yet (WP-19, W3): even a clean photo is refused, never rebuilt unchecked.
#[cfg(windows)]
#[tokio::test]
async fn without_the_sandbox_a_photo_is_refused() {
    let e = rebuild(&common::checker(), &phone_photo(), "me.jpg", ANY)
        .await
        .unwrap_err();
    assert_eq!(e.code, "sandbox_unavailable", "{e:?}");
}

#[tokio::test]
#[cfg_attr(windows, ignore = "WP-19 (W3): the file check sandbox")]
async fn a_type_other_than_the_declared_one_is_refused() {
    // A contact declared JPEG but sent a PNG: the check compares the content with the name, the type with the list.
    let mut png = Vec::new();
    image::RgbImage::from_pixel(32, 32, image::Rgb([5, 5, 5]))
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    let e = rebuild(&common::checker(), &png, "picture.jpg", JPEG)
        .await
        .unwrap_err();
    assert!(matches!(e.code, "check_failed" | "not_an_image"), "{e:?}");
    // A non-image is never a picture, whatever it is called.
    let e = rebuild(
        &common::checker(),
        b"<svg xmlns='http://www.w3.org/2000/svg'/>",
        "picture.svg",
        ANY,
    )
    .await
    .unwrap_err();
    assert_eq!(e.code, "not_an_image", "{e:?}");
}
