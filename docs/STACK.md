# STACK — checking the stack on real crates (stage 0)

2026-10-02 · gate before MVP v0.1 · environment: Ubuntu 24.04, KVM virtual server, 16 vCPU, 30 GB RAM;
Rust 1.99.0 (rustup, profile minimal + clippy + rustfmt; pinned in `rust-toolchain.toml`),
clang 18.1.3, cmake 3.28.3, protoc 3.21.12, pkg-config, libssl-dev.

## Principle: proven technology first (maintainer decision, 2026-10-04)

Antenna is built from existing, battle-tested technologies: audited libraries, standard protocols and formats, the operating system's own isolation. Anything new that we create ourselves needs time and a security review before users depend on it, however good it looks: a new mechanism has holes nobody has found yet.

- **Compose before inventing.** Prefer a proven component over a home-made one. When something new is unavoidable, the decision entry says what is new and why nothing existing fits.
- **An experimental track for our own inventions.** New mechanisms (protocol extensions, sandbox techniques, new formats, new agent modes) ship behind a flag or marked "experimental" in previews. They come with their own tests, a written threat analysis, negative and adversarial tests, and a formal model where one applies (as `formal/` does for pairing). They become the default only after review and time in use.
- **No custom cryptography, ever** (SPEC §7, §15): the strictest case of this rule.

The spikes live in `spikes/<name>/`. They are **not** workspace members: each has its own `[workspace]` and `Cargo.lock`
(committed, so the versions are reproducible). They build into the shared `spikes/target`:

```sh
cd spikes/<name> && CARGO_TARGET_DIR=../target cargo run
```

The output of each spike's last run lies next to it, in `run*.log`. "Checked" below means: built, run, output in the log.
Code reading without running is marked as such.

## Table

| Component (SPEC §14) | Crate | Exact version / git rev | License | Checked by a spike | Pitfalls (details in TROUBLESHOOTING) |
| --- | --- | --- | --- | --- | --- |
| QUIC transport, NAT traversal, relay | `iroh` (+ `iroh-relay`, `noq`) | **1.4.1** (iroh-relay 1.4.1, noq 1.4.0; 1.3.0 until 2026-10-27, RUSTSEC-2026-0346…0349) | MIT OR Apache-2.0 | **yes**, `spikes/iroh-conn`: T1–T7 in one process (`run-all.log`) + two processes (`two-process.sh`, `run-two-process.log`) | `presets::N0` publishes addresses to pkarr/DNS by itself, `presets::Minimal` is needed. The accept-list for direct UDP works only after TLS. There is no PSK in the handshake. With relay+IP the contact learns all local IPs, including Tailscale 100.x. With `clear_ip_transports` the debug log says "Not enough addresses" every 100 ms |
| PQ key exchange in the transport's TLS | `rustls` + `aws-lc-rs` (iroh feature `tls-aws-lc-rs`) | rustls 0.23.46, rustls-webpki 0.103.16, webpki-roots 1.0.11, aws-lc-rs 1.18.1, aws-lc-sys 0.45.0 | Apache-2.0 / ISC / MIT (composite, see `cargo metadata`) | **yes**, T6/T7: `X25519MLKEM768` is negotiated directly and through the n0 relay; the TLS exporter is the same on both sides | By default iroh builds with `ring`, which has only X25519. In PQ-only mode (one group) the n0 relay is unreachable: the crypto provider is shared with the TLS connection to the relay. The working mode is prefer-PQ: `[X25519MLKEM768, X25519]` |
| Files, content-addressed, resume | `iroh-blobs` (+ `bao-tree`, `redb`) | **0.103.0** (bao-tree 0.16.1, redb 4.3.0) | MIT OR Apache-2.0 | **yes**, `spikes/iroh-blobs` (`run.log`) | Still 0.x, the API is unstable. Requires `iroh ^1.0.0` and builds with 1.4.1 (and before it 1.3.0) with one iroh version in the tree. `Router::shutdown` shuts the store down by itself |
| E2E Triple Ratchet | `libsignal-protocol` (git) | tag **v0.103.1** = rev `e8cc2dddd578859b4a029c9c94670b24ce2b616a` (2026-09-22) | AGPL-3.0-only | **yes**, `spikes/libsignal-tr` (`run.log`) | Not on crates.io, git only. README: "Use outside of Signal is unsupported", the API changes without warning. Needs `protoc`. A session cannot be set up from our own secret. The default KEM is Kyber1024 (pre-FIPS 203), ML-KEM-1024 is behind the `mlkem1024` feature |
| PQ ratchet SPQR | `spqr` (git, pulled in by libsignal) | tag **v1.6.0** = rev `06959b4708f9b7b1e94d0f8cc835f3958c077e94` | AGPL-3.0-only | **yes**, same spike: SPQR epochs 1→5 over 400 messages, `NegotiationComplete(V1)` | ML-KEM-768 inside (libcrux, feature `incremental`). Verification per the README: hax/F\* prove absence of panics and correctness of field arithmetic, there are ProVerif models; some functions are marked `verification_status(lax)` |
| Hybrid KEM X25519 + ML-KEM-768 (pairing) | `libcrux-kem` `Algorithm::XWingKemDraft06` | **0.0.9** (libcrux-ml-kem 0.0.10) | Apache-2.0 | **yes, but separately**, `spikes/hybrid-kem` (`run.log`); byte-for-byte compatible with RustCrypto `x-wing` 0.1.1 in both directions | **Does not compile in one tree with libsignal/SPQR** (`spikes/combined`, option B). `PublicKey::decode` panics on a short string. A tampered ct gives `Ok` with a different secret (implicit rejection) |
| ML-DSA-65 (link-root signatures, checkpoints) | `libcrux-ml-dsa` | **0.0.10** | Apache-2.0 | **yes**, briefly, in `spikes/combined`: sign/verify, a foreign context and tampering are rejected | Randomness is passed as an array; take it from the OS RNG |
| Ed25519 / X25519 | `ed25519-dalek` / `x25519-dalek` | 3.0.0 / 3.0.0 (in iroh); `curve25519-dalek` 5.0.0 (in libsignal-core) | BSD-3-Clause | indirectly, via iroh and libsignal | biscuit-auth 6 also pulls `ed25519-dalek` 2.2 and `curve25519-dalek` 4.1: two versions in the binary |
| MCP server | `rmcp` | **3.5.0** (default MCP protocol 2026-07-28) | Apache-2.0 | **yes**, `spikes/rmcp-stdio` (`run.sh` → `run.log`): initialize, tools/list, tools/call; an unknown tool → −32602 | By default `serverInfo` = `rmcp 3.5.0`. stdout is taken by the protocol, logs only to stderr |
| Storage: SQLite + encryption | `rusqlite`, feature `bundled-sqlcipher-vendored-openssl` | **0.40.2** (libsqlite3-sys 0.38.2): SQLCipher 4.14.0 community, SQLite 3.51.3, OpenSSL 3.6.3 (vendored) | MIT; SQLCipher BSD-3-Clause; OpenSSL Apache-2.0 | **yes**, `spikes/sqlcipher` (`run.log`): the file has neither the SQLite header nor plaintext; a foreign key is rejected; `rekey` works; no dynamic libssl/libcrypto (`ldd`) | With a wrong key SQLCipher writes `ERROR CORE ...` to stderr. The first OpenSSL build takes about 50 s |
| Capability tokens | `biscuit-auth` | **6.0.0** (2025-07-16) | Apache-2.0 | **yes**, `spikes/biscuit` (`run.log`): issuing, attenuate, offline verification; holder-of-key via a third-party block | **No** holder-of-key out of the box: done with a standard third-party block signed by the holder's key over a nonce. Pulls rand 0.8 and ed25519-dalek 2. A future-incompat warning from `proc-macro-error2` |
| CBOR | `ciborium` + `serde_bytes` | 0.2.2 + 0.11.19 | Apache-2.0; MIT OR Apache-2.0 | **yes**, tests in `crates/antenna-proto` | Without `serde_bytes`, `[u8; 32]` is encoded as an array of numbers, not a bstr |
| CLI | `clap` | 4.6.7 | MIT OR Apache-2.0 | **yes**, `crates/antenna-cli/tests/cli.rs` | — |
| OS key storage | `keyring` | 4.2.0 (not added) | MIT OR Apache-2.0 | **no**, only an inspection of the host (item h) | — |
| The whole stack in one binary | all of the above except libcrux-kem | 580 packages in the graph | — | **yes**, `spikes/combined` (`variants.sh` → `run-variants.log`) | Duplicates: ed25519-dalek 2+3, curve25519-dalek 4+5, sha2 0.9/0.10/0.11, rand 0.8/0.9/0.10, getrandom 0.2/0.3/0.4, aes 0.8/0.9, hmac 0.12/0.13 |

