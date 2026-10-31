// SPDX-License-Identifier: AGPL-3.0-only
//! Thin wrappers over established constructions (`docs/PROTOCOL.md` §2): HKDF-SHA256, HMAC-SHA256, SHA-256,
//! BLAKE3 `derive_key`, OS CSPRNG, constant-time comparison.
//!
//! No custom primitives here (SPEC §7, §15): only calls into `hkdf`, `hmac`, `sha2`, `blake3`, `subtle`, `rand`.

use hkdf::Hkdf;
use hmac::{Hmac, KeyInit, Mac};
use rand::{TryRngCore, rngs::OsRng};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

/// Secret 32 bytes, wiped on drop.
pub type Secret32 = Zeroizing<[u8; 32]>;

/// `n` bytes from the OS CSPRNG.
pub fn random<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    OsRng
        .try_fill_bytes(&mut b)
        .expect("OS RNG must be available");
    b
}

/// Secret 32 bytes from the OS CSPRNG.
pub fn random_secret() -> Secret32 {
    let mut s = Zeroizing::new([0u8; 32]);
    OsRng
        .try_fill_bytes(s.as_mut())
        .expect("OS RNG must be available");
    s
}

/// CSPRNG for the libsignal API (`rand` 0.9).
pub fn rng() -> impl rand::CryptoRng {
    OsRng.unwrap_err()
}

/// HKDF-SHA256 (RFC 5869): Extract + Expand into 32 bytes.
pub fn hkdf32(salt: &[u8], ikm: &[u8], info: &[&[u8]]) -> Secret32 {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = Zeroizing::new([0u8; 32]);
    hk.expand_multi_info(info, out.as_mut())
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    out
}

/// HKDF-SHA256 Extract: PRK.
pub fn hkdf_extract(salt: &[u8], ikm: &[u8]) -> Secret32 {
    let (prk, _) = Hkdf::<Sha256>::extract(Some(salt), ikm);
    let mut out = Zeroizing::new([0u8; 32]);
    out.copy_from_slice(&prk);
    out
}

/// HKDF-SHA256 Expand from a PRK into 32 bytes; `info` is the concatenation of the parts.
pub fn hkdf_expand(prk: &[u8; 32], info: &[&[u8]]) -> Secret32 {
    let hk = Hkdf::<Sha256>::from_prk(prk).expect("PRK of hash length");
    let mut out = Zeroizing::new([0u8; 32]);
    hk.expand_multi_info(info, out.as_mut())
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    out
}

/// HMAC-SHA256 over the concatenation of the parts.
pub fn hmac(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut m =
        <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC accepts any key length");
    for p in parts {
        m.update(p);
    }
    m.finalize().into_bytes().into()
}

/// SHA-256 over the concatenation of the parts.
pub fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

/// BLAKE3 in `derive_key` mode (domain separation by a context string).
pub fn blake3_dk(context: &str, data: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new_derive_key(context);
    h.update(data);
    *h.finalize().as_bytes()
}

/// Constant-time comparison (for equal lengths; different lengths give `false`).
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && bool::from(a.ct_eq(b))
}

/// `u32be(len(x)) ‖ x`.
pub fn lp(x: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(4 + x.len());
    v.extend_from_slice(&(x.len() as u32).to_be_bytes());
    v.extend_from_slice(x);
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        data_encoding::HEXLOWER.decode(s.as_bytes()).unwrap()
    }

    #[test]
    fn hkdf_rfc5869_test_case_1() {
        // RFC 5869, A.1 (first 32 bytes of the OKM)
        let ikm = hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
        let salt = hex("000102030405060708090a0b0c");
        let info = hex("f0f1f2f3f4f5f6f7f8f9");
        let okm = hkdf32(&salt, &ikm, &[&info[..5], &info[5..]]);
        assert_eq!(
            okm.as_slice(),
            hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf").as_slice()
        );
        let prk = hkdf_extract(&salt, &ikm);
        assert_eq!(
            prk.as_slice(),
            hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5").as_slice()
        );
        assert_eq!(hkdf_expand(&prk, &[&info]).as_slice(), okm.as_slice());
    }

    #[test]
    fn hmac_rfc4231_test_case_2() {
        let mac = hmac(b"Jefe", &[b"what do ya want ", b"for nothing?"]);
        assert_eq!(
            mac.to_vec(),
            hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        );
    }

    #[test]
    fn sha256_abc() {
        assert_eq!(
            sha256(&[b"a", b"bc"]).to_vec(),
            hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        );
    }

    #[test]
    fn ct_eq_and_lp_and_random() {
        assert!(ct_eq(b"abc", b"abc"));
        assert!(!ct_eq(b"abc", b"abd"));
        assert!(!ct_eq(b"abc", b"ab"));
        assert_eq!(lp(b"xy"), vec![0, 0, 0, 2, b'x', b'y']);
        assert_ne!(random::<32>(), random::<32>());
        assert_ne!(blake3_dk("ctx a", b"m"), blake3_dk("ctx b", b"m"));
    }
}
