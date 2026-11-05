<!-- SPDX-License-Identifier: Apache-2.0 -->
# Antenna protocol v0: pairing and link format

> The product is called **Antenna** (until 2026-10-02 the working name was `x`). All wire labels stay as they were: ALPN
> `x/pair/0` and `x/link/0`, the HKDF/BLAKE3/signature domains `x/pair/v0/…`, `x/link/v1/…`, `x/file/v0/…`, `x/device/v0/…`,
> the contexts `x 2026-10-02 …`, the suite string `x-pair/1;…`. They are part of keys, MACs, signatures,
> test vectors (appendices A, B) and the formal model (`formal/`). Since 2026-10-03 the invite link is issued as a web address
> `https://antenna.contact/#…` (§3, D-74); `x://pair#` is only accepted. Changing wire labels is a new protocol version,
> not a rename (DECISIONS D-57).

Status: **draft, pairing v1, link format v1** (not frozen), v0.1 MVP, 2026-10-02. Pairing v1 (slice 2): `psk_mac`
covers the whole body of M1 (refinement F-3 from the formal model); everything else is as in v0 of slice 1. v0 and v1 nodes do not pair
(`abort{"version"}`). Link format v1 (slice 3): message signatures, author counter, history verification, receipts, rekey
after rollback (§12, §16–§18); not compatible with format v0 nodes (`routing-blob.v` = 1). Slice 4: files: message types
`file` and `request`, the manifest, the `xfile/0` cipher, link blobs (§19); a node without §19 rejects such messages (`bad_request`).
v0.2: streaming messages (§20): a `stream_open` link request and chunks on the same QUIC stream; only the final message goes into the history,
an ordinary `text`, so a node without §20 simply receives the final message (it answers `stream_open` with `rejected`, and the sender does not
stream). A side's agents (§21): the `features` request, the `control`/`agent` message and `author` = the agent's key, only to nodes
that answered `agents/0`; nothing new is sent to a node without §21 (`0.1.0-preview.1`). LAN (§22): discovery
via mDNS with link aliases; it does not change the link format. Addressing and topics (§23): optional `to` and
`topic` in `envelope-core`, only to nodes that answered `addr/0`; nothing new is sent to a node without §23
(`0.1.0-preview.3` and older). Withdrawing a file offer (§19): a `withdraw_file` / `withdrawn` receipt, only to nodes that answered
`file-withdraw/0` (`0.1.0-preview.4` and older get none). A message for an agent the recipient does not have (§23): a
`deliver` / `no_such_agent` receipt, only to nodes that answered `no-agent/0` (`0.1.0-preview.8` and older get none).
Own devices (§24): a `device` link request outside the history between contacts at level 5 both ways, only to nodes
that answered `device/0` (experimental). Profile pictures (§25): a `control`/`picture` message from a side's link-root,
only to nodes that answered `picture/0` (`0.1.0-preview.8` and older get none). The writing agent's name in a stream
opening (§20): `agent` in `stream-open`, only to nodes that answered `stream-agent/0` (`0.1.0-preview.8` and older get
the opening without it). The address of a file offer (§19, §23): `to` in the `core` of a `file` message, only to nodes
that answered `file-addr/0`. The number a received file's name got when its name was taken (§19, D-128): `name_number`
in an `accept_file` / `accepted` receipt, only to nodes that answered `file-saved-as/0` (`0.1.0-preview.8` builds
before it get the receipt without it).
License: Apache-2.0 (SPEC §16): this document is enough to write an independent implementation and a formal model
(ProVerif/Tamarin, SPEC §15). The reference implementation is `crates/antenna-proto` (formats) and `crates/antenna-core` (`pairing.rs`,
`e2e.rs`, `transport.rs`, `history.rs`).

This document refines SPEC §4–§8, taking into account maintainer decisions Q-1, Q-2, Q-4, Q-5 and decisions D-5…D-8, D-13… (`docs/DECISIONS.md`).
If the code and this document disagree, that is a bug; whichever is wrong gets fixed, and `DECISIONS.md` records why.

---

## 0. Notation

| Notation | Meaning |
| --- | --- |
| A | The inviting node (`antenna invite`) |
| B | The joining node (`antenna join`) |
| `a ‖ b` | Concatenation of byte strings |
| `u16be(n)`, `u32be(n)` | Unsigned integer, big-endian, 2 / 4 bytes |
| `lp(x)` | `u32be(len(x)) ‖ x`: a length-prefixed string |
| `"..."` | An ASCII string without a terminating zero (a domain separation label) |
| `HKDF(salt, ikm, info, L)` | HKDF-SHA256, RFC 5869 (Extract + Expand) |
| `HKDF-Extract(salt, ikm)`, `HKDF-Expand(prk, info, L)` | The individual steps of RFC 5869 |
| `HMAC(k, m)` | HMAC-SHA256, RFC 2104, 32-byte output |
| `H(m)` | SHA-256, FIPS 180-4 |
| `BLAKE3-DK(ctx, m)` | BLAKE3 in `derive_key` mode with the context string `ctx`, 32-byte output |
| `ct_eq(a, b)` | Constant-time comparison |
| `rand(n)` | n bytes from the OS CSPRNG |
| base32 | RFC 4648 §6, lowercase alphabet, without `=`; case-insensitive when parsing |
| base64url | RFC 4648 §5, without `=` |
| CBOR | RFC 8949; the schemas below are CDDL (RFC 8610). Structures are encoded as maps with text keys |

All lengths are in bytes. All comparisons of secret values (MACs, codes, commitments) use `ct_eq`.

## 1. Overview

```
 A (antenna invite)                                             B (antenna join <link>)
 ek_A, s := rand(32), E_A := pub(ek_A)
 link https://antenna.contact/#E_A.s.relay ── out of band (messenger, QR, in person) ──▶
                         QUIC/TLS 1.3 (X25519MLKEM768), ALPN x/pair/0, B → E_A
                         X := TLS-Exporter("EXPORTER-x-pair-v0", "", 32)
      ◀── M1 join{v, suite, psk_mac, C_B, P_B} ─────────────  C_B = H(L_COMMIT ‖ X ‖ N_B)
 check psk_mac (5 failures → the invite burns); after that any error burns the invite
      ── M2 offer{P_A, N_A} ───────────────────────────────▶
                                                            TH, PRK, K_A, K_B
      ◀── M3 reveal{N_B, kc_B} ─────────────────────────────
 check C_B, TH, kc_B
      ── M4 key_confirm{kc_A} ──────────────────────────────▶ check kc_A
 SAS(TH) is shown to owner A,                               owner B enters the code,
 A reads the code out by voice                              node B checks ct_eq(code, SAS(TH))
      ◀── M5 code_entered{mac_B} ───────────────────────────  (wrong → abort, the invite burns)
 owner A confirms on their side after hearing "it matched" from B
      ── M6 confirmed{mac_A, bundle_A} ─────────────────────▶ PQXDH (process_prekey_bundle)
      ◀── M7 session_init{PreKeySignalMessage(L_INIT ‖ TH)} ─
 decrypt, link A active
      ── M8 done{SignalMessage(L_ACK ‖ TH)} ────────────────▶ decrypt, link B active
 ephemeral endpoints are destroyed; from here on: pairwise endpoints E'_A ↔ E'_B, ALPN x/link/0, Triple Ratchet
```

## 2. Primitives and where they come from

There are no custom cryptographic primitives (SPEC §7, §15). The protocol only **combines** existing
constructions; every place where they are combined is listed in §14, which is the input for the formal model.

| Purpose | Construction | Crate (version) |
| --- | --- | --- |
| Pairing and link channel | QUIC + TLS 1.3, raw public key Ed25519 (EndpointId), group `X25519MLKEM768` | iroh 1.3.0 → noq 1.3.0 → rustls 0.23 + aws-lc-rs |
| Channel binding | TLS 1.3 Exporter, RFC 8446 §7.5 | rustls |
| KDF | HKDF-SHA256 | `hkdf` 0.13 + `sha2` 0.11 |
| MAC | HMAC-SHA256 | `hmac` 0.13 |
| Transcript hash and commitment | SHA-256 | `sha2` 0.11 |
| Message ID | BLAKE3 `derive_key` | `blake3` 1.8 |
| Link-root keys (pinned at pairing). Ed25519 signs messages (§12) and the rekey offer (§17); the hybrid with ML-DSA-65 signs checkpoints (v0.2) | Ed25519 (RFC 8032, verified with `verify_strict`) + ML-DSA-65 (FIPS 204) | `ed25519-dalek` 3.0.0, `libcrux-ml-dsa` 0.0.10 |
| E2E | libsignal PQXDH (KEM prekey ML-KEM-1024, FIPS 203) + Double Ratchet + SPQR (ML-KEM-768) = Triple Ratchet, session version 4 | `libsignal-protocol` rev `e8cc2ddd` (v0.103.1), `spqr` v1.6.0 |
| Device key on disk (local, not protocol) | Argon2id → ChaCha20-Poly1305; HKDF → SQLCipher key | `argon2` 0.6, `chacha20poly1305` 0.11 |

The X25519 + ML-KEM-768 hybrid at pairing comes from the TLS 1.3 transport, not from a separate KEM (decision Q-2).
That is why SPEC §6 items 4–5 are refined: a random nonce is committed, not a key share (the SAS-MCA scheme, Vaudenay 2005).

## 3. Invite link

```
https://antenna.contact/#<E_A>.<s>.<relay>[.<direct>]      — issued by the node (D-74)
antenna://pair#<E_A>.<s>.<relay>[.<direct>]                — the same link for the app (preview.1 nodes understand it too)
x://pair#<E_A>.<s>.<relay>[.<direct>]                      — historical form: only accepted (D-57)
```

The link body `<E_A>.<s>.<relay>[.<direct>]` is the same in all forms; the prefix is not part of the cryptography (neither of `psk_mac` nor of
`TH`), so the test vectors of appendix A do not depend on the form of the link.

| Field | Contents | Encoding | Length in the link |
| --- | --- | --- | --- |
| `E_A` | EndpointId of the invite's ephemeral endpoint: an Ed25519 public key, 32 bytes | base32 | 52 characters |
| `s` | The link's one-time secret, `rand(32)` | base32 | 52 characters |
| `relay` | URL of the relay where `E_A` sits (UTF-8, `https://…` or `http://…`), or empty | base64url | 0…512 |
| `direct` | Optional. A comma-separated list of `ip:port` (UTF-8) | base64url | ≤ 512 |

Rules:
- The node issues the web address `https://antenna.contact/#<body>` (D-74) and next to it `antenna://pair#<body>` (in the output of
  `antenna invite`, in the `invite_created.link_app` event and in `pairings`): `0.1.0-preview.1` nodes parse only
  `x://pair#` and `antenna://pair#`, so the second form is for them. The parser (`antenna_proto::invite`) accepts all three
  forms, and also `https://antenna.contact#` (without `/`), the scheme and domain in any case, a nested scheme
  (`https://antenna.contact/#antenna://pair#…`, which the site accepts too) and spaces and line breaks inside (a mail client
  wraps the link). Another domain, `http://`, or a path before `#` is a rejection.
- Everything after `#` is the fragment: the browser does not send it to the server; the site reads it only in the browser, without external
  requests, and erases it from the address bar (`docs/SITE.md` "Invite link handler"). The site's server never sees the link.
- The separator is `.`; it occurs in neither base32 nor base64url.
- `relay` is empty only if A has its relay turned off (tests, LAN). Then `direct` is mandatory.
- `direct` is present **only** when the relay is turned off. With a relay, IP addresses do not go into the link: the link travels
  through third-party channels and would reveal the inviter's IP (SPEC §4).
- The total link length is ≤ 1024 characters. `E_A` must be a valid Ed25519 point, `s` exactly 32 bytes.
- The link does not contain a protocol version: the version is negotiated in M1 and is part of the transcript.

## 4. The invite's ephemeral endpoint and limits

- A creates a fresh key `ek_A` and an endpoint with ALPN `x/pair/0`. If the relay is on, the endpoint works **only through the relay**
  (no IP transports): before the SAS check neither A nor B sees the other's IP. To connect, B also creates a fresh ephemeral
  endpoint `ek_B` (`E_B`), unrelated to its future pairwise endpoint.
