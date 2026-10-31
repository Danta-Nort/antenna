// SPDX-License-Identifier: AGPL-3.0-only
//! STREAM and blob read throughput measurement (not a test): `cargo run --example bench_crypt`.
use antenna_files::crypt::*;
use std::time::Instant;

#[tokio::main]
async fn main() {
    let n = 64usize << 20;
    let plain: Vec<u8> = (0..n).map(|i| (i * 7) as u8).collect();
    let s = FileSecret::random();
    let t = Instant::now();
    let (ct, _) = encrypt_to_vec(&s, &plain).unwrap();
    println!("encrypt {} MiB: {:?}", n >> 20, t.elapsed());
    let t = Instant::now();
    let _ = decrypt_to_vec(&s, &ct).unwrap();
    println!("decrypt: {:?}", t.elapsed());
    let t = Instant::now();
    let _ = blake3::hash(&plain);
    println!("blake3: {:?}", t.elapsed());
    let dir = tempfile::tempdir().unwrap();
    let store = iroh_blobs::store::fs::FsStore::load(dir.path())
        .await
        .unwrap();
    let t = Instant::now();
    let tag = store.blobs().add_bytes(ct.clone()).await.unwrap();
    println!("import: {:?}", t.elapsed());
    let t = Instant::now();
    use tokio::io::AsyncReadExt;
    let mut r = store.blobs().reader(tag.hash);
    let mut buf = vec![0u8; 1 << 20];
    let mut total = 0;
    loop {
        let k = r.read(&mut buf).await.unwrap();
        if k == 0 {
            break;
        }
        total += k;
    }
    println!("reader 1MiB reads ({total} B): {:?}", t.elapsed());
    let t = Instant::now();
    let b = store.blobs().get_bytes(tag.hash).await.unwrap();
    println!("get_bytes ({}): {:?}", b.len(), t.elapsed());
}
