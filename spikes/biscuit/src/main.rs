// SPDX-License-Identifier: AGPL-3.0-only
//! Spike g): biscuit-auth 6.0: issue a token, attenuate it, verify offline;
//! holder-of-key: there is no built-in PoP, so we use a standard third-party block signed with the
//! holder's key over a fresh nonce (a challenge from the daemon). No custom cryptography: only the biscuit API.

use anyhow::{Result, bail};
use biscuit_auth::{
    Biscuit, KeyPair, ThirdPartyRequest,
    builder::{Algorithm, AuthorizerBuilder, BlockBuilder},
};

fn authorize(token: &Biscuit, op: &str, res: &str, extra_check: Option<String>) -> Result<(), String> {
    let mut b = AuthorizerBuilder::new()
        .time()
        .code(format!(
            r#"operation("{op}"); resource("{res}");
               allow if right($link, $op, $prefix), operation($op), resource($r), $r.starts_with($prefix);"#
        ))
        .map_err(|e| e.to_string())?;
    if let Some(c) = extra_check {
        b = b.check(c.as_str()).map_err(|e| e.to_string())?;
    }
    let mut a = b.build(token).map_err(|e| e.to_string())?;
    a.authorize().map(|_| ()).map_err(|e| format!("{e:?}"))
}

fn main() -> Result<()> {
    // Root issuing key (daemon, local) and the holder key (for example, an agent/link session key).
    let root = KeyPair::new_with_rng(Algorithm::Ed25519, &mut rand::rngs::OsRng);
    let holder = KeyPair::new_with_rng(Algorithm::Ed25519, &mut rand::rngs::OsRng);
    let holder_pk = holder.public().to_bytes_hex();

    // 1) Issue: level 3 = read+write in the link's shared/, 24 h.
    let token = Biscuit::builder()
        .code(
            r#"right("link-7f3a", "read", "shared/");
               right("link-7f3a", "write", "shared/");
               check if time($t), $t < 2099-01-01T00:00:00Z;"#,
        )?
        .build(&root)?;
    let b64 = token.to_base64()?;
    println!("1. issued token: {} bytes base64, {} block(s)", b64.len(), token.block_count());

    // 2) Offline verification with only the public root key.
    let parsed = Biscuit::from_base64(&b64, root.public())?;
    println!("2. read  shared/report.pdf: {:?}", authorize(&parsed, "read", "shared/report.pdf", None));
    println!("   write shared/report.pdf: {:?}", authorize(&parsed, "write", "shared/report.pdf", None));
    println!("   read  ../etc/passwd    : {}", authorize(&parsed, "read", "../etc/passwd", None).map(|_| "ALLOWED?!".into()).unwrap_or_else(|e| format!("denied ({})", e.split(',').next().unwrap_or(""))));

    // 3) Attenuation by the holder without contacting the issuer: read only.
    let narrowed = parsed.append(BlockBuilder::new().code(r#"check if operation("read");"#)?)?;
    println!("3. attenuated (read-only): read={:?}", authorize(&narrowed, "read", "shared/a", None).is_ok());
    let w = authorize(&narrowed, "write", "shared/a", None);
    println!("   attenuated write => {}", if w.is_ok() { "ALLOWED?!".to_string() } else { "denied".to_string() });
    if w.is_ok() {
        bail!("attenuation not enforced");
    }

    // 4) Holder-of-key through a third-party block (PoP over a fresh nonce).
    let nonce = "c0ffee-4f1d-request-hash-9a";
    let pop_check = format!(r#"check if pop("{nonce}") trusting ed25519/{holder_pk}"#);
    // 4a. A leaked token without proof of key possession.
    let r = authorize(&narrowed, "read", "shared/a", Some(pop_check.clone()));
    println!("4a. stolen token, no PoP: {}", if r.is_ok() { "ALLOWED?!" } else { "denied" });
    // 4b. The holder signs the third-party block with its key.
    let req = narrowed.third_party_request()?.serialize()?;
    let blk = ThirdPartyRequest::deserialize(&req)?
        .create_block(&holder.private(), BlockBuilder::new().fact(format!(r#"pop("{nonce}")"#).as_str())?)?;
    let with_pop = narrowed.append_third_party(holder.public(), blk)?;
    println!("4b. holder PoP: {:?}", authorize(&with_pop, "read", "shared/a", Some(pop_check.clone())));
    // 4c. PoP with someone else's key.
    let mallory = KeyPair::new_with_rng(Algorithm::Ed25519, &mut rand::rngs::OsRng);
    let req = narrowed.third_party_request()?.serialize()?;
    let blk = ThirdPartyRequest::deserialize(&req)?
        .create_block(&mallory.private(), BlockBuilder::new().fact(format!(r#"pop("{nonce}")"#).as_str())?)?;
    let fake = narrowed.append_third_party(mallory.public(), blk)?;
    let r = authorize(&fake, "read", "shared/a", Some(pop_check.clone()));
    println!("4c. PoP signed by other key: {}", if r.is_ok() { "ALLOWED?!" } else { "denied" });
    // 4d. Replay of an old PoP for a new nonce.
    let r = authorize(&with_pop, "read", "shared/a", Some(format!(r#"check if pop("new-nonce") trusting ed25519/{holder_pk}"#)));
    println!("4d. replay old PoP for new nonce: {}", if r.is_ok() { "ALLOWED?!" } else { "denied" });
    // 4e. A PoP block cannot be moved to another token (the third-party request is bound to the token signature).
    let other = Biscuit::builder().code(r#"right("link-7f3a", "write", "shared/");"#)?.build(&root)?;
    let req = narrowed.third_party_request()?.serialize()?;
    let blk = ThirdPartyRequest::deserialize(&req)?
        .create_block(&holder.private(), BlockBuilder::new().fact(format!(r#"pop("{nonce}")"#).as_str())?)?;
    match other.append_third_party(holder.public(), blk) {
        Ok(t) => {
            let r = authorize(&t, "write", "shared/a", Some(pop_check.clone()));
            println!("4e. PoP block moved to another token: {}", if r.is_ok() { "ALLOWED?!" } else { "denied at authorize" });
        }
        Err(e) => println!("4e. PoP block moved to another token: rejected at append ({e})"),
    }
    println!("DONE");
    Ok(())
}