## Items a)–h): what exactly the spikes showed

### a) iroh 1.3 — `spikes/iroh-conn`
- **Connecting by EndpointId.** Relay-only (`clear_ip_transports`, n0 relay `euc1-1`): connect in 68 ms, an echo of 15 B in
  72 ms, 64 KiB in 207 ms, neither side has a single IP path. Direct-only (`RelayMode::Disabled`, 127.0.0.1): connect in
  48 ms. Relay+IP: start through the relay, after 243 ms the direct path with an rtt of 0.65 ms is chosen.
  Two processes: dial only by `EndpointId` + relay URL → connect+echo in 162 ms, `kx=X25519MLKEM768`.
- **Many endpoints in one process.** 50 endpoints were brought up and came online in 16.8 s with sequential startup
  (~0.34 s per endpoint). RSS grew from 66 to 151 MB (debug build): ~1.7 MB and 4 fds per endpoint. 10 of 10 pairwise links
  echoed through the relay. All 50 have the same home relay, i.e. the relay operator sees them from one IP. Each endpoint
  keeps its own relay connection (a ping every 15 s, `iroh-relay` `PING_INTERVAL`) and its own net_report.
- **Accept-list.** The `Router`'s `IncomingFilter` sees `IncomingAddr::Relay { endpoint_id }` even before the handshake.
  We answer an unpaired key with `Ignore`: no reply at all, the attacker times out. For direct UDP the EndpointId is
  unknown before TLS. `EndpointHooks::after_handshake` closes the connection with code 403 after ~60 ms: by then TLS has
  completed and a reply has been sent. Checked with two processes too: an unpaired dial got a 20 s timeout.
  A pre-filter by a secret token in ALPN (`Incoming::decrypt().alpns()`) is unreliable: the ClientHello is often not
  parsed from the first Initial, and with a PQ key share — never.
- **Address publishing.** `presets::N0` = pkarr publish + resolve + DNS lookup. `presets::Minimal` = only the crypto
  provider, no address lookup. mDNS in iroh 1.3 was moved into a separate crate `iroh-mdns-address-lookup` and is not
  enabled by itself.
- **Own relay.** `Builder::relay_mode(RelayMode::Custom(RelayMap))` / `RelayMode::custom([url])`.
  The address for dialing: `EndpointAddr::new(id).with_relay_url(url)` — no lookup needed.
- **PSK in the handshake** — iroh has **none** (searching the sources for `psk` found nothing). There is
  `Connection::export_keying_material` (TLS exporter, T7): the same on both sides and different for different connections.
  PSK and channel binding are done at the application layer.
- **PQ in the transport** (T6): with ring — `X25519`; with aws-lc-rs and the groups `[X25519MLKEM768, X25519]` —
  `X25519MLKEM768` both directly and through the n0 relay. With a single group `[X25519MLKEM768]` the endpoint cannot
  connect to the n0 relay.

### b) iroh-blobs 0.103 with iroh 1.3 — `spikes/iroh-blobs`
Compatible. `iroh-blobs 0.103.0` requires `iroh ^1.0.0`; the tree has one version, `iroh v1.3.0` (`cargo tree -d` is clean
for iroh/noq).
- FsStore → FsStore, 64 MiB. A break at 25 MiB, a store restart, only 38 MiB downloaded on resume. Content and BLAKE3
  matched.
- ACL on the provider (`EventSender`, `ConnectMode::Intercept`): an unpaired EndpointId gets `permission`, 0 bytes.
- Changing 1 byte in the provider's file: the provider resets the stream itself (error 3), the receiver keeps only the
  verified prefix of 2864 KiB out of 4096 KiB, the blob is not complete. The "malicious provider sends garbage" scenario
  was not checked. Receiver-side verification by bao is guaranteed by the design of iroh-blobs; it was not confirmed by a
  separate test.
- **The alternative if iroh-blobs breaks its API** (not implemented): `bao-tree 0.16` over our own iroh stream
  (`ALPN x/blob/0`). The receiver keeps an outboard and a bitfield, requests the missing ranges and verifies chunk groups
  against the BLAKE3 tree. This is the core of iroh-blobs without its store and RPC.

