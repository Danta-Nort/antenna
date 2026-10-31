#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Independent check of the docs/PROTOCOL.md §7 test vectors (appendix A) using only the Python standard library.
# Run: python3 docs/protocol_vectors.py; the output must match the appendix A table and the test
# crates/antenna-core/src/pairing.rs::regression_vectors. This is a verification script, not part of the product.
import hashlib, hmac, struct
H=lambda *p: hashlib.sha256(b"".join(p)).digest()
mac=lambda k,*p: hmac.new(k,b"".join(p),hashlib.sha256).digest()
def extract(salt,ikm): return mac(salt,ikm)
def expand(prk,info,L=32):
    out=b"";t=b"";i=1
    while len(out)<L:
        t=mac(prk,t,info,bytes([i])); out+=t; i+=1
    return out[:L]
def hkdf(salt,ikm,info,L=32): return expand(extract(salt,ikm),info,L)
lp=lambda x: struct.pack(">I",len(x))+x
SUITE=b"x-pair/1;tls13:X25519MLKEM768;kdf:HKDF-SHA256;mac:HMAC-SHA256;hash:SHA-256;sig:Ed25519+ML-DSA-65;e2e:libsignal-PQXDH-MLKEM1024+SPQR"
V=1
KX=b"X25519MLKEM768"
s=b"\x11"*32; x=b"\x22"*32; ea=b"\x33"*32; eb=b"\x44"*32; na=b"\x55"*32; nb=b"\x66"*32
def party(b): return lp(bytes([b])*33)+bytes([b])*32+lp(bytes([b])*1952)+bytes([b])*32
# addrs(a) (§7): 0 for no relay, otherwise 1 ‖ lp(relay); then u32be(n) ‖ lp(d_1)…; the vectors have no relay, direct is empty
addrs_none=b"\x00"+struct.pack(">I",0)
kpsk=hkdf(b"x/pair/v0/psk-salt",s,b"x/pair/v0/psk-mac-key")
cb=H(b"x/pair/v0/commit",x,nb)
# v1 (F-3): psk_mac covers the whole M1 body: v, suite, C_B, P_B with addrs
print("psk_mac", mac(kpsk,b"x/pair/v1/psk-proof",x,ea,eb,struct.pack(">H",V),lp(SUITE),cb,party(0xb2),addrs_none).hex())
print("C_B",cb.hex())
th=H(b"x/pair/v0/transcript",struct.pack(">H",V),lp(SUITE),lp(KX),ea,eb,x,cb,na,nb,party(0xa1),party(0xb2)); print("TH",th.hex())
prk=extract(b"x/pair/v0/prk",x+s)
ka=expand(prk,b"x/pair/v0/key/A"+th); kb=expand(prk,b"x/pair/v0/key/B"+th)
print("K_A",ka.hex()); print("K_B",kb.hex()); print("link_id",expand(prk,b"x/pair/v0/link-id"+th).hex())
print("kc_B",mac(kb,b"x/pair/v0/key-confirm",th).hex())
d=hkdf(b"x/pair/v0/sas-salt",th,b"x/pair/v0/sas-digits",4)
print("SAS","%06d"%(struct.unpack(">I",d)[0]%1000000))
# Emoji representation of the same code (PROTOCOL §7, Q-6): digit → emoji by a fixed table
EMOJI=["\U0001F436","\U0001F431","\U0001F981","\U0001F40E","\U0001F984","\U0001F437","\U0001F418","\U0001F430","\U0001F43C","\U0001F413"]
sas="%06d"%(struct.unpack(">I",d)[0]%1000000)
print("SAS_emoji","".join(EMOJI[int(c)] for c in sas), " ".join("U+%04X"%ord(EMOJI[int(c)]) for c in sas))

# Appendix B (link format v1, slice 3): message signature, author chain, history fingerprint (PROTOCOL §12, §16).
# BLAKE3 and Ed25519 are not in the standard library: the `blake3` and `cryptography` packages are needed
# (for example: python3 -m pip install --target /tmp/pylib blake3 && PYTHONPATH=/tmp/pylib python3 docs/protocol_vectors.py).
try:
    import blake3
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
except ImportError as e:
    print("appendix B skipped:", e)
else:
    dk=lambda ctx,m: blake3.blake3(m, derive_key_context=ctx).digest()
    core=b"core-bytes-of-the-envelope"
    print("B.id", dk("x 2026-10-02 message-id v0", core).hex())
    seed=b"\x77"*32; link=b"\x33"*32; rcpt=b"\x44"*32; n=2
    sk=Ed25519PrivateKey.from_private_bytes(seed)
    pk=sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    m=b"x/link/v1/msg-sig"+link+rcpt+struct.pack(">Q",n)+lp(core)
    print("B.author", pk.hex())
    print("B.sig_msg_sha256", H(m).hex())
    print("B.sig", sk.sign(m).hex())
    c1=dk("x 2026-10-02 author-chain v1", b"\x00"*32+b"\x11"*32)
    c2=dk("x 2026-10-02 author-chain v1", c1+b"\x22"*32)
    print("B.chain1", c1.hex()); print("B.chain2", c2.hex())
    heads=sorted([b"\x55"*32, b"\x44"*32])
    f=dk("x 2026-10-02 history-fingerprint v1", link+b"".join(heads))
    v="%03d"%(struct.unpack(">I",f[:4])[0]%1000)
    print("B.fingerprint", v, "".join(EMOJI[int(c)] for c in v))
