// SPDX-License-Identifier: AGPL-3.0-only
//! Spike f): rusqlite 0.40 + SQLCipher (bundled, vendored OpenSSL).
//! Open the DB with a key, write, reopen with the right/wrong key, check that the file is encrypted.

use anyhow::{Result, bail};
use rusqlite::{Connection, params};

fn open(path: &std::path::Path, raw_key_hex: &str) -> Result<Connection> {
    let c = Connection::open(path)?;
    // Raw key (32 bytes hex), no PBKDF inside SQLCipher: we derive the DB key ourselves (Argon2id/TPM).
    c.pragma_update(None, "key", format!("x'{raw_key_hex}'"))?;
    Ok(c)
}

fn main() -> Result<()> {
    let dir = std::env::temp_dir().join(format!("x-spike-sqlcipher-{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("history.db");
    let key = "2b7e151628aed2a6abf7158809cf4f3c2b7e151628aed2a6abf7158809cf4f3c";
    {
        let c = open(&path, key)?;
        let v: String = c.query_row("PRAGMA cipher_version", [], |r| r.get(0))?;
        let p: String = c.query_row("PRAGMA cipher_provider", [], |r| r.get(0))?;
        let pv: String = c.query_row("PRAGMA cipher_provider_version", [], |r| r.get(0))?;
        let sv: String = c.query_row("select sqlite_version()", [], |r| r.get(0))?;
        println!("cipher_version={v} provider={p} {pv} sqlite={sv}");
        c.execute_batch("CREATE TABLE msg(id BLOB PRIMARY KEY, body TEXT); PRAGMA journal_mode=WAL;")?;
        c.execute("INSERT INTO msg VALUES (?1, ?2)", params![vec![1u8; 32], "secret message"])?;
    }
    let raw = std::fs::read(&path)?;
    let plain_header = raw.starts_with(b"SQLite format 3\0");
    let leaks = raw.windows("secret message".len()).any(|w| w == b"secret message");
    println!("file {} bytes; plain SQLite header: {plain_header}; plaintext found in file: {leaks}", raw.len());
    if plain_header || leaks {
        bail!("db file is not encrypted!");
    }
    {
        let c = open(&path, key)?;
        let body: String = c.query_row("SELECT body FROM msg", [], |r| r.get(0))?;
        println!("reopen with right key: {body:?}");
    }
    {
        let c = open(&path, "00000000000000000000000000000000000000000000000000000000000000ff")?;
        match c.query_row("SELECT count(*) FROM msg", [], |r| r.get::<_, i64>(0)) {
            Ok(_) => bail!("wrong key accepted!"),
            Err(e) => println!("reopen with wrong key: rejected ({e})"),
        }
    }
    {
        // rekey (changing the DB key, for example after a password/TPM wrapping change)
        let c = open(&path, key)?;
        c.pragma_update(None, "rekey", "x'1111111111111111111111111111111111111111111111111111111111111111'")?;
        drop(c);
        let c = open(&path, "1111111111111111111111111111111111111111111111111111111111111111")?;
        let n: i64 = c.query_row("SELECT count(*) FROM msg", [], |r| r.get(0))?;
        println!("rekey OK, rows={n}");
    }
    std::fs::remove_dir_all(&dir)?;
    println!("DONE");
    Ok(())
}