### c) libsignal + SPQR — `spikes/libsignal-tr`
Builds as a git dependency (`libsignal-protocol` from `rust/protocol`), which pulls in `spqr` v1.6.0 itself. Both are
AGPL-3.0-only. The spike's scheme (option 1 from the task):
1. The link's identity keys are pinned in advance (`save_identity` — in production the SAS will cover them). TOFU is not
   used.
2. Bob gives Alice a bundle: identity, signed prekey, KEM prekey, one-time prekey — 1828 bytes over a "verified channel".
   Alice calls `process_prekey_bundle` (PQXDH, 33–39 ms in debug).
3. Exchange: 12 messages ping-pong, a batch of 5 in reverse order, then 400 messages ping-pong.
   Session version 4. SPQR: `StillNegotiating` → `NegotiationComplete(V1)`. Every message has a 37 B SPQR chunk.
   The SPQR epoch grows 1→2→3→4→5 (messages #65, #152, #239, #326): a new ML-KEM-768 shared secret every ~87 messages.
4. Serializing and restoring a `SessionRecord` (6.3 KB) works. A replayed ciphertext is rejected (`old counter`), a
   tampered one — `decryption failed`. A bundle with an identity different from the pinned one is rejected
   (`untrusted identity`).
5. Both KEM prekey types (`Kyber1024` and `MLKEM1024`) give the same result.

That SPQR really takes part in the message keys is confirmed **by the code**: `MessageKeyGenerator::generate_keys(pqr_key)`
→ `MessageKeys::derive_keys(seed, pqr_key, counter)`. The epoch numbers were obtained by parsing the messages' SPQR headers.

**Option 2 (a session from our own shared secret) is impossible through the public API.** The `Handshake` trait is
`pub(crate)`, `initialize_alice/bob_session_record` accept only PQXDH parameters (`pqxdh::InitiatorParameters` /
`RecipientParameters`), and the root key is always derived inside PQXDH. The only way around it is a fork of libsignal.

### d) Hybrid KEM — `spikes/hybrid-kem`, `spikes/combined`
- libcrux **has** a ready construction: `libcrux-kem 0.0.9`, `Algorithm::XWingKemDraft06`
  (X-Wing draft-06: an SHA3-256 combiner over ss_M, ss_X, ct_X, pk_X). There is also `X25519MlKem768Draft00`, but it
  returns two secrets without a combiner — not suitable.
- encaps/decaps work: pk 1216 B, sk (seed) 32 B, ct 1120 B, ss 32 B. With the same seed the public keys match RustCrypto
  `x-wing 0.1.1` byte for byte, and cross encaps/decaps in both directions give the same secret.
- **Blocker.** Together with libsignal/SPQR in one binary (`spikes/combined`, `run-variants.log`):
  A) without libcrux-kem — builds and works.
  B) + libcrux-kem 0.0.9 — **does not compile**: `libcrux-ml-kem 0.0.10` with the features `incremental` (from spqr) and
  `rand` (from libcrux-kem) breaks on `use ::rand::{RngCore, TryRngCore}`.
  C) `[patch.crates-io]` to `cryspen/libcrux@c938b46` (main, not a release) for libcrux-ml-kem and libcrux-kem — builds,
  X-Wing works, the Triple Ratchet spike passes too. But the graph has duplicates of all libcrux-* (registry + git), and
  the formally verified code is taken from an unreleased commit.
- There are no other audited combiner options: RustCrypto `x-wing` says plainly in its README "never been independently
  audited".
- **Without a new crate** the X25519 + ML-KEM-768 hybrid is already provided by the transport's TLS 1.3: the
  `X25519MLKEM768` group in rustls/aws-lc, the IETF standard for TLS. Its secret is derived via the TLS exporter (T7). The
  recommendation below is built on this.

### e) rmcp 3.5 — `spikes/rmcp-stdio`
A stdio server with one tool `get_trust` on the `#[tool_router]` / `#[tool_handler]` macros.
Replies to `initialize` (protocolVersion 2025-06-18, capabilities.tools), `tools/list` (JSON Schema of the arguments),
`tools/call` are there. An unknown tool `trust` → `-32602 tool not found`. Replies do not come in id order — that is
normal for JSON-RPC.

### f) rusqlite + SQLCipher — `spikes/sqlcipher`
`bundled-sqlcipher-vendored-openssl` builds (~52 s from scratch), the binary does not depend on the system
libssl/libcrypto/libsqlite. The DB is opened with a raw 32-byte key (`PRAGMA key = "x'..'"`). The file does not start with
`SQLite format 3`, and there is no plaintext in it. A foreign key gives `file is not a database`. `PRAGMA rekey` works.

### g) biscuit-auth 6 — `spikes/biscuit`
Issuing a token (336 B base64), offline verification only by the public root key, attenuation by the holder
(`check if operation("read")`) — writing after narrowing is forbidden. **There is no built-in holder-of-key.** Done in the
standard way: the authorizer requires `check if pop("<nonce>") trusting ed25519/<holder key>`, and the holder adds a
third-party block signed with its key. Results: a stolen token without PoP → refused; PoP with a foreign key → refused; an
old PoP for a new nonce → refused; a PoP block transplanted onto another token → refused already at
`append_third_party`.

### h) Key storage on the build server (observation only)
- No TPM: no `/dev/tpm*`, no `/sys/class/tpm`, `systemd-creds has-tpm2` = `partial` (-firmware, -driver).
- No Secret Service: nobody owns `org.freedesktop.secrets` on the user D-Bus; gnome-keyring/kwallet/libsecret are not
  installed.
- There is the kernel keyring (keyutils): memory only, does not survive a reboot. Suitable as a cache for the unlocked
  key.
- `/var/lib/systemd/credential.secret` has not been created (`systemd-creds` with a host key has never been used).
- So on a headless server what remains is the SPEC §13 fallback: a key wrapped with a password via Argon2id.
  Options for unattended autostart are in DECISIONS, questions for the maintainer.

## Final recommendation

### Pairing → Triple Ratchet
1. B connects to A's ephemeral invite endpoint: the key from the link, the relay from the link, no lookup.
   The transport is iroh QUIC/TLS 1.3 with `X25519MLKEM768` (prefer-PQ, aws-lc-rs). The X25519 + ML-KEM-768 hybrid gives
   the standard TLS key schedule; there is no combiner of our own.
