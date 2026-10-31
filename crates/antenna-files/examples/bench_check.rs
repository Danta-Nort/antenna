// SPDX-License-Identifier: AGPL-3.0-only
//! Sandboxed check of a large file, timing measurement (not a test): `cargo run --example bench_check -- <MiB> [text]`.
use std::time::Instant;

use antenna_files::sandbox::{Checker, CheckerConfig};

#[tokio::main]
async fn main() {
    let mib: u64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(64);
    let text = std::env::args().nth(2).is_some();
    let size = mib << 20;
    let worker =
        std::env::var("X_FILES_WORKER").expect("X_FILES_WORKER=<path to antenna-files-sandbox>");
    let mut cfg = CheckerConfig::new(worker);
    cfg.av = None;
    let (mut w, r) = tokio::io::duplex(4 << 20);
    let feeder = tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        let mut xof = blake3::Hasher::new_keyed(&[7; 32]).finalize_xof();
        let mut buf = vec![0u8; 1 << 20];
        let mut left = size;
        while left > 0 {
            let n = (left as usize).min(buf.len());
            if text {
                for (i, b) in buf[..n].iter_mut().enumerate() {
                    *b = b"lorem ipsum dolor sit amet\n"[i % 27];
                }
            } else {
                xof.fill(&mut buf[..n]);
            }
            w.write_all(&buf[..n]).await.unwrap();
            left -= n as u64;
        }
    });
    let t = Instant::now();
    let o = Checker::new(cfg)
        .check(r, size, if text { "big.txt" } else { "big.bin" }, true)
        .await;
    feeder.await.unwrap();
    println!(
        "{mib} MiB {}: {:?} in {:?}; findings {:?}",
        if text { "text" } else { "random" },
        o.report.verdict,
        t.elapsed(),
        o.report
            .findings
            .iter()
            .map(|f| &f.code)
            .collect::<Vec<_>>()
    );
}