- The ephemeral endpoint has no accept-list (B's key is not known in advance); protection comes from the link's secret and limits:
  - **TTL**: 10 minutes by default (`--ttl`), at most 24 hours. When it expires, the endpoint is closed.
  - **One session**: while a pairing session is in progress, new connections are refused without a handshake (QUIC refuse).
  - **Attempts**: a wrong `psk_mac`, a foreign version/suite, a non-PQ TLS group, garbage instead of M1 is a failed attempt.
    After **5** failed attempts the invite burns.
  - **One-time use**: after a correct `psk_mac` the invite counts as used. Any outcome other than success
    (wrong SAS, owner refusal, timeout, protocol error, disconnect) burns it. So does success.
  - A burned invite: the endpoint is closed, `ek_A` and `s` are erased from memory. A repeated `antenna join` with the same
    link cannot even establish a connection.
- The invite lives **in the daemon** until its TTL (maintainer decision Q-7), not while `antenna invite` is open: side A is driven by a background
  task in the daemon, and the client only watches it. Owner A sees the stage and the SAS code in `antenna pairing`, confirms the link with a separate
  command `antenna pairing confirm <id>` (owner password) and can burn the invite with `antenna pairing cancel <id>`. The confirmation
  is accepted only after a correct M5 (step A9); a "yes" sent in advance does not count. If several invites are waiting for
  confirmation, the interface shows the code and the label next to the confirmation, and `--code` binds "it matched" to the code of that particular
  invite (see §15). `antenna lock` aborts all invites. Control commands: `docs/CONTROL.md` §6.

## 5. Pairing transport

- B connects to `E_A` at the addresses from the link (`relay`, `direct`), ALPN `x/pair/0`. Address lookup (DNS/pkarr/mDNS) is not used.
- After the handshake both sides check the negotiated TLS group: it must be `X25519MLKEM768`. Otherwise the connection
  is closed with code `2`; for A this is a failed attempt. The group name is part of the transcript (`kx_group`).
- Both sides compute `X = TLS-Exporter(label = "EXPORTER-x-pair-v0", context = "" (empty), L = 32)`.
- All pairing messages go over a single bi-stream, opened by B. Frame: `u32be(len) ‖ CBOR(msg)`, `len ≤ 65536`.
- The timeout for an automatic step is 30 s. Waiting for a person (code entry on B, confirmation on A) lasts until the end of the invite's
  TTL (on B, no longer than 10 minutes). The connection is kept up by QUIC keep-alive.

## 6. Pairing messages (CDDL)

```cddl
pair-msg = { "join": join } / { "offer": offer } / { "reveal": reveal }
         / { "key_confirm": key-confirm } / { "code_entered": code-entered }
         / { "confirmed": confirmed } / { "session_init": session-init }
         / { "done": done } / { "abort": abort }

join = {                         ; M1, B → A
  "v": uint,                     ; pairing version, currently 1
  "suite": tstr,                 ; SUITE, §7
  "psk_mac": bstr .size 32,
  "commit": bstr .size 32,       ; C_B
  "party": party,                ; P_B
}
offer = { "party": party, "nonce": bstr .size 32 }            ; M2, A → B (P_A, N_A)
reveal = { "nonce": bstr .size 32, "kc": bstr .size 32 }       ; M3, B → A (N_B, kc_B)
key-confirm = { "kc": bstr .size 32 }                          ; M4, A → B (kc_A)
code-entered = { "mac": bstr .size 32 }                        ; M5, B → A
confirmed = { "mac": bstr .size 32, "bundle": bundle }         ; M6, A → B
session-init = { "ct": bstr }                                  ; M7, B → A: libsignal PreKeySignalMessage
done = { "ct": bstr }                                          ; M8, A → B: libsignal SignalMessage
abort = { "reason": tstr }    ; "version" / "suite" / "auth" / "commit" / "key_confirm" / "sas_mismatch"
                              ; / "owner_rejected" / "timeout" / "protocol" / "busy" / "internal"

party = {
  "identity_key": bstr .size 33,    ; libsignal IdentityKey of this link (0x05 ‖ Curve25519)
  "root_ed25519": bstr .size 32,    ; link-root, the Ed25519 part
  "root_mldsa65": bstr .size 1952,  ; link-root, the ML-DSA-65 part (verification key)
  "endpoint": bstr .size 32,        ; EndpointId of this side's future pairwise endpoint
  "addrs": addrs,                   ; route hints for the pairwise endpoint (not part of TH, §7);
                                    ; if the side has a relay, only the relay; direct is empty (no IP revealed before the SAS)
}
addrs = { "relay": tstr / null, "direct": [* tstr] }   ; direct is "ip:port"; empty in "relay only" mode

bundle = {                          ; side A's libsignal prekey bundle
  "registration_id": uint, "identity_key": bstr .size 33,
  "prekey_id": uint, "prekey": bstr .size 33,
  "signed_prekey_id": uint, "signed_prekey": bstr .size 33, "signed_prekey_sig": bstr .size 64,
  "kyber_prekey_id": uint, "kyber_prekey": bstr .size 1569, "kyber_prekey_sig": bstr .size 64,
}
```

Unknown fields and extra bytes after the CBOR are a `protocol` error. Every `bstr .size N` is checked before use.

## 7. Computations

Constants:

```
SUITE = "x-pair/1;tls13:X25519MLKEM768;kdf:HKDF-SHA256;mac:HMAC-SHA256;hash:SHA-256;sig:Ed25519+ML-DSA-65;e2e:libsignal-PQXDH-MLKEM1024+SPQR"
KX    = "X25519MLKEM768"
```

| Symbol | Definition |
| --- | --- |
| `K_psk` | `HKDF(salt = "x/pair/v0/psk-salt", ikm = s, info = "x/pair/v0/psk-mac-key", L = 32)` |
| `psk_mac` | `HMAC(K_psk, "x/pair/v1/psk-proof" ‖ X ‖ E_A ‖ E_B ‖ u16be(v) ‖ lp(suite) ‖ C_B ‖ party(P_B) ‖ addrs(P_B.addrs))`: the whole body of M1 except `psk_mac` itself (v1, F-3); `v`, `suite`, `C_B`, `P_B` as in M1 |
| `addrs(a)` | `0x00` if `a.relay = null`, otherwise `0x01 ‖ lp(utf8(a.relay))`; then `u32be(n) ‖ lp(utf8(d_1)) ‖ … ‖ lp(utf8(d_n))` for `a.direct` |
| `N_A`, `N_B` | `rand(32)` on each side, fresh for every session |
| `C_B` | `H("x/pair/v0/commit" ‖ X ‖ N_B)` |
| `party(P)` | `lp(P.identity_key) ‖ P.root_ed25519 ‖ lp(P.root_mldsa65) ‖ P.endpoint` |
| `TH` | `H("x/pair/v0/transcript" ‖ u16be(v) ‖ lp(SUITE) ‖ lp(KX) ‖ E_A ‖ E_B ‖ X ‖ C_B ‖ N_A ‖ N_B ‖ party(P_A) ‖ party(P_B))` |
| `PRK` | `HKDF-Extract(salt = "x/pair/v0/prk", ikm = X ‖ s)` |
| `K_A` | `HKDF-Expand(PRK, "x/pair/v0/key/A" ‖ TH, 32)` |
| `K_B` | `HKDF-Expand(PRK, "x/pair/v0/key/B" ‖ TH, 32)` |
| `link_id` | `HKDF-Expand(PRK, "x/pair/v0/link-id" ‖ TH, 32)` |
| `kc_A`, `kc_B` | `HMAC(K_A, "x/pair/v0/key-confirm" ‖ TH)`, `HMAC(K_B, "x/pair/v0/key-confirm" ‖ TH)` |
| `mac_B` (M5) | `HMAC(K_B, "x/pair/v0/code-entered" ‖ TH)` |
| `mac_A` (M6) | `HMAC(K_A, "x/pair/v0/owner-confirmed" ‖ TH)` |
| `SAS` | `u32be⁻¹(HKDF(salt = "x/pair/v0/sas-salt", ikm = TH, info = "x/pair/v0/sas-digits", L = 4)) mod 10⁶`, 6 digits with leading zeros |
| `L_INIT`, `L_ACK` | `"x/pair/v0/session-init"`, `"x/pair/v0/session-ack"` |

All fields in `TH` have a fixed length except those wrapped in `lp`, so parsing is unambiguous. In M1/M2 `addrs.direct` is filled in
only when the relay is off (tests, LAN); with a relay, the contact learns the side's direct addresses in "direct" mode after activation
from the `hello` frame. `addrs` is not part of `TH`:
these are route hints, not identity; on an established link they are updated by the `hello` frame (§12).
Substituting `addrs` only gives a denial of service, which a network attacker can cause anyway.

**Emoji are another representation of the same code** (SPEC §6 item 8, maintainer decision Q-6). Each digit of `SAS` in order is replaced by
an emoji from the table (the first ten emoji of the SAS Matrix table; all are animals, easy to name by voice). The entropy is the same (10⁶),
`TH` and the computations do not change: the sides compare digits.

| Digit | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Emoji | 🐶 U+1F436 | 🐱 U+1F431 | 🦁 U+1F981 | 🐎 U+1F40E | 🦄 U+1F984 | 🐷 U+1F437 | 🐘 U+1F418 | 🐰 U+1F430 | 🐼 U+1F43C | 🐓 U+1F413 |
| Name (English / Russian) | dog / собака | cat / кошка | lion / лев | horse / лошадь | unicorn / единорог | pig / свинья | elephant / слон | rabbit / кролик | panda / панда | rooster / петух |

Owner B can enter the code as digits, as these emoji (one code point; U+FE0F after an emoji is ignored) or as names
(in English or Russian, case-insensitive); space, `-`, `,`, `.` are separators. Node B reduces the input to 6 digits; any other character or not exactly
6 digits means the input did not match (`sas_mismatch`). Reference: `crates/antenna-proto/src/sas.rs`.

## 8. Protocol steps

### A (inviter)

1. Create `ek_A`, `s`; bring up the ephemeral endpoint (§4); give the link to the owner.
2. Accept a connection (while a session is in progress, other connections are refused without a handshake). Check the TLS group (§5), compute `X`.
3. Read M1. `v ≠ 1` → `abort{"version"}`; `suite ≠ SUITE` → `abort{"suite"}`; `!ct_eq(psk_mac, expected)` → `abort{"auth"}`,
   where the expected value is computed over the fields of the **received** M1 (§7).
   Each of these cases is a failed attempt (5 → burns), after which A waits for the next connection.
4. From this point on the invite is used. Check the fields of `P_B` (lengths; `identity_key` is parsed by libsignal;
   `root_ed25519` and `endpoint` are valid Ed25519 points). Error → `abort{"protocol"}`, the invite burns.
5. Generate for the link: a libsignal `IdentityKeyPair` and registration id; link-root Ed25519 and ML-DSA-65; the pairwise endpoint key `ek'_A`.
   Send M2 `offer{P_A, N_A}`.
6. Read M3. Check `ct_eq(H("x/pair/v0/commit" ‖ X ‖ N_B), C_B)` → otherwise `abort{"commit"}`.
   Compute `TH`, `PRK`, `K_A`, `K_B`; check `kc_B` → otherwise `abort{"key_confirm"}`. Send M4 `key_confirm{kc_A}`.
7. Show owner A the `SAS` code with an instruction to read it out to B.
8. Wait for M5. `abort` from B → the session failed. Check `mac_B` → otherwise `abort{"protocol"}`.
9. Only after a correct M5, ask owner A: "Did B say the code matched?". The answer "no" or a timeout → `abort{"owner_rejected"}`.
10. After confirmation: create the libsignal bundle (identity = `P_A.identity_key`, prekey, signed prekey, KEM prekey `MLKEM1024`)
    and send M6 `confirmed{mac_A, bundle}`.
11. Read M7. Pin `P_B.identity_key` to B's address (§10), decrypt `ct` (PQXDH on the responder side).
    The plaintext must be exactly `L_INIT ‖ TH` → otherwise `abort{"protocol"}`.
12. **Link A active**: atomically save the link, the contact, the keys and the session. Encrypt `L_ACK ‖ TH` and send M8 `done{ct}`.
13. Close the ephemeral endpoint, erase `ek_A`, `s`. Bring up the pairwise endpoint `ek'_A` (§11).

### B (joiner)

1. Parse the link. Create `ek_B` and an ephemeral endpoint, connect to `E_A`. Check the TLS group, compute `X`.
2. Generate the link keys (as A in item 5), `N_B`, `C_B`, `psk_mac`. Send M1.
3. Read M2 (`abort` → failure). Check `P_A`. Compute `TH`, `PRK`, `K_A`, `K_B`. Send M3 `reveal{N_B, kc_B}`.
4. Read M4, check `kc_A` → otherwise `abort{"key_confirm"}`.
5. Ask owner B to **enter** the code that A will read out (there is no "matches" button, SPEC §6 item 8).
   `!ct_eq(entered, SAS)` → `abort{"sas_mismatch"}`, failure (on A the invite burns).
6. Send M5 `code_entered{mac_B}`.
7. Wait for M6 (owner A confirms). `abort` → failure. Check `mac_A`.
8. Check `bundle.identity_key == P_A.identity_key`, pin it to A's address, run `process_prekey_bundle`
   (libsignal verifies the signatures of the signed prekey and the KEM prekey with this key). Encrypt `L_INIT ‖ TH`, send M7.
9. Read M8, decrypt; the plaintext must be `L_ACK ‖ TH`.
10. **Link B active**: save atomically. Close the ephemeral endpoint, bring up the pairwise `ek'_B`.

## 9. Confirmation by the owners

A link is activated on a side only when **two** conditions hold:

| Side | Condition 1 (local, a person) | Condition 2 (over the network, authenticated with a key from PRK) |
| --- | --- | --- |
| A | Owner A confirmed on their side after a spoken "it matched" from B (step A9) | A correct `mac_B` in M5: node B reported that its owner entered the correct code |
| B | Owner B entered a code that matched `SAS` (step B5) | A correct `mac_A` in M6: owner A confirmed |

**Non-interactive confirmation on A (`antenna invite --confirm`) is for tests only.** It removes condition 1 on A: whoever
intercepted the link and connected first will compute `mac_B` themselves and get the link. So the daemon accepts such a request only
if it was started with `--allow-auto-confirm` (a hidden test flag); an ordinary daemon answers `forbidden`.

A network "B confirmed" (M5) turns nothing on by itself: A will not send M6 without the owner's local decision, and without M6 and M7 A
has neither a session nor a link record. An attacker in the middle who knows `s` can compute `mac_B` for their own session with A,
so the deciding factor remains the spoken confirmation to owner A (SPEC §6 item 9).

**How owner A gives condition 1 (A9).** Since `0.1.0-preview.5` (D-95), after a correct M5 owner A confirms with one action (a
button, `yes` in `antenna invite`, `antenna pairing confirm <id>`), without typing the code again: B's node already compared the
code B's owner entered with the SAS (B5), and A's click is the human assent that the person they read the code to said it
matched. The click must name the session, because a spoken "it matched" does not (§15, F-4): the daemon accepts a confirmation
without the code only for an invite during whose life **no other invite of this node showed a code**; otherwise the owner types the
code they read out, as in v1 before D-95, and the daemon accepts "yes" only for the invite with that code (`docs/CONTROL.md` §6).
The protocol messages do not change.

## 10. libsignal session

- Each link has its own libsignal `IdentityKeyPair` and registration id (pairwise, SPEC §5). They are created at pairing and
  sent as `P.identity_key`, that is, they are covered by `TH` and `SAS`. TOFU is not used: the identity store considers
  **only** the pinned key trusted.
- libsignal addresses (`ProtocolAddress`): the name `hex(link_id) ‖ ".a"` for A and `hex(link_id) ‖ ".b"` for B, device id 1.
  libsignal binds the sender and recipient addresses to PreKey messages, so both sides must use these names.
- A's bundle: a one-time prekey (X25519), a signed prekey (X25519, signed by identity), a KEM prekey `MLKEM1024`
  (signed by identity). The identifiers are 1. The bundle is not part of `TH`. The signed prekey and the KEM prekey are signed by the pinned
  identity; the one-time prekey and the registration id are not signed, and their integrity comes from the channel itself: `TH` contains the TLS exporter,
  and a matching SAS means that the TLS channel between A and B has no intermediary (except with probability 10⁻⁶). The lengths of the bundle fields
  are checked (§6).
- B initiates (PQXDH, `process_prekey_bundle`), A responds. M7/M8 carry `L_INIT ‖ TH` and `L_ACK ‖ TH`: the Triple Ratchet session
  is bound to the pairing transcript, and B's session is acknowledged before activation (otherwise libsignal would consider it unacknowledged).
- The session version is 4 (PQXDH + SPQR). SPQR is negotiated in the first messages (`StillNegotiating` → `NegotiationComplete(V1)`).

## 11. Switching to pairwise endpoints

- `P_A.endpoint` and `P_B.endpoint` are the keys of the link's pairwise endpoints, and they are in `TH`. After activation each side brings up
  its pairwise endpoint, and the ephemeral one is closed.
- The network mode of the pairwise endpoint is set by the trust level that **this** side assigned to the contact (SPEC §4):
  levels 1–2: "relay only" (no IP transports, the contact does not see the IP); 3–5: direct (relay + IP).
  Without a relay, "relay only" mode is impossible, and such an invite is rejected locally.
- The `addrs` from pairing are the first route hints. The pairwise endpoint's port is saved and reused after a restart.

## 12. Link format (ALPN `x/link/0`, format v1)

Each request is a separate bi-stream: `u32be(len) ‖ CBOR(request)`, then the response `u32be(len) ‖ CBOR(response)`, `len ≤ 1 MiB`.

```cddl
link-request = { "hello": { "addrs": addrs } }
             / { "deliver": { "blob": routing-blob } }   ; a new message (E2E: the plaintext is CBOR(envelope))
             / { "resend": { "blob": routing-blob } }    ; resend during verification (E2E: CBOR([* envelope]), ≤ 64), §16
             / { "sync": sync-summary }                  ; history verification, §16 (no message content)
             / { "chain": chain-query }                  ; searching for the divergence point, §16
             / { "conflict": conflict-note }             ; a divergence point that was found, §16
             / { "want": { "ids": [* bstr .size 32] } }  ; please resend these messages (≤ 1024, more is rejected), §16
             / { "rekey_offer": rekey-offer }            ; rekey after rollback, §17
             / { "rekey_init": { "blob": routing-blob } }
             / { "rekey_ack": { "blob": routing-blob } }
link-response = "ok" / "duplicate" / "pending" / { "rejected": { "reason": tstr } }
             / { "sync": sync-summary } / { "chain": { "points": [* chain-point] } }
             / { "conflict": { "id": bstr .size 32 / null, "sig_ok": bool / null } }
             / { "rekey_init": { "blob": routing-blob } } / { "rekey_ack": { "blob": routing-blob } }
                                         ; to rekey_init: "pending" (waiting for the second code) or rekey_ack (already confirmed)

routing-blob = {                 ; everything visible outside E2E (SPEC §7)
  "v": uint,                     ; link format version, 1
  "link": bstr .size 32,         ; link_id
  "ct": bstr,                    ; pad(e2e-frame), the length is exactly one of the buckets of SPEC §7
}
; e2e-frame = u8(libsignal type: 2 = SignalMessage, 3 = PreKeySignalMessage) ‖ libsignal message bytes
; pad(x) = u32be(len(x)) ‖ x ‖ 0x00…  up to padded_len(4 + len(x)): 256, 1024, 4096, 16384, then multiples of 16384

envelope = {                     ; libsignal plaintext
  "id": bstr .size 32,           ; = BLAKE3-DK("x 2026-10-02 message-id v0", core)
  "core": bstr,                  ; CBOR(envelope-core): exactly the bytes that are hashed and signed
  "auth": { "sig": bstr .size 64 },  ; the author's signature (SPEC §7); deniable mode (MAC) is v0.3
}
envelope-core = {
  "salt": bstr .size 32,         ; rand(32): the text cannot be guessed from the id
  "author": bstr .size 32,       ; the side's link-root Ed25519 or its agent's key (§21)
  "parents": [* bstr .size 32],  ; the link's current heads at the author, in ascending byte order
  "lamport": uint,               ; 1 + the maximum lamport among the link's known messages
  "ts": uint,                    ; Unix ms, the author's clock
  "n": uint,                     ; the side's message counter in the link (owner and agents share one): 1, 2, 3… without gaps
  "type": "text" / "receipt" / "file" / "request" / "control",
  "body": { "text": tstr } / { "receipt": receipt }
        / { "file": file-offer }             ; a file offer, §19 (type "file")
        / { "file_request": file-request }   ; a request for a file from the contact's shared/, §19 (type "request")
        / { "agent": agent-announce }        ; an announcement of the side's agent, §21 (type "control")
        / { "picture": picture },            ; a profile picture, §25 (type "control", only to a node with "picture/0")
  ? "to": to,                    ; who it is for, §23 (text only, only to a node with "addr/0")
  ? "topic": topic,              ; the topic, §23 (the same)
}
receipt = {                      ; a receipt for an action requested by the contact, §18
  "actor": tstr,                 ; "owner" or the agent's name (sub-identity, SPEC §5): [A-Za-z0-9._-]{1,64}
  "action": "read_messages" / "read_history" / "send_message" / "check:read" / "check:write" / "check:exec"
          / "share_file" / "request_file" / "accept_file" / "reject_file"
          / "withdraw_file"           ; only to a node with "file-withdraw/0" (§19)
          / "deliver"                 ; only to a node with "no-agent/0" (§23)
          / "check_file",             ; only to a node with "file-fate/0" (§19)
  "decision": "allowed" / "denied" / "approval_required" / "approved" / "accepted" / "rejected"
          / "withdrawn"               ; with "withdraw_file" only
          / "no_such_agent"           ; with "deliver" only
          / "held",                   ; with "check_file" only, and always with "why"
  "refs": [* bstr .size 32],     ; the IDs of the messages it refers to (≤ 64)
  ? "count": uint,               ; a batch of identical receipts (§18, Q-22): how many times; no field means one (≤ 10⁶)
  ? "name_number": uint,         ; 2–1000, with "accept_file" / "accepted" only: the file was saved as "<stem> (n).<ext>"
                                 ; because another file had the name (§19); only to a node with "file-saved-as/0"
  ? "why": tstr,                 ; a file's fate (§19), only to a node with "file-fate/0": with "check_file" / "held"
                                 ; "threat" / "executable" / "installer" / "uninspected" / "check_failed" / "review" /
                                 ; "not_saved"; with "reject_file" / "denied" "threat" / "damaged" / "limit"
  ? "rules": [* tstr],           ; with "why" only, ≤ 16, each [a-z0-9_:.-]{1,64}: the check's finding codes, never
                                 ; content; the recipient's own rules by kind only ("yara:extra", "av")
}
```

**Message signature** (SPEC §7 "signature with context": the link ID, the recipient's key, the counter and the content):

```
sig = Ed25519-Sign(sk_author, "x/link/v1/msg-sig" ‖ link_id ‖ recipient_root ‖ u64be(n) ‖ lp(core))
```

`sk_author` is the side's link-root Ed25519 (pinned in `TH` at pairing, §7) or the key of its agent that it announced (§21);
`recipient_root` is the other side's link-root Ed25519.
Exactly the bytes of `core` are signed (as with the ID, D-19): no CBOR canonicalization is needed. Verification is RFC 8032 in strict mode
(`verify_strict`: small subgroups and non-canonical `S` are rejected). A signed message cannot be forwarded into another link or to
another recipient: their keys are in the signature. A side's agents sign with their own key in the link, announced by the link-root (§21).

Recipient checks (`deliver`); if any fails, `rejected` with a reason, and the message is not saved:
- an `e2e-frame` of type 3 (PreKeySignalMessage) on the link: `unexpected_prekey`, even before decryption (both sessions are acknowledged
  at pairing; the only exception is `rekey_init`, §17);
- `id` is recomputed from the received bytes of `core`; a mismatch is `bad_request`;
- `author` is the contact's link-root from `TH` or the key of its agent announced earlier (§21; otherwise `unknown_author`); the signature:
  `bad_signature`;
- `lamport` ∈ [1, 2⁶²], `n` ∈ [1, 2⁶²], `ts` ≤ 2⁶³ − 1, `parents` ≤ 256; text 1…64 KiB; receipt fields 1…64 bytes, `refs` ≤ 64,
  `count` ≤ 10⁶; a signed file manifest 1…16 KiB and a 64-byte signature; a file request path 1…1024 bytes (the rest about the file
  is checked by the recipient's quarantine, §19);
- another message from the same author with the same `n` already exists: `history_conflict`: a history divergence, and the place is recorded (§16).

Responses and the queue:
- `ok`: the message is saved (the libsignal session, the message record and the state counter of §17 are committed in one transaction).
  `duplicate`: already seen (libsignal: "old counter", or the same `id`); the sender removes it from the queue just as on `ok`.
- Temporary rejections, which the sender retries without counting attempts: `rekey_required` (the recipient has a rollback, delivery waits for a rekey,
  §17), `read_only` (the recipient has a history divergence pending the owner's decision), `recovering`, `internal`. For other rejections,
  after 5 in a row the message is taken off the queue and marked `failed`.
- The sender keeps a queue (outbox) of already encrypted `routing-blob`s and retries them with exponential backoff
  (SPEC §4, v1). A retry does not re-encrypt: ratchet counters are not consumed. Re-encryption happens only after a rekey (§17).
- Before delivering the queue over a new connection, the sides verify the history (`sync`, §16); if verification fails, the queue is not
  delivered.
- The contact's service requests (`sync`, `chain`, `conflict`, `want`, `resend`, `rekey_*`): no more than 120 per minute per link
  (beyond that, `rejected{"rate_limited"}`); one resend in response to `want` at a time.
- `hello`: the sender's address hints (the relay and, in direct mode, IPs). Accepted only from the pinned key (§13).

## 13. Accept-list (SPEC §4, decision Q-5)

A pairwise endpoint accepts QUIC only from the contact's `EndpointId` from `TH`:
1. **Through a relay**: the relay reports the sender's `EndpointId` before the handshake; a foreign one → the packet is ignored, no response.
2. **Directly (UDP)**: the `EndpointId` is known only from TLS. A foreign key → the connection is closed with code `403` right after the
   transport handshake, before any application data and application cryptography. The pairwise endpoint's address is not published anywhere.
3. The TLS group on the link is checked too: not `X25519MLKEM768` → close.
4. In "relay only" mode the node connects to the contact **only through its own relay** (from its own relay map: n0 by default
   or explicitly configured). A relay suggested by the contact (in `addrs` or `hello`) that is not our own is rejected: the operator of someone else's relay
   would see our IP.

## 14. Places where primitives are combined (formal model input)

| # | Where | What is combined | Why |
| --- | --- | --- | --- |
| C1 | `psk_mac` | HKDF(`s`) as the HMAC key over the TLS exporter, both EndpointIds and the whole body of M1 (v1) | The "PSK" of SPEC §6 item 3 at the application layer; binding to the TLS session (D-7); the fields of M1 cannot be substituted without the link's secret (F-3) |
| C2 | `C_B` | SHA-256 over the exporter and `N_B` | Commit-then-reveal: B fixes its nonce before it sees `N_A` (SAS-MCA) |
| C3 | `TH` | SHA-256 over the version, suite, TLS group, endpoint keys, exporter, commitment, nonces, all of the sides' keys | A single transcript: a downgrade or the substitution of any key changes the SAS |
| C4 | `PRK` | HKDF-Extract over `X ‖ s` | The confirmation keys depend both on the hybrid PQ secret of TLS and on the link's secret |
| C5 | `K_A`, `K_B`, `link_id` | HKDF-Expand(PRK) with the role and `TH` in `info` | Different keys per role; the link ID is shared and unpredictable |
| C6 | `kc_*`, `mac_A`, `mac_B` | HMAC under `K_*` over a label and `TH` | Key confirmation; authenticity of the network "entered the code" and "confirmed" |
| C7 | `SAS` | HKDF over `TH`, `mod 10⁶` | A code for comparison by voice; because of `mod`, any code comes up with probability at most 4295/2³² ≈ 1.0000076·10⁻⁶ (statistical distance from uniform ≈ 2⁻¹⁷): negligible |
| C8 | libsignal | identities from `TH` pinned before PQXDH; `L_INIT ‖ TH`, `L_ACK ‖ TH` inside the first ratchet messages | Binds the E2E session to the SAS-verified transcript (D-8) |
| C9 | message `id` | BLAKE3 `derive_key` over `core` with a salt | The ID in the hash-DAG; the salt prevents guessing the text from the hash |
| C10 | `pad` | Length and zeros **outside** the libsignal ciphertext | Size padding; integrity comes from the libsignal MAC, the length is only for parsing |
| C11 | keystore (local) | Argon2id(password) → ChaCha20-Poly1305 key, AAD = file header; HKDF(root key) → SQLCipher key | The device key on disk without a TPM (Q-4); not part of the network protocol |
| C12 | message signature (§12) | Ed25519 link-root over a label, `link_id`, the recipient's key, `n` and `lp(core)` | Authorship and integrity of every message; cannot be redirected into another link or to another recipient (SPEC §7) |
| C13 | author chain (§16) | BLAKE3-DK over the previous value and the ID of message `n` | One summary (32 bytes per author) fixes all of the author's IDs in order: equal history copies are confirmed in one exchange |
| C14 | history fingerprint (§16) | BLAKE3-DK over `link_id` and the heads, `mod 1000` → 3 emoji | For display to a person; the exact comparison is done by the daemon on heads and chains |
| C15 | rekey offer (§17) | Ed25519 link-root over a label, `link_id`, the recipient's key, the time and the bundle bytes; the bundle's identity = the pinned one | A new ratchet session only from the holder of the link keys, fresh, confirmed by both owners (each enters the other's code: the first over the bundle, the second over the bundle and the response) |
| C16 | state counters (local, §17) | HMAC-SHA256 under HKDF(root key) over the link counters | The file outside the DB cannot be substituted without the root key; a rollback of the DB alone is visible |
| C17 | a side's agent key (§21) | A C12 signature by link-root over a `control`/`agent` message with the agent's key; then C12 with the agent's key. No new construction | A sub-identity signed by link-root (SPEC §5): without the link-root signature the agent's key is not an author in the link; the key is unique per link |

## 15. Security goals, assumptions, limitations

**Model assumptions.** TLS 1.3 with `X25519MLKEM768` is a secure channel, strong as long as at least one of X25519 and ML-KEM-768 is strong;
the exporter is a PRF output of the TLS key schedule; HKDF and HMAC are PRFs; SHA-256 is collision-resistant (a random oracle in the model);
libsignal PQXDH and Triple Ratchet are secure according to their own analyses. The owners compare the code over an authentic channel (voice, in person).
The link may be intercepted (the attacker knows `E_A`, `s`, the relay).

**Goals.**
- G1 · Agreement: if A activated a link with keys `P_B`, then B activated a link with the same `TH` (and vice versa), except when the attacker's
  SAS happens to match, with probability ≤ 4295/2³² ≈ 10⁻⁶ per attempt (C7); there is one attempt per invite (the limit of 5 applies only to a wrong
  `psk_mac`, before the secret is checked).
- G2 · Commit-then-reveal: an attacker in the middle cannot choose their values after seeing both nonces: `N_B` is hidden by the
  commitment before `N_A`, and `N_A` is revealed before `N_B`. Offline SAS grinding is impossible.
- G3 · Activation only after both owners (§9).
- G4 · Secrecy of `K_A`, `K_B`, `link_id` and the E2E keys against a passive attacker, including a future quantum one ("harvest now").
- G5 · Downgrade is impossible: the version, `SUITE` and the TLS group are in `TH`; there are no legacy modes. While only one value is allowed, `TH` takes
  the implementation's constants; when a second version or suite appears, `TH` must include the values each side saw
  (A: those received in M1, B: those sent); otherwise, with broken TLS, a downgrade is possible (`formal/neg_nohdr.pv`).
- G6 · Pairing cannot be started without the link's secret: a wrong `psk_mac` is rejected, 5 failures burn the invite.

**Formal model** (`formal/`, pairing v1, ProVerif 2.05; results in `formal/run.log`, assumptions in `formal/README.md`).
G1–G3, G5 and the binding of E2E to `TH` (C8) are proven symbolically for an unbounded number of sessions against the strongest attacker: TLS
is compromised, the link is intercepted and can be substituted, the SAS is weak (the attacker fits their contribution to any code if they know the other
fields of `TH`), owner A has many invites at once, and the voice does not name the session.
G4: `K_A`, `K_B`, `link_id` are secret when TLS is intact (including against a future quantum attacker, even if the link leaked) or
when the link was not disclosed; the E2E key also when TLS is broken (ML-KEM in PQXDH holds it). G6 holds with compromised TLS. The probability
10⁻⁶ is not a result of the model but a separate argument (`formal/README.md`). What holds each condition of §9 against which attacker:
- `mac_B` (M5) and `mac_A` (M6) are authentic as long as `PRK` is secret, that is, TLS is intact **or** the link's secret has not leaked. If both are
  broken, the attacker computes both. Then "owner B entered the code" is confirmed for A only by the spoken "it matched" (A9), and
  "owner A confirmed" for B by the bundle signed by the identity from `TH` (B8): A creates it only after the owner's decision.
  The B8 check and this ordering are mandatory: without them B activates a link with the intermediary (`formal/neg_nopin.pv`).
- In v1 `psk_mac` covers the whole body of M1 (F-3): without the link's secret one cannot substitute `C_B`, `P_B` or the address hints in
  someone else's M1 even with broken TLS. A replay of M1 **in full** with broken TLS is still stopped only by the invite burning
  after the first correct `psk_mac` (§4): this is a mandatory property, not a convenience (`formal/replay_tnull.pv`:
  a full replay passes the MAC check but does not get past M3 without the link's secret; field substitution: `formal/psk.pv`; the v0 MAC:
  the attack in `formal/neg_v0mac.pv`).
- A spoken "it matched" does not name the session: owner A confirms the invite whose code they read out. In v1 the confirmation
  carries the code that the owner enters, and the daemon accepts "yes" only for the invite with that code (`docs/CONTROL.md` §6):
  the model with a voice channel shared by all invites gives Q4 `true`; "yes" without a code is an attack (`formal/neg_nocode.pv`). The code must
  be entered by the owner: a client that fills in the current code by itself removes this protection. Since D-95 the code may be
  left out when only one invite of the node showed a code while it was open: then the voice channel carries only this invite's code,
  and the model with one invite with a code per owner and a "yes" without a code gives Q4 `true` (`formal/button_single.pv`). With two
  codes at once the daemon requires the code (`code_required`). What remains is the human factor of §9: a click without having heard
  "it matched" about the code on the screen.

**Known limitations of v0.**
1. The last message (M8) may be lost: then the link is active on A and not active on B. This is visible (A's queue is not delivered);
   the fix is to pair again. The "two generals" problem cannot be solved without an extra round.
2. The invite lives in the daemon until its TTL and survives closing `antenna invite`, but not a daemon restart: unfinished invites are
   not written to disk (§4); a restart and `antenna lock` burn them.
3. Short PAKE codes (SPEC §6, v0.3) are not implemented. The emoji SAS is a representation of the same code (§7).
4. Message signatures exist from link format v1 (§12). Joint checkpoints (Ed25519 + ML-DSA-65) are v0.2, deniable mode
   (a MAC instead of a signature) is v0.3 (SPEC §17). A full binary search over the Merkle tree (SPEC §8 item 3) is v0.2; in v1 the place is found by
   chain checkpoints (§16).
5. A cached link connection keeps QUIC keep-alive while it is open: the contact sees that the node is online.
6. When joining via a link, B connects to the relay from the link: its operator (possibly A itself with its own relay) sees B's IP.
   This happens before the SAS and does not depend on the trust level; whoever does not trust the relay in a link should not join through it.
7. Local authentication (slice 2): `invite`, `join`, `pairing confirm/cancel` require the owner password on every call;
   agents talk to the daemon with tokens and do not have the owner's commands (`docs/CONTROL.md`). The boundary is drawn between processes
   of the same uid; the limits are in `docs/CONTROL.md` §11.
8. A message that the contact rejected 5 times (except for the temporary `internal` error) is taken off the queue and marked `failed`
   (visible in `antenna contacts`), rather than silently lost.
   For levels 1–2 (presence is forbidden, SPEC §4) this has to be closed in the next slice.

## 16. History verification (SPEC §8)

**Author chain.** Each side's messages are numbered by its counter `n` (§12). For author `Z` and `k ≥ 1`:

```
chain_Z(0) = 0³²
chain_Z(k) = BLAKE3-DK("x 2026-10-02 author-chain v1", chain_Z(k−1) ‖ id(Z's message with n = k))
count_Z    = the largest k for which the side has all of Z's messages with n = 1…k
```

A message ID fixes its content and its parents, so two copies of a link's history are equal if and only if for both
authors `count` and `chain(count)` match (and, as a consequence, the heads).

**Summary** (`sync`; the request and the response have the same shape; it travels under the link's TLS, contains no message content, only hashes and counters, and
works without the ratchet, that is, also during a state rollback):

```cddl
sync-summary = {
  "v": 1,
  "heads": [* bstr .size 32],                                         ; the side's heads, in ascending order
  "authors": [* { "author": bstr .size 32, "count": uint, "tip": bstr .size 32 }],   ; both sides of the link
  "audit": "ok" / "unchecked" / { "damaged": place },                 ; the check of the side's own copy (below)
  "state": "ok" / "rolled_back" / "read_only",
}
place = { "author": bstr .size 32, "n": uint }
```

The side that has no fewer of author `Z`'s messages (`count_mine ≥ count_theirs`) compares `chain_Z(count_theirs)` of its copy with
the other side's `tip`:
- if they match and it has more, it sends the contact `n ∈ (count_theirs, count_mine]` (`resend`, E2E, in batches of ≤ 64 envelopes and ≤ 512 KiB;
  its own messages that are still in the queue are delivered by the queue);
- if they don't match, the copies diverge at `n ≤ count_theirs`: search for the place (below).

The recipient of `resend` checks each envelope as for `deliver` (ID, the author's signature from either of the two sides with the recipient key
"the other side", limits) and saves it as restored (not "unread": agents do not receive it again). Resending is not
subject to the level's limit, so messages from the contact that are **new** to the recipient are accepted only with `n` no greater than the counter
the contact itself declared in its last summary, and no more than 1000 per unlock (100,000 after a rekey, §17); messages requested with
`want` (evidence, restoration, missing parents) are always accepted. In "read-only", only requested ones. After
the resend the sides repeat `sync`.

**"History verified"**: the heads, counters and chains of both sides match, both copy checks are `ok`, there are no rollbacks. Verification happens on
every new link connection before the queue is delivered, after a batch of messages (1.5 s without activity) and on `antenna verify`.
**Fingerprint** (the same on both sides when the history is verified):

```
fp = BLAKE3-DK("x 2026-10-02 history-fingerprint v1", link_id ‖ h₁ ‖ … ‖ h_k)    ; heads in ascending order
d  = u32be(fp[0..4]) mod 1000  → 3 digits with leading zeros → 3 emoji from the table in §7 (the same 10 animals as the SAS)
```

1000 variants are a representation for people ("I have 🐼🐶🐓" — "me too"); the exact comparison (32 bytes per head and chain)
is done by the daemon. The bias of `mod 1000` from uniform is less than 2⁻²².

**Check of the side's own copy** (once after unlock, after restoration and on `antenna verify`): each ID is recomputed from
the bytes of `core`; the author, `n`, lamport, time, type and displayed text are checked against `core`; the chains are rebuilt; the heads
are recomputed from `core.parents`. A manual edit in the DB without recomputing the ID shows up here with the exact place: the side reports
`audit = damaged(place)`, its copy switches to "read-only", and the contact's side shows "the contact's copy is damaged".

**Searching for the divergence point** (IDs changed, re-signed and so on):

```cddl
chain-query = { "author": bstr .size 32, "from": uint, "to": uint, "step": uint }   ; n ∈ [from, to], multiples of step
chain-point = { "n": uint, "tip": bstr .size 32, "id": bstr .size 32 / null, "sig_ok": bool / null }
conflict-note = { "place": place, "id": bstr .size 32, "sig_ok": bool }
```

The interval is `(lo, hi]` (the chains are equal at `lo` and not at `hi`). While `hi − lo > 1024`, points are requested at a step that is a multiple of 1024
(chain checkpoints that each side keeps in memory: 32 bytes per 1024 messages), no more than 1024 points; the first
mismatching point narrows the interval to one step. Then points with step 1: the ID and the signature check of the responder's own copy.
The first `n` with a different ID is the place. **For 1 million messages of an author**: 2 exchanges (976 points and ≤ 1024 IDs), ≤ 64 KiB over the network,
answers from memory and ≤ 1024 IDs from the DB (measured: 65 ms); for 1 billion, 3 exchanges. Checking one's own copy for 1 million takes 7.3 s (D-44). A full binary search over the Merkle tree (SPEC §8 item 3, ≈ 20 rounds of
32 bytes) is v0.2; this method finds the same place in fewer rounds at the cost of a larger volume.

**Whose copy was altered** is decided from the signatures of both copies at the divergence point, and **the side checks both itself**: its own copy locally,
the contact's copy by requesting it with `want` (it arrives as a resend and is checked like any other). The contact's word (`tip`, `id`, `sig_ok` in
`chain`/`conflict`) does not count as evidence:

| Signature of my copy | Signature of the contact's copy | Conclusion |
| --- | --- | --- |
| invalid | valid | my copy was altered (`signature_invalid`) |
| valid | invalid | the contact's copy was altered (does not block my side: my copy is intact) |
| valid | valid | both are signed with the author's key: the author's side signed two versions (`two_signed_versions`): its copy was altered by someone who has its key, or it forked the history |
| invalid | invalid | both were altered |
| valid | not yet arrived | the contact reports a difference (`contact_reports_difference`): shown without blocking until the contact's copy arrives and is checked |
| place not found (the `chain` answer contradicts the summary) | — | the divergence is not recorded |

The contact's copy is accepted as evidence only at the place `(author, n)` where it was requested, no more than 16 at a time and
for no longer than 10 minutes. A proven divergence in which the side's own copy was altered or the history was forked (two signed versions)
is recorded on the side and survives a restart; the link is "read-only" (sending and receiving new
messages: the temporary rejection `read_only`; only requested copies are resent) until the owner decides: accept the divergence
(`antenna verify --accept`, with the password; an accepted divergence stays displayed as a divergence) or, if the side's own copy is damaged with the same ID,
restore it from the contact's copy (`antenna verify --repair`: `want`, then `resend`, the author's signature is checked). An unproven one
(the contact's word) is shown without blocking. When the copies match again (the summaries are equal), unproven divergences and divergences accepted by the owner
are cleared. Messages with unknown parents are accepted, and the missing parents of this
link are requested with `want` (the check is within the link: from the absence of a `want` the contact does not learn about messages of other links).

**Rollback on the contact's word.** The statement "I have more of your messages than you do" blocks the side's sending even without
evidence (the safe side: if it is true, encrypting is not allowed); this way a contact can push **its own** link into a rekey,
which is a denial of service for that link only, which the contact can cause anyway. After a rekey, "recovery" lasts no
longer than 2 minutes if the contact does not resend what it declared.

## 17. State rollback protection and rekey (SPEC §8, §13)

**State counter.** Every transaction that changes the link's ratchet session (encryption, decryption, rekey) increments
the link's counter in the DB, and **after** the commit writes it to a separate file `state-counters.cbor` outside the DB:

```
file = CBOR({ "v": 1, "links": [* { "link": bstr .size 32, "counter": uint }], "mac": bstr .size 32 })
mac  = HMAC-SHA256(HKDF-SHA256(salt "x/device/v0", device root key, "x/device/v0/state-counter-mac"),
                   "x/state-counters/v1" ‖ u32be(k) ‖ (link_id ‖ u64be(counter))…)      ; in ascending link_id order
```

The file is written atomically (temporary file, fsync, rename); the values only grow. After a crash between the DB and the file, the file lags
behind the DB and catches up; there are no false positives. On unlock: the DB counter is less than the file's: the DB was restored from an old copy,
and the link is blocked (`rolled_back:local_counter`); the file is missing or its HMAC does not match with non-zero counters: blocked too
(`counter_file_missing` / `counter_file_damaged`, the safe side). **The contact sees the rollback in the numbers**: in the summary (§16)
it has more of my messages than I do, so my side blocks itself (`rolled_back:contact_numbers`), and its side
shows "rollback at the contact" and holds back delivery. This also catches a rollback of the whole data directory or a VM snapshot, which
a file on the same disk cannot see.

A blocked link encrypts nothing new (sending gives `rekey_required`), rejects incoming messages temporarily, and answers summaries.

**Rekey** (both owners enter the code read out by the other and confirm with the password; `antenna rekey <contact>`):

```cddl
rekey-offer = { "bundle": bstr,          ; CBOR(bundle §6): fresh prekeys on the identity pinned at pairing
                "ts": uint,              ; Unix ms; older than 10 minutes is rejected
                "sig": bstr .size 64 }   ; Ed25519(root, "x/link/v1/rekey-offer" ‖ link_id ‖ recipient_root ‖ u64be(ts) ‖ lp(bundle))
```

1. The side with the rollback (B; `antenna rekey <contact>` without a code; the side without a rollback **cannot** make an offer, otherwise whoever
   stole a copy of B's DB would get their offer accepted) creates a fresh bundle (a one-time prekey, a signed prekey, a KEM prekey
   ML-KEM-1024, identity signatures), keeps the prekeys in memory, sends `rekey_offer` and shows the owner the **first code**:
   `u32be(HKDF-SHA256(salt "x/link/v1/rekey-code", link_id ‖ H(bundle), "x/link/v1/rekey-digits")[0..4]) mod 10⁶`: 6 digits
   (or the same 10 animals, §7). Owner B reads the code out to owner A by voice. Repeating `antenna rekey` within the window sends **the same**
   offer (the same code): A will never have two different ones; in the last 30 s of the window: "retry in N s", then a new one.
2. A checks the link-root signature, freshness and `bundle.identity_key` = the pinned one, answers `pending` and notifies the owner
   (the notification does not contain the code). Owner A enters the code heard from B (`antenna rekey <contact> --code …`, password): if the code does not match the
   code of **this** offer, it is rejected (`sas_mismatch`), like the pairing confirmation with a code (F-4): "consent" does not name the
   offer, the code does.
3. A: `process_prekey_bundle` → a new session (the previous one is archived), the first message `PreKeySignalMessage(L_REKEY ‖ link_id ‖
   H(bundle))`, `L_REKEY = "x/link/v1/rekey-init"`, sent as a `rekey_init` request. The accepted offer (the hash and the first message)
   is kept in A's DB until confirmation: a retry after a disconnect or restart sends **the same** response.
4. B checks the response with a trial decryption using its fresh prekeys (the transaction is rolled back: a session is **not** created, the block
   is **not** lifted), remembers it and answers `pending`. A shows its owner the **second code**:
   `u32be(HKDF-SHA256(salt "x/link/v1/rekey-confirm", link_id ‖ H(bundle) ‖ H(init), "x/link/v1/rekey-digits")[0..4]) mod 10⁶`,
   `H(init) = SHA-256(type ‖ libsignal bytes)` of the first message without padding. Owner A reads it out to owner B.
5. Owner B enters the second code (`antenna rekey <contact> --code …`, password; a wrong one gives `sas_mismatch`). Only now does B decrypt
   the first message for real, check the plaintext, raise the state counter above the file, lift the block and
   send, as a `rekey_ack` request, `SignalMessage(L_REKEY_ACK ‖ link_id ‖ H(bundle))`, `L_REKEY_ACK = "x/link/v1/rekey-ack"`
   (contact unreachable: retry until the end of the window; a repeated `rekey_init` with the same response gets the same `rekey_ack` back).
6. A decrypts the acknowledgement: the session is confirmed; if A had a rollback too, its block is lifted the same way. Both sides
   **re-encrypt their queues** with the new session (old blobs encrypted with the previous state are not sent) and verify
   the history: whatever was lost in the rollback (one's own and the other's messages) comes back as a resend (§16). While the contact has more of my messages
   than I do, my new messages wait (`recovering`): otherwise their `n` would collide with the lost ones. My undelivered messages
   whose `n` are already taken by returned ones are sent again with the next `n`.

**Conflict.** A second, different offer within 10 minutes of the first being received (on A), or a second, different response to one
offer (on B), burns both (`rejected{"conflicting_offers"}`, owner event `rekey{conflicting_offers}`): someone else also has the contact's link
keys. There is no commitment in the first code, so a bundle ground to match an overheard code (10⁶ attempts) must not
take the place of the real one, either after a conflict or after the real offer has expired: A remembers the codes of **all**
received offers (one day, up to 1024, in the daemon's memory), and an offer with a code seen before but a different bundle is a
conflict. After a conflict, the contact's offers and responses are not accepted for 10 minutes. There is nothing to grind the second code against: the response to
B's offer is saved before owner A sees the second code, a different response burns the offer itself, and the next
offer is a new bundle and new codes. The real side starts over.

Why both owners confirm, each with the other's code: whoever stole an old copy of B's (or A's) DB has all of the link's
long-lived keys; a rekey without the other side's confirmation would give them a fresh working session in the victim's name and
cancel the ratchet's post-compromise security. The first code confirms to A that the offer comes from the real B; the second code
confirms to B that the response comes from the real A. The second code is also needed because the `contact_numbers` rollback flag is set by the
contact's word: the holder of a stolen copy of A's DB can tell B that it has more of B's messages, and B will block itself and offer
a rekey, but without the second code from the real A the attacker's response will not create a session (review recheck, finding N1). The offer,
the response and the wait for confirmation live 10 minutes. The accepting side's accepted offer is kept in the DB; the offer and the response on
the side with the rollback, and the remembered codes, are in the daemon's memory: restarting it in the middle of a rekey means starting over.

## 18. Receipts in the shared history (SPEC §9, maintainer decision Q-16)

An action by an agent or the owner requested by a contact is a `type: "receipt"` message in the link's history: signed, part of the DAG,
delivered to the contact, verified together with the rest of the history. A receipt is written:
- for an agent reading the contact's messages (`read_messages` / `read_history`, `refs` = the IDs read), **only for contacts
  of level 3+** (SPEC §4: "read" from level 3);
- for an agent action prompted by the contact's data, i.e. a tool check (`check:read|write|exec`: `denied`,
  `approval_required`, `approved` by the owner's decision), to the contact that is the source of that data;
- for files, to the contact whose file it is (§19): `accept_file` / `accepted` on accept (`refs` = the offer message;
  `name_number` when the file got a numbered name, only to a node with `file-saved-as/0`),
  `reject_file` / `denied` on a rejection based on the manifest or the check (threat, damaged file), `reject_file` / `rejected`
  on a refusal by the owner or the agent; `request_file` / `allowed` or `denied` as the answer to a request from `shared/`;
  by the sender of a file, `withdraw_file` / `withdrawn` (`refs` = its own offer) when it withdraws an offer the contact has not
  answered (§19, only to a node with `file-withdraw/0`);
- for a file the recipient holds for its owner (§19 "The file's fate", only to a node with `file-fate/0`), `check_file`
  / `held` with `why` and `rules` (`refs` = the offer); the same node gets `why` and `rules` on `reject_file` / `denied`;
- for a text message addressed to an agent the recipient's node does not have, `deliver` / `no_such_agent`
  (`actor` "owner", `refs` = those messages), so the sender learns that nobody there reads it (§23, only to a node
  with `no-agent/0`, only to contacts of level 3+).

The agent's tool checks for contacts of **levels 1–2** (`check:*` without `refs`) are batched (decision Q-22): identical ones
(agent, action, decision) accumulate for up to 10 minutes and are written as one receipt with `count`; the batch is also written on `antenna lock`. The details
of each check are only in the local audit log.

Approvals of **sending** (secret scanner, no-write-down, flow between links) are not written to the shared history: otherwise the recipient or
the source would learn about another link's data. A receipt contains no text, no policy reasons (except a file's fate, a
closed vocabulary about the sender's own file, D-130), no trust level (SPEC §7) and no labels of other
links (SPEC §5); `action` and `decision` are closed vocabularies (§12), `actor` is `[A-Za-z0-9._-]{1,64}`. Identical receipts without
`refs` are written no more than once a minute per link. The details stay in the node's local audit log. While the link is blocked (rollback,
divergence), receipts are written only locally. The contact's receipts are not given to agents (not in `inbox`, `history` or
`log`): they are the contact's data, not messages.

## 19. Files (SPEC §7 "Files and streams", §10)

A file travels two ways: the **offer** is an ordinary link message (E2E, signed, in the DAG), the **content** is `xfile/0`
ciphertext as an iroh-blobs 0.103 blob over the endpoint of the same link. Implementation: `crates/antenna-files` (AGPL), types: `antenna-proto::files`.

```cddl
file-offer = {
  "manifest": signed-manifest,
  "secret": bstr .size 32,       ; the file secret: the STREAM key is derived from it and the header salt (inside E2E)
}
signed-manifest = {
  "body": bstr,                  ; CBOR(manifest): exactly the signed bytes, ≤ 16 KiB
  "sig": bstr .size 64,          ; the author's Ed25519 link-root, below
}
manifest = {
  "v": 0,
  "file_id": bstr .size 16,      ; random: distinguishes repeated sends of the same content
  "name": tstr,                  ; 1…1024 bytes, no control characters, Unicode tags or text direction characters
  "mime": tstr,                  ; the type by content at the sender, ASCII 1…128
  "size": uint,                  ; size of the plaintext content
  "blake3": bstr .size 32,       ; BLAKE3 of the plaintext content
  "blob": bstr .size 32,         ; the iroh-blobs blob hash = BLAKE3 of the xfile/0 ciphertext
  "blob_size": uint,             ; = the ciphertext length for size (checked)
  "sender_check": { "verdict": "clean" / "suspicious" / "threat" / "failed", "findings": [* tstr] },  ; ≤ 64 codes
  "created_ms": uint,
}
file-request = { "path": tstr }  ; a path inside the contact's shared/: "/"-separated, no "..", no absolute paths
```

**Manifest signature:** `Ed25519-Sign(sk_author, "x/file-manifest/v0" ‖ 0x00 ‖ link_id ‖ recipient_root ‖ body)`: the keys
are the same as for the message signature (§12); a manifest cannot be forwarded into another link or to another recipient.

**The `xfile/0` format** (STREAM from `aead-stream` 0.6 over ChaCha20-Poly1305, D-F-2):

```
header  = "xfile/0\n" (8) ‖ u32be(65536) ‖ salt (32)                         — 44 bytes, in the clear
key     = HKDF-SHA256(salt = salt, ikm = secret, info = "x/file/v0/stream-key")
chunk_i = ChaCha20-Poly1305(key, nonce = 0^7 ‖ u32be(i) ‖ last_flag, aad = header, ≤ 64 KiB of plaintext)
blob    = header ‖ chunk_0 ‖ … ‖ chunk_last   (an empty file is one empty last chunk)
```

**Transfer.** The sender puts the ciphertext into the store **of its link** (a separate iroh-blobs directory and database per link)
and allows serving only this hash and only in full. The recipient downloads the blob over the same link endpoint (ALPN
`/iroh-bytes/4`; the link's accept-list lets in only the contact, and the handler additionally checks the connection's `EndpointId` against
the contact's key): a foreign hash, partial ranges, push, observe and hash-seq are refused (D-F-10). The hash is verified while
downloading (BLAKE3 verified streaming); after a disconnect the download resumes from the last verified chunk; more than
`blob_size` aborts it. The sender serves the blob until the recipient's `accept_file` / `reject_file` receipt referring to
the offer, or for 14 days.

**Withdrawing an offer** (since `0.1.0-preview.5`). Until the recipient answers, the sender's owner may withdraw the offer: the
sender stops serving the blob at once (it goes to the link store's garbage collection) and, **only if the recipient's node answered the
feature `file-withdraw/0`**, sends a receipt `withdraw_file` / `withdrawn` with `refs` = the offer message. The recipient's node then
deletes its copy that is not accepted yet exactly as on a rejection (the record and the file key are wiped, the ciphertext goes to
garbage collection, a repeat of the same offer is not taken), sends no receipt back, and tells its owner (`file` event with
`state: "withdrawn"`); an accepted file stays where it was. A recipient acts only on its own link's quarantine, so a contact can
withdraw only its own offers. A node without the feature would refuse the receipt's unknown action (strict vocabularies, §12) and the
two copies of the history would differ, so it gets none: for it the withdrawal only stops the serving, and a copy it already
downloaded stays there until its owner decides.

**Recipient** (SPEC §10, the order is mandatory):
1. check the manifest signature with the contact's key, the fields and **the level before downloading**: level 1 and below, exceeding the level's daily
   volume, more than 256 unaccepted files on the link: rejected without downloading and without a record (receipt `reject_file` /
   `denied` to the contact);
2. download the ciphertext into quarantine (the link's store + a record encrypted with the node's quarantine key);
3. decrypt, and the BLAKE3 of the plaintext = the manifest's `blake3` (otherwise rejected, receipt `denied`);
4. check in an isolated process (Landlock + seccomp + rlimits; type by signature, polyglots, archives without unpacking,
   YARA-X, an optional external antivirus), preview (pixels and cleaned text);
5. levels 1–2: threat → receipt `reject_file` / `denied` to the contact immediately; the record is kept for 7 days for the owner's decision
   (`--force`), then deleted; otherwise it waits for an explicit accept (by the owner) into `inbox/`. Levels 3–5 (D-130): a file the rules hold
   waits for the owner's keep-anyway (`--force`), receipt `check_file` / `held` to a node with `file-fate/0`; any other file is accepted at
   level 5 by the daemon and waits for an explicit accept (by the owner or the agent) into `shared/` at 3–4; receipt `accept_file` / `accepted`.

**A taken name** (D-128). When another file has the offered name in the destination folder (ignoring case and Unicode
form) and the accept names no other one, the file is saved as `<stem> (n).<ext>` with the first free `n` from 2 to
1000 (a double extension such as `.tar.gz` stays whole; a dot file and a name without an extension get the number at
the end). The name is claimed in one step that fails rather than replace (`linkat` of the unnamed file,
`renameat2(RENAME_NOREPLACE)`), the next number on failure. A file with the same size and BLAKE3 under the name or a
number is accepted as that file, without a copy. The `accept_file` / `accepted` receipt then carries `name_number` = `n`
to a node that answered `file-saved-as/0`; that node derives the name from its own manifest. A name chosen by the
recipient's owner is not told. The recipient checks `name_number` like the other receipt fields: 2–1000, on
`accept_file` / `accepted` only.

**What holds a file, and the file's fate** (D-129, D-130). From the recipient's level 3, the check's heuristics (markup
or a script in a file, an HTML polyglot, a secret pattern, an unknown type) do not hold a file: they are labels, and
the file is accepted as its level says (at level 5 by the recipient's daemon at once). Held for the recipient's owner,
at every level from 3: native executables, installers and disk images (a file a release manifest signed by a key the
recipient pins lists by name, size and SHA-256 excepted: the signed update flow), archives holding those, signature hits
(an antivirus hook, EICAR, the owner's own YARA rules), a failed check; at levels 3–4 also archives not opened whole or
with a dangerous structure. The check opens every ZIP, tar and gzip member in its sandbox's memory for its first bytes;
an image's own metadata (PNG `caBX`/`iTXt` XMP/`eXIf`/`iCCP`, JPEG APP segments with a metadata identifier, WebP `XMP `
/`EXIF`/`ICCP`/`C2PA`) is not read as HTML. At levels 1–2 a threat is refused at once (`reject_file` / `denied`), as
before. A node that answered `file-fate/0` is told: `check_file` / `held` (`refs` = the offer) with `why` and `rules`
when its file waits for the recipient's owner (levels 3–5), and `why` with `rules` on a `reject_file` / `denied`
(`limit` for every refusal by the manifest, so as not to tell which; `damaged` for content that does not match the
manifest; `threat` at levels 1–2). The sender keeps serving a held file until the final `accept_file` or `reject_file`
or 14 days. A node without the feature gets no `check_file` (it would refuse the unknown action and the two histories
would differ) and `reject_file` / `denied` without the fields; it learns the outcome from the final receipt. The
`rules` of a hold are facts about the sender's own file (its type, a signature): a contact learns nothing it could not
learn by running the open checker itself, except that the recipient's antivirus or own rules matched (`av`,
`yara:extra`, never their names). An agent's file offer is signed by the agent's key in the link (§21), like its
messages, so the recipient can save an agent's files apart; the manifest is still signed by the link-root.

**Request from `shared/`** (`file-request`): only a node that has the contact at level 3+ answers; the path is opened without
following symbolic links at each step and only inside the `shared/` folder of this link; a file with secrets,
one that failed the check at the sender, or one with hard links is not served automatically; per link: one request
at a time, ≤ 20 per hour, the same unanswered file is refused, unanswered serving is ≤ the level's daily volume. The answer is an ordinary `file` offer (the requester gets the same
quarantine) and the receipt `request_file` / `allowed`; a refusal is the receipt `request_file` / `denied` without a reason.

## 20. Streaming messages (v0.2; "the agent's reply as it is being written")

A stream is a "live" display of a message that is still being written (an agent's reply, `<program> | antenna send --stream`). The history,
hash-DAG, signatures and verification (§12, §16) get **only the final message**: an ordinary signed `type: "text"` message, which
goes through the ordinary queue (outbox) and verification. The chunks are ephemeral: they are neither in the DB nor in verification. Implementation:
`crates/antenna-core/src/stream.rs`, formats: `antenna-proto::stream`; decisions: DECISIONS D-63…D-66.

**Boundaries.** The sender streams only if its trust level for the contact is ≥ 3 (a stream is a typing indicator, SPEC §4) and
the message does not require approval for reasons known in advance (link isolation, the agent's no-write-down). The recipient
accepts a stream only if its trust level for the sender is ≥ 3 (otherwise `rejected{"level"}`). The sender's secret scanner
checks every chunk before sending, holding back the tail (D-40): if a secret is found, the stream is cut (`cut`) and the
whole message goes to the owner for approval. "What the source is busy with" (`activity`) is sent only to contacts at levels 4–5.

**Opening** is a link request on a separate bi-stream (§12):

```cddl
link-request /= { "stream_open": { "blob": routing-blob } }   ; E2E: the plaintext is CBOR(stream-open)
stream-open = {
  "v": 0,
  "id": bstr .size 16,           ; random stream ID
  "secret": bstr .size 32,       ; the stream secret (inside Triple Ratchet, like the file secret of §19)
  "ts": uint,                    ; Unix ms, the sender's clock
  ? "agent": tstr,               ; the sender's agent that writes, by its name in this link (§21); only to a node
                                 ; with "stream-agent/0"
}
```

`agent` names the side's agent that writes, so the recipient's live display shows who writes before the final message
arrives (the window puts the bubble in that agent's chat). It follows the name rules of §21, otherwise the opening is
`rejected{"malformed"}`. It is the sending node's word for the display only: the final message's `author` (an announced
agent key, §21) is what counts, and the history never stores this name. A node without `stream-agent/0` parses
`stream-open` strictly, so it gets the opening without the field; a sender that does not know the contact's features
yet sends it without the field too.

`stream-open` is encrypted with the link session (Triple Ratchet, type 2, SignalMessage only) like an ordinary message, but it is not
part of the history; the ratchet state and the state counter (§17) are committed on both sides, as with `deliver`. The recipient
checks the level, the level's incoming limit (the backpressure of §12: an opening counts as one message), no more than
4 concurrent streams per link, that the link is not blocked by a rollback/divergence, the decryption and `v`, and answers on **the same**
bi-stream with a `link-response` frame: `"ok"` or `{ "rejected": { "reason" } }` (`level`, `busy`, `rate_limited`,
`read_only`, `malformed`, `duplicate`). A node without §20 does not parse `stream_open` and answers `rejected{"malformed"}`;
the sender then sends only the final message.

**Chunks**: after `"ok"`, on the same bi-stream, frames `u32be(len) ‖ CBOR(stream-frame)`, `len ≤ 80 KiB`:

```cddl
stream-frame = { "c": bstr, "last": bool }
stream-piece = {                 ; the chunk's plaintext before padding
  "text": tstr,                  ; continuation of the text (may be empty: "alive", an activity change)
  ? "activity": tstr,            ; what the source is busy with (≤ 64 characters; "" clears it), only to contacts at 4–5
  ? "end": "done" / "interrupted" / "cut",   ; only in the last chunk
  ? "final_id": bstr .size 32,   ; only in the last one: the ID of the final message (§12)
}
```

```
key      = HKDF-SHA256(salt = id, ikm = secret, info = "x/stream/v0/key")
aad      = "x/stream/v0/piece" ‖ link_id ‖ id
c_i      = ChaCha20-Poly1305(key, nonce = 0^7 ‖ u32be(i) ‖ last, aad, pad(CBOR(stream-piece)))   — STREAM (aead-stream StreamBE32)
pad(x)   = u32be(len(x)) ‖ x ‖ 0x00…  up to a bucket of §12 (256, 1024, 4096, 16384, then multiples of 16384)
```

This is the same off-the-shelf STREAM construction as for `xfile/0` files (§19, D-F-2): the chunk index and the "last" flag are in the nonce;
reordering, substitution, truncation and appending after the last chunk are decryption errors. `last` in the frame is a hint about
which function to call; tampering with the flag from outside breaks decryption. Limits: ≤ 8192 chunks, stream text ≤ 64 KiB − 64 B,
a stream ≤ 30 minutes, ≤ 60 s between frames (if the source is silent, the sender sends an empty chunk every 15 s). After
the last chunk the recipient answers `"ok"`. A QUIC stream reset, a timeout or a decryption error interrupts the stream.

**Final message.** The sender creates the final `text` message (signature, author counter, everything per §12) with the **salt**

```
final_salt = HKDF-SHA256(salt = id, ikm = secret, info = "x/stream/v0/final-salt")
```

instead of a random one (`envelope-core.salt`), puts it in the queue, waits for delivery confirmation (≤ 5 s) and only then sends
the last chunk `{end, final_id}`. The salt is still unpredictable to anyone but the two sides of the link: the final message's ID
cannot be guessed from the text (§12). The final message's text is the whole stream text; if the source broke off (the agent crashed or timed
out, the input was interrupted, the text is longer than the limit), it is the text that arrived plus the string `"\n\n[interrupted]"`, `end = interrupted`.
If the final message needs approval (secret scanner), the last chunk is `{end: "cut"}` without `final_id`; after the owner approves,
the final message goes through the ordinary queue with the same salt.

**The recipient learns about the final message** in two ways: (1) the last chunk with `final_id`: if a message with this ID is already in the link's
history, its author is the contact and its `salt` equals the stream's `final_salt`, a `final` event; (2) any new incoming `text`
on the link whose salt equals the `final_salt` of a recent (≤ 15 minutes) unfinished stream: a `final` event (link dropped, final message
after approval, final message arrived after the last chunk). An announced final message that has not arrived within 30 s: `interrupted`. A final message without
a stream (a node without §20, level 1–2) is an ordinary incoming message.

**What the network and the relay see.** As with messages: ciphertext under the link's TLS; chunk sizes are padded to buckets, but the number of chunks
and the moments they are sent are visible (the rhythm of writing), which is why streams are only for levels 3+.

## 21. A side's agents: sub-identities in a link (v0.2, SPEC §5; DECISIONS D-75)

SPEC §5: "the owner's agents are sub-identities inside a link, signed by its link-root key; the contact sees "Bob",
"Bob / claude-backend"". The trust level stays per link (SPEC §9: a person and their agents are one contact).

**Node features**: a link request on every new connection after `hello`:

```cddl
link-request  /= { "features": { "list": [* tstr] } }     ; the sender's features
link-response /= { "features": { "list": [* tstr] } }     ; the recipient's features
; known: "agents/0", this section; "addr/0", §23; "file-withdraw/0", §19; "no-agent/0", §23; "device/0", §24;
; "picture/0", §25; "stream-agent/0", §20; "file-addr/0", "file-saved-as/0", §19; "agent-connect/0",
; "agent-approve/0", "agent-stop/0", §24; "urgent/0", §23. Unknown
; names are skipped; ≤ 32 names of ≤ 32
; characters each
```

Each side learns the other's features: the one that connected from the response, the one that accepted from the request. A node without §21
(`0.1.0-preview.1`) does not parse `features` and answers `rejected{"malformed"}`: it has no features. A node
remembers the contact's features (until the next connection) and **sends nothing from §21 to a node without `agents/0`**: agent
messages to such a contact are signed by the link-root, as before (the agent's name stays only in the side's own history).

**An agent's key** is Ed25519, **unique per link** (32 random bytes from the OS; nothing shared between links, SPEC §5);
the secret is in the node's encrypted DB; the node signs, and the agent (process) never sees the key. It is announced with a history message:

```cddl
envelope-core.type = "control"
envelope-core.body = { "agent": agent-announce }
agent-announce = {
  "name": tstr,                      ; the name shown to the contact: [A-Za-z0-9._-]{1,64}
  "key": bstr .size 32,              ; the agent's public key in this link
  "state": "active" / "revoked",
}
```

- The `author` of an announcement is **only the side's link-root**: its signature (§12, context: link, recipient's key, `n`, `core`) is
  the link-root's signature over the agent's key. An announcement with `author` = the agent's key is rejected.
- After the announcement, the side's messages with `author` = `key` come from this agent: the §12 signature with the same construction, using the
  agent's key. The side has **one** counter `n` for the owner and all of its agents; the agent's key is valid for `n` greater than the `n` of
  the announcement and (if revoked) less than the `n` of the revocation. In the history, the verification chains (§16), rollback (§17) and the divergence point,
  the side is still the link-root: an agent's message is stored under the side (`messages.author`), the key separately
  (`messages.agent_key`), so summaries, `chain` and the vectors of appendix B do not change.
- The recipient checks (`antenna_core::agentid::check_incoming`; on `deliver` and on `resend`): the author is the link-root of one
  of the sides or a key announced by the side before this `n` and not revoked, otherwise `rejected{"unknown_author"}`;
  the signature with this key, otherwise `bad_signature`; in an announcement: the name follows the rules, the key is a valid Ed25519 point not of small
  order and not the link-root of either side, the key is not yet known (or is known for the same side under the same name:
  a repeat), a revoked key does not become `active`, a revocation applies only to an announced key, ≤ 64 keys per side in a link.
- The announcement is sent **before the agent's first message in the link**, in one transaction with it (the ordinary queue: delivery in
  order, resend in order of `n`). Until the agent has written to the contact, the contact does not know about it (the list of
  agents is not revealed in advance). A wake agent with the default name `wake-<contact label>` is announced as `wake`: the label is
  the owner's local name for the contact (the same name appears in `actor` of the §18 receipts).
- If a resend after a rollback displaced the side's own not-yet-delivered announcement, the key is forgotten: the agent's next message
  will use a new key with a new announcement. The side's own announcement, returned by the contact in a resend, is recorded as a
  known key without the secret (it cannot be used for signing; there will be a new one).
- Announcements are service messages: they do not go into the feed (`history`, `inbox`, `message` events); the owner gets `contacts[].agents`
  and `peer_kind`, messages get `via_agent` (CONTROL §17). A revocation (`revoked`) is accepted and displayed.
- **Revocation** (0.2.0): when the owner removes an agent, the node sends a `control`/`agent` message with the same name
  and key and `state: "revoked"`, signed by link-root, in each link where the key was announced, through the ordinary
  queue, and deletes the key's secret. The contact accepts the key only for `n` below the revocation's. An agent created
  later under the same name gets a new key with a new announcement (the contact lists both: the old one `revoked`). A
  revocation needs no feature beyond `agents/0`: nodes since `0.1.0-preview.2` accept it. A link that cannot send at that
  moment (a rollback, an unfinished rekey) keeps the key valid at the contact; nothing signs with it any more.

Verification: unit tests `antenna_core::agentid` (an agent key before its announcement, an announcement not signed by the link-root, an agent
announcing an agent, a signature for another recipient, a key after revocation: all rejected), integration tests
`crates/antenna-cli/tests/peer_agents.rs` (two agents and owner A → B sees who wrote, history verification and the copy check after
a restart), compatibility with `0.1.0-preview.1`: `tests/peer_agents.rs::legacy_*` (the preview.1 release binaries).

## 22. LAN without internet: mDNS with link aliases (v0.2, SPEC §4, §18; DECISIONS D-77)

SPEC §4: "LAN: discovery via mDNS, works without internet; off by default and turned on for trusted networks:
on public Wi-Fi, mDNS reveals the node's presence". This is not a link request but a route hint: the addresses found
are added to the saved ones when connecting, and TLS checks the contact's key (accept-list, §13). The owner turns it on
(`antenna lan on`, password); it applies only to links to which **this** node gave level 3+ (levels 1–2 are relay
only, §11).

**An alias instead of the EndpointId.** iroh's stock mDNS (`iroh-mdns-address-lookup` 0.6, `swarm-discovery`) announces the
instance name = the EndpointId, the link's permanent address (an observer on the network could use it to recognize the node on another network and count
its links). Instead, the node announces an alias (the service is the shared `_irohv1._udp.local`, like any iroh node):

```
K_lan = HKDF-SHA256(salt = "x/lan/v0/salt", ikm = link_id ‖ min(root_A, root_B) ‖ max(root_A, root_B), info = "x/lan/v0/key", 32)
seed  = HMAC-SHA256(K_lan, "x/lan/v0/beacon" ‖ E ‖ u64be(t))      ; E is the announcing side's EndpointId, t = ⌊unix_s / 3600⌋
name  = Ed25519-PublicKey(seed)                                     ; only the mDNS instance name (52 base32 characters)
```

`root_*` are the sides' link-root Ed25519 keys (§7); `min`/`max` are bytewise, so both sides get the same `K_lan`. The listener
computes the names of its contacts (level 3+) for the epochs `t − 1`, `t`, `t + 1` and compares them with what it finds. Without the `link_id` and
the link keys (known to the two sides of the link; the `link_id` never goes onto the network outside TLS) the name cannot be computed or linked to
other epochs and links.

**What goes onto the network.** The listener (while the mode is on) sends only PTR queries for `_irohv1._udp.local` (≈ once a second),
without its own names and addresses. An announcement (an instance with an alias, SRV/A) is made only **when needed**: there is something to
deliver to the contact (or to announce itself after unlock, §12 `hello`) and there is no connection; it lasts 2 minutes after
the last such attempt; once a connection appears, the announcement is withdrawn; a new epoch means a new name. Addresses are only
local ones (IPv4 RFC 1918, link-local, loopback); no relay, no user data in TXT, no CGNAT/Tailscale and no
public IPv4/IPv6.

**A contact is found**: the addresses (≤ 8, the same filters) are remembered for 10 minutes and added to the hints when dialing; the node
connects by itself (no more than once every 3 s per alias): the contact announced itself, so it has something to deliver. From there it is an ordinary
link: `hello` updates the saved addresses, `features`, history verification, the queue.

**What this does not hide (honestly, review D-78).** An observer on the same network sees that iroh mDNS queries come from this IP and,
from time to time, announcements with changing names; the number of simultaneous announcements ≈ the number of contacts that currently
have something to be delivered. The announcement contains the **port** of the link endpoint, and it is permanent (kept across restarts, D-18):
by the port, one link's announcements can be linked across epochs and networks, and by connecting to it an observer gets
the public key of the link endpoint (iroh does not hide the server key in TLS; scanning UDP ports without mDNS gives the same). A direct
connection on the LAN shows the ALPN `x/link/0` in the cleartext ClientHello: Antenna is visible as Antenna. All of the node's private
addresses are announced, including VPN 10.x and Docker bridges 172.17.x. Anyone on the network can substitute the addresses in an announcement with someone else's alias:
the found addresses are merged (freshest first, ≤ 16), the real ones are not erased, TLS checks the key; the node
only gets failed attempts at foreign addresses, and the attacker gets our IP and the link port. A flood of foreign names on the network grows
the peer tables of the mDNS crates (only expiry cleans them): the listener is recreated every 10 minutes, the crates' log is
errors only; our own bounded parsing of responses comes later.

Verification: `lan::tests` (aliases per link, side and epoch; the address filter), `crates/antenna-cli/tests/lan.rs`, in
a separate network namespace (`unshare -rn`, only `lo` with multicast, no internet): two `antennad` instances without a relay
find each other only through mDNS after their ports change; nodes whose relay disappeared bring their links up and find each other;
level 2 links do not go onto the LAN.

## 23. Addressing and topics (v0.2, SPEC §5, §9; DECISIONS D-90)

A link is between two nodes, and a side's agents (§21) used to read everything the other side sent. A message now
names who it is for and may belong to a topic, a thread for one task. Both are optional fields of `envelope-core`,
so they are covered by the message ID and the author's signature (§12) like everything else in `core`.

```cddl
envelope-core /= {                   ; §12, plus:
  ? "to": to,
  ? "topic": topic,
  ? "urgent": true,                  ; the owner's "interrupt now" (urgent/0, below)
}
to    = "person"                     ; the recipient side's owner
      / "everyone"                   ; the owner and the agents its owner allows to read such messages
      / { "agent": tstr }            ; one agent of the recipient side, by the name it announced in this link (§21):
                                     ;   [A-Za-z0-9._-]{1,64}, not "owner"
topic = { "id": bstr .size 16,       ; random, chosen by whoever started the topic
          "title": tstr }            ; 1–120 bytes of UTF-8, no control characters
```

- **Only on `text` messages** and **only to a node that answered the feature `addr/0`** (§21 `features`). A node
  without it (`0.1.0-preview.3` and older) parses `envelope-core` strictly and refuses unknown fields: the message would
  be `failed` after five rejections. To such a node the fields are not sent; the sender keeps the address and topic in
  its own history only. A recipient refuses (`bad_request`) `to` or `topic` on another type, a malformed agent name or
  title. **Since 0.2.0 also `to` (never `topic`) on a `file` message** (an offer, §19), only to a node that answered
  `file-addr/0`; a node without it refuses `to` on a non-text message, so the sender keeps the offer's address in its
  own history only.
- **No field, the old bytes.** Without `to` and `topic` the encoding of `core` is byte for byte what a node without
  `addr/0` writes (the fields are skipped, not `null`), so plain messages hash and sign as before.
- **History verification does not change.** The address and topic are part of `core`, hence of the message ID; the
  author chains, summaries, the divergence search and rollback detection (§16–§17) work over IDs and counters and see
  nothing new. Appendix B's vectors are unchanged.
- **Who decides what an agent reads** is the recipient's daemon, by the address in the signed `core` (CONTROL §20):
  a message for one agent reaches only that agent; for the person, only the owner (and the link's wake agent, which
  answers for the owner); for everyone, the agents the owner allows. A message without `to` (an older node) counts as
  for everyone. This is a policy of the recipient's node about its own agents, not a protection against the
  recipient's owner, who reads everything in the link. **A file offer** (0.2.0, PG-19) follows the same rule for an
  address to one agent or to the person; an offer to everyone or without an address stays visible to every agent with
  the link, as before offers could be addressed (an older sender cannot address one). The answer to a file request
  is addressed to the side's agent that signed the request (a 0.2.0 node signs an agent's request with the agent's
  key, §21); a request signed by link-root gets an answer without an address.
- **Topics are organization, not a channel.** Whoever is in the link reads every topic; there is no key, no separate
  ratchet and no access rule per topic. A topic's ID is random so that two titles that happen to be equal at
  different times are not merged by the other side unless the sender continues the same topic.
- **Defaults** (the sending node's policy, CONTROL §20): the owner's message goes to the person; an agent's message
  is a reply to whoever wrote the last message it read on the link (the person, or the contact's agent by `via_agent`)
  and continues that message's topic.
- **A message for an agent nobody has** (feature `no-agent/0`, 0.2.0). A name in `to` is only the sender's guess: an
  agent may never have existed under it, or the app the sender had in mind may be connected under another name. When
  a new `text` message arrives addressed `{"agent": name}` and none of the recipient's agents answers to that name in
  this link (an agent with the link in its scope, under the name it announced, the link's wake agent as `wake`), the
  recipient's node writes a receipt `deliver` / `no_such_agent` with `actor` "owner" and `refs` = the IDs of such
  messages (§18). The message itself stays delivered: the owner reads every message of the link. The receipt is sent
  **only to a node that answered `no-agent/0`** (an older node refuses an unknown receipt action, so it keeps today's
  behaviour: "delivered", and nobody tells the sender) and **only to contacts of level 3+**: below that, a contact
  could probe which agent names exist on the node, and level 3 is where reading starts (SPEC §4). A message that
  comes again (a resend) is not answered twice. The sender's node, on such a receipt about one of its own messages,
  marks the message and tells the owner (CONTROL §26: `no_agent`); the names the contact *can* be addressed by are the
  agents it announced (§21).

**The owner's urgent message** (feature `urgent/0`, 0.2.0, D-133; experimental). `urgent: true` in `core` asks the
recipient to interrupt the addressed agent's turn instead of letting the message wait until the agent is idle. A
sender writes it only on a `text` message of its owner (link-root, never an agent's key), addressed `{"agent": name}`,
only to a node that answered `urgent/0` (an older node parses `core` strictly and would refuse it: the message then
goes without the field, and the sender's owner is told), and only to a contact the sender has at level 5. The field
is `true` or absent; `false`, the flag on another type or address, or an agent as the author are a malformed message
(`bad_request`). The recipient **honours** it only when the contact is at level 5 there (its owner's own computer,
D-99), the message arrived by `deliver` (never in a `resend`), its `ts` is at most 10 minutes old and at most 2
minutes ahead of the recipient's clock, and that agent was not interrupted by an urgent message in the last 30 s;
otherwise the message is delivered as a normal one. Either way the recipient writes a local audit entry (`urgent`,
`allowed` or `refused` with the reason). The flag is part of `core`, so it is covered by the message ID and the
author's signature and changes nothing in history verification; a plain core is the old encoding. How the recipient
interrupts its agent is its own (CONTROL §33).

Verification: `antenna_proto` tests (a plain core is byte for byte the old encoding; the old strict parser refuses
the new fields; the round trip and wire shape of every address; `urgent` refused by a parser without it and by the
format rules), `crates/antenna-cli/tests/addressing.rs` (who reads
what, replies and topics on both sides, history verification and the copy check across addressed and plain messages
after a restart), compatibility with `0.1.0-preview.3` release binaries:
`tests/addressing.rs::a_preview3_node_gets_no_addressing_fields`. A message for an agent nobody has:
`crates/antenna-cli/tests/chats.rs` (`a_message_to_an_agent_nobody_has_is_answered_not_delivered`: the receipt, the
mark and the names; `a_contact_below_level_3_cannot_probe_agent_names`; with `0.1.0-preview.7` release binaries,
`a_preview7_node_neither_gets_nor_triggers_the_no_agent_receipt`, `#[ignore]`, run with `ANTENNA_PREVIEW7_BIN_DIR`).

## 24. Own devices: status, approvals from another own device, a lost computer (preview, D-114; experimental)

SPEC §9 amended by D-99: trust level 5 is the owner's own computer. An owner with several computers needs one view of
them (their versions, health, agents and the requests waiting) and to answer an approval request of one computer from
another (D-106). Nothing here is part of the history: it travels as a link request `device`, sealed with the link's
session exactly like `stream_open` (§20), between two contacts that have each other at level 5.

**Feature** `device/0` (§21 `features`). A node sends `device` only to a contact it has at level 5 whose node answered
`device/0`; a node without it never gets one. A node serves `device` only from a contact it has at level 5 (otherwise
`rejected{"level"}`, before anything is decrypted), and each side checks its own level: both must be 5 for anything to
flow both ways.

```cddl
link-request  /= { "device": { "blob": routing-blob } }   ; E2E: the plaintext is CBOR(device-msg), outside the history
link-response /= { "device": { "blob": routing-blob } }   ; E2E: the plaintext is CBOR(device-reply)

device-msg = { "status": device-status }                  ; reply: "ok"
           / { "challenge": {} }                          ; reply: device-reply.challenge
           / { "decide": remote-decision }                ; reply: device-reply.decided, or rejected{code}
device-reply = { "challenge": { "nonce": bstr .size 32, "expires_ms": uint } }
             / { "decided": { "id": tstr, "state": tstr } }

device-status = {
  "v": 0, "at_ms": uint,
  "name": tstr,                         ; host name, ≤ 64 bytes
  "os": tstr, ? "os_version": tstr,     ; "macos" / "linux"; "macOS 27.0", "Ubuntu 26.04 LTS" (≤ 64)
  "arch": tstr, ? "memory_bytes": uint,
  "version": tstr,                      ; "antennad 0.2.0 (abc1234)", ≤ 64
  "update": { "auto": bool, ? "staged": tstr, ? "staged_state": tstr, ? "last": tstr, ? "last_result": tstr,
              ? "last_at_ms": uint },
  "health": [* { "code": tstr, "severity": "problem" / "warning", ? "count": uint }],      ; ≤ 16, doctor codes
  "agents": [* { "name": agent-name, ? "app": tstr, "state": tstr, ? "last_seen_ms": uint }], ; ≤ 64
  "approvals": [* device-approval],     ; pending, newest first, ≤ 32
  "pending_approvals": uint,            ; how many are pending in all
  "lend": bool,                         ; "Lend this computer to my teams"
  "keys": [* { "key_id": tstr, "public": bstr .size 65, "label": tstr, "kind": "touch_id" / "password" }],  ; ≤ 9
  "accepts": [* tstr],                  ; which of the recipient's keys the sender accepts (key IDs), ≤ 9
  "lost": [* { "keys": [+ bstr .size 65], "at_ms": uint }],   ; computers the sender revoked as lost, ≤ 32
}
device-approval = { "id": tstr, "action": tstr, "requester": tstr, "contact": tstr, "contact_trust": 1..5,
                    ? "target": tstr, "reasons": [* tstr], "quote": tstr, ? "quote_withheld": true,
                    "fingerprint": tstr, "created_ms": uint, "expires_ms": uint, ? "completes": true }
remote-decision = { "request": tstr,                     ; the exact signed text below, ≤ 1024 bytes
                    ? "nonce": bstr .size 32, ? "key_id": tstr, ? "sig": bstr .size 64 }
```

Parsing is strict (`deny_unknown_fields`, no trailing bytes) and every limit above is checked; a status that breaks one
is `rejected{"malformed"}`. A later change to these shapes is a new feature name, not a new field.

**Status.** Each node looks every 2 s at what it would tell its own devices and sends a status to each connected one when
it changed, when a new connection came up, and at least every minute; an own device without a connection is dialled at
most every 30 s (a new link has no connection until something is sent). The status carries facts only: no message
text, no file content, no secret. A pending request's quote is cut to 1 KiB and **withheld** (empty, `quote_withheld`)
when the secret scanner finds anything in it: the reasons (`secret:password`) say what kind, the text stays on the
computer that asked. The receiver keeps the last status (without its requests) for when the device is offline; the
requests live in memory only.

**Keys.** A node offers the keys it answers other devices' requests with: its owner keys (§22 of CONTROL: the window's
Secure Enclave keys behind Touch ID) and its own **device key**, a P-256 key its daemon generated (`aws-lc-rs`) and keeps
in the encrypted database, which it uses only after the owner typed the password on that computer, for one request.
The receiver accepts a key only after its owner **confirmed** it with the password (`device_keys_confirm`); a confirmed
key that the device stops announcing (Touch ID turned off there), or announces with another point under the same ID, is
dropped; lowering the device below level 5 drops all of its confirmed keys, and raising it back does not restore them.

**A remote approval.** The device where the owner is asks the computer that holds the request for a challenge
(`challenge`): 32 random bytes, valid 60 s, used once, good only for a decision that arrives over the same link (at most
16 outstanding per link). The owner signs, with Touch ID there (the window) or by typing the password there (the daemon,
with its device key), the D-102 owner proof over that challenge and the exact text

```
{"cmd":"remote_approve","link":"<link_id hex>","id":"<approval id>","fingerprint":"<ApprovalInfo.fingerprint>"}
sig = ECDSA-P256-SHA256(key, "antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(text))      — 64 bytes r ‖ s
```

and sends `decide {request: text, nonce, key_id, sig}`. The text names the link as the signer's node knows it, so a
proof made for one computer's request cannot be relayed to another computer over another link. The receiver checks, in
this order: the device is at level 5 here (`level`); at least one of its keys is confirmed here (`forbidden`); its
remote decisions are not paused (`rate_limited`, below); the text parses strictly as one of the two shapes and names
this link (`bad_request`); the challenge was issued here to this link, is fresh and unused, and is taken by this attempt
whatever follows (`challenge_invalid`); the key is one confirmed for this device (`owner_key_unknown`); the signature
holds (`proof_invalid`). Then the request is approved exactly as the owner would approve it here, with the fingerprint
compared (`approval_mismatch`, `not_found` when it is no longer pending), carried out by the daemon when it completes
by itself (D-100), and logged as `approved_from_own_device` with a `device_decision` entry on the device's link naming
the request and the key. Three failed proofs in a row from one device pause its remote decisions for a minute, doubling
with each further failure up to eight minutes.

`{"cmd":"remote_deny","link":…,"id":…}` denies a request with no challenge and no signature, as a local `deny` needs no
password (D-84), under the same level and confirmed-key checks. **Only approve and deny exist** among the owner's
decisions on requests: no other owner command is reachable over `device`, apart from the stop below
(`agent-stop/0`), which only takes work away.

**A lost computer.** "Revoke this computer" on one own device puts the lost computer's announced public keys on a list
the node includes in its status for 30 days (`lost`), then revokes the link as `revoke` does. A device that receives
such a status from a contact it has at level 5 drops its confirmed keys of every own device that announced one of those
keys (it only takes a way in away) and marks it reported lost; the owner then revokes it there too, or clears the mark.
Contacts linked only to the lost computer cannot be told this way; their links are paired again from a new computer.

**A connection between agents** (feature `agent-connect/0`, the agent map, CONTROL §30, D-123; experimental). The
owner draws a line on one own computer between its agent and an agent of another own computer. The first computer sets
its own side (its agent's default counterpart) and asks the other for the other side:

```cddl
device-msg   /= { "connect": { "agent": agent-name,          ; the recipient's agent
                               ? "peer_agent": agent-name,   ; the sender's agent, as announced on this link; absent: disconnect
                               ? "tasks": bool } }           ; the recipient's agent takes the sender's messages as tasks or not
device-reply /= { "connect_asked": { "id": tstr, "state": "pending" / "unchanged" } }
; in device-status.agents[], only to a node that announced agent-connect/0:
;   ? "counterpart": agent-name / "",   ; this agent's default counterpart is the recipient's agent (or "": its person), on this link
;   ? "takes_tasks": true               ; it takes the recipient's messages as tasks
```

A node sends `connect` and the two status fields only to a contact whose node announced `agent-connect/0`: a node with
`device/0` alone parses `device` strictly and would refuse them (a status without the fields is byte for byte the old
encoding). The recipient changes nothing by itself. It checks, in this order: the sender is at level 5 here (`level`,
before anything is decrypted, and again when the request is handled); the names are agent names, and `tasks: true`
comes only with `peer_agent` (`bad_request`); its agent exists (`not_found`), is not a link's wake agent, a team's
worker or a local-model agent (`denied`) and has this link in its scope (`bad_request`); at most 8 connection
requests from this sender wait (`rate_limited`). When the agent already has exactly that, the reply is `unchanged`.
Otherwise it makes an **approval request** for its own owner (action `connect_agent` or `disconnect_agent`, reason
`agent_connect`, the requester the sender's label here, a text the recipient writes itself from the checked names)
and answers `pending` with the request's ID. The request is shown like any other: in the recipient's approvals, and in
its status to its own devices, where the owner answers it with the remote approval above. Once approved, the recipient
carries it out (D-100): it checks the level and the scope again, sets its agent's default counterpart on this link to
the sender's agent (or clears it when its counterpart is on this link), and changes its task authority for this link
when `tasks` says so. A disconnect never clears a counterpart on another link. A denial or an expired request changes
nothing.

**An agent that answers approvals in the owner's place** (feature `agent-approve/0`, approver agents, CONTROL §31,
D-127; experimental). The owner of one own computer names an agent of another own computer an approver. The computer
that holds a request decides each answer; the approver's computer carries it, signed by the agent's own key:

```cddl
device-msg   /= { "agent_challenge": { "id": tstr } }        ; reply: device-reply.challenge, bound to this request
             /  { "agent_decide": agent-decision }           ; reply: device-reply.decided, or rejected{code}
agent-decision = { "request": tstr,                          ; the exact signed text below, ≤ 4096 bytes
                   "nonce": bstr .size 32,                   ; the recipient's challenge for that request
                   "sig": bstr .size 64 }                    ; Ed25519 by the agent's key in this link (§21)
; in device-status, only to a node that announced agent-approve/0:
;   ? "approvers": [* { "agent": agent-name,                 ; the recipient's agent the sender's owner made an approver
;                       ? "agents": [* agent-name],          ; whose requests (the sender's agents); absent: all
;                       ? "kinds": [* tstr] }],              ; send_message / share_file / request_file / accept_file
; in device-approval:
;   ? "approvers": [* agent-name]                            ; which of them may answer this request now
```

```
{"cmd":"agent_decision","link":"<link_id hex>","id":"<approval id>","fingerprint":"<fingerprint>",
 "decision":"approve"|"deny","agent":"<name>","key":"<agent key hex>","reason":"<1–500 characters>","clean":true|false}
sig = Ed25519(agent key, "antenna/agent-decision/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(text))
```

A node sends the new messages and the status fields only to a contact whose node announced `agent-approve/0`; a status
without them is byte for byte the older encoding. The approver's node sends an answer only for a request the other
computer's last status offers to that agent, only while it has that computer at level 5 and the link is in the agent's
scope; it asks for a challenge naming the request, signs the text with the agent's key in this link (the agent never
sees it) and sets `clean` to whether the agent's session read anything of a contact below level 5 there (an answer that
is not clean is still sent, so the other computer's owner is told why). The recipient checks, in this order: the sender
is at level 5 here (`level`, before decryption and again when handled); its approvers' answers are not paused
(`rate_limited`); the text parses strictly and names this link (`bad_request`); the challenge was issued here, on this
link, for this request, is fresh and unused, and is taken by this attempt (`challenge_invalid`); the owner named that
computer's agent of this name (`forbidden`) with this key (`owner_key_unknown`), and the key is still announced under
that name and not revoked (`owner_key_unknown`); the signature holds (`proof_invalid`); `clean`; then the scope and the
level-5 circle of CONTROL §31 at that moment (`forbidden`, with the reason on the owner's card). Then it approves or
denies exactly as its owner would, with the fingerprint compared (`approval_mismatch`), carries an approved request
out (D-100), and logs the answer with the agent as the actor. Three unverifiable answers in a row pause that
computer's approvers for a minute, doubling up to eight. Lowering the computer below level 5 drops every delegation to
its agents; raising it back does not restore them. The label, the key, the algorithm and the challenge pool are not
the owner proof's: an agent's answer never verifies as an owner proof, nor the reverse.

**Stopping an agent of an own computer** (feature `agent-stop/0`, 0.2.0, D-133; experimental). The owner on one own
computer stops an agent of another and the processes it started:

```cddl
device-msg   /= { "stop_agent": { "agent": agent-name } }
device-reply /= { "stopped": { "agent": agent-name,
                               "how": tstr,                ; terminal / process / app / resident / wake / worker / local / none
                               "processes": uint, "left": uint,
                               "names": [* tstr] } }       ; ≤ 16 process names of ≤ 64 bytes, no control characters
```

A node sends `stop_agent` only to a contact it has at level 5 whose node announced `agent-stop/0` (a node with
`device/0` alone parses `device` strictly and would refuse it). The recipient checks that the sender is at level 5
there (`level`, before anything is decrypted, and again when it carries it out), that the name is an agent name
(`bad_request`), and that this sender asked for at most 6 stops in the last minute (`rate_limited`); then it stops
its agent exactly as its owner's `agent_stop` would (CONTROL §33; `not_found` without such an agent), logs an
`agent_stop` entry on the sender's link, tells its owner's subscriptions (`agent` event, `stopped`, by the sender's
label) and answers `stopped`. No challenge and no proof: a stop takes work away, like a denial (D-84), and the sender
is the recipient's own computer at ∞. The sender checks the answer's limits before it shows the names.

**What this protects and what it does not.**

| Threat | Answer | Test |
| --- | --- | --- |
| A contact that is not an own computer announces itself or reports a computer lost | level 5 checked before decryption and again before anything is stored | `devices.rs` step 9 (bob's forged report), both checks off seen failing |
| A replayed decision | the challenge is taken by the first decision that names it | `challenge_invalid`, live and unit |
| A proof made for another request, another fingerprint or another link | the signature covers the exact text, which names the link, the request and the fingerprint | `proof_invalid`, `approval_mismatch`, `bad_request`; unit and live |
| A key the owner never confirmed here, or a device lowered below ∞ | confirmed keys per device; dropped on a level change | `owner_key_unknown`, `forbidden`; live |
| A compromised own device | it can approve only with a key the owner confirmed for it, one request per proof; with Touch ID keys only, the finger on that device too | residual: an own device is trusted at level 5 anyway (D-99) |
| A secret in a request's text | withheld from the status; the reasons say what kind | live: the quote with a password does not travel |
| An own device draws a connection on this computer | only an approval request, applied when this computer's owner approves it; a counterpart on another link is never cleared | `connections.rs`: nothing before the approval, a denial applies nothing, a computer not at ∞ both ways makes no request (each with a negative control) |
| An approver's answer replayed, made for another request or another link | the challenge is bound to the request and the link and taken by the first attempt; the text names the link, the request and its fingerprint | `delegation::remote` unit tests with real keys; `approvers.rs`: a second answer changes nothing |
| An answer from an agent the owner did not name, or signed by another key | the delegation names the agent and its key; only that key verifies; a revoked key is refused | `delegation::remote` (forged signature, another key, revoked); `approvers.rs`: an agent made again under the same name gets nothing |
| A contact's text injected into the approver | an approver that read a contact below 5 does not count (`clean`), nor a request that carries such data | `approvers.rs`: tainted on its own computer, refused with the reason on the card |
| The approver's computer lowered below ∞ | its delegations are dropped and not restored | `approvers.rs` |
| A computer that is no longer at ∞ stops this one's agents | level 5 checked before decryption and again when the stop is carried out | `urgent.rs`: refused at level 4, both checks loosened seen failing |
| A stop storm from an own computer | at most 6 stops a minute per link | `agent_stop::StopState` |

Verification: `antenna_proto::device` (wire shapes, strict parsing, limits), `antenna_core::devices` (the decision check
with each refusal, the device key's proofs, confirmed keys following announcements, lost reports, the pause), and
`crates/antenna-cli/tests/devices.rs` with real daemons (the view's data both ways; approvals from the other device with
a software Touch ID key and with the device key; every refusal above; a lost computer reported to a third own device;
lending). Negative controls, each seen failing: the level checks off (a forged lost report removed keys), the challenge
not taken (the replay passed the proof check), the signature not verified (another request approved), the trust hook off
(old keys accepted after a raise), the lost report not applied, the link not compared (unit).

Approver agents (`agent-approve/0`): `antenna_proto::device` (the new messages and fields round-trip, a status without
them is the old encoding, the strict decision text, its label distinct from the owner proof's),
`antenna_core::delegation::remote` (the check with real Ed25519 keys: an answer verifies once; a replay, a challenge
for another request, a forged signature, another key, a text changed after signing, another link, an owner proof's
message, a key not named, a revoked key are refused), and `crates/antenna-cli/tests/approvers.rs`
(`an_approver_on_another_own_computer_answers_with_its_key`, real daemons; D-127 lists what it covers and its negative
controls).

## 25. Profile pictures (0.2.0, D-115)

A side tells its contact which picture to show for its owner and for each of its agents: a **drawn picture** by id, or
an **own photo**. Only to a node that answered the feature **`picture/0`** (§21 `features`); a node without it would
refuse the unknown body and the two copies of the history would differ, so it gets nothing and its owner keeps seeing
initials (`0.1.0-preview.8` and older).

```cddl
envelope-core.type = "control"
envelope-core.body = { "picture": picture }
picture = {
  ? "agent": tstr,                ; one of the side's agents by its announced name (§21); absent: the side's owner
  ? "drawn": tstr,                ; a drawn picture: "<set>/<animal>", [a-z0-9]{1,16} "/" [a-z0-9][a-z0-9_-]{0,31}
  ? "photo": {
      "mime": "image/jpeg" / "image/png" / "image/webp",
      "data": bstr,               ; 1…65536 bytes
    },
}                                 ; neither "drawn" nor "photo": the picture is removed (initials)
```

- **Author.** Only the side's link-root, like an agent announcement (§21): the side vouches for its agents' pictures,
  and an agent cannot set its own or another agent's picture. A picture with `author` = an agent key is rejected
  (`bad_request` on `deliver`, not taken on `resend`). Not both `drawn` and `photo`; unknown fields are refused.
- **Drawn pictures travel as their id only.** The receiver draws the id from its own copy of the sets; an id it does
  not know (a set added in a later release) is shown as initials, so a new set needs no protocol change.
- **A photo** is at most 64 KiB inside the signed message (the size of the largest text, §12; resend batches are
  sized by bytes). The sender of this implementation makes it from its owner's image file in its check sandbox (§19
  step 4): only the rebuilt pixels, cropped to the middle square, at most 512 px, flattened onto white and encoded as
  a JPEG without metadata. **The receiver never shows the bytes it received**: before anything reaches its owner's
  window it checks them in its own sandbox like any received image (type by content equal to `mime`, clean verdict,
  one rebuilt image) and encodes the rebuilt pixels again; a photo that fails stays unshown. A contact at trust level
  1 takes no files (SPEC §9), so its photo is neither checked nor shown; a drawn id is shown at every level (nothing
  is decoded).
- **Which message counts.** The receiver keeps, per subject (the owner, or each agent name), the picture with the
  highest `n`; a removal replaces it like any other.
- **When a side sends.** On a link, the owner's picture and the pictures of the side's agents that the contact already
  knows (announced in this link: a picture never reveals an agent the contact has not heard of, §21) are compared with
  the side's latest picture message in its own copy of the history; a new message goes out when they differ, when the
  owner changes a picture, when the contact's features are learned on a connection, and right after an agent's first
  message in the link. The history is the record of what was sent: a picture message displaced by a resend after a
  rollback (§17) is gone from it, so the current picture simply goes out again.
- Picture messages are service messages: they are not in the feed (`history`, `inbox`, `message` events) and do not
  count as the contact's owner writing (`peer_kind`). They take part in history verification like any message.

Verification: `antenna_proto::picture` (the wire shape, unknown fields refused, the id and size rules),
`antenna_core::agentid::tests::only_the_link_root_sets_pictures`, `antenna_core::pictures` (newest per subject,
shown only when checked and the level allows), `crates/antenna-files/tests/picture.rs` (the real sandbox: metadata
and orientation, a malformed image, data hidden after the image, a type other than the declared one),
`crates/antenna-cli/tests/pictures.rs` (real daemons: drawn ids, an own photo rebuilt on both sides and the received
bytes never served, an agent's picture only after it wrote, level 1, and `#[ignore]` with the `0.1.0-preview.7`
release binaries: no picture message to a node without the feature, the history verifies).

## Appendix A. Test vectors for §7

Inputs (pairing v1): `s = 0x11×32`, `X = 0x22×32`, `E_A = 0x33×32`, `E_B = 0x44×32`, `N_A = 0x55×32`, `N_B = 0x66×32`, `v = 1`,
`KX` and `SUITE` from §7; `P_A`: all fields filled with the byte `0xa1` (`identity_key` 33 B, `root_ed25519` 32 B, `root_mldsa65` 1952 B,
`endpoint` 32 B), `P_B` with the byte `0xb2`; `addrs` for both: `relay = null`, `direct = []` (that is, `addrs(P_B.addrs) = 00 00000000`).

| Value | Hex |
| --- | --- |
| `psk_mac` | `40e04b7f0482cebb95be72ab94c69122560e26ab40d0e8591d7e187f333874a2` |
| `C_B` | `096fa366a8867f0286d2994cf692929d734a281ed0cc7f4973cd3c7484332e57` |
| `TH` | `9cb46025c108ff6a309fe45c0331057da45d8ae289631958968712fbab7624da` |
| `K_A` | `b31f4aa5fde46f5e5af271ca0bb472053120a97bb1526748b2e78ed623fda127` |
| `K_B` | `02a0bcf3dfa72f9a88a39921c270b7d04f21e1e0835ee5164712aa107ae054d3` |
| `link_id` | `bf1b744029928db4e74ae94fe2a0ce658d66407b3b149bd4c70fc7d43ddc6e7b` |
| `kc_B` | `a6006f723a32891eaa84db8d1e2a0552de59de8b58de2674cf9a6ab2dc725045` |
| `SAS` | `169264` |
| `SAS`, emoji (§7) | 🐱🐘🐓🦁🐘🦄 (U+1F431 U+1F418 U+1F413 U+1F981 U+1F418 U+1F984) |

The vectors were obtained in two independent ways and matched: by the Rust implementation (`antenna-core`, test `pairing::tests::regression_vectors`)
and by a script using only the Python standard library, written from the text of §7 (`docs/protocol_vectors.py`).

## Appendix B. Test vectors for link format v1 (§12, §16)

Inputs: `core` = ASCII `"core-bytes-of-the-envelope"`; the author's link-root Ed25519 seed `0x77×32`; `link_id = 0x33×32`;
`recipient_root = 0x44×32`; `n = 2`; the chain: ID `0x11×32`, then `0x22×32`; the fingerprint: `link_id = 0x33×32`, heads
`0x55×32` and `0x44×32` (sorted).

| Value | Hex |
| --- | --- |
| `id = BLAKE3-DK("x 2026-10-02 message-id v0", core)` | `7b68fc614f894f083963a6af39c0c8459e5c02b13f0abc0269322314e4637d28` |
| the author's link-root (public) | `c853ad0f0cd2b619aea92ceec4fd56a24d6499d584ce79257e45cfd8139b60a7` |
| SHA-256 of the signed bytes (§12) | `9e57db6810f59356a55fb9280de1ca49cfea518a81b00a21a161da488f953bf9` |
| `sig` | `7770c44ef6acffd3dc5dd97e7f981f2060586e3897a9b19f87ac4418d397cab805bc844c8daf05d6bd23e1a8918789f2d77d4b194874a42274be6fd79ff2590c` |
| `chain(1)` | `714b85e3169bcc51d0f7979feda9bbf246c362b16312d056815d5f4f6a6fc455` |
| `chain(2)` | `b30e9e7717a0c85b1b150d691bfce0a8e8a33dceb34978b8358c4017adf36779` |
| fingerprint | `809` → 🐼🐶🐓 |

Obtained in two ways and matched: Rust (`antenna-core`, test `history::tests::history_vectors_appendix_b`) and
`docs/protocol_vectors.py` (Python, the `blake3` and `cryptography` packages).