2. Inside the channel, at the application layer:
   - B proves knowledge of the link secret: a MAC under a key from the link secret over the TLS exporter (this is the
     "PSK");
   - commit-then-reveal of random nonces (B commits first) — Vaudenay's SAS-MCA scheme: a MITM cannot pick the SAS even
     by choosing its own TLS share;
   - transcript = version, algorithm suite, both EndpointIds, exporter, nonces, libsignal identity keys,
     link-root keys (Ed25519 + ML-DSA-65), the future pairwise EndpointIds;
   - key confirmation, then the SAS from the transcript, then entering the code and confirmation by both owners.
3. After confirmation — an exchange of libsignal prekey bundles (KEM prekey `MLKEM1024`, signed by the link's pinned
   identity key), `process_prekey_bundle` → the first `PreKeySignalMessage` → Triple Ratchet (PQXDH + Double Ratchet +
   SPQR/ML-KEM-768). Identities are pinned from the transcript; the spike showed that a foreign bundle is rejected.
4. The sides move to the link's pairwise endpoints (their EndpointIds were in the transcript), and the ephemeral endpoint
   is destroyed. The protocol of steps 1–3 is modeled in ProVerif/Tamarin before the MVP (SPEC §15).

An alternative for step 1 is an additional X-Wing (libcrux-kem) on top of TLS. It is currently blocked by the libcrux
conflict (option B); options and cost are in DECISIONS, question 2.

### Files
Take **iroh-blobs 0.103**: compatible with iroh 1.3; resume, ACL and BLAKE3 verification are checked. What must be
transferred is **ciphertext** — a file already encrypted in STREAM chunks (SPEC §7). Then the iroh-blobs store (redb +
files) and the quarantine contain no plaintext. The plaintext's BLAKE3 travels inside the E2E message. Blob isolation per
link: a separate `FsStore` and `BlobsProtocol` for each pairwise endpoint, plus an ACL by EndpointId. The fallback if the
API breaks is `bao-tree` over our own iroh stream (see b).

## v0.1, slice 1 "link" (2026-10-02): what was added to the workspace

All versions are from the root `Cargo.lock`. The RustCrypto generation was chosen to match libsignal v0.103.1
(`hkdf`/`hmac` 0.13, `sha2` 0.11, `aead` 0.6), so there are no new duplicate crypto crates (`cargo tree -d`: one `spqr`,
shared with libsignal).

