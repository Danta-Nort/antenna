// SPDX-License-Identifier: AGPL-3.0-only
//! Spike d): hybrid KEM X25519 + ML-KEM-768 without custom cryptography.
//! - libcrux-kem 0.0.9: Algorithm::XWingKemDraft06 (X-Wing, draft-connolly-cfrg-xwing-kem-06),
//!   inside: the formally verified libcrux ML-KEM-768, X25519 (HACL*), SHA3-256 (the combiner).
//! - x-wing 0.1.1 (RustCrypto, also draft-06): only as an independent implementation for cross-checking.
//! We check: encaps/decaps in libcrux, byte-for-byte compatibility with RustCrypto x-wing in both directions,
//! rejection on a substituted ciphertext (implicit rejection => a different secret), behavior on garbage.

use libcrux_kem::{Algorithm, Ct, PublicKey, key_gen, key_gen_derand};
use rand::{RngExt, rngs::SysRng};
use rand_core::UnwrapErr;
use x_wing::kem::{Decapsulate, Decapsulator, Encapsulate, KeyExport};

fn main() {
    let mut rng = UnwrapErr(SysRng);

    // 1) libcrux X-Wing: encaps/decaps
    let (sk, pk) = key_gen(Algorithm::XWingKemDraft06, &mut rng).expect("keygen");
    let pk_bytes = pk.encode();
    let pk2 = PublicKey::decode(Algorithm::XWingKemDraft06, &pk_bytes).expect("decode pk");
    let (ss_b, ct) = pk2.encapsulate(&mut rng).expect("encaps");
    let ct_bytes = ct.encode();
    let ss_a = Ct::decode(Algorithm::XWingKemDraft06, &ct_bytes)
        .expect("decode ct")
        .decapsulate(&sk)
        .expect("decaps");
    assert_eq!(ss_a.encode(), ss_b.encode());
    println!(
        "1. libcrux X-Wing OK: pk={}B sk(seed)={}B ct={}B ss={}B",
        pk_bytes.len(),
        sk.encode().len(),
        ct_bytes.len(),
        ss_a.encode().len()
    );

    // 2) Byte-for-byte compatibility with the independent RustCrypto x-wing implementation (draft-06).
    let seed: [u8; 32] = rng.random();
    let (lc_sk, lc_pk) = key_gen_derand(Algorithm::XWingKemDraft06, &seed).expect("derand");
    let rc_sk = x_wing::DecapsulationKey::from(seed);
    let rc_pk = rc_sk.encapsulation_key().clone();
    let rc_pk_bytes = rc_pk.to_bytes();
    assert_eq!(lc_pk.encode().as_slice(), rc_pk_bytes.as_slice(), "public keys differ");
    println!("2a. same 32-byte seed => identical 1216-byte encapsulation keys in libcrux and RustCrypto");

    // RustCrypto encaps -> libcrux decaps
    let (rc_ct, rc_ss) = rc_pk.encapsulate_with_rng(&mut rng);
    let lc_ss = Ct::decode(Algorithm::XWingKemDraft06, rc_ct.as_slice())
        .expect("decode rc ct")
        .decapsulate(&lc_sk)
        .expect("decaps");
    assert_eq!(lc_ss.encode().as_slice(), rc_ss.as_slice());
    println!("2b. RustCrypto encapsulate -> libcrux decapsulate: shared secrets equal");

    // libcrux encaps -> RustCrypto decaps
    let (lc_ss2, lc_ct2) = lc_pk.encapsulate(&mut rng).expect("encaps");
    let ct_arr = x_wing::Ciphertext::try_from(lc_ct2.encode().as_slice()).expect("ct len");
    let rc_ss2 = rc_sk.decapsulate(&ct_arr);
    assert_eq!(lc_ss2.encode().as_slice(), rc_ss2.as_slice());
    println!("2c. libcrux encapsulate -> RustCrypto decapsulate: shared secrets equal");

    // 3) Substituted ciphertext: ML-KEM implicit rejection => a different secret (not an error!).
    let mut bad = ct_bytes.clone();
    bad[100] ^= 1;
    let ss_bad = Ct::decode(Algorithm::XWingKemDraft06, &bad)
        .expect("decode")
        .decapsulate(&sk)
        .expect("decaps returns Ok with a pseudo-random secret");
    assert_ne!(ss_bad.encode(), ss_a.encode());
    println!("3. tampered ML-KEM part of ct: decapsulate returns Ok but a DIFFERENT secret (implicit rejection) => key confirmation MAC is mandatory");
    let mut bad_x = ct_bytes.clone();
    let n = bad_x.len();
    bad_x[n - 1] ^= 1;
    let ss_bad_x = Ct::decode(Algorithm::XWingKemDraft06, &bad_x)
        .expect("decode")
        .decapsulate(&sk);
    match ss_bad_x {
        Ok(s) => assert_ne!(s.encode(), ss_a.encode()),
        Err(e) => println!("   tampered X25519 part: error {e:?}"),
    }
    println!("   tampered X25519 part of ct: secret differs as well");

    // 4) Garbage input: a short public key.
    let short = vec![0u8; 100];
    let r = std::panic::catch_unwind(|| PublicKey::decode(Algorithm::XWingKemDraft06, &short));
    match r {
        Ok(Ok(_)) => println!("4. short pk accepted?!"),
        Ok(Err(e)) => println!("4. short pk rejected with error {e:?}"),
        Err(_) => println!("4. GRABLE: PublicKey::decode(XWing, 100 bytes) PANICS (no length check) => check len == 1216 before decode"),
    }
    let r = std::panic::catch_unwind(|| Ct::decode(Algorithm::XWingKemDraft06, &short));
    match r {
        Ok(Ok(_)) => println!("   short ct accepted?!"),
        Ok(Err(e)) => println!("   short ct rejected with error {e:?}"),
        Err(_) => println!("   GRABLE: Ct::decode(XWing, 100 bytes) PANICS => check len == 1120 before decode"),
    }
    println!("DONE");
}
