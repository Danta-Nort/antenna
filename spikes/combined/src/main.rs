// SPDX-License-Identifier: AGPL-3.0-only
//! Spike: the whole stack in one binary. We touch one symbol from each crate so that it gets linked.

fn main() {
    let ep_key = iroh::SecretKey::generate();
    let blob = iroh_blobs::Hash::new(b"x");
    let mut rng = rand_like();
    let id = libsignal_protocol::IdentityKeyPair::generate(&mut rng);
    #[cfg(feature = "xwing")]
    let pk_len = {
        let (_sk, pk) = libcrux_kem::key_gen(libcrux_kem::Algorithm::XWingKemDraft06, &mut libcrux_rng()).unwrap();
        pk.encode().len()
    };
    #[cfg(not(feature = "xwing"))]
    let pk_len = 0usize;
    let kp = biscuit_auth::KeyPair::new();
    // ML-DSA-65 (FIPS 204) for link-root/checkpoint signatures: the caller supplies randomness (OS RNG).
    use libcrux_ml_dsa::ml_dsa_65;
    let dsa = ml_dsa_65::generate_key_pair(rand09::random());
    let msg = b"checkpoint head 9f2c";
    let sig = ml_dsa_65::sign(&dsa.signing_key, msg, b"x-checkpoint-v0", rand09::random()).unwrap();
    let ok = ml_dsa_65::verify(&dsa.verification_key, msg, b"x-checkpoint-v0", &sig).is_ok();
    let wrong_ctx = ml_dsa_65::verify(&dsa.verification_key, msg, b"other-ctx", &sig).is_ok();
    let tampered = ml_dsa_65::verify(&dsa.verification_key, b"checkpoint head 0000", b"x-checkpoint-v0", &sig).is_ok();
    assert!(ok && !wrong_ctx && !tampered);
    let db = rusqlite::Connection::open_in_memory().unwrap();
    db.pragma_update(None, "key", "x'00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'").unwrap();
    let cv: String = db.query_row("PRAGMA cipher_version", [], |r| r.get(0)).unwrap();
    let mcp = rmcp::model::ProtocolVersion::LATEST;
    println!(
        "iroh id {} | blake3 {} | libsignal idk {}B | xwing pk {}B | biscuit pk {} | sqlcipher {cv} | mcp {mcp:?} | ml-dsa-65 vk {}B sig {}B verify ok, wrong ctx/tampered rejected",
        ep_key.public().fmt_short(),
        blob.fmt_short(),
        id.identity_key().serialize().len(),
        pk_len,
        &kp.public().to_bytes_hex()[..8],
        dsa.verification_key.as_ref().len(),
        sig.as_ref().len(),
    );
}

fn rand_like() -> impl rand09::CryptoRng {
    use rand09::TryRngCore;
    rand09::rngs::OsRng.unwrap_err()
}

#[cfg(feature = "xwing")]
fn libcrux_rng() -> impl rand010::CryptoRng {
    rand_core010::UnwrapErr(rand010::rngs::SysRng)
}