| Purpose | Crate | Version | License | Where checked |
| --- | --- | --- | --- | --- |
| Password KDF (keystore, Q-4) | `argon2` (+ `blake2` 0.11) | 0.6.0 | MIT OR Apache-2.0 | `keystore` unit tests; `antenna init` ≈ 0.2 s at 64 MiB / t = 3 |
| Root key wrapping | `chacha20poly1305` (+ `poly1305` 0.9) | 0.11.0 | Apache-2.0 OR MIT | `keystore` unit tests (wrong password, tampered header) |
| Pairing KDF / MAC / hash | `hkdf` / `hmac` / `sha2` | 0.13.0 / 0.13.0 / 0.11.0 | MIT OR Apache-2.0 | test vectors RFC 5869 A.1, RFC 4231 #2, SHA-256("abc") in `crypto.rs` |
| Message ID | `blake3` | 1.8.7 | CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception | `history.rs` |
| Link-root Ed25519 | `ed25519-dalek` | 3.0.0 (the same as iroh's) | BSD-3-Clause | generating and checking points during pairing |
| Link-root ML-DSA-65 | `libcrux-ml-dsa` | 0.0.10 | Apache-2.0 | a key from a 32-byte seed (FIPS 204 keygen is deterministic) |
| SPQR state (a fact for `antenna contacts`) | `spqr` (git, tag v1.6.0) | 1.6.0 | AGPL-3.0-only | `antenna --json contacts` → `NegotiationComplete(V1)` |
| TLS group (a fact) | `noq` / `rustls` | 1.4.0 / 0.23.46 | MIT OR Apache-2.0 / Apache-2.0 OR ISC OR MIT | `transport::kx_group` → `X25519MLKEM768` |
| CLI password input without echo, umask, SIGTERM, PR_SET_DUMPABLE | `rustix` | 1.1.5 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | no `unsafe` in our code (`unsafe_code = "forbid"`) |
| Control protocol | `serde_json` | 1.0.154 | MIT OR Apache-2.0 | `antenna-proto/src/control.rs` |
| libsignal stores | `async-trait`, `futures` (block_on) | 0.1.92, 0.3.34 | MIT OR Apache-2.0 | stores on top of SQLCipher, `e2e.rs` |
| Async runtime | `tokio` (`full`) | **1.54.1** (1.53.1 until 2026-10-27, RUSTSEC-2026-0386, unsound `AsyncFd::new`; we do not use `AsyncFd`) | MIT | the whole workspace test run |
| Constant-time helpers (through RustCrypto `digest`, `aes-gcm-siv` in libsignal) | `ctutils` | **0.4.6** (0.4.2 until 2026-10-27, RUSTSEC-2026-0385) | Apache-2.0 OR MIT | lock only, no direct use |

## v0.1, slice 2 "agents and permissions" (2026-10-02): what was added to the workspace

Versions are from the root `Cargo.lock`. There are no new cryptographic crates: tokens and approval requests are computed
with the same `sha2` 0.11 and `rand` (the OS CSPRNG) as in slice 1.

| Purpose | Crate / data | Version | License | Where checked |
| --- | --- | --- | --- | --- |
| MCP server `antenna mcp` (stdio), only in `antenna-cli` | `rmcp` (+ `rmcp-macros`), features `server`, `transport-io`, `macros` | 3.5.0 | Apache-2.0 | `tests/agents.rs`: initialize, tools/list, tools/call with a real stdio client |
| JSON Schema of tool arguments | `schemars` (re-exported as `rmcp::schemars`, `#[schemars(crate = "rmcp::schemars")]`) | 1.2.2 | MIT | the schemas in the tools/list reply |
| Local relay in integration tests (dev only) | `iroh-relay`, feature `server` (HTTP, no TLS) | 1.4.1 | MIT OR Apache-2.0 | `tests/agents.rs`, `tests/control.rs`: levels 1–2 through a relay on 127.0.0.1 |
| Seed phrase scanner | the English BIP-0039 list, 2048 words — **data**, copied from `rust-bip39` 3.0.0 into `antenna-core/src/bip39_english.rs` | — | CC0-1.0 | unit tests `bip39_list_is_sorted`, `secret_scanner_finds_secrets_and_ignores_prose` |

- `iroh-relay` with the `server` feature pulls `rcgen` 0.14, `tokio-rustls-acme` 0.9, `x509-parser`, `dashmap`, `toml` and
  enables `tls-ring` for the relay. It is **only** a dev dependency of the `antenna-cli` tests: the `cargo build --release`
  binaries `antennad` and `antenna` do not contain it, but with `cargo test --workspace` the features are unified, and the
  test builds of `antennad` contain it (without using it).
- The `bip39` crate was not added as a whole: for the sake of the word list it would have brought one more SHA-256
  implementation (`bitcoin_hashes`) into the audit surface.

## v0.1, slice 4 "files and quarantine", stage A (2026-10-02): `crates/antenna-files`

Since stage B (2026-10-02) it is a member of the root workspace, versions come from the root `Cargo.lock` (they did not
change in the move; D-F-15). At stage A it was a separate workspace (D-F-1). All licenses below are compatible with
AGPL-3.0-only (MIT, Apache-2.0, BSD, Zlib, CC0). Where checked — the tests of `crates/antenna-files` (`cargo test`:
37 unit + 45 integration, +1 `--ignored` on 1 GiB).

| Purpose | Crate | Version | License | Status / where checked |
| --- | --- | --- | --- | --- |
| STREAM (SPEC §7 "Files and streams") | `aead-stream` (RustCrypto/AEADs) | 0.6.0 (released 2026-06-28, the same `aead` 0.6.1 generation as libsignal's) | Apache-2.0 OR MIT | The crate has no separate audit; it is ~400 lines of nonce layout (`StreamBE32`: 7-byte prefix ‖ u32be counter ‖ flag); the AEAD is `chacha20poly1305` 0.11.0 (NCC Group audit 2020 for the 0.x line). `crypt::tests`: reordering/tampering/truncation/appending/replay/a foreign chunk |
| Deriving the file key and the quarantine record key | `hkdf` / `sha2` | 0.13.0 / 0.11.0 | MIT OR Apache-2.0 | as in slice 1 |
| Plaintext BLAKE3, blobs | `blake3` | 1.8.7 | CC0-1.0 OR Apache-2.0 | |
| Manifest signature | `ed25519-dalek` | 3.0.0 | BSD-3-Clause | `manifest::tests` |
| Transfer, link store | `iroh` / `iroh-blobs` (+ `bao-tree` 0.16.1, `redb` 4.3.0) | 1.4.1 / 0.103.0 | MIT OR Apache-2.0 | `tests/transfer.rs`: ACL, resume, tampering; 1 GiB — `--ignored` |
| Sandbox: Landlock | `landlock` | 0.4.7 | MIT OR Apache-2.0 | kernel 6.8 → ABI 4 (FS + TCP; signal/socket scope — from 6.12) |
| Sandbox: seccomp-bpf | `seccompiler` (Firecracker) + `libc` | 0.5.0 + 0.2.189 | Apache-2.0 OR BSD-3-Clause; MIT OR Apache-2.0 | `tests/sandbox.rs`: probes from inside the isolated process |
| rlimits, `openat`/`renameat2`, `PR_SET_DUMPABLE` | `rustix` | 1.1.5 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | no `unsafe` in our code |
| YARA | `yara-x` (VirusTotal) without modules, feature `pulley` (+ `wasmtime`/`pulley-interpreter` 48.0.7, `cranelift` 0.135) | **1.22.1** (1.21.0 with wasmtime 45.0.3 until 2026-10-27, RUSTSEC-2026-0222, 0269, 0316, 0327, 0359, 0362, 0363, 0379) | BSD-3-Clause; wasmtime — Apache-2.0 WITH LLVM-exception | rules compiled before seccomp, the scan under seccomp without `PROT_EXEC`; `tests/corpus.rs` |
| Images → pixels | `image` (without default features: png, jpeg, gif, webp, bmp, ico; no rayon) + `zune-jpeg` 0.5.15, `png` 0.18.1, `gif` 0.14.2, `image-webp` 0.2.4 | 0.25.10 | MIT OR Apache-2.0 (zune — + Zlib) | `cdr::tests`, PngSuite |
| PDF → pixels and text | `hayro` (+ `hayro-interpret` 0.7.0, `hayro-syntax` 0.7.2, `vello_cpu` 0.0.8, `skrifa` 0.42.1, `kurbo` 0.13.1, `moxcms` 0.8.1) | 0.7.1 | Apache-2.0 OR MIT; the bundled Foxit fonts — BSD-3-Clause (PDFium), ICC — CC0 | "experimental, work-in-progress" per the README; `forbid(unsafe_code)`; no encrypted PDFs. **At release** — the PDFium/Foxit license text in NOTICE |
| DOCX/XLSX/PPTX/ODF, ZIP | `zip` (only `deflate-flate2`) + `flate2` 1.1.10 (`miniz_oxide`) + `quick-xml` | **9.1.2** (8.6.0 until 2026-10-27, RUSTSEC-2026-0367…0369) / 0.42.0 | MIT; MIT OR Apache-2.0 | `inspect::tests`, `tests/corpus.rs` |
| File names (NFC/NFKC) | `unicode-normalization` | 0.1.25 | MIT OR Apache-2.0 | `names::tests` |
| Secret scanner (for both messages and files) | our own module `antenna_files::secrets` (moved from `antenna-core`; the core depends on `antenna-files` and re-exports it) — at stage A it was a git revision of the core, `065ed21` | 0.0.1 | AGPL-3.0-only | D-F-11, D-F-15 |
| Check worker in the daemon | `antennad` itself with the hidden argument `--antenna-files-worker` (`current_exe`) | — | AGPL-3.0-only | D-F-16; `crates/antenna-cli/tests/files.rs` |

**What is absent and was not installed** (we install no system packages on the build server): bubblewrap
(`which bwrap` — empty), ClamAV (`clamscan` — none), LibreOffice; `pdftoppm` (poppler, GPL) is on the server but is not
used.

**Measurements** (build server, debug build with `opt-level = 2` for the dependencies and the crate, D-F-12):

| What | Result |
| --- | --- |
| STREAM, 64 MiB in memory | encryption 116 ms (~580 MB/s), decryption 155 ms; BLAKE3 of 64 MiB — 22 ms; before `opt-level = 2` for the crate — 9.2 s |
| 64 MiB: encryption into the store / transfer with a break at 40 % and a store restart / decryption + BLAKE3 | 216 ms / 736 ms (38 of 64 MiB downloaded on resume) / 333 ms |
| **1 GiB** (`one_gib_with_drop_and_resume`, `--ignored`): the same | 3.2 s / 5.3 s (resumed from 410 MiB, 614 MiB downloaded) / 5.0 s; the whole test 15 s, RSS ≤ 125 MB, 2 × 1 GiB on disk in a temporary directory (deleted) |
| Check in the sandbox (worker start, YARA compilation, isolation, parsing, answer) | text — ≈ 10 ms; the whole `tests/corpus.rs` corpus (12 tests, ~45 checks, including 150–200 MiB bombs) — 1.3 s; 64 MiB of random data — 0.55 s, 1 GiB — 9.1 s (64 MiB windows), 300 MiB of text — 16 s (secrets over the whole text) |
| Isolation probes | an infinite loop killed by SIGXCPU after 10.0 s; 2 GiB against a 512 MiB limit — SIGABRT |

## LAN, links through the site, contact agents (2026-10-03): what was added to the workspace

| Purpose | Crate | Version | License | Where checked |
| --- | --- | --- | --- | --- |
| QR code of the invite link in the terminal (`antenna invite`), only `antenna-cli` | `qrcode` (kennytm), without default features (no `image`/`svg`: only the half-block text renderer) | 0.14.1 | MIT OR Apache-2.0 | `output::tests::invite_qr_fits_a_terminal` (a link with the n0 relay ≈ 200 characters — QR ≤ 80 columns); not cryptography |
| LAN via mDNS (SPEC §4, §18), only `antenna-core` | `iroh-mdns-address-lookup` (n0, `github.com/n0-computer/iroh-address-lookups`) → `swarm-discovery` 0.6.3 (Apache-2.0) → `hickory-proto` 0.26.3 (MIT OR Apache-2.0), `acto` 0.8.2 (Apache-2.0 OR MIT) | 0.6.0 (requires `iroh ^1.0` — one iroh 1.4.1 in the tree) | MIT OR Apache-2.0 | `lan::tests`, `tests/lan.rs` (netns). Only `subscribe` and `publish` are used — without registering as the endpoint's `AddressLookup` (the instance name is the link pseudonym, D-77). Pitfalls: `Peer` is compared together with `last_seen` — the `Discovered` event arrives on every reply (≈ once a second), hence the connection limit per pseudonym; the subscription channel holds 20 events with `try_send` — read right away |

## Code mode: the agent's terminal in the window (2026-10-03): what was added to the desktop app

The window runs an agent CLI (Claude Code, Codex, an own command) in a pseudo-terminal and draws it with a terminal
emulator widget (DESIGN "Code mode", DECISIONS D-83, D-UI-16). Both packages are pinned to an exact version in
`apps/antenna_desktop/pubspec.yaml`. Neither does cryptography.

| Purpose | Package | Version | License | Maintenance (checked 2026-10-03) | Platforms | Where checked |
| --- | --- | --- | --- | --- | --- | --- |
| Terminal emulator widget (VT100/xterm escape sequences, scrollback, selection, input) | `xterm` (TerminalStudio/xterm.dart), pure Dart | 4.0.0 (2024-02-27) | MIT | the reference package for terminals in Flutter (≈ 650 stars); last release 2024-02, last repository activity 2025-06; maintained forks exist (`xterm2` MIT, `xterm3` AGPL-3.0) if it stalls | all Flutter platforms (no native code) | compiles and renders with Flutter 3.47.6 / Dart 3.13 (`test/widget/code_mode_test.dart`, goldens `34_code_mode*`); its `Buffer.getText` drops cursor-positioned blanks, so the window copies through its own `terminalText` (TROUBLESHOOTING "Code mode"); it reports the mouse wheel as buttons 68/69 (Shift + wheel) instead of 64/65, so the agent's terminal passes its own `WheelMouseHandler` (TROUBLESHOOTING "Scrolling back in the dock's terminal") |
| Pseudo-terminal: `forkpty` + `execvp` in C, a read thread posting to a Dart port | `flutter_pty` (TerminalStudio/flutter_pty), FFI plugin | 0.4.2 (2025-01-06) | MIT | small and stable, last release 2025-01 (18 open issues); a fork with the exec-failure fix exists (`kyroon_pty`, 2026-08, MIT) | Linux (CMake), macOS (CocoaPods podspec, no Swift package), Windows, Android, iOS | live test `test/protocol/live_code_mode_test.dart` against a real `antennad` on Linux, with the plugin's C code built by the test (flutter_tester does not build plugins); macOS: see "Needs a Mac" |
| Transitive (pulled in by `xterm`) | `equatable` 2.1.0 (MIT), `quiver` 3.2.2 (Apache-2.0), `zmodem` 0.0.6 (MIT), `convert` 3.1.2 (BSD-3-Clause) | — | AGPL-compatible | — | — | `flutter pub get`, `flutter analyze` |

**Why these.** They are the pair the Flutter ecosystem uses for embedded terminals (the same authors, designed to work
together), permissively licensed (MIT is compatible with the app's AGPL-3.0-only), and both work with Flutter 3.47.6
without changes. Alternatives looked at: `pty2` (MIT, active) forks the Dart VM process from Dart code through FFI and
runs Dart between `fork` and `exec`, a hazard we do not take in a process that holds the owner session; `portable_pty`
builds a Rust crate at app build time; `flutter_alacritty` brings a Rust engine through flutter_rust_bridge. No PTY
bridge of our own was needed: `flutter_pty` works, and its gaps are covered by the window (below).

**Gaps of `flutter_pty` 0.4.2 and how the window covers them** (details: TROUBLESHOOTING "Code mode"):
- the child inherits the window's open descriptors (the Flutter engine keeps some without close-on-exec): the wrapper
  shell closes every descriptor above 2 before it starts the agent;
- after a failed `execvp` the forked child falls through into the window's code: the window only ever execs an
  absolute path to bash that it checked before, so `execvp` does not fail;
- its exit code can be lost: the Dart VM reaps any child with `wait()` while the window has other children (the daemon
  on Linux), and the output port is closed when the exit is reported: the wrapper reports the agent's exit code in a
  private OSC sequence and pauses 0.2 s before exiting, and the window also probes the session leader every 250 ms;
- `chdir` failure is ignored: the wrapper changes to the folder itself and refuses with 126;
- no `close()` for the master descriptor: one descriptor per finished run stays open until the window exits;
- macOS: a CocoaPods podspec only, so `flutter build macos` needs CocoaPods next to the Swift packages of the other
  plugins (`packaging/macos/build-dmg.sh` checks for `pod`).

**Gaps of `xterm` 4.0.0 and how the window covers them** (2026-10-05, TROUBLESHOOTING "Code mode terminal: underlined
lines"): its SGR parser ignores a private marker (`CSI > 4 ; 2 m`, modifyOtherKeys, which Claude Code writes, reads as
underline and dim), ends only dim on `22`, drops the colon of sub-parameters (`4:3`, `38:2::R:G:B`) and runs the
arguments of `58` (underline color) as codes of their own. The window passes a program's output through `SgrFilter`
(`lib/state/terminal_sgr.dart`), which rewrites exactly these sequences. xterm's latest release is 4.0.0 and its main
branch has the same parser (checked 2026-10-05); the MIT fork `xterm2` ≥ 5.0.0 (2026-07) parses all of them. Moving to
it is a maintainer decision (the live test on Linux and a build on a Mac), and the filter goes with the move: it
relies on 4.0.0's own readings.

**Checked with Claude Code 2.1.233** (the CLI installed on the build server): `--mcp-config '<json>'`,
`--strict-mcp-config` and `--settings '<json>'` are accepted on the command line; Claude Code passes its own environment
to a stdio MCP server whose config has no `env` (so `ANTENNA_AGENT_TOKEN` reaches `antenna mcp` without being an
argument); it starts the MCP servers only after the "do you trust this folder" question is answered; `antenna mcp`
binds the token to the `claude` process, the wrapper's child. Codex was not available on the build server: its
`-c mcp_servers.<name>.*` overrides and `env_vars` follow the Codex documentation (`learn.chatgpt.com/docs/extend/mcp`).

**Kept current by a canary** (2026-10-05): Claude Code updates itself, so the version above is history the day after.
`tools/claude-canary.sh` runs the Code mode wake (the flags above, the session hooks, the screen fallback and the Stop
hook continuation, D-UI-25) against whatever `claude` is installed and prints the version with PASS or FAIL; it is meant
to run daily (TROUBLESHOOTING "Claude Code changed: how to read a canary failure"). Checked so far: 2.1.289 and 2.1.290
(the CLI updated itself between two runs of the same evening), after a fix to the screen fallback that the first run
found.

## Composer: files and text from other apps (2026-10-05): what was added to the desktop app

Two macOS bugs found on a clean Mac (macOS 27, Antenna 0.1.0-preview.4): a screenshot dragged from the floating
thumbnail was "Not sent: file not found", and text from dictation apps (Superwhisper) never reached the composer
(TROUBLESHOOTING "2026-10-05 · Composer: dropped screenshots and dictation"). No package was added: the window's own
code, a small native file in the macOS Runner (`macos/Runner/ComposerInput.swift`, AppKit only) and one in the Linux
runner (`linux/runner/clipboard_channel.cc`, GTK 3 only). Nothing here does cryptography.

**Clipboard images: why not `pasteboard`.** `pasteboard` 0.5.0 (MixinNetwork, the publisher of `desktop_drop`;
Apache-2.0, 2026-02-24; Swift Package Manager on macOS, GTK on Linux) reads clipboard images on both platforms and
worked in a scratch app under Xvfb. It was dropped because it pulls in `crypto` (through `uuid`, for temporary file
names on Windows): a new dependency that does cryptography needs a maintainer decision (CONTRIBUTING.md, security rules),
and reading an image is a few lines of platform code. The Runners answer `antenna/clipboard` `image` with PNG bytes:
NSPasteboard on macOS (PNG as is; TIFF, JPEG, HEIC re-encoded), `gtk_clipboard_request_image` +
`gdk_pixbuf_save_to_buffer` on Linux. Checked on Linux: `flutter build linux --debug`, and the real runner under Xvfb
with a GTK process owning the clipboard read a 118-byte PNG through `RunnerClipboardImages` (with text only on the
clipboard: `null`, `Clipboard.hasStrings` true). The macOS reader needs a Mac.

**Drops: why not `super_drag_and_drop`.** It is the most complete drag and drop package for Flutter (MIT; file
promises, virtual files, data of any type), but: the last stable release, 0.9.1, is from 2025-06-11, and 0.10.0-dev.2
(2026-08-07, a prerelease) needs Flutter ≥ 3.44; its native side, `super_native_extensions`, is a Rust crate built
during `flutter build`. 0.9.1 builds it through cargokit (on macOS from a CocoaPods podspec), which needs `rustup` and
by default downloads prebuilt binaries from the project's GitHub releases (`precompiled_binaries` in its
`cargokit.yaml`); the job that produced them was removed on 2026-08-07 (upstream #596), and 0.10 builds the crate from
source through a Dart build hook (`native_toolchain_rust`). Either way the window's build gets a second Rust build
that fetches its own crates from crates.io outside our `Cargo.lock` and `cargo deny`, on every machine that builds the
window (`packaging/`, `release.yml`), and the package replaces `desktop_drop` and the clipboard as a whole, for one
missing behavior. Checked by reading both published packages (0.9.1 and 0.10.0-dev.2), not by building them.
`super_clipboard` (same project, same build) was not needed: reading a clipboard image is a few lines per Runner.

**Drops: what `desktop_drop` 0.8.4 does and lacks** (Apache-2.0, 2026-09-01, kept for Linux). On macOS it accepts file
promises, but it prefers a file URL whenever the pasteboard has one, and it hands the paths to Dart only after
`performDragOperation` has returned. The screenshot thumbnail offers both, and deletes the file behind its URL as soon
as the drag ends, so the path is dead before the window sees it. Neither behavior can be configured. The window
therefore takes drops on macOS with its own view in the Runner (`macos/Runner/ComposerInput.swift`, AppKit only:
`NSFilePromiseReceiver`, `clonefile(2)`, `NSPasteboard`), which stages everything before the drop ends and reports
the copies over the `antenna/drop` channel; `desktop_drop`'s own view stays registered by the plugin but is told not
to take drops. GTK on Linux hands over paths of files that stay; the window copies small ones at once anyway.

**Paste: no package can fix it.** The text from dictation apps is lost inside the Flutter engine (3.47):
`FlutterTextInputPlugin`, the `NSTextView` the macOS embedder keeps for accessibility, inherits `paste:` and the
accessibility setters, which change only that view (flutter/flutter#184571, the fix is a draft, PR #190539;
flutter/flutter#191503 for accessibility writes). The Runner catches the synthetic Cmd+V before Flutter does and adds
the missing methods to that class with `class_addMethod`, which never replaces a method the class defines itself, so a
Flutter release with its own fix keeps it. When that fix ships in a stable Flutter, the Runner's part can go.

## Owner keys: approving and unlocking with Touch ID (2026-10-06, D-102): what the daemon uses

No new crate. Maintainer decision D-102: P-256 verification uses `aws-lc-rs` directly, the crate rustls and iroh
already build as the TLS provider (row "PQ key exchange" above), with the same features, so the graph only gains edges
(`cargo tree -d` unchanged).

| Purpose | Crate | Version | License | Where checked |
| --- | --- | --- | --- | --- |
| ECDSA P-256 / SHA-256 verification of owner proofs (`ECDSA_P256_SHA256_FIXED`, `ParsedPublicKey`) | `aws-lc-rs` (`default-features = false, features = ["aws-lc-sys"]`) | 1.18.1 (aws-lc-sys 0.45.0) | ISC AND (Apache-2.0 OR ISC) | `owner_keys::tests`: another key, nonce or request refused, the DER form refused, a vector signed by Python `cryptography` 41 / OpenSSL 3.0 verifies; `tests/owner_keys.rs` against real daemons |
| Unlock slot: KEK from the slot key, root key wrapping | `hkdf` / `sha2` / `chacha20poly1305` | 0.13.0 / 0.11.0 / 0.11.0 | as above | `keystore::slots::tests` (wrong key, tampered header, another keystore, atomic writes) |
| Exact request bytes for the proof hash | `serde_json` feature `raw_value` | 1.0.151 | MIT OR Apache-2.0 | `antenna-proto` `owner_keys::tests` |

The window's side is Apple's: CryptoKit `SecureEnclave.P256.Signing` and `.KeyAgreement` keys with
`SecAccessControl` `.privateKeyUsage` + `.biometryCurrentSet`, LocalAuthentication for the Touch ID sheet and the
biometry domain state, CryptoKit HPKE (RFC 9180, P-256 / SHA-256 / AES-GCM, macOS 14 and later) to seal the unlock
slot's key. Not chosen: RustCrypto `p256` (its arithmetic was never independently audited, proposal §3 A), HPKE in
Rust (nothing in the daemon needs it: the daemon only makes the random slot key and wraps the root key with the
construction the password slot already uses).
## Local models (2026-10-06): the runtime and the weights (D-104)

| Component | Exact version | License | Checked | Pitfalls (details in TROUBLESHOOTING) |
| --- | --- | --- | --- | --- |
| Model runtime: llama.cpp `llama-server` | **v0.6.0** = commit `d81235049384534c167caea52b85a694f6103d14` (build b11429, 2026-10-05); source archive SHA-256 `09b36dba235fcac180efff18514da7038e65d8e5b9e4aefa59238468abfdec12`; ggml 0.26.0 | MIT | **yes**: built here by `packaging/llama/build.sh` (Linux x86_64, GCC 13.3, 4–5 min with 8 jobs, 38 MB with 14 CPU variants); unix socket, API key (401 without it), streaming, prompt cache, `--offline --no-slots --no-webui`; the real 2B answered through the daemon in its sandbox (`tests/local.rs`, `#[ignore]` test) | Built with `LLAMA_OPENSSL=OFF`, `LLAMA_SUBPROCESS=OFF`, `LLAMA_BUILD_UI=OFF`, `LLAMA_USE_PREBUILT_UI=OFF`: no HTTPS client, tools, MCP servers, router or web UI. Every flag is also an `LLAMA_ARG_*` variable: the sandbox's empty environment keeps the daemon's out. A socket path over `sun_path` fails to bind ("couldn't bind HTTP server socket"). `--version` says "commit unknown" for a build from the archive. The macOS Metal build is not tried yet |
| Models: Qwen3.5 2B, 4B, 9B (Q4_K_M GGUF) | `unsloth/Qwen3.5-2B-GGUF@f6d5376b…`, `-4B-GGUF@e87f1764…`, `-9B-GGUF@3885219b…` (files, sizes and SHA-256 in `packaging/models.json`); chat templates from `Qwen/Qwen3.5-2B@15852e8c…`, `-4B@851bf6e8…`, `-9B@c2022362…` | Apache-2.0, not gated | **yes**: all three downloaded here, SHA-256 equal to the hub's `lfs.oid`; memory and speed on this CPU in `docs/LOCAL-ASSISTANT.md` §14 | The 2B's template thinks only when asked, the 4B's and 9B's unless told not to: the loop always sends `enable_thinking: false` and the runtime runs with `--reasoning off`. The CPU build repacks the weights (memory ≈ 1.6× the file) |

## Teams of agents (2026-10-06): what the daemon runs (D-111)

| Component | Exact version | License | Checked | Pitfalls (details in TROUBLESHOOTING) |
| --- | --- | --- | --- | --- |
| git (the owner's, not linked and not shipped) | 2.38 or later (`merge-tree --write-tree`); 2.43.0 on the build server | GPL-2.0 (a separate program the daemon starts) | **yes**: `tests/teams.rs` (checkouts with `read-tree -u`, snapshots with `add -A`, `write-tree`, `commit-tree`, fast-forwards and merges with `merge-tree --write-tree`, `update-ref` compare-and-swap, `merge --ff-only` in the project's working folder) | Run only by the daemon, with `--git-dir`, a private index, hooks, fsmonitor and gc off, no external diff or textconv, and an environment of `PATH`, `HOME` and the locale only; a filter driver the owner configured (git-lfs) still runs on a worker's files when they are added. Older git: fast-forwards work, merges fail with "teams need git 2.38 or later" |
| Claude Code as a worker | 2.1.291 (build server) | the vendor's | **yes**: `real_claude_code_works_as_a_worker` (`--model haiku`, the owner's login read-only in the sandbox): the task read through MCP, the bug fixed, `run_check`, `task_report`; 15 s | The daemon's hook comes in `--settings` (outranks the project's and the user's settings) with `disableAllHooks: false`; `--allowedTools` without `Bash` while the worker may run no commands; `--strict-mcp-config` with the worker's own `antenna mcp` |
