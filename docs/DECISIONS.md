# DECISIONS

Decisions on the stack and on the open questions of SPEC §19. Format: date · question · decision · why · who decided.

---

## Stage 0 (2026-10-02): stack check and workspace skeleton

Facts and logs are in `docs/STACK.md`. Decided during stage 0, within the scope of the assigned task. Everything that
changes the meaning of SPEC is listed below under "Questions for the maintainer" and is **not** considered decided.

### D-1 · Toolchain pinned: Rust 1.99.0, edition 2024
- **Decision.** `rust-toolchain.toml` → `1.99.0` (profile minimal, clippy, rustfmt); `rust-version = "1.99"` in the workspace.
- **Why.** Reproducible builds (SPEC §15). The whole stack was checked on exactly 1.99.0; the dependencies' minimums are
  lower (libsignal-protocol 1.85, spqr 1.88), but nothing was checked on them. Spikes inside the project pick up this file too.

### D-2 · Workspace layout and crate names
- **Decision.** Four crates:
  - `crates/x-proto` — Apache-2.0: CBOR envelope, LinkId, MessageId, message types, protocol version, padding buckets;
  - `crates/x-core` — AGPL-3.0-only: stub modules transport, pairing, e2e, history, store, keystore, policy, files, agent_api;
  - `crates/xd` — AGPL-3.0-only: the daemon binary;
  - `crates/x-cli` — AGPL-3.0-only: the `x` binary.

  `spikes/` are excluded from the workspace (`exclude`). Each spike has its own `[workspace]` and a committed `Cargo.lock`.
- **Why.** The license boundary of SPEC §16 runs exactly along crate boundaries. The specification layer, with no
  cryptography and no AGPL dependencies, can be released under Apache. Everything that links with libsignal/SPQR is AGPL.
  The names are working names: the product name is an open question of SPEC §19, and renaming costs one `sed`. The CLI
  package is called `x-cli` because the package name `x` is too generic; the binary is still `x`, as in SPEC §12.

### D-3 · Unimplemented commands exit with code 69
- **Decision.** At stage 0, `x <command>` and `xd` print "not implemented yet" (with `--json`, JSON on stdout) and exit
  with 69 (`EX_UNAVAILABLE`, sysexits.h).
- **Why.** clap exits with code 2 on an argument parsing error. An agent that reads the exit code must be able to tell
  "no such command" from "wrong arguments".

### D-4 · Stack versions pinned exactly (`=`), libsignal by git rev
- **Decision.** `[workspace.dependencies]` holds the checked versions: `iroh =1.3.0` (feature `tls-aws-lc-rs`),
  `iroh-blobs =0.103.0`, `libsignal-protocol` rev `e8cc2ddd…` (tag v0.103.1, feature `mlkem1024`), `libcrux-ml-dsa =0.0.10`,
  `rmcp =3.5.0`, `biscuit-auth =6.0.0`, `rusqlite =0.40.2` (SQLCipher + vendored OpenSSL). Workspace members do not use them
  yet. They do not get into `Cargo.lock` until a crate pulls them in with a `foo = { workspace = true }` line.
- **Why.** iroh-blobs and libcrux are still 0.x, and libsignal changes its API without warning (in v0.103.1
  `AliceSignalProtocolParameters` is already a hidden alias, kept "during the transition", for `pqxdh::InitiatorParameters`).
  A tag can be rewritten, a rev cannot.

### D-5 · PQ in the transport: aws-lc-rs, prefer-PQ mode
- **Decision.** The endpoint gets the aws-lc-rs crypto provider with the groups `[X25519MLKEM768, X25519]`.
- **Why.** With `ring` (iroh's default) there is only X25519 (spike T6). In PQ-only mode the endpoint cannot connect to
  the n0 relay: the provider is shared with the TLS connection to the relay. With prefer-PQ, the node↔node connection is
  `X25519MLKEM768` both directly and through the relay.

### D-6 · No address publishing: the `Minimal` preset
- **Decision.** `Endpoint::builder(presets::Minimal)` + an explicit `relay_mode`; the contact's address is the
  `EndpointAddr` from the invite or from the link store. pkarr, DNS lookup and mDNS are off by default.
- **Why.** SPEC §4: "publishing addresses to the global DNS is off by default", "mDNS is off". `presets::N0` publishes the
  address to pkarr on its own (`PkarrPublisher::n0_dns()`).

### D-7 · Accept-list in two layers; the ALPN token rejected
- **Decision.** Two layers:
  1. `Router::incoming_filter`: a relay packet from an unpaired EndpointId → `Ignore` (no reply), direct UDP without
     address validation → `Retry`;
  2. `EndpointHooks::after_handshake`: an unpaired key → close the connection before any application data.
- **Why.** Through the relay, the sender's ID is known before the handshake, so we drop silently. Over direct UDP the ID
  only becomes known inside TLS. A secret token in ALPN as a pre-filter was tested and rejected:
  `Incoming::decrypt().alpns()` often fails to parse the ClientHello from the first Initial, and with a PQ key share
  (1184 B) it never parses it.

### D-8 · libsignal integration: bundles inside the verified channel, KEM prekey ML-KEM-1024
- **Decision.** The Triple Ratchet session is set up the standard way: `process_prekey_bundle` → `message_encrypt` /
  `message_decrypt` on bundles passed inside the pairing channel. libsignal identity keys are separate for each link and
  are pinned from the pairing transcript (under the SAS); TOFU is not used. The KEM prekey type is `MLKEM1024`.
- **Why.**
  - Initializing from our own secret is impossible through the public API: the `Handshake` trait is `pub(crate)`.
  - libsignal itself rejects a bundle with a foreign identity (spike).
  - `Kyber1024` is Signal's default type, but it is pre-standard Kyber, and SPEC requires FIPS 203. We do not need
    compatibility with Signal; the spike passed on both types.
  - Risk: a comment in libsignal says "ML-KEM … may still change incompatibly". That is why the rev is pinned (D-4).

### D-9 · libcrux-kem (X-Wing) is not added to the core dependencies for now
- **Decision.** It is not in `workspace.dependencies`. At stage 0 the hybrid X25519 + ML-KEM-768 for pairing is recommended
  via the transport's TLS 1.3. The final call is question for the maintainer no. 2.
- **Why.** `libcrux-kem 0.0.9` and `spqr` in one tree break the build of `libcrux-ml-kem 0.0.10` (STACK.md, d). The only
  workaround is a git patch to libcrux's unreleased main.

### D-10 · SQLCipher with vendored OpenSSL and a raw key
- **Decision.** `rusqlite` with the feature `bundled-sqlcipher-vendored-openssl`. The DB key is raw 32 bytes
  (`PRAGMA key = "x'…'"`) from the keystore, with no PBKDF inside SQLCipher. Turn SQLCipher's logs off or redirect them
  (TROUBLESHOOTING).
- **Why.** SPEC §14: "one binary with no external runtime dependencies" — `ldd` is clean. We derive the key ourselves
  (Argon2id/TPM); a second KDF inside SQLCipher only slows down opening.

### D-11 · Holder-of-key for biscuit — a third-party block with PoP
- **Decision.** The token is checked together with `check if pop("<request nonce>") trusting ed25519/<holder key>`.
  The holder proves possession of the key with a standard biscuit third-party block over a fresh nonce.
- **Why.** biscuit-auth 6 has no built-in holder-of-key. A third-party block is a standard, already verified part of the
  format: the block is bound to the token signature and to the holder's key. There is no custom cryptography here
  (spike g: 4 negative cases).

### D-12 · The x-proto v0 format is not frozen
- **Decision.** CBOR via `ciborium` + `serde_bytes` (byte fields are bstr), string keys, `ProtocolVersion(0)`.
- **Why.** The skeleton tests need a minimal but real format. Integer keys, canonical encoding and the exact fields
  under the signature are fixed in the specification before v0.1.

---

## Mismatches between SPEC §14 (and related sections) and the actual stack as of 2026-10-02

`SPEC.md` is not edited (our rule: discrepancies go to the maintainer first). The list for the maintainer's decision:

| Where in SPEC | In SPEC | Fact | Consequence |
| --- | --- | --- | --- |
| §3, §4, §14 | iroh 1.0 | iroh **1.3.0** (2026-09-28); API: presets, `EndpointHooks`, `IncomingFilter`, `clear_ip_transports` | Write "iroh 1.x"; `presets::N0` publishes addresses to pkarr → `Minimal` is needed (D-6) |
| §10, §14 | iroh-blobs (1.x implied) | iroh-blobs **0.103.0** (2026-06-15), still 0.x; compatible with iroh 1.3 (one iroh version) | Risk of API breakage; fallback is bao-tree (STACK.md, b) |
| §14 | libsignal + SPQR from Signal (Rust) | Git only: `signalapp/libsignal` (tag v0.103.1), `signalapp/SparsePostQuantumRatchet` (tag v1.6.0); README: "Use outside of Signal is unsupported" | x-core cannot be published on crates.io; §14 "Distribution: `cargo install`" — only `cargo install --git` or vendoring (question 3) |
| §7 | "The initial key is taken from the handshake during pairing" | libsignal's public API does not accept an external secret; the session starts via PQXDH on bundles passed inside the pairing channel | The link to pairing goes through pinned identity keys, not through a shared secret (D-8) |
| §7, §14 | PQ "ML-KEM-768 (FIPS 203)" everywhere | SPQR is ML-KEM-768 (FIPS 203). PQXDH in libsignal defaults to **Kyber1024** (pre-FIPS); ML-KEM-1024 is the `mlkem1024` feature | `MLKEM1024` chosen (D-8) |
| §14 | "SPQR is verified with hax/F\* and ProVerif models" | spqr README: hax/F\* prove absence of panics and correctness of field arithmetic; ProVerif models the ML-KEM Braid and the symmetric ratchet; some functions are `verification_status(lax)` | Make the SPEC wording more precise so it does not promise more than is proven |
| §6, §14 | X25519 + ML-KEM-768 for pairing (libcrux) | `libcrux-kem 0.0.9` has X-Wing (draft-06), but **it does not compile** together with libsignal/SPQR in one binary; the hybrid exists in iroh's TLS 1.3 (`X25519MLKEM768`, aws-lc) | Question 2 |
| §6 item 3 | "The secret from the link is mixed into the handshake as a PSK" | iroh/QUIC-TLS has no PSK | PSK at the application layer right after TLS, bound to the TLS exporter |
| §18 | "A connection from an unpaired key is dropped at the transport without a reply" | Through the relay, yes (Ignore before the handshake). Over direct UDP the ID is only known after TLS: the server manages to send a ServerHello, then closes (403) | Question 5 |
| §14 | ed25519-dalek, x25519-dalek | 3.0.0 in iroh; biscuit-auth 6 pulls ed25519-dalek **2.2** and curve25519-dalek 4.1 | Two Ed25519 versions in the binary: larger audit surface, `cargo-deny` will complain |
| §14 | keyring | keyring 4.2.0; on headless Linux without Secret Service and TPM there is no backend | Question 4 |
| §3 | "Encryption: Double Ratchet" in the diagram | §7 and §14 say Triple Ratchet | A typo in the diagram |

---

## Questions for the maintainer (not decided)

### Q-1 · A pairwise endpoint per link or one endpoint (SPEC §19)
**What spike a) showed.** 50 endpoints work in one process. The cost in a debug build: ~0.34 s of startup and ~1.7 MB RSS
per endpoint, 4 fds, its own relay connection (a ping every 15 s) and its own net_report. All 50 sit on the same home
relay from the same IP, so the relay operator links them, as SPEC §4 says.

The spike surfaced two arguments **for pairwise** that SPEC §19 does not have:
1. "Relay only" mode (the contact does not see the IP, levels 1–2) is a property of the endpoint (`clear_ip_transports`).
   With relay+IP, iroh hands the contact all local addresses by itself, including LAN and Tailscale 100.x (spike T3).
   The IP mode cannot be chosen per link on a shared endpoint.
2. The EndpointId is visible to the contact. One endpoint = one global ID for all contacts, and contacts can link you
   across each other. This directly contradicts SPEC §1 and §5 ("nothing in common between links").

| Option | Cost | What it gives |
| --- | --- | --- |
| **A. Pairwise, as in SPEC** (recommended) | Cost linear in the number of links: memory, relay connections, background ping and net_report traffic; at 200+ links the release build has to be measured | §1/§5 and the per-level IP privacy modes of §4 are met; the accept-list is trivial (one paired key per endpoint) |
| B. Pairwise + "sleeping" endpoints for links without presence (levels 1–2) | Extra wake-up logic; incoming traffic to a sleeping link only possible via mailbox v2 | Saves resources at 50+ links |
| C. One endpoint, pairwise only in E2E | Breaks §1/§5 (shared EndpointId); "relay only" only for all links at once | One relay connection, fewer resources |

### Q-2 · Where to get the X25519 + ML-KEM-768 hybrid for pairing (SPEC §6 items 4–5)
| Option | Cost | What it gives |
| --- | --- | --- |
| **I. The transport's TLS 1.3 `X25519MLKEM768` + an application-level commit-then-reveal nonce + SAS from the transcript with the TLS exporter** (recommended) | SPEC §6 has to be reworded: a nonce is committed, not a key share — the classic SAS-MCA scheme (Vaudenay). The PQ strength of pairing rests on rustls/aws-lc. The ProVerif model has to include a TLS abstraction | No new crates and no conflicts; the standard IETF hybrid; works through the n0 relay too (spikes T6/T7) |
| II. Option I + an additional X-Wing (libcrux-kem) inside the channel | Does not build together with libsignal/SPQR now. Either wait for a libcrux-ml-kem release > 0.0.10 (no date), or a git patch to the unreleased main with duplicate libcrux-* crates | Two independent PQ exchanges (TLS + application) — a margin in case one of the stacks has a bug |
| III. RustCrypto `x-wing` | Breaks our rule of no custom or unaudited cryptography: the README says "never been independently audited" | Not recommended |

### Q-3 · libsignal/SPQR: git dependency or vendoring (SPEC §19, second-to-last item)
Facts: not on crates.io; "use outside of Signal is unsupported"; the public API changes (D-4).

| Option | Cost | What it gives |
| --- | --- | --- |
| **a. Git dependency with a pinned rev** (current state, recommended for the MVP) | x-core cannot be published on crates.io, `cargo install` only with `--git`; every update means a manual API check | Least work, updates from Signal |
| b. Vendor `rust/protocol` + `spqr` into the repository (AGPL-compatible) | We port Signal's security fixes ourselves; the amount of code under audit grows | Independence from their API and build, crates.io becomes possible |
| c. A fork with a public `Handshake` (session from the pairing secret, as in §7) | Our own change to Signal's cryptographic protocol, needs a separate audit | Exactly the SPEC §7 wording; essentially not needed, D-8 solves the task without a fork |

### Q-4 · Keys on a headless server without TPM and Secret Service (SPEC §5, §13)
Our build server (and a typical VPS where agents live) has no TPM and no Secret Service.

| Option | Cost | What it gives |
| --- | --- | --- |
| a. Password + Argon2id, `x unlock` after every boot | The daemon does not start on its own; agents are unavailable until the password is entered | The key never lies on disk in the clear (the letter of SPEC) |
| b. `systemd-creds` with a host key (without TPM) | Does not protect against root on the same host or against a copy of the whole disk | Autostart; protection against a leak of a single file |
| c. A 0600 key file in an explicit "server mode" with a warning | Weakest at-rest protection | Autostart, simplest |

Recommendation: (a) by default; modes (b) and (c) only with an explicit flag and a warning in `x doctor`.

### Q-5 · The §18 criterion "dropped at the transport without a reply" for direct UDP
Through the relay it holds literally. Over direct UDP, QUIC/TLS cannot learn the client's key without answering with a
ServerHello. Recommended wording: "a connection from an unpaired key is closed right after the transport handshake,
before any application data and application cryptography; through the relay, without a reply". In addition, the IP:port
of a pairwise endpoint is never published (D-6). The alternative is relay-only for all incoming connections from
strangers, but that breaks direct connections.

---

## Maintainer decisions (2026-10-02)

| Question | Maintainer decision | What it changes |
| --- | --- | --- |
| Q-1 · endpoint | **A. A pairwise endpoint per link**, as in SPEC | "Relay only" mode for levels 1–2 is a property of the link's endpoint. Measure the release build at 200+ links |
| Q-2 · PQ during pairing | **I. Hybrid from the transport's TLS 1.3** (`X25519MLKEM768`, aws-lc-rs, prefer-PQ) + PSK-MAC over the TLS exporter + commit-then-reveal of random nonces (SAS-MCA) + SAS from the transcript | Amendment to SPEC §6 items 4–5: a nonce is committed, not a key share. libcrux-kem is not added |
| Q-4 · keys without TPM | **a. Password + Argon2id by default**, `x unlock` after boot; `systemd-creds` and a key file only with an explicit flag and a warning in `x doctor` | MVP keystore: an Argon2id wrapper; hardware backends later |
| Q-5 · the §18 criterion | **Refine the wording**: "through the relay, without a reply; directly, closed right after the transport handshake, before any application data and application cryptography; the address of a pairwise endpoint is never published" | The §18 acceptance test checks exactly this |
| Q-3 · libsignal | The maintainer was not asked separately; for the MVP the recommendation **a. git dependency with a pinned rev** was accepted. Revisit before v1.0 (publication, `cargo install`) | — |

The SPEC amendments (§6, §7, §14, §18, the §3 diagram) live here for now; `SPEC.md` has not been edited for them — to be
updated on the maintainer's word. (`SPEC.md` did get one naming update, recorded under "SPEC amendments from research".)

---

## v0.1 MVP, slice 1 "link" (2026-10-02)

Decided during the slice, within the scope of the assigned task. The specification is `docs/PROTOCOL.md`; whatever changes
SPEC is listed below under "Questions for the maintainer (slice 1)" and is **not** considered decided.

### D-13 · Link format: base32 for keys, base64url for the relay, a fourth field only without a relay
- **Decision.** `x://pair#<E_A>.<s>.<relay>[.<direct>]`: the key and the secret are lowercase base32 without `=` (52
  characters each), the relay is base64url (the URL contains dots), the secret is 32 bytes. The `direct` field (a list of
  `ip:port`) appears **only** if A has the relay turned off (tests, LAN); with a relay, no IP gets into the link. The
  link length with the n0 relay is ≈ 180 characters.
- **Why.** The SPEC format is kept; base32 survives case changes when copied; without a relay there is no other way to
  reach A. An IP in the link would expose the inviter to everyone the link passed through (SPEC §4).

### D-14 · One family in pairing: SHA-256 / HMAC-SHA256 / HKDF-SHA256; BLAKE3 for message IDs
- **Decision.** PSK-MAC, commitment, transcript hash, confirmation keys, `link_id`, SAS — only SHA-256 constructions
  (PROTOCOL §7). The message ID is BLAKE3 `derive_key` (SPEC §7).
- **Why.** Fewer primitives in the formal model and in the audit; HKDF-SHA256 is named in SPEC §7; libsignal already pulls
  the same generation of `hkdf`/`hmac`/`sha2`, so there are no duplicates.

### D-15 · `link_id` is derived from the transcript, not chosen by a side
- **Decision.** `link_id = HKDF-Expand(PRK, "x/pair/v0/link-id" ‖ TH)`, `PRK = HKDF-Extract(…, X ‖ s)`.
- **Why.** Shared by both sides, unpredictable for outsiders, and neither side can impose it.

### D-16 · libsignal during pairing lives in memory; to disk only on activation
- **Decision.** `PairingE2e` on top of `InMemSignalProtocolStore`; the contact's identity is pinned from the transcript
  before any operation. On activation, the link's identity, the contact's pinned key and the `SessionRecord` move into
  SQLCipher. Prekeys are not stored: B initiates PQXDH on A's bundle (M6→M7), A answers right away (M8), both sessions are
  confirmed before activation; PreKey messages over the link after pairing are rejected (`NoPreKeys`). M7/M8 carry
  `L_INIT ‖ TH` / `L_ACK ‖ TH`, so the session is bound to the transcript.
- **Why.** A failed pairing leaves no traces on disk; less state means a smaller surface (replay of an old PreKey).

### D-17 · Ephemeral pairing endpoints are "relay only" if there is a relay
- **Decision.** A's invite endpoint and B's endpoint for joining work without IP transports; B uses the relay from the link.
- **Why.** Before the SAS comparison neither side should learn the other's IP (SPEC §4); B does not need to know its own
  relay in advance.

### D-18 · The pairwise endpoint is brought up before `P` is revealed and accepts no one until activation
- **Decision.** The link's key and endpoint are created at the start of the session (real addresses and a port are
  needed for `addrs`); the accept-list is empty (`PeerSlot` = no one) until activation; on failure the endpoint is
  closed. The port is saved and reused after a restart; if it is taken, a random one is used and the contact learns the
  new address from the `hello` frame.
- **Why.** The link's EndpointId must be in the transcript (SPEC §6, Q-1), and the addresses must be real.

### D-19 · Envelope: `{id, core, auth}`, the ID over the `core` bytes
- **Decision.** `core` = CBOR(`EnvelopeCore`: salt, author, parents, lamport, ts, type, body); `id = BLAKE3-DK(ctx, core)`;
  the recipient recomputes the ID and rejects a mismatch. `auth = null` in slice 1 (signatures come in the next slice).
  `author` = the side's link-root Ed25519; `parents` = the current heads (in ascending byte order), `lamport` = max + 1.
- **Why.** Independent implementations do not need CBOR canonicalization; the next slice's signatures will sign the same
  bytes.

### D-20 · Padding outside the libsignal ciphertext, strict parsing
- **Decision.** `RoutingBlob.ct = pad(type ‖ libsignal message)`, `pad(x) = u32be(len) ‖ x ‖ zeros` up to a SPEC §7 bucket;
  `unpad` rejects a non-bucket size and a non-zero tail.
- **Why.** The visible size is exactly a bucket; libsignal's internal padding (AES-CBC) does not hide the size.

### D-21 · Delivery: a request = a bi-stream, `ok` only after commit, the queue stores ciphertext
- **Decision.** Decryption, writing the message and the ratchet step are one SQLite transaction; `ok` is sent after the
  commit. The outbox stores ready `RoutingBlob`s: a retry does not re-encrypt and does not spend counters. An "old counter"
  at the recipient = `duplicate` = delivered. `rejected` 5 times in a row takes the message off the queue. Backoff
  250 ms × 2 up to `--retry-max-ms` (30 s by default); an incoming connection from the contact and `hello` wake the queue
  immediately.
- **Why.** No losses on a break between "decrypted" and "acknowledged", no duplicate messages, SPEC §4 v1.

### D-22 · Control socket: JSON lines, one request per connection, the pairing dialog on the same connection
- **Decision.** `x_proto::control` (Apache-2.0): `hello` (protocol, role) → `req` → `event`* → `ok`/`err`; the owner's
  input (`input`: code / confirmation) goes over the same connection. Permissions: socket 0600, directory 0700,
  `umask 077`, SO_PEERCRED — same uid. The `agent` role is rejected in slice 1 (`not_implemented`). An invite lives as
  long as `x invite` lives (closed it, the invite burned).
- **Why.** Simple for any client (TUI, agent wrappers); no need to store unfinished invites on disk.

### D-23 · CLI exit codes
- **Decision.** 0 — success; 1 — the operation failed; 2 — arguments (clap); 69 — not implemented (D-3); 75 — daemon
  unavailable (EX_TEMPFAIL); 77 — keystore locked / not created / no permission (EX_NOPERM). With `--json`, an error is
  `{"ok":false,"error":<code>,"message":…,"command":…}` on stdout.
- **Why.** An agent can tell "retry later", "the owner is needed" and "this is not allowed" apart.

### D-24 · Keystore: Argon2id 64 MiB / t = 3 / p = 1, password ≥ 8 bytes, AAD = the whole header
- **Decision.** The file `keystore.cbor` (0600): parameters, a 16 B salt, a 12 B nonce, ChaCha20-Poly1305 of the root key;
  the AAD covers all header fields (tampering with the parameters breaks decryption). SQLCipher key =
  HKDF-SHA256(root key). A lower bound on the parameters of 19 MiB (the OWASP minimum) prevents slipping in a weakened
  file. Secrets are `Zeroizing`/`ZeroizeOnDrop`; `PR_SET_DUMPABLE=0`. `mlock` and privsep (SPEC §13) are not in this
  slice. `--key-backend systemd-creds|file` → 69.
- **Why.** RFC 9106 §4 (the second recommended profile, p = 1 without threads); Q-4.

### D-25 · Minor defaults of the slice
- `x invite`/`x join` without `--trust` — level **2** (as in the SPEC §6 example); TTL 10 min by default, 24 h maximum.
- SAS — **6 digits**; emoji are not implemented (question Q-6).
- `x send` waits for the delivery confirmation up to `--wait 2s`, otherwise `queued` (the message stays in the queue).
- `x invite --confirm` (non-interactive confirmation at A) works only with `xd --allow-auto-confirm` (D-26).
- Presence: after `x unlock` the node announces itself (`hello`) only to contacts of level 3+; not to levels 1–2 (SPEC §4).
- `dev` profile: dependencies are built with `opt-level = 2` (TROUBLESHOOTING).

### D-26 · Fixes from the independent security review of the slice (2026-10-02)
Code review against PROTOCOL.md (an independent reviewer, read-only). No critical holes in the normal scenario; fixed:
- `x invite --confirm` removed the protection of SPEC §6 item 9 (whoever intercepts the link computes `mac_B` themselves)
  → the daemon accepts it only with the hidden flag `--allow-auto-confirm` (tests); a normal one answers `forbidden`
  (test `auto_confirm_is_refused…`).
- The pairwise endpoint's IPs went into M1/M2 before the SAS comparison → with a relay, `addrs` contains only the relay;
  IPs come after activation via `hello`.
- A contact could assign its own relay and learn our IP in "relay only" mode → such links only go through their own relays.
- The TTL could fire after the link was saved (the owner saw an error while the link was in the DB) → the TTL only bounds
  the waits up to M6.
- `x lock` did not interrupt pairing (the session held the DB and the keys) → it does now (test
  `lock_during_pairing_cancels_the_invite`).
- A rejected message was silently removed from the queue → a temporary error (`internal`) is retried, a permanent one
  marks the message `failed` after 5 attempts (`x contacts` → `failed`).
- On the link: PreKey messages are rejected before decryption; the author is checked against the contact's link-root;
  `lamport`/`ts`/`parents` are range-checked; the lengths of the bundle and of `addrs` are checked; the `abort` reason
  comes only from an allow-list; the CLI escapes control characters in the contact's text; `Debug` does not print the
  endpoint secret, the link or the token; the link secret is wiped on drop; input sent ahead of time does not count as a
  decision; without a relay, `0.0.0.0` does not get into the link.
- Not fixed (recorded in PROTOCOL §15 and in the questions below): the owner role = the same uid (Q-12); the relay from
  the link sees B's IP (Q-13); the old link connection is not closed when a new one appears (both keep it alive with
  keep-alive, a minor thing).

---

## Questions for the maintainer (slice 1, not decided)

| # | Question | What is done now | Options |
| --- | --- | --- | --- |
| Q-6 | Default SAS: digits or emoji (SPEC §19) | 6 digits; no emoji | a) keep digits (easier to read out by voice); b) add 6 emoji from the same TH as an alternative; c) emoji by default |
| Q-7 | Where the invite lives | While the `x invite` process lives (dialog with the owner on the same connection) | a) keep it so; b) the daemon holds the invite until the TTL, confirmation by a separate command (`x pairing confirm <id>`), needs a DB record |
| Q-8 | Presence for levels 1–2 (SPEC §4) | An open link connection keeps QUIC keep-alive while it is cached: the contact sees "online" | a) close level 1–2 connections right after delivery (+~40 ms direct / ~1 s via relay for the next message); b) idle timeout of 30–60 s; c) leave it |
| Q-9 | Loss of the last pairing message (M8) | Known limitation: A has the link, B does not; fixed by pairing again (PROTOCOL §15) | a) leave it; b) a ninth message + a "half-active" state at A until the first incoming message from B |
| Q-10 | The `direct` field in the link (only without a relay) | An extension of the SPEC §6 format (D-13) | a) keep it for tests/LAN; b) remove it and always require a relay (mDNS discovery comes in v0.2) |
| Q-11 | Default trust level if `--trust` is not given | 2 (D-25) | a) 2; b) 1 (the strictest); c) a mandatory flag |
| Q-12 | Local owner authentication for `invite`/`join` (SPEC §6 item 1, §9) | Owner = any process of the same uid while the keystore is unlocked; an agent of the same user can call `x invite`/`x join` | a) slice 2: agents only via tokens (a separate role), and `invite`/`join` require entering the password again; b) tokens only, no password; c) a separate uid/socket for agents |
| Q-13 | The relay in the link sees the IP of whoever joins | A warning in PROTOCOL §15; level 1–2 links after pairing only go through their own relays — users with different relays will not get a level 1–2 link | a) leave it; b) B joins through its own relay if A's relay is untrusted (needs two-relay support in iroh); c) Tor (v0.3) |

### Maintainer decisions on the slice 1 questions (2026-10-02)
| Question | Decision | Slice |
| --- | --- | --- |
| Q-12 · who is the owner | **a.** Agents only through their own tokens (the agent role) and do not see owner commands; `invite`/`join`/`trust`/`approve`/`rotate`/`revoke` require entering the owner password again | 2 |
| Q-7 · where the invite lives | **b.** In the daemon until the TTL ends; the owner gets a notification that someone joined and confirms the code with a separate command (`x pairing confirm <id>` or similar) | 2 |
| Q-8 · presence of levels 1–2 | **b.** A level 1–2 link connection is closed after 30 s of idleness | 2 |
| Q-6 · SAS | **b.** 6 digits by default; an alternative representation of the same code is 6 emoji (a switch in the CLI/TUI) | 2 |
| Q-9 · loss of M8 | The default recommendation **a** was accepted (a known limitation, fixed by pairing again); the maintainer may revisit | — |
| Q-10 · the `direct` field | Default **a**: keep for tests and LAN | — |
| Q-11 · default level | Default **a**: 2 (as in the SPEC §6 example) | — |
| Q-13 · the relay from the link sees B's IP | Default **a**: keep with a warning; the radical fix is Tor in v0.3 | — |

### SPEC amendments from research (docs/WATCHLIST.md and a survey of existing projects, 2026-10-02)
- §4: QUIC NAT Traversal is neither a standard nor an IETF working group draft, but an individual n0 draft; `X25519MLKEM768`
  for TLS is already RFC 10024.
- §10/§14: the iroh-blobs 0.103 README says "not yet considered production quality"; we keep the bao-tree fallback alive.
- §11: Claude Code Channels is a research preview; a custom channel only via `--dangerously-load-development-channels`;
  it also works with a Console API key.
- §14: there are no ready Flutter bindings for iroh (there are Swift, Kotlin, Python, JS) — for the v1.x mobile clients.
- iroh transport identity stays Ed25519 (n0, 2026-09-15); PQ authentication of the link is at the application layer:
  link-root Ed25519 + ML-DSA-65 under the SAS.
- **Naming update (2026-10-03; not a requirement change).** `SPEC.md` now uses the decided names: the product is
  Antenna instead of `[Name]` (§1; "Product name: Antenna" below), the CLI is `antenna` and the daemon `antennad` instead
  of `x` and `xd` (§2, §3, §5, §6, §9–§13, D-55); the first open question of §19 is marked decided. Protocol labels keep
  their historical names, as D-57 requires: `x/…`, `x-control/N`, `x://pair#`.

### SPEC amendments by the maintainer
`SPEC.md` is not edited for these until the maintainer says so; the decision named holds the details.
- **§9, trust level 5 (SPEC amendment by the maintainer, 2026-10-05; D-99).** "Forbidden at every level: keys,
  passwords, tokens…" now reads, for the owner's own computers: at level 5 (own computers, chosen after a warning the
  owner accepts) secrets are not held for approval, in messages, streams, files or file names; the daemon's scanner
  still runs and the audit log records every finding. At levels 1–4 secrets wait for approval as before. Also at
  level 5: files from outside the link folder and the sender-side check's verdict need no approval, incoming clean and
  suspicious files are accepted automatically (a threat still waits for the owner), and a task's commands run without
  confirmation (§9 "Without confirmation within the scope"; the command sandbox of the level-5 row is not built yet).
- **§10, level 5 without a project folder (2026-10-05; D-99).** "At level 5 the owner explicitly specifies the path to
  the project folder": until one is set, accepted files go to the link's `shared/`, as at levels 3–4.
- **§10, the link folder's name (2026-10-06; D-125).** `~/Antenna/links/<contact>/` is the contact's label as one
  shell word ("hel server" → `hel-server`); a folder made before under the label as it is keeps working.
- **§9 and §18, an agent that approves for the owner at level 5 (SPEC amendment by the maintainer, 2026-10-06;
  D-127, experimental).** "An agent cannot grant permissions to itself or anyone else" and "An agent cannot … approve"
  now read, for the owner's own computers: an agent the owner names an approver (with the password or Touch ID) may
  answer other agents' approval requests in the owner's place, within the scope the owner set, only while everything
  the request touches stays at level 5, and never its own or another approver's requests. The owner's `approve` and
  every other owner command stay absent from agents.
- **§10–§11, what holds a received file (SPEC amendment by the maintainer, 2026-10-06; D-130).** The maintainer: "The
  security settings must be lowered, because ordinary files are already blocked from transfer. This is the basis of
  any messenger: nobody blocks file transfer, especially pictures." From trust level 3, the check's heuristic findings
  (markup or scripts in a file, an HTML polyglot, secret patterns on receive, unknown types) never hold a file: they
  are labels, and the file is accepted the normal way for its level. Held for the owner at every level from 3: native
  executables, installers and disk images outside the signed update flow, archives containing those, real antivirus
  hits; at levels 3–4 also encrypted or uninspectable archives. A held file reads like a browser's dangerous download:
  the danger in plain words, Delete, and Keep anyway with the owner's password; the sender is told it waits, never
  that it was declined. Levels 1–2 are unchanged.

---

## v0.1 MVP, slice 2 "agents and permissions" (2026-10-02)

Decided during the slice, within the scope of the assigned task. The local socket specification is `docs/CONTROL.md`;
acceptance tests are `crates/x-cli/tests/agents.rs`, `control.rs`. Whatever changes SPEC is under "Questions for the
maintainer (slice 2)" below and is **not** considered decided.

### D-27 · The agent token is 256 random bits, only the hash in the DB; biscuit with holder-of-key is for capabilities between links
- **Decision.** `x agent add <name> [--links …] [--local-level N]` (owner password) issues `xat_` + base32(32 bytes from
  the OS). The token is shown once; SQLCipher stores `SHA-256("x/agent-token/v0" ‖ token)`. `x agent reset` starts the
  session over (same token), `x agent remove` revokes it. Biscuit + holder-of-key (D-11) is **not** used for the local token.
- **Why.** Biscuit is needed where the verifier did not issue the token and checks it offline (a capability for a contact
  over a link, SPEC §9). Locally, one daemon issues and checks against its own DB, and holder-of-key gives the same as
  binding to the process (D-28), at the cost of a second copy of Ed25519 (biscuit pulls ed25519-dalek 2, STACK 0.15). A
  token leaked into an LLM context is useless to the provider: reaching the `0600` socket requires a local uid. Another
  local process of the same uid **can** read the token (MCP host configs are stored in the clear); while the host is alive,
  the binding (D-28) does not let the token in from a foreign process tree, and a process from another agent's tree only
  gets in with its own token (D-38). After the host exits, the token is again "bearer".

### D-28 · Binding the token to the MCP host process; the agent's process tree is the agent
- **Decision.** At startup `x mcp` introduces itself with `bind_parent`: the daemon takes the client's PID via
  `SO_PEERCRED`, its parent (the MCP host: Claude Code, Codex…) and start time (protection against PID reuse) via
  `/proc/<pid>/stat`. While the host is alive: the token is accepted only from its descendants (otherwise `token_bound`;
  a second host with the same token is refused; a client without a readable process chain or without a valid parent is
  refused, D-38), and **any** process in its tree, even without a token and claiming to be the owner, gets this agent's
  role (`hello_ok.forced`). When the host exits, the binding is removed (taint stays, D-29). An agent that uses only the
  CLI (without `x mcp`) is bound to the uid.
- **Why.** Claude Code runs commands through a new `bash` for every call (`setsid`, no tty, the parent is the claude
  process: verified empirically), so "the same PID" does not work for the CLI, while "a descendant of the MCP host" works
  both for MCP and for the agent's Bash tool. This way the agent cannot bypass the policy just by removing the variable
  with the token.
- **Limits (honest).** A double fork (the orphan goes to init/subreaper) takes the process out of the tree: it will
  connect as the owner without a token. It does not get around the password that way, but against an agent with a shell
  of the same uid the password is a weak boundary: it can replace the daemon or the `x` binary and capture the password
  the next time it is entered (`docs/CONTROL.md` §11). This bypasses taint/no-write-down for `send`/`inbox`. It is closed
  only by a separate uid for agents or by the daemon launching the agent in a sandbox without access to the socket (v0.2,
  wake). Outside Linux and macOS there is no binding (only the uid); macOS uses `proc_pidinfo` and the audit token (D-P-2,
  D-P-3).

### D-29 · The agent session and what the daemon knows about what was read (SPEC §9, §11 "two sandboxes"; cross-owner information flows, which no existing project covers)
- **Decision.** A session = the life of the token until `x agent reset` (owner, password). The session label is stored in
  the DB and survives daemon restarts and agent restarts: taint `{link, level at the time of reading}`, declared local
  reads, the base label.
  - The daemon **knows**: what the agent read through the daemon (`inbox`, `history` → taint by contact) and everything the
    agent sends through the daemon. The subscription and `wait` give the agent only facts (who, level, length) — no text
    and no taint.
  - The daemon **does not know** which files the agent reads past it. So no-write-down rests on two inputs: the base label
    from the owner, `--local-level N` ("this agent sees data of level N": 0 — a sandbox with only link folders, 5 — the
    project), and declarations via `mark_read` / `x mark-read --level N` — these can be made not by the model but by a
    host hook (Claude Code `PostToolUse` on Read/Grep/Edit → `x mark-read --level 5`): the hook is run by the harness, the
    model cannot skip it. The label only grows.
- **Why.** A new agent process ≠ a new context (`claude --resume` restores the previous one), so resetting taint is only
  the owner's decision. Full enforcement is possible only for an agent launched by the daemon in a sandbox (SPEC §11, v0.2):
  then the base label = what is mounted in the sandbox.

### D-30 · Semantics of the level 1–3 policy (SPEC §9) in the daemon
- **Ceiling (taint, no read up)** = the minimum over the links read of (level at read time, current level): lowering trust
  takes effect immediately, raising it does not remove old taint.
- **Actions the daemon does not perform itself** (`x check read|write|exec` for `PreToolUse` hooks): a clean session —
  everything is allowed (acts on the owner's behalf); ceiling 1 — words only (read/write/exec are forbidden); 2 — read and
  write only after approval, exec forbidden; 3 — read allowed, write after approval, exec forbidden; 4–5 — exec only after
  approval while there is no sandbox (allowlist and sandbox are v0.2).
- **Outgoing** (`send`, `share_file`): link isolation — if the session read another link, approval (SPEC §9 "from link A
  to B only via approval"); no-write-down — a local data label above the recipient's level → approval; the secret scanner
  (PEM/OpenSSH/PGP/age keys, tokens by prefix and JWT, our own `xat_`, an invite link, `password=`, BIP-39 ≥ 12 words) →
  approval at any level, **for the owner too**. Replying with words to the same contact is allowed at any level.
- **Limits** (msg/min: 10 / 30 / 60 / 120 / 600): agents' outgoing messages — refused with `rate_limited` (the approval is
  not burned: the limit is checked before approval and counted after); incoming — back pressure: the daemon holds
  reception for up to 10 s, then does not answer, and the sender retries from its queue. The link format (PROTOCOL §12)
  does not change; nothing is lost.
- **Approval request**: `SHA-256` over (who asks, action, recipient link, text/details) + a random nonce, valid for
  10 minutes, single-use; the approval is looked up by hash (the agent does not need to remember an ID) or by
  `approval_id`; a different text/recipient/agent — `approval_mismatch`, a repeat — `approval_used`. Stored in the
  daemon's memory: a restart burns the pending ones (the safe side). The request is attributed to the contact whose data is
  in the session (the lowest level), otherwise to the recipient; > 3 requests per contact within 10 minutes accumulate
  without a notification (`x approvals --all`); `x deny --hour` rejects everything for the contact for an hour. Display:
  permissions structured (Read · Write · Commands · Send), the text separately as a quote with control characters escaped.
- **The agent sees** only incoming messages that arrived after it was created, and only on its own links; each agent has
  its own read cursor (the owner and agents do not "eat" each other's messages).

### D-31 · Audit log — a local `receipts` table, not the shared hash-DAG (replaced by D-47 in slice 3)
- **Decision.** Every agent action on a link (reading, sending, check, files, approval decisions, level change) is a
  `receipts` record in SQLCipher; `x log <contact>` (for an agent — on its own links). Message text does not go into the
  record.
- **Why.** SPEC §9 wants a `receipt` in the shared hash-DAG, i.e. sent to the contact. That is a new wire type (PROTOCOL
  §12, only `text` in slice 1), and changing §12 was outside this slice's mandate (the formal model was being worked on in
  parallel). Question Q-16.

### D-32 · The invite lives in the daemon (Q-7)
- **Decision.** Side A is a daemon background task; `x invite` only follows (events, entering "yes" with an already checked
  password); closing `x invite` does not burn the invite. `x pairing [--wait]` — a list and a "notification" (returns when
  the code is ready or confirmation is needed); `x pairing confirm <id> [--code CODE]` (password) is accepted only after
  the correct input at B; with `--code` the daemon checks the code of exactly this invite (formal model: a spoken "it
  matches" does not name the session, F-4). `x pairing cancel <id>` burns it. The invariant "A's bundle only after the
  owner's decision" (F-1) is kept: A's state machine did not change. `x lock` interrupts all invites.

### D-33 · Presence of levels 1–2 (Q-8)
- **Decision.** A link connection where **our** level for the contact is ≤ 2 is closed after 30 s without application
  activity (requests in both directions); levels 3+ keep the connection. In contacts, `presence`: `online`/`offline` for
  3–5, `not_tracked` for 1–2.
- **Limit.** A level 1–2 contact can still learn that the node is online by trying to deliver a message (the connection is
  accepted). Without a mailbox (SPEC §4, v2) this cannot be removed.

### D-34 · SAS emoji — the same number, a different representation (Q-6)
- **Decision.** Digit → emoji by a fixed table (the first 10 emoji of the SAS Matrix table, all animals: 🐶 🐱 🦁 🐎 🦄
  🐷 🐘 🐰 🐼 🐓), PROTOCOL §7, test vector 645826 → 🐘🦄🐷🐼🦁🐘. B enters digits, emoji or names (Russian/English); the
  node normalizes the input to digits and compares as before. `--sas digits|emoji|both` in `x invite`/`x pairing`; digits
  by default.
- **Why.** "An alternative representation of the same code" (Q-6): the entropy and the protocol are unchanged, the formal
  model does not change.

### D-35 · Control protocol v1 for interfaces (requested for the Flutter client)
- **Decision.** `x-control/1`: `history` (pages by `seq`, both sides, delivery status), `subscribe` (one long-lived
  connection: messages, statuses, contacts, invites, approval requests; for an agent, facts without text), `presence` and
  `peer_kind` in contacts. `x-control/0` is accepted; v1 only adds (`docs/CONTROL.md` §2). CLI: `x history`, `x events`.
- **Why this way.** The subscription goes through the daemon's internal `broadcast`: a lagging subscriber gets `lagged` and
  re-reads the state; the daemon does not keep a queue on the client's behalf. `peer_kind` is `unknown` for now: agent
  sub-identities are v0.2.

### D-36 · Levels 1–2 in tests go through a real local relay
- **Decision.** Integration tests bring up `iroh-relay` 1.3 (feature `server`, a dev dependency of `x-cli`, HTTP on
  127.0.0.1) in a test thread; nodes run with `--relay http://127.0.0.1:PORT --bind-ip 127.0.0.1`. A level 2 pairing
  through it takes ≈ 0.6 s.
- **Why.** Levels 1–2 are "relay only" (SPEC §4); they cannot be created without a relay; a test flag "direct mode for 1–2"
  would test something other than what the user gets.

### D-37 · Owner password: brute force through the daemon is slowed down
- **Decision.** After 3 wrong passwords in a row (`unlock` and owner commands) the daemon does not check the password for
  1, 2, 4 … 60 s (`rate_limited`). A correct password resets the counter.
- **Limit.** An agent of the same uid can copy `keystore.cbor` (0600, but the same user) and brute-force the password
  offline (Argon2id 64 MiB, t = 3 — expensive, but not impossible for a weak password). Question Q-19.

---

## Questions for the maintainer (slice 2, not decided)

| # | Question | What is done now | Options |
| --- | --- | --- | --- |
| Q-14 | A process of the same uid **outside** the MCP host's tree can claim to be the owner without a password and call `send`/`inbox`/`history` bypassing taint and no-write-down (the secret scanner still applies here) | The password is only for trust commands (decision Q-12a); the D-28 binding catches the host's process tree | a) leave it and document; b) for the owner, a password login per interface session (TUI/Flutter keep a connection), and a one-off owner `x send` with a password; c) agents under a separate uid (a group on the socket); d) the agent only in a daemon sandbox (v0.2) |
| Q-15 | Default base label of a new agent, `--local-level` | After the review — **5** (safe: the daemon does not see what the agent reads past it; SPEC §9 "no rule depends on the model's obedience"); 0 explicitly for an agent in a sandbox | a) 5 (now); b) a mandatory flag with no default; c) 0 + hooks |
| Q-16 | `receipt` in the shared hash-DAG (SPEC §9) — needs a `receipt` wire type (PROTOCOL §12) | A local table and `x log` (D-31) | a) add the type to §12 in the next slice (together with signatures); b) keep it local |
| Q-17 | Approval "always allow for this contact" (SPEC §9) | No: only once, deny, "reject for an hour" | a) do it as a temporary narrowing of a capability (v0.2, with biscuit tokens); b) do not do it: it is essentially a level change — `x trust` |
| Q-18 | `x trust <contact> N --for 24h` (SPEC §9) | `not implemented` (69) | a) v0.2 together with automatic downgrade; b) now |
| Q-19 | Owner password length: an agent of the same uid can brute-force `keystore.cbor` offline | Minimum 8 bytes | a) minimum 12 and a dictionary check; b) a passphrase of 4+ words by default; c) leave it |

### Maintainer proposal: streaming agent replies (2026-10-02) — planned for v0.2, together with wake
The maintainer: agents write for a long time, so the user should see an agent's reply gradually, as it is being written,
as in ChatGPT/Claude.
Maintainer decision: do it in v0.2 together with wake (SPEC §11); lay the groundwork in the protocol and design now.
Sketch (to be refined in PROTOCOL.md during implementation):
- A stream message: open → chunks → final. Chunks are encrypted with the STREAM construction from SPEC §7 (key from the
  ratchet, chunk index and end flag in the AAD) — no custom cryptography. Only the final message goes into the history,
  the hash-DAG, the signatures and the verification; chunks are ephemeral. A break — a final "interrupted" with whatever
  arrived.
- Source of the stream: an agent launched by the daemon (wake: `claude -p --output-format stream-json`, `codex exec`), and
  `<program> | x send --stream <contact>`. MCP passes the tool text whole, so there is no stream for MCP agents (only a
  "typing…" indicator).
- SPEC bounds: a stream = a typing indicator → only to contacts of level 3+ (SPEC §4); levels 1–2 get the finished message.
  The secret scanner checks every chunk before sending, holding back a "tail" at chunk boundaries; if a secret is found,
  the stream is cut. Messages that need approval are not streamed.
- Beyond ChatGPT: "what the agent is doing now" (reading a file, running tests) — only to levels 4–5.
- Interface: a "live" reply bubble with a cursor and a status; an agent receiving a message does not need the stream (MCP
  gives the final).

### D-38 · Fixes from the independent security review of slice 2 (2026-10-02)
Review of code `0975782` against SPEC §9/§11/§15 and PROTOCOL (an independent reviewer, read-only, experiments on built
binaries in temporary directories). Fixed (tests — `tests/agents.rs`, `tests/control.rs`, unit tests `policy`,
`procinfo`, `output`):
- **Critical — the owner password could be bypassed by swapping `keystore.cbor`** (an agent of the same uid copied in its
  own keystore and passed the check with its own password). Now the daemon checks the password against the keystore
  **remembered at unlock** and against the root key fingerprint in memory; the swap shows up in the log (test: a swapped
  file → `wrong_password`, the real password works).
- **Link isolation via `history`**: a page with only outgoing messages did not affect the label — now any history read
  adds the link to "read" (cross-link), incoming messages also to the ceiling; an agent gets only the history after its
  creation.
- **No-write-down depended on the model's obedience** (`--local-level 0` by default) → **5** by default; plus a ready
  hook adapter `x hook claude-code` (PreToolUse → `check`, PostToolUse of reads → `mark-read`), run by the harness.
- **The process check failed open** (depth > 64, a vanished `/proc`, an orphan under PID 1): the client's process chain
  is read in full up to PID 1 right at connect; if it cannot be read — refused (if there are bound agents); a token is not
  bound to PID 1, systemd, a session leader or the daemon's ancestors; a process from agent A's tree does not get in with
  agent B's token; `x agent reset` no longer removes the binding (otherwise a live host's tree became the "owner").
- **Unbounded approvals**: ≤ 16 pending per requester and ≤ 32 per contact, quote ≤ 4096 characters, a repeat of a pending
  request does not write the audit log, limit refusals at most once a minute, a link's audit log ≤ 10,000 records; ≤ 3
  notifications per 10 minutes — both per contact and per requester; the text length and whether the link is active are
  checked before approval (the approval is not burned); the slot in the limit is taken atomically and returned if the
  sending did not happen.
- **Pairing confirmation names the session**: "yes" carries the code the owner saw (`x invite` follows and sends it,
  `x pairing confirm` shows the code and the label and sends the code); a failed attempt resets the step and the code; the
  link and the code in `pairings` only with the password, never in the subscription.
- **Socket**: a line is bounded before it is read into memory, `hello` is awaited for 10 s, ≤ 256 connections, a pause on
  an accept error, password checks one at a time (no parallel 64 MiB Argon2id runs).
- **Approval screen**: invisible characters are escaped too (text direction, zero width, U+2028/2029), the quote is
  wrapped with `│` on every visible line and limited to 4000 characters, after the quote — the request's summary line.
- **Minor**: `check write` takes the path into account (a tainted session writes without approval only to `~/X/links/`;
  memory/CLAUDE.md/configs require approval at any level); a revoked agent's subscription is closed; an agent's `log` —
  only its own records, an agent's `status` — without the number of links; `Debug` does not print texts, links, codes,
  quotes or the token; `x` does not dump core; the race between `x trust` and `x lock` is closed.
- **Not fixed (limits, `docs/CONTROL.md` §11):** an agent with a shell of the same uid against the owner (swapping the
  daemon/binary, offline brute force of the keystore, `kill`), double fork and wrappers around `x mcp`, tokens in plain
  configs, the secret scanner catches accidental pasting rather than deliberate exfiltration (splitting, base64,
  paraphrase), `lock` without a password (the safe side), passwords in `Request` are plain `String`s (the line containing
  them is read into `Zeroizing`).

### D-39 · Pairing v1: `psk_mac` covers the whole M1 body (formal model F-3, team decision)
- **Decision.** `psk_mac = HMAC(K_psk, "x/pair/v1/psk-proof" ‖ X ‖ E_A ‖ E_B ‖ u16be(v) ‖ lp(suite) ‖ C_B ‖ party(P_B) ‖
  addrs(P_B.addrs))`, `addrs` is encoded unambiguously (PROTOCOL §7). Pairing version 1, `SUITE` `x-pair/1;…`; v0 and v1
  nodes do not pair (`abort{"version"}`). Burning the invite after the first correct `psk_mac` remains mandatory.
  The test vectors of appendix A were recomputed and matched between Rust and the independent `docs/protocol_vectors.py`
  (`psk_mac 40e04b7f…`, `TH 9cb46025…`, SAS `169264`); unit test: changing any M1 field, including `addrs`, changes the MAC.
- **Why.** Without this, with broken TLS, an attacker replaying M1 could tamper with the fields of someone else's M1 (only
  burning the invite protected against it). The formal model (`formal/`) was updated for v1 (2026-10-02): tampering with M1
  fields while the link is not disclosed is caught by the MAC even with broken TLS (`formal/psk.pv`), the v0 MAC is an
  attack (`formal/neg_v0mac.pv`); replaying the whole M1 with broken TLS is still covered only by burning
  (`formal/replay_tnull.pv`). Confirmation with the code (F-4) — `formal/neg_nocode.pv`.
- **F-1** (a bundle with the identity from `TH`, step B8, and "A creates the bundle only after the owner's decision"): the
  order did not change — the invite in the daemon runs the same A state machine; the B8 check was moved into a function
  with a unit test (a foreign identity and broken lengths — refused). **F-4**: D-32, D-38 (the confirmation carries the code).

### D-40 · Secret scanner for streaming replies (requested ahead of the stream itself, which is v0.2)
- **Decision.** `policy::SecretStream` releases text chunk by chunk, holding back a "tail" where a secret could start at a
  boundary: an unfinished word, the last 48 bytes (PEM markers with spaces), an unfinished series of BIP-39 words (< 12).
  The check window is up to 256 bytes of already released context + the held part, the same pure `scan_secrets`. Once it
  finds something, it releases nothing more (the whole message goes through approval). Held back ≤ 8 KiB.
- **Checked.** For every secret in the set and **every** cut point, and for chunks of 1…1000 bytes: the secret is found,
  its substance is not released; text without secrets comes out whole and unchanged.


---

## Visual version, stage 1 — the desktop app (2026-10-02)

Decided while building the interface, within the assigned task (maintainer decision: Flutter + Rust core,
docs/DESIGN.md). Numbers have the D-UI prefix so as not to collide with the core slices.

### D-UI-1 · The window is a client of the control socket; the protocol client is pure Dart behind the `XDaemon` interface
- **Decision.** `apps/x_desktop/lib/protocol` depends only on `dart:io`; screens and state know only the `XDaemon`
  interface.
- **Why.** Keys, network and permissions stay in `xd` (the daemon, not the LLM, checks permissions: SPEC §9). On
  phones (v1.x) the same interface is implemented by the core embedded via flutter_rust_bridge, and the screens do not
  change. The same code works for Dart utilities.

### D-UI-2 · Feed = `history` + `subscribe`; the window does not call `inbox`
- **Decision.** After unlock: `contacts` → one long `subscribe` → `approvals`, `pairings`, `history limit 1` per link; the
  feed comes in pages of 50; transport/E2E facts — polling `contacts` every 10 s; `lagged` or a dropped subscription —
  re-read.
- **Why.** `inbox` marks messages as read for all clients: the window would "eat" the queue of the CLI and agents. The cost
  is that the window's unread counters live from the moment it started (DESIGN "needed from the daemon" item 1).

### D-UI-3 · The owner password is asked for every trust command; the window does not store it
- **Decision.** invite, join, trust, approve, deny, pairing confirm/cancel ask for the password every time (Q-12a); the
  field is cleared right after sending. *Revised 2026-10-03 (D-84): deny no longer asks; Q-12a never listed it.*
- **Why.** Maintainer decision. Limitation: Dart strings are immutable, so the password cannot be wiped from the window's
  memory — it lives until garbage collection. The protection against this is the daemon itself (the password is checked
  with Argon2id, brute force is slowed down, D-37).

### D-UI-4 · Pairing confirmation at A: the owner enters the code (revised 2026-10-02 per D-41 / F-4)
*Revised 2026-10-05 (D-95): once the joiner entered the code, the window shows one button instead of the code field; the
code field stays for two invites with codes at once and for older daemons.*
- **Decision.** At the confirmation step the window **does not show** the code and does not fill it in: A's owner enters
  the code that B read out to them (6 digits or 6 animals) and the owner password; the window sends
  `pairing_confirm {id, code, password}`. An empty code — "Enter the code" without a request; `sas_mismatch` — "This is not
  the code of this invite", the invite stays alive and the code can be entered again; `wrong_password` — its own error.
  The `linked` result also arrives on the `invite --follow` following connection. "Doesn't match — decline" is
  `input confirm {yes:false}` on the following connection (declining does not need the code).
  Invites created with `x invite` are confirmed with the same field; the window shows the link and the code to read out
  only after `pairings` with the password.
- **Why.** A spoken "it matches" does not name the session (PROTOCOL §15, formal model F-4): a "yes" with the displayed
  code filled in is the same as confirming without comparing, and it would also confirm a tampered session. Entering the
  code from B's words binds the confirmation to what B actually entered. `pairing_confirm` rather than
  `input confirm {yes, code}`: on a wrong code on the following connection the daemon stays silent (debug log only),
  while `pairing_confirm` answers with an explicit error. The cost is entering the password a second time (at creation
  and at confirmation), as with `x pairing confirm`.
- **First version (cancelled).** The button "It matches — create the link" sent `input confirm` with the displayed code.
- **Revision for x-control/2 (2026-10-02).** The daemon now answers input on the following connection with an
  `input_rejected` event (CONTROL §6), so the window confirms **without a second password**: `input confirm {yes, code}`
  with the code the owner entered, on the same `invite --follow` connection (the password was checked when the invite was
  created). A wrong or empty code — `input_rejected` → "This is not the code of this invite", the invite stays alive.
  Invites from `x invite` (without a following connection in the window) still use `pairing_confirm {id, code, password}`.

### D-UI-5 · Delivery status only moves forward
- **Decision.** sending → queued → delivered/failed; a `message(queued)` event that arrives after the `send(delivered)`
  reply does not roll the status back. The message being sent is matched with the event by id, without duplicates.
- **Why.** The `send` reply and the subscription events arrive in any order (test against a live daemon).

### D-UI-6 · Fonts are bundled with the app
- **Decision.** IBM Plex Sans/Mono (OFL) and a subset of Noto Emoji (OFL) with the 10 SAS animals — 9.6 KB, built with
  fonttools (instancer wght=500 + subset by the code points of `x_proto::sas::EMOJI`).
- **Why.** The same look on every OS; the verification code looks the same on both sides (Apple's system emoji and Noto
  differ); monospaced time and digits are part of the mockup's style; real glyphs in the golden screenshots.

### D-UI-7 · macOS: App Sandbox off
- **Decision.** `com.apple.security.app-sandbox = false` in both entitlements.
- **Why.** From the sandbox, a unix socket outside the app container is unreachable (`~/.local/share/x/xd.sock`, ssh
  forwarding). Distribution through the App Store (v1.x) will need another path (XPC/an app group) — decide then.

### D-UI-8 · Slash commands — only existing `x` commands
- **Decision.** `/invite /join /trust /approvals /pairings /log /contacts /status /lock`; plain text = `x send`; a leading
  `//` escapes. Commands the daemon does not have (verify, share, files, rotate, revoke) are not in the suggestions;
  `/inbox` is excluded per D-UI-2.
- **Why.** The interface must not promise what does not exist (our rule: honest measurements, no stubs presented as
  features).

### D-UI-9 · Golden screenshots
- **Decision.** In tests, fonts are loaded from the same `FontManifest.json` as in the app (`test/flutter_test_config.dart`);
  regression at DPR 1 (`test/goldens/`), frames for the maintainer are the same scenarios at DPR 1.5
  (`docs/design/screens/`); mockups of the future are separate `D*` frames with a banner "DESIGN · NOT YET IMPLEMENTED IN
  THE DAEMON".
- **Why.** By default flutter_test draws text with the Ahem font (black rectangles); DPR 1.5 is readable on Retina with
  reasonable file sizes.


### D-UI-10 · The window brings up the daemon itself: macOS — a LaunchAgent, Linux — a child process (user path, 2026-10-02)
- **Decision.** If the daemon does not answer, `xd` is present in the app (`x.app/Contents/Helpers/xd`; on Linux, `bin/xd`
  next to the window) and the socket is the default one, the window starts the daemon itself. macOS: a user LaunchAgent
  `~/Library/LaunchAgents/dev.x.xd.plist` (`launchctl bootstrap gui/<uid>`; when the path changes — `bootout` and again;
  `KeepAlive.SuccessfulExit=false` — restart after a crash, not after a normal stop; log `~/Library/Logs/x/xd.log`). Linux
  desktop: a child process, SIGTERM when the window closes. An already running daemon — just connect. "Stop daemon" in
  the window — with no unilateral restart. A socket forwarded over ssh belongs to someone else; our own daemon is not
  started for it.
- **Why a LaunchAgent on the Mac.** The owner's assistant on that Mac (Claude Code, a custom script) and receiving
  messages must not depend on the window being open; launchd is the standard macOS way to keep a user process running,
  without root and without home-made "daemonizers". The cost: x will appear in macOS "Login Items" (visible to the owner),
  and after login the keys are locked until the password (Q-4). A child process on the Mac is simpler, but the daemon
  would die with the window. Checked: the plist and the launchctl sequence — with a stubbed executor; not on a real Mac
  (there is no macOS here).

### D-UI-11 · Packaging: the core inside the app, ad-hoc signature, .dmg; Linux — tar.gz + install.sh (systemd user)
- **Decision.** `packaging/macos/build-dmg.sh`: `cargo build --release` (arm64 by default; universal via lipo) →
  `flutter build macos` → `xd` and `x` into `x.app/Contents/Helpers/` (`Contents/MacOS/` already holds the window named
  `x`) → `codesign --sign -` (ad-hoc) → a `.dmg` with an "Applications" shortcut and "If it doesn't open.txt". Workflows
  `.github/workflows/release-macos.yml` (macos-14) and `release-linux.yml` (x86_64 and aarch64, `cargo test`, window tests
  against the built xd, an install.sh check). `packaging/linux/install.sh`: binaries into `~/.local/bin` (or `--prefix`),
  a systemd **user** service, `x init`; no apt and no root.
- **Why.** There is no Apple Developer ID signature, so ad-hoc is mandatory (arm64 does not run unsigned code);
  Gatekeeper is bypassed with "Open via right click" / "Open Anyway" / `xattr -dr com.apple.quarantine`. The workflows had
  not been run yet: the GitHub repository did not exist at that point.

### D-UI-12 · "Connect an agent": the label is mandatory, the path to `x` is absolute, hooks on macOS carry the token
- **Decision.** The screen requires a name and a data label 0–5 with no default (Q-15 b), the owner password, and links —
  all or selected ones; the token is shown once; snippets use the absolute path to `x` from the app: `claude mcp add x
  --scope user --env X_AGENT_TOKEN=… -- <x> mcp`, `.mcp.json`, Claude Code hooks, Codex `config.toml`, a bash loop
  `x --json inbox --wait`. `X_SOCKET` is added only if the window does not work with the default socket. On macOS the
  hook command carries `X_AGENT_TOKEN`: outside Linux there is no binding to the process tree (D-28) (docs/PORTABILITY.md).
- **Why.** The owner connects their assistant themselves, following the instructions; the agent does not need `x` in
  PATH; with `--scope user` the token does not end up in the project repository. Live test: the bash snippet really
  replies, `x mcp` answers initialize/tools/list without owner commands; an agent with label 5 writes to a level 3
  contact only with approval (exit 77) — this is stated on the screen and in the USER-GUIDE.

### D-UI-13 · The window's owner session: one password for the keys and the session; the `login {hold}` connection lives with the window (x-control/2)
- **Decision.** The window speaks `x-control/2`. After `unlock`/`init`, the same password opens the session
  `login {password, hold: true}` (CONTROL §3, §13): the token from the `session` event goes into `hello.session` of all of
  the window's connections, and the session connection is kept while the window is open. If the daemon is already running
  with the keys open (LaunchAgent, the window restarted) — the "Sign in" screen (only `login`). The session connection
  closed or `login_required` arrived — "Sign in" again; `err{locked}` — "Keys are locked". The lock at the top of the
  window (`lock`) closes the session too.
- **Why.** Maintainer decision Q-14b: a process of the same uid is not the owner without the password. A `held` session
  is bound to the window process (PID + start time) and dies with it — no "dangling" session remains after the window
  closes. Entering the password once means less friction: the owner is not confused about why the password is asked twice.

### D-UI-14 · Unread counts come from the daemon (`unread` + `mark_read`), receipts as a service line
- **Decision.** Counters are taken from `contacts[].unread`; selecting a link and an incoming message in the open chat —
  `mark_read` up to the last incoming `seq`. Receipts (`kind: receipt`) — a line "who · action: decision" with a mark of
  whose signature it is, not a bubble; they do not go into the list preview or into unread. In the action log: `→` our own
  receipt in the shared history, `←` the contact's receipt, `·` a local-only record.
- **Why.** The "read by the owner" state is shared by the window and the owner's `x inbox` (checked against the daemon:
  after `mark_read` from the window, `x inbox` is empty) — counters do not diverge between the window and the CLI; the
  agents' queue does not depend on it.
### D-41 · Re-check of the fixes by the same reviewer (2026-10-02)
Experiments on the new binaries confirmed no. 1, 5, 6, 7, 8, 9, 11 as closed; no. 14 was closed partially. A regression
was found and fixed: `x pairing confirm` filled in the current code by itself (the same as confirming without the code) —
now the owner enters the code and the daemon requires `code`. Finished: wrapping the quote by width in columns and escaping
wide spaces; the links folder is only the real `~/X/links`; a timeout on the request after `hello`; the owner's pending
requests are outside the per-contact limit; the keystore is remembered after the session is opened; the CLI does not panic
on a closed stdout; a hook without a token works by the host's process tree.
Remaining (limits, CONTROL §11): the PID reuse window between connect and reading `/proc` (closed by `SO_PEERPIDFD`,
kernel ≥ 6.5); a subreaper is recognized only by `comm == systemd` (tini, dumb-init, s6 are not); symbolic links inside
`~/X/links` are not canonicalized; `policy::SecretStream` is not used yet (ready for the v0.2 streaming replies).


### Decisions on the slice 2 questions (2026-10-02)
| Question | Decision | When |
| --- | --- | --- |
| Q-14 · a same-uid process outside the host's tree | **b. Owner login with a password per session** (like sudo): the window/TUI hold a session, the CLI a 15 min session; without a session a process is not the owner. A continuation of maintainer decision Q-12a ("tokens for agents + password"). Full closure — agents in a daemon sandbox (v0.2) | slice 3 |
| Q-15 · the agent's base label | **b. A mandatory choice in `x agent add`** (no default; hint: 5 — an agent with access to projects, lower — a front-desk agent) — maintainer decision | slice 3 |
| Q-16 · receipt in the shared DAG | **Do it** — a direct requirement of SPEC §9; a `receipt` type in PROTOCOL §12 together with signatures | slice 3 |
| Q-17 · approval "always allow" | **Do it** — a requirement of SPEC §9; as a narrowing of a capability with biscuit | v0.2 |
| Q-18 · `trust --for` | **Do it** — a requirement of SPEC §9; together with automatic downgrade | v0.2 |
| Q-19 · password length | **c. Keep the minimum of 8** — maintainer decision (the risk of an offline brute force of `keystore.cbor` by an agent of the same uid is recorded in CONTROL §11) | — |

---

## v0.1 MVP, slice 3 "history and integrity" (2026-10-02)

Decided during the slice, within the assigned task and the maintainer decisions Q-14b, Q-15, Q-16. The specification is
`docs/PROTOCOL.md` §12, §14 (C12–C16), §16–§18, appendix B; the local socket is `docs/CONTROL.md` (x-control/2). Acceptance
is `crates/x-cli/tests/history.rs`. Whatever changes SPEC is under "Questions for the maintainer (slice 3)" below and is
**not** considered decided.

### D-42 · Link format v1: a link-root Ed25519 signature over `core` with context, the author counter `n`
- **Decision.** `envelope.auth = {"sig": Ed25519(sk_author, "x/link/v1/msg-sig" ‖ link_id ‖ recipient_root ‖ u64be(n) ‖
  lp(core))}`; `core` gets a new field `n` — the author's message counter in the link (1, 2, 3… with no gaps). The author
  key is the side's link-root Ed25519 (pinned in `TH`); verification is `verify_strict`. The recipient rejects a wrong
  signature (`bad_signature`), and another message from the same author with the same `n` is treated as a history
  divergence (`history_conflict`). `routing-blob.v = 1`: the link does not work with slice 1–2 nodes (their links are
  re-created; the DB migrates by adding columns).
- **Why.** SPEC §7: "the link ID, the recipient key and the message counter are signed" — libsignal's counter is not
  available to us and does not fit the history, hence our own author counter, which is also the number for rollback
  detection (SPEC §8) and the divergence point. The signature covers the same `core` bytes that are hashed into the ID
  (D-19). The hybrid with ML-DSA-65 is for checkpoints (v0.2); per SPEC, ordinary messages are signed with Ed25519. The
  deniable mode (MAC) is v0.3.

### D-43 · History verification: author chains and a summary under TLS; resending over E2E; a fingerprint of 3 SAS animals
- **Decision.** Instead of "exchange the set of heads and send what is missing one by one" — a `sync` summary: the heads
  + for each of the two authors `(count, chain(count))`, where `chain(k) = BLAKE3-DK(ctx, chain(k−1) ‖ id_k)`. The summary
  goes under the link's TLS 1.3 (the contact's key was pinned at pairing), **without** the ratchet: it has no content, and
  after a rollback the ratchet is broken — exactly when the summary is needed. What is missing is resent with
  `resend` — inside the Triple Ratchet, in batches, checking the ID and the signature of every envelope (including our own
  messages that the contact returns after a rollback). Verification runs on every new connection before the queue is
  delivered, after a batch of messages (1.5 s of quiet) and on `x verify`. "History verified" means the heads, counters
  and chains are equal and the copy checks are clean. The fingerprint is 3 emoji from the same table of 10 animals as the
  SAS (`BLAKE3-DK(ctx, link_id ‖ heads) mod 1000`).
- **Why.** A set of heads says "same/not the same", but not "what is missing" without walking the whole DAG; two 32-byte
  chains give both the equality of the copies (the ID fixes the content and the parents), what to resend (`n` after the
  contact's counter), and a rollback (the contact has more of my messages than I do), in one exchange and O(1) over the
  network. The fingerprint is for humans ("I have 🐼🐶🐓 — so do I"): the exact comparison is done by the daemon; the 10
  animals are already bundled in the window (D-UI-6) and are easy to name by voice (Q-6). 1000 variants are enough to
  notice a divergence when shown, but not as a cryptographic check — this is written in PROTOCOL §16.

### D-44 · Checking our own copy and finding the divergence point in the MVP (SPEC §8 items 3–4; Merkle in v0.2)
- **Decision.** (1) **Our own copy** is checked in full once after unlock (and after a restore, on `x verify`): the ID from
  the `core` bytes, the columns against `core`, the chains, the heads by `core.parents` — one pass over the index, no
  sorting. This reveals a manual edit of the text in the DB with the old ID (the most natural "manual edit"), with the
  exact location. Signatures are **not** checked here (they were checked on reception; a substitution with a recomputed ID
  changes the chain, which the summary catches). (2) **The point** when the chains do not match — chain checkpoints every
  1024 messages (in the daemon's memory) with a step that is a multiple of 1024, ≤ 1024 points, then the IDs inside the
  block, with each side checking the signature of its own copy. (3) **Whose copy** — by the signatures of both copies at
  that point (PROTOCOL §16, table). (4) The divergence is recorded on both sides (`links.hist_note`), the link becomes
  "read-only" (sending and receiving — a temporary refusal, the contact's queue waits), the owner's decision is
  `x verify --accept` (password) or `--repair` (our damaged copy with the old ID is restored from the contact's copy, the
  author's signature is checked). Damage to our own copy blocks only our side; the contact sees "the contact's copy is
  damaged".
- **Measurements** (our build server, `sync::tests::audit_scale`, `--ignored`): checking a copy of **1,000,000** signed
  messages from one author — **7.3 s** (x-core and dependencies at -O2), 100,000 — 1.39 s in debug (linear; the first
  version, in portions with `ORDER BY` without an index, was quadratic — TROUBLESHOOTING); the divergence search replies
  for 1 million (976 checkpoints + 1000 IDs with signature checks) — **65 ms**. Over the network for 1 million: 2
  exchanges, ≤ 64 KiB; memory — 32 bytes per 1024 messages permanently + a set of IDs (≈ 70 MB per 1 million) while the
  copy is checked. Writing 1 million signed messages in the test — 332 s (signing + DB encryption). A full binary search
  over a Merkle tree (≈ 20 rounds) is v0.2: it is needed when the copies diverge in many places or the copy cannot be held
  in memory.
- **Why this way in the MVP.** Correct and honest: the point is found exactly (tests: a text edit and a substitution with
  a recomputed ID), with a constant number of rounds. The cost is an O(N) copy check on every unlock (not on every
  connection): a DB edit **while** the daemon is running will be seen at the next unlock or `x verify` — recorded as a limit.

### D-45 · Rollback protection without TPM: a counter in the DB and a file outside the DB; rekey confirmed by both owners
- **Decision.** Every transaction that changes the link's ratchet session increments `links.state_counter`; **after** the
  commit the same value is written to `state-counters.cbor` (outside the DB; HMAC-SHA256 under a key derived from the
  device root key; atomic write, values only grow). At unlock, DB less than the file → the link is
  `rolled_back:local_counter`; no file, or a corrupted one, with non-zero counters → the same (the safe side). The contact
  sees the rollback by the numbers (`n`) in the summary and blocks **our** side with our own hands: it sees by itself that
  the contact has more of its messages (`rolled_back:contact_numbers`). A blocked link encrypts nothing and rejects incoming
  messages temporarily. **Rekey** (`x rekey`, password on both sides): the side with the rollback sends a fresh prekey
  bundle on the pinned identity, signed by the link-root (`rekey_offer`, ≤ 10 minutes); the other side, after its owner
  confirms, does `process_prekey_bundle` and sends the first message of the new session, and the answer is the
  confirmation. Both sides re-encrypt the queue with the new session; whatever was lost in the rollback comes back by
  resending; while the contact has more of my messages, new ones wait (`recovering`), and our undelivered messages with
  taken `n` are sent again.
- **Why this way.** The order "DB, then file": after a crash the file lags and catches up — no false blocks, while a DB
  restored from a backup is always less than the file. **Both** owners confirm: whoever stole an old copy of the DB has all
  the link's long-term keys; a rekey without the other side's confirmation would give them a fresh session in the victim's
  name and cancel the ratchet's post-compromise security. libsignal brings up a new session from a bundle in the standard
  way (no custom cryptography), and the bundle's identity was pinned at pairing — the bundle cannot be swapped.
  Re-encrypting the queue: blobs encrypted with the stale state are not sent.
- **Limits (honest).** Without TPM the file is on the same disk: a rollback of the **whole** data directory or a VM
  snapshot rolls it back too — only the contact catches that, by the numbers during verification (unless the contact rolled
  back at the same time). Messages encrypted after such a rollback and before the first verification stay in the queue and
  are re-encrypted after the rekey, but if the contact is unreachable and the owner has already sent something new, the
  ratchet keys may have been reused locally in the DB (they did not leave the device). TPM / Secure Enclave monotonic
  counters come together with a hardware keystore (Q-4, later).

### D-46 · The owner session (maintainer decision Q-14b)
- **Decision.** Without a session, a process of the same uid gets only `status`, `init`, `unlock`, `lock`, `login`,
  `logout` and commands with a password; everything else is `login_required`. A session is opened with the password:
  **terminal** (`tty`: terminal, session, start time of the leader — like `sudo` `timestamp_type=tty`; the same for
  `unlock`/`init`/a command with a password from a terminal) or **parent** (without a terminal: PID and start time of the
  parent — like `sudo` `ppid`; not for PID 1 and not for `systemd`) — 15 minutes after the last command, `logout` (like
  `sudo -k`); **connection** of the window/TUI (`login {hold}`) — while the connection is open, the `xos_…` token is
  accepted only from the same process. The tree of a bound agent stays an agent before any session check (D-28). The CLI
  in a terminal without a session asks for the password itself and repeats the command.
- **Why.** "Like sudo" is the maintainer's explicit requirement, and it is the pattern people understand best. The key is
  the terminal, not a file with a token: an agent would read a file of the same uid. Claude Code runs commands in a new
  session without a terminal (D-28), so a terminal session does not extend to them. An implicit session exists only for a
  terminal: for scripts and the window it must be explicit.
- **Limits** — CONTROL §11 item 10 (an agent in the same terminal without `setsid`, children of the same parent, the
  window token in memory, without `/proc` — only `held`).

### D-47 · Receipts in the shared hash-DAG (maintainer decision Q-16; replaces D-31)
- **Decision.** A `receipt` type in the link format (PROTOCOL §12, §18): `actor`, `action`, `decision`, `refs` (message
  IDs) — no text, no policy reasons, no trust level and no labels of other links. It is written when an agent reads the
  contact's messages, for an approval request caused by the contact's data, for the owner's decision on it, for a policy
  refusal/approval (`check:*`, files), and for an agent's sending after approval. A receipt is an ordinary signed message:
  in the DAG, delivered to the contact, verified. The local audit log remains for what the contact is not supposed to know
  (level changes, limits, reasons). `x log` shows both parts (`source: dag` / `local`). Agents do not get receipts as
  messages (neither in `inbox` nor as subscription facts), and they do not count as unread.
- **Why.** SPEC §9: "it is written into the link's history as a receipt and goes into the shared hash-DAG". Per SPEC §7
  the trust level is stored only locally, and labels of other links would reveal to the contact the existence of other
  contacts (SPEC §5) — so a receipt carries only the fact of the action. An agent's sending without approval is not
  duplicated with a receipt: the message itself in the DAG is the trace (otherwise every agent reply would double the
  traffic and hit the recipient's level limit).

### D-48 · F-6: "yes" on the `x invite` following connection only with the code the owner entered
- **Decision.** `Input::Confirm{yes:true}` without `code` — refused (`bad_request`); with a code that is not this invite's
  — `sas_mismatch`; in both cases an `input_rejected` event, and the invite stays alive. The check is both on the
  following connection and in `invites::decide` (for all paths). In follow mode the CLI asks the owner for the code (digits
  or animals) instead of filling in the displayed one; on `input_rejected` it asks again. Tests: without a code, with
  someone else's code, with the correct code as animals.
- **Why.** Formal model (F-4, scenario `neg_nocode`, observation F-6): with two `x invite` open, a "yes" in the wrong
  terminal with the code filled in would confirm someone else's session. The window already does this (D-UI-4).

### D-49 · `x agent add --local-level` is mandatory (maintainer decision Q-15)
- **Decision.** There is no default: without `--local-level` the CLI answers with an argument error (2); help text: "5 — an
  agent with access to the owner's projects and memory; lower — a 'front desk' agent (0 — none)". In the protocol the field
  was mandatory before as well.

### D-50 · Portability M-1/M-2: process memory protection per OS
- **Decision.** `PR_SET_DUMPABLE=0` only under `#[cfg(target_os = "linux")]`; on macOS and other unixes, `RLIMIT_CORE=0`
  (rustix, no `unsafe`): core dumps are forbidden, and protection against a debugger (`PT_DENY_ATTACH` + hardened runtime)
  is PORTABILITY M-7, after slices 3–4. `cargo check --target aarch64-apple-darwin -p x-cli -p xd` gets as far as the C
  dependencies (aws-lc-sys, ring, blake3, openssl-sys — no SDK); `x-proto` and `x-cli` check without errors.

### D-51 · API for the window in x-control/2 (DESIGN "needed from the daemon")
- **Decision.** `mark_read {contact, up_to_seq}` and `unread` in contacts (owner; one read mark shared with `inbox`),
  `history_status` and the `history` event, `verify` (for an agent too, without owner decisions), `revoke` (password: the
  link keys are wiped — the link-root and endpoint seed, the libsignal session and identity, the queue; `secure_delete` +
  a WAL checkpoint; the label is freed; the history stays or is deleted per `delete_history`), `rename` (owner session
  only: the label is a local name and does not change trust), `rights` in the owner's contacts, `input_rejected`. Not
  done: `peer_kind`/`via_agent` (v0.2), files (slice 4), the reply stream (v0.2), `contact_facts`, several requests on one
  connection (x-control/3) — CONTROL §13.

### D-52 · Fixes from the independent security review of slice 3 (2026-10-02)
Review of code `35aaa9b` against SPEC §7–§9, §13, PROTOCOL and CONTROL (an independent reviewer, read-only; experiments —
running the acceptance tests on a copy and checking how Claude Code runs commands). 1 critical finding, 6 important,
4 medium, 7 minor. Fixed (`0fc35d2`):
- **Critical (no. 1): an overflow in the reply to `chain` from the contact's numbers → a panic under the shared DB mutex →
  a "poisoned" mutex and failure of all links until restart.** Arithmetic is checked, the step is 1 or a multiple of 1024
  (the reply from memory); all `std::sync::Mutex`es of the core are taken without poisoning (`PoisonError::into_inner`): a
  panic in the handler of one request no longer brings down the rest.
- **No. 2: the contact's words changed the saved state and the "whose copy was changed" verdict.** Now only evidence
  verified locally blocks: our own copy with a wrong signature, or the contact's copy requested with `want` and checked
  when the resent messages are received. While there are only the contact's words — "the contact reports a difference" without a
  block; "point not found" is not recorded. The contact's claim of a rollback still blocks sending (the safe side) — this is
  a denial of service for this link only; "recovery" after a rekey takes no more than 2 minutes.
- **No. 3: resource consumption by the contact's requests.** Service requests — at most 120 per minute per link; `want`
  ≤ 1024 IDs and one resend at a time.
- **No. 4: `resend` accepted new messages from the contact past the level limit.** Only those declared in its summary,
  with a budget of 1000 per unlock (100,000 after a rekey); in "read-only" only the requested ones.
- **No. 5: fields of the contact's receipts went into the agent's context without taint.** Closed vocabularies for
  `action`/`decision`, `actor` is `[A-Za-z0-9._-]`; the contact's receipts are not given to an agent (`history`, `log`).
- **No. 6 (SPEC §4): "read" went to level 1–2 contacts.** Read receipts only to levels 3+ (Q-22: to be confirmed).
- **No. 7: the rekey confirmation did not name the offer (like F-4 in pairing).** A rekey code from `link_id` and the
  bundle hash: the initiating side shows it to its owner, who reads it out by voice, and the receiving owner enters it
  (`x rekey --code`). Consent given in advance was removed.
- **No. 8: the check for missing parents across the whole DB** — an oracle for linking identities (SPEC §5). Now within the
  link.
- **No. 9, no. 10: approval receipts went to the recipient and revealed another link's data; a flood of `check:*`
  receipts.** Into the shared history — only `check:*` and files, to the source contact; send approvals — locally;
  identical receipts without references — at most once a minute.
- **No. 11, no. 12:** the rollback block is also removed at the receiving side of a rekey; deadlines for waiting for
  confirmation; the offer is not lost on a wrong first message; the offer time without overflow.
- **No. 13–no. 15:** an accepted divergence is not shown as "verified"; the subscription re-checks any owner session
  without extending it; a connection session on Linux only with a readable process chain.
- **No. 17** (the queue went out on a failed verification) was fixed even before the review (`1049366`).
- **Not fixed (limits, recorded):** no. 16 — an agent of the same uid can type commands into the owner's pane within a
  terminal session (`tmux send-keys`; CONTROL §11 item 10, the "agent with a shell of the same uid" class); no. 18 — the
  copy check does not check signatures (a swap of one signature shows up in the divergence search or in resending; batch
  Ed25519 verification is v0.2).

### D-53 · Re-check of the fixes by the same reviewer (2026-10-02)
Closed: no. 1, no. 3–no. 6, no. 8–no. 15; no. 2 and no. 7 partially, plus 7 new findings in the fixes themselves (N1
important, N2–N3 medium). Fixed:
- **N1 (important):** a rekey without a code is offered **only** by the side with the rollback. Otherwise: side A sees "a
  rollback at the contact", its owner presses "rekey", the offer goes to whoever connected with the keys from B's stolen
  DB copy, and they accept it without a code — the §17 attack was back. Now the side without the rollback only enters the
  code (test: `bad_request`).
- **N2:** evidence is accepted only at the `(author, n)` point where it was requested; the contact's copy with a wrong
  signature while ours is intact does **not** block our side (before, when our copy was missing, the verdict was "both
  changed").
- **N3:** an unproven and an accepted divergence are cleared when the summaries match again: "History verified" is
  reachable again.
- **N4:** at most 16 pieces of evidence, they live 10 minutes and are used only for the divergence decision (they do not
  bypass the budget).
- **N5:** a second, different rekey offer within the window burns both (one cannot craft a bundle for an overheard code
  and swap the real one). A commitment with the receiver's random number is a possible hardening (v0.2).
- **N6:** the "recovery" window is extended while resending is running. Not fixed: a restart in the middle of recovery
  resets the rekey flag — a repeated rekey will be needed (the safe side, a limit).
- **N7:** `want` is retried if the contact has another resend running.
- Remaining (limits): one `want` can cost up to 1024 × 64 KiB of re-encryption (a budget in bytes is v0.2); `check:*`
  receipts show levels 1–2 the agent's activity at most once a minute (Q-22).

### D-54 · Rekey: a second code (the side with the rollback also confirms the answer) and burned codes (2026-10-02)
Final re-check: N2, N4, N6, N7 closed; N1 and N5 partially (a bypass for each), N3 is minor.
- **N1 (important), remainder:** the `contact_numbers` rollback flag is set by **the contact's words**. The holder T of a
  stolen copy of B's DB tells A that it has more of A's messages; A blocks itself, A's owner offers a rekey, T answers
  with `rekey_init` — and before, A created a session with T without any code. **Decision: two codes, each owner enters
  the other's code.** The answer to an offer (`rekey_init`) is only checked by the side with the rollback with a trial
  decryption (the transaction is rolled back) and remembered, answering `pending`; the accepting side shows a **second
  code** `HKDF(link_id ‖ H(bundle) ‖ H(init))` (6 digits, PROTOCOL §17), and its owner reads it back; the session is
  created and the block removed only after the second code is entered, and the confirmation (`rekey_ack`) goes as a
  separate request (retried until the window ends; a repeat of the same `rekey_init` gets the same `rekey_ack`).
  Why not "forbid offering under `contact_numbers`": that is how a rollback of the whole directory and a VM snapshot is
  caught (the counter file rolled back together with the DB) — without a rekey that side would not recover. The second
  code covers both cases and is symmetric with pairing: each owner confirms exactly what the real peer sent. The cost is
  one more read-out by voice. Test: after the first code is entered, the side with the rollback is still
  `rekey_required`; someone else's second code — `sas_mismatch`.
- **N5 (medium), remainder:** after burning, the next offer was stored as the first — T, having overheard code c1, burned
  the real offer with any offer of its own, then sent a bundle crafted for c1. The same bypass works without burning, just
  by waiting for the real offer to expire, if the owner enters the overheard code later than 10 minutes (found while
  analyzing the re-check). **Decision:** the accepting side remembers the codes of **all** received offers (a day, up to
  1024, in the daemon's memory); an offer with an already seen code but a different bundle is a conflict. After a conflict,
  the contact's offers and answers are not accepted for 10 minutes (and our own is not created). The window at the
  accepting side is 10 minutes from the **first** reception (a repeat of the same offer does not extend it). The
  `conflicting_offers` event is now shown in the CLI as human-readable text. Test: restart of B → a new offer → both burned;
  the third — refused by the window; the overheard code at A — `not_found` "expired or burned".
- **False alarm on an honest retry** (last re-check: N1, N3, N5 closed, this remained): (a) repeating our own `x rekey`
  within the window sends **the same** offer for all 10 minutes (before — the first 5, then a new one burned both); in the
  last 30 s — "retry in N s", then a new one; (b) the accepted offer (hash and answer) is stored in the accepting side's DB
  (`links.rekey_pending`): after its restart, repeating the first code sends the same answer — the second code is the same,
  no conflict (test: restart of A in the middle of a rekey). The second code is checked inside `confirm_rekey_init`
  against the same answer from which the session is created (defense in depth).
- **N3 (minor):** when an accepted or unproven divergence is cleared by matching summaries, the IDs of both versions
  (evidence of the fork) are written to the local audit log (`x log`: `history_conflict_cleared`).
- Limits: at the side with the rollback, the offer and the answer are in the daemon's memory (its restart in the middle of
  a rekey means starting over); the remembered offer codes are also in memory: after a restart of the accepting side they
  are forgotten (the N5 bypass then also requires a restart of the victim between the overheard code and its entry;
  storing them in the DB is v0.2). An attacker with the contact's keys can burn rekeys forever (a denial of service for
  this link, which they can do anyway).

### Questions for the maintainer (slice 3, not decided)

| # | Question | What is done now | Options |
| --- | --- | --- | --- |
| Q-20 | A rekey after a rollback at a level 4–5 contact and in general: both owners confirm with a code (D-45, D-52) — while SPEC §5 says for **rotation** "levels 1–3 — with a notification, 4–5 — with confirmation" | Always both, the receiver enters the code (safer: a stolen DB copy = all the link's long-term keys) | a) keep "always both"; b) like rotation: 1–3 — automatic with a notification, 4–5 — confirmation |
| Q-21 | History fingerprint: 3 symbols from 10 animals (1000 variants) or a larger alphabet (for example, the 64 emoji of SAS Matrix, 262,144 variants; the window needs a font with 64 glyphs) | 10 animals — the same as the SAS (D-43) | a) keep; b) 64 emoji; c) 4 animals (10,000) |
| Q-22 | SPEC §9 "every action at a contact's request — a receipt in the shared DAG" versus SPEC §4 "read receipts — only to level 3+" | Read receipts only to levels 3+; other receipts (tool checks, files) to all levels (review no. 6) | a) as is; b) for levels 1–2 no receipts in the DAG at all (local log only); c) for 1–2 — as a batch with the next outgoing message |

---

## Core portability to macOS (2026-10-02)

Decided during the portability work; team decisions on PORTABILITY §6: item 1 — `unsafe` only in a separate crate
`x-sys`, item 2 — the anchor rule for GUI hosts: propose and implement the conservative option. Prefix D-P.
The audit and the status of changes M-1…M-18 are in `docs/PORTABILITY.md`. **Nothing was run on a real Mac**: types and
clippy for both darwin targets were checked from Linux (D-P-7); the build, the tests and the XNU facts are proven by CI
(`release-macos.yml`, job `core`). The assumptions about the XNU kernel that the logic rests on are backed by tests in CI,
not by words.

### D-P-1 · `unsafe` only in the `x-sys` crate
- **Decision.** A new crate `crates/x-sys` (AGPL-3.0-only) is the only one in the workspace with `unsafe`: its own
  `[lints]` (`unsafe_code = "deny"` instead of the root's `forbid`, `unsafe_op_in_unsafe_fn = "deny"`, clippy
  `undocumented_unsafe_blocks = "deny"`), `#[allow(unsafe_code)]` only on FFI wrappers, every block has a `// SAFETY:`.
  It exposes safe functions
  `x_sys::darwin::{short_info, uniq_info, bsd_info, exe_path, peer_audit_token, deny_debugger_attach}`. On Linux the crate
  is empty; `libc` only under `cfg(target_os = "macos")` (it was already in Cargo.lock transitively, MIT OR Apache-2.0).
  Struct sizes are checked at compile time (`const assert`) and against the kernel's answer (a wrong size is an error, not
  silently wrong fields). 8 tests run on macOS (CI): our own process against std, `launchd` as a regular user, a child and
  `p_puniqueid`, the audit token of our own socket pair and of another process (`nc -U`), the session leader and terminal
  flags (`script` gives a pty), `PT_DENY_ATTACH`.
- **Why not ready-made crates** (PORTABILITY §2.2): `libproc` uses `bindgen` in build.rs and `PROC_PIDTBSDINFO` (`EPERM` on
  root ancestors); `nix` has no `proc_pidinfo` and no `LOCAL_PEERTOKEN`; `sysinfo` is heavy and has the same uid check;
  `ps` as a subprocess means a fork+exec for every ancestor on every connection.
- **Review.** ≈ 260 lines without tests: 5 `unsafe` blocks and 3 `unsafe impl` of one sealed trait. It needs an
  independent security review (like D-38/D-41) — after the first CI run on a Mac, together with the facts from it.

### D-P-2 · macOS: the process chain for D-28 — `proc_pidinfo`, `p_uniqueid`, audit token (M-3, M-4, M-9, M-10)
- **Decision.** `procinfo::stat` on macOS: `PROC_PIDUNIQIDENTIFIERINFO` → `PROC_PIDT_SHORTBSDINFO` (+ `e_tdev` from
  `PROC_PIDTBSDINFO` for our own uid) → `UNIQIDENTIFIERINFO` again; if `p_uniqueid` differs, the process changed in the
  middle of reading → `None`. The anchor's "start time" = `p_uniqueid`. The session is `getsid` (error → 0, "unknown" →
  not an anchor). `ancestry`: for a link whose parent is > 1, `p_puniqueid` equals the `p_uniqueid` of the parent that was
  read, otherwise `None`; a link with `PROC_FLAG_TRACED` → `None` (XNU re-parents a traced process to the debugger).
  `is_alive` does **not** take tracing into account: otherwise an agent attaching a debugger to its host would "end" the
  binding — a fail-open. The socket client: PID and `pidversion` from the audit token (`LOCAL_PEERTOKEN`), checked against
  `p_idversion`: the PID reuse window between `connect` and reading (the D-41 remainder on Linux) is closed on macOS. The
  token could not be read — no chain — refused when there are bound agents (D-38).
- **Owner sessions (D-46)** on macOS: `tty` = `e_tdev`, the session leader by `p_uniqueid` (in Terminal.app the leader is
  the root process `login`, and it can be read); `held` — only from the holding process, as on Linux
  (`procinfo::SUPPORTED`).
- **Why.** `PROC_PIDTBSDINFO` for another uid gives `EPERM`: the chain would break at `login`/`launchd`, and with
  "fail-closed" everyone would be refused. `p_uniqueid` is stricter than the start time (it does not repeat until reboot)
  and allows checking the link to the parent, which Linux does not have. Claude Code hooks on macOS now work without a
  token too — by the host's tree (D-UI-12 with the token in the hook command remains acceptable).
- **To check on a Mac** (CI tests, `FACT` output): `SHORTBSDINFO`/`UNIQIDENTIFIERINFO`/the path are readable for
  `launchd`; a child's `p_puniqueid`; the token names the connecting process; the `PROC_FLAG_*` constants; `getsid(1)`;
  whether XNU updates `p_puniqueid` when re-parenting to launchd (orphans are not checked — safe either way).

### D-P-3 · The agent anchor on macOS: a session leader only if it is a GUI host (team decision, PORTABILITY §6 item 2, M-5)
*Amended 2026-10-05 (D-97): a GUI host is also what makes two MCP hosts "one app" on macOS.*
- **Decision (conservative option).** Linux — unchanged. macOS: an anchor (the parent of `x mcp`) is never PID 1,
  `launchd`, `systemd`, an ancestor of the daemon, or a process with an unknown session; a **session leader** only if it is
  a GUI host, all five conditions: (1) the executable is the app's main file `…/<name>.app/Contents/MacOS/<file>`
  (`proc_pidpath`); (2) the parent is launchd (PID 1); (3) no controlling terminal — neither
  `PROC_FLAG_CONTROLT`/`PROC_FLAG_CTTY` nor `e_tdev`; (4) the same uid as the daemon; (5) the same process (`p_uniqueid`)
  before and after the reads. If anything could not be read, it does not qualify.
- **Why.** Apps launched by launchd (Claude Desktop, Cursor, VS Code) are leaders of their sessions (to check on a Mac,
  PORTABILITY §5 step 2); if `x mcp` is launched by the app's main process, rule D-38 no. 7 would always refuse. Rule
  no. 7 protects against binding to a terminal shell, `tmux`, `login`, `sshd` — they have a terminal, or they are not a
  `.app`, or their parent is not launchd: they are still not anchors. What else passes: the main process of any of the
  owner's `.app`s, if it launches `x mcp` itself (Terminal.app does not do that — it launches `login`). The cost of a
  mistake is that the tree of that app becomes an "agent": its processes lose the owner role (a refusal, not an
  escalation); to undo — `x agent remove` from the window or another terminal.
- **Checks.** Tests `child_is_an_anchor_session_leader_is_not` (a session leader without `.app` is not an anchor),
  `app_main_executable_paths`; on a real app — `gui_host_accepts_a_launched_app` (Calculator via `open`, CI,
  informational). The experiment with Claude Desktop (PORTABILITY §5 step 2) is the first thing to run on the maintainer's
  Mac.

### D-P-4 · SPEC §13 on macOS: `RLIMIT_CORE=0` + `PT_DENY_ATTACH` (release) + hardened runtime (M-7)
- **Decision.** `xd` and `x`: `RLIMIT_CORE=0` (D-50) and, in a release build, `ptrace(PT_DENY_ATTACH)`; not in debug (the
  developer needs a debugger, and a process with `PT_DENY_ATTACH` under a debugger exits). Reading memory via
  `task_for_pid` is closed by signing with `codesign --options runtime` without `get-task-allow` —
  `packaging/macos/build-dmg.sh` signs `xd` and `x` that way.
- **Why.** `PT_DENY_ATTACH` alone is not a barrier (it is bypassed via `task_for_pid` on a process without hardened
  runtime), but it is cheap and closes "attach lldb to a running xd". The barrier is the hardened runtime. Check — CI
  `core`, step "PT_DENY_ATTACH in release" (informational: the runner may not have debugging rights at all), and manually
  `lldb -p $(pgrep xd)` (PORTABILITY §5).

### D-P-5 · Data on macOS: the `~/.local/share/x` directory, excluded from Time Machine, `F_FULLFSYNC`, limits (M-11…M-14, M-16, M-17)
- **The directory (M-16) stays `~/.local/share/x`**, as on Linux (the audit's recommendation, PORTABILITY §6 item 3): the
  same path is looked up by the window (`apps/x_desktop/lib/protocol/src/socket_path.dart`), the LaunchAgent, CONTROL §1,
  the USER-GUIDE and the `ssh -L` instructions; paths without a space (snippets for hosts and `ssh -L` do not break).
  `~/Library/Application Support/x` is an Apple convention, not a requirement; switching would touch 5 places, including
  the window's Dart client — change them all in one change if the team decides otherwise. Pitfall: apps started from the
  Dock do not see variables from `.zshrc` (`XDG_DATA_HOME`, `X_DATA_DIR`) — TROUBLESHOOTING.
- **Time Machine (M-13, SPEC §8 and §15: "the database outside backups", PORTABILITY §6 item 5)** — automatically: at startup `xd`
  calls `tmutil addexclusion <data directory>` in the background (a sticky attribute, no sudo); a failure is a warning in
  the log.
- **`PRAGMA fullfsync = ON; checkpoint_fullfsync = ON`** on Apple (M-11): without them a commit may be lost on power
  loss → a ratchet rollback. The cost is commit latency; measure on a Mac.
- **`RLIMIT_NOFILE` (M-12):** the macOS soft limit of 256 = `MAX_CONNECTIONS`; `xd` raises it to `min(hard, 10240)`.
- **`sun_path` (M-14):** a socket path longer than 107 bytes (Linux) / 103 (macOS) — a clear error before `bind` and a
  hint in the client.
- **`PROTECTED_PATHS` (M-17):** + `Library/Application Support/{Claude, Code/User, Cursor/User}/`, `Library/LaunchAgents/`,
  `.zprofile`, `.zshenv`, `.zlogin`.

### D-P-6 · File checking (`x-files`) on macOS: fail-closed for now, the plan is Seatbelt (M-15)
> **2026-10-03: done — D-P-12** (Seatbelt via `sandbox_init` in the worker itself, not `sandbox-exec`; memory is guarded by
> a daemon watchdog). Below is the original plan.

- **Now.** On macOS the worker cannot confirm isolation (Landlock and seccomp are Linux only): `is_isolated() = false` →
  verdict `failed` (`sandbox_unavailable`) → the file is not checked, there is no preview, **an agent does not accept it**
  (D-F-4: `failed` is accepted only by the owner with `--force` and the password). The message to the owner says this
  plainly: "this OS has no sandbox for checking files, the file was NOT checked; an agent cannot accept it; the owner only
  with --force and the password".
- **Plan (a separate task after stage B, D-F-14).** Option A (recommended): the worker is launched via
  `/usr/bin/sandbox-exec -p '<SBPL>'` — the profile `(version 1) (deny default)` + `(allow process-exec (literal <worker>))`
  + reading only system libraries and the worker itself, no network and no writes; rlimits (`CPU`, `FSIZE=0`, `NOFILE`,
  `CORE=0`) — rustix; the memory limit — a watchdog in the parent via `proc_pid_rusage` (`ri_phys_footprint`): `RLIMIT_AS`
  does not work on macOS (to check). `sandbox-exec` is marked deprecated, but it exists in macOS 15 (Bazel and Nix use it);
  no `unsafe`. Option B — `sandbox_init_with_parameters` (FFI in `x-sys`, the same SBPL) — once the worker becomes an `xd`
  subcommand. Option C — a separate user without permissions — needs root and does not fit a per-user install.
  `WorkerReady` gets a `seatbelt` field, `is_isolated()` on macOS — `seatbelt && rlimits && extra_fds == 0`; checked with
  the same `selftest` probes.

### D-P-7 · Checking for macOS without a Mac: replacing the build scripts of C dependencies
- **Decision.** `tools/check-darwin.sh` — `cargo clippy --all-targets -D warnings` for x-sys, x-proto, x-core, xd, x-cli for
  `aarch64-apple-darwin` and `x86_64-apple-darwin` (and `--release`) from Linux: the build scripts of `aws-lc-sys`, `ring`,
  `openssl-sys`, `libsqlite3-sys` are overridden with Cargo's standard `[target.<target>.<links>]` mechanism
  (`tools/darwin-check.toml`), `blake3` — `--features blake3/pure`, ready SQLCipher bindings are put into OUT_DIR. There is
  no linking during check — the types and clippy are honest; it cannot be built or run this way.
- **Why.** Otherwise all of the macOS code in x-core and xd would be compiled for the first time in CI. The check
  immediately found a lifetime error that the Linux build does not see (TROUBLESHOOTING). The build of the C parts,
  linking, tests and XNU facts are proven by CI.
- **After merging with stage B (x-files in the workspace):** the script checks `x-files` too; the C helper of `wasmtime`
  (`helpers.c`, YARA-X) is compiled by clang in freestanding mode with a stub `stdlib.h` (`CC_<target>`,
  `CFLAGS_<target>`) — the object is only needed by the build script.

### D-P-8 · Inherited descriptors: `xd` marks them CLOEXEC at startup (merge with stage B, D-F-24)
- **Decision.** `x_sys::fds::cloexec_inherited_fds()` — all descriptors > 2 get `FD_CLOEXEC`: Linux —
  `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)` (kernel ≥ 5.11, via `syscall`: the libc wrapper exists only in glibc ≥ 2.34),
  fallback (old kernel, container seccomp, macOS) — walking `/proc/self/fd` or `/dev/fd` and `fcntl(F_SETFD)`. The call is
  in `xd` right after parsing the worker mode (`--x-files-worker`), before clap, tokio and logging. Descriptors are not
  closed (it may be someone else's socket) — only not passed to children. If it fails — a warning in the log, and the file
  check honestly refuses, as before (D-F-24: `failed`, "inherited N open file descriptor(s)").
- **Why.** The Flutter window (`flutter_tester` — fd 9) and scripts leave fds without CLOEXEC; the check worker inherited
  them and did not work without isolation — files were not checked. The workaround in the window
  (`withoutInheritedFds`) stays as a second line.
- **Checks.** `x-sys`: `inherited_descriptor_is_not_passed_on` (the main path; on Linux exactly `close_range`) and
  `listed_fallback_is_not_passed_on` (the fallback); `x-cli/tests/files.rs::inherited_descriptor_does_not_reach_the_worker`
  — `xd` with an open fd 9 checks a file: verdict `clean` (before, `failed`).

### D-P-9 · An agent's binding to a process does not survive an OS reboot (macOS branch review)
- **Decision.** Together with the anchor (PID, start time/`p_uniqueid`, name), `agents.anchor_boot` stores the OS boot
  number: Linux — `/proc/sys/kernel/random/boot_id`, macOS — `sysctl kern.bootsessionuuid`
  (`x_sys::darwin::boot_session_uuid`). An anchor from another boot (or an old record without the number) read from the
  DB means "no binding"; the next `x mcp` call binds again. If the number cannot be read, `NULL` is stored and compared,
  i.e. as before.
- **Why.** After a reboot numbering starts over: on Linux the start time is ticks since boot, on macOS `p_uniqueid` is a
  counter from zero; with a similar boot order another process could match the anchor by the "PID + start" pair: its tree
  would become the "agent", and the token would be accepted only from it. Check:
  `store::agent_anchor_does_not_survive_a_reboot`.

### D-P-10 · Nested anchors: a process belongs to the agent nearest to it (macOS branch review)
*Amended 2026-10-05 (D-97): an agent can have several MCP hosts of one app; "nearest" is the nearest of all of them.*
- **Decision.** If the client's chain has several live anchors (Claude Code in the built-in terminal of a GUI app that has
  also connected `x mcp` — D-P-3 makes this real on macOS), the process is the agent of the anchor **nearest** to it
  (`procinfo::chain_position`): both for the "claimed to be the owner" role (`agent_for_process`) and for login with a
  token — our own token is accepted if our anchor is nearer than the others; if a foreign one is nearer (or there is no
  own one) — `token_bound`, as before (no. 9, with no "laundering" of taint: a new agent is not bound inside another
  agent's tree).
- **Why.** Before, the first agent in DB order was chosen: if the outer one had been added earlier, the actions and taint
  of the agent in the built-in terminal went to the outer one, and its own token was rejected there. Check:
  `x-cli/tests/agents.rs::nested_anchors_belong_to_the_nearest_agent`; negative control — with the old `agents.rs` the test
  fails (`B_OWN=77 … belongs to agent "ide"`, `FORCED_B` → "ide").

### D-P-11 · Window: "MCP on macOS" is on (`mcpWorksOnMacos = true`)
- The window's only switch (DESIGN "MCP switch on macOS") was flipped with the merge of the core port: on macOS the tabs
  and Claude Code hooks work as on Linux (hooks without a token: the daemon sees the host's tree). USER-GUIDE updated: on
  the Mac only the sandboxed file check does not work (D-P-6).

### macOS sandbox — Seatbelt (2026-10-03)

Built on a separate branch for the security work; closes the plan of D-P-6 and D-72. Prefix D-P (after D-P-11).
**Nothing was run on a real Mac**: types and clippy — `tools/check-darwin.sh` (both targets, debug and release); the
profile text — unit tests on Linux; that the profiles are compiled by the kernel and hold what they promise is proven by
CI (`release.yml`, job `core`, the "Sandbox …" steps, the `FACT` lines). Code: `crates/antenna-sys/src/seatbelt.rs` (FFI),
`crates/antenna-files/src/{seatbelt,sandbox_macos}.rs`, `crates/antenna-core/src/sandbox/{seatbelt,macos,common}.rs`.

### D-P-12 · File checking on macOS: the worker isolates itself with Seatbelt (`sandbox_init`), memory is guarded by a daemon watchdog
> **2026-10-03, macOS 26 on a real Mac:** `RLIMIT_DATA` is best effort (macOS 26 refuses it with `EINVAL`, and a refusal
> turned off the whole isolation, fa70b38); the av-exec profile carries what dyld needs to start the antivirus (D-P-15);
> the worker's environment probe counts only variables passed in (D-P-16).

- **Decision.** As on Linux (D-F-6): the worker (`antennad --antenna-files-worker check`) reads the request, compiles YARA
  and **before the first byte of the file** isolates itself: `sandbox_init` with the profile
  `antenna_files::seatbelt::worker_profile`: `(deny default)`; reading — only system libraries (`/usr/lib`,
  `/System/Library`, the dyld cache) and its own binary; writes, network (including `bind` and unix sockets),
  `fork`/`exec`, signals (except to itself), Mach, POSIX IPC, sysctl (except CPU and OS information) — forbidden; then
  rlimits (core 0, file writes 0, ≤ 32 fds, CPU, data — after the profile: libsandbox compiles it in this same process,
  and the sandbox does not restrict `setrlimit`). Then a probe from inside: listing `/` gives `EPERM`, otherwise "not
  isolated". `WorkerReady.seatbelt`; `is_isolated()` on macOS — `seatbelt && rlimits && extra_fds == 0`. Without the
  confirmation the daemon does not hand over the content — `failed` (`sandbox_unavailable`); an agent will not accept such
  a file, the owner only with `--force` and the password (as before).
- **Memory.** `RLIMIT_DATA`/`RLIMIT_AS` do not limit `mmap` memory on macOS. A watchdog in the daemon (`MemoryWatchdog`,
  `antenna-files/src/sandbox.rs`): every 50 ms, `proc_pid_rusage(RUSAGE_INFO_V2).ri_phys_footprint` of the worker (and of
  the antivirus); above the limit — SIGKILL (whether it is the same process — by `p_uniqueid`); if the footprint cannot be
  read already at launch — no check (fail-closed). Report: `seatbelt=true rlimits=true extra_fds=0 memory=watchdog`;
  exceeding the limit — `worker_crashed` "stopped by the memory watchdog".
- **`av-exec` (external antivirus)** on macOS is Seatbelt too (`seatbelt::av_exec_profile`): reading and executing —
  system paths and `--ro`, writing — only the check directory, no network, signals — to its own sandbox, Mach — only user
  and group information. `AvHook::clamscan` on macOS names the Homebrew config and databases (their `etc/`/`var/` are not
  in the general system read set).
- **Why `sandbox_init` and not `sandbox-exec -p` (option A of the D-P-6 plan).** The engine is the same. Self-isolation
  from inside our own process is the same model as Landlock: the profile does not need to allow launching, loading
  libraries and compiling YARA (all of that happens before isolation), and the worker confirms the isolation itself with a
  probe. `sandbox_init` is a public function of `<sandbox.h>` (marked deprecated since 10.8, works in macOS 15; Chromium,
  Servo's `gaol` and `birdcage` rely on it); FFI only in `antenna-sys` (D-P-1), with `// SAFETY:`. A fallback via
  `sandbox-exec` is not needed: if `sandbox_init` does not work, neither does it.
- **Differences from Linux (honest).** Seatbelt does not forbid threads (it has no system call filter like seccomp) — the
  `thread` probe is not in `PROBES` on macOS; a thread lives under the same profile. Something forbidden is refused with
  `EPERM` rather than the process being killed (`SIGSYS`). Memory is a watchdog with a 50 ms step, not a kernel limit:
  within one step the process can go over the limit.
- **Checks.** Linux: unit tests of the profiles (`antenna-files` `seatbelt::tests`), all `antenna-files` tests and
  `tests/files.rs` — no behavior change; new `worker_cannot_read_secrets_write_outside_or_connect` and
  `a_worker_over_the_memory_limit_is_stopped` (Linux — `RLIMIT_DATA`, SIGABRT). macOS — CI: the same test files (the
  `cfg(target_os = "linux")` was removed), expectations per OS (`EPERM` instead of `SIGSYS`), lines `FACT file worker`,
  `FACT memory limit`, `FACT worker isolation`; `antenna-sys` `seatbelt::tests` (a profile in a child, a malformed profile
  and applying twice — an error).

### D-P-13 · Agent wake on macOS: Seatbelt following the D-71 model, orphans found by the sandbox itself (closes D-72)
> **2026-10-03, macOS 26 on a real Mac:** the profile also carries what dyld needs to start the agent (D-P-15), which
> makes the root directory's own listing readable, so the stage 2 probe lists `/Library` instead of `/`.

- **Scheme.** daemon → `antennad --antenna-wake-exec` (the supervisor outside the sandbox: a bridge
  `127.0.0.1:<free port>` ⇄ the unix socket of the daemon's CONNECT proxy, the lifeline = stdin, the start gate `go`) →
  stage 2: `setsid` (its own session without a terminal), rlimits, `sandbox_init` with the profile
  `antenna_core::sandbox::seatbelt::agent_profile`, a probe from inside (`/` — `EPERM`) → `exec` of the agent.
  `SandboxKind::Seatbelt`, `wake list` → `sandbox: "seatbelt"`.
- **Profile (`(deny default)`).** Reading — system paths (`/usr` without `/usr/local/{var,etc}`, `/bin`, `/sbin`,
  `/System`, `/Library/{Apple,Frameworks,Developer/CommandLineTools}`, Xcode, Homebrew and MacPorts without `var/` and
  `etc/` — service databases and configs live there; from `etc/` only the root certificates; a selected `/private/etc`,
  like `ETC_ALLOW` on Linux), the spec's `ro` paths (the program's and `antenna`'s directories, the link folder), the
  `ro_binds` sources, its own run directories; metadata (`stat`, `readlink`) everywhere, as in Landlock mode. Writing —
  only `cwd`/`home`/`tmp`/`rw`, without nested read-only paths (`require-not`: "CLAUDE.md" in `shared/` and so on); the
  agent's memory, configs and the owner's keystore are outside these paths. Network — only `localhost:<bridge port>` and
  the spec's unix sockets (the daemon socket); `bind`/`inbound` — no; DNS — no (`mDNSResponder` is closed, the proxy
  resolves names). `fork`/`exec` — yes (descendants inherit the profile); signals and process information — only within
  its own sandbox. Mach — `opendirectoryd` (users, groups), `notify`, `trustd` (TLS) and the run label; the keychain
  (`SecurityServer`), `cfprefsd`, the clipboard, LaunchServices — no. sysctl — CPU and OS, without
  `kern.proc*`/`kern.procargs*` (the process list and other processes' arguments). `/dev` — `null`, `zero`, randomness,
  own `fd`; `/dev/tty` — no.
- **Orphans and the lifeline.** macOS has no pidns and no subreaper: a double fork and `setsid` take a process to launchd.
  The profile allows a unique Mach name for the run (`io.github.danta-nort.antenna.wake.<128 bits>`) — a label; a second
  random name is forbidden, like everything unnamed. On exit (EOF on the lifeline, the agent finished) the supervisor
  kills the agent's group, its descendants by parent and all processes of the same uid created after the supervisor
  (greater `p_uniqueid`) that are in a sandbox (`sandbox_check(pid, NULL)`) and whose profile allows the label and forbids
  the second name (`sandbox_check(pid, "mach-lookup", GLOBAL_NAME)`) — so other sandboxes (App Store, Codex and so on) are
  not swept up. The daemon does the same (`Running::kill_now`) if the supervisor is already gone. `sandbox_check` is an
  SPI looked up with `dlsym` at runtime: if it is missing, cleanup is only by group and parent, with a warning in the run
  log; CI checks it as a fact.
- **Why not a "killer" inside the sandbox** (`kill(-1)` from the same sandbox would kill exactly its processes): an agent
  in the same sandbox could kill it first (signals within its own sandbox are allowed to it) and leave orphans. A check
  from outside cannot be disrupted by the agent.
- **Why `setsid` in stage 2.** An orphan that has left the tree (parent — launchd) is no longer an agent for the daemon,
  but a process of the same uid without a session (D-46): only `status`, `lock` and commands with a password are available
  to it; the run token from it is `token_bound` (the anchor is alive) and invalid after the run. But in the daemon's
  session and with its terminal (the daemon was started from the owner's terminal) it would match the owner's `tty`
  session. Its own session without a terminal rules that out (like bwrap's `--new-session`).
- **Not closed (compared with bwrap, D-71; CONTROL §11 item 11).** (1) Memory and the number of processes (no cgroups —
  as on Linux). (2) File metadata everywhere: the agent can learn whether a path exists, its size and time (not the content
  and not the directory listing); bwrap hides this. (3) The bridge listens on the host's loopback: another local process
  of the user can use it (to the allowed hosts). (4) An orphan between leaving the tree and the end of the run is not an
  agent for the daemon (see above: it gains no privileges). (5) Seatbelt is a deprecated but supported API (App Sandbox
  and Chromium rely on it; Apple has given nothing else for third-party programs). (6) The agent reads system software and
  its program's directory in full and runs any programs from the allowed set (under the same profile) — as on Linux.
  Stronger than Landlock mode (Linux without bwrap): signals and information about other processes, the user's other unix
  sockets (`SSH_AUTH_SOCK`, service sockets), the process list — closed.
- **Checks.** Linux: unit tests of the profile (`sandbox::seatbelt::tests`: writing — exactly its own directories without
  "CLAUDE.md", network — the bridge and the daemon socket, no keychain, clipboard, DNS, `kern.proc`; quotes are escaped, a
  newline is refused); Linux behavior unchanged (shared code moved to `sandbox/common.rs` without changes). macOS — CI:
  `wake_sandbox.rs` and `wake.rs` in `seatbelt` mode, `FACT agent sandbox=seatbelt claude_md_write=denied
  keystore_read=denied direct_tcp=denied via_proxy=ok`; orphans after `setsid` (via perl: macOS has no `setsid` utility)
  are cleaned up; `kill -9 $PPID` and a signal to an unrelated process — `EPERM`; the lifeline; a socket outside the spec
  is unreachable; `antenna-sys` — `sandbox_check` sees the child's profile.

### D-P-14 · CI on macOS: sandbox tests are blocking, `cfg(target_os = "linux")` removed
- `tests/{sandbox,corpus,pipeline,review}.rs` (antenna-files), `tests/{files,wake,wake_sandbox}.rs` (antenna-cli) —
  `cfg(any(linux, macos))`; expectations that differ are per OS, without weakening Linux (checks were added there: an
  unrelated process is alive after the agent's signal — bwrap; facts for the log). Job `core`: "Core tests" (as before)
  now include files and wake; separate steps "File check sandbox (Seatbelt)" and "Agent wake sandbox (Seatbelt)" print
  `FACT` (`--nocapture`). Not `continue-on-error`: a broken sandbox is a broken feature, and no release is created. First
  run — record the facts in TROUBLESHOOTING "macOS sandbox — Seatbelt".

### macOS 26 on a real Mac (2026-10-03)

The first run of the sandbox suites on a real Mac (macOS 26.5.2, build 25F84, arm64, Xcode 26.4). Facts and how each
problem was found: TROUBLESHOOTING "macOS 26 on a real Mac".

### D-P-15 · Programs started under a Seatbelt profile get what dyld needs: Apple's `dyld-support.sb` and an explicit rule
- **Problem.** On macOS 26 every program started under the av-exec profile (D-P-12) or the agent profile (D-P-13)
  aborted inside dyld before `main` (SIGABRT, termination namespace DYLD, no denial in the sandbox log): libignition,
  dyld's loader of the cryptex-based system volume, opens `/` to use it as the root for `openat(2)`, and the profiles
  allowed `/` only as metadata.
- **Decision.** Every profile under which programs are started carries `antenna_files::seatbelt::exec_support`:
  `(import "dyld-support.sb")` when `/System/Library/Sandbox/Profiles/dyld-support.sb` exists (Apple ships it with the
  OS and keeps it in step with what dyld needs), and always the explicit rule `(allow file-read* (literal "/"))`, so the
  profile does not depend on that file. The worker profile does not get it: the worker isolates itself after dyld has
  run.
- **What the import allows** (macOS 26.5.2): reading, existence checks and executable mapping of the cryptex graft
  points (`/System/Volumes/Preboot/Cryptexes/{OS,App/System,Incoming/OS}`, `/System/Cryptexes/{OS,App}`) and reading
  their ancestors, all under `/System`, which the profiles already read; reading `/` itself; the file-control commands
  `F_ADDFILESIGS_RETURN`, `F_CHECK_LV`, `F_GETPATH`; the system calls dyld and libignition use (`open`, `openat`,
  `fstatat`, `dup`, `getfsstat`, `map_with_linking_np`, `__mac_syscall`) and the sandbox's own check call. No writes,
  connections, signals, Mach services or process information. A later system may add rules to the file; that is the
  point of importing it, and the trust in it is the same as in the OS.
- **What changes for the agent.** The listing of the root directory itself (`literal`, not `subpath`) is readable: the
  names of the top-level directories, nothing below them (metadata was already visible everywhere). So stage 2 no longer
  proves isolation by listing `/`: it lists `/Library` (always there, readable by any user, not in the profile) and
  refuses to start the agent if that works.
- **Checks.** Linux: unit tests of the profile text (`seatbelt::tests::programs_get_what_dyld_needs_and_nothing_wider`,
  the agent profile test: the literal rule, never `(subpath "/")`; the worker profile without it). macOS:
  `antenna-files --test sandbox` runs `/usr/bin/true` under the av-exec profile with the import only, the explicit rule
  only and neither, through `sandbox-exec -p` (`FACT dyld under a profile`: 0, 0, SIGABRT on macOS 26); the existing
  av-exec and `wake_sandbox` tests run the production profiles through `sandbox_init`.

### D-P-16 · The worker's environment: only variables passed in count; CoreFoundation's own is listed apart
- **Decision.** The daemon starts the worker with an empty environment (as before). The `env` self-test probe prints
  variable names (never values) and is closed only if no variable was passed in. A variable the system sets in the
  process itself is listed separately: on macOS exactly `__CF_USER_TEXT_ENCODING`, which CoreFoundation sets at startup
  when it is missing, with the shape `0x<uid>:0x<encoding>:0x<region>` and the process's own uid; any other name, shape
  or uid counts as passed in.
- **Why not clear it.** It is created inside the worker by a system framework after `exec`, not inherited, and it
  holds the worker's own uid and the user's text encoding and region: nothing from the daemon and nothing secret.
  Removing it would take `unsafe` (`remove_var`) for no protection.
- **Checks.** The probe on macOS: `0 environment variables []; set by the system in this process:
  [__CF_USER_TEXT_ENCODING]`; Linux: nothing at all. Negative control `a_variable_passed_to_the_worker_is_reported`: a
  variable passed in is named, its value is not printed.

### D-F-25 · Apple disk images are a known type, and stay suspicious
- **Decision.** A file that ends with a UDIF trailer (the 512-byte `koly` block, version 4, header size 512) and does
  not start as a recognized format (or starts as bzip2, as UDBZ images do) is `application/x-apple-diskimage`
  (`Kind::Dmg`). The verdict does not change: `suspicious`, with `disk_image` (macOS mounts it, it can hold apps and
  installers, the contents are not inspected), `no_safe_preview` and `secrets_not_scanned`, so an agent cannot accept
  it and the owner decides (D-F-9, D-82 item 8). A recognized format that also ends with a `koly` trailer is a polyglot
  (`polyglot_dmg_trailer`, a threat), like a ZIP directory at the end.
- **Why.** `unknown_type` told the owner nothing about a file that is in fact the most common way to ship a Mac app,
  including our own releases; knowing the type does not make it safer, so the verdict stays.
- **Checks.** `detect::tests` (UDZO and UDBZ layouts, a trailer one byte short of the end, a wrong version), the
  corpus test `disk_image_is_recognized_and_stays_suspicious` (a synthetic image everywhere, a real `hdiutil create
  -format UDZO` image on macOS) and a PDF with a `koly` trailer (threat).

---

## v0.1 MVP, slice 4 "files and quarantine", stage A (2026-10-02)

Decided during the slice, within the assigned task. Code — `crates/x-files` (AGPL-3.0-only), tests — `crates/x-files/tests`.
Prefix D-F, so as not to collide with slice 3. Whatever changes SPEC or needs system packages is under "Questions for the
maintainer (slice 4)" below and is **not** considered decided.

### D-F-1 · Stage A is a separate workspace, stage B is the integration
- **Decision.** `crates/x-files` has its own `[workspace]`, its own `Cargo.lock`, and builds into `target/x-files` (under
  the shared `/target`, not in git). The versions of shared dependencies are the same as in the root. The core (`x-core`)
  is needed only by the worker binary, for the secret scanner, and is pulled in **by a git revision of this same
  repository** (`065ed21`) rather than by path: the core's working tree was being changed by slice 3 at that time.
  Integration (`x share/request/files`, MCP, `x-proto` types) is stage B, after slice 3 is committed.
- **Why.** Slice 3 and stage A were developed in parallel in one checkout: in the root workspace our builds would wait for
  slice 3's `target` lock, and a crate broken for a minute would break its `cargo test` (and vice versa). The cost is a
  second build directory (~3 GB) and compiling the dependencies twice.

### D-F-2 · File encryption `xfile/0`: STREAM from `aead-stream` (RustCrypto) over ChaCha20-Poly1305
- **Decision.** `header = "xfile/0\n" ‖ u32be(65536) ‖ salt 32` (in the clear, 44 bytes); `key = HKDF-SHA256(salt, file
  secret, "x/file/v0/stream-key")`; chunk i — `ChaCha20-Poly1305(key, nonce = 0⁷ ‖ u32be(i) ‖ "last" flag, aad =
  header)` via `aead_stream::StreamBE32`; the last chunk is 0…64 KiB (an empty file is one empty last chunk). The BLAKE3 of
  the plaintext is computed during encryption and travels in the manifest. The file secret is 32 random bytes, passed
  inside a Triple Ratchet message (`FileOffer`, stage B), like attachments in Signal.
- **Why.** Only a ready construction (our rule: no custom cryptography): STREAM (Hoang–Reyhanitabar–Rogaway–Vizár
  2015) is implemented in RustCrypto, in the same `aead 0.6` generation that is already in the tree. SPEC §7 says "the
  index and the last flag in the AAD"; in STREAM, age and Tink they are in the **nonce** — they are authenticated the
  same way; the AAD binds the chunks to the header. "A key from the ratchet" literally is impossible: libsignal does not
  hand out message keys (D-8), so the secret is random and protected by the ratchet in transit. A random salt makes the
  key unique even if a secret repeats; as a side effect, the same file in two links is two unrelated blobs
  (deduplication across links is impossible by construction). Checked: reordering, a changed byte, truncation at a chunk
  boundary and inside a chunk, appending, a repeated chunk, a chunk from another file, a wrong key — `file_corrupt`
  (`crypt::tests`).

### D-F-3 · Manifest: an Ed25519 signature with the link and recipient context
- **Decision.** `msg = "x/file-manifest/v0" ‖ 0x00 ‖ link_id ‖ recipient key ‖ body`, `body` is exactly the transmitted
  CBOR bytes (`deny_unknown_fields`, a trailing tail is an error, ≤ 16 KiB). Fields: version, a random `file_id`, name,
  MIME by content, size, BLAKE3 of the plaintext, the blob's hash and size (the blob size must equal
  `ciphertext_len(size)`), the sender's check verdict and finding codes, time. The file secret is next to it, not in the
  signed body. The signing interface is `ManifestSigner`: at stage A a key from the test, at stage B the side's link-root
  Ed25519. A repeat of the same `file_id` in the link is refused.
- **Why.** SPEC §7 "signature with context": the manifest cannot be redirected to another link or another recipient; CBOR
  canonicalization is not needed (like D-19). At stage B the protocol format moves into `x-proto` (Apache-2.0).

### D-F-4 · Levels and acceptance (SPEC §9, §10 items 1 and 5)
- **Decision.** Daily volume in binary units: level 2 — 100 MiB, 3 — 1 GiB, 4 — 10 GiB, 5 — 100 GiB by default
  (configurable); level 1 and below — no files at all (refused already at the manifest, before downloading; acceptance at
  level 1 is impossible even with `--force`). Where to: 2 → `inbox/`, 3–4 → `shared/`, 5 → the project folder. Who accepts:
  level 2 — only the owner; 3+ — an agent, but only a **clean** file; "suspicious" — the owner; "threat" and "not checked"
  — only the owner with `--force` and the password (`OwnerForce` is created by the daemon after checking the password).
  The contact's **current** level applies, not the level at the time of the offer. Dot files and auto-executing names —
  only with a separate approval. A threat gets no preview.
- **Why.** "The agent decides from level 3" (SPEC) — but an agent can be talked into things: wherever the check found
  something, a human decides. Exactly 1 GiB passes at level 3 (the §18 "1 GB" test).

### D-F-5 · Quarantine: ciphertext in the link store + encrypted records; rejection = erasing the key
- **Decision.** The quarantine root is a daemon directory (0700, with `.metadata_never_index`), not `~/X/links`. The content
  is only `xfile/0` ciphertext in the link's iroh-blobs store; the file record (manifest, secret, report, preview) is
  encrypted with the same STREAM under the key `HKDF(quarantine key, link_id ‖ id)` and written atomically. Plaintext
  exists only in memory: "store → decryption → worker" and "store → decryption → temporary file in the destination
  directory → rename" on acceptance. Rejection erases the record with the secret (crypto-shredding) and removes the blob's
  tags (the store's garbage collection removes the data).
- **Why.** "An encrypted storage that the agent and the OS have no path to" (SPEC §10 item 2): an agent of the same uid can
  read the quarantine files but will get only ciphertext; at stage B the quarantine key comes from the keystore root key.

### D-F-6 · The check is a worker process that isolates itself (Landlock + seccomp + rlimits)
- **Decision.** The daemon launches the worker (`x-files-sandbox check`; at stage B, a hidden `xd` subcommand) with an empty
  environment, `cwd=/`, only stdin/stdout/stderr. The worker reads the daemon's request (trusted), compiles the YARA rules
  and **before the first byte of the file** enables: rlimits (core 0, file writes 0, CPU 120 s, `RLIMIT_DATA` 1.5 GiB,
  ≤ 32 fds), `PR_SET_DUMPABLE=0`, Landlock with no rules (not a single file; TCP bind/connect; scope — where the kernel
  supports it), seccomp with two filters: kill the process on `execve*`, sockets, `ptrace`, `clone*`/`fork`, `unshare`,
  `mount`, `keyctl`, `bpf`, `io_uring_setup`…; the rest is an allow-list, otherwise `EPERM` (`read` only fd 0, `write` only
  1 and 2, `mmap` only anonymous and without `PROT_EXEC`, `mprotect` without `PROT_EXEC`, `tgkill` only to itself). Then it
  reports what is enabled; without isolation (Landlock ABI ≥ 1, seccomp, rlimits, no extra fds) the daemon **does not hand
  over** the content — verdict `failed`. A crash, a signal, a timeout, a malformed answer — also `failed`.
- **Why.** SPEC §13 names bubblewrap + Landlock; bubblewrap is not on the build server and may not be installed there
  (we install no system packages on the build server), while self-isolation of a process with Landlock + seccomp is
  the approach of Chromium renderers and `codex-linux-sandbox`, pure Rust, without root or packages. Checked
  with probes from inside (`tests/sandbox.rs`): reading/writing/listing the FS — refused (and Landlock on its own —
  `EACCES`), UDP/TCP/exec/a thread — SIGSYS, 2 GiB against the limit — SIGABRT, an infinite loop — SIGXCPU after 10 s, the
  environment is empty.
- **YARA-X with wasmtime in Pulley mode** (an interpreter): no JIT is needed, so seccomp forbids executable pages. YARA's
  timer (`set_timeout`) is not used: it starts a thread — time is bounded by the CPU limit and the daemon's timeout.

### D-F-7 · The CDR engine (SPEC §19): a native sandbox + pure Rust; only pixels and text leave the sandbox
- **Decision.** Images (PNG, JPEG, GIF, WebP, BMP, ICO) — `image` 0.25 with limits (side ≤ 20,000, memory ≤ 512 MiB),
  downscaled to 2048 px, the first frame; PDF — `hayro` 0.7 (pure Rust, `forbid(unsafe_code)`): a raster of the first 8
  pages (≤ 1600 px) + the text of the first 200 pages via the glyphs' Unicode (ToUnicode/glyph names, spaces by glyph
  widths); DOCX/XLSX/PPTX/ODF — text from the XML (`zip` + `quick-xml`, no DTD and no external entities);
  text/HTML/SVG/XML/RTF — the source text (SVG and HTML are **not rendered**); an archive — the file list. The worker
  returns **raw RGBA pixels and a string**; the daemon assembles the PNG with the `png` encoder (only IHDR/IDAT/IEND — no
  metadata) after checking the geometry, and the text is sanitized again.
- **Why.** The Dangerzone approach ("pixels instead of parsing") without a container: podman/docker + gVisor are
  system packages, and D-F-6 provides the isolation. The "only pixels leave the sandbox" scheme removes a second parse of
  an untrusted format in the daemon. Limitation: rasterizing Office pages is impossible without LibreOffice (question
  Q-F-1); poppler/pdftoppm is on the build server, but it is a system package and GPL — not used.
- **ClamAV** — an external hook (`clamscan -` with the 0/1 convention): the program at an **absolute path from the owner's
  configuration** (not from `PATH` — an agent of the same uid would plant its own there), launched through the `av-exec`
  worker under Landlock (reading — only libraries, settings and databases; writing — only the 0700 temporary check
  directory, which is deleted), seccomp without network, and rlimits. Off by default; ClamAV is not on the build server.
  Checked with a fake "antivirus" that tries to read the "daemon key" outside the allowed directories (`tests/sandbox.rs`).
  Not linked (GPL-2.0). `clamscan -` writes a copy of the content into a temporary file — into the isolated
  check directory, not the shared `/tmp`.

### D-F-8 · Archives are not unpacked (SPEC §10 item 3)
- **Decision.** ZIP (and OOXML/ODF/JAR/APK) — only the central directory: a declared size > 10 GiB, or > 100 MiB with
  compression > 100× (per entry — > 1000×) — a bomb; overlapping entries — a bomb (Fifield); `..`, absolute paths, device
  names, symlinks, devices/FIFOs — a threat; encryption, a nested archive (depth 1 — we do not look inside), executable
  entries, Office macros, > 10,000 entries — a risk. tar — headers (including GNU long name and pax `path=`),
  hardlink/symlink/devices — a threat. gzip — the stream is counted against a 1 GiB limit (not accumulated in memory), a tar
  inside is parsed from the same stream. bzip2/xz/zstd/7z/RAR — not parsed (risk: "content unknown").

### D-F-9 · Verdict and thresholds
- **Decision.** `clean` / `suspicious` / `threat` / `failed` = the maximum severity of the findings (`info` does not change
  the verdict). Threat: EICAR, YARA signatures with `severity = threat` (`/Launch` in a PDF, an executable in a PDF, a
  "download and run" script), bombs, polyglots (a PDF header in the first 1024 bytes of another type, a ZIP directory at the
  end, HTML/script at the start of a binary), an executable/script named as a document, dangerous archive entries, an image
  the limited decoder could not open. Risk: JavaScript/auto-action/attachments in a PDF, macros, old OLE, scripts,
  HTML/SVG with handlers, secrets, executables, an unknown type, an extension mismatch, a PDF that `hayro` could not open,
  a file > 256 MiB (structure checked over the first 256 MiB, YARA and secrets in 64 MiB windows with overlap over the
  whole file). Info: "looks like prompt injection", "archive: N files".
- **Why.** Unknown is not "clean": an agent must not accept such a file by itself. Prompt injection is not a file threat;
  taint protects against it (SPEC §9); the mark helps the owner.

### D-F-10 · ACL of the link's blobs
- **Decision.** A connection only from the EndpointId of this link's contact; a request only `get` of a whole blob (not
  hash-seq) from the set sent **in this link** (tag `out/…`, restored when the store is opened); `get_many`, `push`,
  `observe` — refused. The refusal is made in the event interceptor before the store is touched: the response time does not
  reveal whether a blob exists. Received blobs are tagged `in/…` (protected from garbage collection, resumed after a
  restart) and are not served.
- **Why.** SPEC §10, §18 "contact B cannot get link A's blob knowing the hash". In iroh-blobs 0.103 `EventMask.push` and
  `observe` are not read (everything is decided by `mask.get`, TROUBLESHOOTING), so the refusals are explicit.

### D-F-11 · The file secret scanner = the message scanner
- **Decision.** `x_core::policy::scan_secrets` is passed to the worker as a function (`TextScanner`); the file goes in
  256 KiB windows with an 8 KiB overlap (modeled on `SecretStream`), up to 64 MiB of text; for binaries — printable strings
  (≥ 8 characters), for PDFs and documents — also the extracted text. An incoming file with a secret is "suspicious" (the
  owner decides); at the sender the finding codes go into the report, and the "send or not" decision (approval at any
  level) is the daemon's policy at stage B.

### D-F-12 · Our crate is also built with `opt-level = 2` in debug
- **Decision.** `[profile.dev.package.x-files] opt-level = 2` (at stage B, the same in the root).
- **Why.** `EncryptorBE32<ChaCha20Poly1305>` is generic: the cipher code is instantiated in our crate, and at `-O0` STREAM
  ran at 7 MB/s (64 MiB in 9 s) versus ~580 MB/s (TROUBLESHOOTING).

### D-F-13 · Independent security review of stage A and fixes (2026-10-02)
Review of code `99df5fa` against SPEC §10, §15 (an independent reviewer, read-only, experiments in a temporary copy):
**no critical findings**, 6 important, 7 medium, 7 minor. Fixed in `50aac3e`, each finding has a regression test
(`tests/review.rs`, `tests/pipeline.rs`, unit tests):

| No. | Finding | Fix |
| --- | --- | --- |
| 1 | The level quota was computed from the manifest, while a blob of any size was downloaded; the store had no garbage collection | The download is cut as soon as more than declared has been downloaded; the excess is forgotten; the store is opened with garbage collection (`GcConfig`, 60 s) |
| 2 | The antivirus was taken from `PATH` and ran without isolation: an agent planted its own `clamscan` and got the plaintext | Only an absolute path from the configuration, launched via `av-exec` (Landlock + seccomp without network + rlimits), off by default |
| 3 | For a file > 256 MiB YARA did not look at the head: a threat at the start of a large text gave "clean" | YARA over the head always, "partially checked" for all non-text files |
| 4 | At the sender, secrets in DOCX/PDF(Flate)/ZIP/gzip are not visible | `check_outgoing`: text of PDFs and documents without pixels; ZIP and gzip content into the worker's memory with a 256 MiB budget, only for the secret search (at the recipient too) |
| 5 | Unicode tags, bidi, zero width, invisible PDF text (`3 Tr`) and Word text (`w:vanish`) passed into the preview | One sanitizer `text.rs` for previews, lists, names and findings; findings `invisible_characters`, `hidden_text`; hidden text does not go into the preview |
| 6 | The destination was set by the caller: a file from link A could be put into link B's folder, a level 2 file into `shared/` | The quarantine chooses the destination: the lower of the level at the offer and the current one; the link folder — from the offer |
| 7 | `mmap(MAP_SHARED|MAP_ANONYMOUS)` bypassed the memory limit | seccomp: only `MAP_PRIVATE`; at most 2 workers at a time |
| 8–9 | Names with a leading `-` (flags for `tar/rm *`), invisible characters; an incomplete list of auto-executing names | Forbidden; the lists were extended (agent instructions, build tools, `*.config.js`, `.bat/.ps1/.command/…`) |
| 10 | "Clean" without parsing and without a preview (TIFF, SQLite, gz(ELF), Follina OOXML relationships, RTF objects, `.bat`, meta refresh) | "No safe preview" is a risk; the type inside gzip; external OOXML relationships (mhtml/ms-msdt — a threat), DDE, RTF `\object`, scripts by name, forms and refresh in HTML |
| 11 | `/J#61vaScript`, `/L#61unch` bypassed the YARA rules | PDF structure via `hayro-syntax` (names decoded, objects from object streams) |
| 12 | Plaintext was written to a named `.x-incoming-*` in `inbox/` before the check and remained after a crash | `O_TMPFILE` + `linkat` (no name until the check is over, does not replace an existing file), a fallback path and cleanup of leftovers |
| 13 | The daemon trusted the worker's answer too much (256 MiB, raw strings, stderr, verdict) | Frame ≤ 96 MiB, codes by mask, ≤ 256 findings, texts escaped, the verdict not lower than the findings, PNG in `spawn_blocking`, the preview as a separate encrypted file |
| 14–20 | Parallel acceptance produced two copies; a rejected offer was accepted again; a spoofed rejection reason; an overflow in tar; a raw name in `pending`; a secret in a public field; a blob was served before the policy decision | A lock on operations per file; a `<id>.rejected` mark; the reason — only for `file_corrupt`/`hash_mismatch`; `checked_mul`; checking and escaping the name; `pub(crate)` + `Zeroizing`; an outgoing blob is a `draft/` until `offer_existing` |

**Limits (not closed in the crate; to be recorded in CONTROL §11 at integration):** an agent of the same uid can replace
the worker binary or the configuration; the worker's verdict is worth nothing after an RCE in a decoder — only "only pixels
and text leave the sandbox" and taint hold; `OwnerForce`, `Acceptor::Owner`, `special_approved` are API values, and the
daemon must give no path to them from MCP and must bind the approval to (link, id, name); plaintext during the check is in
the daemon's memory without `mlock`; outside Linux there is no isolation — verdict `failed`; YARA does not look at archive
contents (per SPEC, archives are not unpacked).

**Re-check by the same reviewer (`50aac3e`)**: of 20 — 12 closed, 8 partially; 7 new ones found (N1–N7). Fixed in
`45ff2f3`, tests — `tests/review.rs`, `tests/sandbox.rs`, `tests/pipeline.rs`:

| What | Fix |
| --- | --- |
| N1 · important: walking PDF objects is quadratic on an object stream (`hayro-syntax` 0.7 re-reads the offset table): 60,000 objects — 101 s, the worker slot is busy until the CPU limit | `pdfscan`: a limit of 5 s and 20,000 objects → finding `pdf_too_complex` (risk); the check timeout includes waiting for a free worker. Test: 60,000 objects — a few seconds |
| N2: a copy of the content for the antivirus in `/tmp` on disk remains after a daemon crash | `/dev/shm` (memory), cleanup of `x-av-*` at startup |
| N3: the incoming blob tag is per hash: rejecting one record broke another with the same ciphertext; someone else's "manifest" with the hash of our outgoing blob deleted it | Tag `in/<hash>/<record>`; on `file_corrupt` only our own tag is removed; drafts are removed at startup (`clear_drafts`) |
| N4: OOXML relationships were searched by substring — single quotes, spaces, `&#69;xternal` bypassed it | Parsing `.rels` with `quick-xml` with attribute normalization; DDE — in all parts of `word/` and `xl/` |
| N5: the antivirus under `av-exec` could send signals to other processes of the same uid (kill the daemon) | seccomp: `kill`/`tgkill`/`rt_*sigqueueinfo` only to its own pid, `tkill`/`pidfd_send_signal` — kill |
| N6: ordinary programs crashed under `av-exec` (NSS → AF_UNIX → SIGSYS), there was no `/dev/null` | `socket`/`socketpair` — `EPERM` rather than a kill; `/dev/null` for reading and writing |
| N7: the `av-exec` deny list did not see x32 numbers | A separate 4-instruction BPF filter: bit `0x40000000` in the number — kill |
| No. 4 partially: secrets in invisible PDF text and in compressed PNG text chunks | Invisible text does not go into the preview, but goes into the scanner; PNG zTXt/iTXt — into the scanner |
| No. 5 partially: white text, < 4 pt, `Tz`, clipping, zero opacity; DOCX in white and `sz < 8`; invisible characters were counted after sanitizing | All go into `hidden_text`, not into the preview; "smuggled" characters are counted before sanitizing |
| No. 8 regression: names with emoji (ZWJ, U+FE0F) were rejected entirely | ZWJ and variation selectors are allowed next to emoji; the manifest rejects only control characters, tags and text direction |
| No. 9: `.js`, `.jar`, `.iso`, `.img`, `.vhd`, `.dmg`, `.sh` | Via a separate approval |
| No. 19: `Item` was serialized together with the file secret | The secret is only in the private encrypted record on disk; `Item` does not have it |

Remaining limits (to be recorded in CONTROL §11 at integration): the link folder (`offer`) and the project folder
(`accept`) are set by the daemon from its DB and a signed configuration — the crate trusts them; the operation lock is in
the memory of a single `Quarantine` (in the daemon it must be the only one); text covered by an opaque shape and white text
on a dark background can only be told apart by checking against the raster (next step: compare a glyph with the pixels of
the rendered page); a key in base64 or paraphrased will not be seen by any content scanner; `clamscan` running under
`av-exec` has not been checked — ClamAV is not on the build server.

### D-F-14 · The stage B (integration) plan — completed 2026-10-02 (D-F-15…D-F-22; deviations from the plan — D-F-22)
When stage A was handed over, slice 3 was still changing `node.rs`, `control.rs`, `linksync.rs`, `x-cli/main.rs` in the
shared working tree (until `9cf44fd`, the fixes from the review re-check); now the tree is clean. Stage B is a separate
task the size of a slice: the core is ~24 thousand lines, and adding `x-files` to the root workspace adds a build of
`yara-x`/`wasmtime`/`hayro` (~6 min and ~2 GB in `target`) to every workspace build. Plan:
1. `x-proto` (Apache-2.0): a message type `file` with the body `FileOffer { manifest: SignedManifest, secret }` (the secret
   inside E2E and in the history too; the DB is encrypted); `Body::Ref` — BLAKE3 of the plaintext for the DAG; the receipts
   `share_file`/`request_file`/`accept_file` already exist in `ReceiptBody.action` (slice 3).
2. `xd`: a hidden worker subcommand (`xd --x-files-worker check|selftest|av-exec`), the scanner is
   `x_core::policy::scan_secrets`; the `x-files` crate becomes a member of the root workspace,
   `[profile.dev.package.x-files] opt-level = 2`, the git dependency on the core is removed.
3. `x-core`: `LinkBlobs` on the link's endpoint (the iroh-blobs ALPN in the link's Router — the link's accept-list already
   admits only the contact), opened on demand and closed when idle (TROUBLESHOOTING "iroh-blobs 0.103": its own runtime on
   the store); the quarantine key is HKDF of the keystore root key; `used_today` accounting per link in SQLCipher; cleanup
   of `.x-incoming-*` at startup.
4. Policy: `share_file` — levels (D-30) + the sender's report (secrets → approval at any level), then `offer_existing`;
   acceptance by an agent sets taint (the contact's level) and the read mark; `special_approved` and `--force` only for the
   owner with the password (slice 3's owner session), the approval is bound to (link, id, name).
5. Control protocol and CLI: `x share <contact> <file>`, `x request <contact> <path>` (from the contact's `shared/`,
   level 3+), `x files pending|preview <id>|accept <id> [--as name] [--force]|reject <id>`; events `file_offered`,
   `file_checked`, `file_accepted`, `file_rejected` in CONTROL.md; MCP `share_file`, `request_file`, `files_pending`,
   `file_preview`, `accept_file` (level 1 — no tools at all, 2 — accept only via the owner's approval).
6. §18 tests on two real daemons: level 1 does not get a file even through prompt injection of an agent; level 2 — only
   `inbox/` and only after the owner's confirmation; a file with an exploit does not reach the agent; 1 GB with resume and
   a hash check; link A's blob is unreachable from link B by hash; a receipt for acceptance in the DAG.

## Questions for the maintainer (slice 4, not decided)

| # | Question | What is done now | Options (cost) |
| --- | --- | --- | --- |
| Q-F-1 | Rasterizing DOCX/XLSX/PPTX pages (SPEC §10 item 4 "Office → text and page images") | Text only | a) keep text; b) headless LibreOffice as an external process under the same isolation (Landlock — reading its directory, no network): `apt install libreoffice-core libreoffice-writer` ≈ 300–400 MB, conversion to PDF → `hayro` raster; ~1–3 s per document; c) only at the owner's request for an individual file |
| Q-F-2 | ClamAV (SPEC §10 item 3 "by default"; §19 "built in or separate") | The hook is ready, no `clamscan` | a) do not install; b) `apt install clamav` + `freshclam` (≈ 200–300 MB of databases, updates over the network, an update service; `clamscan` memory ≈ 1 GB per check) — the hook picks it up by itself; c) only in the build for workstations |
| Q-F-3 | "Threat found → refused, file deleted" (SPEC §10 diagram) versus "an infected file can be accepted by the owner with `--force`" (§10 item 5) | The threat stays in quarantine (ciphertext, no preview) until the owner rejects it or accepts it with `--force` | a) as is; b) delete right away (then `--force` applies only to "not checked"); c) delete after 24 h |
| Q-F-4 | Public exploit PNG/PDF for the §18 test | Corpus: PngSuite (broken PNGs) + generated attack structures; no live CVE samples | a) as is; b) add test PDFs from pdf.js/PDFBOX (Apache-2.0, damaged, no live payload); c) live samples as a separate encrypted archive outside the repository |
| Q-F-5 | Files > 256 MiB: the structure is checked over the first 256 MiB → "suspicious" → only the owner accepts | As is | a) keep; b) raise the limit (worker memory = file size); c) streaming structure checks per format (work) |

### Decisions on the slice 3 and 4 questions (2026-10-02)
| Question | Decision | Who |
| --- | --- | --- |
| Q-F-2 · ClamAV | **Not mandatory**: used if it is already installed on the device (an external hook); we do not install it on the build server. A deviation from SPEC §10 "ClamAV by default" | maintainer |
| Q-F-1 · Office preview | **Sanitized text only for now**; rasterizing pages via LibreOffice — later, optional. PDFs and images are rasterized | maintainer |
| Q-F-3 · a file with a threat | Stored encrypted in quarantine for **7 days** for the owner's decision (`--force` + password), then deleted; the contact gets a refusal. Combines the SPEC §10 diagram ("deleted") and item 5 ("`--force`") | team |
| Q-F-4 · test exploit PDFs | Take them from the open pdf.js / PDFBox sets (Apache-2.0), keeping the licenses; store as inert data | team |
| Q-F-5 · files > 256 MiB | Structure check over the beginning, the "suspicious" mark, the decision is the owner's | team |
| Q-20 · rekey | **After a DB rollback — always both owners with codes** (a rare event; theft of the contact's keys is a real threat, N1); planned rotation `x rotate` (v0.3) — by the per-level rules of SPEC §5 | team |
| Q-21 · history fingerprint | **3 emoji, as in SPEC §8** (it is a quick visual indicator, not the only protection: verification uses the full hashes of the heads) | team, per SPEC |
| Q-22 · `check:*` receipts for levels 1–2 | **As a batch**: an aggregate per 10 minutes in the DAG, details in the local audit log. The SPEC §9 requirement is met, and the contact's spam does not bloat the history | team |

## v0.1 MVP, slice 4 "files and quarantine", stage B — integration into `xd`, `x`, MCP (2026-10-02)

Plan — D-F-14; protocol — PROTOCOL §19, CONTROL §14 (x-control/3); tests — `crates/x-cli/tests/files.rs`.

### D-F-15 · `x-files` is a workspace member; the secret scanner lives in `x-files`
Stage A took the secret scanner from the core by a git revision of this same repository (`065ed21`), because slice 3 was
changing the core. Now the dependency is inverted: `x-core → x-files`, the scanner (`scan_secrets`, `SecretStream`, the
BIP-39 word list) moved to `x_files::secrets`, and `x_core::policy` re-exports it — one and the same code checks both
messages and files (D-F-11) and runs inside the worker, which must not pull in the core. `crates/x-files/Cargo.lock` was
removed, the dependencies come from `[workspace.dependencies]`, `[profile.dev.package.x-files] opt-level = 2` is in the
root; `target/x-files` was removed. The cost: every workspace build compiles `yara-x`/`hayro` (~6 min from scratch); this
was known (D-F-14).

### D-F-16 · The check worker is `xd` itself
`xd --x-files-worker check|selftest <probe>|av-exec …` is parsed first thing in `main` — before `clap`, `tokio`, logging and
`harden()`: the worker sets up Landlock + seccomp + rlimits itself (D-F-6) and must not get a chance to open anything
extra. The path is `std::env::current_exe()` (on Linux, `/proc/self/exe`); `CheckerConfig` got a `worker_prefix` so that
the `av-exec` mode goes through the same hidden argument. The separate `x-files-sandbox` binary remains for the crate's
tests.

### D-F-17 · The blob store is per link, on the link's own endpoint; quarantine is in the data directory
- `<data-dir>/quarantine/<link_id>/` — the iroh-blobs store and the encrypted records; the quarantine key is HKDF of the
  keystore root key with the label `x/device/v0/files-key` (unavailable before `unlock`, wiped on `lock` together with the
  rest).
- The link store is opened on first access (offer, sending, acceptance) and closed on `x lock` and `x revoke`, not when
  idle: an open store is one background actor and a redb database, and a node has from a few to a few dozen links.
- The iroh-blobs ALPN (`/iroh-bytes/4`) is added to the `Router` of **every link endpoint**; the handler checks the
  connection's `EndpointId` against the contact's key (on top of the link's accept-list, D-F-10) and passes the request to
  the store **of this link only**. The download is driven by the recipient over a separate connection with the same ALPN
  and the same checks (the contact's key, PQ exchange).
- Link folders: `--links-dir` (by default `~/X/links`, without `$HOME` — `<data-dir>/links`), created before the first file
  is accepted (not at `unlock`: a daemon without files does not touch the home directory); an existing directory is
  resolved to its real path (a symlink to another disk is allowed), after that `O_NOFOLLOW` at every step. The link
  folder is the normalized contact label; a label with a special name — the first 16 hex of `link_id`; labels that
  coincide after case-insensitive normalization get a suffix from the link ID for all but the oldest (D-F-24).

### D-F-18 · An offer is a link message; what is stored and what is not
- `type: "file"` with `FileOffer {manifest, secret}` and `type: "request"` with `FileRequest {path}` are ordinary messages of
  link format v1: signed, in the DAG, verified; the file secret lies in the history (the SQLCipher DB), like an attachment
  key in Signal. Only **live** deliveries from the contact go into the file pipeline (not a resend during verification
  and not our own messages).
- A refusal at the manifest (level 1, daily volume, a bad manifest) **stores nothing**: only a `file{state: "refused"}`
  event and a `reject_file`/`denied` receipt to the contact — a level 1 contact cannot fill the disk with offers.
- The level's daily volume is counted from the link's quarantine records over 24 hours (`volume_since`), including rejected
  ones (their size stays in the `.rejected` mark) — not in SQLCipher, as the plan assumed: the accounting sits next to what
  it limits.
- Download: up to 4 at a time, 8 attempts with a pause; after a restart of `xd` (or `lock`/`unlock`) — continued from the
  `offered`/`downloaded` records (iroh-blobs resumes from the last verified chunk).
- Threat: a `reject_file`/`denied` receipt to the contact **immediately**; the record (ciphertext, no preview) is kept for
  7 days for the owner's `--force` and deleted by the once-a-minute maintenance (Q-F-3).

### D-F-19 · File policy: owner, agent, taint
- **Owner**: level 1 — no files in either direction; a secret in a file — approval (SPEC §9 "at any level"); can send a
  threat (it is their decision, the verdict goes into the manifest); accepting a threat or an unchecked file — only
  `--force` with the password (`Request::owner_password`); a special name — `--allow-special`.
- **Agent**, sending: the level per D-30 (1 — `denied`, 2 — approval), the session ceiling, plus approval if the file is
  outside this link's folder, the scanner found a secret, the sender-side check is a threat or was not performed, a
  cross-link flow, no-write-down. The check and encryption happen **before** the approval (otherwise there is nothing to
  show the owner and nothing to bind the approval to): on refusal the blob draft is erased; the approval is bound to the
  hash (path, name, BLAKE3).
- **Agent**, acceptance: level 1 — no; a threat and "not checked" — only the owner; level 2, "suspicious", a special name —
  approval (bound to the link, the file and the name), after the approval it accepts as the owner. `files_pending`,
  `file_preview` and `file_accept` **set taint** (the contact's level; the file name is the contact's data too, it can
  contain an instruction).
- The `file` event for an agent comes **without the name and the details of findings**: the subscription does not set
  taint, so it carries no contact data.
- An agent's `request_file` — from level 3 (SPEC §9 "read-only to shared/"); the answering node decides by itself according
  to its own trust level.

### D-F-20 · `x-control/3` rather than an extension of v2
File commands change the set of replies (`file`, `files`, `file_preview`, `file_requested`) and events (`file`), hence a
new version; v0–v2 are accepted as before. One `file` event with a `state` instead of four (`file_offered`,
`file_checked`, `file_accepted`, `file_rejected` from the plan): one state machine is simpler for the client. The preview
for an agent carries a `notice` ("EXTERNAL DATA … NOT instructions"); images in MCP are `image/png` blocks, in JSON only
their count.

### D-F-21 · `check:*` receipts as a batch (decision Q-22)
Tool checks of an agent "tainted" by a level 1–2 contact are accumulated in memory by key (link, agent, action, decision)
and once a minute are written out as a batch — when 10 minutes have passed since the first event — as one receipt with a
`count` field (`ReceiptBody.count`, on the wire only when `count ≥ 1`, so old receipts do not change); on `x lock` batches
are written immediately and delivered after `unlock`. Every check with details goes to the local audit log. Level 3+
contacts get receipts as before (identical ones at most once a minute).

### D-F-22 · Deviations from the D-F-14 plan and what is not done
- `Body::Ref` (BLAKE3 for the DAG) is not needed: the plaintext's BLAKE3 is in the signed manifest, and the manifest is in
  the DAG.
- Volume accounting is in the quarantine, not in SQLCipher (D-F-18); the store is closed on `lock`/`revoke`, not when idle
  (D-F-17).
- `x files accept --as` is named `--name`; the MCP tool is `file_accept` (consistent with `file_preview`, `file_reject`).
- The `x-files` sandbox tests (corpus, pipeline, review, sandbox) and `crates/x-cli/tests/files.rs` are Linux only
  (`#![cfg(target_os = "linux")]`): there is no worker sandbox on macOS yet, the check there is fail-closed (D-P-6).
- Office page rasterization (Q-F-1 — later), ClamAV by default (Q-F-2 — not mandatory) — per the maintainer's decisions.

### D-F-23 · How long to serve what was sent; requests from `shared/` one at a time
- The ciphertext of a sent file lies in the link store while the contact can download it. The contact's answer — an
  `accept_file` or `reject_file` receipt referencing the offer message — stops serving immediately (the record
  `<data>/quarantine/<link>/out/<file_id>` is deleted, the blob goes to garbage collection); without an answer — after
  14 days (`OUT_KEEP_MS`). Otherwise every sent file would double disk usage forever. The contact's receipt can only stop
  serving to that same contact — it cannot reach other links or other files.
- A request from `shared/` costs checking and encrypting the whole file, while level 3 incoming messages are limited only
  to 60 per minute: so per link — one request at a time and at most 20 per hour; the same file (path, inode, size,
  mtime) that has not been answered yet — refused without encryption; unanswered serving on requests — at most the
  contact level's daily volume; files with hard links (`st_nlink > 1`) are not served. Beyond that — a refusal receipt.
- Acceptance leftovers after a daemon crash (`.x-incoming-*`) are cleaned up on `unlock` in the already existing `inbox/`
  and `shared/`.


### Product name: Antenna (maintainer decision, 2026-10-02)
- The maintainer chose "Antenna" as the name. This closes the open question of SPEC §19 (the product name). The working
  name `x` goes away.
- Name check (2026-10-02): on crates.io the name `antenna` is taken by an unrelated WASM library for P2P meshes over WebRTC
  (v0.1.1) — a nearby area, possible confusion in search; `antennad`, `antenna-core`, `antenna-proto` are free.
  No major messenger projects with this name were found on GitHub. A trademark and app store check — before the public
  launch (an open task).
- Proposed names (team proposal; the maintainer may change them): CLI `antenna`, daemon `antennad`, app `Antenna.app`;
  crates `antenna-proto`, `antenna-core`, `antenna-files`, `antenna-sys`, `antennad`, `antenna-cli`; the data directory
  and socket — `antenna`. The rename is a separate step after stage B of slice 4 and the merge of the macOS branch, one
  change in all places (code, window, packaging, CI, documents).

### D-F-24 · Independent security review of stage B and fixes (2026-10-02)
An independent reviewer (read-only, experiments on two real `xd` in a temporary directory): no critical findings, 6
important, 6 medium, 5 minor. Fixed (regression tests — `crates/x-cli/tests/files.rs::review_*`,
`inherited_descriptor_*`):
1. **The `request_file` path and the file name are a sending channel** past no-write-down, the cross-link flow and the
   secret scanner (confirmed: `request bob "api_key=sk-ant-…"` was delivered). Now the request path and the name of the
   file being sent go through the agent's `outflow_reasons` (approval); for the owner, through the secret scanner
   (approval, as with `send`).
2. **`shared/` bypassed no-write-down**: an agent with label 5 wrote to `links/bob/shared/` (the hook allowed it), and the
   contact fetched the file with a request. Now `check write` into link X's folder counts as a transfer to X: cross-link
   flow and no-write-down → approval; the links folder is taken from the daemon's `--links-dir`, not from `$HOME`. Limit:
   an agent with a shell bypassing the hooks writes wherever it wants (CONTROL §11 item 1).
3. **Reading a file from a link folder did not set taint** (the `Read` hook declared "local data 5"). Now `mark_read` with
   a path inside a link folder sets that link's taint level instead of the local data label.
4. **The file name without taint**: an agent's `file_reject`, the approval request for `file_accept` (before taint),
   `saved_as` and `sender_mime` in the event. Now taint comes before the approval and in `file_reject`; the event for an
   agent carries only closed vocabularies and numbers.
5. **Sent blobs forever** and a new ciphertext for every request — D-F-23 (the contact's answer or 14 days, deduplication,
   a limit on unanswered volume).
6. **A race on the daily quota** with parallel offers — the volume check and writing the offer under one lock, plus at
   most 256 unaccepted records per link (review no. 11), all outside tokio threads (`spawn_blocking`).
7. (medium) A download without progress for 60 s — cut; one download and check per link, the shared slot (4) is held only
   for an attempt, not during pauses; a deleted record is not re-downloaded 8 times.
8. (medium) Coinciding labels — one folder: folders are computed across all links, coinciding ones get a suffix.
9. (medium) An agent rejected a threat and an accepted file: an agent's `file_reject` — from level 3, only for a checked
   clean/suspicious file before acceptance.
10. (medium) `share_file`/`request_file` approvals in the shared history — removed from `receipt_worthy`.
12. (medium) After `revoke` the link's quarantine remained — now it is erased (store, records, keys, serving).
15. (minor) The list of special names was extended (Podfile, Pipfile, Bazel BUILD/WORKSPACE, Procfile, sitecustomize.py,
    JS configs…).
17. (minor) Without `$HOME`, link folders inside the data directory can be sent; the `check:*` batch counter ≤ 10⁶.

**Not done (open, with the reason):**
- No. 7 partially: `reject` during a download waits for it to end (up to 60 s without progress) — cancelling the download
  on rejection is not done.
- No. 11 partially: `files pending` and lookup by ID decrypt the records synchronously; the number of pending ones is
  bounded (256 per link), accepted ones — only by explicit actions.
- No. 13: an agent's `share_file` reads and encrypts the file before the approval and reports the kinds of secrets and the
  size; an oracle for "does the path exist". The right scheme (approval by path and `(dev, ino, size, mtime)` before
  reading) — together with the approval window.
- No. 14: TOCTOU in `open_for_share` (intermediate directories, a symlink to a link folder) — the CONTROL §11 item 1 class
  (an agent with a shell of the same uid); hard links in answers to requests are closed.
- No. 16: `accept_file`/`reject_file` receipts to a level 2 contact reveal the time of the owner's action; kept — the sender
  stops serving the file because of them (D-F-23). Maintainer decision — if it matters, delay them, like the `check:*`
  batches.
- No. 17: `x lock` during a check leaves the verdict `failed` (after `unlock` the check is not repeated — only the owner
  can accept with `--force`); an offer is lost if the daemon crashed between the link's `ok` and writing to quarantine.
- Inherited descriptors without CLOEXEC — an honest `failed` instead of `bad_state`; CLOEXEC itself at `xd` startup needs
  `unsafe` and waits for the `x-sys` crate (merge of the macOS branch, D-P-1), TROUBLESHOOTING.
- For the macOS branch (x-sys, D-P-3) the reviewer has nested anchors of GUI hosts and anchors across a reboot: handed over
  to the owner of that branch.


### Releases and variants (maintainer decision, 2026-10-02)
- The maintainer asked for a download link and several variants: a visual one and a command-line-only one; the command
  line can be built into the visual one if that is safe.
- Decision: releases are GitHub Releases of the private repository, triggered by a `v*` tag; files:
  `Antenna-<ver>-macos-arm64.dmg` (the window + the bundled `antenna`/`antennad`), `antenna-<ver>-macos-arm64-cli.tar.gz`
  (only the CLI and the daemon), `antenna-<ver>-linux-x86_64.tar.gz` (CLI + daemon + `install.sh`, a systemd user service).
- The CLI in the visual version is safe: it is a client of the same daemon with no additional rights (owner commands —
  password/session Q-14, agents — only a token). The window has the button "Install the `antenna` command in the
  terminal" (a symbolic link in `~/.local/bin`, no administrator rights; `/usr/local/bin` only by explicit choice with the
  macOS password prompt).
- The first release: `v0.1.0-preview.1` after the rename to Antenna; a node from the pre-release `x` build is picked up
  (migration of the data directory `x` → `antenna`).

## Rename to Antenna and the first release (2026-10-02)

Carrying out the decisions "Product name: Antenna" and "Releases and variants" (above). The historical records of this
file and TROUBLESHOOTING were not rewritten: they keep the names of their time, `x`, `xd`, `x-core`…

### D-55 · Names, paths and environment variables
- **Code:** crates `antenna-proto` (Apache-2.0), `antenna-core`, `antenna-files`, `antenna-sys`, `antennad`, `antenna-cli`
  (the `crates/*` directories via `git mv`, file history preserved); modules `antenna_proto`…; binaries `antenna` (CLI)
  and `antennad` (daemon); the test worker is `antenna-files-sandbox`, the hidden worker argument is
  `--antenna-files-worker`.
- **On the user's machine:** the data directory `$XDG_DATA_HOME/antenna` or `~/.local/share/antenna` (Linux and macOS —
  the same scheme, D-P-5), socket `antennad.sock`, DB `antenna.db`, link folders `~/Antenna/links/<contact>/`, the window's
  log on the Mac `~/Library/Logs/Antenna/antennad.log`, on Linux `~/.local/state/antenna/antennad.log`, the systemd user
  unit `antennad.service`, the MCP server in snippets — `antenna` (`claude mcp add antenna …`, `[mcp_servers.antenna]`).
- **Variables:** `ANTENNA_DATA_DIR`, `ANTENNA_SOCKET`, `ANTENNA_AGENT_TOKEN`, `ANTENNA_LINKS_DIR`, `ANTENNA_PROJECT_DIR`,
  the daemon log — `ANTENNAD_LOG`. The old `X_*` (and `XD_LOG`) are read as fallbacks only if the new one is absent: the
  daemon writes a warning to the log, the CLI one line to stderr per process; the window reads `X_SOCKET`/`X_DATA_DIR` in
  the same order. The single source of the lookup order is `antenna_proto::local` (CONTROL §1); `antennad`, the CLI and the
  Dart client repeat it.
- **Why fallbacks rather than dropping them right away:** the owner may have assistant configs from the pre-release build
  (`X_AGENT_TOKEN` in `~/.claude.json`, `X_SOCKET` in hooks): a silent refusal would look like "the token does not work".
  Removing the fallbacks is a separate decision after 0.1.0 (an open task).
- **The host hook** (`antenna hook claude-code`) lets through without a check only a plain `antenna …` call; the old name
  `x` — no longer: any unrelated program could be under that name in PATH, and letting it through without a check would
  be a hole.
- **Internal Dart names** (`XDaemon`, `XText`, `XControlClient`, `x_theme.dart`, `x_control.dart`) were not renamed: the
  user does not see them, and `x_control` is named after the `x-control` protocol anyway (D-57). The window package is
  `antenna_desktop`.
- **Checked:** `crates/antenna-cli/tests/cli.rs::legacy_environment_variables_are_a_fallback` (the old variables work and
  warn, the new ones take precedence), `antenna_proto::local` unit tests, `test/host/daemon_host_test.dart` (socket,
  binaries, log).

### D-56 · Migration from the pre-release `x` build — once, atomically, at `antennad` startup
- **Decision.** Before opening anything, `antennad` (module `migrate`):
  1. the default data directory: the new `~/.local/share/antenna` does not exist and the old `~/.local/share/x` does →
     `rename(2)` of the old one into the new one (one parent — atomic, no copying; the Time Machine exclusion xattr moves
     together with the directory), an `xd.sock` socket left over after a crash is deleted. If the old daemon's socket
     **answers** — refused with a clear message (a directory is not moved out from under a running process); if both
     directories exist — we work with the new one, leave the old one alone, and write a warning to the log;
  2. the DB file `x.db` → `antenna.db` (also for an explicit `--data-dir`): first `-wal`/`-shm`/`-journal`, then the file
     itself — an interrupted migration is finished at the next start, and the DB is never opened without its WAL; if a
     companion file exists under both names — refused, the owner sorts it out;
  3. the default link folders `~/X/links` → `~/Antenna/links`, an empty `~/X` is deleted (a non-empty one is not: the
     owner's files may be there); if it fails (another partition) — we work with the old folder, with a warning.
  Every step writes a line to the daemon log. Keys, links and history do not change: the keystore, rollback counters,
  quarantine and the blob store hold only relative paths.
- **macOS:** at every start of its daemon, the window removes the old build's LaunchAgent `dev.x.xd` (`launchctl bootout`,
  the plist is deleted — it will not come back at login) and only then installs the new one; a log entry. **Linux:**
  `install.sh` stops and removes the `xd.service` service and deletes `~/.local/bin/{xd,x}` only if their `--version` is the
  pre-release build (`xd 0.0.…`/`x 0.0.…`). The window also deletes the dangling link `~/.local/bin/x` →
  `…/x.app/Contents/Helpers/x` (the old instructions recommended it) — and no other.
- **Why this way:** the move is done by whoever owns the directory — the daemon, at one point and before opening the DB;
  the window and the installer only remove the old process. Copying instead of `rename` would produce two diverging nodes
  (rollback, D-45).
- **Checked:** `crates/antennad/src/migrate.rs` (6 unit tests: the move, a running old daemon, both directories, a DB with
  companions and an interrupted migration, a conflict of companions, link folders); `crates/antenna-cli/tests/migration.rs`
  — a pre-release node (directory `x`, `x.db`, `xd.sock`, `~/X/links`) with a real link and a conversation after the
  update starts with the same password (start on the migrated data — 20 ms), the history is in place, the conversation
  continues, a file checked in quarantine before the move is accepted after it into `~/Antenna/links` (the blob store and
  the quarantine records are alive), a second start moves nothing; an old daemon
  with a live socket blocks the move. LaunchAgent — `test/host/daemon_host_test.dart` with a stubbed `launchctl`. **Not
  checked:** on a real Mac (we have no Mac) — the first thing for the maintainer to check.

### D-57 · Protocol labels stay historical
- **Do not change:** ALPN `x/pair/0`, `x/link/0`; HKDF/HMAC/BLAKE3/signature domains `x/pair/v0/…`, `x/pair/v1/psk-proof`,
  `x/link/v1/…`, `x/file/v0/…`, `x/file-manifest/v0`, `x/device/v0/…`, `x/keystore/v0`, `x/agent-token/v0`,
  `x/owner-session/v0`, `x/approve/v0/…`, `x/state-counters/v1`, `x/quarantine/v0/record`; BLAKE3 contexts
  `x 2026-10-02 …`; the suite string `x-pair/1;…`; the TLS exporter label `EXPORTER-x-pair-v0`; the control protocol name
  `x-control/0…3`; the token prefixes `xat_`, `xos_`; the PROTOCOL test vectors (appendices A and B) and the formal model
  `formal/` (including its README's links to the old crate paths).
- **Why:** they go into keys, MACs, signatures and the transcript. Changing any of them is a new protocol version: nodes of
  the pre-release build would stop linking with new ones, keystore keys (`x/device/v0/…`) would not open, and the vectors
  and the ProVerif model would have to be recomputed and re-verified. The name on the wire is not visible to the user; the
  cost of changing it is out of proportion to the benefit. It can be changed together with the next incompatible protocol
  version (v2), in one change with the vectors and the model.
- **The invite link** is the only visible label: the node still **issues** `x://pair#…` (pre-release nodes understand it),
  while **parsing already accepts** `antenna://pair#…` as well (the scheme does not go into the cryptography; the secret
  scanner recognizes both). When no nodes understanding only `x://` remain, issuing can be switched to `antenna://`
  without a new protocol version. Test — `antenna_proto::invite::tests::accepts_next_scheme`, PROTOCOL §3. If the link
  becomes a web address per the "Domain" decision (`https://antenna.contact/#…`, below), it is added to the same list of
  accepted prefixes (`antenna_proto::invite::ACCEPTED_PREFIXES`; the secret scanner takes it from there too), and issuing
  is switched later.

### D-58 · "Install the `antenna` command in the terminal"
- **Decision.** The terminal icon at the top of the window (and a button in the daemon window) → a dialog: a symbolic link
  `~/.local/bin/antenna` → the CLI from the app (`Antenna.app/Contents/Helpers/antenna`; Linux — `bin/antenna` next to the
  window), no administrator rights; replacement is atomic (a new link next to it and `rename(2)`); a foreign link (an old
  location of the app) is replaced, a regular file (for example, from `install.sh`) — never. PATH is checked in the
  owner's **login shell** (`$SHELL -ilc`, with a 5 s limit and killing the process): on macOS the window has its own PATH,
  from launchd. No `~/.local/bin` — a line for the profile (zsh — `~/.zprofile`, bash — `~/.bash_profile`/`~/.bashrc`,
  fish — `fish_add_path`) with a "copy" button. On macOS by explicit choice — `/usr/local/bin/antenna` via
  `osascript … do shell script … with administrator privileges`: macOS itself asks for the password, the window does not
  see it; the path in AppleScript goes through `quoted form of`, quotes and `\` are escaped; "Cancel" is not an error. On
  Linux there is no system-wide install (only `~/.local/bin`).
- **Why a link, not a copy:** the app updated — the command updated too; there is no second CLI version diverging from
  the daemon.
- **Checked:** `test/host/cli_install_test.dart` — real links in a temporary `$HOME` (install, repeat, a foreign link, a
  regular file untouched, a dangling `~/.local/bin/x` deleted, a foreign `x` left alone, PATH present/absent), the
  AppleScript text and cancellation with a stubbed `osascript`; widget test `user_path_test.dart` — the button installs the
  link and shows the PATH hint. **Not checked:** the real `osascript` and the macOS password prompt (no Mac).

### D-59 · App identifiers
- macOS: `PRODUCT_NAME = Antenna` (`Antenna.app`, the window `Contents/MacOS/Antenna`), bundle id
  `io.github.danta-nort.antenna` (reverse-DNS on the author's GitHub account — the domain `danta-nort.github.io` belongs
  to the author), the daemon's LaunchAgent — `io.github.danta-nort.antenna.daemon`. Linux: the window binary
  `antenna-desktop`, GTK application id `io.github.danta_nort.antenna` (a hyphen is undesirable in D-Bus names — `_`), the
  window title "Antenna".
- Looking up the core in the macOS bundle — only `Contents/Helpers`: APFS is usually case-insensitive, and
  `Contents/MacOS/antenna` would "find" the `Antenna` window itself (test `locateCore`).

### D-60 · Release: `release.yml`, version and commit
- **Version** `0.1.0-preview.1` — `[workspace.package]` in Cargo.toml (single source; `packaging/version.sh`), the same in
  `pubspec.yaml` (`0.1.0-preview.1+1`) and `lib/version.dart`; a window test compares all three, the workflow compares the
  tag with Cargo.toml. **Build commit** — `build.rs` in `antennad` and `antenna-cli` (`ANTENNA_COMMIT` from the
  environment, otherwise `git rev-parse --short=12 HEAD`, without `.git` — `unknown`): `antenna --version` →
  `antenna 0.1.0-preview.1 (<commit>)`, the daemon version in `status`/`hello_ok` — `antennad 0.1.0-preview.1 (<commit>)`;
  the window — `--dart-define=ANTENNA_COMMIT`, it shows the window and daemon versions in the daemon window.
  CFBundleShortVersionString is the numeric part (`0.1.0`): Apple accepts only numbers.
- **Workflow** `.github/workflows/release.yml` replaced `release-macos.yml` and `release-linux.yml` (the logic is not
  duplicated): `version` → `core` (macOS arm64; Intel by a flag on a manual run) → `linux` (fmt, clippy, all tests,
  `mcp_smoke`, the window with live tests and goldens against the built `antennad`, the archive,
  `packaging/linux/check-install.sh`) → `macos` (the window, `build-dmg.sh`: the .dmg and the CLI archive from **the same
  signed** binaries, a check of the .dmg contents) → `publish` (only on a tag and only if everything is green:
  `SHA256SUMS.txt`, release notes from `packaging/release-notes.sh`, `gh release create --verify-tag`, `--prerelease` for
  versions with `-`; `permissions: contents: write` only for this job). A manual run on a branch — the same checks and
  files as run artifacts, without a release.
- **Deliberately not done:** Linux aarch64 and Intel Mac are not in the release (they are not in "Releases and variants";
  ARM runners for private repositories and macOS minutes are an expense); notarization — no Developer ID; signing the archives
  (minisign/GPG) — later.
- **Cost:** macOS minutes in a private repository count ×10; one release — `core` + `macos` (≈ 40–70 min without a cache)
  — about 400–700 of the 2000 free minutes per month of GitHub Free. Hence macOS jobs only on a tag and manually, not on
  every push. Since 2026-10-03 the macOS jobs run on a self-hosted runner and the Linux files are built outside GitHub
  Actions (D-81).

### Domain (2026-10-02)
- The project's main domain is **antenna.contact** (the site, the download page, invite links of the form
  `https://antenna.contact/#…`: the browser does not send the part after `#` to the server, so the site never sees the
  invite secret).

## The first run of `release.yml` (2026-10-02, run 37052359720): fixes

### D-61 · The file check worker gets no inherited descriptors, whoever launches it
- **What happened.** On the GitHub runner (Linux), the `cargo test` test process inherited 2 open descriptors without
  CLOEXEC; the `antenna-files` library's `Checker` launched the worker bypassing `antennad` (which sets CLOEXEC at
  startup, D-P-8), the worker got them and honestly refused to check: 13 tests of `tests/corpus.rs` got
  `sandbox_unavailable` instead of verdicts. For the product, the same would threaten any embedding of `antenna-files` and
  any future way of launching the worker.
- **Decision.** `antenna_sys::fds::no_inherited_fds_in_child(&mut Command)`: between `fork` and `exec`, in the **child**,
  all descriptors > 2 are marked CLOEXEC (Linux — `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)`; otherwise, and on macOS —
  `fcntl(F_SETFD)` over the numbers up to the soft `RLIMIT_NOFILE`, at most 65,536, computed in advance in the parent);
  `pre_exec` makes only async-signal-safe calls, without allocating memory. The calling process loses nothing; std's
  channel for the `exec` error is CLOEXEC anyway, so launch errors are visible. `antenna-files` calls this at all three
  places where the worker is launched (`check`, `av-exec`, `selftest`). `unsafe` only in `antenna-sys` (D-P-1). The
  `extra_fds` check in the worker stays: it is a second line, not a replacement.
- **Checked.** `antenna-sys` `fds::tests::child_only_mode_keeps_the_parent_untouched` (both paths: `close_range` and the
  walk; the child does not see fd 9, the next ordinary child does, the `exec` error comes through);
  `antenna-files` `tests/sandbox.rs::caller_with_inherited_descriptors_still_gets_an_isolated_worker` — a test process
  with open fds 7 and 8: verdict `Clean`, `extra_fds=0`; negative control — without the call the same test fails with
  `sandbox_unavailable … extra_fds=2`. The whole `cargo test --workspace` was run with two extra open descriptors (as on
  the runner).

### D-62 · macOS: the agent anchor is checked by PID, not by process name
- **What happened.** `tests/agents.rs::nested_anchors_belong_to_the_nearest_agent` on macOS: the behavior is correct (our
  own token in our own tree — `claude`, a foreign one — `token_bound`, the "owner" in each tree is the nearest agent,
  D-P-10); only the check that `bound_to` ends with ` sh` failed: on macOS `/bin/sh` is a shim that execs bash, the PID is
  the same, `comm` = `bash` (`bound_to: "67095 bash"`). This was a "to check" assumption in TROUBLESHOOTING; now it is a
  fact.
- **Decision.** The test compares the anchor's PID with `$$` of the inner `sh`, printed by itself — stricter than before
  (an unrelated process could also be named `sh`). The core code did not change: the protection was not weakened.

### Server for mass adoption: mailbox and push (maintainer's idea, 2026-10-02)
- The maintainer: we may need a server at least for users to talk to each other — it could make the product mass-market:
  notifications and message delivery even when the user is offline; we need features like Signal's.
- Team decision (within SPEC §4 "offline mailbox v2" and v1.0 "own relay"): bring it forward, together with the mobile
  client. Components: (1) **mailbox** — stores only E2E ciphertext, the mailbox address changes every ratchet epoch, TTL,
  no accounts; "sealed sender" — the server does not know the sender; spam protection without accounts (anonymous
  credentials/quotas, proof-of-work — to be chosen in the specification); (2) **push without content** via APNs/FCM — an
  empty "you have mail", and the app fetches the ciphertext itself; (3) **our own iroh relay**. Principles: no accounts,
  the server does not read, when both are online — direct; the server is open and self-hostable. Honestly about the
  cost: the server sees the IP and the time of requests (Tor — v0.3), costs and availability are on us, Apple/Google see
  the fact and the time of a push.
- Order: the specification (PROTOCOL/architecture) — now; implementation — after the desktop beta, together with the
  mobile clients.

## v0.2 · agent wake and streaming replies (2026-10-03)

Goal: "chat with an agent that replies by itself — as a stream, as in ChatGPT/Claude" — the maintainer's proposal
"streaming agent replies" (above, slice 2) together with wake (SPEC §11). Protocol — PROTOCOL §20, control protocol —
CONTROL §15–§16 (x-control/4), code — `crates/antenna-core/src/{stream,wake,sandbox}`, tests —
`crates/antenna-cli/tests/{stream,wake,wake_sandbox}.rs`.

### D-63 · The stream is separate from the history; the final is an ordinary `text` message
- **Decision.** A stream is an ephemeral display on a separate QUIC bi-stream of the link (`stream_open` + chunk frames on
  the same stream); only the final goes into the history, the hash-DAG, the signatures and the verification — an ordinary
  signed `text` through the ordinary queue. There is no new message type and no new fields in the envelope.
- **Why.** (1) Compatibility: `0.1.0-preview.1` nodes parse `envelope-core` strictly (`deny_unknown_fields`) — any new
  field or type would make the final "undeliverable"; this way a node without streams simply gets the final and answers
  `stream_open` with `rejected{malformed}` — the sender understands that it cannot stream. (2) History verification and
  signatures do not know about chunks at all: there is nothing to verify and nothing to roll back. (3) One QUIC stream for
  the whole display gives chunk ordering and flow control without our own numbers and acknowledgements; 1 RTT for opening
  (the recipient's answer) is the price of an honest `live` in `stream_started`.

### D-64 · The stream secret is inside the Triple Ratchet; chunks are STREAM, like files
- **Decision.** `stream-open {v, id(16), secret(32), ts}` is encrypted with the link session (Triple Ratchet) as a
  message outside the history: the ratchet state and the state counter (§17) are committed in one transaction on both
  sides. Chunks — `aead-stream` `StreamBE32` + ChaCha20-Poly1305, key `HKDF-SHA256(id, secret, "x/stream/v0/key")`, AAD — a
  label ‖ `link_id` ‖ `id`, the chunk plaintext is padded to the §12 buckets.
- **Why.** Our rule: only ready constructions; exactly the same scheme as for `xfile/0` files (D-F-2), and the same
  argument: libsignal does not hand out message keys, so a fresh random secret travels under the ratchet. Reordering,
  substitution, truncation and appending after the last chunk are caught by STREAM (tests `stream::tests`). Chunk padding
  hides token lengths; the writing rhythm cannot be hidden — hence only levels 3+ (D-66).

### D-65 · The final is recognized by a salt derived from the stream secret
- **Decision.** The final's envelope salt (`envelope-core.salt`, 32 bytes) = `HKDF-SHA256(id, secret, "x/stream/v0/final-salt")`
  instead of a random one. The recipient declares `final` only for a **contact's** message in this link's history with
  this salt: by the `final_id` from the last chunk (if the message has already arrived) or by the salt of any new incoming
  text (a broken connection, a final after approval, a final that arrived after the chunk). A final that was declared but
  did not arrive within 30 s — `interrupted`.
- **Why.** A connection break in the middle of a stream and a final after approval (a secret) could not otherwise be tied
  to the bubble without a new envelope field (D-63). The salt stays unpredictable for everyone except the two sides of the
  link (the ID cannot be guessed from the text, §12), and HKDF is a ready construction. Checking the author and the salt
  prevents the sender from pointing `final_id` at someone else's message (for example, at the owner's message).

### D-66 · Stream bounds: levels 3+ on both sides, approval is not streamed, the scanner on every chunk
- **The sender** streams only if its level for the contact is ≥ 3 (SPEC §4: the typing indicator — from level 3) and the
  message does not need approval for reasons known before the text: for an agent, link isolation (another link's data in
  the session) and no-write-down. The agent's session label is re-checked along the way (the label change counter
  `store::LABEL_GEN`): if the agent read another link in the middle of a stream, the stream is cut (`cut`), and the final
  goes to approval.
- **The secret scanner** (`SecretStream`, D-40) — on every chunk before sending, holding back a tail (an unfinished word,
  the last 48 bytes, an unfinished BIP-39 series): if a secret is found, the stream is cut and the whole message goes to
  the owner's approval; the secret does not reach the contact (tests `stream.rs`, `wake.rs`). The cost: the live text lags
  the source by ≥ 48 bytes (for an LLM, fractions of a second); the tail is released at the end.
- **The recipient** accepts a stream only from a contact whose level it has set to ≥ 3 (otherwise `rejected{level}`): live
  text is contact data too, and a stream holds the connection; with the asymmetry "3 for me, 2 for them", the sender learns
  of the refusal before the first chunk (`stream_started.live = false, reason = contact_refused`).
- **"What the agent is doing"** (`activity`, `tool:<name>`) — only to contacts of levels 4–5 (beyond ChatGPT, the
  maintainer's proposal).
- **Limits**: ≤ 4 incoming streams per link, opening counts as a message against the level limit, text ≤ 64 KiB − 64 B,
  ≤ 8192 chunks, ≤ 30 minutes, ≤ 60 s between frames (if the source is silent, an empty chunk every 15 s); frames at most
  every 30 ms (coalescing), the first one immediately.
- **Reception by an agent** — only the final (inbox, MCP): agents do not get stream events; v4 events do not go to v0–v3
  subscribers.

### D-67 · Wake: a dedicated agent per link, a clean session for every run
- **Decision.** `wake set <contact>` creates (or reuses its own) agent `wake-<label>`: its scope is only this link, base
  label 0. For every run: `agent_reset` (taint and declarations — anew), a new token in the agent's environment, the
  agent's anchor (D-28) — the root of the sandbox (bwrap or the supervisor); at the end the anchor is removed and the token
  is replaced with a random one. `antenna mcp` launched by the agent inside (`bind_parent`) does not re-bind the token: the
  anchor is already its ancestor (`agent_login`). The owner's agent (with an MCP host) cannot be woken — `wake set --agent`
  accepts only its own dedicated one.
- **Why a clean session is acceptable.** D-29: "resetting taint is only the owner's decision", because the daemon does not
  know what context the agent will restore (`claude --resume`). On wake it does know: the sandbox carries nothing over —
  HOME, the working folder and TMPDIR are per run and are wiped, writing to the owner's memory/CLAUDE.md/configs is closed,
  `--resume`/`--continue` are forbidden. This is exactly the "full enforcement" of D-29: the base label = what is mounted
  in the sandbox (nothing). What survives a run is only the link history (reading it sets taint again) and this link's
  `shared/`.
- **Why a separate agent per link.** An agent session with several links, after reading one, would need approval to answer
  another (link isolation) — on wake that is a useless queue of approvals; an agent per link is the least privilege.

### D-68 · The agent's prompt and command
- **A fixed prompt** (SPEC §11): "You have a new message in your Antenna link with <label>. Read it with the read_inbox tool
  (or `antenna inbox`) and reply…" — as the last argument (for `claude`, as the first one, right after the program:
  `--allowedTools`/`--mcp-config` take multiple values and would swallow the prompt — found by a manual run), or in place
  of `{prompt}`, also `ANTENNA_WAKE_PROMPT`. The contact's text is not substituted; the label (set by the owner) is only
  `[A-Za-z0-9._-]`, so even the label cannot bring a newline or an instruction into the prompt (test `wake::tests`).
- **Forbidden arguments** (`wake set` → `denied`): everything containing `dangerously` (`--dangerously-skip-permissions`,
  `--allow-dangerously-skip-permissions`, codex `--dangerously-bypass-approvals-and-sandbox`), `bypassPermissions`,
  `--yolo`, `danger-full-access` (including `-c sandbox_mode=…`), `--resume`, `--continue`, `--fork-session`. No shell is
  launched: `--cmd` is parsed by the CLI the way a shell would (quotes), without substitutions.
- **Modes.** `--output-format stream-json` → `claude_stream`: the daemon reads Claude Code's events
  (`stream_event`/`text_delta` with `--include-partial-messages`, otherwise whole `assistant` events; the fallback is
  `result`) and sends the reply text to the contact as a stream on the agent's behalf; sub-agents' text
  (`parent_tool_use_id`) is not the reply; between the agent's messages — an empty line; `tool_use` → `activity`. For
  `claude` the daemon adds the missing `-p`, `--verbose`, `--include-partial-messages`, `--mcp-config` (its own `antenna`
  server with the run token) + `--strict-mcp-config` and `--allowedTools` with only Antenna's read tools — the agent's
  reply goes as text, not via `send_message`. Otherwise — `plain`: the agent replies by itself. `--bare` is not added: it
  requires `ANTHROPIC_API_KEY` (it does not read the subscription OAuth).
- **The agent's login to its own CLI.** For `claude`, by default the agent sees the owner's `~/.claude/.credentials.json`
  **read-only** (`home_files`; for `codex` — `~/.codex/auth.json`). The agent cannot refresh the login (the file is
  read-only, the refresh host `platform.claude.com` is not on the proxy list) — and must not: a login file overwritten by
  the agent would replace the login of the owner's interactive Claude Code (for example, with an attacker's account). A
  manual run on 2026-10-03 showed exactly this: the token in the file had expired, the agent got 401, 7 refresh attempts were
  blocked by the proxy (there was no token rotation on the server side — the owner's login is intact). So for an agent that
  runs all the time — `--secret-env CLAUDE_CODE_OAUTH_TOKEN` (a long-lived `claude setup-token` token) and
  `--no-home-files`; secret variables are stored in the encrypted DB, `wake list` shows only the names.
  Honestly: the agent can read its login token and try to send it (the scanner catches `sk-ant-…` when pasted by accident,
  not when sent deliberately — CONTROL §11 item 6); this cannot be removed for any agent that talks to the provider itself.

### D-69 · The queue, limits and the wake log
- One run per link at a time; messages during a run set a "once more" flag: after the run the agent is started again only
  if it still has unread messages (otherwise an agent that does not read would spin forever).
- At most `max_runs_per_hour` (20 by default) runs per hour per link — otherwise a level 1 contact (10 messages per
  minute) would burn the owner's subscription with hundreds of runs; a refusal — a `wake{refused}` event and a log entry
  (at most once a minute).
- A run time limit (600 s by default, ≤ 3600): the agent is stopped, and a started reply goes out as an "interrupted" final.
- The log is the link's audit log (`wake`: outcome, exit code, duration, sandbox, reply ID, what the proxy allowed and what
  it blocked), the `wake` event, and the stderr tail of the last run in `<data>/wake/logs/<agent>.log`. After a daemon
  crash, the run directories are wiped, and the dedicated agents' tokens and anchors are reset at the next unlock.

### D-70 · A final that needs approval is sent by the daemon after the approval
- A stream has no "repeat the same call with `approval_id`": the text has left stdin or the agent's output. So a final for
  which the scanner (or the agent policy) requested approval is held by the daemon in memory until the request expires
  (10 minutes) and, after `antenna approve <id>`, sent by the daemon itself — with the stream's salt (D-65), so the contact
  recognizes it as the final of the cut stream. A refusal or expiry — the final is not sent.

### D-71 · The agent sandbox on wake: bwrap + Landlock + seccomp, a supervisor with a lifeline, the daemon's CONNECT proxy
Built on a separate branch (`52dd59e`) and merged into the slice; code — `crates/antenna-core/src/sandbox/`, tests —
`crates/antenna-cli/tests/wake_sandbox.rs` (11) and `wake.rs` (both modes).
- **Decision.** The agent is launched only through `antenna_core::sandbox::launch`. The main mode is the system bubblewrap
  (installed on the build server): its own user/pid/net/ipc/uts/cgroup namespaces (`--disable-userns` if available),
  `--as-pid-1`, `--die-with-parent`, `--new-session`, `--cap-drop ALL`, `--clearenv`; the root is a tmpfs with the system
  directories in it, **a selected list from `/etc`** (we are root: root reads `/etc/shadow` even without capabilities),
  `/proc`, its own `/dev` and `/tmp`, the spec's paths (the run's own HOME/working folder/TMPDIR — writable; the agent
  program's and `antenna`'s directories and the link folder — read-only, its `shared/` — writable; the agent CLI's login
  files — read-only). Network — an empty netns; the only way out is the supervisor's bridge `127.0.0.1:<port>` → the unix
  socket of the **daemon's CONNECT proxy**: only `CONNECT` to the rule's list of hosts (an exact name or `*.domain`, port
  443), the daemon resolves names, internal addresses are dropped (including inside IPv4-mapped, NAT64, 6to4), ≤ 64
  connections. `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` are set by the supervisor. On top — "stage 2" before the agent's
  `exec`: rlimits (core 0, nofile, fsize, cpu), `PDEATHSIG`, dropping capabilities, Landlock (FS; TCP connect — only to the
  bridge, bind — nothing), seccomp (sockets other than unix/TCP/netlink-route, `io_uring`, `kill(-1)`, signals to the
  supervisor and the daemon). The fallback mode (no bwrap, or it cannot set up namespaces — for example, Ubuntu 24.04's
  AppArmor for an ordinary user): the same supervisor without bwrap (subreaper + cleanup of descendants via pidfd) and the
  same Landlock layer (ABI ≥ 4 is mandatory) + seccomp. Neither one nor the other — the agent is not launched
  (`sandbox_unavailable`). bwrap is looked up only on system paths, root-owned, not writable by group/others, plus a
  functional probe.
- **The lifeline.** The supervisor's stdin is held by the daemon: EOF (`stop`, the time limit, `wake off`, the daemon's
  death) — SIGKILL for the whole agent tree; in bwrap, PID 1 exiting brings down the whole pidns. A double fork inside does
  not take a process out of the tree the agent is bound to (D-67).
- **Why this way.** SPEC §13 names "bubblewrap + Landlock"; namespaces close what Landlock cannot do before ABI 6 (unix and
  abstract sockets, signals, process visibility); seccomp covers UDP/DNS (Landlock ABI 4 does not hold them) and
  `io_uring`. The proxy is the SPEC §11 rule "the agent's network only to the model provider". A daemon test flag
  `--wake-landlock-only` (hidden) checks the fallback mode on a machine with bwrap; nothing can weaken it to "no sandbox".
- **Limits (CONTROL §11 item 11).** bwrap: closed — the FS outside the spec, the network except the bridge, UDP/DNS,
  signals and processes outside the sandbox, orphan escape, the daemon's descriptors and environment. Landlock mode, in
  addition, **not** closed (before ABI 6): unix sockets of the same user (D-Bus, ssh-agent), abstract sockets, signals to
  other processes of the uid, the process list in `/proc`; the bridge listens on the host's loopback. Both modes: memory
  and the number of processes are not limited (cgroups are needed); traffic to the allowed provider is a leak channel
  (SPEC §11); the CLI login file is mounted read-only — the agent will not save a refreshed OAuth token; the second
  sandbox of SPEC §11 (the agent's commands without network and without its variables) is not done: the agent's commands
  run in the same sandbox (network — only the provider).

### D-72 · macOS: wake is fail-closed until there is a Seatbelt profile
> **2026-10-03: done — D-P-13** (a Seatbelt profile following the D-71 model, orphans found by the sandbox itself). Below is
> how it was.

- **Decision.** `sandbox::probe()` outside Linux means "no sandbox": `wake set` answers `sandbox_unavailable` with an
  explanation, and the agent is not launched (SPEC §11 "only in a sandbox"). Streaming messages work on macOS
  (`send --stream`, the window).
- **Why.** A `sandbox-exec` (Seatbelt) profile cannot be checked without a Mac: an unchecked profile is either a hole or an
  agent that does not work. The plan is D-P-6 (the same mechanism as for the file check worker): `(deny default)` +
  reading the system, the program and its own run directories, writing to its own HOME/working folder, network — only
  `localhost:<bridge>`; the check is the CI `core` job on macOS with the same test
  `wake.rs::the_sandbox_keeps_the_agent_inside`.

### D-73 · Independent security review of v0.2 and fixes (2026-10-03)
An independent reviewer, read-only, against SPEC §4/§9/§11/§13 and the stream sketch (commit `8c4c2a4`): **no critical
findings**, 1 important, 2 medium, 2 minor. Fixed (tests — `stream.rs::at_most_four_live_streams_per_link`,
`wake.rs::activity_reaches_level_4_and_passes_the_secret_scanner`):
1. **(important) The "≤ 4 incoming streams per link" limit was checked non-atomically**: the check — before decrypting the
   open, the insertion — after, without a re-check; simultaneous opens on one connection all passed (up to the level's
   message limit and the QUIC limit). Now the check and the insertion are under one lock, the refusal is `busy`. The test
   holds the invariant (of 6 simultaneous — exactly 4 live, two `contact_refused`, a final for all six); the race of the
   opens themselves cannot be reproduced by a CLI test — the fix was checked by reading.
2. **(medium) `activity` went to the contact past the secret scanner** (on wake — the tool name from the agent's output).
   Now a line with a secret is not sent at all. Negative control: without the fix the test sees `ghp_…` at a level 4
   contact.
3. **(medium) A window before the anchor is bound**: the run token was valid before the daemon bound the agent to the
   sandbox root. Now `SandboxSpec.start_gate`: the supervisor does not start the agent until the daemon sends `go` on the
   lifeline; the daemon first binds the anchor and only then makes the run token valid and sends `go`. The agent's code
   does not run for a single moment without the binding.
4. **(minor) The `--agent` name in `wake set` was not validated** — now the same rules as for `agent add`
   (`[A-Za-z0-9._-]`, ≤ 64).
5. **(minor) The end of the final was recognized by an `[interrupted]` mark in the text** (the contact's words): now by
   the last chunk of the stream, if it arrived; the mark is only a fallback (a break, a final after approval). This is
   presentation, not a boundary.
Checked by the reviewer and in order: the final always goes through the full `send` policy; re-checking the label along
the way (`LABEL_GEN`) without a race by causality; levels 1–2 do not see streams on either side; `final_id`/the salt;
STREAM; the ratchet and the §17 counter for the ephemeral open; v4 events do not go to old subscribers and agents;
forbidden flags (case, `=`, separate arguments); the prompt without the contact's text; `--cmd` without a shell; the proxy
(only CONNECT, port 443, internal addresses, including inside IPv4-mapped/NAT64/6to4, resolution and connection to the same
addresses); the sandbox (the selected `/etc`, seccomp, Landlock, capabilities, the lifeline, orphans, fds). Not checked by
the reviewer with a live experiment: the race of item 1, parsing the output of the real `claude` (checked with a manual
run, D-68), behavior on macOS.

## LAN, links through the site, contact agents (2026-10-03)

Goal: public beta quality — invite links through the site, the contact's agents visible by name (SPEC §5, §11), LAN
without internet via mDNS (SPEC §4, §18). Decided during the core work, within the task; whatever changes SPEC is marked.

### D-74 · The invite link is a web address `https://antenna.contact/#<body>`; `antenna://pair#` alongside, `x://pair#` only accepted
- **Decision.** The node issues `https://antenna.contact/#<E_A>.<s>.<relay>[.<direct>]` (the "Domain" decision): this is
  `link` in the `invite_created` event, in `pairings` and in the output of `antenna invite` (stdout — one line with the
  link, for scripts; in a terminal, the QR code of this link goes to stderr). Alongside — `link_app` =
  `antenna://pair#<body>`: the app scheme, which `0.1.0-preview.1` nodes also understand (their `ACCEPTED_PREFIXES` =
  `x://`, `antenna://`). Parsing accepts all three forms, the web address also without `/` before `#`, the scheme and the
  domain in any case, a nested scheme (as the site does), spaces and line breaks inside; another domain, `http://`, a path
  before `#` — refused. The body and the pairing cryptography did not change (the prefix goes into neither `psk_mac` nor
  `TH`) — the appendix A vectors and the formal model are the same.
- **The secret scanner** recognizes an invite by its **body** (`<52 base32>.<52 base32>.`) with any prefix or without one
  (`antenna_proto::invite::contains_invite`), not by the prefix: a web address pasted without the scheme or retyped by hand
  is caught too; a link to the site without a body (`https://antenna.contact/#beta`) is not.
- **Why a web address.** Any messenger and email client makes a link with `https://` clickable; for a person without the
  app it opens a page with an explanation and an "Open in Antenna" button rather than an "unknown scheme" error. The secret
  stays in the fragment: the browser does not send it, and the site reads it only in the browser without external
  requests and wipes it from the address bar (`docs/SITE.md`, checked with headless Chrome). The cost: the domain becomes
  part of the format — changing the domain = one more accepted form (the body is the same).
- **Compatibility.** A preview.1 node will not join via the web address ("must start with x://pair#") — for it there is
  `antenna://pair#…` from the output. The window with `normalizeInviteLink` (2026-10-03) already accepts all three forms; a
  window client of the old contract simply shows the new link in the `link` field. Test:
  `tests/link.rs::invite_link_is_a_web_address_and_every_form_joins` (three nodes join A via the three forms; without the
  password neither `link` nor `link_app` is visible), `invite::tests`.

### D-75 · A side's agents are keys in the link, announced by a link-root message; the counter and the chains are per side
- **Decision** (SPEC §5 "sub-identities inside the link, signed by its link-root"; `docs/PROTOCOL.md` §21). Each of the
  owner's agents has its own Ed25519 key in every link (32 random bytes from the OS, the secret is in the encrypted DB, the
  daemon signs: the agent process does not see the key). The key is announced to the contact with a history message
  `control`/`agent {name, key, state}` whose `author` is the side's link-root: the ordinary message signature (§12) is
  exactly the link-root's signature over the agent's key — **there is no new cryptographic construction**. After that,
  the agent's messages have `author` = the agent's key and are signed by the same §12 with this key. The recipient accepts
  an author only if it is the link-root of one of the sides or a key announced by a side before this `n` and not revoked
  (`antenna_core::agentid::check_incoming` — one code path for delivery and resending).
- **The counter `n` and the verification chains are per side**, not per key: in the DB `messages.author` = the side's
  link-root, the agent's key is in `messages.agent_key`, the name in `messages.agent`. The summary, `chain`, the
  divergence point, rollback protection (§16–§17) and the appendix B vectors do not change; the copy check compares
  `core.author` with the agent's key and checks that the key was announced by this side. Otherwise every agent would become
  a third "author" in a two-sided verification.
- **Compatibility with `0.1.0-preview.1`** (strict CBOR, `deny_unknown_fields`: a new body or a foreign `author` — refused
  and `failed`): nodes exchange capabilities (`features`, on every new connection after `hello`); preview.1 answers
  `rejected{malformed}` (checked against the tag's sources: an unknown request → `malformed`) and is remembered as a node
  without capabilities — nothing from §21 is sent to it, agents' messages are signed by the link-root, and the agent's
  name stays only in our own history. If the contact's capabilities are not known yet (the link was just created), the
  node connects (up to 3 s) before the agent's first message to learn them; if that fails — the message goes on the
  owner's behalf (the safe side).
- **Lazily and minimally**: an agent is announced to the contact only before its first message in this link, in one
  transaction with it (the queue delivers in order). The list of the owner's agents is not disclosed in advance.
  A wake agent with the default name `wake-<label>` is announced as `wake` — in receipts (`actor`) too: the label is the
  owner's local name for the contact (before, it went to the contact in read receipts — fixed along the way).
- **What the owner sees** (x-control/5, CONTROL §17): `via_agent` in the history, events, `inbox` and the agent wrapper (for
  an agent — only in `inbox`, which sets taint: the agent's name is chosen by the contact, it is their data, like a file
  name, D-F-19; in facts without taint — `wait`, `message_fact` — there is no name);
  `peer_kind` = `human` / `agent` / `mixed` / `unknown` (the last — the contact has not written, or its node has no §21) and
  `agents` in contacts; a `contact` event when `peer_kind` changes. The trust level is per link (SPEC §9: a person and
  their agents are one contact): the contact's agent gets the link's rights and has no separate level.
- **Not done (honest):** the node does not revoke an agent's key when the agent is removed (the revocation format
  `state: revoked` is accepted and shown, but not sent; done since D-119): a removed agent writes no new messages, and a new agent with the
  same name writes with the same key — the contact sees the same name, which is correct. Files and file requests of an
  agent are signed by the link-root (an agent's file request is signed with its key since D-120) (the link-root signs the manifest, PROTOCOL §19) — they have no `via_agent`. The
  streaming display (§20) does not carry the agent's name — the final does (it does since D-119).
- **Checked:** `agentid::tests` (a real Ed25519 signature: an agent key before the announcement, an announcement not signed
  by the link-root, an agent announcing an agent, a signature for another recipient, `n` before the announcement, after
  revocation, reviving a revoked one, a foreign/own key posing as a contact's agent — refused; keys are per link);
  `tests/peer_agents.rs` — two agents and owner A → at B, who wrote (history, `inbox`, the agent wrapper, MCP facts),
  `peer_kind` and `agents`, history verification is equal on both sides, after restarting both the copy check is clean
  and the agent writes with the same key; MCP agents on both sides see each other by name; compatibility with the
  `v0.1.0-preview.1` release binaries — `tests/peer_agents.rs::legacy_*`.

### D-76 · The final of our own stream after approval — a `final` event with `stream_id`
- Found while working on the window (TROUBLESHOOTING, 2026-10-03): a deferred final (`stream_pending`) did not remember
  the stream, and after `antenna approve` our own subscribers did not get `message_stream{state: final}` — the window
  closed the bubble by the text. Now the deferred final stores `stream_id`, the next `seq` and how the source ended; after
  sending, the daemon sends subscribers `final` with `stream_id` and `message_id`, as without approval (CONTROL §15). The
  window's workaround remains as a fallback. Test:
  `tests/stream.rs::a_secret_in_the_middle_cuts_the_stream_and_the_final_waits_for_approval` (at the sender,
  `interrupted{cut}`, then `final` of the same stream with the ID of the last history message).

### D-77 · LAN via mDNS: off by default, only level 3+, link pseudonyms on the network and only when needed
- **Question** (SPEC §4, §18): "a pairwise endpoint must not expose in mDNS anything that links the links to each other —
  should the per-link EndpointId be published on the LAN at all, or only on request". The standard iroh path
  (`iroh-mdns-address-lookup` as the endpoint's `AddressLookup`) publishes every link's EndpointId all the time, with the
  relay and all addresses: an observer on the Wi-Fi sees how many links a node has, recognizes the node on another network
  by the same IDs and sees its relay/VPN addresses.
- **Decision (conservative).** (1) The mode is off by default; the owner turns it on with the password (`antenna lan on`,
  `lan_set` x-control/5), turning it off needs no password. (2) Only links to which the node has given level 3+ (the
  direct mode of SPEC §4); levels 1–2 are relay only and do not get into the LAN either as listeners or as announcements.
  (3) **The EndpointId is never published in mDNS**: the instance name is the link pseudonym
  `Ed25519-Pub(HMAC(K_lan, "x/lan/v0/beacon" ‖ E ‖ epoch))`, `K_lan` is HKDF of `link_id` and both sides' link-roots
  (PROTOCOL §22); it changes every hour and is different for each side and link — by the name it cannot be linked across
  links, networks and hours (but the link endpoint's port is constant — it can be linked by that, D-78 no. 4).
  (4) **Announcing only when needed**: there is something to deliver to the contact (or to announce ourselves after an
  unlock) and there is no connection — 2 minutes after the last attempt; once connected — withdrawn. The rest of the time
  the node only listens (queries without its own names). (5) Only local addresses (RFC 1918, link-local, loopback): no
  relay, no TXT with data, no CGNAT/Tailscale, no public IPv4/IPv6. (6) What is found is a routing hint; TLS checks the key.
  The mDNS service is the shared `irohv1` (the names do not give away Antenna; a direct connection still shows the ALPN
  `x/link/0`).
- **Why not the standard `AddressLookup`.** Its name is the EndpointId, and resolution is by EndpointId; a pseudonym would
  need a wrapper around resolution, and a permanent announcement would expose the number of links anyway. From the crate
  we use only discovery (`subscribe`) and announcement (`publish`), and dialing gets the found addresses as hints
  (`connect_raw`). The link endpoints remain `presets::Minimal` without address lookup (D-6).
- **Cost and limits (honest).** With the mode on, the listener sends an mDNS query ≈ once a second (the crate's
  `new_interactive`, τ = 0.7 s) — it is visible that the device is looking for iroh nodes. The number of simultaneous
  announcements ≈ the number of contacts that currently have something to be delivered. By connecting to an announced
  port, an observer learns the public key of the link endpoint (iroh 1.3 does not hide the server key; the same as by
  scanning UDP ports without mDNS). The contact on the other side must be listening (the mode on for both). IPv6 is not
  used on the LAN. A "trusted network" is a manual switch, not by SSID/gateway (later).
- **Along the way (found by a test):** a saved link without a reachable relay did not come up at all (20 s waiting for the
  relay for each, sequentially, then a failure and a retry on a random port) — without internet the node was useless even
  on a LAN. Now a link waits for the relay for at most 2 s and comes up without it (`transport::bind_saved`), links come up
  in parallel; pairing still requires a relay (its address is in the pairing messages).
- **Checked** (`crates/antenna-cli/tests/lan.rs`, in a separate network namespace `unshare -rn`: only `lo` with multicast,
  no internet and no relay, mDNS does not reach the server's network): the paired nodes were restarted on new ports (the
  old ones were taken) — without `lan on` a message does not arrive (negative control), after it — it arrives in ≈ 1.1 s
  from `lan on` and back; the relay disappeared — both nodes unlock in 4.6 s and find each other (delivery ≈ 1.3 s); a
  level 2 link is absent from `lan_status`. Unit: `lan::tests` (pseudonyms, the address filter).

### D-78 · Independent security review of LAN, links through the site and contact agents (2026-10-03)
An independent reviewer, read-only, commits `be7d697`, `c1b7bb2`, `d37feb6` (and `64f550b`): **no critical findings**, 1
important, 5 medium, 7 minor. Fixed (tests in parentheses):
1. **(important) A table row, not the history, made someone an "agent".** `sig_ok` of our own copy and the copy check
   trusted `link_agents`: whoever edits the open DB could replace a contact's message with one signed by their own key,
   write the key into the table — and the contact would be falsely accused of forking the history
   (`two_signed_versions`) instead of "my copy was changed". Now `sig_ok` requires a link-root-signed announcement of the
   key in our own history before this `n`, the copy check collects keys only from such announcements (with revocations),
   a message with another key is `foreign_author` in our own copy, and the table is brought in line with the history
   (`agentid::tests::a_key_in_the_table_without_a_signed_announcement_is_not_an_agent`).
2. (medium) The contact label went out in batches of check receipts (`check:*` of levels 1–2) — the wake agent's name
   (`wake`) is now substituted before batching (`wake.rs`: the contact has the label in neither `via_agent` nor `actor`).
3. (medium) The scanner missed a link broken by a space, a line break, NBSP, U+2028, " . ", although parsing accepted it —
   the scanner also searches the text with whitespace removed (`invite::tests`).
4. (medium) The LAN promise "cannot be linked across networks" was overstated (a constant port, the ALPN in the
   ClientHello) — now written honestly (PROTOCOL §22, D-77); a random link port for each network — later.
5. (medium, the reviewer's hypothesis — the mDNS flooding experiment was not run) The listener's memory grows from
   foreign names: the listener is re-created every 10 minutes, the mDNS crates log only errors; our own reply parsing —
   later.
6. A forged announcement erased the found addresses — now they are merged, freshest first, ≤ 16 (`lan::tests`).
7. `hello` without a relay (the link came up without internet) erased the contact's saved relay — the previous relay is
   kept.
8. LAN announcements — only when there are messages in the queue (not for presence at every unlock, `tests/lan.rs`: bob
   without messages is not announced); the announcement and the findings are withdrawn when the link no longer qualifies
   (level 1–2, revoke, stop).
9. `antenna invite` always printed `link_app` (with the secret) to stderr — now only to a terminal (scripts use `--json`).
10. Our own limit of 64 agent keys per link (beyond that, the link-root signs); an announcement taken off the queue as
    `failed` forgets the key — otherwise all of the agent's following messages would get `unknown_author`.
11. An agent's messages displaced after a rollback are sent again from the same agent.
12. `peer_kind` is cached in the link (before — a pass over the messages under the DB lock for every incoming message).
13. The name `owner` is reserved for an agent (that is what receipts call the owner).

**Not fixed (recorded):** agent names are the same for the whole node (contacts can compare and link the owner by a rare
name; the owner chooses); `peer_kind: human` is not proof (the contact decides what to sign with); all private addresses
are announced, including VPN and Docker; DoS by mDNS flooding — mitigated, not removed (a flooding experiment is a
maintainer decision).

## Releases on our own runners (2026-10-03)

### D-81 · macOS jobs on a self-hosted runner; Linux release files built outside GitHub Actions
- **Context.** The Actions minutes included in the repository's GitHub plan for 2026-10 are used up, so GitHub-hosted
  jobs do not start again until 2026-11-01. `v0.1.0-preview.2` is not published yet: its first CI runs failed on two
  test bugs that are fixed on `main` (TROUBLESHOOTING "Release `v0.1.0-preview.2` on GitHub runners"). Jobs on
  self-hosted runners do not use the plan's minutes.
- **Maintainer decision.** (1) The macOS jobs run on a **self-hosted runner**, an Apple Silicon Mac registered to this
  repository with the extra label `antenna`. (2) The **Linux release files are built and checked on our Linux build
  server outside GitHub Actions** and uploaded to the same release.
- **`release.yml`.**
  - `version`, `core` (arm64), `macos` and `publish` take `runs-on` from the repository variable `MAC_RUNNER` (a JSON
    value); unset, it is `["self-hosted","macOS","ARM64","antenna"]`. The Intel check of `core` (manual, `intel`) stays
    on GitHub's `macos-15-intel`.
  - `linux` runs only when the repository variable `LINUX_ON_GITHUB` is `'true'`. Otherwise `publish` (still only on a
    tag, only when `version`, `core` and `macos` succeeded) creates the release as a **draft** with the macOS files, and
    the notes say that the Linux files follow (`LINUX_PENDING=1` for `packaging/release-notes.sh`).
  - Back to GitHub-hosted runners without editing the file: `MAC_RUNNER='"macos-14"'`, `LINUX_ON_GITHUB='true'`.
  - What a persistent runner needs: `actions/checkout` with `clean: false`, then `git clean -ffdx -e /target/` (target/
    survives between runs, a stale `dist/` or `build/` does not); the Cargo cache action only on GitHub-hosted runners;
    `brew install` only for what `brew list` does not have, with `HOMEBREW_NO_AUTO_UPDATE`; Flutter in its own checkout
    in the runner's tool cache, reused or moved to the pinned tag (not `~/flutter`, which on a desktop Mac may be the
    user's own); `/opt/homebrew/bin` and `~/.cargo/bin` added to `PATH`; `gh` installed if missing; `shasum -a 256`
    (present on macOS and Linux) for `SHA256SUMS.txt`. Steps that would act on the desktop session are limited: the
    D-P-3 GUI host test (it opens Calculator and kills whatever process has that name) runs only on GitHub-hosted runners;
    the `PT_DENY_ATTACH` check is skipped when developer mode is off (`DevToolsSecurity`), where an `lldb` attach would
    wait for a password on screen. Run artifacts are kept 7 days (the release holds the files; artifact storage is
    limited).
- **`packaging/release-linux.sh <tag>`** does the `linux` job's work on the build server: core tests (fmt, clippy, all
  tests, `mcp_smoke`), the window against the built `antennad` (analyze, widget and live tests, goldens), both archives
  with `build-tarball.sh`/`build-desktop.sh`, and `check-install.sh`/`check-desktop.sh` (Xvfb required). It builds from a
  temporary `git worktree` of the tag (never from a working tree), removes it with its `target/` on exit, runs niced with
  `CARGO_BUILD_JOBS=8`, and checks the tag against Cargo.toml, `pubspec.yaml` and the tag on GitHub. Then it uploads the
  archives to the draft, recomputes `SHA256SUMS.txt` over all files as GitHub serves them, regenerates the notes with
  the tag's `release-notes.sh`, and publishes (`--prerelease` for versions with a `-`). `--no-upload` is a dry run;
  `--publish-only` uploads already built archives (for when the build finished before the draft existed); `--ref` builds
  another revision as if it were the tag, for dry runs only. Missing system tools are reported, never installed.
- **Checked.** `actionlint` 1.7.12 (with shellcheck 0.11.0) reports nothing for `release.yml`; shellcheck is clean for
  `release-linux.sh` and `release-notes.sh`. A dry run on the build server, `release-linux.sh --no-upload --ref main
  v0.1.0-preview.2` (commit 9d5b85d, from scratch): 17 min 36 s in total; clippy 3 min 40 s, core tests 6 min 27 s (342
  passed, 0 failed, 6 ignored), window analyze and tests 41 s (166 passed), the core release build and archive 5 min
  52 s, the Linux window 48 s, `check-install.sh` and `check-desktop.sh` (with the Xvfb launch) passed; the temporary
  worktree and its 12 GB target/ were removed. The error paths (`--ref` without `--no-upload`, a missing tool, a
  missing archive for `--publish-only`) stop with a message. Not run yet: the workflow on the self-hosted Mac, and the
  upload and publish half of the script (it needs the draft).
- **Security boundary.** The runner serves only this private repository and must never be attached to a public one (a
  pull request from a fork could run code on it). The workflow has no `pull_request` trigger: only tag pushes and manual
  runs by people with write access start it. Jobs run as the Mac's user account.
- **Why.** Releases do not wait for the plan's minutes; the full Linux checks already run on the build server during
  development, and it is the same distribution as the CI image (Ubuntu 24.04); building from a clean checkout of the
  tag keeps the result independent of the server's working trees.
- **What it costs.** A release needs both machines online: until the Mac picks the jobs up they wait in the queue (GitHub
  fails a job queued for more than 24 hours), and until `release-linux.sh` runs the release stays a draft. The Linux
  files are no longer built on a fresh GitHub image, so the build server's toolchain has to match: Rust comes from
  `rust-toolchain.toml` through rustup, the script stops unless Flutter is the version pinned in `release.yml`, and the
  system packages are the server's.

## Signed releases and `antenna update` (2026-10-03)

### D-82 · Signed release manifest, pinned release keys, `antenna update` with rollback
- **Context.** SPEC §12 lists `antenna update`, SPEC §13 requires a release signing key built into the binary and an
  update only on the owner's command, SPEC §15 lists "substitution of the update channel". `0.1.0-preview.1` answered
  "not implemented". Maintainer decision: the loop "an installed version receives a newer one, verifies it and replaces
  itself" must be in `0.1.0-preview.2`, so that the step to `preview.3` can be tested on a real Mac.
- **Decision.** The format and the steps are `docs/UPDATES.md`; in short:
  1. **A signed release manifest** `antenna-<version>-manifest.json` (version, channel, created, commit; per asset name,
     OS, architecture, kind, size, SHA-256, BLAKE3) and a detached signature file `…-manifest.json.sig`: Ed25519 over
     `"antenna/release-manifest/v1" ‖ 0x00 ‖ <the exact file bytes>`, one entry per key. No custom cryptography:
     `ed25519-dalek` (`verify_strict`), `sha2`, `blake3`, keys from the OS CSPRNG through `rand`; minisign-style crates
     that carry their own Ed25519 code were not taken. BLAKE3 is listed next to SHA-256 so that a file received over
     Antenna (whose transfer shows its BLAKE3) can be matched to the manifest while it is still in quarantine.
  2. **Pinned keys as a list** (`antenna_update::keys::RELEASE_KEYS`), for rotation; a release may be signed by any of
     them. Until the release key exists the list is empty and every update is refused (`no_release_key`). The test key
     has a public seed; only debug builds compile the code that trusts it, and only with `ANTENNA_UPDATE_TEST_KEY=1`.
  3. **Tools.** `crates/antenna-update` (format, verification, installer) and `crates/antenna-release` (`keygen`,
     `manifest`, `sign`, `verify`), both AGPL-3.0-only; the format document is Apache-2.0. `packaging/release-linux.sh`
     signs every release on the build machine (`ANTENNA_RELEASE_KEY`) and checks the signature against the keys pinned
     in that very release before publishing; the workflow always creates a draft, so the key never goes to CI.
  4. **`antenna update`** in the owner CLI only (not in the agent CLI, not in MCP: rule 2): `--from` (a folder or the
     files) with `--dry-run` / `--manifest-only`, the install, `--rollback`, `--check [--url] [--download]`. Strictly
     newer versions only (SemVer precedence; `--allow-same` is honored by debug builds only). The daemon authorizes an
     install with the new owner command `update_authorize` (password or owner session; CONTROL §19) and reports its PID
     and executable; the CLI does the update itself, because the daemon is one of the things being replaced.
  5. **Installing.** A locked staging folder next to the installation; the asset is copied there and checked again; the
     new version is checked before anything installed is touched (macOS: `codesign --verify --deep --strict`, bundle ID,
     `CFBundleShortVersionString`, the bundled binaries' `--version` equal to the manifest's version and commit;
     Linux: the binaries' `--version`); a journal; the window closed and the daemon stopped the way it is kept
     (LaunchAgent / systemd user unit); atomic swaps (`renamex_np(RENAME_SWAP)` / `renameat2(RENAME_EXCHANGE)` through
     `rustix`, no new `unsafe`); the old version kept as `.previous`; the daemon started again and required to answer
     with the new version within 30 s, otherwise the old version is swapped back. After a restart the keys are locked.
  6. **Interruptions.** Identity by device and inode, recorded in the journal before the first change: a failure puts
     the old version back at once, a crash is undone by the next `antenna update`.
  7. **`--check`** uses `curl` (HTTPS only, also for redirects) to keep an HTTP stack out of the CLI; the URL comes from
     `--url`, `ANTENNA_UPDATE_URL` or `~/.config/antenna/update-url`. There is no built-in URL while the repository is
     private.
  8. **Updates received over Antenna.** Checked how the real release files are classified today (the `preview.1`
     files through the sandboxed check): the `.dmg` is `suspicious` (`unknown_type`, `no_safe_preview`; since D-F-25 the
     type is known: `disk_image`, still `suspicious`), the CLI
     `.tar.gz` archives are `suspicious` (`executable_entry` for `install.sh`, and `secret:*` findings from strings in
     the binaries), the manifest and `SHA256SUMS.txt` are `clean`. Nothing is a threat, so nothing is refused to the
     contact or deleted: at level 2 and above the files wait in quarantine for the owner (an agent cannot accept a
     suspicious file), at level 1 no files arrive (as for any file). So **no special path was added and no check was
     weakened**: the owner accepts the files (level 2+, owner only), and `antenna update --from` checks the signature.
     The window marks an accepted release manifest that verifies, with "Install", and can label a quarantined file
     whose BLAKE3 matches a verified manifest. For this, accepted files carry `saved_path` in owner replies (CONTROL
     §14). Sending a release file needs the sender owner's approval (the secret scanner flags strings in the binaries),
     as for any file with such findings.
- **Why this way.** The signature is the only thing that decides; who delivered the files, their names and the channel
  do not matter, so one mechanism covers a download, a USB stick and a file from a contact. A single signed manifest
  over all files (instead of a signature per file) keeps one place for versions and hashes and matches `SHA256SUMS.txt`.
  Keeping the previous version next to the installed one makes the rollback a swap, not a reinstall.
- **Checked.** `cargo test -p antenna-update` (manifest, signature: valid, wrong key, tampered manifest, tampered asset,
  wrong platform, downgrade, same version, no key; the installer against a fake macOS and systemd: install, rollback,
  a daemon that does not come up, failures at every step, a crash and the recovery, one update at a time; a documented
  test vector also verified with Python `cryptography` and `openssl pkeyutl`); `cargo test -p antenna-release`;
  `crates/antenna-cli/tests/update.rs` (two versions in the `install.sh` layout with a real daemon: refusals that change
  nothing, a dry run, the install, a restart, a rollback, an error and a crash in the middle); `tools/check-darwin.sh`.
  **Not checked yet:** the macOS path on a Mac (`packaging/macos/check-update.sh` runs it on a throwaway app copy; the
  LaunchAgent restart and the window relaunch need a person with a real install).
- **Open.** SPEC §13 asks for two independent keys per release; the format carries several signatures and the threshold
  is one constant (`REQUIRED_SIGNATURES = 1`): who holds the second key is the maintainer's decision. The public update
  URL waits for public releases. The Linux window bundle cannot update itself yet.

## Approvals housekeeping (2026-10-03)

### D-84 · Refusing needs no authentication; an unanswered request closes by itself (maintainer decision)
- **Context.** A live test with a build agent on a second Mac, driven over Antenna: expired approval requests stayed in
  the window's list, dismissing each one asked for the owner password, and nothing in the conversation showed that a
  request was waiting, so both sides looked silent. Maintainer decision: dismissing must not need authentication,
  expired requests close by themselves, and a pending request must be visible where the owner looks; the prompts
  doubled the work.
- **Decision.**
  1. **`deny` needs neither the owner password nor an owner session**, like `lock` (CONTROL §11 item 9). Only
     approving needs the password, every time. Refusing can only reduce what happens: a request that is not approved
     does not run, and "deny for an hour" only adds refusals. `deny` stays an **owner** command: an agent's connection
     (a token, or a process in a bound agent's tree, D-28) parses requests as `AgentRequest`, which has no `deny`
     (`unknown_command`), MCP has no such tool, and the agent CLI has no such command. The `password` field is
     optional and ignored, so older clients that send it keep working; `antenna deny` still accepts a hidden
     `--password-stdin` (the line is read and dropped) for scripts written against older versions.
  2. **An unanswered request closes by itself.** A sweep every second marks pending (and approved but unused)
     requests whose 10 minutes ran out as `expired`, sends the `approval` event with `state: "expired"` to the owner's
     subscriptions and to the requesting agent, and writes a local `approval_expired` record to the audit log of the
     contact's link (actor: who asked). Nothing goes to the contact: shared-history receipts keep their closed
     vocabulary (D-52), so preview.2 nodes see nothing new. Approving, denying or using an expired request gives
     `approval_expired`. A stream final held for the request (D-70) is dropped at once when the request is denied or
     expires, instead of staying in memory until its time runs out.
  3. **Where a request is shown.** `ApprovalInfo` gains `link_id` and `target_link_id` (optional fields, for all
     control versions), so a client can put the request into the conversation it concerns without matching labels.
  4. **No "dismiss all expired".** With expired requests closing by themselves, the pending list never holds one; the
     decided and expired ones stay visible for an hour in `approvals --all`, as before.
  5. **Tests only:** `antennad --approval-ttl-ms <ms>` (hidden) shortens the request lifetime so that an end-to-end
     test sees a request expire; it can only shorten the 10 minutes of SPEC §9, never lengthen them.
- **Why this way.** The authentication that matters guards what makes something happen (approve, trust, invite). A
  refusal asked for the same password as an approval, so the owner paid for safety twice and was trained to type the
  password without reading. Without a session, a same-uid process can deny only requests whose 40-bit random ID it
  knows (the owner's list or its own request), and the worst it achieves is that an agent's action does not happen.
- **SPEC.** SPEC §9 lists `approve` among the commands that need local authentication and does not list `deny`; SPEC §12
  puts `approve` and `deny` in one row and says commands not available to agents require local owner authentication.
  This decision refines §12 for `deny`: it is still not available to agents, but it needs no authentication.
- **Checked.** `crates/antenna-cli/tests/control.rs::approval_requests_expire_by_themselves_and_deny_needs_no_password`
  (real daemon with a 4 s lifetime: the owner's and the agent's subscriptions get `expired`, the pending list is empty,
  `--all` and the audit log keep it, late approve/deny/use give `approval_expired`; deny without a password from a
  connection without a session, approve without the password refused, an agent's `deny` is `unknown_command`; the CLI
  without a session or terminal denies without asking); negative control: without the sweep the test fails waiting
  for `expired`. Unit tests: `policy::tests::expired_requests_close_by_themselves`,
  `approval_lifetime_only_shortens`; `antenna_proto` `deny_needs_no_password_or_session`.

### D-UI-15 · A pending approval is shown where the owner looks: in the conversation, in the list, as a notification
- **Decision.**
  1. **A card in the conversation.** A pending request **from an agent** stands at the end of the conversation with the
     contact it is about and, for a send, with the recipient: "Waiting for your approval", "<agent> wants to <action>
     → <recipient>", the structured permissions and the request text as a quote (the same facts as in the list, SPEC
     §9: an approval is never blind),
     **Approve** (password; "Approve", not "with Touch ID", until that exists) and **Deny** (no password), "Details"
     opens the full list with "deny for an hour". Layout and buttons follow the reference v3 (style, not a pixel copy;
     primary solid brand blue, secondary neutral with a 1 px border, destructive red text, radius 8, visible hover,
     pressed and focus); the rest of the window keeps its look until the polish pass. The owner's own requests are
     not repeated there: their bubble or file card already has "Approve and send".
  2. **The list and its counter stay** at the top of the link list. Deny there needs no password either; if the daemon
     is older than D-84 and answers `bad_request` for the missing password, the window asks for it and retries.
  3. **A system notification** when a new request from an agent arrives (a subscription event, not a re-read; "quiet"
     requests excluded, as SPEC §9 requires) and the window is not in focus (`AppLifecycleState` other than `resumed`:
     both the macOS and the Linux embedder report focus loss as `inactive`). Facts only: "Antenna: approval needed",
     "<agent> is waiting for your approval: <action> → <recipient>"; the agent's name and the contact's label are the
     owner's own, and the request text is never in it (SPEC §11, it may show on a locked screen). Linux:
     `org.freedesktop.Notifications.Notify` on the session bus through the pure-Dart `dbus` package (MPL-2.0, already in
     the app through `desktop_drop`; now a direct dependency); macOS: `osascript` `display notification`, the texts
     passed as script arguments. No plugin and no native code, so nothing new to build or sign.
  4. **Expired requests leave the window** on the daemon's `expired` event; a timer re-reads `approvals` shortly after
     the earliest expiry (an older daemon, a missed event), and a late decision answered with `approval_expired` drops
     the card.
  5. **Connecting an agent** says on the form and on the result screen that the agent sees only messages that arrive
     after it is connected (D-30, a privacy property) and how to give it an earlier one: paste it into the agent's
     session, or ask the contact to send it again.
- **Why.** The owner looks at the conversation and at the system's notifications, not at a separate list; a request
  nobody sees expires, and both sides go silent. A native notification framework would need a plugin or Swift code that
  can only be built and checked on a Mac; the two system tools need neither.
- **Checked.** `test/widget/approvals_test.dart` (8 tests: deny without a password and approve with it; an older daemon;
  expiry; which conversation shows a request; the card, also in Russian; the notification only out of focus, facts
  only, once; the "Connect an agent" note), `test/host/notifier_test.dart` (a real D-Bus round trip through an in-process
  bus with a stand-in notification service; the osascript command), the live
  `test/protocol/live_approvals_test.dart` (real `antennad` with a 3 s lifetime), golden `33_approval_in_chat(_ru)`.
  **Not checked yet:** the macOS notification on a real Mac (how macOS 26 attributes `osascript` notifications).

---

## Code mode: agents run in the window (2026-10-03)

### D-83 · Connecting an agent takes one click: the window starts the agent's CLI in its own terminal (maintainer decision)
- **Context.** Maintainer decisions of 2026-10-03, after building `preview.2` with a Claude Code agent on a second Mac:
  the conversation lived in the Antenna window and the agent in a separate Terminal window; connecting it meant copying
  a token and `claude mcp add …` into the terminal by hand. "Connecting an agent must take one click", "the terminal
  should be built into the window", and a person with several agents should run them all from one window. Two interface
  modes: Chat (conversations only, the default) and Code (for developers).
- **Decision.**
  1. **"Start agent"** in the window: pick an agent (or create one), the program (Claude Code, Codex, an own command)
     and the working folder. The window gets the agent's token through the owner flow, with the owner password checked
     by the daemon: `agent_add` for a new agent, the new owner command **`agent_token`** for an existing one (CONTROL §4:
     a new token, the old one stops working at once; links, data label, session and process binding stay; refused for
     a link's wake agent, which gets a new token for every run inside its sandbox). The window keeps the token in memory
     for Restart and drops it on lock, sign-out and when the daemon stops.
  2. **The token goes only into the environment of the agent's process tree** (`ANTENNA_AGENT_TOKEN`), never into an
     argument (arguments are readable by every user through `ps`), never shown, copied or written to disk. The Antenna
     MCP server is given on the command line of this one process: Claude Code `--mcp-config '{"mcpServers":{"antenna":…}}'
     --strict-mcp-config` plus the Antenna hooks in `--settings` (CONTROL §5: the daemon decides on every tool); Codex
     `-c mcp_servers.antenna.command=…`, `args`, `env = {}`, `env_vars = ["ANTENNA_AGENT_TOKEN", "ANTENNA_SOCKET"]`
     (Codex starts MCP servers with a clean environment). The user's own Claude Code and Codex settings are not touched.
     `--strict-mcp-config` makes the window's session use only the Antenna server: a user's own `antenna` entry with an
     old token cannot start a second, differently bound server in the same tree.
  3. **The process tree stays the boundary (D-28, D-P-3, D-P-10).** A terminal's first process is a session leader, and
     a session leader never becomes an anchor. So the terminal runs a small bash wrapper as its session leader, which
     forks the agent (never `exec`): the agent is the wrapper's child, `antenna mcp` binds the token to the agent, and
     every process the agent starts is that agent for the daemon, with or without the token. The window, an ancestor of
     the agent, stays the owner. The wrapper also closes descriptors the window would pass on, changes to the folder,
     and reports the agent's exit code to the terminal.
  4. **Lifecycle.** Status (running, exited with code N, stopped); Restart and Stop; Stop sends SIGHUP to the terminal's
     process group, as closing a terminal window does, then SIGKILL after 3 s. Closing the window with agents running
     asks first ("Stop and quit" / Cancel) and stops them; if the window dies, the kernel hangs up the terminal and the
     agents get SIGHUP. One agent runs at most once (the daemon's binding allows one host per token); an agent bound to a
     live process elsewhere is not given a new token, the window says where it runs.
  5. **Code mode.** A switch in Settings → Interface: Chat / Code. Chat stays the default for new users; an owner who
     has agents is offered Code once (a banner; the answer is remembered in `window.json`). "Connect" next to Claude
     Code or Codex in Agents → "Detected on this computer" starts the agent and switches to Code mode. Apps the window
     cannot connect yet (Claude Desktop, Cursor) are listed as found, with "Coming soon", never with a Connect button.
     *Revised 2026-10-04 (D-85): Agents → AI apps connects Claude Desktop, Cursor and the other apps; "Coming soon" is
     gone.*
  6. **Role preset** for new agents: "Assistant with access to my projects" (data label 5) or "Front desk: messages
     only" (data label 0), chosen in Agents or Settings → Agents and stored in `window.json`. Until the owner chooses,
     nothing is preselected (Q-15 stays: the label is the owner's explicit choice).
- **Why.** The friction was copying secrets between windows, not the protocol: the daemon already identifies an agent
  by its process tree, so a window that starts the agent itself can hand over the token through the environment of
  that tree alone. Command-line MCP configuration keeps the change local to one process and leaves the user's own
  configuration as it was.
- **Checked.** `crates/antenna-cli/tests/agents.rs::agent_token_replaces_the_token_and_keeps_the_agent`
  (wrong password changes nothing; the old token fails at once; label and links stay; the wake agent is refused);
  `agent_has_no_owner_api_…` now also covers `agent_token` (CLI, protocol, MCP). Window: `test/host/agent_launch_test.dart`
  (no secret in the arguments; the wrapper forks, closes two-digit descriptors, keeps the exit code, refuses a missing
  folder with 126), `test/widget/code_mode_test.dart` (15 scenarios on a fake daemon and a fake terminal), the live
  `test/protocol/live_code_mode_test.dart` on Linux (real `antennad`, real pseudo-terminal: the output reaches the
  terminal within ≈ 0.2 s; the agent's shell has only descriptors 0–2; `antenna --json session` with the injected token
  answers as the agent; `antenna mcp` binds to the agent's process, the wrapper's child, and not to the session leader;
  the window stays the owner; Restart binds again without a password; Stop leaves no process of the terminal's session;
  the exit code survives the Dart VM reaping the child; negative control: `antenna mcp` under the session leader itself
  is refused with `forbidden`), and the same with the real Claude Code 2.1.233 (the MCP server binds to `claude`; the
  token is in its environment and not in its arguments).
- **Limits.** The token is a bearer secret in the environment of the agent's processes (as in a host config, CONTROL
  §11 item 3, but not on disk); a process of the same uid that is not in the tree can read `/proc/<pid>/environ` on Linux
  (the same uid could read a config file too). Code mode needs the agent on the same computer as the daemon (a forwarded
  socket cannot bind a process tree). macOS is built and tested on a Mac separately.

### D-UI-16 · Code mode in the window: the terminals' dock, the packages, Settings sections
- **Decision.** `xterm` 4.0.0 (terminal widget) and `flutter_pty` 0.4.2 (pseudo-terminal), both MIT (STACK "Code mode").
  In Code mode the navigation shrinks to icons, the chat list to 300 px, and the agents' terminals sit in a dock on the
  right of every section: one tab per agent, a status line with Restart / Stop, resizable by dragging its edge (the
  conversation keeps at least 500 px), foldable to a strip. The terminal is dark in both window themes (Claude Code and
  Codex draw for a dark terminal); copy and paste are Cmd+C / Cmd+V on a Mac and Ctrl+Shift+C / Ctrl+Shift+V on Linux,
  so Ctrl+V and Ctrl+A reach the program. Settings get a section list on the left (General, Interface, Network,
  Security, Agents, Advanced) after the maintainer's reference v3.
- **Why.** The conversation, the chats and the agent's terminal must fit next to each other on a laptop screen; the
  window theme is kept for everything around the terminal.

---

## Connecting AI apps (2026-10-03…04)

### D-85 · AI apps connect in one click, each as its own agent, after the owner sees what is written (maintainer decision)
- **Context.** Maintainer decisions of 2026-10-03: the point of Antenna is a bridge between the AI apps of different
  companies, inside their subscriptions, not through API keys; the list of apps had no ChatGPT, Codex must be named so
  that people understand it is OpenAI's, every other AI app needs an instruction a beginner can follow ("step 1, step
  2"), and ideally a button that opens the app, where the owner confirms and the agent is connected. Then, after a live
  incident (a "Connect an agent" command with the token inside was pasted into a ChatGPT chat): configs must hold a
  token file's path, never the token. And: the owner must see at a glance whether an app is really connected, and which
  AI each agent is.
- **Decision.**
  1. **Agents → AI apps** lists every app the window knows (`docs/CONNECT-APPS.md`, sources checked 2026-10-03), found
     ones first: ChatGPT, Codex ("Codex by OpenAI · with your ChatGPT plan"), Claude Desktop, Claude Code, Gemini CLI,
     Cursor, VS Code, Devin Desktop (formerly Windsurf), Zed, LM Studio, Grok Build. Each row has its status (D-89) and
     its best action.
  2. **Connect** creates the app's own agent (`chatgpt`, `claude-desktop`…; an existing one gets a new token) through
     the owner flow with the password asked once, with a token file (D-86) and, when the owner changes it, whose
     messages are tasks (D-88). Then the window shows exactly what it will write and where (or which install link it
     opens) and acts only on the owner's click. Routes, by what the vendor documents: write the app's MCP file (ChatGPT
     and Codex share `~/.codex/config.toml`; Claude Desktop, Gemini CLI, Devin Desktop, Grok Build), or open the app's
     install link where the app is found here (Cursor, VS Code, LM Studio: the app shows the server and asks to
     confirm; the link carries only the token file's path). Not found: the file instead. **Start in Code mode** for
     Claude Code and Codex (D-83). **Guide** for the rest (Zed) and as the manual way for every app: numbered steps
     with copy buttons.
  3. **Editing a file**: a backup next to it (`<file>.antenna-backup-<time>`, at most 0600) before any change; only
     Antenna's entry (`antenna`) changes; JSON is parsed strictly and a file with comments or an unexpected shape is
     never rewritten (the guide instead); Codex's TOML is edited line by line inside Antenna's own table, and a server
     defined another way is not guessed at; a file that changed after the review is shown again, not overwritten.
  4. **Disconnect** removes the entry (after a backup) and revokes the agent (`agent_remove`, which deletes the token
     file).
  5. **Claude Code** gets no user-level connection from the window: its own config is its state file, and Antenna's
     hooks at user level would block every tool in sessions where Antenna's server is not bound. Code mode passes both
     for one session.
  6. **Claude Desktop** is connected through its documented config file, not a desktop extension (`.mcpb`): whether
     Claude Desktop accepts a bundle whose command is an absolute path outside it is not verified (open question).
- **Why.** The friction was never the protocol; it was copying secrets between windows and guessing each app's
  format. One agent per app gives each its own token, permissions and status, and a revocation that touches nothing
  else. Writing only after the owner has read the exact entry keeps the owner in charge of other programs' settings.
- **Checked.** `test/host/mcp_config_test.dart` (each vendor's shape and path; other entries untouched; JSON with
  comments refused; TOML byte for byte; links decode to the entry; Codex's TOML validated against the relevant parts of OpenAI's published
  schema and Gemini CLI's settings against Google's, with Python `jsonschema`), `test/widget/ai_apps_test.dart` (14
  scenarios on a fake daemon, file system and launcher: every route, backups, an older daemon, a changed file,
  Disconnect, tasks), the live `test/protocol/live_connect_test.dart` (a real daemon: the token file, the generated
  Claude Desktop entry started as an app starts it is a bound MCP server, status, tasks, Disconnect).
- **Limits.** One token binds to one MCP host at a time (D-28): two apps that share a file (ChatGPT and Codex), or one
  app that starts a server per window, get one working server at a time. The apps themselves are checked on a real Mac
  separately (`docs/CONNECT-APPS.md`, "What still needs a real Mac").

### D-86 · Agent token files: written by the daemon, read like an ssh key
- **Decision.** `agent_add` and `agent_token` take `token_file: true`: the daemon writes `<data-dir>/agents/<name>.token`
  (folder 0700, file 0600, `xat_…\n`, a temporary file with `O_EXCL` then a rename) and returns its path in
  `agent_added.token_file`. `agent_token` always rewrites an existing file, so an app that names the file follows a new
  token; `agent_remove` deletes it; `agent_reset` keeps it; `agent_add` without the flag removes a stale file of the same
  name. `.` and `..` cannot name a file. The agent CLI reads a token from `--token-file <path>` or
  `ANTENNA_AGENT_TOKEN_FILE`; first match wins: `--agent-token` / `--token-file`, then `ANTENNA_AGENT_TOKEN`, then
  `ANTENNA_AGENT_TOKEN_FILE`. The file is opened without following a symlink and must be a regular file owned by the
  user, without group or other permissions, at most 4 KiB, holding a token; otherwise `token_invalid` (exit 77) with the
  fix. CLI: `antenna agent add|token … --token-file` prints the path (the token only with `--json`). The window issues
  every token with a file and shows the file, never the token; with a daemon older than this it shows the token once,
  with "Paste this only into the app's settings, never into a chat. The AI does not need to see it." and "Revoke and
  create a new token".
- **Why.** App configs get synced, shared and pasted into chats; a path leaks nothing useful. It is also the only form
  every app passes through: Gemini CLI drops `*TOKEN*` variables, Codex forwards only listed ones, Claude Desktop "a
  limited subset". The ssh rules refuse the mistakes that would widen access (a world-readable copy, a symlink pointed
  elsewhere).
- **Limits.** The file is readable by any process of the same uid, like a config (CONTROL §11 item 3).
- **Checked.** `agents.rs::agent_token_file_is_written_by_the_daemon_and_read_like_an_ssh_key` (modes, rewrite,
  removal, `antenna mcp --token-file` and the variable binding like the env token, a 0644 file, a symlink, another
  owner, garbage refused).

### D-87 · `share_file_content`: an agent sends a file by its bytes, through the `share_file` path
- **Decision.** An agent command and MCP tool `share_file_content {contact, name, content_base64, approval_id?}` (the
  control dialog: `size`, then `data` input frames ≤ 96 KiB raw and `end`, so `MAX_LINE` stays 256 KiB). Limit:
  `antennad --share-content-max-mib` (env `ANTENNA_SHARE_CONTENT_MAX_MIB`), 25 MiB by default, 0 turns it off;
  `too_large` before any data. The bytes go into a staging file of the data directory whose name is removed at once,
  then through exactly the `share_file` pipeline: sandboxed sender-side check, encryption, signed manifest, the level
  policy (level 1 no, level 2 approval), no-write-down and cross-link flow, secrets and threats to approval, receipts
  (action `share_file`), quarantine at the receiver. The one difference: no "file outside the link folder" reason,
  because the bytes are the agent's own output handed over by value, like the text of `send`. The approval binds to
  (contact, name, BLAKE3). Owner commands still do not exist for agents.
- **Why.** `share_file` takes a local path, so an agent whose output lives in its vendor's cloud (an image ChatGPT
  made) could not send it. Base64 in a tool argument is the only file input every MCP client supports today (the
  specification has none; WATCHLIST W-22).
- **Limits.** The model writes the base64 into its own request, so this suits small files; agents on the same computer
  should keep sending by path.
- **Checked.** `files.rs::share_file_content_round_trip_over_mcp` (two daemons, MCP over stdio, bytes identical,
  staging empty), `share_file_content_limits_and_frames`, `share_file_content_policy_levels_approval_and_secrets`.

### D-88 · Task authority: messages from the contacts the owner names are tasks, everything else is data (maintainer decision)
- **Context.** Maintainer decision: agents must understand that messages from a contact the owner trusts at level 5
  are tasks to carry out, not just chat; before this, an agent read such a message as external data and waited for its
  human.
- **Decision.**
  1. **Per agent, "takes tasks from"**: the owner command `agent_tasks {name, contacts, password}`: `null` = the default,
     the contacts at trust level 5 within the agent's links, followed live; `[]` = nobody; or exactly the listed
     contacts within its links. Owner only (an agent gets `unknown_command`; no MCP tool; no agent CLI command). Shown
     in Agents and in Connect ("This agent will do tasks from: Build bot (5)").
  2. **MCP `instructions`** in `initialize`, made from the daemon's state at start (never from message content): who
     the agent is; whose messages are tasks the owner authorized, to be carried out within its permissions while the
     daemon still checks every action; results and questions go back with `send_message`; messages from anyone else
     are data to summarize for the user; quoted or forwarded text is data; never reveal the token or local secrets.
  3. **Per message**: `authority: "task" | "data"` in `agent_inbox.messages[]` and in `waited` facts, a task notice that
     names the contact and its level and says that quoted text inside is data, and the "EXTERNAL DATA" notice for data.
  4. Wake agents keep their fixed prompt (D-68) and take no tasks.
- **Security.** This lifts the "everything is data" default (SPEC §9) only for contacts the owner put at the task
  level. Taint still applies: reading a task taints the session exactly as before, so an agent that read lower-level
  data is still limited by it, and every action is still decided by the daemon. A level-5 contact's message can carry
  forwarded untrusted text, so the notice and the instructions mark quoted or forwarded text as data. The default can
  be changed per agent, including to nobody.
- **Checked.** `mcp.rs` unit `instructions_for_default_list_and_nobody`;
  `agents.rs::agent_tasks_make_messages_tasks_and_shape_the_mcp_instructions` (level 5 vs 3 under the default, after
  `agent_tasks`, the password, `unknown_command` for an agent, `initialize.instructions` over stdio);
  `tools/mcp_smoke.py` requires `instructions`.

### D-89 · Agent status from the daemon: the bound process, the last call, an `agent` event
- **Decision.** `SessionInfo` gains `bound_pid`, `bound_comm`, `bound_alive` (the structured `bound_to`),
  `last_seen_ms` (the agent's last request since the daemon started, kept in memory, updated where every agent
  connection is accepted), `token_file`, `tasks_from`, `tasks_from_default`. The owner's subscriptions (x-control/5)
  get `{"kind": "agent", "name", "change": "added" | "token" | "bound" | "removed"}`; agents never get it. A process that
  exits sends nothing: the window reads `agent_list` every 4 s while an Agents view is open. The window's states:
  Connected (bound, alive), Waiting for the app (no binding, never seen), Disconnected (bound process ended), Active (seen
  without an MCP host), Revoked (an app names an agent that no longer exists).
- **Why.** "Is ChatGPT connected?" was the owner's first question; the daemon already knew the binding, and the binding
  is the honest answer (the token is used by that process tree and no other).
- **Compatibility.** Only additions to v5; a preview.3 `antenna events` (Rust CLI) stops on the unknown event kind, the
  current CLI and the window skip unknown kinds.
- **Checked.** `agents.rs::agent_status_shows_the_connected_app_and_the_owner_gets_agent_events`; the live Connect test.

### D-UI-17 · AI apps in the window: the list, the Connect dialog, statuses and marks
- **Decision.** Agents opens with the **AI apps** card (reference v3: a mark tile, the name, "on this computer", a
  status chip with a dot or a check, the app's line as people know it, the status detail, one action, a ⋯ menu with the
  guide, "Takes tasks from…" and Disconnect), then the agents (each with its status chip and whose tasks it takes),
  then the role preset. Connect is one dialog in three steps (set up with the password, review, done with the live
  status); the guide is the same dialog. **Marks**: shown only where the owner's guidelines allow referring to the
  integration (Claude, Claude Code, Cursor, Zed, LM Studio, from Simple Icons 16.33.0, in their own colours, white on
  dark where the owner provides it); a neutral monogram for OpenAI, Google Gemini, VS Code, Devin Desktop and xAI
  (`docs/CONNECT-APPS.md`, "Marks"; `apps/antenna_desktop/assets/logos/`). The marks are drawn from their SVG path data
  (`lib/theme/svg_path.dart`, generated `lib/theme/ai_logos.dart`): no SVG package, the same pixels everywhere. An
  agent's avatar, here and in conversations ("Jordan Lee / claude-backend"), uses its app's mark or one guessed from
  its name (whole words). *Amended by D-UI-18 (2026-10-04): the mark comes only from what the window knows (the AI
  app it connected, or the CLI it started); a contact's agent always keeps the neutral mark.*
- **Why.** The owner should see at a glance which AI it is and whether it is connected; marks used without permission
  would be a risk for the product, a monogram is not.
- **Checked.** Goldens `37_ai_apps(_dark, _ru)`, `38_connect_review`, `39_connect_guide`; the frames with agent
  avatars and status chips were redrawn (`10_approvals*`, `15`, `16` (now the token file, no token), `21`, `28`, `30*`,
  `33*`, `35`, `36`).

---

## Conversations for agents and batch approvals (2026-10-03…04)

### D-90 · Addressing and topics are fields of the signed message, sent only to nodes with `addr/0` (maintainer decision)
- **Context.** A live session with a build agent and a ChatGPT agent on one node, both talking to the lead agent of the
  server node: everything landed in one chat, every agent on the node read every message the contact sent (one had to
  write "Builder: not for you"), and the maintainer asked whether ChatGPT could read the whole conversation. Maintainer
  decisions: separate conversations for different agents or different tasks; an agent reads only what is for it.
- **Decision** (PROTOCOL §23). `envelope-core` gains two optional fields: `to` (`"person"`, `"everyone"` or
  `{"agent": <name>}`, the name an agent of the recipient side announced in §21) and `topic` (`{id: 16 random bytes,
  title}`), only on `text` messages. They are in `core`, so the message ID and the author's signature cover them, and
  history verification over IDs (§16–§17) does not change. **No new cryptography**: no key, no ratchet, no channel per
  topic; a topic is organization the two sides agree on, and the recipient's owner reads every topic.
- **Compatibility.** Nodes up to `0.1.0-preview.3` parse `envelope-core` strictly (`deny_unknown_fields`): a message
  with the new fields would be refused and end `failed`. The new node advertises `addr/0` in the §21 `features`
  exchange and puts the fields into `core` only for a contact that answered it; otherwise it keeps them in its own
  history only (`sent.addressed: false`, `contacts[].peer_addressing: false`). Without the fields the encoding of `core`
  is byte for byte the old one (`skip_serializing_if`), so plain messages hash and sign as before. If the contact's
  features are not known yet, the node connects (up to 3 s) first, as for agents (D-75).
- **Defaults.** The owner's message goes to the person; an agent's message is a reply to whoever wrote the last message
  it read with `inbox` on that link (the contact's person, or its agent by `via_agent`) and continues that message's
  topic; `topic: ""` leaves the topic. A title continues the link's topic with exactly that title or starts a new one.
- **Why in `core`.** Outside `core` the address would not be signed: the relay cannot see it (it is inside the
  ratchet), but the recipient's copy could not prove what the author addressed, and a resend during verification would
  lose it. Inside `core` it costs nothing new and survives every path a message takes.
- **Checked.** `antenna_proto` tests (`a_plain_core_is_byte_for_byte_the_old_format`,
  `a_node_without_addressing_rejects_the_new_fields`, `addressing_round_trip_and_wire_shape`, field rules);
  `crates/antenna-cli/tests/addressing.rs::history_verification_holds_across_addressed_and_plain_messages` (both
  directions, agents and owners, topics; verified with equal fingerprints, and again after a restart with the copy
  check); `a_reply_goes_to_its_author_and_keeps_the_topic` (the same topic ID on both sides, `topics`); compatibility
  with the `v0.1.0-preview.3` release binaries: `a_preview3_node_gets_no_addressing_fields`.

### D-91 · What an agent reads is decided by the daemon from the signed address (maintainer decision)
- **Decision** (CONTROL §20). An incoming message on a link in an agent's scope, received after the agent was created
  (D-30), is visible to the agent when: it is addressed to this agent by the name the contact sees (`wake` for a link's
  default wake agent); or it is addressed to everyone, or has no address, and the owner allows this agent messages to
  everyone (`everyone`); or it is addressed to the person and the agent is the link's wake agent. `inbox`/`read_inbox`,
  `wait`/`wait_for_message`, the `message_fact` event, `history` (incoming: visible ones; outgoing: only the agent's
  own) and wake runs follow the rule. The address is read from the signed `core`, not from a column.
- **`everyone` per agent.** New agents: off (they read only what is addressed to them by name, the setting that holds
  against any contact). Agents created before v6 and wake agents: on, so that agents talking to not-yet-updated nodes
  keep working (an older node's messages carry no address and count as to everyone). Turning it on needs the owner
  password (it widens what an agent reads); turning it off needs a session (`agent_set`, `antenna agent set
  --everyone on|off`, a switch in the window). Agents the window creates (Connect, Start agent) start with it off too,
  with the switch shown there (maintainer decision, 2026-10-04: that is the privacy asked for; the other side addresses
  agents by name through its To picker).
- **Task authority (D-88) applies to what the agent may read.** A contact the owner named for tasks still reaches the
  agent only with messages addressed to it (or to everyone, when allowed); what that contact writes to the person stays
  the person's. Visibility decides whether the agent gets the text at all, authority how it is to take it.
- **The wake agent reads what is for the person.** The owner sets wake up with the password to answer a contact for
  them (D-67); the contact writes to the person by default, so without this the wake agent would never see a message.
  It still never sees what the contact addresses to another of the owner's agents. This refines the maintainer's "an
  agent never reads what is for the person": the wake agent is the person's stand-in on that one link (confirmed by
  the maintainer, 2026-10-04).
- **The cursor moves past what the agent will never see**, so unseen messages do not pile up in every `inbox` call;
  turning `everyone` on later does not reveal older messages to everyone (like D-30: from now on).
- **Not covered.** File offers are not addressed: every agent with the link in scope still sees them in
  `files_pending` (a separate step). The rule is about this node's own agents; the recipient's owner reads everything.
  A process that is the owner (CONTROL §11 item 10) or gets past the agent boundary (item 1) reads everything too.
- **Checked.** `tests/addressing.rs::an_agent_reads_only_what_is_addressed_to_it` (two agents and one with
  `everyone`; messages to each agent, to the person and to everyone, from the contact's agent and the contact in person;
  `inbox`, `wait`, `history`; the owner's own messages are not on an agent's pages; turning `everyone` on needs the
  password, off does not; `mark_read.ids`); `tests/control.rs` (an agent's subscription gets no fact about a message to
  the person); `tests/wake.rs::a_plain_agent_replies_by_itself` (a message to another agent neither wakes nor reaches
  the wake agent; its reply goes to the person who wrote); unit tests `addressing::tests::the_visibility_rule`.

### D-92 · Approving several requests: one password per call, each request approved on its own (maintainer decision)
- **Context.** The maintainer, during the same live session: "approve several requests at once: press 'approve all'
  and enter the password once."
- **Decision** (CONTROL §20). `approve_many {items: [{id, fingerprint?}], password}` (≤ 64): the daemon checks the
  password once for the call (one Argon2id), then calls the same single approval for each item: each request keeps its
  own binding (its request hash with its own nonce, SPEC §9) and is used up only by the request it was made for; the
  optional `fingerprint` (what the owner was shown) must match, otherwise that item fails alone with
  `approval_mismatch`. Unknown, expired or decided items fail alone; each approval is logged on its own and sends its own
  `approval` event; a stream final waiting for one goes out by itself. `deny_many {ids, hour?}` needs neither a
  password nor a session (D-84). Agents have neither command (`unknown_command`), MCP has no such tools. CLI: `antenna
  approve <id> <id>…` (one password prompt), `antenna deny <id> <id>…`.
- **Why not a "blanket" approval.** An approval for "everything from this agent for N minutes" would be a new kind of
  permission that SPEC §9 does not have and that a prompt injection could fill; here the owner still approves listed
  requests, each with its text shown, and only the password prompt is shared.
- **Checked.** `tests/addressing.rs::batch_approvals_check_the_password_once_and_each_binding` (a wrong password
  approves nothing; a tampered fingerprint and an unknown ID fail alone while the others are approved; an approval is
  not taken by another text, and one request's approval is not another's (`approval_mismatch`); two audit entries;
  deny-many from a connection without a session; the CLI with two IDs; agents get `unknown_command` for
  `approve_many`, `deny_many` and `agent_set`); `antenna_proto` `batch_approvals_and_agent_visibility_are_owner_commands`.

### D-UI-18 · Threads per counterpart, the To and topic pickers, signed bubbles, batch approvals in the window
- **Decision** (DESIGN "Threads, addresses, authorship and batch approvals"). The window speaks `x-control/6` and falls
  back to `x-control/5` when the daemon refuses the newer hello.
  1. **Threads.** A link's messages are grouped by the counterpart on the contact's side (CONTROL §20): the person and
     each of the contact's agents, one chip each with its own unread count, under the conversation header. Inside a
     thread, filters: All, each topic, each of the owner's agents that talked there. The bar shows only when there is a
     choice, so a conversation between two people looks as before. The thread with the latest message opens by default.
  2. **Unread per thread.** Showing a thread marks exactly its unread messages (`mark_read {up_to_seq: 0, ids}`).
  3. **Composer.** A **To** line (the person, each agent of the contact, Everyone) when the contact has agents, and a
     **#** button for the topic (none, existing, new); defaults follow the open thread and the topic filter; after a
     send the window follows the message into its thread. When the contact's node cannot address, one line says so.
  4. **Authorship.** In links where agents take part, the first bubble of each group is signed: "You", one's own agent
     (its name, the mark, "your agent"; the bubble tinted, the owner's stays brand blue), the contact, "contact /
     agent"; "→ everyone" or "→ <agent>" when the addressee is not the obvious one. The mark comes from
     `agentServiceLogo`, built on the AI-apps marks (D-UI-17).
     *Amended by D-UI-24 (2026-10-05): the owner's own messages carry no name and no picture; every other sender has
     its picture beside the first bubble of its group.*
  5. **Batch approvals.** Checkboxes, Select all, Approve selected (the password once, `approve_many` with each
     request's fingerprint) and Deny selected (`deny_many`, no password); per-item failures are listed alone. A card in
     the conversation offers "Approve all from this agent (N)" when one agent waits with several requests.
  6. **"Sees messages to everyone"** per agent: the password to turn it on, none to turn it off.
- **Why.** The maintainer's words: a ChatGPT task about avatars must not sit in the same chat as the build agent's;
  "approve all and enter the password once"; "in my window I look like the computer". Grouping by counterpart needs no
  state in the daemon; topics and the owner's-agent filters separate tasks and agents within one counterpart.
- **Checked.** `test/widget/threads_test.dart` (15 scenarios, including a v5 daemon), `test/protocol/client_v6_test.dart`
  (the fallback and the v6 requests on a real unix socket), the live `test/protocol/live_threads_test.dart` (two real
  nodes: addresses and topics on both sides, `topics`, an agent's inbox, per-thread `mark_read`, `approve_many` with one
  password, `deny_many` without a session), goldens `40_threads` (light, dark, Russian) and `41_batch_approvals`.
- **Agent marks and what a new agent reads** (maintainer decision, 2026-10-04). A contact's agent is always drawn with
  the neutral agent mark and its name: in the author line, thread chips, the To picker, the contact card, Agents →
  Contacts' agents and the avatars of contacts whose side is an agent. A contact chooses its agents' names, so a name
  proves nothing, and a vendor logo there could be spoofed. A logo appears only for the owner's own agents, and only
  from a fact the window has: the CLI it started for the agent in Code mode, or the AI app it connected (Agents → AI
  apps). Names are never guessed (this amends D-UI-17). Every place the window creates an agent (Connect an agent,
  Connect an AI app, Start agent) has the switch "Sees messages to everyone", off by default as in the daemon (D-91),
  with one line: "Off: this agent sees only messages addressed to it by name." / "On: it also sees messages to
  everyone and messages without an address." The window sends `everyone` with `agent_add` only to a daemon that speaks
  `x-control/6`. Checked: `test/widget/agent_marks_test.dart` (6 scenarios: neutral marks for a contact's
  `claude-backend` everywhere, the Claude Code mark for an own agent the window started, the switch in all three forms
  sending `false`/`true`, no switch and no field for a v5 daemon), live `test/protocol/live_code_mode_test.dart` (the v6
  daemon accepts `everyone` on `agent_add`). Frames redrawn: `10_approvals*`, `15_agent_connect`, `21_agents`,
  `26_chat_files`, `28_wake_agents`, `30_contact_agents*`, `33_approval_in_chat*`, `35_start_agent`,
  `38_connect_review`, `39_connect_guide`, `40_threads*`.

## Resident agents (2026-10-04)

Goal (maintainer decision): the agent that works with a contact or with the owner for hours must be **the same agent**,
which already knows why the work is done and what was decided, instead of a fresh run per message that knows only that
message (D-67). Code: `crates/antenna-core/src/resident.rs`, the sandbox's agent input (`sandbox/supervisor.rs`,
`sandbox/macos.rs`, `sandbox/common.rs`); control protocol `x-control/6` (CONTROL §21); tests
`crates/antenna-cli/tests/resident.rs`.

### D-93 · Resident agents: one long-lived agent session per link, woken by turns on its stdin
*Amended 2026-10-05: resident agents are not Linux-only. On macOS they run in the Seatbelt sandbox like one-shot wake
(D-P-13); the first run on a Mac failed only because the proxy socket path was longer than `sun_path` (fixed: long socket
paths move to `/tmp/antenna-<uid>`, TROUBLESHOOTING "macOS 27 on a real Mac"); the suite passing on a Mac is still to be
recorded. Agents started on wake inherit none of the daemon's environment (a test checks `CLAUDECODE`, `CLAUDE_CODE_*`,
`CODEX_*`).*
- **What the agent CLIs offer (checked 2026-10-03…04).**
  1. **Claude Code** (2.1.233 on the build server): `claude -p --input-format stream-json --output-format
     stream-json` is a long-lived process that takes user turns as JSON lines on stdin,
     `{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null}`, one after another, and ends
     each turn with a `result` line (`usage`, `total_cost_usd`, `session_id`) (docs: code.claude.com/docs/en/headless,
     …/agent-sdk/streaming-vs-single-mode: "a long lived process that takes in user input, handles interruptions";
     the user message type: …/agent-sdk/typescript). `--session-id <uuid>` names a new session, `--resume <id>` loads it
     from its transcript (`~/.claude/projects/…/<id>.jsonl`); `--autocompact <auto|tokens>` sets the auto-compacting
     window; `/compact` sent as a user turn compacts and reports a `compact_boundary` system line with
     `compact_metadata` (…/agent-sdk/slash-commands). The interrupt is a control request on stdin,
     `{"type":"control_request","request_id":"…","request":{"subtype":"interrupt"}}`: not in the public docs; read in
     the 2.1.233 binary (it parses `control_request` lines and handles `subtype === "interrupt"`) and tried in the real
     run. A subscription login works headless with `claude setup-token` →
     `CLAUDE_CODE_OAUTH_TOKEN` (a long-lived token; its lifetime of about a year is stated only by third-party
     sources).
  2. **Claude Code Channels** (code.claude.com/docs/en/channels, …/channels-reference): an MCP server declares
     `capabilities.experimental["claude/channel"]` and sends `notifications/claude/channel {content, meta}`; Claude
     Code shows it to the model as a `<channel source=…>` block, queued until the next turn if busy. Research preview;
     `--channels plugin:<name>@<marketplace>` for allowlisted plugins, `--dangerously-load-development-channels` for
     others; Team and Enterprise organizations must enable it; documented for interactive sessions, not for `-p`. It
     fits an agent the owner runs interactively (Code mode, D-83), not a session the daemon runs: kept for later.
  3. **Prompt caching** (platform.claude.com/docs/en/build-with-claude/prompt-caching): a cached prefix costs 0.1× of
     base input on read; writing it costs 1.25× (5-minute TTL) or 2× (1-hour TTL). Claude Code 2.1.233 chooses the TTL
     itself (read in its request code): `FORCE_PROMPT_CACHING_5M` → 5 minutes, `ENABLE_PROMPT_CACHING_1H` → 1 hour,
     otherwise **1 hour for a claude.ai subscription login** (not on overage) for the query sources of a server-side
     allowlist whose default holds `sdk`, the source of `-p`; `CLAUDE_CODE_PROMPT_CACHE_TTL` (`5m`/`1h`) from 2.1.242
     (code.claude.com/docs/en/env-vars). How cached tokens count against subscription usage limits is not documented.
  4. **Codex** (learn.chatgpt.com/docs/app-server): `codex app-server` speaks JSON-RPC 2.0 over stdio lines:
     `initialize` (+ `initialized`), `thread/start {model, cwd, approvalPolicy, sandbox}` → `{thread: {id}}`,
     `thread/resume {threadId}`, `turn/start {threadId, input: [{type: "text", text}]}`, `turn/interrupt {threadId,
     turnId}`, `thread/compact/start {threadId}`, notifications `item/agentMessage/delta` and `turn/completed {turn: {id,
     status}}`. `codex exec resume <id>` / `--last` resume a one-shot session. `codex login` signs in with a ChatGPT
     plan by default and stores `auth.json` under `CODEX_HOME` (developers.openai.com/codex/auth). OpenAI caches
     prompts automatically (cached input at about a tenth of the price, retention up to 24 hours:
     developers.openai.com/api/docs/guides/prompt-caching). Not verified: the parameters of the delta notification,
     the approval requests, a ChatGPT login inside our sandbox (Codex rewrites `auth.json` when it refreshes the login,
     like Claude Code's credentials file, D-68). Codex is not installed on the build server.
  5. **Gemini CLI**: `gemini --experimental-acp` speaks the Agent Client Protocol (agentclientprotocol.com):
     `session/new`, `session/prompt`, `session/cancel`, and `session/load` (ACP v1; v2 replaces it with
     `session/resume`). Which ACP version the CLI implements: not verified.
- **Decision.**
  1. **A mode of the wake rule.** `wake set <contact> --resident --cmd "claude -p --output-format stream-json …"`
     (owner password, as before). The program must speak Claude Code's stream-json (other programs: `bad_request`);
     the dedicated agent, its scope (this link), the sandbox (bwrap / Landlock / Seatbelt), the lifeline, the start
     gate, the CONNECT proxy, the secret variables and the forbidden flags are those of D-67…D-71 and D-P-13. The
     owner's own `--resume`, `--continue`, `--fork-session` and `--session-id` stay forbidden: sessions are the
     daemon's (D-29).
  2. **The process.** The daemon starts the agent CLI on the first turn, not at `wake set`, and keeps it while it
     waits: the agent is blocked reading its stdin and the supervisor in `wait`, so an idle session uses no CPU and no
     tokens. It stops the process after `--idle-stop` (1 hour by default; 0 keeps it), and the process also ends with
     a crash, a daemon restart or a reboot; the next turn starts it again with `--resume <session>`. The session ID is
     a UUID the daemon chooses (`--session-id` on the first start), kept with the rule in the encrypted database; the
     agent CLI's transcript and notes are in the session's own HOME and working folder, `<data>/wake/resident/<link>/`.
     A turn is written to the agent's stdin through the lifeline: after the start gate the supervisor copies the
     lifeline's bytes to the agent's stdin pipe, so the daemon stays the only writer and EOF still kills the tree;
     stage 2 reads its own plan one byte at a time, so it never buffers the agent's input. One session per link for
     now; with conversation threads the key becomes the thread.
  3. **A wake is a turn, and the turn carries a reference, not the text.** "[Antenna] New message from <label>: N
     unread (IDs …). <label> has trust level L (…): tasks: …; commands: …. Read the messages with read_inbox …;
     everything you write as text in this turn is sent to <label>." The content stays where it was: a tool result
     marked as external data (CONTROL §5), read through the daemon. Why not the text in the turn: (a) a user turn is
     the channel of instructions and a tool result the channel of data; a contact's text in the user turn would speak
     with the owner's voice; (b) reading through `read_inbox` keeps taint, the agent's read cursor, and the
     hidden-text and secret filters in the one code path every agent read takes; (c) an agent that already read the
     next messages during this turn does not get them again. The price is one more model call per turn (the tool
     call), mostly read from the prompt cache. **What the agent may read** (D-91) holds for turns too: a turn counts
     only the messages the wake agent may read, so a message the contact addresses to another of this node's agents
     starts no turn, and `read_inbox` does not show it.
  4. **Replies.** The text of a contact's turn streams to the contact as the agent's streaming reply (D-63…D-66,
     the same policy on every piece); the final message goes to the history. An error of the agent CLI itself (login,
     limit, a synthetic API message) goes to the log, never to the contact (as in D-68).
  5. **Interjections.** A message that arrives during a turn waits; when the turn ends, all unread messages become one
     turn (a burst of messages costs one turn, not one each). Nothing is written to a busy agent. Only the owner can
     interrupt (`wake say --interrupt`): a contact must not be able to cancel the owner's work, and an interrupt per
     message would let a contact keep the agent from finishing anything.
  6. **The owner in the same session.** `wake say <contact> <text>` (owner session; CONTROL §21) is a turn labelled
     "[Antenna] Your owner writes to you directly …" with the owner's text in it (the owner is trusted). Its reply comes
     back to the owner only, as `resident_delta` events and a `resident_turn` reply; with `--to-contact` it goes to the
     contact as the agent's reply. The window's chat thread and Code mode terminal are meant to use the same command.
  7. **Context: the agent keeps its full context by default** (maintainer decision: the agent's full context is
     worth more than the tokens compacting would save). The agent CLI still compacts by itself near its context limit.
     Compacting by the daemon is opt-in per rule: `--compact-idle 50m --compact-above 100k` compacts **before the
     provider's cache goes cold** (50 minutes is inside the 1-hour cache), once per turn and only a large context;
     later, after hours, it would cost what it saves, because compacting is itself a model call over the whole context
     and only a warm cache makes that call cheap (for an API-key login, a 5-minute cache: `--compact-idle 4m`). The
     owner can compact at any time (`wake session <contact> compact`); `status` shows the context size, how many times
     the session was compacted (by anyone, the agent CLI included) and when last, so the owner can decide. The agent is
     told once (Claude Code: `--append-system-prompt`; other programs: the first turn) to keep short notes in
     `NOTES.md` in its working folder and to read them after compacting or a restart.
  8. **Taint is sticky** (D-29). The session keeps its taint for as long as it keeps its context: a process restart,
     a resume or compacting does not reset it; only `wake session <contact> reset` does, with the owner password, and
     the reset also wipes the transcript and the notes (they hold the data the taint is about). `wake off` and
     `revoke` remove the session and its directory. `wake list` shows the ceiling.
  9. **Costs and limits.** Tokens are spent only by turns: one model call per step of a turn, each processing the
     whole context, mostly from the cache (0.1×); after the cache expires the next turn writes the whole context
     again. Unchanged: the link's message limits (D-30), the agent policy, the secret scanner. Per rule: the time limit
     of one turn (`--timeout`; at the limit the daemon interrupts the turn, and stops the process if it does not end
     within 15 s), the turns a contact's messages start per hour (`--max-per-hour`; 60 by default for a resident
     rule, which works with its contact for hours; 20 runs for a one-shot rule, as before), three crashes
     within 10 minutes make the session wait for the next message, `RLIMIT_CPU` 6 hours per process. `wake list` and
     `wake session` show turns (the owner's among them), process starts, tokens (fresh input, cache read, cache write,
     output), the context of the last call and the agent CLI's cost estimate at API prices (a subscription is not
     billed per token).
- **Why.** A model call always processes its whole context, so remembering is never free: what a resident session
  saves compared with resuming a session for every message is the process start and the rereading by the CLI, and
  what it buys is the agent's working memory between messages, at cache-read prices while the conversation is active.
  Sleeping costs nothing, and the first turn after a long pause pays for the context once; an owner who wants that
  once smaller turns on compacting before the cache goes cold.
- **Codex.** The adapter is the protocol on the agent's stdin and stdout; the daemon's side (queue, routing,
  counters, timers, the sandbox) does not change. Codex app-server mapping: start = `initialize` + `thread/start` (or
  `thread/resume` with the kept thread ID); turn = `turn/start {threadId, input: [{type: "text", text}]}`; text =
  `item/agentMessage/delta`; end = `turn/completed`; interrupt = `turn/interrupt`; compacting =
  `thread/compact/start`. Not built until the notification parameters and approval requests are verified against
  Codex's source and a ChatGPT login is shown to refresh inside the sandbox without writing the owner's `auth.json`
  (`wake set --resident` with a Codex command answers `bad_request` until then).
- **Checked.** `crates/antenna-cli/tests/resident.rs` (two real daemons; a fake agent script that speaks the
  stream-json protocol and keeps a turn counter per session in its HOME, refusing a reused or unknown session ID as
  Claude Code does): three messages reach one process and the counter carries on (`starts=1`, the same session); an
  idle process and its sandbox use 0 CPU ticks over 3 s; a crash in a turn → the turn ends "interrupted", the next
  message resumes the same session (`how=resume`, `starts=2`); a daemon restart → resumed again (`starts=3`); two
  messages during a turn → nothing reaches the busy agent, both arrive in one turn; the owner's `--interrupt` ends a
  turn; owner turns are labelled and stay local, `--to-contact` sends the reply to the contact; inside the resident
  sandbox the owner's `CLAUDE.md` and the keystore are closed and direct TCP is refused; `wake say`, `wake session`,
  `trust` from inside are `unknown_command`, with or without the token; no compacting by default and the owner's
  `compact` at any time; with `--compact-idle`, compacting after the idle time, once; the idle
  stop and a resume; `reset` needs the password and gives a new session with clean taint and no old transcript;
  `wake off` removes the directory. The protocol and CLI tests list `wake_say` and `wake_session` among the commands
  an agent does not have. **The real Claude Code** (2.1.233, `--model sonnet`, a `claude setup-token` token, bwrap;
  `resident.rs::real_claude_code_keeps_its_context_across_messages`, `#[ignore]`): the second message ("what is my
  cat called, and my favourite colour?") was answered from the first ("Biscuit … teal"); an owner turn named what the
  contact had said and told the owner apart from the contact; the interrupt ended a long answer and the next turn
  answered in 2.0 s; a real `/compact` shrank the conversation and the next turn still knew the facts; a turn 400 s
  after the previous one read 71,360 tokens from the cache and wrote 637, so the 1-hour cache held; the transcript
  `<session>.jsonl` is in the session's HOME.
- **Limits.** (1) **The transcript is not encrypted at rest** (accepted for now, maintainer decision): the node's
  database is encrypted, but the agent CLI writes its transcript as plain text into the session's HOME under the data
  directory (0700), as the owner's own Claude Code transcripts are. A later step keeps it inside an encrypted area. (2) The turn header
  is the daemon's; a contact's text can still claim to be the owner inside a tool result: the model must keep the two
  apart, and the daemon enforces the policy either way. (3) The CLI's cost estimate assumes API prices and may count
  differently from a subscription's limits. (4) The `interrupt` control request is not in Claude Code's public
  documentation. (5) Resident Codex and Gemini CLI: not yet (above). (6) The window does not show resident sessions
  yet: `wake list` carries the `resident` field and `wake_say` streams the reply, for the window to use. (7) Claude
  Code's fixed prompt and tools are about 32,000 tokens per call; compacting cannot go below that, which is why
  `--compact-above` is 100,000 by default.

### D-94 · Proven technology first; our own mechanisms ship as experimental (maintainer decision, 2026-10-04)
**Question.** Antenna is gaining mechanisms of its own design on top of the proven base (libsignal, iroh, rustls with aws-lc-rs, SQLCipher, the OS sandboxes): resident agent sessions (D-93), message addressing and topics (D-90, D-91), agent token files (D-86), sending a file by content (D-87), task authority (D-88). New mechanisms have holes nobody has found yet.

**Decision.** The product is built from existing, verified technologies (`docs/STACK.md`, "Principle: proven technology first"). A mechanism of our own design ships **marked experimental** until it has had its own tests, a written threat analysis, negative and adversarial tests, a formal model where one applies, and time in use; only then does it become the default. In v0.1.0-preview.4 the experimental ones are: resident agents (`wake set --resident`), addressing and topics, task authority, `share_file_content`; the window labels them "Experimental" and the user guide says so. Token files are a hardening of an existing mechanism (the token stays the same, only its storage changes) and are not marked. No custom cryptography stays absolute (SPEC §7, §15).

**Why.** The maintainer: a technology can look great to its authors and still have holes; what users rely on must be proven, and what we invent is tested separately first.

---

## Built-in local assistant and local models (2026-10-05, proposed)

### D-96 · A built-in local assistant: the doctor first, then local models as sandboxed agents without authority (proposed, experimental)
- **Status.** Proposed 2026-10-05, not built; the design is `docs/LOCAL-ASSISTANT.md`. Everything of our own design in
  it ships on the experimental track (D-94). The maintainer's decisions it records are marked as such; the open
  questions are Q-LM1…Q-LM11 there.
- **Question.** The maintainer's idea (2026-10-05): a local open-weight model, downloaded inside Antenna without an
  account or API key, appears as one more agent with its own chat and helps people who are not technical to set up and
  troubleshoot Antenna (it sees the node's status and logs, explains, proposes fixes), with a chat view and a terminal
  view, without weakening security. Refinements of the same day (maintainer decisions): fix-it buttons that need no
  model come first; the model offered follows the computer's power; a curated catalog plus "add another model";
  several models, each its own agent; local models can work for other agents, on this computer or another of the
  owner's devices; a truthful "Local" badge; full performance by default, with scheduling for throughput and an
  optional power setting that never switches by itself.
- **Decision (proposed).**
  1. **Phase 1 is a deterministic doctor with no model:** seven checks (`daemon_down`, `keys_locked`,
     `relay_unreachable`, `ai_cli_missing`, `ai_cli_not_on_path`, `app_restart_needed`, `token_bound_elsewhere`), each
     with a fix whose text and command are fixed in the release and shown in a consent dialog before they run: the
     vendor's official installer in a visible terminal tab, one PATH line in the shell profile after a backup, an app
     restart by bundle ID, quitting the process that holds a token, the existing unlock, LAN and agent commands. The
     window and `antenna doctor` run fixes as owner actions; the daemon only reports (`diagnose`, `doctor_report`).
  2. **Runtime: llama.cpp `llama-server`** (MIT), built by us from a pinned build tag, without its HTTPS client
     (`LLAMA_OPENSSL=OFF`), signed and shipped with the app; never with its built-in tools, MCP options or downloads.
     It runs in **its own sandbox** (bwrap/Landlock/Seatbelt following D-71 and D-P-13): one model file read-only, a
     unix socket in its run folder, no network, no daemon socket, no token, no owner files; on macOS the narrow Metal
     rules (`iokit-open` for the GPU user client, `mach-lookup` for Metal's compiler service), verified on a real Mac
     and optional ("Run without GPU"); `--no-slots`, no slot save path, no web UI.
  3. **Connection: an ordinary agent through MCP.** Our small loop `antenna local-agent` runs in a second sandbox
     without network, starts `antenna mcp` with its own token (bound to the loop, D-28), turns the MCP tools into the
     runtime's tool list, and speaks the stream-json subset that the resident machinery already parses (D-93), so the
     session, turns, interrupt and counters are D-93's, keyed by agent and counterpart instead of by link. The daemon
     keeps the conversation in its encrypted database (no plain-text transcript). Not an internal adapter: the boundary
     would be the same, but a second tool surface would drift from MCP's; not inside the daemon: model-facing parsing
     stays out of the process that holds the keys.
  4. **No authority.** A `diagnostics` capability (owner only, exclusive with links in scope, so the agent can send
     nothing to anyone) gives read-only tools: status, findings, filtered log lines, agents' status, the AI-app scan,
     pairing state, network facts without addresses, the bundled guide. `propose_fix` only asks the window to show one
     of the doctor's current fixes; the window draws it from its own catalog and opens the doctor's consent dialog after
     re-running the check, so an assistant button is always a subset of the doctor's buttons at click time. Owner
     commands do not exist for it, as for every agent.
  5. **Models:** the first catalog is one family in three sizes, Qwen3.5 (Apache-2.0, ungated; the best measured
     Russian and tool use up to 10B): the 9B (5.68 GB at Q4_K_M) by default on Apple silicon M2 or newer with 16 GB or
     more, the 4B (2.74 GB) on M1 and on x86 CPUs, the 2B (1.28 GB) as the fallback for 8 GB machines, the doctor only
     below that; started with Qwen's official chat template and thinking off for tool turns. The catalog is curated
     per release (name, maker, license, size per quantization, memory needed, languages, tool-use rating from our
     evaluation, "recommended for your computer"), carried in the signed release manifest (D-82, a new `models[]`
     field that older readers ignore) and compiled into the daemon. Files come from Hugging Face by commit
     (`resolve/<commit>/<file>`), are downloaded by the daemon with `curl` (resumable, HTTPS only, through an allowlist
     of the hub's hosts), checked for disk space first, verified against the manifest's SHA-256 before first use (a
     mismatch deletes the file), and removable. "Install from a file" uses the same hash. "Add another model"
     (advanced) takes a repository, a commit, a file and either a SHA-256 or a "pin on first download" box plus a
     license confirmation, and labels the model "added by you, not reviewed".
  6. **Hardware assessment without permissions:** macOS `sysctl` (`hw.memsize`, `hw.ncpu`, `hw.perflevel0.physicalcpu`,
     `machdep.cpu.brand_string`, `sysctl.proc_translated`) and the bundled runtime's own `--list-devices` run inside its
     sandbox (the Metal device and its recommended working set); Linux `/proc/meminfo`, `/proc/cpuinfo`, the cgroup
     limits and `/sys/class/drm`; power state from `pmset -g batt` and `/sys/class/power_supply`. Nothing that prompts,
     needs root or reads other apps' data. The recommendation is the largest catalog model whose memory need fits the
     budget at an acceptable speed; the default is the recommendation, not a fixed model.
  7. **Several models, each its own agent** with its own conversation ("On this computer"), a chat view and a terminal
     view of one daemon-held session; roles Assistant (diagnostics), Worker or Chat only, which the daemon keeps apart.
  8. **Workers (phase 4):** over links, a local model agent is a resident agent addressed by name (D-90, D-91) that
     takes tasks only from contacts the owner names (default nobody, D-88), one session per thread; on one computer, a
     new delegation tool `ask_local_model` for agents the owner allows, with a session per delegating agent carrying its
     taint (D-29).
  9. **The "Local" badge** only when this daemon launched the runtime itself (the agent was created by the model flow
     and is recorded `runtime: "local"`); on another of the owner's devices only over an own-device link, from that
     node's signed agent announcement; never for a contact's agent, never from a name (D-UI-18).
  10. **Performance (maintainer decision 2026-10-05): no throttling by default.** The scheduler is for throughput:
      requests to one model batch as parallel slots, a second model loads only if both fit in memory, nothing ever
      swaps; the owner's own chat goes first. An optional Power setting (Maximum by default, Balanced, Battery saver),
      chosen by the owner; on battery at most a one-line note.
- **What is new and why nothing existing fits** (D-94). Reused as is: llama.cpp, published GGUF weights, `antenna mcp`
  and `rmcp`, agent tokens and binding, the sandboxes and supervisor, the resident machinery, the signed manifest,
  `curl`, the owner commands and approvals. New: the loop, the doctor and its fix catalog, the diagnostics capability,
  local sessions without a link, the runtime's sandbox profiles (with GPU access on macOS), the catalog and download,
  same-computer delegation. Existing agent CLIs that can drive local models (Claude Code, Codex, goose) carry fixed
  prompts and tools of tens of thousands of tokens, which a small model on a laptop CPU needs minutes to read, and
  shell tools we would have to disable and prove disabled; the loop needs a handful of read-only tools.
- **Why.** People who are not technical get stuck on setup problems that Antenna can see (a missing CLI, PATH, a stale
  app, a token held elsewhere, a locked node); a button fixes most of them without any model, and a local model can
  explain the rest in their language without an account, a key or sending their logs anywhere. Keeping the model
  without authority, without network and in a sandbox apart from the agent token means that prompt injection through
  logs can change what it says, not what happens.
- **Residual risks** (named in the design, §6.3): misleading prose to the owner; steering the owner among legitimate
  fixes; memory-safety bugs in the runtime reachable from crafted model files or text (contained by its sandbox);
  the GPU driver surface on macOS; same-user processes using the runtime socket; poisoned context within a session;
  downloads denied; text the owner copies out.
- **To check before it leaves the experimental label.** Per phase (design §11): tests with negative controls, an
  evaluation set of troubleshooting cases in English and Russian per catalog model, an adversarial corpus for prompt
  injection and terminal sequences, measurements on the build server and real Macs, and an independent security review.

## Fixes from the first run on macOS 27 (2026-10-05)

### D-95 · The inviter confirms with one button once the joiner entered the code (maintainer decision, 2026-10-05)
- **Question.** At the confirmation step the inviter (A) typed the same code again after the joiner (B) had typed it correctly
  (D-UI-4, D-41/F-4). The maintainer, on the clean Mac: "the computer already knows the code"; replace the retyping with one
  button, "The contact confirmed — codes match".
- **Decision.** After a correct M5 (B's node reports, with `mac_B`, that B's owner entered the code that matched the SAS, PROTOCOL
  §8 B5), owner A confirms with one explicit action and no code: the button in the window, `yes` in `antenna invite`, `antenna
  pairing confirm <id>` without `--code`. The password or the owner's connection stays as before (it is a trust command). The
  daemon accepts a confirmation without the code **only for an invite during whose life no other invite of this node showed a
  code** (`InviteInfo.confirm_without_code`, `need_input{confirm_without_code}`); otherwise it answers `code_required` and the
  owner types the code they read out, which is checked against this invite's code as before (`sas_mismatch`). The CLI and the
  window never fill the code in. Wire, PROTOCOL messages and older clients are unchanged: the fields are optional and only added
  (CONTROL §6, x-control/6).
- **Why this is safe enough.** Condition 2 of PROTOCOL §9 is B's correct entry, proven to A by `mac_B` while `PRK` is secret (TLS
  intact or the link not leaked). Condition 1 is the human assent; with the code typed, the daemon also checked which invite
  the assent was about, because a spoken "it matched" does not name the session (F-4, `formal/neg_nocode.pv`: two invites,
  the "yes" applied to the one an intermediary completed). With one code on the owner's screen at a time there is nothing to
  confuse it with: `formal/button_single.pv` (one invite with a code per owner, a "yes" without a code, TLS broken, the link
  leaked) gives Q4 `true` for both sides, and two codes at once keep the typed code. An invite that showed a code and then
  ended still counts (an attacker can make the honest invite fail after its joiner said "it matched"). What remains is the
  human factor already outside the model (formal README): a click without having heard "it matched" about the code on the
  screen.
- **Checked.** `crates/antenna-cli/tests/link.rs::the_inviter_confirms_without_retyping_once_the_joiner_entered_the_code`
  (`yes` in the dialog; `pairing confirm <id>` without the code, refused early and with a wrong password),
  `two_invites_with_codes_at_once_need_the_typed_code` (`code_required` from the command and in the dialog, also after the
  other invite failed; the typed code as animals links; negative control: with the overlap check disabled the test fails),
  `history.rs::invite_follow_confirmation_by_click_or_by_the_typed_code` (the window's raw path), `agents.rs::
  invite_lives_in_the_daemon_and_is_confirmed_by_a_separate_command` (the `--code` path for compatibility);
  `formal/run.sh button_single` (23 s, Q4 `true` ×2). The window: the button, the fallback to the code field on
  `code_required` and on an older daemon's `bad_request` (D-UI-4 revision).

### D-97 · One agent token for several MCP processes of one running app (2026-10-05)
- **Question.** On the clean Mac, Claude Desktop with Antenna connected through a token file (D-85, D-86) started several `antenna mcp`
  processes from the one config entry: one for its chats and a "shared pool" for its Cowork and Code sessions. The first bound the
  token (D-28); every other one exited with `token_bound: this token is bound to another agent process (pid …); one token = one agent`,
  and Claude Desktop showed "Couldn't start for Cowork and Code sessions". The binding must not get weaker: a stolen token must stay
  useless to another program or process (D-28, D-38, D-P-3, D-P-10).
- **Decision.** A token stays bound to one running app, not to its first process. Another `antenna mcp` with the same token joins the
  agent when its MCP host and the bound one belong to the same running app (`crates/antenna-core/src/app_hosts.rs`): their nearest
  common ancestor is a valid anchor (D-38 no. 7, D-P-3: not PID 1, launchd, systemd, a terminal's session leader or an ancestor of the
  daemon), no process between it and either host leads a session (two programs started from two terminals under one Terminal.app are
  two programs), and it is either a GUI app's main process (macOS, the D-P-3 conditions) or runs the same executable as both hosts
  (an Electron app's helpers on Linux). The extra hosts are kept in memory (they are live processes; each MCP request binds again);
  the database keeps the first host (D-P-9). Everything else is refused as before, with the bound process and the reason in the message,
  and the daemon logs the refused process chain (command names only). All hosts of an agent are **one agent with one session and
  one taint**: an app's chats can share memory and projects that the daemon does not see (D-29: a new process is not a new
  context), so per-process taint would let data read in one chat leave from another without the daemon seeing it; the
  conservative shared taint is kept. `agent list` shows how many `antenna mcp` processes run (`mcp_processes`, CONTROL §4), and the
  window shows it next to the app.
- **Why not the code-signing identity.** Binding to a Team ID and bundle ID through Security.framework would need new FFI (new `unsafe`
  in `antenna-sys`, which needs its own decision and review) and is wider than a running app: any process started from the same signed
  binary would match, including a second copy started by another program. The process tree of the running app is narrower and uses
  what the daemon already reads (D-P-2). If an app turns out to start MCP servers outside its own process tree (through launchd or an
  XPC service), this rule refuses them, and the code-signing identity is the next step to evaluate.
- **Limits (honest).** The boundary is now the running app, not its first MCP process: any process of that app can use the
  token, for example another extension in the same editor window process tree, as far as no session leader lies in
  between. Such code runs inside the app the owner connected and could read the owner's files anyway; the token still
  does not work from another app, a terminal or a process outside the app's tree.
- **Checked.** `crates/antenna-cli/tests/agents.rs::one_token_serves_several_mcp_hosts_of_one_app`: two helpers of one "app" run
  `antenna mcp` with one token (`mcp_processes: 2`, both accepted); a helper in its own session (`setsid`), a helper that is another
  program (`perl`) and a process outside the app's tree are refused with `token_bound`; negative controls: with the old rule (always
  refuse) the second host fails, with the check disabled (always accept) the outsiders get in. The nested-anchor, token-file and
  binding tests still pass (`agents.rs`, `wake*.rs`, `control.rs`).

### D-98 · The sender can withdraw a file the contact has not accepted (maintainer decision, 2026-10-05)
- **Question.** A sent photo hung as "offered" with no way to take it back. The maintainer: add "Cancel" on the outgoing file
  card while the contact has not accepted it; the receiver's pending offer disappears or shows "withdrawn by the sender"; if the
  receiver already has it, say so and promise no false "unsend"; use the file protocol's own path or add one, feature-gated.
- **Decision** (PROTOCOL §19, CONTROL §14). The owner's `file_withdraw {id}` (session, no password: it only reduces what
  happens, like `deny`, D-84, but it is still the owner's; agents do not have it) for a file whose outgoing record still exists
  (the contact has not answered, less than 14 days). The blob stops being served at once. A contact whose node answered the new
  feature `file-withdraw/0` gets a receipt `withdraw_file` / `withdrawn` referring to the offer, in the shared history; its node
  deletes the copy it has not accepted like a rejection (record and file key wiped, a repeat not taken), sends nothing back and
  tells its owner (`file` event, `state: "withdrawn"`). An accepted file stays: a receipt cannot unsend what the contact's owner
  already took. A node without the feature gets no receipt (its strict receipt vocabulary would refuse it and the histories would
  differ); the reply says `contact_cannot_withdraw`.
- **Why a receipt, not a new message type.** Receipts already carry "what happened to that file" in the signed shared history
  (`accept_file`, `reject_file`); the withdrawal is the same kind of fact from the other side, references the offer the same
  way, and needs no new cryptography or envelope field. The feature check keeps older nodes' histories identical.
- **Checked.** `crates/antenna-cli/tests/files.rs::a_sent_file_can_be_withdrawn_until_the_contact_accepts_it` (two daemons:
  withdrawn by the offer's message ID; the contact's copy and its record are gone, its owner got the event, `files accept` is
  `not_found`, the receipt is in its history; nothing left to withdraw twice; an accepted file is not withdrawn and stays saved;
  negative control: with the receiver's handling disabled the test fails);
  `a_preview4_contact_gets_no_withdrawal_receipt` (`#[ignore]`, run against the `v0.1.0-preview.4` release binaries:
  `contact_cannot_withdraw`, nothing `failed`, the history verifies with equal fingerprints; negative control: sending the
  receipt regardless fails it); the "no owner API for agents" checks of the CLI, the protocol and MCP list `file_withdraw`.

### D-UI-19 · The window finds agent CLIs like the user's terminal, starts them clean, counts contacts live, and ends Connect with concrete steps (2026-10-05)
- **Question.** On the clean Mac: Claude Code showed "Not found on this computer"; the agent in Code mode inherited the
  window's own session markers (`CLAUDE_CODE_CHILD_SESSION` from the Claude Code session that had started the window: no
  transcript, no resume) and launchd's short PATH (`cargo` not found); the status line said "0 contacts" right after a
  pairing; the Connect dialog for Claude Desktop ended with "Waiting for the app" and the maintainer did not know what to do.
- **Decision.**
  1. One `ProgramLocator` (`lib/host/program_locator.dart`) serves AI apps, Start agent / Code mode, the agents' PATH and the
     core binaries outside the bundle: the login shell's PATH (`$SHELL -ilc`, once per window session, 5 s), the window's
     PATH, then the official installers' folders (`~/.local/bin`, `~/.claude/local`, the npm global prefix, `~/.bun/bin`,
     `~/.volta/bin`, `~/.cargo/bin`, Homebrew, `/usr/local/bin`); only an executable regular file counts; the AI apps list
     scans again when the window comes back to the front.
  2. Code mode starts agents with an allowlisted environment: every window variable not on the list is removed (other
     agents' session markers `CLAUDECODE`, `CLAUDE_CODE_*`, `CODEX_*`, `GEMINI_CLI*`, `MCP_*`, terminal identities such as
     `TERM_PROGRAM`, other agents' tokens), and PATH is the login shell's, with the standard tool folders as the fallback.
     Agents the daemon starts (wake, resident) already get only an explicit environment (`env_clear`), now checked by a test.
  3. The node status counts the window's live contact list, not `status.links` read at connect.
  4. Connect ends with "What to do now": an app that reads its MCP settings only at start is restarted or opened only on
     the owner's click (its own Quit through an Apple Event, then `open -a`; macOS asks for the Automation permission), then
     the exact first question to ask; the status turns to Connected on the daemon's `agent` event and says how many MCP
     processes of the app run (D-97).
- **Why.** A Dock-started GUI app has launchd's environment, not the user's terminal; anything the window launches or
  names must use one resolver, or the list says "found" while the launch fails. A stale count looked like a failed
  pairing; "waiting" without a next step is not a next step.
- **Checked.** `program_locator_test`, `agent_launch_test` (a real bash run of the wrapper: no markers, this agent's token,
  HOME/LANG kept; fails without the unset line), `status_line_test` (failed before the fix), `connect_restart_test`,
  `app_restart_test`, `live_code_mode_test` with real Claude Code from an environment with 20 `CLAUDE*` variables;
  goldens `42_invite_confirm_button`, `43_connect_restart`.

---

## Own computers and approvals that finish by themselves (2026-10-05)

The maintainer, managing a freshly installed Mac as one of their own machines: the agent in the terminal stopped at
every file and every command and waited for Approve, and after each approval the maintainer had to tell the agent in
its terminal that it was approved. "After approval everything should continue by itself. And there must be a way to
send absolutely all files, even with passwords, to my own machine. Otherwise there is no point: with 20 or 30 such
machines, am I going to press approve on each?" Findings (c) and (f) of the build on the second Mac (2026-10-03) were
the same two problems. Earlier the same day level 5 had been decided to skip the prompts for ordinary files only; the
maintainer then chose that level 5 itself means "my own computer", with no separate switch.

### D-UI-21 · Attachments wait in the composer until Send (maintainer decision, 2026-10-05)
- **Question.** An attached, dropped or pasted file was sent at once; every messenger lets the user see it, add a caption
  and remove it first.
- **Decision.** The paperclip, drops and image pastes put each file in a chip above the input (a thumbnail for images, the
  name and size, ✕), several at a time, kept per contact. Send (or Enter) shares the files in the order they were added, one
  `share_file` each, then sends the text as the caption, only once every file went; a refused file keeps its chip with the
  reason, or "Approve and send" for a secret (the password, then a retry with the approval). Text on the clipboard always
  wins over an image next to it. On a sent, unanswered file card, "Cancel sending" withdraws it (D-98); the receiver's card
  says "Withdrawn by the sender".
- **Why.** It matches every messenger, prevents an accidental send of a sensitive screenshot, and keeps the caption with
  its media.
- **Checked.** `composer_input_test`, `files_test`, `file_withdraw_test` (both sides, both withdrawal answers, an older
  daemon), the live `live_file_withdraw_test`; frames `49_composer_staged`, `50_file_withdrawn`, `26_chat_files` (the
  button).

### D-UI-22 · On macOS the composer takes drops and pastes from other apps itself (2026-10-05)
- **Question.** A screenshot dragged from the macOS thumbnail arrived as "file not found" (the system deletes its temporary
  file right after the drop, and `desktop_drop` 0.8.4 hands Dart the URL only after the drop ended); text from dictation
  apps (Superwhisper) vanished (they paste with a Cmd+V whose Command exists only in the event's flags, which Flutter 3.47
  drops: flutter/flutter#184571, the fix is a draft upstream).
- **Decision.** A small native bridge in the macOS Runner (`ComposerInput.swift`): a drop view stages everything before the
  drop ends into a 0700 folder the window owns outside the daemon's data directory (file promises received there, files
  cloned or copied, image data written as PNG) and reports the copies to Dart; a flags-only Cmd+V, Edit › Paste and an
  accessibility text insert reach the composer at the cursor; clipboard images are read by the Runners themselves (macOS
  and GTK) over `antenna/clipboard`. Copies are deleted after the send, when a chip is removed, on lock, or after a day.
- **What is new and why nothing existing fits.** `super_drag_and_drop` would bring a second Rust build that fetches crates
  outside our lock file (0.9.1 also downloads prebuilt binaries), for one missing behavior; `pasteboard` would bring the
  `crypto` package, a cryptography dependency that needs the maintainer's decision. The bridge is a stopgap: remove its
  paste part once Flutter ships the fix (`docs/WATCHLIST.md`).
- **Checked.** Unit and widget tests for staging (a source deleted 0 and 100 ms after the drop is still sent), data drops,
  the paste rules and the clipboard reader against a mocked channel; the Linux reader under Xvfb with a real GTK clipboard;
  the macOS Swift compiles and the scripted checks (`test/macos/drop_check.swift`, `paste_check.swift`) need a Mac.

### D-99 · Trust level 5 is the owner's own computer: files, messages and secrets go without asking (SPEC amendment by the maintainer, 2026-10-05)
- **Question.** Level 5 ("Self") still asked for approval for secrets, for files from outside the link folder, for
  the sender-side check, for suspicious files and for every command of a task, at the same rate as a stranger's level
  2. For an owner who links 20–30 of their own machines that is a prompt per file, per message with a token and per
  command.
- **Decision.**
  1. **Level 5 means "my own computer".** Choosing it shows one warning that must be accepted: "Level 5 'Self' is for
     your own computers only. This contact will get files and messages without asking, including ones with keys,
     passwords or tokens, and its tasks run without confirmation." The window shows it in the trust picker, for
     `/trust 5`, in the invite and join forms and for their "This is my own computer (level 5)" box (D-UI-20);
     `antenna trust <c> 5`, `antenna invite --trust 5` and `antenna join --trust 5` ask in a terminal and need `--yes`
     without one (`--password-stdin`, scripts). The password stays as for every trust change; the daemon's `trust`
     command is unchanged.
  2. **What level 5 does not hold for approval** (the target contact's current level; for an accept, the lower of the
     level at offer time and now): secrets in a message, a stream, a file's content or name and a request path
     (`secret:*`, `secret_in_name:*`); a file from outside the link folder; the sender-side check's verdict
     (`sender_check:*`; the receiver checks again); a suspicious verdict and a dot-file or auto-executed name when an
     agent accepts. The owner and agents alike. Code: `policy::waived_at_level_5`, `Session::waive_level_5`.
  3. **The scanner still runs and the audit log keeps what it found:** each waived reason is a local audit entry
     `allowed_at_trust_5` on the contact's link, with the reasons (what), the link (where) and the actor (the agent's
     name or `owner`). A stream to level 5 is not cut; its final message's entry records the finding.
  4. **Incoming files from a level-5 contact are accepted by the daemon** right after the check when the verdict is
     clean or suspicious (dot-file names included), with the owner's accept and its receipts (`accept_file` /
     `accepted` to the contact). A threat or a failed check stays in quarantine for the owner (`--force` and the
     password, as before); a name already taken leaves the file for the owner.
  5. **Without a project folder** (the window sets none), level 5 saves into the link's `shared/`, as levels 3–4 do;
     before, every accept from a level-5 contact failed with "the owner has not set a project folder".
  6. **Tasks without confirmation.** A session whose ceiling is 5 (it read data of level-5 contacts only) runs commands
     and writes through the host hook without approval (`check exec`, `check write`), each logged with the command or
     path (one line, at most 200 characters; a command that carries a secret is logged by its length only). Agent
     memory, instructions, configs and keys (the protected paths: `CLAUDE.md`, `.claude/`, `.ssh/`, shell profiles…)
     still need the owner. The command sandbox of SPEC §9's level-5 row is not built: the commands run as the owner's
     own agent would run them without Antenna.
  7. **Unchanged:** levels 1–4; taint (a session that also read a lower-level contact keeps that contact's limits, so a
     level-3 message in the same session means no commands at all); the flow between links (`cross_link`) needs
     approval at every level, because a stranger's text must not reach a machine that runs tasks without confirmation
     unseen; level limits; a threat verdict at the receiver.
  8. **Contacts already at level 5:** the window shows once, at its next start, "Level 5 now also sends secrets without
     asking: keep it or lower to 4", with Keep and Lower to 4 per contact (D-UI-20). A node used only from the CLI gets
     no notice; the release notes say it.
- **Why.** The prompts at level 5 guarded against another person seeing a secret or planting a file; the owner's own
  machine is the owner. One accepted warning per machine replaces a click per file. The scanner and the audit log
  keep the record that the prompt used to make. What stays guarded is what crosses from other people's links (taint,
  the flow between links, a threat verdict).
- **SPEC.** An amendment of §9 and §10 by the maintainer, listed under "SPEC amendments by the maintainer" above.
- **No new mechanism.** The level-5 rules reuse the existing scanner, gates, accept and audit log; nothing new on the
  wire, nothing cryptographic.
- **Checked.** `crates/antenna-cli/tests/own_computer.rs`:
  `level_5_sends_everything_without_asking_and_keeps_threats_out` (two daemons: an agent's and the owner's messages
  with a password and a token, files from outside the link folder with a secret inside and in the name, a suspicious
  file and EICAR, all sent without a request and each finding in the audit log; the receiver accepts the clean and
  the suspicious file into `shared/` by itself and keeps EICAR; at level 4 the same sends ask again and a received
  file waits for an accept) and `hook_runs_level_5_tasks_without_confirmation_and_waits_for_the_owner_below` (the host
  hook at level 5: commands and project writes pass and are logged, a token in a command is not, `CLAUDE.md` still
  asks; at level 4 a command waits for the owner; after reading a level-3 contact no commands at all);
  `stream.rs::at_level_5_a_secret_does_not_cut_the_stream`;
  `antenna-files/tests/pipeline.rs::level_five_without_a_project_folder_saves_into_shared`;
  `policy::tests::level_5_waives_secrets_and_file_prompts_only` and the level-5 rows of
  `tainted_writes_go_only_to_the_link_folder` and `taint_ceiling_and_actions`;
  `agents.rs::no_write_down_secret_scanner_and_approvals_cannot_be_replayed` (secrets to level 1 still ask, for agents
  and the owner). Negative controls: with `split_level_5` waiving nothing the level-5 test stops at the first send
  (`approval_required`), and with the trust check in `StreamWriter::push` removed the stream is cut.
- **Next.** A "My devices" group in the window for the level-5 contacts, so many own machines read as one list.

### D-100 · After the owner approves, the daemon carries out the approved request itself and tells the agent (maintainer decision, 2026-10-05)
- **Question.** An approval only marked the request approved; the agent had to repeat the call (with the approval
  ID), so somebody had to tell it in its terminal. D-70 had the daemon send a stream's final message itself, but only
  that.
- **Decision.**
  1. **The daemon keeps the request.** When an agent's `send_message`, `share_file`, `share_file_content`,
     `file_accept` or `request_file` ends in `approval_required`, the daemon keeps exactly that call in memory: the
     text with the address resolved at the time, the path and name, the open staging file that has no name on disk,
     the file ID and name, the request path; a stream's final message as before (D-70). Such a request carries
     `ApprovalInfo.completes: true`.
  2. **On approval it runs once, under the same binding.** Approve (and each item of `approve_many`) claims the
     approval for the daemon at once, then the daemon runs the same code path as the agent's call, naming the
     approval: the policy is checked again (level, taint, flow between links, limits) and the approval must match the
     request hash with its nonce (SPEC §9). A file changed since the approval fails with `approval_mismatch` and
     nothing is sent; the approval then stays for the agent. A run that used the approval stores its result.
  3. **The agent is told.** The `approval_resolved` event (to the requesting agent's subscription and the owner's,
     `x-control/6` only): `{id, action, requester, contact, link_id?, target?, target_link_id?, state, result?,
     error?, message, at_ms}`, `state` = `completed` (with the reply the action returned), `failed`, `approved` (a
     tool check: the host runs the action, the next check passes once), `denied`, `expired`. The same resolution
     comes once in the agent's next `wait` and `inbox` (`approvals`), and a waiting `wait` returns for it, so
     `wait_for_message` reports it.
  4. **Repeats are idempotent.** A repeat with the approval ID returns the stored result (or waits for the run) instead
     of `approval_used`; another request with that ID is `approval_mismatch` as before. A repeat without the ID during
     the approval's 10 minutes gets the same answer, so an agent that follows the old instructions sends nothing twice
     and asks nothing twice. The owner cannot deny a request that is being carried out, and the expiry sweep leaves a
     running one to finish.
  5. **The host hook waits.** `antenna hook claude-code` waits up to `--approval-wait-secs` (50 s by default, below
     Claude Code's 60 s hook timeout, because a hook that times out does not block the tool) for the owner's decision
     on a tool check: approved → it checks once more (the approval is used) and lets the tool run; denied or expired →
     it blocks with that answer; still undecided → it blocks with "the daemon reports `approval_resolved`, then run it
     again".
  6. **Agents are told not to relay.** The MCP `initialize` instructions (D-88) say: approvals are handled by the
     daemon; after `approval_required`, continue with other work or wait for the `approval_resolved` result; do not
     repeat the call and do not ask the owner in the terminal. The tool descriptions and the `approval_required`
     message for agents say the same and no longer name `antenna approve`.
  7. **The owner's own requests** (a message or file of the owner with a secret, below level 5) are unchanged: the
     owner's client repeats them ("Approve and send").
- **Why.** The approval is already bound to the exact request (hash and nonce), so the daemon can carry out exactly
  what the owner saw without trusting the agent's repeat; the repeat was the only reason a person had to carry the
  word "approved" from the window to the terminal. Nothing broader is granted: one approval still covers one request.
- **Security.** The daemon's run goes through the same policy at the time of the run, so a level lowered in between
  still refuses. It is marked by a task-local value scoped to that one approval ID, not by anything in a request an
  agent could send. A kept request lives in memory only until it is approved, denied or expired (10 minutes); a
  restart forgets it (the safe side). The staging file of `share_file_content` keeps no name on disk while it waits.
- **Compatibility.** Only additions within `x-control/6`: optional `completes`, `approvals`, and an event kind sent
  only to `x-control/6` subscriptions (the preview.4 window and CLI skip event kinds they do not know). An older agent
  that repeats with the ID gets the stored result instead of `approval_used`.
- **Checked.** `crates/antenna-cli/tests/approved.rs`:
  `the_daemon_carries_out_each_approved_request_once_and_tells_the_agent` (a message with a secret, a file from
  outside the link folder, a file changed after the request (`failed`, `approval_mismatch`, nothing sent), a
  suspicious incoming file accepted, a file request with a secret in the path, a denial, a batch of two; each reported
  by `approval_resolved` and once in `wait`, each sent or accepted exactly once, repeats with the ID answered with the
  same result, another request with the ID refused) and
  `mcp_agent_gets_the_result_of_an_approved_upload_from_wait_for_message` (the instructions; `share_file_content` with
  a secret carried out with exactly those bytes and reported by `wait_for_message`);
  `control.rs::approval_requests_expire_by_themselves_and_deny_needs_no_password` (an expired request reaches the
  agent's `wait`); `own_computer.rs` (the hook lets a command through after Approve and blocks after Deny);
  `files.rs::share_file_content_policy_levels_approval_and_secrets`, `files.rs::level2_inbox_only_after_owner_approve`,
  `addressing.rs::batch_approvals_check_the_password_once_and_each_binding` and
  `agents.rs::no_write_down_secret_scanner_and_approvals_cannot_be_replayed` (repeats now return the stored result);
  `policy::tests::the_daemon_carries_out_an_approved_request_once`, `a_running_completion_is_not_expired_by_the_sweep`;
  `antenna_proto` `approval_resolution_is_additive`; the `mcp.rs` unit `instructions_for_default_list_and_nobody`.
  Negative control: with `complete_approved` not spawned, the first `approval_resolved` never comes and the test
  times out.

### D-UI-20 · The window: a warning before level 5, "This is my own computer" at pairing, a one-time notice, approval cards that finish
- **Decision.** (1) Choosing level 5 anywhere in the window (the contact card's picker, `/trust 5`, the invite and
  join pickers, Create for an invite opened at 5) shows the D-99 warning with Cancel and "Use level 5"; Cancel keeps
  the previous level, the password prompt comes after. (2) The invite and join forms have a box "This is my own
  computer (level 5)": ticking it sets level 5 (with the warning the first time in that form), unticking returns to
  the form's default; it follows the picker and the picker follows it. (3) Once, after the contacts load, a notice
  lists the contacts already at level 5: "Level 5 now also sends secrets without asking: keep it or lower to 4", with
  Keep (nothing sent) and Lower to 4 (password, `trust`); remembered as `self_notice_shown` in the window's settings,
  marked shown without appearing when there is no level-5 contact. (4) The contact card reads "5 · Self · your own
  computer" with "Files, messages and secrets go without asking; tasks run without confirmation."; Agents mark
  level-5 contacts "(own computer)" in "takes tasks from…". (5) An approval card with `completes: true` says before
  approval "After you approve, Antenna continues by itself; the agent does not need to be told", and after Approve
  "Approved — Antenna is finishing it…" with no buttons; it leaves on `approval_resolved`, on `used`, `denied` or
  `expired`, or 15 s after the approval at the latest (an older daemon sends no `approval_resolved`); on `failed` it
  says "Approved, but Antenna could not finish it: <reason>" with Dismiss. Batch approve does the same per item.
- **Checked.** `test/protocol/approval_resolved_test.dart` (5), `test/widget/approval_finish_test.dart` (8),
  `test/widget/self_level_test.dart` (8, with a negative control), `test/widget/self_notice_test.dart` (4); frames
  `48_approval_finishing`, `45_self_level_warning(_ru)`, `46_invite_own_computer`, `47_self_level_notice`; the live
  `test/protocol/live_approval_resolved_test.dart` against `antennad` from this tree.

### D-UI-23 · Code mode: the window wakes an idle agent with built-in lines only (maintainer decision, 2026-10-05)
- **Revised by D-UI-25** (the same day): when to type comes from Claude Code's hooks first and its screen only as the
  fallback, and a line for a running turn is continued by the turn's Stop hook instead of being typed.
- **Question.** An agent CLI in a Code mode terminal (Claude Code) reads Antenna only while a turn runs; when the turn
  ends it waits for the keyboard. Messages from a lead agent on another node reached the computer and the daemon
  carried out approved requests itself (D-100), but somebody still had to type "check the chat" or "approved" into that
  computer's terminal. The maintainer: the lead must be able to drive such an agent over Antenna without anyone
  touching the computer, and the window may type only phrases built into the app.
- **Decision.**
  1. **Wake.** When the owner's subscription reports a new incoming text message that an agent running in a terminal
     of this window reads (the D-91 rule: within its links, addressed to it by name, or to everyone or unaddressed
     when its `everyone` is on, or always with a daemon older than v6), the window types one line into that terminal,
     then Enter: "New Antenna messages from <label>: read your inbox and continue.", with the owner's own local label
     of the contact, or "New Antenna messages: read your inbox and continue." when several contacts wrote or nothing
     printable is left of the label. The message itself is never typed: the agent reads it over MCP, as data (D-88).
     History re-read after a reconnect wakes nobody.
  2. **Only when the agent waits for input:** the terminal has been silent for 5 s (Claude Code animates its spinner
     and timer while a turn runs) and its last rows show Claude Code's empty prompt: `❯` between two horizontal rules,
     nothing typed after it (or the hint "? for shortcuts", shown only while the input is empty), no "esc to
     interrupt". Checked against Claude Code 2.1.233 on a real terminal. A permission or folder-trust dialog (where
     Enter answers "Yes"), the owner's unsent draft, Codex and own commands do not match, so the window types nothing
     there by itself; what waits stays pending, one line per agent, until the screen changes.
  3. **Rate.** At most one automatic line per agent per 30 s; what arrives meanwhile is coalesced into the next line
     (typed after the 30 s and another 5 s of quiet).
  4. **"Approved — continue."** After the owner approves a request of an agent running here (Approve, a batch, or an
     approval seen on the subscription; each request counts once), the same rules type "Approved — continue.". When a
     wake waits as well, only the wake is typed: the inbox carries the outcome of approved requests (D-100).
  5. **Quick replies** under a running agent's terminal: Approved, Check the chat, Yes, go ahead, Stop. A click types
     "Approved — continue.", "Check the Antenna chat: read your inbox and continue." or "Yes, go ahead." and Enter;
     Stop sends Escape (Claude Code, Codex) or Ctrl+C (own command) and types nothing. The labels are translated; the
     typed text stays English. A click answers what was waiting of the same kind.
  6. **Switch.** "Wake on new messages" per agent, on by default, in the tab's menu and in Agents (Code mode); it
     covers both automatic lines and is kept in `window.json` (`code_wake_off`). No password: turning it either way
     never widens what an agent can do.
  7. **Enter goes 300 ms after the text, as a write of its own:** Claude Code reads text and a carriage return that
     arrive together as a paste and inserts a line break instead of sending (TROUBLESHOOTING "Code mode wake").
  8. **Log.** Every typed line, automatic or clicked, goes into the window's log (agent, kind, the contact's label,
     time; never message text), and the dock shows the last automatic one ("Woken at 14:32: new messages from Jordan
     Lee"). The daemon gets no audit record: the typing happens on the window's side and the control protocol has no
     command for a client to write into a link's audit log; the message itself is in the link's history.
- **Security.** Everything the window writes into a terminal by itself goes through one method that takes an
  `AllowedLine`, a type whose only values are the phrases above and the wake line with a label (its constructor is
  private). The label is cut down to letters, combining marks, digits, spaces and `. - _ @ ' + & # ( )` (no control
  characters, escapes, line breaks, format or bidi characters, no `:` or `/`), runs of spaces collapsed, at most 40
  characters. So a contact can at most cause a wake (one line per 30 s, and only for an agent that reads its messages
  anyway) and never chooses or adds text; it cannot answer a permission dialog or complete the owner's draft, because
  the window types only at the empty prompt. The line adds no rights: the agent still reads the message as data, under
  the daemon's policy and taint. The same idea as the daemon's wake agent (D-68: a fixed prompt, the message read as
  data).
- **What is new, and why** (D-94: experimental, marked so at the switch). Typing into an agent's terminal on an event
  is a mechanism of our own. The vendor's way to start a turn from outside, Claude Code's *channels* (an MCP server
  that declares the `claude/channel` capability pushes inbound messages into a session started with `--channels`;
  present in 2.1.233), accepts only servers on Anthropic's approved list (otherwise only with
  `--dangerously-load-development-channels`) and is off by policy for Teams and Enterprise organizations, so Antenna's
  server cannot use it today (WATCHLIST). Hooks run only inside a turn. So the window acts as the keyboard, within
  the narrowest rules above; the idle check reads the screen and fails closed when Claude Code's layout changes (no
  wake rather than a wrong one).
- **Checked.** `test/widget/code_wake_test.dart` (15): the idle check on Claude Code 2.1.233's screens (idle, after a
  turn, busy, a permission dialog, a draft); labels; a wake only for a message the agent reads (not for another agent,
  the person, everyone without `everyone`, a link outside its scope, an outgoing message), once, 5 s after the last
  output; one line per 30 s, coalesced, several contacts without a name; nothing while busy, in a permission dialog,
  over a draft, or for Codex; the switch in the menu and in Agents, saved; "Approved — continue." once for a batch and
  not for another agent's request; a waiting wake covers a waiting approval; the quick replies type exactly their
  phrases and Stop sends Escape; message text with control characters and Enter never reaches the terminal (only
  allowlisted writes); a hostile label is sanitized. Negative controls, each seen failing: without the sanitizer, the
  visibility rule, the idle check, the rate limit, or with the message text in the label's place. The live
  `test/protocol/live_code_wake_test.dart` (two real daemons, a real pseudo-terminal running a stand-in for Claude
  Code that records what is typed into it): a message to the person and one to everyone type nothing; a message to
  the agent by name types the fixed line once, 5.4 s after it was sent (Linux, debug build); negative control without
  the visibility rule. Frames `51_code_quick_replies(_ru)`; `34_code_mode(_ru, _dark)` and `44_code_terminal_attrs`
  gain the quick-reply bar.
- **Limits.** Claude Code only: Codex and own commands get the quick replies but no automatic lines until their idle
  prompt is verified. The idle check depends on Claude Code's screen layout. A wake after a turn in which the agent
  already read the message costs one short turn.

### D-UI-24 · Visual polish to reference v3: one button system, one "Secure" indicator, an 8 px grid and type scale, conversations that read like a group chat, minimal settings (maintainer decision, 2026-10-05)
- **Question.** The maintainer, looking at the window on a Mac next to the reference v3 style guide: the drawn design
  "still has not come out; it was laconic and minimal there". The conversation header showed a cluster ("E2E · PQ",
  "History verified" with three animals and a time, "Direct", "online") with a monospaced dump of TLS and libsignal
  facts on hover; Code mode had an icon-only navigation; a row of ten slash commands sat under the message field;
  settings carried a paragraph under every option; buttons were Material defaults outside the approval UI. And for
  conversations with agents: the owner's own messages must not carry an avatar; every agent message shows that agent's
  picture, so it reads like a group chat where agents talk; agents running on this computer carry a "this Mac" mark.
- **Decision** (DESIGN "Visual polish to reference v3"). Style and meaning of the reference, not a pixel copy.
  1. **Tokens.** One type scale, H1 28/36, H2 20/28, H3 16/24, Body 14/20, Caption 12/16, Small 11/14 (`XType`, the
     `XText` styles); spacing on an 8 px grid with a 4 px half step (`XSpace`); radii 4, 8, 12, 16, 24 (`XRadius`);
     motion 0.15 s and 0.2 s. `lib/ui` uses only these: `test/widget/design_tokens_test.dart` fails on an off-grid
     spacer, inset or gap, or a font size off the scale (the verification code and the terminal are the exceptions).
  2. **One button system.** The app's ThemeData maps every FilledButton to primary, OutlinedButton to secondary,
     TextButton to tertiary and IconButton to a quiet icon button: hover, pressed, disabled and a 2 px keyboard focus
     ring outside the button, no ripple (`lib/theme/buttons.dart`, imported by screens from `ui/widgets/x_buttons.dart`).
     Destructive actions are red text (Stop, Revoke, Remove contact…) or, for the one action that removes something for
     good, red on a soft red fill.
  3. **One "Secure" indicator** under the contact's name, then "Direct · online". The word follows the facts: **Secure**
     (green: an end-to-end session and post-quantum facts, PQ as before: the hybrid TLS group and a v4 session),
     **Encrypted** (end-to-end, no post-quantum facts), **Not confirmed** (no session facts), **History differs**
     (red) or **Rekey needed** (amber; a history problem wins over the rest). Its popover, on hover, a click or keyboard
     focus, says in plain words: end-to-end encrypted, post-quantum (or "SPQR still negotiating", "not confirmed"), the
     network mode with what it means, and the history state with the fingerprint's animals and digits (or what is
     wrong), with **Verify now** and **Contact card**; the raw TLS, session, SPQR and incoming facts are behind
     **Technical details**. The banners for a mismatch, a rollback and a rekey stay as they were. A presentation change:
     the same facts, nothing claimed that the daemon did not report.
  4. **Group chat.** In a link where agents take part (D-UI-18), the owner's own messages carry no picture and no name
     (only "→ everyone" when it applies); every other sender has its picture beside the first bubble of its group and
     its name above it; a group is one sender to one addressee, the same day, less than 3 minutes apart, with no file
     card between. My agents' pictures stand on my side. An agent's picture is the mark of its AI only for the owner's
     own agent and only from a fact the window has (the CLI it started in Code mode, now also remembered across
     restarts, or the AI app it connected), otherwise a neutral monogram with a small agent badge; a contact's agent
     always gets the monogram (D-UI-18: a name proves nothing). No character set is drawn before the maintainer chooses
     one: `AgentPicture` is the hook for pictures later (ROADMAP "Profile pictures"). A conversation between two people
     keeps its unsigned bubbles.
  5. **"This Mac"** ("this computer" on Linux) after the name of one of my agents that runs here, as a fact the window
     has: it was started in this window's terminal (in this session or remembered), or an AI app's configuration on this
     computer names it. An agent that only holds a token is not marked (where it runs is not known), and a contact's
     agent never is, whatever its name.
  6. **The server's agent identity** needs no daemon change: a contact's message sent through one of its agents carries
     `via_agent`, and the window shows that agent with its picture and name; a server node that writes as its agent
     ("lead") reads as one participant.
  7. **Minimal settings.** Each setting is one line: its name, a small **?** and the control. The longer explanation
     (the old hint) is behind the **?**: on hover, on a click or tap (it stays until a click outside or Escape), and on
     keyboard focus. The role preset shows one line per role with its own **?**. The LAN privacy trade-off (D-77) is also
     shown in the page at the moment the owner turns the local network on.
  8. **Window.** The labelled navigation (216 px: the wordmark, Chats with its count, Agents, Files, Settings, the
     daemon card, Lock keys) in both modes; Code mode folds it to icons only below 1,400 px, where the terminals need the
     room. The slash commands are offered when the owner types "/", not as a permanent row. The thread and filter bar is
     lighter (outlined counterparts, plain filter tabs, no divider). On macOS the title bar takes the app's theme and
     the navigation's color instead of the system's (`WindowChrome`, `MainFlutterWindow.swift`).
- **Why.** The maintainer's measure is the user, not the market: the header must say "secure" in one word and explain
  itself when asked; settings must read at a glance; a conversation of agents must look like the group chat it is. Every
  existing warning stays reachable, and the facts behind the word are the same the card always showed.
- **Not done here.** The ∞ "My computer" display of level 5 and the trust picker (a separate change); avatars from a
  character set or photos (the maintainer chooses the style first); a full-size content view on macOS with the
  navigation under the traffic lights (needs a Mac to verify dragging and the inset); the live stream bubble keeps its
  name line without a picture.
- **Checked.** `test/widget/design_tokens_test.dart` (3, with a negative control in the test and one seen failing in
  `lib/ui`), `secure_indicator_test.dart` (4: the states from the facts, the popover in plain words with the raw facts
  behind the disclosure, Verify now and the card, keyboard focus, Escape and Enter, every not-secure word, Russian),
  `group_chat_test.dart` (5: the grouping rule, no picture or name on my own messages, the AI mark only for my known
  agents, "this Mac" only for my agents that run here and never for a contact's agent of the same name, two people
  unchanged), `settings_help_test.dart` (5: every section's names and "?" with the hints only behind it, hover, click,
  a tap outside, Tab, Escape and Space, placement near the window's corner, the settings still working in Russian),
  `test/host/window_chrome_test.dart` (3), `code_mode_test.dart` (the navigation by width), `contrast_test.dart` (the
  indicator's words on their tints, the popover, the monogram). Negative controls, each seen failing: the local mark
  for a contact's agent of the same name, pictures on my own messages, a history mismatch shown as Secure, a popover
  without hover and focus, an off-grid spacer. Frames: all regression goldens and showcase frames were redrawn (the
  scale, the grid and the buttons change every screen); new `52_secure_details(_dark, _ru)` and `53_settings_help(_ru)`.

## Check panel, screenshots for Code mode agents, wake from hooks (preview.6, 2026-10-05)

### D-101 · The doctor's facts come in the owner's existing replies; `antenna doctor` (2026-10-05)
- **Question.** Phase 1 of D-96 (the doctor, no model) proposed two commands for x-control/7, `diagnose` and
  `doctor_report`. Two of its checks need facts only the daemon has: whether a link's endpoint reaches its relay
  (each link has its own iroh endpoint), and which process was refused because an agent's token is bound to another
  app (the refusal of D-97 is decided inside `agent_login`). `antenna doctor` answered "not implemented".
- **Decision.** Read-only facts, added as optional fields to existing owner replies of x-control/6 (CONTROL §4); no
  new command, nothing for agents:
  1. `contacts[].transport.relay = {url, connected, error?}`: the link endpoint's home relay as iroh 1.3 reports it
     (`Endpoint::home_relay_status()`, first entry). `error` is iroh's last connection error as one line, control
     characters replaced, at most 200 characters, only while not connected; `url` is empty until a home relay was
     chosen; the field is absent when the node runs without a relay or the link's endpoint is not running.
  2. `agent_list[].session.refused_pid`, `refused_comm`, `refused_ms`, `refused_alive`: the last MCP host refused with
     `token_bound` because the agent's token is bound to another app. In memory only (gone after a daemon restart or
     a lock), the newest refusal wins, cleared when that host later joins the agent or the agent is removed. The
     `agent` event with the change `refused` (at most once a minute per refused host) lets the owner's window refresh.
     The CLI's own refusals (`bind_parent` false) and "this process belongs to another agent" are not recorded: the
     first points at a short-lived command, the second guards against taint laundering, not a binding conflict.
     Agents never see these fields: their `session_view` and `AgentContact` do not carry them.
  3. `antenna doctor` (owner CLI), built only from `status`, `contacts` and `agent_list`: findings `daemon_down`
     (exit code 75), `not_initialized`, `keys_locked`, `relay_disabled`, `relay_unreachable` (a level 1–2 link is an
     error, level 3+ a warning) and `token_bound_elsewhere`, each with a plain "what to do". `--json` gives
     `{state, daemon, relay, findings: [{code, severity, contact?, agent?, detail, fix, facts}], checked_ms,
     skipped?}`. Without an owner session and without a terminal it reports what `status` gives and says that the
     link and agent checks need `antenna login`. The agent CLI's `doctor` stays unimplemented.

  `diagnose` and `doctor_report` stay with the assistant phase (D-96 phase 3), where an agent with the diagnostics
  capability needs them.
- **Why.** Both facts exist only inside the daemon, and the window already reads `contacts` and `agent_list`: adding
  fields needs no protocol version and gives agents nothing. A refused process names itself, so clients escape
  `refused_comm` before showing it.
- **Checked.** proto: `control::diagnostics::tests` (an older daemon's JSON parses; absent fields are not serialized;
  a round trip). core: `transport::tests::relay_error_text_is_one_capped_line`,
  `app_hosts::tests::a_refusal_is_kept_per_agent_and_announced_without_flooding`. CLI: `tests/doctor.rs` (a level-2
  link through the local test relay: `connected` true; the relay stopped → false with the error, measured 3 ms after
  it stopped; `antenna doctor --json` reports `relay_unreachable`; the node's states, `skipped` without a session,
  `keys_locked`, `daemon_down` with 75), `agents.rs::a_refused_mcp_host_is_shown_to_the_owner_and_by_the_doctor` (an
  app's own helpers leave no refusal; an outsider's refusal with its PID, name, time and `refused_alive`; nothing of it
  in the agent's `get_session`; the doctor's `token_bound_elsewhere`), `cli.rs::doctor_without_a_daemon_reports_daemon_down`.
  Negative controls, each seen failing: the relay reported as connected always; the doctor skipping every link; the
  refusal not recorded; the refusal shown to the agent. The window's `live_doctor_test.dart` reads a refusal from a
  real daemon.

### D-UI-25 · Code mode wakes Claude Code from its hooks; its screen is only the fallback (maintainer decision, 2026-10-05)
- **Question.** On the maintainer's Mac Claude Code 2.1.289 runs in auto mode: its idle prompt shows
  `⏵⏵ auto mode on (shift+tab to cycle)` instead of "? for shortcuts", the faint placeholder `Try "fix lint errors"`
  stands after `❯`, and the screen check of D-UI-23 read the placeholder as a draft: the wake and "Approved —
  continue." never fired. The maintainer: Claude Code changes its screen with every release; base the wake on its
  documented, versioned interfaces, keep reading the screen only as a fallback, and say so when neither works.
- **Decision.** (Revises D-UI-23 items 2 and 7; the lines, the rate limit, the switch and the log stay.)
  1. **State from hooks.** Code mode starts Claude Code with session-only settings (`--settings`, as for the policy
     hooks of D-83) that register one fixed command per hook event: SessionStart → at the prompt; UserPromptSubmit,
     PreToolUse, PostToolUse → working; PermissionRequest and Notification `permission_prompt` → a dialog is open;
     Stop and Notification `idle_prompt` → at the prompt; SessionEnd → ended. Every command runs one fixed script that
     the window wrote into a folder of its own (`~/Library/Caches/Antenna/code/session-*` on macOS,
     `$XDG_CACHE_HOME/antenna/code/session-*` on Linux, 0700) and appends only the event's name to the `events` file
     there (0600); the window reads it every 250 ms. What a hook receives (a prompt, a tool's input, the last message)
     is read and dropped. The user's and the project's settings are not touched: Claude Code adds session settings to
     them, and their hooks still run.
  2. **The owner's keys, from the window itself** (the terminal is its widget). Text is a draft until Enter or Ctrl+C
     (Claude Code clears its input on Ctrl+C); a draft deleted with Backspace counts as gone only when the screen check
     confirms an empty prompt. Esc, Ctrl+C during a turn, arrows, Tab, Shift+Tab and other keys make the state unknown
     until the next hook (an Esc that interrupts a turn or closes a dialog fires no hook); a digit in a dialog answers
     it. The terminal's own answers to the program (cursor reports, device attributes, focus reports) are not keys.
  3. **A running turn continues by itself.** A line for an agent whose turn runs is left for that turn's Stop hook:
     the script prints `{"decision":"block","reason":"<the line>"}` once and Claude Code goes on with that line instead
     of waiting for the keyboard. Not when the stop carries `stop_hook_active` (it already follows a continuation: no
     loops); the window then takes the line back and types it at the prompt. The reason is always an `AllowedLine`, and
     the rate limit counts it like a typed line.
  4. **Typing** only when the hooks say Claude Code is at its prompt, the owner has no draft, the terminal has been
     quiet for 5 s, and the screen shows nothing modal: the cursor shown and no numbered choice (`❯ 1.`) on screen.
     That last guard is defence in depth: an agent can write into its own hook folder (it runs as the same user), but
     it cannot make the window type into a permission dialog.
  5. **Fallback: the screen**, when the hooks cannot tell (no hook event within 20 s of the start: an older Claude Code,
     hooks turned off by a policy; or the owner's keys made the state unknown). The check now uses signals a draft
     cannot fake: the cursor stands right after `❯ ` and whatever follows on that row is blank or drawn faint; the
     rules, the bottom position and "esc to interrupt" as before; "? for shortcuts" is no longer needed. When neither
     recognises the state, nothing is typed and the dock says "Wake is unavailable for this Claude Code version".
  6. **Codex** has a documented `notify` program that it runs when a turn completes: the same kind of interface, for
     ROADMAP "Wake for Codex". Until then Codex and own commands get no automatic lines, only the quick replies.
- **Why.** Documented interfaces over screen layout: hook names and their input are part of Claude Code's settings
  format and change with notice; its screen changes with every release (2.1.233 and 2.1.289 differ already). The
  window types only where both its own knowledge (keys, hooks) and the screen agree that nothing else is waiting for
  an answer.
- **Security.** Unchanged from D-UI-23: only `AllowedLine`s reach the terminal or the Stop hook's answer; a contact
  can cause a line, never choose it. The hook folder holds event names only; the agent can write into it, which at
  most makes the window believe a state: typing still needs the screen guard, and a continuation is a fixed line into
  the agent's own context.
- **Checked** on the real Claude Code 2.1.289 (Haiku, a throwaway folder, a few short turns): SessionStart arrived 6 s
  after the start; a prompt gave `prompt`, `stop`; a Bash command that needed permission gave `tool`, `permission`
  (Notification `permission_prompt` had not come 4 s later); Esc in that dialog gave nothing; a waiting line made the
  Stop hook continue the turn (its transcript shows "Stop hook error: Approved — continue.") and the next stop came
  with `stop_hook_active`; a project hook ran next to these; through the window's own launch with a real daemon: the
  hooks, a continuation during a 40-line turn, and a typed line 30 s later. Tests: `claude_state_test.dart` (15),
  `code_wake_hooks_test.dart` (10), `test/host/code_hooks_test.dart` (6, the real script through `sh -c` with JSON on
  its input), `code_wake_test.dart` (18: the 2.1.233 and 2.1.289 screens, auto mode, a draft that starts with
  `Try "`, the cursor moved back to its start, faint text with the cursor elsewhere), the live
  `live_code_hooks_test.dart` (the real hook channel and a stand-in that runs the hooks as Claude Code does: a message
  during a turn is continued once, nothing typed), `live_code_wake_test.dart` (the screen fallback),
  `live_code_mode_test.dart` (the real Claude Code 2.1.289 binds `antenna mcp`). Negative controls, each seen
  failing: the screen check without the faint test, without the cursor test; the screen guard always passing; a draft
  ignored when idle; a dialog or a running turn typed into; the owner's keys not making the state unknown; the Stop
  hook script ignoring `stop_hook_active`.

### D-UI-26 · The Check panel: fixed checks with one-click fixes (local assistant phase 1, 2026-10-05)
- **Question.** D-96 phase 1: fix-it buttons that need no model, for the problems people actually hit: the daemon not
  running, the keys locked, the relay unreachable, an AI app's program missing or not on PATH, an app that needs a
  restart to read its MCP settings, an agent token bound elsewhere.
- **Decision.**
  1. **Where.** Settings → **Check**; the sign-in screen's "Check Antenna" under the card (the daemon down, the keys
     locked, the window signed out); "Check" in the daemon details. One panel: every check as a row (fine, a problem,
     worth knowing, or "not checked" with the reason), its facts, its code (D-96 §4.1) and its fix; "Check again"
     reads fresh facts first (status, contacts, agents, the local network, the login shell's PATH, the apps' files).
  2. **Checks and fixes.** `daemon_down` → **Start Antenna** (the window's own LaunchAgent or child; a socket of
     another daemon says where to start it); `keys_locked` → **Unlock** or **Sign in** (the password, as at sign-in);
     `relay_unreachable` → which links, their level, "relay only", the relay and the error, the same report in a
     terminal (`antenna doctor`), and **Turn on the local network** when a level 3+ link lost its relay (the password,
     D-77); `relay_disabled`; `ai_cli_missing` → **Install guide for <app>** (the vendor's page, checked
     2026-10-05: Claude Code `code.claude.com/docs/en/setup`, Codex `learn.chatgpt.com/docs/codex/cli`, Gemini CLI's
     repository, Grok Build `docs.x.ai/build/overview`); a problem when the owner uses the app (connected, or started
     in Code mode), worth knowing otherwise; `ai_cli_not_on_path` (found in a folder the login shell's PATH lacks) →
     **Add <folder> to PATH**: a dialog shows the two lines and the profile file (`~/.zprofile` for zsh,
     `~/.bash_profile` or `~/.bashrc` for bash, `config.fish` for fish, `~/.profile` otherwise); after a click the
     window backs the file up and appends them (appending keeps a profile that links into a dotfiles folder a link),
     reads the login shell again and checks; only plain folder names (letters, digits, `/ . _ + @ -`) are offered, so
     nothing is quoted into a shell line; `app_restart_needed` (an app that reads its settings at start, connected
     here, running, its agent bound by no process: macOS app bundles) → **Restart <app>**, its own Quit then open,
     after a confirmation that it may ask to save work; `token_bound_elsewhere` (from D-101's refusal) → who holds the
     agent and who was refused, and **Start <Claude Code or Codex> as a new agent** (Start agent with a new agent and
     that program) or **Open AI apps**.
  3. **Owner actions only.** Every fix is the owner's click: an existing owner command (`unlock`, `login`, `lan_set`,
     `agent_add` through Start agent) or a local action shown before it runs. Agents get nothing new; no owner command
     moves to the agent or MCP surface (rule 2 of the project).
- **Why.** Most setup problems are visible to Antenna and have one right fix; a button with the exact action shown is
  safer and faster than instructions, and needs no model.
- **Checked.** `test/widget/doctor_test.dart` (16: each check on its inputs; each fix in the panel: Start from the
  sign-in screen, Unlock with the password, the relay facts with `antenna doctor` and the local network, the PATH line
  shown first and appended once then found, the install guide opened, Restart in the right order after a
  confirmation, a refusal with "Start Codex as a new agent"; the PATH line per shell; folder names that are not plain
  text refused; appended once after a backup, a linked profile kept a link), `live_doctor_test.dart` (a real daemon:
  the keys locked, then a refusal read from `agent_list`). Negative control: the PATH line taking any folder (seen
  failing). Frames `54_check_panel` (light, dark, Russian).
- **Limits.** The PATH check needs the login shell (read once per window session; again after the fix). "Needs a
  restart" is told only for macOS app bundles (elsewhere the window cannot see whether the app runs). The vendor
  installers are linked, not run (the D-96 design's install-in-a-terminal-tab is left for later).

### D-UI-27 · A screenshot for an agent in Code mode (maintainer decision, 2026-10-05)
- **Question.** The maintainer: a button by the Code mode terminal takes a screenshot (an area or a window) and hands it
  to that agent, so the owner does not have to explain where on the screen something is. Only window-made content may
  reach the terminal, only on the owner's click, never into a dialog.
- **Decision.**
  1. **Taking it.** **Screenshot** next to the quick replies runs the system's tool: macOS `screencapture -i -o -x -t
     png` (drag an area, Space for a window, Esc cancels); Linux the first installed of `gnome-screenshot -a`,
     `spectacle -r`, `xfce4-screenshooter -r`, `grim` with `slurp` (Wayland; only a geometry from `slurp` reaches
     `grim`), `maim -s`, `scrot -s`, ImageMagick `import` (X11); no tool, no button. The file goes into the window's
     folder (`~/Library/Caches/Antenna/screenshots/<agent>` on macOS, `$XDG_CACHE_HOME/antenna/screenshots/<agent>`
     on Linux, 0700) under a name the window chose (`screenshot-YYYYMMDD-HHMMSS.png`), and is deleted after a day.
  2. **Handing it to Claude Code.** Claude Code attaches an image when its path arrives as a paste: one bracketed paste
     (`ESC[200~<path>ESC[201~`) of the PNG's absolute path becomes "[Image #1]" in its prompt (checked on 2.1.289); a
     path typed key by key stays text, and a leading `/` opens its command menu. The window pastes, without Enter: the
     owner adds what to do and sends. Code mode starts Claude Code with `--add-dir` on the agent's screenshot folder,
     because the model may still open the file with its Read tool, which asks for permission outside the working
     folders.
  3. **When.** Only on the owner's click, and only when Claude Code is at its prompt by its hooks (a draft is fine: the
     paste adds to it, nothing is sent) or, where the hooks cannot tell, by the screen check; never in a dialog (the
     screen guard of D-UI-25) and never into a program that did not ask for bracketed paste. Otherwise it waits for the
     prompt for 2 minutes, then stays in its folder with its path and **Copy**. After the paste the prompt holds the
     attachment, so no automatic line presses Enter over it.
  4. **Codex and own commands:** the screenshot is taken and kept; the owner gets its path to copy; nothing is typed.
- **Security.** `AllowedLine.screenshot` takes only a `WindowScreenshot`, whose constructor is private to the store
  that wrote the file: in the agent's own folder, under the window's name pattern, a regular file (not a link), not
  empty, under 64 MB, with the PNG signature; and the path is pasted only when it is plain text (`/`, letters, digits,
  `. _ -`). Nothing from a contact, a message or another file can become a pasted path.
- **Checked** on the real Claude Code 2.1.289 (Haiku, a throwaway folder): the bracketed paste of a red PNG's path gave
  "[Image #1]" and the answer "Red."; typed key by key it stayed text and opened the command menu; a file outside the
  working folder made the model ask to read it, and `--add-dir` on its folder removed the question; through the
  window's own launch the button's paste gave "[Image #1]". Tests: `code_shot_test.dart` (9: exactly one bracketed
  paste of the path and nothing else, no Enter over it afterwards; `--add-dir`; waiting through a turn; never into a
  dialog, kept with its path after 2 minutes; a forged "idle" with a dialog on screen; no bracketed paste mode; Codex
  gets the path; a cancel; no tool, no button), `test/host/screenshot_test.dart` (10: the tools and their arguments,
  `slurp`'s output checked, the folders, the name, refusals of other names, folders, links and non-PNG files, a path
  with a space kept but not pasted, the daily sweep). Negative controls, each seen failing: any file in the folder
  accepted; a path that is not plain text pasted; a paste outside the prompt. Frames `55_code_screenshot(_ru)`.
- **To verify on a real Mac:** `screencapture -i` from the app (macOS asks for Screen Recording the first time; without
  it only the desktop is captured), the paste into Claude Code there, and a Linux desktop with each tool.

## Touch ID and updates without the owner at the computer (2026-10-06)

### D-102 · Touch ID: a Secure Enclave key signs owner commands, the daemon verifies (maintainer decision, 2026-10-06)
- **Question.** The owner types the password for every approval and unlock (ROADMAP: approve with Touch ID). The
  options and their threat analysis: (A) a Secure Enclave key signs
  each owner command and the daemon verifies the signature; (B) the password kept in the keychain behind biometry;
  (C) what proven apps do. The app is ad-hoc signed (no Team ID), which rules out the data-protection keychain and
  makes (B) little more than a check in our own code.
- **Decision (maintainer, 2026-10-06).** (A), experimental: a CryptoKit Secure Enclave P-256 key with
  `.biometryCurrentSet`, enrolled with the password in Settings → Security; the signature covers a one-time nonce
  from the daemon and the hash of the exact command (an approval's fingerprint, a batch's items), so one touch is one
  command or one batch; unlock through a second keystore slot whose key is released only through the Secure Enclave
  key. P-256 verification uses `aws-lc-rs` directly (already in every build as the TLS provider of rustls and iroh;
  FIPS 140-3; a cryptography dependency decision taken by the maintainer); no new crate, no own construction (D-1).
  Touch ID serves every command that asks for the password today; the password stays for enrollment, the security
  settings, after a fingerprint change and every 14 days. A software key stands in for the Secure Enclave only in debug
  builds; release binaries refuse it (checked like the update test key, D-82).
- **Why.** One touch per command without a stored password; the daemon, not the window, checks each proof (SPEC §9),
  and the proof cannot be replayed for another command. Proven model (Secretive, passkeys).
- **Built (preview.8, 2026-10-06; experimental, D-94; protocol `x-control/7`, CONTROL §22).** The daemon: owner keys
  in the encrypted database (at most 8), `owner_challenge` (32 random bytes, 60 s, used once, bound to the client
  process and its session token), a `proof` next to the request in place of the password (ECDSA P-256 / SHA-256,
  `aws-lc-rs` `ECDSA_P256_SHA256_FIXED`), the unlock slot, `antenna owner-key list|remove`. Where the build differs
  from the proposal, and why:
  1. **The signature covers SHA-256 of the exact request bytes on the line**, not of a canonical CBOR re-encoding. The
     window (Dart), its Secure Enclave helper (Swift) and the daemon would each need one canonical encoder of every
     request; a disagreement turns a valid touch into a refusal, and two encoders that read one request differently
     would be worse. Hashing what the daemon parses removes the question (the D-82 manifest signature covers the
     exact file bytes for the same reason). The request carries what the owner approved: an approval's ID and
     `fingerprint` (new optional field of `approve`), every item of a batch.
  2. **No node ID in the signed message.** A node has no identity of its own (every link has its own keys, SPEC §5);
     the nonce is this daemon's, single use and bound to the client, which is what keeps a proof from being used
     anywhere else.
  3. **The unlock slot is its own file** (`keyslots.cbor`), not a second slot inside `keystore.cbor`: every released
     daemon parses `keystore.cbor` strictly, so a new format there would make the version an `antenna update
     --rollback` brings back unable to unlock at all. `keystore.cbor` (the password slot, v0) is never rewritten; the
     slot's AAD covers SHA-256 of it, and the database, not the slot file, decides whether the key is still enrolled.
     The construction is the password slot's with HKDF-SHA256 in place of Argon2id (the slot key is 32 random bytes):
     no new primitive and no new combination in the daemon. The window seals the slot key with CryptoKit HPKE to a
     Secure Enclave key-agreement key (macOS 14+), Apple's construction, not ours.
  4. **Enrolling takes the password and a proof by the new key** (proof of possession: one touch, over an
     `owner_challenge {enroll: true}`, of the request that names the key and its label), so a key the window cannot use
     with this finger is never stored. A challenge serves its purpose only: an enroll challenge proves nothing else,
     and enrolling takes no other challenge.
  5. **Which commands take a proof is a list** (CONTROL §22.2), not "every command with a password": a password command
     added later, such as D-103's setting, takes only the password until someone decides otherwise. `init`, `unlock`
     (it has the slot instead), `owner_key_add` and `update_authorize` (the password, or a session as before) refuse a
     proof with `password_required`.
  6. **The 14 days and "three failed proofs" are the daemon's rules**, not the window's: the last correct password is
     kept in the database, failed proofs are counted in memory; `owner_challenge` itself answers `password_required`,
     so the window asks for the password before it shows a Touch ID sheet (an enroll challenge is issued anyway: the
     enrollment carries the password). Proof failures also count in the D-37 limiter. "After a fingerprint change" is the window's (the Secure Enclave key dies with `.biometryCurrentSet`).
  7. **Removing a key needs neither the password nor a session** (like `deny`, D-84: it only takes a way in away);
     `antenna owner-key remove <id>` revokes one from a terminal.
  8. **The test key** is a published P-256 key accepted only by a debug build started with `ANTENNA_OWNER_TEST_KEY=1`
     (D-82's pattern; `owner_keys.test_key` reports it, `packaging/linux/check-install.sh` requires `false` from the
     release build). Any other software key can be enrolled with the password: the daemon cannot tell it from a Secure
     Enclave key, so the Secure Enclave's guarantee is the window's, and the password decides what is enrolled.
  9. **The window** uses proofs for approvals (one, a batch), unlock and sign-in, and Settings → Security (D-UI-28); its
     other password prompts (trust, invite, revoke, tokens, …) keep the password for now, though the daemon already
     takes proofs for them.
- **Threats, and what answers them** (the experimental track's analysis):
  | Threat | Answer | Test |
  | --- | --- | --- |
  | A proof replayed | the nonce is taken by the first proof that names it, valid or not | `challenge_invalid`, live and unit |
  | A proof for one command used for another, or for another approval fingerprint | the hash of the exact request bytes | `proof_invalid`, live and unit |
  | One item of a batch changed | the whole line is signed: the call is refused, nothing approved | live |
  | Another process uses the window's challenge | bound to the client process (PID, start time) and its session token | a `perl` child's nonce refused, live |
  | Malware of the user reads the Secure Enclave blob | it can ask for a touch with its own text; one touch is still one command; the guide says to cancel a prompt nobody clicked for; a Developer ID would bind the key to the app | residual (CONTROL §22.6, §11 item 14) |
  | The slot file read or copied | useless without the slot key, which exists only sealed to this Mac's Secure Enclave key | — |
  | The slot file replaced or kept after its key was removed | AAD over the header and the keystore; the database decides | `slot_invalid`, the stale-slot test |
  | Online guessing through proofs | the D-37 pause and three-in-a-row → the password | live |
  | An agent | no commands, no `proof` key on an agent line, no MCP tools, no agent CLI command | the three "no owner API" checks |
  | A build people run trusting the test key | the branch that reads the variable is compiled into debug builds only | `check-install.sh`, the release binary checked by hand |
  | An older daemon | it refuses the `x-control/7` hello, so the window keeps the password | the client's fallback |
- **Checked** (Linux build server, debug unless said). `cargo test --workspace --locked` with two extra fds: 484
  passed, 9 ignored. New: `tests/owner_keys.rs` 4 (valid; another key; a removed key; another command's hash; another
  approval fingerprint; replayed, expired, foreign (a `perl` child process) and session-bound nonces; malformed
  signatures; a batch with one tampered item; a password next to a proof; proofs on password-only and password-less
  commands; three failures → the password; sign-in with a proof; enroll challenges; unlock by slot, a wrong or removed
  slot key, a stale slot, the password slot's bytes unchanged; the 14 days with a shortened period; the test key refused
  without the variable); `keystore::slots` 4 and `owner_keys` 7 unit tests (a signature vector made by Python
  `cryptography` 41 / OpenSSL 3.0 verifies); `antenna-proto` 63; the three "no owner API for agents" checks extended
  (CLI, protocol, MCP). Negative controls, each seen failing: the slot AAD reduced to its label; `verify` returning
  success; the bind check removed from the challenge; the challenge's purpose check removed; the test-key gate open;
  the slot's database check skipped; the 14-day check removed; `owner_key_list` listed as an agent command. Release
  build: `antennad` started with `ANTENNA_OWNER_TEST_KEY=1` reports `test_key: false`, refuses to enroll the test key
  (`owner_key_refused`) and enrolls a key made by Python `cryptography` over the wire. `tools/check-darwin.sh` debug and
  `--release`; fmt and both clippy passes.
- **Open.** The Mac checks of proposal §7 items 1–4; a signature from a real Mac kept
  as a test vector; Touch ID on the window's other password prompts; the same proof carried from another own device
  (a remote owner action, its own decision); Secure Enclave ML-DSA-65 keys on macOS 26+ (`libcrux-ml-dsa`); binding
  the key to the app with a Developer ID.

### D-UI-28 · Touch ID in the window: one touch per request or listed batch, the password always one click away (2026-10-06, experimental)
- **Question.** How the window offers D-102 without hiding the password or showing a Touch ID sheet the owner did not
  ask for.
- **Decision.**
  - **Settings → Security → "Use Touch ID"** (Experimental), one line, shown only on macOS with Touch ID and a daemon
    that speaks `x-control/7`. Turning it on opens a dialog that says what changes and when the password is still
    asked, takes the password, then one touch: the window creates two Secure Enclave keys (signing and key agreement,
    `.privateKeyUsage` + `.biometryCurrentSet`), enrolls the signing key with `owner_key_add` and a proof by the key
    itself over an `owner_challenge {enroll: true}`, and seals the unlock slot's key with CryptoKit HPKE to the
    key-agreement key (macOS 14 and later; on 12–13 enrollment uses `unlock: false`). Turning it off removes the key
    (`owner_key_remove`, no password) and the local files. The "?" shows when the password is due next.
  - **Approvals:** with it on, "Approve with Touch ID" is the primary action on every card (the list and the
    conversation), with "Use password" beside it; "Approve all from this agent" and the list's "Approve selected" take
    one touch for the listed batch. `approve` carries the card's `fingerprint`, every batch item its own, so the touch
    signs what the owner saw.
  - **The gate:** locked → "Unlock with Touch ID" (one touch opens the slot key; the same evaluated `LAContext` then
    signs `login {hold}`); keys unlocked without a session → "Sign in with Touch ID". The password field stays below.
  - **Prompts start from a click** and their reason names what is approved ("approve sending a message to Bob",
    "approve 3 requests from claude", "unlock Antenna and sign in"; names cut to 32 characters, control characters
    removed). The challenge is asked before any prompt, so a `password_required` never costs a touch.
  - **Every failure leads back to the password, saying why:** cancelled, Touch ID unavailable or locked out, 14 days
    passed, three failed attempts, the key gone from the daemon (dropped locally too), fingerprints changed (the key is
    dead; turn Touch ID on again with the password).
  - **Linux and daemons before v7 show nothing.** The window's other password prompts (trust, invite, revoke, agent
    tokens, …) keep the password in this version.
  - The keys live as Secure Enclave blobs in `~/Library/Application Support/Antenna/touchid/<hash of the socket path>/`
    (0700, files 0600), with the biometry domain state at enrollment; no keychain item (the app has no Team ID).
- **Why.** One touch replaces typing the password without weakening the binding: the exact request text, with its ID
  and fingerprint, is what is signed (D-102). The password stays one click away everywhere (proposal §3, the rules
  1Password follows). A sheet nobody clicked for is the residual risk of an ad-hoc app (any process of the user can
  use the key blob, with a touch), so the window never raises one by itself and the guide says to cancel such a sheet.
- **Checked.** `flutter analyze` clean; the non-live suite (new: `test/widget/touch_id_test.dart` 23,
  `test/protocol/owner_proof_test.dart` 5, `test/host/touch_id_test.dart` 5, the fallback chain in
  `client_v6_test.dart`); `test/protocol/live_owner_keys_test.dart` 4 against a real daemon (enroll, approve one, a
  batch, lock → unlock by slot → sign in, sign in alone, off; refusals; enrolling when the password is due), signing in
  software with `openssl` and the published test key. Negative controls seen failing: the line re-encoded instead of
  the signed text, approve without the fingerprint, batch items without fingerprints, signing before the challenge, the
  gate starting Touch ID by itself, the Linux host offering it, sign-in signing inside the session dialog. Frames
  `56_touch_id_settings`, `57_touch_id_enroll`, `58_approval_touch_id`, `59_unlock_touch_id` (light, dark, ru).
  **Not checked:** the Swift side (`macos/Runner/TouchID.swift`) compiles and runs only on a Mac, and is
  checked there.

### D-103 · Signed updates install by themselves when the owner turned that on (maintainer decision, 2026-10-06)
- **Question.** An update needs the owner at the computer twice: to install it and to unlock the keys after the
  restart. The maintainer manages their own computers through Antenna and wants an update sent at night to install
  and come back by itself, agents included (proposal §4).
- **Decision (maintainer, 2026-10-06).** Experimental, off by default, turned on per computer with the password:
  1. **Automatic install** of a release that `antenna update` would accept anyway (the pinned release keys, newer,
     this platform), triggered by release files from a level-5 contact or by the daily check of the update URL, and
     installed only after 10 minutes without agent activity. A level-5 contact may deliver release files and nothing
     else remote: owner commands, downgrades and rollbacks, the update URL and keys, these settings and unlocking stay
     with the owner at the computer. **SPEC amendment (§13):** signed updates may install by themselves when the
     owner turned that on for the computer.
  2. **Keys across the update's restart, in memory (R2):** the daemon swaps the files and `execve`s the new
     `antennad` with the same PID, handing the root key over an inherited pipe; nothing is stored. If the new version
     fails, the old one comes back locked, as today.
  3. **Code mode agents restored after the update** (per agent; the token file and `claude --resume` / `codex resume`)
     and woken with a built-in line; while nobody has signed in, the window that started an agent gets only that
     agent's own facts.
  4. **Unlock after a reboot or a crash from the computer's key store (R3): later**, only after a Developer ID (Team
     ID) and only with FileVault on.
  5. One release signature is enough for automatic installs of previews; **a second release key is required before a
     public release offers automatic installs.**
- **Why.** The owner's own computers (level 5) should not need a person for an update, without opening a remote path
  to anything but a signed release; R2 keeps the key out of storage; R3 waits until the key store can bind the key to
  the app.
- **Built (preview.8, experimental; `docs/UPDATES.md` §8, `docs/CONTROL.md` §23, window: D-UI-29).**
  1. The setting is an owner command with the password both ways (`update_auto_set`), kept in the encrypted
     database; `update_auto_status`, `update_auto_now`, `update_auto_later`; `antenna update --auto
     on|off|status|now|later`. `x-control/7`.
  2. The trigger is a release-named file that the daemon itself accepted from a level-5 contact (`accept_own`), or
     the daily URL check; nothing else calls it. The verification is `antenna-update`'s (`package::locate`,
     `open_release`, `check_newer`, `find_asset`): the core now depends on `antenna-update` (a leaf crate with no
     workspace dependencies, so the dependency direction holds). The same version is ignored without a record, so
     re-sent files are quiet.
  3. R2 as proposed, with one difference: a new version that answers but came up locked (no key in the pipe) is
     kept, not rolled back; rolling back would come up locked too and lose a working, signed release. The pipe
     carries `0x01 ‖ key ‖ installer PID`, so the new image can reap the installer that is still its child. The only
     new `unsafe` is `antenna_sys::fds::take_inherited_pipe` (an inherited descriptor, a pipe, once).
  4. The installer must outlive a failing new daemon: its own process group (launchd) and, under the `install.sh`
     unit, its own scope (`systemd-run --user --scope`); without `systemd-run` the install is refused.
  5. `agent_watch`: the agent's own subscription (the same filter as the agent's `subscribe`) for a strict ancestor of
     the agent's bound process that is not itself under any agent; PID 1, `systemd` and `launchd` never count. A
     window started as the daemon's parent (Linux) qualifies, so the ancestor test does not use `valid_anchor`.
  6. Not built: R3; the window's notice text and its five minutes come from the daemon's `soon` event (D-UI-29).
- **Checked (Linux build server, debug).** `crates/antenna-cli/tests/auto_update.rs` (real daemons: the end-to-end
  install from a level-5 contact in about 11 s, the same PID, unlocked, the link both ways, the key in none of the files
  under the data, link, install and home folders nor in `/proc/<pid>/environ` and `cmdline`, no extra pipe; refusals of
  older, other-platform and unsigned releases and the same version ignored; the test key refused without the variable;
  level 4 and the setting off start nothing; a busy agent holds it; a failing version comes back locked and is not
  retried; without the pipe locked; the password both ways and `unsupported_install` on a development build; the
  update URL over a local HTTPS server; the window's `soon`, Later and Install now), `agent_watch.rs`,
  `duplicates.rs`, `antenna-update` `install::handover_tests` (fake OS: systemd restart, LaunchAgent kickstart and the
  window reopened, a hand-started daemon started again with its arguments, a PID that is not the daemon never
  signalled), the no-owner-API checks (CLI, protocol, MCP). Negative controls, each seen failing: the owner's accept
  triggering (level 4 installs), the setting not checked, agent calls not counted, failed versions retried, older
  releases not refused, the handover pipe left open, the key written to the log, the ancestor check off (an outsider
  watches the agent), the PID guard off.
- **Not checked yet.** On a Mac: `launchctl print` showing the same PID after the `exec`, the window closed and opened
  again by the installer, Code mode restore with the real Claude Code and the wake line. A real systemd user unit
  (`systemd-run --scope` from the unit; the build server's user manager is shared). A second release key (item 5).

### D-UI-29 · The window's part of signed updates that install by themselves: the switch, "ready to install", Code mode agents restored after the update, received files whose name is taken (2026-10-06)
- **Question.** D-103 needs the window in four places: the per-computer switch; a way to see and start an install;
  Code mode agents that come back after the update's restart (the installer closes the window with SIGTERM, and nobody
  signs in to the new one); and two findings on the maintainer's Mac. First, the Install button existed only on the
  accepted manifest's card in Files → Decided, among 22 items, while the re-sent copies above it said only "Part of the
  signed Antenna update …". Second, accepting identical re-sent release files (the same BLAKE3, already in the link's
  `shared/`) opened "Another name" with the same name filled in, and pressing Accept did nothing: no error, the dialog
  stayed.
- **Decision.**
  1. **Protocol.** The window speaks `x-control/7` and falls back one version at a time (v6, then v5). An older daemon
     is never sent a v7 command: there is no switch (one line says the daemon is older), no name check and no watch;
     everything else works as before.
  2. **Settings → Updates → "Install signed updates by itself"**, per computer, off by default, experimental (D-94):
     turning it on and off each asks for the owner password, which the daemon checks. Where the installation cannot
     replace itself the switch is disabled with the daemon's reason, and an `unsupported_install` refusal is shown.
     Under it: the staged release ("Antenna 0.1.0-preview.9 from Build bot: installs when agents are idle", or the
     time it installs at), the last record (installed, failed or refused, with the reason), the versions not tried
     again, the update address and its last check.
  3. **"Antenna <version> is ready to install"**: one banner at the top of Files and in Settings → Updates whenever a
     release newer than the running daemon can be installed. From an accepted release manifest in any link folder that
     the CLI verified (signed by a pinned key, newer, this computer's file next to it, an installation that can be
     updated): **Install** opens the usual dialog with the password. From the release the daemon staged: "Installs by
     itself when agents are idle" with **Install now** (`update_auto_now`), and once the daemon says it installs soon,
     the time and **Later**. At equal versions the staged one wins (one click, no password). A release that is
     installed already or older is never offered: the CLI's `newer` and the daemon's running version both decide (a
     manifest checked before an install is stale after it). The cards keep their own buttons.
  4. **A received file whose name is taken** (CONTROL §14). Accept on the card first: the same file under the name is
     accepted without a second copy (`duplicate: true`) and the card says "Already in the folder: the same file"; a
     waiting card says so before the click too (`file_name_check`, once per waiting file, asked again after any
     accept). Another file under the name opens **Another name**, filled in with the daemon's free suggestion
     (`report (2).pdf`); every edit is checked 300 ms after the last key; Accept stays disabled, with the reason shown,
     while the name is taken or invalid. The dialog accepts the file itself, so every refusal of the accept is shown in
     it and the dialog stays open; a name the accept refused is never sent again as it is (also with a daemon that
     cannot check names). The silent no-op had two causes: the old flow sent the refused name again, up to three
     times, each time reopening an identical dialog (it looked as if the dialog stayed), and then ended without a word;
     and the dialog's text controller was disposed while the dialog was still animating out.
  5. **Code mode agents restored after an update** (D-103), per agent **Restore after an
     update**, on by default, next to "Wake on new messages" in the tab's menu and in Agents (Code mode), kept in
     `window.json`. Such an agent (Claude Code or Codex, with a v7 daemon) gets a token file (`agent_add` /
     `agent_token` with `token_file`, D-86) and `ANTENNA_AGENT_TOKEN_FILE` in its environment instead of the token;
     never a token in its arguments or in a config. The CLI's own session ID comes from Claude Code's hooks (every
     hook's input carries `session_id`) and from Codex's documented `notify` program (one JSON argument with
     `thread-id`), passed as `-c notify=[…]` for that session only; fixed scripts in the window's hook folder keep the
     ID only when it is a UUID (36 characters of `[0-9a-f-]` right after the key), and the window checks it again.
     `agent_runs[agent]` keeps the CLI, the folder, the own command, `session`, `token_file` (the path), `restore`,
     `running`, `started_ms` and `restored_ms`. `running` is set when the agent starts and cleared when its process
     ends while the window lives (Stop, the window's quit question, the agent exiting); the installer's SIGTERM leaves
     it set. When the window starts it restores an agent only when the daemon is unlocked and reports `status.updated`,
     the agent was running, started before the update came up, has not been restored for this update, its switch is
     on, its session ID is valid, its token file is the daemon's file for this agent and its folder exists:
     `claude … --resume <id>` or `codex … resume <id>` (never `--continue`, which takes the newest session in the
     folder). It then gives one built-in line, "Antenna was updated to <version>: read your inbox and continue." (the
     version cut to SemVer characters, at most 40), once, by the rules of D-UI-25 (the Stop hook continues a running
     turn; typed only at the idle prompt; never into a dialog or over a draft); "Wake on new messages" covers it. An
     update that came up locked restores the agents once the owner unlocks.
  6. **Wake without a session.** While the window has no owner session, it opens `agent_watch` (CONTROL §23) for each
     restored Claude Code agent and turns each `message_fact` into the usual wake line for that contact; it tries again
     with growing pauses until the agent's MCP server is bound, and closes the watch when the owner signs in (the owner
     subscription takes over), the agent stops or the keys are locked. A daemon without the command: no watch, and the
     sign-in screen and the dock say so. The sign-in screen names the restored agents.
- **Why.** The owner's own computers should come back from an update with their agents working, without anyone at the
  keyboard (D-103), and the release that waits should be one click away wherever its files sit in the list. Every
  fact the window shows or acts on comes from the daemon or the CLI; the window decides nothing about a release.
- **Security.** The switch is an owner command with the password both ways; the window offers only what the CLI
  verified or the daemon staged and checks no signature itself. The restore adds no power: the token file is the
  daemon's own 0600 file (D-86), named in the environment only; the session ID can only be a UUID (an agent can write
  into its hook folder, so the window validates what it reads); nothing is restored without the daemon's unlocked
  state and its own update fact, and at most once per update. The update line is an `AllowedLine` (a contact chooses
  nothing typed). `agent_watch` is allowed by the daemon only to an ancestor of the agent's bound process and carries
  the agent's own facts, no text; before sign-in the window has no owner powers.
- **Checked** (Linux, debug). `test/widget/code_restore_test.dart` (13: the restore with `--resume`, the token file in
  the environment and no token anywhere; the update line once, never into a dialog or a running turn, continued by the
  Stop hook; nothing restored while locked, without `status.updated`, after a normal quit, for an agent started after
  the update, twice, or without what it needs, one case each; the record from start to Stop, the quit question and a
  window killed by the installer; the switch in the tab's menu and in Agents; `agent_watch` until sign-in and never
  with a session; a daemon without it; Codex with `codex resume` and its notify program; the version sanitized),
  `update_auto_test.dart` (9), `file_rename_test.dart` (4), `test/protocol/client_v7_test.dart` (3: the wire format,
  `agent_watch` as a subscription, a v6 daemon), `test/host/code_hooks_test.dart` (+3: the real scripts keep only a
  UUID, compact or spaced, from Claude Code's input and Codex's argument), `agent_launch_test.dart` (+3),
  `appearance_test.dart` (+1). Frames `60_update_ready` (`_ru`, `_dark`), `61_update_auto` (`_ru`),
  `62_file_rename` (`_ru`); `01_unlock(_ru)`, `02_init` and `20_login` show `x-control/7`, and `32_update` the new
  setting behind its dialog. The non-live suite: 605 passed, 1 skipped (was 557 + 1). The maintainer's finding was
  reproduced first: the regression test failed on the old flow (it sent the refused name again and the dialog stack
  broke). Negative controls, each seen failing: the restore without the `status.updated` check, without the unlocked
  check, without the "started before the update" check, twice for one update, with `--continue`, with a token instead
  of the token file; the watch opened with a session; the update line not cleared once typed; a line typed into a
  dialog; the version unsanitized; the hook script without its character check; the window trusting the session file;
  the rename dialog's Accept enabled for a taken name; a refused name sent again; the banner without the running
  version check; the banner for a manifest without this computer's file. Live (`--tags live`), against the daemon of
  D-103: `live_update_auto_test.dart` (2: the status, the password both ways, nothing staged; the same file accepted
  without a copy, another one refused with `report (2).txt`) and `live_code_restore_test.dart` (1: real daemons, a
  real pseudo-terminal, the window's real hook scripts and a stand-in that runs the hooks and the real `antenna mcp`:
  the session ID recorded, the window torn down as by SIGTERM, a new window without a session restores the agent with
  `--resume` and the token file, types the update line once, `agent_watch` wakes it for bob's message 35 s after
  sending (the 30 s rate limit after the update line), a process that is not an ancestor gets `forbidden`, the watch
  closes at sign-in); every live window test, one file at a time: 19 files, 31 tests passed, 1 skipped (the real
  Claude Code canary). Against a preview.7 (`x-control/6`) daemon the new live tests skip with the reason, and the
  existing ones that do not expect the newest version (13 files) pass, so an older daemon keeps working.
- **Limits.** Codex is checked only with a stand-in (it is not installed on the build server), gets no automatic lines
  (its idle prompt is not verified) and no watch; its `notify` override replaces a user's own `notify` program for
  that session. A live test cannot get `status.updated` from a daemon without a real automatic install (the
  installer's part of D-103): the live restore test gives the new window that one fact itself. With "Restore after an
  update" turned off the next start keeps the token in memory, but a token file the daemon wrote once is rewritten by
  every new token (D-86). The restore needs the window settings file. What only a Mac can confirm: the installer
  closing and reopening the window, the real Claude Code resumed with `--resume`, the line typed into it.

### D-UI-30 · Trust level 5 shown as the symbol ∞ "My computer" (maintainer decision 2026-10-05, built 2026-10-06)
- **Question.** D-99 renamed what level 5 *does* (the owner's own computer, no prompts); the window still showed it
  everywhere as a digit among digits, "5 · Self", the same family as a stranger's trust level. D-99 left a "Next": a
  "My devices" group for level-5 contacts, so many of the owner's own machines read as one list rather than one more
  number in the 1–5 run.
- **Decision.** A display change only: the protocol, the CLI and the daemon keep the number 5 (SPEC §9, D-99, D-100
  unchanged; `trustGlyph(level)` in `lib/state/trust.dart` is the one place that turns 5 into the glyph, everywhere
  else still reads and sends the number).
  1. **The glyph.** Every trust badge (the conversation header, the chat list, the contact card, Agents, approval
     cards, invite/join summaries) prints `∞` instead of `5`; its name is "My computer" (`trust5Name`, `trustSelfName`)
     instead of "Self". The resting badge keeps its existing level-5 colour (a deep filled blue in light, a pale glow
     in dark, D-UI-24) — quiet, the same family as 1–4, not a warning.
  2. **The picker.** `TrustPicker` splits into two groups, "People" (1–4, as before) and "My devices" (∞ alone, full
     width): a different kind of choice, not a sixth rung on the same ladder. The ∞ cell and the level-5 warning
     dialog (`confirmSelfLevel`) use `XColors.danger` — the moment of picking it is marked, not merely labelled;
     `Icons.all_inclusive_rounded` replaces the computer icon wherever level 5 is a glyph rather than a digit
     (the warning dialog, `OwnComputerToggle`, `SelfMark`). Once chosen and applied, the picker is gone and only the
     quiet resting badge remains: the red lives only in the act of choosing, per the maintainer's word.
  3. **Wording.** Every window string that named "Trust level 5" or "'Self'" now says "∞" and "'My computer'"
     (`selfWarnTitle`, `selfWarnBody`, `selfOwnComputerToggle` "This is my own computer (∞)", the one-time level-5
     notice). A CLI-echo note (`antenna trust →`) keeps the real number, since it quotes the command the daemon ran.
  4. **Russian.** Translated the same way (`app_ru.arb`: `trustSelfName`, `trustGroupPeople`, `trustGroupDevices`);
     the glossary (`lib/l10n/GLOSSARY-ru.md`) now notes the window and the site read level 5 differently (the site
     still says "Self" in Russian; not in scope here).
- **Why.** The maintainer's own measure (25.08.2026, "rise above the problem first" — engineering principle 7): level
  5 is not a trust rung, it is the owner's own hardware, and the display should say that outright rather than make the
  owner read "5" and recall what it means. Red at the moment of choice repeats the warning dialog's own colour
  language instead of adding a new one; a quiet badge afterward keeps the header from reading as a standing alarm.
- **Checked.** `test/widget/self_level_test.dart`: the picker's two groups (position, not just existence), the ∞
  cell's and the warning's colour matching `XColors.danger` while a 1–4 cell does not, the resting header badge
  matching `XColors.trustColor(5)` and not danger once the level is actually applied, the exact wording of
  `selfWarnBody`/`selfNoticeTitle`/`trustSelfName`. `test/widget/self_notice_test.dart`, `test/widget/ai_apps_test.dart`,
  `test/widget/flows_test.dart` updated for the new wording and the `trustChangeAction` glyph placeholders.
  `l10n_guard_test.dart`, `design_tokens_test.dart` and `contrast_test.dart` unchanged and green (no new spacing, no
  new colour pair: `danger` on every surface was already checked). Frames: every regression and showcase frame with a
  level-5 contact in it (the chat list carries one in the demo data) was redrawn; see the commit for the list.
## Local models: the first slice of phase 2 (2026-10-06)

### D-104 · Local models as ordinary agents: a pinned runtime in its own sandbox, a verified catalog, a pool, and a loop of ours (2026-10-06, experimental)
- **Question.** D-96 phase 2 (`docs/LOCAL-ASSISTANT.md` §11) for preview.8, under a maintainer direction of the same
  day: the target is local multi-agent work (a lead agent creates workers on this computer, several models placed in
  the memory at once, the product plan §3), so the foundation must make a local model an ordinary
  Antenna agent, addressable by name, each in its own sandbox, able to get tools later without a redesign, and the
  window must not assume "one model, one chat".
- **Decision.**
  1. **Runtime:** llama.cpp `llama-server` **v0.6.0** (commit `d81235049384534c167caea52b85a694f6103d14`, MIT; the first
     versioned release, the same code as build b11429), built by `packaging/llama/build.sh` from the source archive
     pinned by SHA-256, with `LLAMA_OPENSSL=OFF` (no HTTPS client), `LLAMA_SUBPROCESS=OFF` (no built-in tools, MCP
     servers or router), no web UI (not even fetched), no tests or examples; Linux x86_64 with the run-time CPU
     variants, macOS arm64 with Metal and its shaders built in. It ships next to the daemon as `llama/` (the Linux
     archive's `bin/llama/`, the desktop archive, `Antenna.app/Contents/Helpers/llama/`, the macOS CLI archive). It is
     started with `--offline --no-slots --no-webui`, `--host <run folder>/llm.sock`, the catalog's official chat
     template (`--chat-template-file`, its SHA-256 checked before every start), `--reasoning off`, and a random API key
     per start in its environment only.
  2. **Its sandbox:** the agent sandbox of D-71/D-P-13 in a new **listen-only** mode (`SandboxSpec::listen`): no
     proxy, no daemon socket; Linux: seccomp refuses `connect` and every socket but a unix stream socket, and stage 2
     proves both from the inside (a TCP socket and a unix `connect` must fail with `EPERM`) before the `exec`, or the
     runtime does not start; Landlock and bwrap as for agents; the runtime's folder and the one model file read-only,
     the run folder writable; `RLIMIT_DATA` = the model's memory + 2 GB; no `RLIMIT_CPU` (it counts every thread and
     would stop a runtime at full power within minutes; the runtime is unloaded when idle instead). macOS: the profile
     binds the one socket path and nothing else on the network, plus the narrow Metal rules (`AGXDeviceUserClient`,
     `com.apple.MTLCompilerService`, `iokit-get-properties`), **unverified until the first run on a Mac**.
  3. **A local agent is an agent:** an `agents` row with no links, created by `local_agent_add` (owner password),
     listed by `agent_list` (`local_model`), removed by `agent_remove`. Its program is **our loop**, `antenna
     local-agent`, in the agent sandbox with no network at all and only the runtime's run folder read-only; it is bound
     to the agent like any agent's tree (D-28) with a fresh token per start that nobody is shown (`agent_token`
     refuses it), so a process of its tree that reached the daemon socket would be this agent, never the owner. The
     loop speaks the stream-json subset the resident parser reads (D-93): turns on stdin, text deltas and a `result`
     out. **Tools are not in this slice**; they come through `antenna mcp` in the same loop, without a new boundary.
  4. **Models and agents are separate.** A model is a file on this computer; several agents may run on one model (the
     runtime serves them as parallel slots, one per agent, up to four) and each agent has its own conversation, keyed
     by (agent, counterpart), with the owner the only counterpart now. Removing a model keeps its agents (`no_model`);
     the design's "removal deletes the file and the agent" assumed one agent per model.
  5. **The pool:** one runtime per model in use; a model loads only if it fits the smaller of half the memory minus the
     loaded models and the available memory minus 1 GB; otherwise idle models are unloaded, least recently used
     first; otherwise the turn waits (`activity: waiting`); with nothing loaded and still no room, `no_memory` with the
     numbers. Idle models unload after 30 minutes (`--local-idle-secs`); a runtime that exited is started again on the
     next turn. Threads: the physical (performance) cores; half of them on a machine that reports no SMT, which is
     most often a shared VM (measured: 16 threads at load 11 ran about seven times slower than 8).
  6. **The catalog** (`packaging/models.json`, strict, compiled in through `antenna_proto::models`): Qwen3.5 2B, 4B and
     9B Q4_K_M from `unsloth/Qwen3.5-*-GGUF` at their commits, each with its exact size and SHA-256 (checked against the
     hub's `lfs.oid` and by downloading all three files here), the memory measured here on the CPU build and estimated
     for Metal, and the official chat templates of `Qwen/Qwen3.5-*` (two files: the 2B's thinks only when asked).
     Debug-only flags replace the catalog and the hub for tests (`--local-catalog`, `--local-hub`,
     `--local-hub-cacert`); release builds refuse them.
  7. **Download and check:** `curl` in the agent sandbox through the daemon's proxy, whose only destinations are
     `huggingface.co` and `*.hf.co`, HTTPS only also for redirects, writing only into the model's own download folder
     (so a compromised `curl` cannot touch checked models), resuming with `Range` (five tries; a proxy refusal or a 4xx
     is final), after a disk space check (the rest of the file + 10 % + 1 GB). The daemon hashes the file, compares
     size and SHA-256 with the release, and only then makes it read-only and moves it into `models/`; a mismatch
     deletes it (`hash_mismatch`). The file's device, inode, size and mtime are kept; a change means a new check
     before the next load. `from_file` copies and checks a file the owner has. `model_install` needs an owner session,
     not the password: a model file gives nobody authority; creating the agent does.
  8. **The conversation** lives only in the encrypted database (`local_turns`, schema 7) and is replayed into a new
     loop as its context; nothing is written in plain text (the loop's folder holds scratch only), which closes for
     local agents the plain-text transcript limit of D-93.
  9. **Hardware assessment** (`local/hardware.rs`, pure and unit-tested on made-up machines): the table of
     LOCAL-ASSISTANT §2.2 picks the class (M2 or newer with 16 GB → 9B; M1 with 16 GB, x86-64 with AVX2 and 16 GB →
     4B; 8 GB and Intel Macs → 2B; below 8 GB or no AVX2 → none), the memory free now can only lower it, and a model
     above the class is `slow` only when the bandwidth estimate says under 10 tokens/s (an M1 Pro reads memory three
     times as fast as an M1). macOS reads `sysctl` through two new safe wrappers in `antenna-sys` (the same
     `sysctlbyname` FFI as `boot_session_uuid`).
  10. **Protocol:** `x-control/7` (CONTROL §24): `local_models`, `model_install`, `model_remove`, `local_agent_add`,
      `local_say` (a dialog like `wake_say`), `local_history`, `local_session`; the events `local_model` and
      `local_agent` for v7 subscriptions; `agents[].local_model`; the codes `no_space`, `hash_mismatch`,
      `fetch_failed`, `runtime_unavailable`, `no_memory`. Owner commands only: the agent CLI, the protocol and MCP have
      none of them (tested).
- **Not in this slice.** Tools and the doctor for local agents (phase 3); local models as workers and same-computer
  delegation (phase 4, the teams of the preview.8 plan); the Power setting; Pause and Resume of a download (Cancel is
  `model_remove`; an interrupted download resumes by itself); GPU builds on Linux.
- **Updates.** The runtime is part of every signed archive, so it changes only with a release: `install.sh` and
  `antenna update` (the `install.sh` layout and the macOS CLI archive, with the automatic installs of D-103) swap the
  `llama/` folder next to the binaries and keep the old one as `llama.previous`, which a rollback brings back; the
  macOS app carries it inside `Antenna.app`. An update onto an installation without `llama/` moves it into place, and
  an undo leaves it (an older daemon does not look for it). Tested in
  `antenna-update` `flow_tests::bindir_carries_the_local_model_runtime`, with a negative control.
- **What is new and why nothing existing fits** (D-94). Reused: llama.cpp, the published weights, the sandboxes, the
  supervisor and the proxy, agent rows and their binding, the stream-json parser, `curl`, SQLCipher. New and
  experimental: the listen-only sandbox mode, the loop, the pool and its placement, the catalog and its checks, the
  hardware assessment, local conversations. Agent CLIs that can drive local models bring tens of thousands of tokens
  of fixed prompt and their own tools (design §3.3); Ollama brings a service, a registry and cloud features (§2.1).
- **Checked.** `crates/antenna-cli/tests/local.rs` (real daemons, a stand-in runtime `tools/fake-llama-server.py`, the
  real `curl` against a loopback HTTPS hub): a chat streamed, kept across a restart and replayed as context; a file of
  another size or hash refused and deleted; a model changed after its check refused and deleted; the runtime's view of
  its sandbox in bwrap and Landlock modes (writing the model, TCP, a secret file, the daemon socket: all denied; the
  same program unsandboxed: all allowed, the negative control); interrupt; a crash; two models that do not fit
  together (the second waits, the first is unloaded) and idle unload; a download cut short and resumed with `Range`, a
  hash mismatch, a redirect to a host the proxy does not allow (refused, no second try). Negative controls seen
  failing: without the `connect` rule (stage 2 refuses the runtime), without the hash comparison (two tests fail).
  Unit tests: catalog validation, the recommendation table, placement, the runtime's flags, disk space, the hash
  check, the threads, the Seatbelt rules. The real runtime with the real 2B: `real_llama_server_answers_in_its_sandbox`
  (`#[ignore]`), numbers in LOCAL-ASSISTANT §14.

### D-UI-31 · Local models in the window: models and agents apart, a conversation per agent, the Local badge (2026-10-06, experimental)
- **Decision.** Agents → **Local models** (Experimental): this computer in one line; the recommended model (maker,
  size, memory, estimated speed, license) with Download after a confirmation that names the host; progress, speed and
  Cancel; "Checking the file…"; Create agent and Remove when ready; the reason by code when it failed; "Other models"
  with their fit in words; then the computer's local agents with their state, the Local badge and Chat; one "coming
  next" line. Local agents leave the general agent list (they hold no token or app). Create agent prefills a unique
  name from the model and asks for the password once. Chats get a section **On this computer** above the contacts,
  one conversation per local agent: history from `local_history`, the reply streaming into the live bubble ("Loading
  the model…", "Waiting for memory…"), Stop, New conversation (with a confirmation), and the standing line "Runs on
  this computer without internet access. It can be wrong." Model text is plain: control characters and direction
  overrides removed, no links fetched, no images. The badge reads "Local · runs on this Mac" or "… on this computer"
  by the daemon's `hardware.os` and shows only for `runtime: "local"`. With a v6 daemon there is no card and no
  section. Frames `65_local_models` and `66_local_chat` (light, dark, Russian).
- **Why.** The maintainer's direction: several local agents at once, each its own agent; a model is a resource, not a
  conversation.

## Decisions for the first complete version (2026-10-06)

The maintainer accepted the recommendations of the product plan §7 on 2026-10-06.

### D-105 · The first complete version is 0.2.0, a public beta; signed with a Developer ID of the company (maintainer decision, 2026-10-06)
- **Question.** The version number of the publishable release; whose name is on the Apple certificate.
- **Decision.** The version the plan calls "the next preview" ships as **0.2.0**, a public beta. Its macOS build is
  signed with an Apple **Developer ID registered to the company**, not to a person, and notarized; the company's
  D-U-N-S registration is in progress, the Apple developer account follows it. Until then builds stay ad-hoc signed.
- **Why.** 0.2.0 marks the first version complete for the twenty scenarios; a Developer ID removes the first-launch
  warning and the folder prompts after each update (each ad-hoc build is a new app to macOS) and is required for the
  key store options of D-103 item 4.

### D-106 · Approvals from another own device (maintainer decision, 2026-10-06)
- **Question.** PG-44: answer an owner approval from another of the owner's own devices.
- **Decision.** Yes: the owner proof of D-102 is made on the device where the owner is (its Secure Enclave key, or the
  password there) and travels over the level-5 link; the computer that asked verifies it against the owner keys it
  knows for that device, bound to its own one-time challenge and the exact request, exactly as a local proof. Only
  approvals and denials travel this way; no other owner command becomes remote.
- **Why.** The owner manages many own machines and should not have to sit at the one that asks.

### D-107 · Disappearing messages: content removed, signed headers kept (maintainer decision, 2026-10-06)
- **Question.** PG-27: disappearing messages without breaking history verification.
- **Decision.** A per-conversation timer agreed by both sides; when it runs out, both sides delete the message body and
  attachments (and their keys) and keep the signed header, so the history check still matches; the window shows
  "Message expired". Design first (PROTOCOL addition with a feature flag), then build.
- **Why.** Sensitive conversations (journalists, lawyers, doctors) without giving up integrity.

### D-108 · Agent sessions on servers are woken through tmux (maintainer decision, 2026-10-06)
- **Question.** PG-22: wake sessions that run outside the window (a Claude Code session on a server).
- **Decision.** `antenna session` runs such a session inside tmux (a proven terminal host; installed on the server
  by its owner) and applies the window's wake: Claude Code's hooks for the state, built-in lines only, the same rules
  as D-UI-23/D-UI-25.
- **Why.** The same verified mechanism as in the window, without a GUI; `--resume` in a second process would write
  into one session twice; Claude Code's channels are not open to third parties yet (WATCHLIST W-24).

### D-109 · Linux packages: .deb and .rpm plus the archive (maintainer decision, 2026-10-06)
- **Decision.** Releases add `.deb` and `.rpm` packages (desktop entry, `antenna://` handler, the user service)
  next to the archives; Flatpak later.

### D-110 · The vendors' installers run in a visible terminal tab (maintainer decision, 2026-10-06)
- **Question.** Q-LM2 of D-96: how the Check panel's "install the CLI" fix works.
- **Decision.** The fix opens a terminal tab in the window and runs the vendor's official install command there, shown
  before it runs and after the owner's consent; the owner sees everything it prints. The window never runs an
  installer hidden.
- **Why.** The owner keeps control and sees what happens; no installer runs out of sight.

The ninth question, the maintained `xterm` fork for the Code mode terminal, is left to the developers (decided with
a comparison when the terminal work comes up).

## Teams of agents (2026-10-06)

### D-111 · Teams in the daemon: a lead, workers within the owner's budget, tasks that carry taint, daemon-made checkouts and commits, a check sandbox (2026-10-06, experimental)
- **Question.** The maintainer decision of 2026-10-06 (the product plan, §3 and WP7): agents of
  one owner work as a team on one project: a lead agent creates workers, gives them tasks, checks the results and
  returns or accepts them, with the daemon enforcing every permission (SPEC §9). This is the daemon's part, starting
  with workers on this computer (cloud CLIs run by the daemon and the local models of D-104); other machines come
  with "My devices" (WP5), the window with WP8.
- **Decision.**
  1. **The model.** A team (`teams`, schema 8): a name, the project (a git repository of this computer: its top folder
     and git directory), the lead (an agent of this node, or the owner in person), the **target** branch, the
     **integration branch** `antenna/<team>` the daemon creates at the target's tip, a **budget** of slots ("up to N
     workers of kind K with role R"; kinds `claude`, `program`, `codex`, `local`) with a limit of workers at once,
     and a **template**: whether workers run commands, the check commands tasks may name (exact argument lists), the
     registries checks may reach, read-only toolchain folders and plain variables for checks, time limits of a turn
     and a check, a token limit per task, how often a failed check returns a result by itself, who applies to the
     target (`owner` by default, or `lead`), "local only". Workers are ordinary `agents` rows with no links
     (`<team>.<role>-<n>`) plus a member row (`team_members`); tasks are records (`team_tasks`) with the state machine
     `open → assigned → working → submitted → accepted → done`, `blocked` (a question), `returned` (changes asked or a
     failed check) and `cancelled` (`teams::rules::next_state`, every pair unit-tested); every step is an entry of the
     team's log (`team_log`). The tables are the record; the board a window shows is derived from them.
  2. **Who may do what.** The owner creates a team and changes its budget or template with the password (the budget
     lets the lead create agents, as `agent_add` does), and applies the integration branch to the target with the
     password (the approval the template keeps for the owner; `--commit` binds it to what the owner reviewed, a moved
     branch is `approval_mismatch`); everything else of the owner's needs a session, and stopping takes no password
     (it only takes work away, D-84). None of these exist for an agent (`unknown_command` in the CLI, the protocol and
     MCP). The agent commands (CONTROL §25) are decided per call from the caller's place: the team's lead, a worker of
     it (lead commands: `forbidden`), or neither (`not_found`); a worker reads and reports only its own task (another
     worker's is `not_found`).
  3. **Attenuation only.** A worker's grant is the template ∩ the lead's session ceiling when it spawned the worker ∩
     this machine's limits (`teams::rules::grant`; this computer: 8 workers at once, at most an hour per turn and per
     check); nothing a member does widens it, and a slot exists only because the owner put it in the budget
     (`choose_slot` refuses with the reason: `no_capacity`).
  4. **Taint travels with tasks.** A task records the taint of the session that wrote it: each link whose contact's
     data it had read, with the level then (`Carried`); its `ceiling` is the lowest with today's trust. Assigning it
     applies that taint to the worker (and reading it again does), a worker the lead spawns starts with the lead's
     taint, and a result records the worker's taint when it submitted, which reaches whoever reads it (the lead's
     `task_get`, `task_diff`, `run_check`, the notes; task lists carry no worker text and taint nothing). So a lead
     that read a level-2 contact writes tasks whose worker runs no command and no check, and an instruction injected
     through the lead never reaches level-5 rights. On one computer the daemon is the only writer of task records; a
     record that crosses machines (WP5) will carry its ceiling signed, and the receiving daemon will apply the lower
     of its own trust in the sender and the carried ceiling.
  5. **Workers run as resident sessions (D-93) keyed by the worker.** One actor per worker owns its process in the
     agent sandbox (D-71, D-P-13): the worker's checkout as its working folder, its own HOME and TMPDIR, the daemon
     socket for its own `antenna mcp`, network only to its provider through the daemon's proxy (a `program` worker
     without hosts has none). A token is made at every start and valid only once the sandbox root is bound to the
     worker (D-28); nobody else holds it (`agent_token` refuses it). A turn names the task ("read it with task_get"),
     never the brief, so the lead's text arrives as a tool result through the daemon. A Claude Code worker gets the
     daemon's PreToolUse hook in `--settings` (command-line settings outrank the project's `.claude/` and the user's
     HOME, both of which the worker can write) with `disableAllHooks: false`, and no `Bash` tool while the grant or
     its ceiling allows no commands (a lower ceiling restarts the process before the next turn, resuming the same
     session). Through the hook every command and write goes to `check`, where a worker's rules come first: the
     template's commands, writes only inside its own folder and never to agent settings, then the ceiling as for any
     agent (`teams::rules::worker_action`). A turn over its time limit is interrupted; a crash retries the task's turn
     in a new process, and three crashes in ten minutes, a task over its token limit, or two turns that end without a
     report (one reminder) hand the task to the lead as `blocked` with the daemon's reason. An idle worker stops after
     15 minutes; the next turn resumes its session; after a daemon restart a task in progress gets a turn to continue.
  6. **Local models as workers** go through the D-104 pool: the slot names an installed catalog model, the worker is a
     local agent in a conversation of its own (`team:<name>`) with a system prompt that names the lead as its
     counterpart. Local agents have no tools yet, so the turn carries the task's text (the lead's words, under the
     task's taint) and the reply is a text-only result. The model's class sets its roles (§3.3: S `triage`,
     `summaries`; M and L also `docs`, `drafts`, `translation`; no local class codes before local agents have tools
     and pass the measured check of §3.3 item 1). "Local only" refuses cloud slots and a lead that is not a local
     agent.
  7. **Isolation through daemon-made checkouts, not `git worktree`.** A git worktree shares the project's object store
     and refs with the worker: worker A could read worker B's submitted commits (and bypass the taint they carry)
     through `.git`, and could write any ref, the target branch included. Each worker instead gets a fresh checkout of
     the integration branch (`read-tree -u` with the daemon's own index, no `.git`, no history) as the only project
     folder its sandbox can write; it never sees the project folder or its git directory. On submit the daemon
     records the folder as a commit on `team/<task>` (`add -A` under the project's `.gitignore`); a nested repository
     or a submodule entry, more than 20,000 files or 256 MiB of new files are refused. Git runs only in the daemon,
     with `--git-dir` and a private index (a `.git` a worker plants is never a repository git discovers), hooks,
     fsmonitor and automatic gc off, no external diff or textconv driver, and an environment cleared but for `PATH`,
     `HOME` and the locale.
  8. **Apply.** `apply_result {id}` (the lead) and `task_apply` (the owner) merge an accepted result into the
     integration branch: a fast-forward when it did not move, otherwise a merge commit by `git merge-tree
     --write-tree` (git 2.38 or later), compare-and-swap on the ref; a conflict changes nothing (`merge_conflict` with
     the files). `apply_result {target: true}` needs the owner unless the template says `apply: lead`: the request is
     recorded (`team.apply_request`, the owner's `team` event) and the lead gets `approval_required`; the owner's
     `team_apply` merges the integration branch into the target, in the working folder where the target is checked
     out as `git merge --ff-only` would (the owner's uncommitted changes stay, or the apply refuses), and the lead
     learns it in `wait`.
  9. **Checks run in a second sandbox** (SPEC §11 "Two sandboxes"): the folder checked (a worker's own, or a fresh
     checkout of the submitted commit), an empty HOME and TMPDIR for every run, the program's folder and the
     template's toolchain folders read-only, its plain variables; no daemon socket, no token, no provider login;
     network only to the template's registries through the daemon's proxy (port 443), none at all without them. The
     run's sandbox root is registered as a **jail**: a process of it that reaches the control socket anyway (Landlock
     mode shares the file system) gets `forbidden` before any role. A check runs only a command of the template's list
     and only when the caller, the task and the result carry no ceiling below 4 (SPEC §9: level 4 runs allowlisted
     commands in a sandbox). On submit the daemon runs the task's check itself; a failure returns the task to its
     worker with the output, up to `check_retries` times, then the lead decides (§3.3 item 3).
  10. **The agents' interfaces.** MCP (`antenna mcp`) lists the team tools only for a member, as the daemon reports at
      the server's start: every member `team_info`, `task_list`, `task_get`, `task_diff`, `task_note`, `run_check`; a
      worker also `task_report`; the lead also `task_create`, `task_assign`, `task_status`, `task_review`,
      `apply_result`, `worker_spawn`, `worker_stop`, `capacity`; the `initialize` instructions gain the team's part
      from the daemon's state (slots, check commands, who applies), never a task's text. The plan's `task_update`
      and `task_submit` are one tool, `task_report` (working, blocked, submitted). The agent CLI has the same
      commands (`antenna team info|capacity`, `antenna task …`, `antenna worker spawn|stop`). `wait` reports task facts
      (`waited.tasks`: what changed, never a worker's text); the owner's subscription gets the `team` event.
- **What is new and why nothing existing fits** (D-94). Reused as they are: agents, tokens and their binding (D-27,
  D-28), the resident session protocol and its parser (D-93), the agent sandbox, the supervisor and the CONNECT proxy
  (D-71, D-P-13), taint and the ceiling rule (SPEC §9, D-29), the host hook (D-99), local agents and the pool (D-104),
  git's plumbing (`read-tree`, `write-tree`, `commit-tree`, `merge-tree`, `update-ref`). New and experimental: teams,
  budgets and templates, the task record and its state machine, taint carried by tasks and results, the daemon-made
  checkouts and commits, the check sandbox's profile and its jail, the worker actor, the team tools. Existing
  multi-agent frameworks run their agents in one process with one set of permissions; none enforces a per-agent
  ceiling derived from what each agent read, which is what Antenna exists for.
- **Threat analysis.** Assets: the owner's project and target branch, the owner's keys, tokens and other links' data,
  the computer itself. Adversaries: a contact whose message the lead reads (injection), a worker model that misbehaves
  or was injected, code in the project or in a result that a check runs, a lead that misbehaves.
  - *Injection through the lead* (a level-2 contact's message asks for commands): the task carries ceiling 2; its
    worker gets no `Bash` and every `check exec` is denied; no check runs on its result (test 3).
  - *A worker escalating*: owner commands do not exist for it; lead tools are `forbidden`; it cannot change the budget
    or the template, see a token, or apply; writes outside its folder and to agent settings are denied by `check`,
    and its sandbox has no other project folder (tests 2, 5).
  - *A worker reaching another worker or the project*: no shared folder, no object store, no `.git`; another worker's
    task is `not_found`; facts carry no text (tests 2, 8 in Landlock mode).
  - *A crafted result attacking the daemon's git*: explicit git directory, private index, hooks and drivers off,
    nested repositories refused, size limits. Residual: a filter driver the owner configured (for example git-lfs)
    runs on the worker's files when the daemon adds them, as when the owner commits them.
  - *Check code exfiltrating*: no secrets in its environment, no daemon (jail), network only to the registries the
    owner named (test 2: a non-registry host refused by the proxy, direct connections refused). Residual: a registry
    the owner allowed is still reachable, by a request whose path carries data.
  - *Settings that switch the hook off*: the daemon's settings come on the command line, which outranks the files a
    worker can write, with `disableAllHooks: false`; without commands there is no `Bash` tool at all. Residual: this
    rests on Claude Code's documented precedence of settings; the sandbox stays the hard boundary either way.
  - *Exhaustion*: caps on workers (slot, team, machine), unfinished tasks (200), text sizes (title, brief 16 KiB,
    notes 8 KiB, report 16 KiB), turn and check time, CPU time, file size, tokens per task. Residual: no memory limit
    on a check yet (`RLIMIT_DATA` of D-104 is not set for checks).
  - *Honest limits*: what a cloud worker reads (its checkout) goes to its provider (SPEC §11; "local only" avoids it);
    a Claude Code worker's transcript is plain text in its HOME under the data folder, as for resident agents (D-93
    limit 1); task records are not signed while teams stay on one computer.
- **Why.** The plan's scenarios (S1, S6, S7) need a lead that does the routine of directing workers while the owner
  keeps the decisions that matter; the daemon already decides every permission of a single agent, and teams are the
  same rules applied to agents an agent directs, with the one addition that what the lead read reaches the workers.
- **Checked.** `crates/antenna-cli/tests/teams.rs` (real daemons, sandboxes, git and the Python test runner; the lead
  is the test driving `antenna mcp`; workers a fake stream-json program that acts through the agent CLI):
  `a_lead_runs_two_workers_and_a_reviewed_result_reaches_the_project` (spawns within the budget, a third refused;
  two tasks; a result whose check fails twice in the check sandbox, once returned by the daemon, then by the lead's
  review; round 3 passes; a fast-forward and a real merge into the integration branch; the lead's apply to `main`
  refused with `approval_required` and `main` unchanged; the owner's `team apply` with the password moves `main` and
  the project's working folder; the facts in `wait_for_message`; the log of every step; `team remove`);
  `workers_stay_in_their_folders_and_have_no_owner_or_lead_api` (another worker's folder, the project's `.git`, the
  project folder, the keystore, a loopback TCP port: all refused in the sandbox and allowed to the test process, the
  control; owner commands `unknown_command`, lead tools `forbidden`, another worker's task `not_found`; a check that
  tries `example.com` through the proxy and `203.0.113.7` directly: both refused, `blocked_hosts` lists the host);
  `a_lead_that_read_a_level_2_contact_writes_tasks_that_run_no_commands` (two daemons and a local relay: the injected
  message, ceiling 2 in the task and the spawned worker, no command and no check; a reset lead tainted again by
  reading the result, not by listing tasks); `the_lowest_level_the_lead_read_travels_with_each_task` (three daemons:
  a task between a level-5 and a level-3 read carries 5 and its worker runs commands, the next carries 3 and its
  worker runs none); `team_owner_commands_do_not_exist_for_agents` (CLI, protocol, MCP; the worker's token is
  refused to the owner too); `a_local_model_works_as_a_worker_through_the_pool` (the stand-in runtime: a text
  result, a second round with the comment, a coder slot refused for a class S model, a cloud lead refused for a local
  only team); `a_task_in_progress_continues_after_a_daemon_restart`; `limits_hand_the_task_back_to_the_lead` (the
  token limit, three crashes, a worker that does not report); `landlock_mode_keeps_workers_apart_and_checks_away_from_the_daemon`
  (Landlock refuses the same reads with the files present; a check that reaches the control socket gets
  `forbidden`); `a_real_cargo_test_runs_in_the_check_sandbox` (the owner's rustup toolchain read-only through
  `--check-path` and `--check-env`, `cargo test --offline` passing in 0.95 s in bwrap, then failing in a later round). The real Claude Code (2.1.291, `--model haiku`, the owner's login read-only in the sandbox) as a worker:
  `real_claude_code_works_as_a_worker` (`#[ignore]`): it read its task through MCP, fixed the bug, ran `run_check`,
  submitted, and the daemon's check passed, 15 s from the assignment. The existing "no owner API for agents" checks
  (`agents.rs`, the protocol's `owner_commands_do_not_exist_for_agents`) list the team commands. Unit tests: the
  state machine (every state and operation), the grant, the commands and writes of a worker at each ceiling, checks
  (the allowlist and level 4), slot choice, local classes and roles, branch names, nested repositories, paths in a
  folder, check variables and folders, turn texts, the wire shapes. **Negative controls**, each seen failing with the
  protection off: the task's taint not applied to its worker (the level-2 test: the worker runs a command); the lead's ceiling not given to a worker it spawns (a clean worker after the lead read level 2); a worker routed to the lead's `worker_spawn` (it spawns); another worker's task readable (`not_found` gone); the team's data folder mounted in the worker's sandbox (worker 2's file read); applying to the target without the owner (`main` moves); `example.com` added to the check proxy (no longer in `blocked_hosts`); checks allowed below level 4 (the tainted task's check runs); the team's rules skipped in `check` (writes outside the folder and to `.claude/` allowed); the check's jail removed (Landlock mode: the check gets `hello_ok` from the daemon); a result's taint not applied to its reader (the reset lead stays clean); a slot one bigger (a third coder spawns); a worker's token given out (`agent token` succeeds); a class S model allowed to code; a cloud lead allowed in a local-only team; the token limit off (the task never blocks). Each was run by a script that patches one line, rebuilds, runs the guarding test and puts the line back: 16 of 16 failed.
- **Not in this slice.** The window (WP8: Teams, New team, the board, task cards, Changes and Apply, the capacity
  strip, dock tabs for cloud workers, the waker for task facts); other machines (WP5: capacity reports, remote spawn,
  lending, signed task records with their ceilings, the forged-ceiling test); Codex workers (the D-93 adapter); local
  workers with tools and the coder role after the measured check; the team room as a group conversation and
  "Escalate to" (PG-18); a memory limit and caches for checks; telling a running MCP server that its tools changed; a
  Seatbelt run of workers and checks on a Mac (the tests are Linux-only).

### D-112 · Linux packages install under `/opt/antenna`, split across the two packages by dependency, never by `antenna update` (2026-10-06)
- **Question.** D-109 leaves the file layout open: `/usr/lib/antenna/…` or `/opt/antenna/…`; whether `antenna-desktop`
  carries its own copy of `antennad`/`antenna`/the local-model runtime, as the self-contained archives do, or depends
  on the `antenna` package for them; and how `antenna update` tells a package install apart from the `install.sh`
  layout it already updates (both put `antennad` next to `antenna`).
- **Decision.**
  1. **`/opt/antenna/…`**, not `/usr/lib/antenna/…`: FHS §4 reserves `/opt` for self-contained, vendor-bundled
     software, which is exactly what this is (its own binaries and, when the release has one, the vendored
     llama.cpp runtime, D-104) — not shared libraries the dynamic linker or other packages consume, which is what
     `/usr/lib` is for. `/usr/bin/antenna`, `/usr/bin/antennad` and `/usr/bin/antenna-desktop` are symlinks into it,
     for PATH and for the path agent configs store.
  2. **Two packages, split by dependency, not by duplication.** `antenna` (the daemon, the CLI and, when present,
     `bin/llama/`) and `antenna-desktop` (the window) Depend/Require each other at an exact version instead of each
     carrying its own copy of the core binaries, unlike the tar.gz archives (which must each be self-contained, since
     nothing resolves a dependency for a plain download). `apps/antenna_desktop/lib/host/binaries.dart` already
     looks for `<exe dir>/bin/<name>` first before falling back to PATH, so placing `antenna-desktop` at
     `/opt/antenna/antenna-desktop` next to the `antenna` package's `/opt/antenna/bin/` finds the daemon the same
     way the self-contained archive's bundle does.
  3. **A marker, not a query, tells `antenna update` to stay out.** A package install is otherwise indistinguishable
     from the `install.sh` layout (`antennad` next to `antenna`): without a way to tell them apart, `antenna update`
     would try to replace files `dpkg`/`rpm` track. Both packages ship one extra file next to the binaries,
     `bin/.antenna-package` (`antenna_update::install::target::PACKAGE_MARKER`); `Target::detect` refuses with
     `unsupported_install` when it is there, naming the package manager. A build-time marker file beats asking
     `dpkg`/`rpm` at update time: no subprocess, no assumption that either tool is even installed, and it is `antenna
     update`'s own code that decides, not an external program's exit code.
  4. **Versions.** Debian compares with `~` sorting before everything (`0.1.0~preview.8` < `0.1.0`), so the SemVer
     `-` becomes `~`; rpm's `Version`/`Release` fields reject `-` outright, so the pre-release tag moves into
     `Release` as `0.<tag>` (sorting before a final release's plain `1`, the standard rpm convention for
     pre-releases).
  5. **Built from the already-built archives, not recompiled** (`packaging/linux/pkg-common.sh`, shared staging for
     both formats): `build-deb.sh` extracts `antenna-<v>-linux-<arch>.tar.gz` and `antenna-desktop-<v>-linux-<arch>
     .tar.gz`, stages the split layout, and calls `dpkg-deb --build --root-owner-group` (root ownership recorded in
     the archive without needing root or fakeroot to build it). `build-rpm.sh` shares the same staging and writes a
     `.spec` plus a payload tarball; with `rpmbuild` present it builds the `.rpm` the same way, otherwise it writes
     the `.spec` and payload to `OUT/rpm-sources/` and says so — a documented fallback, not a fake `.rpm` (`rpmbuild`
     is not installed on the build server, and this is not a reason to install it without the maintainer's word, CLAUDE.md). The
     two `.deb`/`.rpm` files per package are signed into the release manifest like the archives, under their own
     asset kinds (`deb_app`/`deb_cli`, `rpm_app`/`rpm_cli`, `docs/UPDATES.md` §2): never a kind `antenna update`'s own
     platform matching asks for, so they can never be picked as "the asset for this installation".
- **Why.** `/opt` matches what this actually is; the dependency split is less to duplicate and more honest about
  what each package needs; the marker file is the cheapest reliable way to keep `antenna update` off files it does
  not own; signing the packages into the manifest reuses D-82's verification instead of a separate trust path for
  them.
- **Checked** (Linux, the build server, 2026-10-06): `build-deb.sh`/`check-deb.sh` against the preview.7 archives in
  `/root/.cache/antenna-release/v0.1.0-preview.7/` (copied first, not touched there) — contents, `root:root`
  ownership and permissions recorded in the `.deb` (`dpkg-deb -c`, not what unprivileged extraction gives on disk),
  the systemd unit's content, the desktop entry (`Exec`, `MimeType`, `StartupWMClass`; `desktop-file-validate` is not
  installed here, skipped and said so), and, under `xvfb-run`, the window starting the daemon from the package's
  split `/opt/antenna/bin` layout. The `antenna update` refusal was checked against a throwaway archive built from
  `target/debug/{antenna,antennad}` of this change (the cached preview.7 binaries predate the marker file and would
  only show the fix had never been reached, not that it works): `"kind":"unsupported"`, reason naming the package
  manager. Negative control, seen failing: the same layout without `bin/.antenna-package` reports `bin_dir` (the
  ordinary, self-updating layout) instead — `antenna-update`'s
  `install::target::tests::a_package_install_cannot_update_itself`. `build-rpm.sh`/`check-rpm.sh`'s fallback path
  (spec fields, `%files` against the payload tarball's actual contents) checked the same way; the `rpmbuild`/
  `rpm2cpio` paths are written but not run anywhere (neither tool is installed on the build server,
  `docs/TROUBLESHOOTING.md` 2026-10-06).

## Chats per agent (2026-10-06)

### D-113 · Each agent of a contact is its own chat; a message for an agent nobody has is answered; `antenna connect` (maintainer decision, 2026-10-06)
- **Question.** PG-6 (the product plan §3.8). The maintainer: talking to one agent session must be
  separate from talking to another, and neither session sees the other's conversation; "a chat with you that I can
  rename, e.g. 'Antenna development', another one 'Volna development', and later another app, another chat". Threads
  (D-UI-18) split one conversation inside the window only; nothing kept two sessions of one computer apart unless the
  owner made two agents by hand. The same day a real failure: a message addressed to an agent "chatgpt" showed
  "delivered", but the other computer had no agent by that name (the ChatGPT app's agent there had another name), so
  nobody read it and nobody was told.
- **Decision.**
  1. **The daemon sorts a link's messages into chats** by the counterpart on the contact's side, with the rule the
     window used for threads: an incoming message by its author (the contact's agent it came through, the person
     otherwise), an outgoing one by its addressee (the contact's agent for `to: agent`, the person otherwise, messages
     to everyone and unaddressed ones included); receipts belong to the person chat. `chats`, `history.chat` and
     `mark_read.chat` (CONTROL §26) make the list, a chat's pages and its unread count the daemon's facts. No protocol
     or history change: the chats are derived from stored columns, and what an agent may read is still decided from
     the signed `core` (D-91). A history from 0.1.0-preview.7 falls into chats as it is (tested with the release
     binaries).
  2. **The owner's settings of a chat** stay on this computer (`chats` table, schema 9) and are never sent: a local
     name (1–64 characters), notifications (`all`, `asks` = only messages addressed to the owner in person and approval
     requests, `off`; the person chat defaults to `all`, a chat with an agent to `asks`), archive (until a newer
     message arrives; the person chat is the contact and is not archived). An owner session is enough, no password:
     these are display settings. A chat with a known agent (one that announced itself, wrote or was written to) can be
     created before its first message; an unknown name is `not_found`, so no chat exists for a name nobody uses.
  3. **Privacy between sessions is D-91 per session:** each session its own agent, its own token, "messages to
     everyone" off; then it reads only what is addressed to it, and its chat on the contact's side is its own. A lead
     that coordinates others is an addressed agent like any other. `antenna connect claude-code|codex --agent <name>`
     makes this the easy path on a server: it creates the agent with a token file (or reuses it), shows Claude Code's
     own command for this project folder (`claude mcp add --scope local`) and runs it after the owner's yes (Antenna
     writes nothing into another program's files, D-85), prints Codex's command line, and with `--hello <contact>`
     sends one fixed line as the agent so its chat appears on the contact's side at once. The owner's own view (the
     window, `antenna history`) shows every chat of the link: the owner reads everything, and the guide says so.
  4. **A message for an agent nobody has is answered, not silently "delivered"** (PROTOCOL §23, feature
     `no-agent/0`): the recipient's node writes a signed receipt `deliver` / `no_such_agent` (actor "owner", `refs` =
     the messages) when none of its agents with the link in scope answers to the addressed name; only to a node that
     announced the feature (an older node would refuse the unknown receipt action, so it keeps today's behaviour) and
     only to contacts of level 3+ (below that a contact could probe which names exist; level 3 is where reading
     starts). The sender marks the message (`no_agent`, the `message_status` value `no_agent`); `send` waits up to
     1.5 s for the answer when the name is not among the agents the contact announced, and its reply carries
     `no_agent` and `peer_agents`. The window and the CLI say "No agent named X at <contact>" and list their agents
     instead of "delivered"; the MCP tool's description tells an agent what `no_agent` means.
  5. **The name to write to is shown**: the AI apps rows on the Agents page say which name contacts address the app's
     agent by (D-UI-32), so the owner can tell others what to write to.
- **Not in this decision.** File offers addressed to one agent (PG-19): a file still goes to the link, so it shows in
  the person chat. Waking sessions that run outside the window (PG-22, D-108). Renaming a local agent's chat (its row
  is the local agent itself, D-UI-31).
- **What is new and why nothing existing fits** (D-94). The chat rule is the window's thread rule moved into the
  daemon. New: the `deliver` / `no_such_agent` receipt, a protocol extension behind a feature, experimental like the
  addressing it completes (D-94). What it tells a contact: whether a name answers on this link, only at level 3+ and
  only for agents scoped to that link. A contact that lies with such a receipt only misleads its own correspondent's
  display; the message itself is delivered either way.
- **Checked.** `crates/antenna-cli/tests/chats.rs` (real daemons): messages land in the chat of their counterpart on
  both sides, local settings never reach the contact, unread per chat, archive brought back by a new message; a new
  chat needs a known agent and its change reaches owner subscriptions only; two sessions of one node through MCP each
  read only their own chat, the MCP server has no chat tool, the agent role has no chat command; `antenna connect`
  with a stand-in `claude`; the no-agent receipt, its mark and the names; no receipt below level 3 (a local relay);
  `#[ignore]` with the 0.1.0-preview.7 release binaries: a preview.7 history maps into chats, and a preview.7 node
  neither gets nor triggers the receipt. Unit tests in `antenna-core` (`chats.rs`) and `antenna-proto`. Negative
  controls seen failing: incoming messages sorted into the person chat; every agent reading every message (the MCP
  test of two sessions); `chat` events reaching agents; the receipt for every name (an agent that exists was
  reported missing); the receipt below level 3; the receipt to a node without the feature (with the preview.7
  binaries); `antenna events` handing an unknown event back and forth until the stack overflows.

### D-UI-32 · Chats per agent in the window (2026-10-06)
- **Decision.** The chat list shows each agent of a contact as its own row under the contact's row, indented, with
  the agent's picture, the local name (and the agent's name beside it, small), the latest message, its unread count, a
  muted mark when notifications are off, and a **⋮** menu that is always visible (right-click works too). The contact's
  row is the person chat. The menu, also in the conversation header: **Rename…** (**Rename contact…** for the person
  chat), **Notifications** (**All messages**, **Only when it asks for me**, **Off**, each with a one-line hint), and
  **Archive** / **Unarchive** for a chat with an agent. Archived chats fold into **Archived (N)** at the end of the
  list; a new message brings a chat back. **New chat with an agent** (the button next to the list's title) lists the
  agents of the contacts that announced themselves or wrote, with **Start chat** or **Open**. In an agent's chat
  the owner's message goes to that agent (no To line); in the person chat the To line offers the person or
  "Everyone on <contact>'s computer" with the line "every agent there that reads messages to everyone gets it".
  Topics and the filters by the owner's agents stay inside a chat. Search ("Search chats") and the Unread and Queued
  filters work per chat and find a chat by its local or agent name. A system notification says only "New message in
  <chat name>", follows the chat's setting, comes at most once per chat in 10 seconds and only when the window is not
  in front. A message for an agent the contact does not have says so under the bubble with their agents' names. The
  AI apps rows say "Contacts write to it as <name>". Local agents keep their own section **On this computer**
  (D-UI-31). With an older daemon the rows come from the loaded history and the settings are disabled with "Needs a
  newer Antenna daemon on this computer". Frames `67_agent_chats` (light, dark, Russian) and `68_chat_menu` (light,
  Russian).
- **Why.** The maintainer's direction of D-113: a chat per agent that the owner can name and silence, and that a person
  can tell apart at a glance; the threads bar inside one conversation hid that there were separate counterparts.
- **Checked.** `test/widget/chats_test.dart` (rows and unread per chat, rename, notifications and archive from the
  menu, a new agent and New chat, notifications, the no-agent line, search and filters, counts read elsewhere, two
  older daemons), `threads_test.dart` (the person chat's To line, the filters inside a chat), `ai_apps_test.dart`
  (the name line), and live with two real daemons in `test/protocol/live_chats_test.dart`. Negative controls seen failing: a `chat` event for a chat the window had not
  listed yet ignored, `mark_read` without the chat, "Only when it asks for me" notifying every message, the no-agent
  line not shown.

## My devices (2026-10-06)

### D-114 · Own computers tell each other what they are; an approval is answered from another own device with an owner proof the asking computer verifies; a lost computer is revoked from another (2026-10-06, experimental)
- **Question.** PG-10, PG-25, PG-14 (the opt-in) and PG-44 of the plan (the product plan), with
  D-106 decided: one view of the owner's own computers (versions, updates, health, agents, the requests waiting), an
  approval request of one computer answered from another, "this computer is lost" from another own computer, and the
  switch a computer turns on to lend itself to the owner's teams.
- **Decision.**
  1. **A status between own computers** (`docs/PROTOCOL.md` §24): a `device` link request sealed with the link's
     session, outside the history, as `stream_open` is (§20); only between contacts at level 5 both ways (each side
     checks its own level, before decrypting and again before storing) and only to nodes that announced `device/0`.
     It carries facts: the host name, the OS and its release, the CPU architecture, the memory, the daemon's version,
     the D-103 state (on/off, a release staged, the last install), health codes of `antenna doctor` (D-101), the agents
     (name, the program they run as, connected or not), the pending approval requests (at most 32, the count of all;
     the quote cut to 1 KiB, and withheld when the secret scanner finds anything in it, so a secret never leaves the
     computer that asked), the lending switch, the keys it answers approvals with, which of the recipient's keys it
     accepts, and the computers it revoked as lost. Sent when it changed, on a new connection and every minute; an own
     device without a connection is dialled every 30 s at most. The receiver keeps the last status without its
     requests.
  2. **An approval from another own device is the D-102 owner proof over the asking computer's challenge.** The
     asking computer issues a 32-byte challenge for one decision on that link (60 s, used once, at most 16 per link);
     the signer signs `"antenna/owner-proof/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(text)` where the text is
     `{"cmd":"remote_approve","link":…,"id":…,"fingerprint":…}`: the link as the signer's node knows it (a proof cannot
     be relayed over another link), the request and the fingerprint the owner was shown. The asking computer verifies it
     with `aws-lc-rs` (ECDSA P-256 / SHA-256, `owner_keys::verify`, unchanged) against a key **its owner confirmed for
     that device with the password**, then approves exactly as a local approval does (the fingerprint compared, the
     request carried out by the daemon, D-100) and logs it as approved from that device with the key. A denial is the
     same text with `remote_deny` and no proof (a local `deny` needs no password, D-84). Only approve and deny travel;
     no other owner command is reachable this way. Three failed proofs in a row from one device pause its decisions for
     a minute, doubling up to eight.
  3. **Which keys.** A computer offers its owner keys (the window's Secure Enclave keys behind Touch ID) and its own
     **device key**: a P-256 key its daemon generated with `aws-lc-rs` and keeps in the encrypted database, used only
     after the owner typed the password on that computer, for one request (a Linux computer, or a Mac without Touch
     ID). Keys travel in the status; the other computer's owner confirms them once with the password there. A confirmed
     key the device stops announcing (Touch ID turned off) or announces with another point is dropped; a device lowered
     below level 5 loses all of its confirmed keys, and raising it back does not restore them.
  4. **A lost computer.** "Revoke this computer" (`device_revoke`, the password) revokes the link as `revoke` does and
     puts the computer's announced keys on a list the node tells its other own devices for 30 days. A device told so
     drops its confirmed keys of every own device that announced one of them (it only takes a way in away) and shows
     it as reported lost; its owner revokes it there too, or clears the mark. Contacts linked only to the lost computer
     cannot be told this way: they are told another way and paired again from a new computer (the guide says so).
  5. **Lending to teams** (PG-14, the opt-in only): "Lend this computer to my teams", per computer, off by default, on
     with the password, off without; kept in the database and announced in the status. `Session::lends` and
     `Session::lending_devices` are what the teams read (D-111): a team's `capacity` now lists the own devices that lend
     themselves, as facts, with every slot unavailable until remote workers exist.
  6. **The owner's interfaces.** CONTROL §27: `devices`, `device_challenge`, `device_approve` (a proof made in the
     window, passed on unchanged), `device_decide` (the password here, or a denial), `device_keys_confirm`,
     `device_keys_remove`, `device_lend_set`, `device_revoke`, `device_lost_dismiss`, the `device` event; CLI `antenna
     devices [confirm|forget|approve|deny|revoke|lend|dismiss]`. None of them exists for an agent (the CLI, protocol and
     MCP checks list them).
- **What is new and why nothing existing fits** (D-94). Reused as they are: the link's session for sealing (§20's
  ephemeral messages), the features exchange, the D-102 proof message and its verification, `aws-lc-rs` for the device
  key (D-102's P-256 implementation, a maintainer decision; until now the daemon only verified with it, now it also
  signs, with the same crate and the same message), the secret scanner, approvals and their completion (D-100),
  `revoke`. New and experimental: the status message, the per-link
  challenge pool, the confirmed keys per device, the device key, the lost list. Nothing cryptographic is built: one
  existing message, one existing verification, a key generated and used by the same audited crate.
- **Threats, and what answers them.** A contact that is not an own computer (announcing itself, asking for a challenge,
  reporting a computer lost): the level check on both layers (`devices.rs` step 9). A replayed decision: the challenge
  is taken by the first decision naming it. A proof for another request, fingerprint or link: the signature covers the
  text that names them. A key never confirmed, a device lowered below ∞: confirmed keys per device, dropped on the
  level change. A compromised own device: it can approve only with keys confirmed for it, one request per proof; with
  only its Touch ID keys confirmed, a finger on that device too (the device key stands for that computer's password,
  which the owner chooses to accept or not). A secret in a request: withheld from the status. Residual: an own device
  is trusted with level 5 anyway (D-99); a status is that computer's word about itself (shown as such, never used for a
  permission); hostnames and agent names reach the owner's other computers.
- **Why.** The owner manages several computers and should see them and answer their requests from where they are, with
  the asking computer, not the answering one, deciding (SPEC §9), and without making any other owner command remote
  (D-106).
- **Checked (Linux, debug).** `crates/antenna-cli/tests/devices.rs` with real daemons: the view's data both ways (version,
  OS, the agent, two requests with one quote withheld, the keys), keys offered after Touch ID is enrolled (a software
  key), nothing accepted before the owner confirms, an approval with the Touch ID key carried out and delivered to the
  contact, the audit entry; a replay (`challenge_invalid`), a proof for another request (`proof_invalid`), another
  fingerprint (`approval_mismatch`), a key never confirmed and the device key before it is confirmed
  (`owner_key_unknown`), then the device key's approval with the password and a denial with neither; a device lowered to
  4 (`forbidden`, its keys gone after the raise back); a contact at 3 that has the asker at ∞ and reports a computer lost
  (refused, nothing changed); a lost laptop revoked from the mini, the server told (its keys dropped, marked), dismissed,
  revoked there; lending on with the password and off without, seen by the other device, a team's capacity listing it.
  Unit tests: `antenna_proto::device` (shapes, strict parsing, limits), `control::devices` (owner commands, passwords,
  no proofs), `antenna_core::devices` (each refusal of a decision, the device key's proof, confirmed keys following
  announcements, lost reports, the pause), the no-owner-API checks (CLI, protocol, MCP). Negative controls, each seen
  failing: both level checks off (a forged lost report removed lap's keys; either check alone held), the challenge not
  taken (the replay passed the proof check), the signature not verified (another request approved), the trust hook off
  (old keys still confirmed), the lost report not applied, the link not compared, the key lookup ignoring the ID.
- **Not checked yet.** A Touch ID signature from a real Mac over a remote text (the Runner signs any text, as for local
  proofs; the window's part is a widget test with a fake Secure Enclave and a live test with the test key in software);
  two Macs on one owner; a computer revoked while its link is offline. Remote workers on a lending computer are the
  teams' "other machines" (D-111).

### D-UI-33 · My devices in the window (2026-10-06, experimental)
- **Decision.** A navigation item **My devices** (between **Agents** and **Files**; the compact rail of Code mode has its
  icon) with the count of requests waiting on own devices. The page (Experimental tag): **This computer** (its name,
  system and version, **Lend this computer to my teams** with the password to turn it on, the keys it answers with),
  then one card per own computer: its name with the quiet ∞ badge, online or when it was last heard, system and
  version; the card opens by itself when something waits (a request, a problem, a key to accept, a lost report). Inside:
  **Requests waiting for you** first (who asks what, for whom, the reasons, the quote or "The text is not shown here:
  it contains a secret…", the fingerprint, the time left; **Approve with Touch ID** with **Use password** beside it,
  **Approve with password** when only the password key is accepted there, **Deny**; when that computer accepts no key
  of this one, a line that says where to accept them, and Deny), then **About it** (name, system, memory, Antenna,
  updates, teams), **Health**, **Agents**, **Approvals** (which of its keys are accepted here, which of this computer's it
  accepts, **Accept approvals signed with …** with the password, **Stop accepting**), and **Revoke this computer**. A
  computer another own device reported lost shows a red banner with **Revoke this computer** and **It is not lost**. The
  revoke dialog says what happens and what does not (the link wiped here, the other computers told, the keys no longer
  approving, contacts linked only to it told another way), with the password and "Also delete the conversation
  history". With an older daemon the page says My devices needs a newer Antenna.
- **Why.** The owner's computers read as one list, and a request is answered where the owner is; the window only
  carries the proof: Touch ID signs the other computer's challenge and the exact text, built by the window and shown
  in the sheet's reason ("approve on Mac mini: send a message").
- **Checked.** `test/widget/devices_test.dart` (10: the view and the counter; one touch over the challenge and the
  exact text; the password; a deny; a computer that accepts no key of this one; a refusal shown; a cancelled sheet;
  keys accepted with the password; lending; a lost computer revoked; an older daemon), the live
  `test/protocol/live_devices_test.dart` against real daemons (one touch with the test key in software, the password
  refused until the device key is accepted, then approved, a denial, lending). Negative control seen failing: the
  request's ID signed as its fingerprint (the proof refused, nothing approved). Frames `69_my_devices` (light, dark,
  Russian), `70_device_revoke` (light, Russian); every frame with the navigation gained the item.
### D-UI-34 · Teams in the window: the board is a view of the daemon's records, the owner's password applies, a lead in Code mode is woken by task facts (2026-10-06, experimental)
- **Question.** Work package 8 of the plan (the product plan §3.5, §6): the window's side of
  teams of agents (D-111). The maintainer's direction: a complete product, the way a coding agent directs its own
  helpers (a lead creates agents, gives them tasks, they do them, it checks the result); obvious UX, every button with
  visible feedback, nothing hidden; exact labels in the guides.
- **Decision.**
  1. **A Teams section** in the navigation, shown only for a daemon that answers `team_list` (below v7, or a v7 daemon
     built before teams: no section, no command, "could not check" is not an error). Its badge counts what waits for
     the owner: a lead's request to apply, and in a team the owner leads, results to review and questions to answer.
     The list shows each team's project, lead, workers and task counts by column, and the lead's request.
  2. **The board is derived state** (principle 4): columns are a view of the task states (`open`; `assigned`,
     `working`, `returned`; `submitted`; `blocked`; `accepted`; `done`; `cancelled` only when there are some), read
     from `team_show` and again on every owner `team` event; a task's text (its brief, the worker's report, the
     reviews, the check's output, the diff) comes from `task_show`/`task_diff` and is shown as plain text (control
     characters and direction overrides removed, nothing a link). A card carries the last note, the check, the change,
     the tokens, the ceiling when it limits its worker, and the worker's current line while it writes.
  3. **The owner's actions are the daemon's owner commands**, each with its own feedback (a spinner on the button,
     the daemon's words on a refusal): New team (`team_create`, the password once, the form checks the name, the
     folder, the budget lines and local-only before the daemon does), New task, Add worker (no password: the budget
     is the permission), Accept / Request changes / Answer / Cancel (`task_review`), Assign (`task_assign`), "Apply to
     antenna/<team>" (`task_apply`), Stop all workers / Stop worker (no password), Make active again (`team_set`, the
     password), Remove team, Log.
  4. **Applying to the project's branch is the owner's approval**: the lead's `apply_result {target}` is refused by
     the daemon and shows as a banner; "Review and apply" lists what the team's branch holds and asks for the password
     in the dialog; `team_apply` is pinned to the integration commit the dialog showed (`approval_mismatch` when it
     moved). The window never sends `team_apply` by itself, whatever an event says.
  5. **Live output** from `team_watch` (the daemon's addition of this work, CONTROL §25): per worker, keyed by the
     worker's name, so a worker's view (its card line, its task's live box, its panel, its dock tab) never shows
     another worker's output or task; a v7 daemon without it gets each worker's last `detail`, and the view says so.
  6. **The capacity strip** from `team_capacity`: the machine, its sandbox and limit, each budget line used and free
     with the daemon's reason when one cannot start, the owner's other computers that lend themselves (My devices,
     D-114: listed, no worker there yet), the local models in memory (`local_models`), open tasks and
     queued turns; derived from the budget, and labelled so, for a daemon without the command.
  7. **Code mode.** The daemon's cloud workers are read-only tabs after the terminals (their output and task, Open
     board, Stop worker; nothing to type into). A team's lead running in a window terminal gets one built-in line,
     "Your Antenna team <team> has news: check task_list and continue.", when the owner's `team` event says somebody
     else changed a task it acts on (`by`, added to the event by this work): a worker submitted or asks something, the
     daemon blocked a task or recorded its check, the owner reviewed, assigned, applied or changed the team. Not for
     the lead's own changes, a worker's progress note, the daemon's return of a failed check (the worker continues by
     itself), or a daemon that does not say who acted. The D-UI-23/25 rules hold unchanged: an `AllowedLine` (the
     team's name sanitized like a contact's label), only at the empty prompt or for the running turn's Stop hook, one
     line per 30 s coalesced, the same switch "Wake on new messages"; a message's wake goes first, the team's line after
     the cooldown.
- **Daemon additions** (x-control/7, additive; CONTROL §25): `team.by` on every team event (`owner`, an agent's name,
  `daemon`), worker state changes as `team` events (`starting`, `busy`, `idle`, `sleeping`, `failed`; a local
  worker's `loading`, `waiting`), `team_worker.queued`, the owner's `team_capacity` and `task_assign`, and the
  `team_watch` dialog: `worker_output` events (`snapshot` of the turns in progress, then `start`, `text`,
  `activity`, `end`) of that team's workers only, from one bounded buffer per session (`lagged` past 1,024 pieces),
  never to an agent or the logs; local workers stream the pool's pieces and count their turns and tokens. `antenna team
  capacity|watch <team>` and `antenna task assign` for the owner; `antenna events` no longer overflows its stack on
  a v7 kind (every kind has a line, no wildcard). None of the new owner commands exists for an agent (the protocol, CLI
  and MCP "no owner API" checks list `team_capacity` and `team_watch`); an older v7 daemon refuses them with
  `bad_request` ("unknown variant"). Checked by `crates/antenna-cli/tests/teams.rs`
  `the_owner_watches_a_worker_live_and_reads_capacity` (the parts in order, a mid-turn snapshot that adds up to the
  whole text, `by` of the lead, the worker and the daemon, `busy` then `idle`, capacity, the owner's assign, a second
  team's output never in the first team's watch, a removed team ending its watch; negative control: the team filter
  off) and the local-worker test.
- **Why.** The owner directs the team the way the lead does, sees everything the daemon records, and approves only
  where the rules keep the decision; the window adds no state of its own that could disagree with the daemon's.
- **Checked.** `test/widget/teams_test.dart` (24), `teams_code_test.dart` (6), `test/protocol/client_teams_test.dart`
  (5: every reply and event parsed, the requests' exact fields, no password or worker text in `toString`), the live
  `test/protocol/live_teams_test.dart` (a real daemon, sandboxes and git: the window creates the team, a lead driven
  through the agent CLI spawns a worker and writes a task, a fake stream-json worker submits, the daemon's check
  passes, the board, the note, the diff and the live output; the lead's apply to `main` refused and shown; a wrong
  password applies nothing; the password moves `main`; the owner's own task, worker, Stop, Remove). Negative controls,
  each seen failing: the lead woken by its own change; a silent daemon waking the lead; workers' output kept per team;
  a worker's text not made plain; the window applying the lead's request by itself; the apply not pinned to the commit
  shown; a worker's tab showing another worker's task; a watch taking another team's pieces; a lagged watch not opened
  again; an action not waiting for a board read after it. Each was run by a script that patches one line, runs the
  guarding test and puts the line back: 10 of 10 failed on their assertions. Frames `71_teams`, `72_team_board`,
  `73_task_detail` (light, dark, Russian), `74_task_changes`, `75_new_team` (light, dark, Russian), `76_team_apply`
  (light, Russian), `77_code_team_worker`.
- **Not done here.** Touch ID for team commands (the password only); a team room as a group conversation and
  "Escalate to" (PG-18); workers on other machines (New team shows whether each own computer lends itself, as My
  devices reports it; the switch is that computer's own); the measured check of local
  coders; on a Mac: the folder picker's privacy question, the dock tabs with a real Claude Code worker.

### D-115 · Profile pictures: drawn sets travel as an id, own photos only as pixels rebuilt in the check sandbox, behind `picture/0` (maintainer decision on the drawings, 2026-10-06)
- **Question.** PG-29 (the product plan; scenarios S3, S4, S18): people and agents need pictures
  so a list of contacts and a group chat of agents can be told apart at a glance (D-UI-24 left `AgentPicture` as the
  hook). Decision 3 of the plan: the maintainer chooses the drawings. The maintainer drew three sets of animal
  pictures (1 "soft 3D", 2 "modern, for developers", 3 "for everyone", 18–19 each, one cover icon per set). A photo is
  personal data and an image file from a contact: it must not carry metadata out, and nobody's window may decode
  bytes a contact chose.
- **Decision.**
  1. **The sets ship in the window** (`apps/antenna_desktop/assets/avatars/`, 55 pictures in three sets, 512 and 128
     px WebP, at most 60 KB at 512 px, 2.7 MB in all, plus a 128 px cover per set). `tools/avatars.py` makes them from
     the originals, which stay outside the repository: square, metadata stripped, the manifest `sets.json`, the
     pubspec folders and the names in both ARB files (`pictureAnimal`, `pictureSet` select messages; Russian names
     only in `app_ru.arb`, a missing one stops the run). Adding a set is putting its folder next to the others and
     running the script. Set names: Soft, Modern, Playful.
  2. **On the wire** (PROTOCOL §25, feature `picture/0`): a `control` message `{"picture": {agent?, drawn? | photo?}}`
     from the side's link-root only. A drawn picture is its id (`set1/fox`); the receiver draws it from its own assets
     and an unknown id is initials, so a later set needs no protocol change. A photo is a JPEG of at most 64 KiB
     inside the signed message. Nothing goes to a node without the feature: its owner sees initials, the history
     stays the same on both sides.
  3. **A photo only ever as rebuilt pixels.** The owner's photo goes through the file check sandbox like a received
     file (`antenna_files::picture::rebuild`): only the rebuilt pixels, the EXIF orientation applied, the middle
     square, at most 512 px, flattened onto white, encoded as a JPEG with no metadata; a malformed image, a
     non-image, a type other than its name says or anything hidden after the image is refused. The receiver keeps a
     contact's photo as received but never hands it out: it checks it in its own sandbox first and the window gets
     only its own rebuild (`picture_photo`). A contact at level 1 takes no files, so its photo is withheld; a drawn
     id is shown at every level.
  4. **When a picture is sent.** The owner's picture, and an agent's picture only on links where the contact already
     knows the agent (it wrote there; a picture never reveals an agent), compared with the side's latest picture
     message in its own history: on a change, on each features exchange, after an agent's first message. A rollback
     that displaced a picture message makes the current one go out again.
  5. **Control** (CONTROL §28, x-control/7, owner session only, no password: display, not permission): `pictures`,
     `picture_set`, `picture_photo`, the `picture` event; the agent role, the agent CLI and MCP have none. CLI:
     `antenna picture [set|photo|remove|save]`. Schema 10 (`own_pictures`, `peer_pictures`).
  6. Defaults stay: a person without a picture shows initials; the owner's own agent shows the mark of its AI where the
     window knows it, a contact's agent a monogram (D-UI-24); a chosen picture wins over both.
- **What is new and why nothing existing fits** (D-94). The picture message is a new protocol message behind a
  feature, experimental like the agent announcements it follows (§21). The photo path is the existing check and CDR
  (SPEC §10) reused, not a new parser: the only new code that touches image bytes outside the sandbox decodes the PNG
  this daemon assembled from the worker's RGBA, and encodes a JPEG with the `image` crate already in the stack.
- **Why.** The maintainer's measure is the user: a picture is the fastest way to tell people and agents apart, and the
  drawn sets give everyone a good one without a photo. Sending the id keeps the message tiny and lets every Antenna
  draw the set at its own quality. A photo is the one personal file every contact gets: rebuilding it on both sides
  means no location or camera metadata leaves, and no contact can make another person's window decode bytes it
  chose.
- **Checked.** `tools/avatars_test.py` (sizes, metadata stripped, square crop, alpha over white, the cover's
  transparency, the manifest, pubspec and ARB kept in step, adding a set in one run, the committed assets; negative
  controls seen failing: an EXIF chunk, an oversized file, a wrong size, a stray file, a missing Russian name);
  `antenna_proto::picture` and `control::pictures` (wire shape, unknown fields refused, ids, sizes, the commands);
  `crates/antenna-files/tests/picture.rs` with the real sandbox (an own photo loses EXIF and its comment and keeps its
  orientation; a malformed image, a ZIP after a JPEG, a PNG declared as JPEG and an SVG are refused; negative control
  seen failing: the orientation not applied); `antenna_core::agentid` (only the link-root sets pictures, negative
  control seen failing), `antenna_core::pictures` (newest per subject; shown only when checked and the level
  allows); `crates/antenna-cli/tests/pictures.rs` with real daemons (drawn ids follow changes and removal; an own
  photo rebuilt on both sides and the received bytes never served; a malformed image and a non-image refused; an
  agent's picture only after it wrote, gone when it is removed; level 1 shows drawn pictures and no photo until the
  level is raised; `#[ignore]` with the `0.1.0-preview.7` release binaries: no picture message to a node without
  the feature, the history verifies; negative controls seen failing: pictures sent regardless of the feature, the old
  node refuses and the message stays queued; a contact's photo shown from the bytes it sent); the agent role has no
  picture command (`tests/agents.rs`, the protocol list).

### D-UI-35 · Profile pictures in the window (2026-10-06)
- **Decision.** Settings opens on a new first section, **Profile**, with one line, **Your picture**: the picture as
  contacts see it and what it is ("Fox · Soft", "A photo", "No picture: contacts see your initials"), a **?** that says
  what travels to contacts, **Change…** and **Remove**. **Change…** opens the picker as "Your picture"; **Picture…**
  on each of the owner's agents on the Agents page (a local agent: in its row's menu) opens it as "Picture for
  <name>". The picker has a tab per drawn set with its cover and name, the set's animals in a grid with the current one
  ringed and checked; a click applies at once (`picture_set {drawn}`); **Use my photo…**, **Remove** (red, only when a
  picture is set) and **Done**. **Use my photo…** opens an image (JPEG, PNG, WebP, GIF, BMP, HEIC); the crop step shows
  it in a square to move and zoom, always covering the square, with the circle contacts see outlined; **Use photo**
  draws the visible square at 512 × 512 as a PNG of pixels only, writes it into a folder of the window's own staging
  root (D-UI-21) and sends `picture_set {photo: path}`; the folder is deleted when the daemon answers, whatever it
  says. **What the window draws:** a drawn picture from its own assets by id (the 128 px file up to 64 px, the 512 px
  file above); a photo only from the daemon's rebuilt bytes (`picture_photo`, fetched once per id), never a path and
  never bytes the window read itself; an id the bundled manifest does not know, a withheld photo and a photo whose
  bytes have not come yet are initials. Every picture is a circle with a thin ring (set 2 has dark backgrounds). A
  picture comes ahead of the other marks: the owner's chosen picture wins over the AI mark of their agent (D-UI-24); a
  contact's agent shows the picture its contact announced for it in that link; an agent's picture keeps the small
  agent badge. **Where:** the chat list, the conversation header, the group chat bubbles (still none on the owner's
  own messages, D-UI-24), the contact card and its agents, the Agents page, approval cards for a request of the
  owner's agent, local agents, My devices (an own computer shows the picture chosen there, its agents and their
  requests theirs), the new chat and level notice dialogs. **An older daemon** draws no pictures and offers no
  **Picture…**; Profile says "Needs a newer Antenna daemon on this computer" with **Change…** disabled. Frames
  `78_picture_picker` (light, Russian; dark on the Modern set), `79_chat_pictures` (light, dark, Russian),
  `80_settings_profile`, `81_picture_crop`; every Settings frame shows the new section.
- **Why.** PG-29 and D-115: a person and each agent recognisable at a glance, with the drawn sets the maintainer chose
  or a photo. The window hands the daemon a re-encoded square, not the file, so nothing of the file leaves the window,
  and the daemon rebuilds it again in its sandbox; drawing only the daemon's bytes means a contact's photo is never
  decoded here before the check (SPEC §10).
- **Checked.** `test/widget/pictures_test.dart` (14: the protocol shapes; the picker's tabs, grid and current mark,
  applying at once, Remove, errors in words; the photo flow, a 512 × 512 PNG from the staging folder deleted after the
  reply with the daemon's bytes shown; a refused photo and a file the window cannot open; every place, My devices
  included; what is never drawn and the events; three older daemons; every bundled picture and cover decoding at its
  size, WebP included, in `flutter test` on Linux), `settings_help_test.dart` (the Profile **?**), the l10n guard reads
  ICU select variants, and live with two real daemons in `test/protocol/live_pictures_test.dart` (a drawn picture and
  a photo reach the contact's window; the photo arrives as a JPEG the daemon made, not the file). Negative controls
  seen failing: the staged file drawn instead of `picture_photo`, a picture on the owner's own messages, an unknown id
  drawn, a withheld photo fetched, the picker's actions on an older daemon. To verify on a Mac: the file dialog's
  image filter, HEIC decoding in the window, a phone photo's EXIF orientation there, the pinch zoom, set 2 on a real
  dark screen.

### D-116 · `antenna session`: agent CLI sessions in tmux, woken like Code mode (D-108 built; 2026-10-06, experimental)
- **Question.** PG-22 (the product plan §3.9): an interactive Claude Code session on a server waits
  for someone to type, and only the window's Code mode wakes one (D-UI-23, D-UI-25). D-108 chose tmux as the terminal
  host and the window's wake rules.
- **Decision.**
  1. **Owner CLI only:** `antenna session start <agent> [--dir] [--cli claude|codex] [--resume] [--no-wake]
     [--attach] [-- <the CLI's own arguments>]`, `session list`, `session attach <agent>`, `session stop <agent>`,
     `session wake <agent> on|off`. Not a daemon command: nothing in the control protocol changes except the backlog
     of item 5. With an agent token there is no such command (the agent's own `antenna session`, its taint, has none of
     these subcommands, and they answer `unknown_command`); a process inside an agent's process tree is refused
     (`forbidden`: the daemon says so at hello, `forced`), so an agent cannot start a session for itself or another
     agent.
  2. **tmux of its own:** a server on a private socket `<data-dir>/sessions/tmux.sock` (the folder 0700), started with
     a clean environment (the same allowlist as Code mode, plus `CLAUDE_CODE_OAUTH_TOKEN`, which signs Claude Code in
     on a server, `CODEX_HOME` and `CLAUDE_CONFIG_DIR`) and Antenna's own small configuration; the owner's own tmux
     sessions and settings are untouched. Sessions are named `antenna-<agent>` and addressed exactly (`=name`).
  3. **The pane's process** (`antenna session run`, hidden) is the pane's session leader and forks the CLI, like the
     window's bash wrapper: the CLI, not a session leader, becomes the MCP host the token binds to (D-28), and the pane's
     process is its parent, which is what `agent_watch` asks of whoever reads the agent's facts (CONTROL §23). The CLI
     gets the token file's path and the socket in its environment, never the token itself (D-86); the Antenna MCP server
     and the session-only hooks on its command line (Claude Code: `--mcp-config … --strict-mcp-config --settings …`;
     Codex: `-c mcp_servers.antenna.*`, `-c notify=…`, `-c hooks.…`, D-117); tmux closes every other descriptor. The
     pane's process writes nothing into the pane; its log is `<data-dir>/sessions/<agent>/wake.log`.
  4. **The wake** is the window's, ported: facts only from `agent_watch` (a message the agent reads, an approval of its
     own request), the same `AllowedLine`s and label sanitizer, the same hook and notify scripts byte for byte (a unit
     test compares them with the window's), the Stop hook for a running turn, at most one line per 30 s, coalesced,
     Enter 300 ms after the text. One difference: the waker cannot see a person's keys the way the window does, so it
     types only where the screen confirms the empty prompt (`capture-pane -e` for the faint placeholder and the cursor),
     even when the hooks say idle; nothing while tmux is in one of its own modes (copy mode), and nothing within 5 s of a
     key from a person attached to the session (`#{session_activity}`). `session list` shows the CLI's state, the switch,
     the last line (never message text) and "unavailable for this CLI version" when neither hooks nor the screen tell.
  5. **`agent_watch` sends the facts of messages that already wait** right after it subscribes (x-control/7, not yet
     released): a session started, or a window restored after an update, while unread messages wait for the agent still
     wakes it. Read without consuming anything (no read cursor moved, no approval taken); a message that lands at the
     moment of subscribing may come twice, and the waker coalesces by contact.
  6. `--resume` continues the CLI session its hooks recorded last (`claude --resume <id>`, `codex resume <id>`); only a
     lower-case UUID is accepted.
- **Why.** The same verified mechanism as the window, without a GUI (D-108); a second process that resumes the session
  would write into it twice; channels are closed to third parties (WATCHLIST W-24).
- **What is new** (D-94: experimental). The headless waker; reading the pane through tmux instead of the window's
  terminal. tmux, the hooks and `agent_watch` are reused as they are.
- **Checked.** `crates/antenna-cli/tests/session.rs` (two real daemons, a real tmux, a stand-in for Claude Code that
  runs the `--settings` hooks the way Claude Code does and starts `antenna mcp` from its `--mcp-config`): a message to
  the person and one to everyone type nothing; two messages to the agent by name type the fixed line once, 5.6 s after
  the first; the switch off, a message, past the 30 s limit: nothing, and on again nothing for what came while off; a
  12 s turn the person started is continued by its Stop hook 12.0 s after the message, nothing typed; a draft at the
  idle prompt (the hooks say idle): nothing until the person deletes it, then the line; a permission dialog (hook and
  screen): nothing for 40 s, the line after the person answered; the CLI's environment has the token file and no
  token, no descriptor above 2, no other session's markers; `--resume` passes the recorded ID; tmux missing, no token
  file, a bad name, a session already running; `stop` gives the CLI SIGHUP and records its end; from inside the agent's
  tree: `unknown_command` with the token file in the environment, `forbidden` without it; the agent CLI and the agent
  checks of `cli.rs` and `agents.rs` list the session subcommands as absent. Unit tests: the screen checks on
  Claude Code's and Codex's screens, the capture parser, the waker's decisions (quiet, rate limit, coalescing, the
  switch, dialogs, drafts, keys, continuation), the hook scripts, the session ID. `agent_watch.rs`: a watch opened after
  the message gets its fact first, twice in a row (nothing consumed). **The real Claude Code 2.1.291**
  (`real_claude_code_in_a_session_is_woken`, `#[ignore]`, part of `tools/claude-canary.sh` now): the folder trust
  question answered as a person would, then a message at the idle prompt: the typed line started a turn 9.3 s after
  it; a message during the person's turn: continued by the Stop hook; hook events `start prompt tool tool-done tool
  tool-done stop prompt continued`. **The real Codex 0.160.1** (`real_codex_in_a_session_is_woken`, `#[ignore]`, a
  stand-in model endpoint on loopback, no account): typed at the idle composer 5.6 s after the message, a turn
  continued by Codex's Stop hook. Negative controls, each seen failing: the screen check always passing (the line was
  typed over the person's draft, `abc` + the line); the `forced` refusal off (an agent's own process reached the token
  check, so it could start a session for itself).
- **Limits.** A message that arrived while the session's watch was not running yet (between `start` and the CLI's MCP
  server binding the token) is covered only by item 5. tmux is the owner's to install (D-108). On macOS the pane's
  checks are the same, but the run on a Mac is still to be recorded.

### D-117 · Code mode wakes Codex from its hooks and its notify program (PG-21; 2026-10-06, experimental)
- **Question.** D-UI-25 item 6: Codex has a documented `notify` program that runs when a turn completes; Codex and own
  commands got no automatic lines.
- **What Codex offers (checked on the Codex CLI 0.160.1, installed in a private npm prefix, against a stand-in model
  endpoint on loopback).** (a) **Hooks of the same kind as Claude Code's** (learn.chatgpt.com/docs/hooks):
  SessionStart (run with the first prompt, not when the program starts), UserPromptSubmit, PreToolUse,
  PermissionRequest, PostToolUse, Stop with `{"decision":"block","reason":…}` continuing the turn ("Blocked by hook"
  on its screen, then the model goes on), Interrupt (Esc ends a turn or closes a dialog), SessionEnd; passed with
  `-c hooks.<Event>=[…]`. Codex asks the owner to trust every new or changed hook definition ("Hooks need review": 1.
  Review hooks, 2. Trust all and continue, 3. Continue without trusting) and keeps the trust by a hash of the hook's
  text in its own `config.toml` (`[hooks.state]`). (b) `notify`, which Codex also runs for its helper threads: the
  turn of the thread that names a new conversation completes while the owner's turn still runs, with another thread
  ID. (c) `codex queue --thread <id> --message <text>` queues a message into a session through Codex's local
  app-server; reports say an idle session no longer starts a turn by itself since 0.157 (WATCHLIST W-25).
- **Decision.**
  1. The window and `antenna session` register Codex's state hooks with `-c`, and their command names the hook folder
     through `$ANTENNA_CODE_HOOKS` (set in Codex's environment), so the hooks' text is the same in every run: the owner
     trusts them once. Nothing answers Codex's review for the owner; until it is answered, nothing is typed (the
     review is a numbered choice and hides the cursor).
  2. **The state** comes from the hooks as for Claude Code, Interrupt meaning "at the prompt". `notify` counts only
     while no hook has reported in the session (an older Codex, or hooks not trusted): then "idle" needs Codex's empty
     composer on screen as well, and nothing goes into a running turn (no Stop hook to continue with).
  3. **A running turn** with hooks is continued by Codex's Stop hook, with the same file and script as Claude Code.
  4. **The screen check** knows Codex's composer: its last row starting with `›`, the cursor right after `› `, the rest
     blank or faint (the placeholder), its footer below (`? for shortcuts`), no `esc to interrupt` in the rows above;
     approvals and the hooks review show `› 1. …` with the cursor hidden; its sign-in screen `> 1. …`. These choices
     count as dialogs for Claude Code's check too.
  5. **The session ID for a restore** (D-103): `notify` writes its thread ID to `session.notify`; the hooks' `session`
     comes first, so a helper thread's ID never replaces the conversation's.
  6. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` pass to an agent CLI (configuration, not session markers): without them a
     user who moved them got a CLI that starts signed out.
- **Why.** Documented interfaces over the screen (D-UI-25); Codex now has the same interfaces as Claude Code.
- **Checked.** `test/widget/code_wake_codex_test.dart` (9, on the real 0.160.1 screens in
  `test/support/codex_screens.dart`): the screen check on the idle, after-turn, draft, running, approval and
  hooks-review screens, and not taking Claude Code's prompt for Codex's or the other way round; the launch (the
  overrides, the constant command text, the hook folder in the environment, no token); typed at idle by the hooks; a
  running turn continued by the Stop hook while a helper thread's notify arrives; nothing into an approval, even with a
  forged Stop, typed after Esc (Interrupt); nothing into the hooks review; notify only: nothing while the turn runs,
  typed at the composer after it; a draft never typed over. `code_hooks_test.dart` (notify: `turn-complete` only from
  the head of the argument, `session.notify`, the hooks' ID wins), `code_restore_test.dart` (a restored Codex is
  watched and gets the update line at its composer). `live_code_real_codex_test.dart` (tags `live`, `real-cli`; with
  `ANTENNA_REAL_CODEX` and a throwaway `CODEX_HOME`): the real Codex 0.160.1 through the window's own launch, hooks
  trusted once by the test as the owner, typed at the idle composer 5.4 s after the message, a turn continued by the
  Stop hook. The Rust side: D-116.
- **Limits.** Codex's screen changes with its releases like Claude Code's; the canary covers Claude Code only (a Codex
  canary needs Codex installed on the build server, which it is not; it runs without an account against the stand-in
  endpoint). Codex has no policy hook from Antenna (`antenna hook` speaks Claude Code's format); Codex's own sandbox and
  approvals apply.

### D-UI-36 · The Check panel runs the vendor's installer in a terminal after the owner's Run (D-110 built; 2026-10-06)
- **Decision.** A missing command-line program (Claude Code, Codex, Gemini CLI, Grok Build) gets **Install** *app*
  next to the install guide. It opens a dialog with the vendor's own command and the page it comes from, with the date
  it was compared with that page (2026-10-06: Claude Code `curl -fsSL https://claude.ai/install.sh | bash`, Codex
  `curl -fsSL https://chatgpt.com/codex/install.sh | sh`, Gemini CLI `npm install -g @google/gemini-cli`, Grok Build
  `curl -fsSL https://x.ai/cli/install.sh | bash`); nothing runs before **Run in a terminal**. Then the command runs in
  the owner's login shell (`$SHELL -l -c …`, so the profile's PATH with Node or Homebrew is there) in a terminal in the
  same dialog, under Code mode's wrapper: descriptors above 2 closed, the window's variables that are not the user's
  own context removed (no agent token, no socket, no other agent session's markers), the exit code reported through
  the terminal. The owner sees all it prints, can answer its questions, **Stop** it (SIGHUP to its process group, then
  SIGKILL) and **Check again** when it has finished. The command is a constant of the app's definition, never built
  from anything else. Frames `82_install_cli(_ru)`: the dialog before Run.
- **Why.** D-110: the owner keeps control and sees what happens; a one-click install without hiding what runs.
- **Checked.** `test/widget/install_cli_test.dart` (6): every command is one fixed line from the vendor's own site
  with its page; the dialog shows the command and runs nothing before Run, nor after Cancel; Run starts exactly
  `[login shell, -l, -c, command]` under the wrapper in the home folder, with the agent token, the socket and
  `CLAUDECODE` of the window's environment in the unset list and no Antenna variable set; the output shows; the exit
  code 0 says "Finished", Check again runs the checks; Stop sends SIGHUP and the code is reported; the login shell
  choice; under a real bash the installer's environment has HOME and none of the Antenna variables, and the exit code
  OSC is there. Negative control seen failing: a dialog that starts the installer when it opens.
- **Limits.** The installer runs with the owner's own rights: a command that asks for `sudo` asks in the terminal, and
  the owner answers there. On a Mac the run is still to be recorded (the Claude Code native installer and Homebrew's
  PATH in a login shell).

### D-118 · "Escalate to": an agent asks its supervisor, the owner or a contact, and the question stays data (PG-18; 2026-10-06, experimental)
- **Question.** An agent that reaches something it should not decide alone (a contact asks for more than the task, two
  instructions disagree, a step cannot be undone) had two choices: guess, or write a message to someone and hope.
  PG-18 asks for a per-agent supervisor; teams (D-111) left "Escalate to" open. Who is the supervisor, how does the
  question reach them, and how does the answer come back without turning a contact's words into the owner's word?
- **Decision.**
  1. **Per agent, the owner sets the supervisor** (`agent_escalate`, with the password, as `agent_tasks`): the owner
     by default, or one contact within the agent's links. A contact outside them is refused: an agent's questions
     never open a channel to someone it does not see.
  2. **To the owner:** the daemon keeps the question in the node's encrypted database and announces it (the owner's
     `escalation` event). The window shows it first in **Approval requests**, as a card, with a notification that
     names the agent only (SPEC §11). The owner answers or sets it aside (`escalation_answer`, an owner session: the
     answer is the owner's word to the agent, like `wake_say`); the agent gets the decision once, in `wait`, `inbox`,
     `escalation_get`, a waiting `escalate`, or its own `escalation` event. Code mode and `antenna session` type a
     fixed line for it, "Your question was answered: read your inbox and continue." (an `AllowedLine`, D-116).
  3. **To a contact:** the question goes as the agent's message to the contact in person, through `send`, so every
     rule of a message applies: the level limit, cross-link flow, no write-down, the secret scanner, approvals. The
     answer is an ordinary message from the contact, data with its level, as any other.
  4. **The question is data.** It is the agent's text and may repeat what a contact wrote to it. The record keeps what
     the agent's session had read when it asked (its taint, SPEC §9), and the card and the CLI show the question
     quoted with "had read messages from Jordan Lee (level 3)". Nothing in the daemon acts on a question's text.
  5. **Teams:** a worker asks the owner, always (it sees no contacts, and the owner cannot point it at one); questions
     about its task go to its lead with `task_report` "blocked", as before. A lead's questions follow its setting, as
     any agent's. The record carries the team, and the card names it.
  6. Owner commands (`agent_escalate`, `escalations`, `escalation_answer`) are absent for agents; the agent has
     `escalate` and `escalation_get` (MCP `escalate`, `escalation_status`; the MCP instructions say where its questions
     go). Schema 11: `escalations`, `agent_escalation`. CONTROL §29.
- **Why.** The smallest mechanism that keeps the rule "the daemon decides, a model never does": the owner path is a
  record and a card, like an approval; the contact path reuses `send` and adds no new way out of a link. What is new
  is only the record and its delivery; nothing existing (a message to oneself, an approval with a free-text field)
  carries an answer back to the asking agent once and only to it.
- **Checked.** `crates/antenna-cli/tests/escalations.rs` (real daemons, a real MCP server):
  `a_question_to_the_owner_is_answered_once_and_reaches_only_its_agent` (the owner's event, the list, nothing for the
  agent before the answer, another agent gets `not_found` and hears no event, `wait` gives the answer once, a waiting
  `escalate` returns with it, answering twice is `denied`, a dismissal reaches `inbox`);
  `a_question_to_a_supervisor_contact_is_a_message_under_the_send_policy` (bob gets the message; after reading carol
  the flow asks the owner first; outside the links refused; back to the owner, the record keeps carol at level 3);
  `the_mcp_server_offers_escalate_and_says_where_questions_go`; the session waker's unit test
  `an_answered_question_has_its_own_line_and_a_message_covers_it`. `teams.rs`
  `a_lead_that_read_a_level_2_contact_writes_tasks_that_run_no_commands`: the worker of the tainted task asks, the
  question goes to the owner with the team and bob at level 2, and the owner cannot send a worker's questions to a
  contact. The three "no owner API for agents" checks list the new commands. The window:
  `test/widget/questions_test.dart` (6: the card, quoted, whose messages it read; Answer and Set aside; a background
  notification without the question's text; the team; the setting with the password; an older daemon shows
  nothing), `code_wake_hooks_test.dart` (the answered line, once, only for its agent),
  `test/protocol/live_questions_test.dart` (a real `antennad`). Frames `83_agent_question(_ru)`. **Negative
  controls**, each seen failing: the agent event filter off (another agent hears the answer); `escalation_get` without
  the agent filter (another agent reads the question); answers not marked given (a second `wait` gets it again); the
  worker refusal off (the owner's `--to` is refused by the links rule instead, with another message).
- **Limits.** One supervisor per agent; no chain (a supervisor contact's own agent asking further is that contact's
  business). The contact path stores no link between the contact's reply and the question: the agent reads the reply
  as any message. A question that needs the owner's approval on the contact path fails with `approval_required` as
  `send` does; after the approval the daemon sends the message (D-100), but no question record is kept for it. The
  team room as a group conversation is still open (D-111).

### D-119 · A removed agent's keys are revoked at its contacts; the live display names the agent that writes (PG-20; 2026-10-06)
- **Question.** D-75 left two things undone: removing an agent kept its key valid at every contact it wrote to (no
  revocation was ever sent), and a stream's live display did not say which agent writes: only the final message did.
  With chats per agent (D-113) the second matters more: an agent's live reply must stand in that agent's chat.
- **Decision.**
  1. **Revocation.** `agent remove` sends, in each link where the agent's key was announced, the existing
     `control`/`agent` message with `state: "revoked"`, signed by link-root, through the ordinary queue, and deletes
     the key's secret here. The name sent is the one the contact knows (`wake` for a link's wake agent). The contact
     refuses the key for every later `n` (the D-75 rule) and lists the agent as revoked. A new agent under the same
     name gets a new key and a new announcement. Nodes since `0.1.0-preview.2` accept a revocation, so no new feature
     is needed. A link that cannot send at that moment (a rollback, an unfinished rekey) keeps the key valid at the
     contact; nothing here signs with it any more, and the log says so.
  2. **The name in the live display.** `stream-open` gets an optional `agent` (PROTOCOL §20): the agent's name in the
     link, only to a node that answered the new feature `stream-agent/0` (older nodes parse the opening strictly).
     The receiver checks the name rules and passes it on as `via_agent` in `message_stream` and `streams`; it is the
     contact's node's word for the display, and the final message's author stays what counts. Our own outgoing
     streams carry our agent's name the same way. The window writes "Jordan Lee / builder" over the bubble and shows
     a named stream only in that agent's chat; an unnamed one (a person, or an older node) shows in every chat, as
     before.
- **Why.** Both reuse what exists: the revocation format and its checks have been in every node since D-75; the name
  is one optional field behind a feature, the same pattern as `addr/0`.
- **Checked.** `peer_agents.rs` `removing_an_agent_revokes_its_key_at_the_contact` (two real daemons: the contact lists
  the key as revoked; an agent that never wrote has nothing to revoke; a new agent under the same name writes and is
  shown under it; both histories verify). `stream.rs` `the_live_display_names_the_agent_that_writes` (both sides'
  events and `streams` carry `via_agent`; the final message carries the same name; the owner's own stream names
  nobody). `streams_test.dart`: the name on the bubble, the bubble in the agent's chat only, an unnamed stream in every
  chat. The D-75 unit tests (`agentid::tests`) already refuse a key after its revocation. **Negative controls** seen
  failing: `agent remove` without the revocation (the contact never lists it revoked); the window's chat filter off
  (the agent's bubble shows in the person's chat).
- **Limits.** A link that is not running when the agent is removed is not told. Removing a team's worker revokes
  nothing, since workers never write to contacts.

### D-120 · A file offer can be for one agent of the contact; the answer to an agent's file request goes to it (PG-19; 2026-10-06)
- **Question.** Addressing (D-90) covered messages only: every file offer reached every agent of the recipient's node
  that had the link. In a link between two companies (scenario S3) one agent asking for a build meant all of the
  other side's agents saw the build. With chats per agent (D-113) a file sent in an agent's chat should be for that
  agent.
- **Decision.**
  1. **The address on the wire.** A `file` message may carry `to` in its `core` (never `topic`), only to a node that
     answered the new feature `file-addr/0`; older nodes refuse `to` on a non-text message, so they get the offer
     without it, and the sender's own history keeps the address either way. The peer feature bits grew from 8 to 16
     (the 8 were used up).
  2. **The recipient's rule.** An agent sees an offer addressed to it, to everyone, or to nobody (offers from older
     senders cannot be addressed, so "nobody" keeps today's behavior); one addressed to another agent or to the person
     (the link's wake agent excepted, as for messages) is left out of its `files_pending` and its `file` events, and
     `file_preview`, `file_accept` and `file_reject` answer `not_found`, the same as for no file. The address is read
     from the offer's signed `core`, never from a derived column; an offer whose message cannot be read is not shown.
  3. **Requests.** An agent's `request_file` is now signed with the agent's key in the link (like its messages,
     PROTOCOL §21), and the node that serves it addresses the file to that agent. A request signed by link-root (the
     owner, or an agent of an older node) gets an answer without an address, as before.
  4. **The surfaces.** `share_file` (owner and agent), `share_file_content`, `antenna share --to/--to-agent`, the MCP
     tools `share_file` and `share_file_content` (`to_agent`, `to`). The window addresses a file sent in an agent's
     chat to that agent (in the person's chat, no address, as before), and only to a daemon that has `chats`: an
     older one parses `share_file` strictly.
- **Why.** The same rule and the same `core` field as messages; nothing new for history verification (the field is
  in `core`, so in the ID). Hiding an unaddressed offer from agents without "messages to everyone" would have broken
  every existing file flow, and an older sender cannot address.
- **Checked.** `files.rs` `a_file_offer_addressed_to_one_agent_reaches_only_that_agent` (two real daemons: the other
  agent's list, `preview`, `accept`, `reject` and its event subscription leave the offer out; the addressed agent
  accepts it; Bob's history carries the address; the answer to the agent's request reaches only it, the owner's
  request's answer both; a malformed address refused). The existing file suites pass unchanged
  (`review_shared_requests_agent_reject_folders_and_revoke` relies on the owner's request staying unaddressed).
  Window: `chats_test.dart` (an agent's chat, everyone, the person's chat, a daemon before chats). **Negative
  controls**, each seen failing: the agent's visibility check off (the other agent lists the offer); the event filter
  off (the other agent hears of it); the agent's request signed by link-root (its answer reaches both agents); the
  window's address off.
- **Limits.** The owner's own request gets an unaddressed answer (a person-addressed one would hide it from the
  agents that handle files today). Files from older senders stay visible to every agent with the link.

### D-121 · A sleeping resident session lives in the encrypted database, not on disk (PG-24; 2026-10-06)
- **Question.** A resident agent (D-93) resumes its session from the agent CLI's transcript, which Claude Code keeps
  as plain text in the session's HOME (`<data>/wake/resident/<link>/home/.claude/projects/…`), together with the
  agent's notes in its working folder. Both hold what the contact wrote, and they stayed on disk for as long as the
  session lived, unlike everything else of a link, which is in the SQLCipher database.
- **Decision.** While the process runs, the files must be on disk (the agent CLI reads and writes them). When it ends
  (the idle stop, a crash, `antenna lock`, the daemon stopping), the daemon **parks** the session: it reads the HOME
  and the working folder into one record (`resident_park`, a CBOR list of directories, files with their modes, and
  symbolic links as links) of the encrypted database and deletes the folders. Before the next process starts it
  **unparks** them and deletes the record. After a crash the next unlock parks whatever was left. A reset or wake off
  forgets the record with the folders. No new cryptography: the database's own encryption.
  - Symbolic links are stored as links and never followed, and files with more than one hard link are left out: an
    agent cannot make the daemon read a file from outside its folders into the record and back into its sandbox.
  - A session over 64 MiB of files is not parked: the files stay where they are (readable only by the owner) and the
    log says so; holding more in memory at once is not worth it, and compacting or a reset shrinks it.
  - The session view gets `parked`.
- **Why.** The simplest way to put the files where the rest of the link's data already is, encrypted at rest with the
  keys the owner unlocks; nothing about the agent CLI changes, and a resume works as before.
- **Checked.** `resident.rs` `a_sleeping_session_lives_in_the_encrypted_database` (real daemons, a stand-in agent
  that keeps what it read in a transcript file in its HOME): while it runs the contact's marker is on disk; after the
  idle stop `parked` is set and nothing under the data directory holds the marker; the next message resumes the same
  session; the daemon killed with the agent running leaves the files, the next unlock parks them, and the session
  resumes again; a reset leaves neither record nor files. The other resident tests pass unchanged (a crash and a
  daemon restart resume). Unit tests: stored paths never leave the session's folders; links are kept as links and
  hard links skipped. **Negative controls** seen failing: parking off (`parked` never set); the unlock's sweep off
  (the crash's files stay); links followed (the walk reads through the link).
- **Limits.** While the agent runs, and between a crash and the next unlock, the files are on disk in plain text.
  Deleted files may survive on the disk below the file system (journals, SSD wear levelling): full-disk encryption
  covers that. Team workers (D-111) keep their own sessions and are not parked yet.

### D-UI-37 · A resident agent's session on its rule's card: state, counters, talk, compact, reset (PG-23; 2026-10-06)
- **Question.** Resident agents (D-93) were visible only in the CLI (`antenna wake list`, `wake say`, `wake session`):
  in the window a resident rule looked like a one-shot one.
- **Decision.** The wake rule's card (in Agents and in the contact's card) shows, for a resident rule, the session's
  state (asleep, waiting, working, stopped after crashes), its turns with the owner's among them, starts, tokens and
  context, the CLI's cost estimate, compactions, the taint it keeps until a reset, and that it sleeps in the encrypted
  database (D-121). **Talk** opens a dialog for the owner's own turn (`wake_say`): labelled as the owner's, the answer
  streams in from `resident_delta`; "Send its answer to <contact> instead" sets `to_contact`; while the agent works,
  "Interrupt what it is doing first" sets `interrupt`. **Compact** and **Stop** are `wake_session`; **Reset…** asks for
  the password. The window refreshes the rules on every `wake` event of a resident rule. Frames
  `84_resident_session(_ru)`, `85_resident_talk`.
- **Why.** Everything the daemon already offers, nothing new in the protocol except reading `parked`.
- **Checked.** `test/widget/resident_test.dart` (4): the card's state, counters, taint and parked line; Compact and Stop
  reach the daemon and the state follows; Reset with a wrong and then the right password; Talk streams the answer and
  sends to the contact with the box ticked; a one-shot rule shows none of it. Negative control seen failing: Reset
  without the password.
- **Limits.** Setting a rule up as resident is still the CLI's (`antenna wake set --resident`); the window's set-up
  dialog makes one-shot rules.

### D-122 · An own computer's wake agent may work in the owner's project with the owner's toolchain (PG-17; 2026-10-06)
- **Question.** A wake or resident agent (D-67, D-93) sees only its own folders, the link's folder and its provider:
  on the owner's server (scenario S1) build and test work therefore ran outside the sandbox. Team checks (D-111)
  already give a sandbox toolchain folders, plain variables and registries through the proxy.
- **Decision.** `wake_set` takes an **own-machine profile**: `project` (a folder, writable, the agent's working
  folder), `tool_paths` (folders it reads; a `bin` among them goes on its PATH) and `env` (plain `NAME=value`
  variables, never secrets). Registries are the existing `allow_hosts`. Only for a contact at trust level 5, the
  owner's own computer (D-99): an agent woken by anyone else never works in the owner's project (`bad_request`).
  The folders follow the rules of team checks (absolute, existing; never the daemon's data, the whole home folder,
  `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config`, `~/.claude`, `~/.codex`, `~/.local/share`), and are checked again at
  every start (a folder may have become a link since the rule was set). Variable names follow the secret-variable
  rules plus the check rules (not `PATH`, `HOME`, `ANTENNA_*`, `LD_*`, `DYLD_*`, `*_PROXY`), and a name cannot be both
  secret and plain.
- **Why.** The sandbox and the proxy stay as they are; the profile only adds folders the owner names, with the rules
  the team checks already proved.
- **Checked.** `wake.rs` `an_own_computer_agent_works_in_the_project_with_its_toolchain` (real daemons and the real
  sandbox): at level 3 the profile is refused; at level 5 the daemon's data as a project and `LD_PRELOAD` are refused;
  the agent's working folder is the project, it writes there, reads the toolchain, finds its tool on the PATH and
  cannot write into the toolchain. `resident_test.dart`: the card shows the project and the toolchains. **Negative
  controls** seen failing: the level check off; a toolchain folder writable; the daemon's data folder allowed.
- **Limits.** The window's set-up dialog does not offer the profile yet (the CLI does). A command the agent runs in
  the project runs with the agent's rights in the sandbox (the hook's level-5 rules, D-99); level 4 commands from an
  allowlist (PG-46) are not built.

## The agent map (2026-10-06)

### D-123 · The agent map: the owner draws an agent's default counterpart; the other side of a line to an own computer is an approval request there (2026-10-06, experimental)
- **Question.** PG-56 of the plan (the product plan). The maintainer: he had picked an agent on
  this computer and the right session on the server by hand; a person should see a screen where they connect this
  session with that agent directly, a "tunnel": when he writes to the session, it knows which agent to talk to; like a
  mind map where you connect two objects, so a person sees which agents talk to whom.
- **Decision.**
  1. **A line is the agent's default counterpart** (CONTROL §30): a contact's agent, an own computer's agent, or a
     contact's person, kept on this computer (`agent_counterparts`, schema 12) and set only by the owner
     (`agent_connect`, the password or an owner proof). An agent's `send` without a contact goes to the counterpart's
     contact and, unless `to` is given, to its agent or person; with a contact and nothing read there yet, to the
     counterpart instead of the person (the reply rule of D-90 still comes first). The agent sees its counterpart in
     `session` (MCP `get_session`, and a line of the MCP instructions) and has no command to change it.
  2. **Task authority comes with the line when the owner ticks it**: the existing per-contact list of D-88
     (`tasks: true` adds the contact; from the default "contacts at level 5" the list becomes explicit). It stays per
     contact: what the contact's other agents address to this agent is a task too, as before.
  3. **The other side.** A contact that is not an own computer is never asked: only this side changes, and the window
     and the CLI say the other side is the contact's decision. An own computer (level 5 both ways, `agent-connect/0`) is
     asked over their link (PROTOCOL §24, `connect`); it makes an **approval request** for its own owner and changes
     nothing until it is approved there, or from this computer with D-106's remote approval (only approve and deny
     travel, as before). No owner command becomes remote: the asking computer can cause a request, never a change.
  4. **Disconnecting** needs an owner session and no password (it only takes away, D-84); the other side of an own
     computer is asked the same way, and a line only the other side drew is removed from here too.
  5. **What the map draws** comes from the daemon: our agents' counterparts, the counterparts an own computer reports
     for its agents (status fields only to a node with `agent-connect/0`, only for a counterpart on that link),
     `agent_traffic` (who wrote to whom in the last 30 days, from the stored display columns, like chats) and the teams.
- **What is new and why nothing existing fits** (D-94). Reused: addressing (D-90), visibility (D-91), task authority
  (D-88), approvals carried out by the daemon (D-100), the own-device link request and remote approvals (D-114, D-106).
  New and experimental: the counterpart as a stored default of `send`, the `connect` ask and the two status fields
  behind `agent-connect/0`. Nothing cryptographic.
- **Threats, and what answers them.** An agent redirecting its own messages: it has no command, and every message still
  passes the policy (a counterpart is only a default, not a permission). A contact that is not an own computer asking
  for a change: it is never asked and a request from it is refused before decryption and again when handled (`level`).
  An own computer flooding requests: at most 8 wait per link, and a repeat is the same request. A request that clears
  another link's counterpart: a disconnect touches only a counterpart on the asking link. Residual: an own device is
  trusted at level 5 anyway (D-99); a status's connection facts are that computer's word, shown, never used for a
  permission.
- **Not in this decision.** A line between two agents of one computer: they have no link between them, so a counterpart
  there would route nothing (a local channel is LOCAL-ASSISTANT §8.3's direction, with its own threat analysis); the
  map says so instead of drawing a line that does nothing. A line between two other computers (draw it on one of them).
  Task authority per contact's agent rather than per contact. Lines for a link's wake agent, a team's worker or a
  local-model agent (`denied`: the daemon decides whom they answer).
- **Checked (Linux, debug).** `crates/antenna-cli/tests/connections.rs` with real daemons: a contact's agent (send
  without a contact reaches it, only it reads it there, its reply is a task, MCP `get_session` and instructions,
  `send_message` without a contact, no agent command and no MCP tool, traffic counts, disconnect without a password,
  a named contact going to the counterpart, a person as the counterpart, nothing asked of or changed on the contact's
  side); two own computers (the request there in the daemon's words, nothing before approval, the request in My devices,
  a repeat is the same request, applied after approval, the status's facts both ways, messages both ways read as
  tasks, `unchanged`, a disconnect approved from the first computer with its device key, a denial applying nothing); a
  computer at ∞ only one way making no request. Unit tests: `antenna_proto::control::connections`,
  `antenna_proto::device` (shapes, limits, the status fields absent when empty), `antenna_core::connections` (task
  lists from the default, what an ask changes, the approval text and its binding), the MCP instructions; the "no owner
  API for agents" checks (CLI, protocol, MCP) list the three commands. Negative controls, each seen failing once: the
  level check of `ask_other_side` off (bob, at 3, was sent a request and refused it); `send` without a contact not
  routed (`not_found`); `connect_ask_in` applying at once (a counterpart before any approval); the continuation not kept
  (the approval applied nothing); the daemon's run not using its approval up (the same ask after the line was removed
  was refused as `approval_used` instead of becoming a new request); both level checks of the recipient off (a computer
  at 4 made a request).

### D-UI-38 · The agent map in the window: a view of Agents, lines drawn from this computer's agents, each side said in words (2026-10-06, experimental)
- **Question.** The window's side of D-123: the maintainer's "map where you connect two objects", visually convenient,
  showing which agents talk to whom.
- **Decision** (DESIGN "The agent map").
  1. **A view of Agents, not a navigation item**: Agents → **List** | **Map** in the page header. The map shows the same
     agents; a seventh navigation item would also redraw every frame.
  2. **This computer in the middle**, own computers on one side, contacts on the other: every line has one end here
     (D-123 draws only from this computer's agents), so no line crosses a cluster.
  3. **Four kinds of lines, never dashed** (dashes read as disappearing messages): connected (solid, arrowheads where
     messages without an address go), waiting for approval on the other computer (muted), recent messages (thin, with
     the time), a team (violet, with its name); **tasks** marks the end that takes the other end's messages as tasks.
  4. **Drawing a line opens a dialog that says what changes on each side**, with checkboxes for task authority: on this
     computer by default for an own computer and off for a contact; on the own computer by default; for a contact only
     "their side is their decision". The window sends `tasks` only when it changes the agent's task authority, and
     `peer_tasks` only for an own computer's agent.
  5. **The request on the other own computer is answered from the dialog** (**Approve now**, the My devices card) or
     there; the line shows as waiting while that request is pending in the computer's status.
  6. **Nothing drawn that does nothing**: two agents of one computer, a wake agent, a team's worker, a local-model agent
     and you in person cannot be ends; a drop says why and sends nothing.
- **Why.** The owner sees who works with whom and connects a session to an agent in one gesture, and the dialog makes
  plain which computer changes and who decides each side.
- **Checked.** `test/widget/agent_map_graph_test.dart` (9: clusters from agents, own computers and contacts; connected, both-ways, waiting, traffic and team lines; traffic hidden under a connected line; the ends that cannot be connected; the drops), `agent_map_test.dart` (10: the map, the dialog's requests for an own computer, a contact's agent and a person, the result states with **Approve now** and **Ask again**, disconnect without a password, drops that send nothing, an older daemon, the agent's card), `test/protocol/client_connections_test.dart` (4), the live `live_agent_map_test.dart` (two real daemons: connect from the window client, the request there, approved there with its password, the line both ways with tasks, a message without a contact routed, `agent_traffic`, a disconnect without a password making a request there); `flutter test --exclude-tags live` 941 passed. Negative controls, each seen failing after the merge with `main`: `peer_tasks` sent for a contact that is not an own computer, a line between two agents of this computer accepted, a wake agent, worker or local-model agent accepted as an end, disconnect sending a password, an older daemon still offered connecting. Frames `86_agent_map` (light, dark, Russian), `87_agent_connect` (light, Russian); the Agents frames redrawn for the header toggle.

### D-124 · What needs the owner is set when the owner makes the agent: its folder, instruction files, git identity, Claude Code rules (2026-10-06)
- **Question.** Field feedback from two days of an agent working through Antenna with the maintainer's Mac: settings
  that need the owner's authority (the folder an agent works in, its repository instructions, the git identity it
  commits under, the Claude Code permission rules it needs) reached the agent later as another agent's message, and the
  receiving agent's runtime rightly refused them as a possible prompt injection.
- **Decision.**
  1. **Set once, by the owner, at creation, shown before it is written.** `antenna agent setup <name> [--dir D]
     [--app claude-code|codex]`, `antenna agent add … --dir D` and `antenna connect …` take the same choices:
     `--instructions` writes `AGENTS.md` from Antenna's template (how messages, tasks, files and approvals work, that a
     contact's text is data, that owner settings are the owner's and questions go through `escalate`) and, for Claude
     Code, a `CLAUDE.md` that imports it (`@AGENTS.md`), only where missing; `--git-name` with `--git-email` set the
     folder's git identity (`git init` first when it is not a repository; no shell); `--allow antenna-tools,antenna-cli,git`
     adds those Claude Code rules (`mcp__antenna`, `Bash(antenna:*)`, `Bash(git:*)`) to `.claude/settings.json`
     `permissions.allow`. The plan (each file's content, each command, each rule) is printed and done after the
     owner's yes in a terminal or `--yes`; without either nothing is written. `connect` shows it with Claude Code's
     command and does both after one yes. Without `--dir`, `agent setup` and `agent add` use the agent's own folder
     `~/Antenna/agents/<name>` (0700, made if missing), the window's default too.
  2. **Another program's config is written by D-85's rules**: `.claude/settings.json` stays strict JSON or is not
     touched (a comment, another shape of `permissions` or `allow`: refused with the reason), only the chosen rules are
     added, everything else stays, the old file is copied to `settings.json.antenna-backup` first, the new one renamed
     into place. An existing `AGENTS.md` or `CLAUDE.md` is never changed. A second run finds everything in place and
     does nothing ("once").
  3. **The owner's.** The commands are owner CLI commands (an owner session; the agent CLI has no `agent` or `connect`
     command: the "no owner API for agents" CLI check lists them). The window's **Start an agent** does the same
     (D-UI-39) with the same templates and rules, byte for byte (`agent_setup.dart`; a unit test of `setup.rs` compares
     them); there, defaults are ticked only in the agent's own folder, never in a project folder the owner chose.
  4. **Nothing an agent reads tells it to run an owner command.** The MCP instructions, every MCP tool description,
     the agent CLI's help and the template are checked by unit tests against the owner CLI's commands the agent CLI
     does not have; the agent CLI answers an owner command with "`antenna agent tasks` is the owner's command … ask with
     `antenna escalate`" (it used to name the value of a global option before the command, "no such command: <data
     dir>"), and its text for `approval_required` says the daemon finishes the request itself (D-100).
- **Why.** The owner's authority is the owner acting, not text that claims it; a receiving runtime cannot tell the
  two apart, and should not have to. One visible step at creation replaces a message nobody may follow.
- **Not in this decision.** Codex's permissions (its config is global, `~/.codex/config.toml`; nothing is written there);
  other agent CLIs' instruction file names (they read `AGENTS.md`).
- **Checked.** `setup.rs` unit tests (a new folder gets the templates, the identity and the rules, a second plan does
  nothing; existing files and settings kept and merged with a backup; non-strict JSON untouched; the template names
  only the agent's own commands; the window's constants); `tests/agent_view.rs::the_owner_sets_up_an_agents_folder_once`
  (real daemon: the plan without a yes writes nothing, with it everything, the owner's `AGENTS.md` kept, `git config`
  read back, a second run only keeps; an unknown agent `not_found`, nothing chosen `bad_request`; `agent add --dir`
  with Codex); `tests/chats.rs::connect_makes_a_session_its_own_agent` with `--instructions --allow`; `tests/agents.rs`
  (an agent's `agent setup`, `agent add --allow`, `connect --allow` are `unknown_command`); `main.rs` and `mcp.rs` unit
  tests (owner commands named as the owner's; the help and the MCP texts name none). Negative controls seen failing:
  the confirmation answering yes without a terminal (the test's "nothing written" failed); a sentence in the agent
  CLI's help naming `antenna agent add` (found by the new check, reworded).

### D-125 · A link's folder is the contact's label as one shell word (SPEC §10 amendment from field feedback, 2026-10-06)
- **Question.** A link folder named "hel server" broke every shell command that named it (`cp ~/Antenna/links/hel
  server/shared/…`), in the hands of agents above all.
- **Decision.** The folder of a link is the label as one shell word: letters and digits of any script, `.`, `_` and
  `-` stay, every other character becomes `-`, runs of `-` become one, `-` and `.` are taken off both ends ("hel
  server" → `hel-server`, "Bob's Mac" → `Bob-s-Mac`); nothing left, or a special name: the first 16 hex of the link ID;
  names that coincide ignoring case and Unicode form get `-<8 hex>` as before. The label stays the contact's name
  everywhere it is shown. **No silent move:** a link whose folder was made before under the label as it is keeps that
  folder while it exists (the files already there, the paths in scripts and approvals). An agent reads its links'
  folders in `agent_contacts[].folder` (MCP `list_contacts`).
- **Why.** The folder is a path people and agents type and paste; the label is a display name. A migration with a
  symlink was considered and left out: the old folder working as it is needs no second name.
- **SPEC.** §10's `~/Antenna/links/<contact>/` now reads "the contact's label as one shell word"; listed under "SPEC
  amendments by the maintainer" above.
- **Checked.** `files::tests::link_folders_are_shell_words_and_old_folders_stay` (the rule, collisions, an older
  folder kept); `tests/agent_view.rs::a_label_with_spaces_gets_a_folder_a_shell_takes_as_one_word` (real daemons at
  level 5: a file for "hel server" lands in `hel-server/shared/`, the agent's contacts name that folder, a folder from
  before under the label as it is keeps receiving). Negative control seen failing: the label used as it is (the file
  landed in `hel server/`).

### D-126 · An agent gets every message whole, the files saved for it with where they are, and SHA-256 next to BLAKE3 (2026-10-06)
- **Question.** The same field feedback: `inbox` cut long messages ("… 1190 more characters not shown") and marked them
  read, so the agent dug the rest out of `history --json`; a file the daemon accepted by itself at level 5 never
  appeared in `files_pending`, `history` did not list it, and it sat in `~/Antenna/links/<label>/shared/` unseen;
  macOS has `shasum`, not `b3sum`, so the BLAKE3 shown could not be checked there.
- **Decision** (CONTROL §5, §14).
  1. **Never mark unseen text read.** One agent `inbox` reply holds at most 32,000 characters of text and 100 messages;
     the first message always comes whole; the rest stays unread with `more: true`. An MCP host cuts a long result at
     its own limit (Claude Code 25,000 tokens), so the bound is the daemon's. The agent CLI prints each message whole
     with its id and length; into a pipe (an agent's tool call) the `│` frame keeps each line whole, so a command in a
     message copies as it is; in a terminal it wraps at the terminal's width. `--json` is named in the agent CLI's
     help.
  2. **Files saved for an agent reach it.** A received file accepted into a link folder (by the owner, the daemon at
     level 5 or another agent) is a notice for every agent with the link in scope that may see its offer (D-120), the
     accepting agent excepted: the whole `FileInfo` with `saved_path`, size, `sha256`, `blake3` in its next
     `agent_inbox.files` (tainting with the link, as the name is the contact's data), a fact without the name in
     `waited.files`, and either ends a wait. The agent that sent a file gets the contact's answer the same way
     (`direction: "out"`, `state: "accepted"` = accepted and saved there, or `"rejected"`), from the contact's existing
     receipt; the sending agent is recorded with the outgoing file, since an agent's offer is signed by link-root.
     `files_pending {all}` (CLI `antenna files list`, MCP `list_files`) lists saved files with their paths; the agent's
     history has unaddressed offers by the offers' rule. In memory, at most 64 per agent: `files list` covers a
     restart.
  3. **SHA-256 next to BLAKE3.** The sender computes it while hashing for its check, the receiver while decrypting for
     the check (and again at accept); kept in the quarantine record and the outgoing record (new optional fields),
     shown in `FileInfo.sha256` and on the CLI's file lines (`sha256 …` first, `blake3 …` whole). Not on the wire, not
     in the history line (that is derived from the signed manifest and verified as it is).
  4. **Global options before the command** (`antenna --data-dir X agent …`) were parsed fine; the agent CLI's refusal
     named the option's value as the command. It now names the command (and says whose it is, D-124).
- **Why.** What the daemon records as read must be what the agent was given; a file the owner's own computer saved
  is the agent's business when it may see it, and it should not have to search folders for it. SHA-256 is what every
  system can check.
- **No protocol change.** Everything is local: control fields only add (x-control/7), the sender's notice uses the
  receipt the contact already sends.
- **Checked.** `tests/agent_view.rs`: `an_agent_gets_every_message_whole_and_the_rest_waits_unread` (three 20,000
  character messages: one per reply, `more` until the last, none lost; a 6,000 character message with a long command
  whole in the human output; `--data-dir X` before `inbox` works and before `agent tasks` is named as the owner's);
  `files_saved_for_an_agent_reach_it_with_their_path_and_hashes` (two real daemons at level 5: the fact in `wait`
  without the name, the record in `inbox` with the path whose bytes match and a SHA-256 the test computes, the taint,
  given once; `files list` and `files pending`; the offer in the agent's history; a file addressed to `builder`
  reaches it and not `other`; the sending agent told accepted and saved with its SHA-256; MCP `list_files`);
  `tests/agents.rs` (MCP tool list with `list_files`); unit tests `output::tests` (a quote into a pipe keeps lines
  whole and uncut), `file_notices::tests` (bounded, a repeat replaces). Negative controls seen failing: the character
  budget off (three messages in the first reply), no notice made on accept (the agent's `wait` ended with nothing), the
  offer rule left out of the notice (`other` was told of `builder`'s file).

### D-UI-39 · Start an agent sets up its folder; approval requests are notified on the owner's other computers and before they expire (2026-10-06)
- **Question.** The same field feedback (D-124): the window's side of setting up an agent's folder at creation; and
  approval requests that ran out unnoticed, above all on a server without a window (item 8).
- **Decision** (DESIGN "Setting up an agent's folder, and approvals that do not expire unnoticed").
  1. **Set up this folder** in **Start an agent**, for Claude Code and Codex: instructions, git identity, Claude Code
     rules, the exact plan under **What will be written**, done on Start before the token is issued; the same plan,
     templates and rules as `antenna agent setup` (D-124). Defaults only in the agent's own folder (the instructions
     while `AGENTS.md` is missing, Antenna's tools); a project folder the owner chose gets nothing unless ticked. A
     refusal (settings that are not strict JSON) or a failing git starts nothing. The dialog's subtitle says the owner's
     own settings stay and the folder changes only as the section shows.
  2. **Approvals.** While the window is not in focus, a new request on this computer or in an own device's status
     (D-114 already sends it within seconds) is a system notification, and once per request, about two minutes before
     it runs out, a reminder; every body says the time left. Facts only, never the request text (SPEC §11). The
     terminal's `antenna devices` shows each request's time left too.
- **Why.** The owner decides once, seeing exactly what is written; and a request the owner never saw is a request
  that expires, whatever computer it waits on.
- **Checked.** `test/host/agent_setup_test.dart` (8), `test/widget/start_agent_setup_test.dart` (7),
  `test/widget/approval_alerts_test.dart` (5), `approvals_test.dart`; `flutter test --exclude-tags live` 961 passed.
  Negative controls seen failing: the merge started from `{}` (the owner's keys lost), the plan writing over existing
  instruction files, the reminder's "once" guard bypassed, a device request's quote put into the alert, a project
  folder ticked by default. Frame `35_start_agent`.

## Approver agents (2026-10-06)

### D-127 · An agent the owner names answers other agents' approval requests, only inside the level-5 circle (maintainer decision, 2026-10-06; experimental)
- **Question.** PG-57 of the plan (the product plan). May an AI agent approve another AI agent's
  approval requests, instead of the person typing the password every time? Maintainer decision: yes, if it is level
  5, the owner's own computers (D-99).
- **Decision** (CONTROL §31, PROTOCOL §24).
  1. **The owner names an approver**: an agent of this computer, or an agent of an own computer (a contact at level 5)
     by the name and the key it announced on that link (PROTOCOL §21; it becomes known with its first message there).
     The scope: whose requests (this computer's agents by name, or all of them) and which kinds: an agent's message (a
     stream's final message too), a file it sends (by path or by content), a file it requests from a contact, a file it
     accepts. `approver_set` takes the password or an owner proof (Touch ID): it widens who decides.
     `approver_narrow` (a scope within the one it has) and `approver_remove` need only an owner session: making things
     safer never needs the password (D-84). A link's wake agent, a team's worker and a local-model agent cannot be
     approvers (`denied`), and an approver is never in its own scope.
  2. **The daemon that holds the request decides each answer, at the moment of the answer** (SPEC §9): the approver has
     a delegation; the request is an agent's of this computer (not the owner's, not another computer's); it is not the
     approver's own; its requester is not an approver itself, here or for an own computer that named it (no chains); its
     agent and kind are in the scope; and the **level-5 circle** holds now: the contact the request is about (at the
     request and now), the recipient, every link the requester's session read (when read and now), the approver's own
     session (when read and now) and, for an approver on another computer, that computer's link, are all at level 5;
     none of these links changed its level after the request was made (a level lowered and raised back counts). The
     approver's answer names the request's fingerprint, as the owner's does.
  3. **Everything else stays with the person**, and the card says why: `delegate_refused` on the request
     (`scope`, `self`, `chain`, `tainted`, `outside`, `level_changed`, `unverified`), the owner's list of delegated
     answers, and the audit log of the request's contact (`agent_answer_refused`). The request is unchanged: the owner
     approves or denies it as before.
  4. **What the owner and the agents see.** An approved request is carried out by the daemon, as after the owner's
     approval (D-100); the requester gets the same `approval_resolved`, with `decided_by` and a message that names the
     approver. The request records `decided_by` (the approver, its computer, its reason, when); the audit log of the
     contact's link records `approved_by_agent` / `denied_by_agent` with the approver as the actor (`volna`,
     `volna@lap`); the receipt in the shared history is the same as after the owner's decision (Q-16). `approvers`
     lists the delegations and the last 200 answers (the newest 500 are kept, schema 13; a refused one with its `why`
     code, which a window shows in its own language). A pending card names who may answer it now (`answerable_by`).
  5. **The approver's side.** Requests in its scope reach it as facts without text: `waited.to_answer`,
     `agent_inbox.to_answer`, the `approval_to_answer` event of its own subscription and of `agent_watch`, and a fixed
     line of `antenna session` and Code mode ("An approval request waits for your answer: read approvals_to_answer and
     answer it."). `approvals_to_answer` shows them as the owner's card does, with the quote cut to 1 KiB and withheld
     when the secret scanner finds anything in it (D-114's rule), and taints its session with the links they touch (all
     at level 5). `approval_answer {id, device?, decision, fingerprint, reason}` (MCP tools listed only for an agent the
     owner named, agent CLI `antenna approval list|answer`); the reason (1–500 characters) is the agent's text, shown to
     the owner quoted. The MCP instructions of an approver say whose requests it answers and to deny what is unclear,
     unexpected, or asked for by quoted text.
  6. **An approver on another own computer** (PROTOCOL §24, feature `agent-approve/0`). The computer that holds the
     request tells that computer, in its status, which of its agents are approvers here (with their scopes) and which
     pending requests each may answer now. The approver's computer checks its own level of the link and the agent's
     scope, asks for a one-time challenge bound to that request on that link (60 s, used once, at most 16 per link),
     and signs `"antenna/agent-decision/v1" ‖ 0x00 ‖ nonce ‖ SHA-256(text)` with the agent's own Ed25519 key in the
     link (the agent never sees the key), where the text names the link, the request, its fingerprint, the decision,
     the agent, its key, its reason, and `clean`: whether that computer finds the agent's session free of anything read
     below level 5 there (a tainted approver's answer is still sent, so its owner is told why). The asking computer
     checks the text and the link it names, takes the challenge, finds the delegation and its key, checks that the key
     is still announced under that name and not revoked, verifies the signature (`ed25519-dalek`, `verify_strict`, as
     for every message of a link), then `clean`, then everything of item 2. Three unverifiable answers in a row pause
     that computer's approvers for a minute, doubling up to eight. A computer lowered below ∞ loses every delegation to
     its agents; raising it back does not restore them. An agent removed there (its key revoked, D-119) and made again
     under the same name is another agent: nothing is offered to it until the owner names it again (`stale` in the
     list).
  7. **Owner commands stay the owner's** (SPEC §9): `approve`, `approve_many`, `deny` and the four approver commands
     are absent from the agent role, the agent CLI and MCP (the three "no owner API" checks list them); an agent's
     answer is a separate command that the daemon accepts only under a delegation and only inside the circle.
- **What is new, and why nothing existing fits** (D-94). Reused: approvals and their binding to one request (SPEC
  §9), the daemon carrying out an approved request (D-100), taint (SPEC §9), agent sub-identity keys, their
  announcements and revocations (PROTOCOL §21, D-75, D-119), the own-device link request with its level checks and
  the challenge pattern (PROTOCOL §24, D-114), the audit log and the shared-history receipts (Q-16). New and
  experimental: the delegation and its scope, the circle evaluated at the moment of the answer, the per-request
  challenge pool, the agent decision text and its signature context, the status fields. Not reused on purpose: the
  owner proof of D-102/D-106, which stands for the person: an agent must never produce it, so an agent's answer uses
  another key (the agent's Ed25519 key in the link), another label, another message and another challenge pool, and
  neither verifies as the other. A "blanket approval" for a time (rejected in D-92) is still not built: each answer
  is to one request, with its fingerprint, by a named agent, inside level 5 only. Nothing cryptographic is built: the
  signature is `ed25519-dalek` over a domain-separated message, as for every message of a link.
- **Threats, and what answers them.**
  - *A contact's injected text makes the approver approve:* an approver whose session read anything of a contact below
    5 does not count (`tainted`; for a remote approver its computer says so in the signed answer), and a request that
    carries such data does not either (`outside`, the requester's read links). Within the circle the data is the
    owner's own computers' (D-99). The MCP instructions mark quoted text as data and say to deny a request that asks
    to be approved.
  - *A level lowered after the request, or between delegation and answer:* every link is checked at the answer, and
    any level change after the request was made sends it to the person (`level_changed`).
  - *A replayed answer:* the challenge is bound to the request and the link and taken by the first answer that names
    it; the signed text names the link, the request and its fingerprint; a decided request is no longer pending.
  - *An approver approving itself:* its own requests (`self`) and every approver's requests (`chain`) go to the person.
  - *A forged answer from an agent that is not the approver:* locally the daemon knows the agent by its token and
    process (D-28) and checks its delegation; remotely only the agent's key named by the owner verifies, and a key
    revoked or replaced there is refused.
  - *An older node:* nothing new goes to a node without `agent-approve/0` (a status without the new fields is byte for
    byte the old encoding; the new `device` messages are sent only to a node that announced the feature), and its
    agents cannot be named (`bad_request`).
  - *Residual:* an own computer is trusted at level 5 anyway (D-99), so its word that its agent is clean is taken; a
    model can be wrong within the circle: the scope, the log, the reasons on the cards and Revoke are the owner's
    answer; an approver can deny the owner's agents' requests (it only takes away; the owner can approve again).
- **SPEC.** An amendment of §9 ("An agent cannot grant permissions to itself or anyone else") and §18 ("An agent
  cannot … approve") by the maintainer, listed under "SPEC amendments by the maintainer" above.
- **Checked (Linux, debug).** `crates/antenna-cli/tests/approvers.rs` with real daemons:
  `an_approver_on_this_computer_answers_inside_the_circle_only` (four nodes: nothing offered before naming; naming
  needs the warning and the password, an agent cannot name one (CLI and raw request); the card's `answerable_by`, the
  agent's `session.approves`; a new request as a fact without text, the list with the quote, the approver's taint at
  5 only; approved: sent once, `approval_resolved` naming volna, `decided_by`, the audit log with volna as the actor,
  the list of answers; a second answer `not_found`; another fingerprint, approve and deny, `approval_mismatch`; a
  denial reaching the requester; refused with the reason on the card: another agent and another kind (`scope`), its
  own request (`self`), another approver's request (`chain`), a request that carries a level-3 contact's data
  (`outside`), a level changed after the request (`level_changed`), an approver that read a level-3 contact
  (`tainted`, then the owner approves it), an agent that is not an approver; narrowing without the password, widening
  through narrow `password_required`; removing without the password) and
  `an_approver_on_another_own_computer_answers_with_its_key` (four nodes: an unknown agent `not_found`; the remote
  approver sees the request from mini and hears of it in `wait`; its MCP server lists the two tools and the
  instructions name whose requests it answers; it approves through MCP, mini carries the request out and the
  requester hears `decided_by` volna on lap; both audit logs; a second answer changes nothing; tainted on lap: refused
  at mini with the reason on the card; removed and made again on lap: `stale`, nothing offered, refused; lap lowered
  to 4 and raised back: the delegation gone). Unit tests: `antenna_core::delegation::rules` (each scope and circle
  refusal), `delegation::remote` (an answer verifies once; a replay, a challenge for another request, a forged
  signature, another key, a text changed after signing, another link, an owner proof's message, a key not named, a
  revoked key), `delegation` (the challenge pool), `antenna_proto` (wire shapes, the old encoding without the new
  fields, the strict decision text, the agent label distinct from the owner proof's), the session waker's line, the
  MCP instructions; the "no owner API" checks (CLI, protocol, MCP) list the new commands. Also in the first live test:
  a request of an agent that read a link while it was at 4, made after that link is at ∞ again (`outside`: the
  request's contact alone does not catch it). `an_older_own_computer_gets_nothing_new` (`#[ignore]`, with the
  `0.1.0-preview.7` release binaries): its agent cannot be named (`bad_request`), nothing new goes to it, messages flow
  both ways and the history verifies. **Negative controls**, each run once and seen failing, then reverted: the
  scope's agent check off; the `self` check off (still refused, by the chain rule: the test fails on the reason); the
  `chain` check off; the approver's own reads not checked; the asking agent's reads not checked; `set_trust` not
  noting the change; the fingerprint not compared on a denial; a remote answer's `clean` ignored; a revoked key still
  offered (the answer then reached the asking computer and was refused only by its key check); delegations kept when
  the computer went below ∞; in the unit test, the challenge not taken (the replay passed) and the signature not
  verified (the forged sender passed).

### D-UI-40 · Approver agents in the window: named with a red warning, decided on the card, reviewed in one list (2026-10-06, experimental)
- **Question.** The window's side of D-127: how does a person name an agent that answers their other agents' approval
  requests, see what it decided and why an answer did not count, and take it back?
- **Decision** (DESIGN "Approver agents").
  1. **Where.** Agents → an agent's card: **Can approve for…** next to "Takes tasks from…" and "Questions go to…",
     shown only once the daemon answered `approvers`; an own computer's agent (a contact at ∞) has the same action
     under *Contacts' agents* and on its chip in My devices. The card reads "Can approve for: <agents> · <kinds>",
     and from `session.approves` "Answers approval requests of <computer>, set there".
  2. **The dialog** "Can <agent> approve for you?" (Experimental): No / Yes, whose requests (all my agents or chosen
     ones; the approver itself is never listed), which kinds (all four send `null`, covering kinds added later), and a
     line above Save saying whether Save asks for the password. The change rule is the daemon's `within`: naming,
     widening or naming a stale approver again is `approver_set`; a narrower scope `approver_narrow`; No
     `approver_remove`.
  3. **Naming or widening** shows a red warning first, in the ∞ colour language of D-UI-20 and D-UI-30, then one
     touch (Touch ID over the exact request) or the password with the CLI line under the field; the warning is
     accepted once per dialog. Narrowing and Off show no warning and take no password (D-84). A stale approver on
     another computer reads "Its key was revoked on <computer>…" with **Name it again**.
  4. **Pending cards** say who may answer (`answerable_by`), and an answer that did not count says so in an amber box,
     one line per reason, "The request waits for you".
  5. **Decided by an approver**: one card per request (in memory, at most 50, until Dismiss, cleared on lock), in the
     conversation the request is about and under **Answered by your approvers**: "Approved by volna" or "Denied by
     volna on Mac mini", what was asked, the reason quoted in its own box as the agent's words, the finishing state
     while the daemon carries it out, **Change** and **Dismiss**.
  6. **Agents → Approvers**: each approver with its scope, a stale note, **Change…** and **Revoke** (no password);
     the latest answers (a refused answer's reason from its `why` code, in the window's language); **All answers
     (n)…** up to 200. Read again when Agents or the dialog opens, after an `approval` event with `decided_by` or
     `delegate_refused`, and on the `agent` event's `approver` change and the `device` event's `approvers` change.
  7. **My devices**: a request with `approvers` says which of this computer's agents may answer it; the Approvals part
     says which of them that computer accepts answers from.
  8. **Code mode** types "An approval request waits for your answer: read approvals_to_answer and answer it.", the
     words of `antenna session`, once per request, after the wake line and "Your question was answered…".
  9. **Older daemons**: the `approvers` probe answered unknown: no action, no section, cards unchanged.
- **Why.** The person stays in the loop at the three moments that matter: naming (warned and authenticated), deciding
  (who decided and why, on the card itself) and reviewing (one list with Revoke). Widening authenticates; narrowing
  never does. The approver's reason is data, always quoted.
- **Checked.** `test/widget/approvers_test.dart` (13: naming with the warning, then the password, and the exact scope;
  a wrong password; narrowing without the password, widening back asking again; Off; Touch ID; an own computer's agent
  from Agents and My devices, a stale one named again; pending cards with every reason; decided cards in the chat and
  the list with the finishing state, Change and Dismiss; the approvers list with Revoke and the answers; a refused
  answer in the window's words, and a change from another client read again; My devices; the "set there" line; an older
  daemon), `test/protocol/client_approvers_test.dart` (5), `code_wake_hooks_test.dart` (+2) and
  `code_restore_test.dart` (+1) for the Code mode line, the live `test/protocol/live_approvers_test.dart` (three real
  daemons: a wrong password, then volna named for builder from the window client; the card's `answerable_by`; volna
  approves with its token and a reason; the window's subscription carries `decided_by`, srv receives the message, the
  answer is in `approvers`; narrowing without a password, a wider narrow `password_required`; remove without a
  password; volna's next answer refused with `why: scope` on the card). **Negative controls**, each seen failing: the
  warning skipped; widening sent as a narrowing; narrowing sent as `approver_set`; a decided card without the
  approver's name; a Code mode line for another computer's approver of the same name; a refused answer's code ignored;
  no refresh on the `agent` event. Frames `88_approver_warning` (light, Russian), `89_approver_card` (light, dark,
  Russian), `90_approvers_list` (light, Russian); no existing frame changed.

### D-128 · A taken name is saved as `name (2).ext`; both sides are told the name (field feedback, 2026-10-06)
- **Question.** Two field reports of the same day. Files sent to the maintainer's Mac could not be saved when the name
  was taken in the link folder: the window's "Another name" came back with the same name, three times, then nothing
  (preview.7; main's reworked dialog stopped the loop, but every taken name still went through a dialog). And an agent
  re-sent `DECISIONS.md` with new content to a level-5 own computer three times over an afternoon: the recipient's
  `shared/` kept the first copy, the daemon's own accept (D-99) left each newer one in quarantine without a word, no
  numbered copy appeared, and the sender saw "sent [clean]" every time.
- **Decision** (CONTROL §14, PROTOCOL §19).
  1. **Same name, different content: the next free number,** `DECISIONS (2).md`, `(3)`, … as a browser saves a
     download; never overwritten, never dropped. It applies to every accept without a name of the owner's: the
     daemon's own accept at level 5, the window's Accept and `antenna files accept` without `--name`. A double
     extension stays whole (`report (2).tar.gz`); a dot file and a name without an extension get the number at the
     end (`.env (2)`); near 255 bytes the stem gives way at a character boundary. The name normalization and the
     special-name rules are unchanged: they apply to the contact's name, and numbering keeps its extension. With
     `--name` (or the window's rename field) a taken name is refused with `file_name_taken` as before.
  2. **The name is claimed exclusively.** The verified file stays unnamed while it is written (`O_TMPFILE`, or a
     hidden temporary name), then gets its name in one step that fails with `EEXIST` rather than replace: `linkat`, or
     `renameat2(RENAME_NOREPLACE)`, the `O_EXCL` of naming a finished file. When another accept takes the name between
     the look at the folder and the claim, this one moves on to the next number, so two accepts never get the same
     name. After `(1000)` the accept fails with `file_name_taken` and the owner chooses a name. A literal `O_EXCL`
     create would make the name visible while the content is still being decrypted and verified.
  3. **The same content is that file.** A file with the same size and BLAKE3 under the contact's name or one of its
     numbers is accepted as that file, with no copy (`duplicate: true`, preview.8), so a third send of the second
     version is `DECISIONS (2).md` again. `file_name_check` answers `same_file` for it.
  4. **"Another name" only for a name that cannot be used** (`bad_file_name`). For a taken name the window asks
     nothing and the card says "Saved as DECISIONS (2).md: another file in shared/ already has the offered name". The
     dialog stays as the fallback for a daemon before this decision, which still answers `file_name_taken`.
  5. **Both sides are told.** The recipient's `file` event, `files pending --all`, an agent's `inbox.files` and the
     card carry the saved name in `saved_as` (and `saved_path`). The sender's node learns it from the existing
     `accept_file` / `accepted` receipt, which may now carry `name_number`: the `n` of `<stem> (n).<ext>`, 2–1000. A
     number, not a name: the sender derives the name from its own manifest, so no free text from the contact enters
     a receipt and the receipt vocabularies stay closed (the recipient checks the range and that it rides only on an
     accept). It goes only to a node with the new feature `file-saved-as/0`; an older node gets the receipt as
     before. The sending agent's `inbox.files` record has `saved_as`, its CLI line says "accepted and saved it: … as
     DECISIONS (2).md (another file had its name)", the owner's sent card says "The contact accepted the file and
     saved it as …", and `antenna log` shows "saved as copy (2)". A name the owner typed is never told to the
     contact: it is the owner's own word.
  6. **A level-5 file that still cannot be saved waits with the reason.** When the daemon's own accept fails for any
     other reason (an invalid name, every number taken, the folder is not a plain directory, the disk), the quarantine
     record keeps the error code and message (`held`, a new optional field of the encrypted record), shown in
     `FileInfo.held`, on the card ("Not saved by itself: …. It waits for you here.") and on the CLI's file line; an
     accept clears it.
- **Why.** Every messenger and browser does this; refusing a taken name pushed a choice onto the person that no one
  needs to make, and at level 5 there was no person in the loop at all. The exclusive claim keeps the old guarantees
  (no overwrite, no hard-link trick, nothing visible before the check) and adds the one a loop needs. The sender
  deserves to know where its file went, and a small number is all the receipt needs to say.
- **No new mechanism.** Numbering and the exclusive claim reuse the existing accept (`O_TMPFILE`, `linkat`,
  `renameat2`); the receipt field is a bounded integer behind capability exchange; nothing cryptographic.
- **Checked.** `crates/antenna-cli/tests/duplicates.rs`:
  `at_level_5_new_content_under_a_taken_name_is_saved_under_the_next_number` (two real daemons at level 5, an agent
  sends `DECISIONS.md` three times: v1, v2, v2 again; the recipient saves `DECISIONS.md`, then `DECISIONS (2).md`,
  then accepts the third as that file, the first copy untouched, nothing waits; the sending agent's inbox says
  accepted with `saved_as: "DECISIONS (2).md"` from the receipt; the reader agent's inbox has the numbered copy with
  its path; the sender's `antenna log` has the contact's receipt with "saved as copy (2)"),
  `at_level_5_a_file_that_cannot_be_saved_waits_with_the_reason` (`shared` replaced by a file: the record waits with
  `held.code: "forbidden"`, said on the CLI line; the owner's accept after the fix saves it and clears it),
  `the_owner_accepts_a_resent_identical_file_without_a_second_copy` (level 3: `notes (2).txt` on Accept, a taken
  `--name` still refused); `antenna-files` `accept::tests` (numbered names, the length limit, the next free name,
  a name taken between the look and the claim, twelve concurrent accepts of one name, the cap at `(1000)`, a copy
  found under a number); `antenna-proto` `receipt_body_wire_shape` (`name_number` absent when 0); `linksync`
  `a_receipt_names_a_number_only_on_an_accept`; the window's `file_numbered_name_test.dart` (no dialog for a taken
  name and the "Saved as" line, the dialog for a bad name, the held reason on the card, the sent card's name from a
  receipt's number) and `file_rename_test.dart` (the fallback for a daemon before D-128). **Negative controls**, each
  seen failing: numbering off in the quarantine (the regression test times out waiting for the second version to be
  accepted); the claim made to replace (an `unlinkat` before the `linkat`: the race test loses the other accept's
  file, and the concurrent test ends with 3 files of 12); the fake daemon without numbering (the window test sees the
  dialog).
- **Not checked yet.** On a real Mac (APFS, case-insensitive: the claim's `EEXIST` there covers case duplicates
  too); against a preview.7 node in the field (the receipt goes without the number by the feature exchange, which
  the unit test of the wire shape and the gate cover, not a run).

## Screen Recording after an update (2026-10-06)

### D-UI-41 · The window checks Screen Recording before a screenshot and explains the per-build permission; a stable self-signed signature evaluated (field feedback, 2026-10-06)
- **Question.** After installing 0.1.0-preview.8, the Code mode **Screenshot** button (D-UI-27) ran `screencapture -i`
  and macOS asked again for Screen Recording, while System Settings → Privacy & Security → Screen & System Audio
  Recording already showed Antenna switched on. It happens after every update, and with other permissions too (the
  folders of the 2026-10-06 TROUBLESHOOTING entry "macOS asks Antenna for Documents, Photos, Music…").
- **Cause (verified from Apple's documentation and our signing; not yet reproduced on a Mac).**
  1. macOS records an app's designated requirement (DR) in its database of apps allowed a privacy-protected resource
     and checks every later version against it; "Ad hoc signed code … has a DR but it's tied to that specific version
     of the code", so macOS "can't reliably track the identity of the code" (Apple, TN3127 "Inside Code Signing:
     Requirements", developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements, read
     2026-10-06).
  2. The app is signed ad hoc (`packaging/macos/build-dmg.sh`: `codesign --force --sign - "$APP"`, no Team ID), so its
     DR is its cdhash, which every build changes. The switch in System Settings is the entry of the previous build;
     the new build does not satisfy its recorded requirement. Toggling that switch is reported not to help, because
     the stored record still holds the old build's requirement; removing the entry with − and adding the app again
     (or letting it ask again) does (github.com/alipovoy/ShatterBreak/issues/101, 2026-08-22;
     github.com/kaorinstar/driveshot/pull/55, 2026-09-22).
  3. `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()` exist since macOS 10.15 (Apple's
     CoreGraphics reference, read 2026-10-06; the deployment target is 12.0). The preflight caches its answer for the
     life of the process: once it said no, it keeps saying no after the owner allows it, until the app restarts
     (developer.apple.com/forums/thread/732726, 2023-06: a developer's measurement; Apple's engineer there does not
     expect a change to take effect at once for this subsystem;
     github.com/ThodsaphonSonthiphin/SPRecorder.Mac/issues/24, 2026-09-10: still so on macOS 26.6.2, while a capture
     in the running app worked without a relaunch). macOS itself offers to quit and reopen an app whose Screen
     Recording was just switched on. The pane and its + button: Apple Support "Control access to screen
     and system audio recording on Mac" (support.apple.com/guide/mac-help/mchld6aa7d23/mac, read 2026-10-06).
- **Decision.**
  1. **Check first.** Before the screenshot tool runs, the window reads the real state with
     `CGPreflightScreenCaptureAccess()`, which never prompts (`macos/Runner/ScreenAccess.swift` over the
     `antenna/screen` channel; `lib/host/screen_permission.dart` behind the `ScreenPermissionHost` interface, faked in
     tests). Linux has no such permission: the tools run as before. A Runner without the channel is "could not check"
     and the tool runs as before (never "missing").
  2. **Our sheet before anything else** when it is missing: what happened (macOS keeps the permission per build until
     Antenna is signed with a Developer ID; after an update the switch can be on and still belong to the previous
     build), the fix in four steps (open the pane; select Antenna and remove it with −; add it back with + and switch
     it on; quit and reopen Antenna when macOS offers to, since a running app gets the permission only after a
     restart), **Open Screen Recording settings**
     (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` through the window's existing
     `openUrl`; if System Settings does not open, the sheet names the pane), and
     **Try again**: check again; still missing → `CGRequestScreenCaptureAccess()` (macOS's own question at most once
     per build, and it puts Antenna back into the list); the tool runs only when that says allowed; otherwise the sheet
     comes back with "Still not allowed for this build… quit and reopen Antenna".
  3. **Settings → Check** shows the same state as a row (`screen_recording_missing`) with the same steps and the same
     button: allowed; missing (worth knowing until a screenshot met it in this session, a problem after); could not
     check. No row where the permission does not exist (Linux).
- **Why.** The system question over the screenshot tool, with the switch already on in System Settings, gives the owner
  no way to understand or fix it; the cause is the signing, and only the window can say so. The check costs one call
  that never prompts.
- **Not changed.** The release signing stays ad hoc. Developer ID is the real fix (a DR on the Team ID that every
  release satisfies, notarization, Gatekeeper trust) and waits for an Apple Developer account.
- **Proposal for the maintainer: a stable self-signed signature until the Developer ID exists** (evaluated, not built).
  The build Mac would keep a code-signing certificate of its own (a self-signed root made with Keychain Access →
  Certificate Assistant, code signing only, a long validity such as 10 years, named after the product) and
  `build-dmg.sh` would sign with `codesign --force --sign "<its name>"` (an optional `SIGN_IDENTITY`; ad hoc stays the
  default).
  - *The DR becomes* `identifier "io.github.danta-nort.antenna" and certificate root = H"<SHA-1 of the certificate>"`
    instead of the cdhash: codesign's default for a certificate not issued by Apple (seen on a self-signed helper in
    github.com/hnykda/wifi-heatmapper/pull/95, 2026-10-04).
  - *Grants across builds.* Every build signed with the same certificate satisfies that recorded DR, so by TN3127's
    mechanism a grant made once carries over; the same pull request reports a Location grant surviving two rebuilt
    versions. Not yet seen for Screen Recording or the folders: the first thing to check on a Mac. The first
    self-signed build is a new identity once more (one last round of questions), and so is each new certificate.
  - *Gatekeeper.* A self-signed certificate is not trusted: a downloaded DMG is refused as the ad-hoc one is today, and
    the first install still goes through Privacy & Security → Open Anyway (`packaging/macos/README-first-run.txt`).
    Apple Silicon only needs a valid signature to run. The app still has no Team ID, so it keeps no hardened runtime
    (library validation would refuse `Flutter.framework`; TROUBLESHOOTING "Visual version, stage 1", on signing the
    .dmg without a Developer ID); the helpers keep theirs.
  - *The updater.* `antenna update` copies the app with `ditto --noqtn` (no quarantine, no Gatekeeper assessment) and
    runs `codesign --verify --deep --strict`, which checks the signature and the code's own DR, not trust in the
    anchor, so a self-signed copy is expected to pass as the ad-hoc one does (`packaging/macos/check-update.sh` runs the
    same steps: run it on the first self-signed DMG). The update's authenticity stays with the release manifest's
    signature (D-82), not with code signing. A useful addition then: the installer requires the new copy to satisfy
    the installed app's DR (`codesign --verify -R "=<installed DR>"`), so a build that would drop every grant (another
    certificate, an ad-hoc fallback) is refused or at least announced.
  - *Risks.* (a) The private key becomes a secret of the same weight as the release key: whoever holds it can sign an
    app with Antenna's identifier that satisfies the recorded DR and inherits every grant on owners' Macs (Screen
    Recording, folders), until the certificate changes; with ad hoc no other code can satisfy a grant. It must stay in
    the build Mac's keychain, never in the repository, CI logs or a hosted runner. (b) Rotation (expiry, compromise)
    costs every owner one more round of questions. (c) A build without the certificate (the hosted-runner fallback of
    D-81, a contributor's build) silently falls back to ad hoc: the script must say which signature it made, and a
    release should refuse the fallback once self-signed is the norm. (d) On a self-hosted runner `codesign` needs the
    key without a keychain dialog (`security set-key-partition-list` for the key). (e) The certificate's name is
    public (`codesign -dvv`, `spctl` "origin="): the product's name, nothing personal. (f) Moving to the Developer ID
    later changes the DR once more.
- **Checked.** `test/widget/screen_permission_test.dart` (11: allowed → the tool runs with no sheet and macOS is not
  asked; missing → the sheet, the tool does not run, **Open Screen Recording settings** opens exactly the pane's URL,
  **Try again** asks macOS once and, still missing, shows the sheet again with the "still" line and runs nothing, Close
  is not reported as a failure; allowed after the question → the tool runs and the image is pasted; System Settings
  does not open → the sheet names the pane; Linux and a Runner without the check → the tool runs as before; the check
  row's states; Settings → Check: the row with the same steps and button, a problem after a blocked screenshot,
  allowed, no row on Linux), `test/host/screen_permission_test.dart` (3: the channel's calls and replies, only a Bool
  is an answer, a missing channel or an error is "could not check", nothing off macOS). Negative control, seen
  failing: the tool run without the check (`checkScreenPermission()` replaced by "could not check" in
  `takeScreenshot`): 5 tests failed (the sheet never came, the tool ran, the check row stayed "worth knowing").
  Frames `91_screen_permission(_ru)`.
- **To verify on a real Mac.** The Runner builds with `ScreenAccess.swift`; a fresh install: the sheet, **Try again**
  shows macOS's question once and puts Antenna into the list, switching it on offers a restart, and after it the
  screenshot captures other apps' windows; an update over a granted build: the sheet comes (the reported case), and
  − then + fixes it (and whether toggling alone does not); the preflight stays "no" until a restart; the pane URL on
  macOS 13 to 27; the Check row; and, if the proposal is taken, a Screen Recording grant surviving two builds signed
  with one self-signed certificate, `codesign --verify --deep --strict`, `spctl --assess` and `check-update.sh` on such
  a DMG.

### D-UI-42 · The first hour of preview.8 in the window: drafts and reading positions per chat, long text as a file, Copy text and Show all, the sender's own image copy, a terminal that scrolls back, time left in words (field feedback, 2026-10-06)
- **Question.** What the maintainer hit in the first hour with `0.1.0-preview.8` on a Mac: a screenshot attached in one
  chat waited in another chat's composer, where Enter would have sent it to the wrong recipient, and the hint named
  only the contact; a chat left at its end opened in the middle when he came back; a pasted crash log over 64 KB said
  only "not sent: bad_request"; selecting a long message from its top lost the start once the list scrolled; his own
  screenshot's bubble said "Couldn't show the preview image"; the dock's terminal could not be scrolled back; "08:35"
  on a request from another computer read as the time of day.
- **Decision.**
  1. **Drafts per chat** (`state/drafts.dart`): a chat (a contact's person, or one of its agents) keeps its text, its
     files waiting for Send and its To and topic choices; another chat's composer is empty and its Send cannot send
     them; a Send under way keeps the chat and address it started with; the chat list says "Draft: …"; the hint under
     the files names the recipient (the contact and the agent, everyone, or the person). In memory only, gone with a
     lock.
  2. **The reading position per chat**: each chat has its own list. Left at the end: back at the end. Left elsewhere:
     the same message at the same height. Messages that came meanwhile: the view stays on the last message read, a
     **New messages** line above the first new one and the jump button with their count. The person's own message
     always shows the end.
  3. **Text over one message** (64 KiB of UTF-8, `link::MAX_TEXT`): the composer counts bytes near the limit, says
     over it that the text goes as a text file and turns Send into **Send as a file** (also right after a paste); the
     window writes a `.txt` named after the first line into its staging folder and shares it in the same chat, with
     the chat's address. The daemon refuses such a text with its own code `text_too_long` (CONTROL §10; an empty text
     stays `bad_request`; an older daemon's `bad_request` for a text over the limit is read the same way); a bubble
     refused so offers **Send as a file** and is replaced by the file. Any other refusal shows its explanation with
     the daemon's own text.
  4. **Reading a message**: **Copy text** (the whole message) in its right-click menu and beside the bubble on hover,
     with a short note; a message taller than 60% of the chat is cut with **Show all**, a reader with one scrollable,
     selectable text and **Copy all**. A bubble's text is a `SelectionArea` instead of a `SelectableText`: Flutter
     corrects a drag's start for a scroll of the list as if the list grew downwards, and the chat's list is reversed,
     so the start slid towards the pointer by twice the scroll; a `SelectionArea` keeps the start as a position in the
     text.
  5. **The sender's own image** (`host/sent_previews.dart`): the window keeps its own copy of an image it sent, made
     from the bytes it sent (decoded by the engine, at most 1600 px, encoded as PNG: pixels only), in its 0700 folder
     per link and file ID; the bubble and the viewer show only that copy, never the original path. Removed with the
     link's history, after 30 days, and oldest first over 256 MiB. A sent image without a copy (an agent sent it)
     reads like any other file.
  6. **The dock's terminal scrolls back**: the main screen's scrollback is bounded (10,000 lines) and scrolls with the
     trackpad, the wheel and the scrollbar; new output keeps the view where the person reads; **Jump to the latest
     output** shows while they read back. Claude Code (2.1.291, recorded in a pseudo-terminal) runs in the alternate
     screen with mouse reports on, so it scrolls its own transcript on the wheel; the terminal now reports the wheel
     with the protocol's codes (64, 65) in every report mode, where xterm 4.0.0 sent 68 and 69 (Shift + wheel), which
     Claude Code ignored.
  7. **Time left in words** on every approval card, here and from another computer: "Expires in 8 min", seconds under
     a minute, then "Expired"; never a bare `08:35`.
- **What is new and why nothing existing fits** (D-94). Nothing cryptographic and no new dependency. The terminal's
  wheel goes through the package's own `mouseHandler` hook instead of a fork; it is to be dropped when the package
  reports the wheel right (STACK "Code mode").
- **Why.** Messenger behaviour the owner should not have to think about: a draft stays where it was written and names
  who gets it, a chat opens where it was left, a long text is never lost to a code, the person's own picture is always
  there, and a terminal scrolls back like any terminal.
- **Checked (Linux).** `test/widget/drafts_test.dart` (2), `reading_position_test.dart` (5), `long_text_test.dart`
  (4), `message_text_test.dart` (3), `test/host/sent_previews_test.dart` (6), `image_thumbnail_test.dart` (3 new),
  `agent_terminal_test.dart` (4), `expires_wording_test.dart` (3); the live `test/protocol/live_sending_test.dart`
  against real daemons (`text_too_long` with the sizes, the file received whole, the preview copy after the original
  was deleted); `antenna_core::node::text_limit` (unit). Negative controls, each seen failing: drafts keyed per contact
  (the file showed in the other chat), one list per contact (the person chat opened at the agent chat's 558 px), no
  restore, no jump on the person's own message; the long text sent as a message, the older daemon's `bad_request`
  not read as too long; a `SelectableText` bubble (the selection started at line 13 instead of line 1), no cut, no
  hover button; no preview copy kept, the original bytes kept instead of the rebuilt ones; the package's wheel codes,
  following the output always; a bare countdown on the device card.
- **Not checked yet.** On a real Mac: Claude Code scrolling its transcript in the dock with a trackpad; a dragged
  screenshot's bubble; the hover button and the right-click menu with a trackpad.

### D-UI-43 · A stable order for a contact's agent chats, Pin, and a local picture for one (field feedback, 2026-10-06)
- **Question.** The maintainer: "if you write to me, you are on top; if the other agent writes to me about Volna, it
  is on top; you keep swapping places. That is inconvenient, I mix up who is who. If I could also set pictures for
  you, your Antenna logo for you and the Volna logo for Volna, you could be recognized. But it is still better that
  you don't jump around and stay in one place." `agentChatsOf` (D-UI-32) sorted a contact's agent chats by the latest
  message, so a busy agent kept jumping to the top of the list.
- **Prior art.** Telegram, WhatsApp and iMessage order the list by the latest message and let the person pin chats on
  top; Telegram lets pins be dragged into order. Slack keeps a sidebar section's channels in a list the person
  orders (alphabetical, by activity, or by hand) and notifies per channel. iMessage and Contacts show a photo the
  person set on their own device over the one the contact chose. We keep the recency order for the contacts (all three
  do), but a contact's agents are a handful of parallel work sessions the person tells apart by position, which is
  Slack's channel list more than a stream of conversations: a stable order they can drag, Pin on top, and a picture
  set locally. The difference from the messengers is the point of this decision, stated by the maintainer.
- **Decision.** All of this is this window's own address book on top of what a contact's agent announces, kept on
  this computer only, in a new `chat_prefs.json` next to the window's settings file (`lib/state/chat_prefs.dart`,
  `appearance.dart`'s pattern). Not in the daemon's `chats` table (D-113): that table holds the owner's *name*,
  *notifications* and *archive* of a chat, which the daemon already computes and serves per chat; an order, a pin and
  a picture override are a display choice of this window with nothing for the daemon to compute.
  1. **A stable order.** `agentChatsOf` keeps the order a contact's agent chats were first seen in (a window with no
     saved order starts from the order the daemon listed them in, its "most recent first", so a first view does not
     change; a new chat is appended once, at its first sight). Activity shows as the unread badge and the time, not
     by moving. A contact's own row keeps the activity order, as in every messenger.
  2. **Drag to reorder.** The unpinned chats of one contact are one `ReorderableListView` (`_AgentChatBlock`),
     press-and-hold to drag (a tap still opens the chat); `AppModel.reorderChats` saves it. Only over the unfiltered
     list: dragging a searched or filtered view would drop what the filter hides from the saved order.
  3. **Pin** on the chat menu: pinned chats stay on top, the most recently pinned first.
  4. **A local picture for a contact's agent**: "Set picture…" on its chat menu and on its row in the contact card
     (`ChatPicturePicker`), a drawn id or a photo through the window's own decode, crop and re-encode (`photo_crop.dart`,
     the one the owner's own picture uses, D-UI-35; nothing new touches image bytes). The 512 × 512 PNG the window
     drew stays in a folder next to `chat_prefs.json`; nothing is sent. `agentProfilePicture` checks the override before
     the picture the agent's owner announced, so the chat list, header, bubbles, the map, the new-chat dialog and (now
     through `AgentAvatar`) the contact card all show it. "Reset to theirs" deletes it.
  5. **A photo that is not shown says why**: the contact card's agent row shows one line for the daemon's reason
     (`withheld`: level, refused, unavailable) instead of a bare monogram (`PicturesMixin.pictureWithheldOf`).
- **Why.** The maintainer's words above. A person tells parallel sessions apart by where they stand and what they
  look like.
- **Checked.** `test/widget/chats_test.dart`: a lower chat getting a new message does not move it (reverting
  `agentChatsOf` to `chatActivityMs` fails it); drag order saved to a real `ChatPrefsStore` and read by a second
  `AppModel` (a store-less one falls back to the daemon's order); Pin and Unpin. `pictures_test.dart`: the card says
  why a photo is withheld, and says nothing for a picture that shows. Frames `67_agent_chats`, `68_chat_menu`,
  `30_contact_agents` updated.
- **Not checked yet.** The press-and-hold drag with a real pointer (the test drives `reorderChats`, the gesture is
  Flutter's own `ReorderableDelayedDragStartListener`); on a real Mac.

### D-UI-44 · "With me", "Between agents" and "All" in an agent's chat; agent-to-agent traffic quiet by default (field feedback, 2026-10-06)
- **Question.** The maintainer, about an agent chat where his own agent and the contact's agent coordinate:
  "Notifications come for everything, even when it is not for me: you are just writing with code. The chips at the
  top (All, # pictures check, claude-code) split it into discussion topics, but few people need that. The filters
  that matter are: the messages for me, my conversation with you; your conversation with other AIs; all messages. A
  person does not care what the AIs discuss among themselves: they set the work and care about what is needed from
  them. So by default show the person ↔ agent conversation."
- **Prior art.** Slack keeps a channel's thread replies out of the main view and notifies about a thread only when
  you take part in it or are mentioned; its preferences are per channel (everything, mentions, nothing). Telegram
  mutes per chat and badges muted chats quietly (a grey count). iMessage notifies per conversation and can hide
  alerts for one. We follow the same line: what is addressed to the person notifies by default, the rest is a
  per-chat opt-in, and the quiet kind of unread is a quiet mark. The difference is the grouping, not the principle:
  the split is by the signed addressing (D-90), who on this side took part, never by reading the text.
- **Decision** (window only: `to`/`to_agent` of every message already carry what this reads, PROTOCOL §23).
  1. **Three fixed chips in an agent's chat** (`thread_bar.dart`): **With me** (the default; this side is the owner
     in person, `myAgentOf(e) == null`), **Between agents** (one of the owner's own agents took part), **All**. Topics
     move into a **Topics** menu, still available; the per-my-agent chips are replaced by "Between agents". The
     person chat keeps its own bar, shown only when there is something to filter by.
  2. **The filter is remembered per chat** (`ConversationMixin._threadFilter` per link and chat); switching chats and
     back no longer resets it.
  3. **Notifications.** `chatNotifies`: a message between agents (the owner's own agent is the addressee) notifies
     only when the chat opted in, **Notify about messages between agents** on its menu (off by default, kept in
     `chat_prefs.json`); the rule is applied before all/asks/off. `asks` now means "addressed to the person or to
     everyone" (before, only "to the person": a broadcast was silently left out). Approvals, an agent's questions
     (D-118) and failures notify by their own paths, unchanged.
  4. **The unread badge** counts what is for the person; the rest is a quiet dot (`QuietUnreadDot`), never a number
     (`chatUnreadForPerson` / `chatUnreadBetweenAgents`). Known limit, stated rather than hidden: for a chat the
     window has not loaded, a message cannot be classified, so it counts toward "for the person": the badge may be
     one too high, never hide a message that might be for the owner.
- **Why.** The maintainer's words above; the over-count bias is "could not verify = refuse" (CONTRIBUTING.md principle 4)
  applied to a notice.
- **Checked.** `threads_test.dart`: the default "With me" shows exactly the person's messages, "Between agents" the
  agent-to-agent ones, "All" everything, the Topics menu works, each chat keeps its filter, the person chat has no
  bar (negative control: the default hides agent-to-agent text); `chats_test.dart`: an agent-to-agent unread is a dot,
  not "1" (negative control: a broadcast still counts). Existing tests that read a whole agent thread now tap **All**
  and say why. Frames `40_threads`, `79_chat_pictures`, `67_agent_chats`, `68_chat_menu`.
  `chats_test.dart` also drives the notification rule through the real system-notification path: an agent-to-agent
  message is silent by default (negative control: without the gate it notifies), notifies after the chat's menu item,
  never when the chat is Off, silent again after opting out, and a broadcast to everyone notifies on "Only when it
  asks for me". The test found a slip of the first version: the opt-in was still stopped by "asks".
- **Not checked yet.** On a real Mac; the live run against two real daemons (`live_chats_test.dart`).

## Files: what holds a received file (2026-10-06)

### D-129 · An image's own metadata (XMP, content credentials, EXIF) is not read as HTML (field feedback, 2026-10-06)
- **Question.** An app icon made by an image generator (`AppIcon-transparent.png`), sent between the maintainer's own
  computers, was held as a threat on both sides: `polyglot_html: binary image/png file contains HTML/script markup in
  its first 1 KiB`. Such PNGs carry an XMP packet in an `iTXt` chunk and content credentials (C2PA, a JUMBF box in a
  `caBX` chunk, about 23 KB here) before the pixels; the polyglot check (D-F-9) searched the first KiB of the raw bytes
  for `<script`, `<html`, `<iframe`, `<svg`, `<body` and `javascript:` and found them in that metadata. The sender's
  window then said "The contact declined the file".
- **Decision.** The HTML part of the polyglot check reads an image's first KiB without the format's own metadata,
  found by walking the container by its own lengths (no decoding, `detect::image_metadata`):
  1. PNG: the data of `caBX` (C2PA), `eXIf`, `iCCP`, and of `iTXt`/`tEXt`/`zTXt` under the keyword
     `XML:com.adobe.xmp` (XMP), up to the first `IDAT`;
  2. JPEG: application segments with a metadata identifier: APP0 `JFIF`/`JFXX`, APP1 `Exif` and XMP (standard and
     extended), APP2 `ICC_PROFILE` and `MPF`, APP11 `JP` (JUMBF, C2PA), APP13 `Photoshop 3.0`, APP14 `Adobe`, up to
     the start of scan;
  3. WebP: the `XMP `, `EXIF`, `ICCP` and `C2PA` chunks.
  Still read, and still a threat with markup in the first KiB: a text chunk under any other keyword, a JPEG comment,
  an application segment without a known identifier, an unknown chunk, anything after the image's end, and a chunk
  whose length runs past the end of a file held whole (a broken file hides nothing; for a file larger than the
  worker holds, the last chunk read is taken to the end of the window). The PDF header check still reads the raw
  bytes: a PDF reader looks for `%PDF-` in the first 1024 bytes whatever the image format says.
- **Why.** XMP is XML and content credentials carry text by design, so every generated image would be a "threat",
  and the person cannot send an ordinary picture. A browser does not take a file that begins with an image signature
  for HTML (the MIME Sniffing standard matches image patterns first), and what the owner and agents see is the preview
  rebuilt from pixels, without any metadata (D-F-7). The check that remains is the one the heuristic was for: markup a
  sniffer could reach outside the image's own structures.
- **No new mechanism.** A length-checked walk over the container's own chunk and segment headers, no parser of the
  metadata itself; the verdict rules are unchanged.
- **Checked.** `detect::tests::image_metadata_is_not_read_as_html` (a generated PNG with XMP `iTXt` and a `caBX` box,
  both carrying markup on purpose: no finding; a `tEXt` "Comment" chunk that is HTML, an unknown chunk with markup,
  HTML right after `IEND`, and `caBX` chunks claiming more than the file holds: `polyglot_html` as before; the start of
  a larger file), `detect::tests::jpeg_and_webp_metadata_is_not_read_as_html` (APP0, APP1 XMP and APP11 JUMBF with
  markup: clean; a comment segment and an APP1 without an identifier: threat; WebP `XMP ` and `EXIF`: clean, another
  chunk: threat), `worker::tests::a_generated_png_with_xmp_and_content_credentials_is_clean` (the whole check: clean,
  a 1×1 preview rebuilt from the pixels; with an HTML text chunk: threat). `cargo test -p antenna-files`: 63 unit, 14
  corpus, 4 picture, 11 pipeline, 10 review, 12 sandbox, 5 transfer (1 ignored), all green. **Negative controls**, each
  seen failing: the metadata left in (the three tests above fail: the field report reproduced), images skipped
  altogether (the true polyglots of those tests and `detect::tests::polyglots` fail).
- **Not checked yet.** The maintainer's own file (only its description reached us); GIF's XMP application extension
  is not left out (no report of it).

### D-130 · From trust level 3 the check labels; programs, installers and signatures wait for the owner's keep-anyway; every sender learns its file's fate (SPEC amendment by the maintainer, 2026-10-06)
- **Question.** Field report (2026-10-06, the server node to the maintainer's Mac, both at ∞): a coding agent sent
  `panel-prototypes-2026-10-06.zip`, three HTML prototypes with inline JavaScript, and saw "sent [threat]"; the same
  pages as `.txt` showed "sent [suspicious]". What matched, reproduced with the worker's `analyze` on the same kind of
  files (`worker::tests::the_field_report_files_are_code_and_markup`): the ZIP was written **stored** (Python's
  `zipfile` default), so the first page's markup lay in the archive's first KiB and `polyglot_html` (threat) fired;
  the same ZIP deflated is clean; the `.txt` copies are HTML by content with `active_content` (suspicious). No secret
  pattern, unknown type or YARA rule matched. The same day a generated PNG was held as `polyglot_html` (D-129), and the
  sender's window read "The contact declined the file" for a file that was in fact held. The maintainer: "The security
  settings must be lowered, because ordinary files are already blocked from transfer. This is the basis of any
  messenger: nobody blocks file transfer, especially pictures." And: "Even for dangerous files: show that the file is
  dangerous, the way a browser does … I can press 'I understand, keep it anyway'."
- **Decision** (`antenna_files::kinds`, `antenna-core/src/file_fate.rs`, CONTROL §14, PROTOCOL §18–§19).
  1. **Heuristics are labels from level 3.** At levels 3–5 the check's heuristic findings (markup or a script in a
     file, an HTML polyglot, secret patterns on receive, unknown types, a structure the preview cannot read, PDF and
     Office active content) never hold a file. They are `FileInfo.labels`, and the file is accepted the normal way for
     its level: the daemon saves it at level 5 (D-99); at 3–4 an agent or the owner accepts it as a clean file. The
     `verdict` field stays the check's own; who may accept follows `kinds::effective_verdict`.
  2. **Held for the owner at every level from 3:** native executables (ELF, PE, Mach-O); installers, packages and disk
     images (UDIF, xar `.pkg`, RPM, squashfs, cabinets, `.deb`, `.msi`, zip-based app packages, an Android package,
     unrecognized content named as a disk image or installer, a disk image trailer behind another format); archives
     holding those; signatures (the antivirus hook, EICAR, the owner's own YARA rules in their namespace); a check that
     could not finish or that the antivirus did not answer; at levels 3–4 also archives not opened whole (encrypted,
     nested, a format the check does not open, too large) or with a dangerous structure (a bomb, paths out of the
     folder, links, devices). A held file reads like a browser's dangerous download: the danger in plain words,
     **Delete** (`file_reject`) and **Keep anyway** (`file_accept` with `force` and the password or an owner proof);
     agents never keep one. Exception: a disk image or archive that a release manifest signed by a key this daemon pins
     lists by name, size and SHA-256 is the signed update flow (D-103) and is saved at level 5, also when the manifest
     arrives after it.
  3. **Levels 1–2 are unchanged:** the verdict decides, no labels, a threat refused to the sender at once.
  4. **What the content is** (`ContentClass`: `code`, `text`, `executable`, `installer`, `other`) is decided in the
     check worker from the bytes: the head of the file and of every ZIP, tar and gzip member, read in the worker's
     memory (8 KiB each, nothing unpacked to disk); a name only adds "installer" for unrecognized content or "code" for
     text. Code and markup carries the label "Code: Antenna does not run it". The daemon checks the top-level magic
     numbers itself (`kinds::guard_class`): a worker that called a program text is overruled with a `class_mismatch`
     signature.
  5. **The sender's own check only labels from level 3:** `sender_check:*` is no longer a reason for approval there;
     the sent `FileInfo` carries its findings as `labels`, and the CLI says "sent, waiting for the contact's check"
     instead of "sent [threat]". Secrets in an outgoing file still need approval below level 5 (SPEC §9).
  6. **Every sender learns the file's fate** (`file-fate/0`, experimental): `check_file` / `held` with `why`
     (`threat`, `executable`, `installer`, `uninspected`, `check_failed`, `review`, `not_saved`) and `rules` when a file
     waits for the recipient's owner (levels 3–5), `why` (`threat`, `damaged`, `limit`) on `reject_file` / `denied`.
     Rules are finding codes, at most 16, the recipient's own rules by kind only (`yara:extra`, `av`). A held file
     stays served until the final answer. The sending agent's `inbox.files` record and the sent card read `accepted`,
     `held` ("waiting for the contact to decide", never "declined"), `rejected` (the contact's owner or agent said no)
     or `blocked` (the contact's node refused it). A node without the feature gets no `check_file` and the plain
     `reject_file` / `denied`.
  7. **An own computer's allowlist** (owner commands `file_allow`, with the password, and `file_disallow`, without;
     absent for agents): `executables`, `installers` or an extension (`.dmg`) let a level-5 contact's programs or
     installers through; in effect only while it stays at 5, never for a signature or a failed check, refused below 5.
     The first request's `code` category is gone: from level 3 code and markup is not held anyway, and levels 1–2 stay
     as they are by the maintainer's decision.
  8. **Save folders for own computers** (owner command `file_save_dir`, absent for agents; the password to set, none to
     clear): files from a contact at level 5 go to the folder of the agent whose key signed the offer, else the
     contact's folder, else `--project-dir`, else the link's `shared/`. The folder must exist in the owner's home (not
     the home itself), not be hidden or a system folder, not be in Antenna's data or link folders; symlinks are
     resolved when it is set. An agent's file offers are now signed by its key in the link (PROTOCOL §21), so the
     recipient can tell them apart. Levels 3–4 keep the link folder (decided here): a file read there is known as that
     contact's data, and the taint by folder (CONTROL §11) depends on it.
- **Threat analysis.**
  1. *Assets:* the owner's computer (code that runs), the owner's agents (instructions hidden in files), secrets, the
     owner's attention.
  2. *Running code:* Antenna never runs a received file and clears exec bits on accept; what runs when opened
     (programs, installers, disk images, archives of them) still waits for the owner at every level from 3. Left open on
     purpose by the maintainer's decision: documents whose active content runs when opened in another program (PDF
     `/Launch`, Office external templates and DDE, macros) and scripts as text are labels from level 3; the protection
     there is the opening program's, and on macOS Gatekeeper's: every saved file carries the `com.apple.quarantine`
     attribute a browser gives a download (`0081;<time>;Antenna;`, set before the file has a name).
  3. *Prompt injection:* reading a file from a link folder still taints the agent's session with that contact's level
     (SPEC §9); the preview stays rebuilt from pixels and cleaned text, hidden text and invisible characters are removed
     from it and labelled. New: a level-3 contact can put such a file in front of an owner's agent without the owner's
     review; the agent then works with that contact's permissions.
  4. *Secrets on receive* are the sender's own; a label for the owner. Passing them on stays guarded (no write-down,
     the flow between links, the outgoing scanner below level 5).
  5. *Archives:* every member's type is read; a program inside holds the archive. At level 5 an archive that cannot be
     opened whole is saved (the owner's own computer, by the maintainer's list); at 3–4 it waits.
  6. *A compromised check worker* can lie about the class; the daemon's own look at the magic numbers catches a
     top-level program or installer called anything else. Members are only the worker's word, as its verdict always was.
  7. *The fate receipt as an oracle:* a sender learns why its own file waits. Heuristic rules are never sent (labels
     stay local), the recipient's own rules and antivirus go by kind only, and a threat was refused at once before. A
     sender can tell level 5 from 3–4 by an encrypted archive (saved or held), as it already could by the time to
     `accepted`.
  8. *The signed update exception* needs a manifest signed by a key this daemon pins listing the file's exact name,
     size and SHA-256: whoever controls an own computer can deliver only genuine release files that way.
  9. *Save folders* are for own computers only, validated when set, with numbered names; a folder that becomes a link
     later is the owner's own change on their own computer.
- **Checked** (Linux build server, debug). Unit: `antenna_files` `kinds::tests` (labels from level 3 for the field
  report's files and a secret; programs, a ZIP holding an ELF, a disk image, an antivirus hit, EICAR and a failed check
  held at 3–5; archives not opened whole held only at 3–4; the allowlist at 5 only), `worker::tests` (the field
  report's files, archives classed by every member, tar and gzip members, executables and installers by format),
  `antenna_proto` (`fate_rules_never_carry_private_rule_names_or_free_text`, `receipt_body_wire_shape`, the commands'
  roles), `linksync::tests::a_receipt_says_why_only_in_its_vocabulary`. Live, real daemons
  (`crates/antenna-cli/tests/file_kinds.rs`, 6 tests): at ∞ the generated PNG, HTML, the `.txt` page, a stored ZIP of
  HTML and JavaScript and a text with a password are saved with their labels and classes; an ELF, a Mach-O, a ZIP
  holding an ELF and a `.dmg` wait with their reasons; the sending agent is told accepted or held, never "declined"; an
  agent cannot keep a program, the owner cannot without the password and can with it. At level 3 the same ordinary
  files are accepted by an agent and the programs wait. Level 2 is unchanged (a stored ZIP still a threat, refused,
  told to the sender as blocked). An antivirus hit (a stub `clamscan`) is held at ∞ and told to the sender as `av`.
  Save folders per own computer and per agent, bad folders refused, clearing without a password, none below ∞. The
  allowlist lets a program through (a held one released at once), is taken off without a password and refused below
  ∞. Updated: `files.rs` (a level-3 threat is held and told as held, served until the owner decides), `approved.rs` (a
  dot-file name still needs the approval, its unknown content is a label), `agents.rs` (the three owner commands
  absent for agents in the CLI and the protocol). **Negative controls**, each seen failing once and reverted: programs
  not held, installers not held, antivirus hits not signatures, heuristics still holding at 3–5 (labels from level 6),
  a held file told as refused, the per-agent folder ignored, a hidden or home folder accepted, the allowlist ignored.
- **Not checked yet.** The quarantine attribute on a real Mac (`xattr -p com.apple.quarantine <file>`, Gatekeeper's
  prompt on opening a received program); it is type-checked for both darwin targets only.
- **Not built.** Keeping a held file from another own computer through My devices (D-114
  carries approval requests, which last 10 minutes and come from an agent; a held file is neither and needs its own
  long-lived owner request on the device status); the window's allowlist and save-folder settings (the CLI has them);
  GIF's XMP extension (D-129).

### D-UI-45 · A held file reads like a browser's dangerous download; a sent file's fate from the contact's receipts (2026-10-06)
- **Decision** (`apps/antenna_desktop/lib/{state/files,ui/files/file_card,ui/files/preview_dialog}.dart`). A received
  file held by the rules (D-130) says what the danger is ("This is a program (…). It can run code on your computer.",
  "This is an installer or disk image. Opening it can install software.", "Antenna could not look inside this
  archive.", "The check found a known threat signature in this file.", "Antenna could not check this file."), shows its
  rules small with "Only you can keep it, with your password; agents can't.", and offers **Delete** first and **Keep
  anyway** (the password, `force`); nothing takes the focus. Labels show as quiet chips, code and markup as "Code:
  Antenna does not run it". A sent file's card follows the contact's receipts, only forward: "Waiting for <contact> to
  decide" (`check_file` / `held`, with the reason in words), "Held by <contact>'s check; it waits there for its owner"
  (`reject_file` / `denied`, with a quiet line that an older node's limits refuse the same way), "Declined" only for
  `reject_file` / `rejected`, then saved.
- **Checked.** `test/widget/file_fate_test.dart` (8), `test/widget/file_held_test.dart` (4); `flutter analyze` clean.
  Negative controls seen failing: `denied` mapped back to declined, the forward-only order removed, a stale reason
  kept, Keep anyway without `force`, plain decision buttons on a held file, the focus on Keep anyway.
- **Not built.** The allowlist and save-folder settings in the contact card and the agent chat menu; "Saved to
  Desktop/…" with Show in folder; Touch ID for Keep anyway (the password for now).

### D-131 · Touch ID everywhere once enrolled: every owner prompt, the terminal, and unlocking when Antenna opens (maintainer decision, 2026-10-06; experimental)
- **Question.** After enrolling Touch ID on preview.8 the maintainer still had to type the password, for example in
  **Agents → Start an agent**, and when entering the app. D-102 had built the daemon side for most commands but left
  the window's other prompts on the password (D-102 item 9) and kept a list of password-only commands.
- **Decision (maintainer, 2026-10-06).** "If I added Touch ID, then Touch ID everywhere. Even when entering the app."
  1. **The daemon** takes a D-102 owner proof for every command that asks for the password, with three exceptions:
     `init` (it sets the password), `owner_key_add` (it enrolls a key with the password and a proof by that key) and
     `update_auto_set` turning installs on (the daemon needs the password itself to open the root key it keeps for the
     restart, D-103). D-130's first version kept `file_allow` and `file_save_dir` password-only as security
     settings; they take a proof too now. Newly on the list: `local_agent_add`, `update_authorize` (with `password: ""`), `update_auto_set`
     turning installs off, `device_decide` (approve: a local proof now stands for this computer's password before the
     device key signs, amending D-114 item 3), `device_keys_confirm`, `device_lend_set` (on), `device_revoke`, and D-130's `file_allow`
     and `file_save_dir` (setting a folder). `unlock` keeps the unlock slot (D-102). The list stays explicit (`Request::accepts_proof`): a new password command
     takes only the password until it is put on one side on purpose.
  2. **The window** asks for one touch wherever it asked for the password: an action that opened the password prompt
     opens the Touch ID sheet instead, straight from the owner's click, and a form that had a password field shows a
     Touch ID line with **Use password**. The sheet's reason names what is confirmed (the prompt's own words, or "start
     the agent claude", "issue a token for the agent …"). A touch that does not go through (cancelled, unavailable,
     locked out, the password due, three failed attempts, the key gone, fingerprints changed) leads to the password,
     saying why; it never confirms anything. A flow with two owner commands (Connect with a changed task list) takes two
     touches: one touch is one command (D-102). **Settings → Security** lists what Touch ID confirms and when the
     password is still asked. Installing an update runs the CLI with `--touch-id`. **Keep anyway** on a held file
     (D-130) and approving a held send (a secret in a message or a file) take one touch too.
  3. **At app start** the first gate (keys locked, or no session) opens the Touch ID sheet by itself, once; after **Lock
     keys** the gate waits for a click, as before. D-UI-28's "no sheet without a click" becomes "no sheet except when
     Antenna opens and after a click".
  4. **The terminal** (CONTROL §22.7): on a Mac where the window turned Touch ID on, `antenna` confirms an owner command
     with one touch through `antenna-touchid`, a small Swift helper next to it that uses the window's Secure Enclave key
     (the key's blob in the window's folder for that daemon); the daemon checks the proof as it does the window's. In a
     terminal this happens by itself; without one only with `--touch-id`; `--password-stdin` never uses Touch ID.
     `antenna unlock` opens the unlock slot with one touch; a sign-in from a terminal takes a proof.
- **Prior art.** 1Password unlocks with Touch ID when it opens and shows the system sheet right after a click for each
  protected action, with "Use password" one click away, and asks for the account password after a restart, after a
  fingerprint change and after a set period. Banking apps show the biometric sheet as the app opens and to confirm a
  payment, and fall back to the passcode on cancel or after failed attempts.
  macOS System Settings shows the Touch ID sheet when a locked pane is clicked, with "Use Password…" in the sheet, and
  `sudo` with `pam_tid` does the same in the Terminal. Antenna follows that shape; what differs is that the daemon, not
  the app, checks a signature over the exact request (D-102).
- **What is new.** Nothing cryptographic: the D-102 message, the same verification with `aws-lc-rs`, the same
  challenge. New and experimental: the window's proving view (one typed request per proof), the terminal helper and the
  automatic sheet at app start.
- **Threats, and what answers them.** A sheet at app start that the owner did not expect: it appears only when the
  window opens with the keys locked or no session, never after Lock keys, never by itself later. A second process using
  the key blob (CONTROL §22.6): the helper is that process, said openly; each use still needs the finger and names the
  command. A proof for one command used for another: one request per proof, the request's exact bytes signed, the
  challenge used once (unchanged). Two commands from one touch: refused by the window's proving view before anything is
  signed. A script expecting the password: `--password-stdin` never asks for a touch.
- **Why.** The owner turned Touch ID on to stop typing the password; a password prompt left anywhere reads as Touch ID
  not working. The daemon still decides every command (SPEC §9).
- **Checked (Linux, debug).** `tests/owner_keys.rs` (6): every newly accepted command with a valid proof, and a
  replayed, a stale and a wrong-key proof refused before anything runs; turning automatic installs on and `init` refuse
  a proof; the CLI signs with the helper (a stand-in that signs with a software key), a cancelled sheet allows nothing,
  `--password-stdin` never asks, a key the daemon does not know falls back. `antenna-proto` unit tests (the list, both
  halves of the device commands). Window: `test/widget/touch_id_everywhere_test.dart` (Start an agent, the trust change,
  Touch ID unavailable or the password due, removing a contact, an invite, Keep anyway on a held file, LAN with "Use
  password", automatic installs, Settings → Security, the gate at start and after Lock keys, the install arguments), `test/protocol/proving_daemon_test.dart`
  (one request per proof, a failed prover), `devices_test.dart` (lending, accepting keys and revoking with one touch);
  live against `antennad` of this tree, `live_owner_keys_test.dart`: `trust`, `agent_add` and `agent_remove` through
  the real client, one proof each (signed in software with the published test key). `tools/check-darwin.sh` debug and
  `--release`. Negative controls, each seen failing: the D-131 entries removed from `accepts_proof`; `owner_keys::verify` returning
  success; `OwnerAuthController.usesTouch` returning false; `confirmOwner` skipping Touch ID; the gate's at-start check
  ignoring its flag; the proving view's one-request check removed; the CLI's `touch_for` ignoring `--password-stdin`.
- **Not checked yet.** On a real Mac: the helper compiles (`packaging/macos/build-dmg.sh` builds it with `swiftc`) and
  signs with the window's key from another process, the sheet at app start,
  the sheets of the new prompts, `antenna trust …` in Terminal.app.

## Pictures and files in the window (2026-10-06)

### D-UI-46 · Pictures and files as a messenger shows them: pictures inline and in albums, compact rows, the viewer's actions, Media and files, an own computer's file settings (field feedback, 2026-10-06)
- **Question.** After preview.8 the maintainer received logos an agent made: "It must appear right here in the chat,
  nicely, not just as a name. Going to Files to find a picture? If pictures are there at all, sort them separately:
  files, pictures, text. Small tiles, so that many fit on the screen, not one file taking almost the whole screen. I
  can't open this file, I can't even press 'show in folder'. We need a proper file history inside one conversation.
  Space in the chat is gold. When I attach a picture, the picture takes 5–10 % and the rest is the file name and its
  size; for a picture the content matters most. And I want to drag pictures to reorder them before sending." Earlier
  the same evening: open an attachment before sending, a full-screen viewer with previous and next, Save as… and Show
  in Finder, Copy, a chat's Media and files, a search by name. Every file was a card of 120–400 px with a progress
  strip, its name and size under the picture; a decided file had no action at all.
- **Prior art.** Telegram Desktop shows a photo as the bubble itself at its aspect ratio, up to about 400 px, and
  photos sent together as one album grid of up to ten; a document is one row with its icon, name and size; Shared
  Media has Photos, Files and Links tabs with search; the viewer pages through the chat's media with zoom, Save as,
  Copy and Show in Folder; the send dialog shows the attached pictures and lets the person drag them into order.
  iMessage shows photos inline with rounded corners, stacks several sent together, opens them in Quick Look (Space)
  and lists a chat's Photos and Documents in its Info pane. Slack shows an image inline with its name on hover and a
  file as a compact card, and its Files browser filters by type and searches by name. WhatsApp groups four or more
  pictures into a grid and has a chat's "Media, links and docs". We take the common shape. What differs: a received
  picture is always the daemon's safe preview, never the file (SPEC §10), and a file is only opened, revealed or copied
  from where the daemon saved it; and an own computer's save folders and allowlist (D-130) have no counterpart, since
  messengers decide neither.
- **Decision** (`apps/antenna_desktop/lib/ui/chat/{chat_media,attachments}.dart`, `lib/ui/files/{file_menu,
  image_viewer,media_files,files_page}.dart`, `lib/ui/contact/file_prefs_section.dart`, `lib/state/{media,
  file_prefs}.dart`).
  1. **A picture is the picture.** In the conversation a picture fills its own rounded box at its aspect ratio, at most
     320 × 320 px and not enlarged (`inlineSize`); its name and size show on hover and in the viewer; the check's state
     or a sent file's fate is a 22 px badge in its corner with the words in its tooltip, and nothing at all for a saved
     clean picture or a sent one still offered. A picture waiting for a decision keeps its buttons under it.
  2. **Albums.** Pictures sent the same way within two minutes of each other, on the same day, up to ten, are one grid
     (`joinsAlbum`, `albumRows`: two side by side, one wide over two for three, then rows of two and three). A tile
     opens the viewer at that picture among all the chat's pictures.
  3. **Any other file is a compact row:** its type icon, name, size and short state on one line; under it, one line
     at most of what the card says about the state (`FileStatusNote`: the same words and keys, so a sent file's fate,
     a numbered name and a duplicate stay visible), "Saved to ~/…" with Show in Finder, Cancel sending, or a text
     file's first line from its safe preview. A click opens a file with its app when it is on this computer, else its
     safe preview. Only what needs something read before a decision keeps the full card: a held file (D-UI-45), a
     threat or an unchecked file, a name the daemon could not use, a non-picture waiting for the owner, and a received
     release manifest with its Install (D-UI-29).
  4. **The same actions everywhere** (`file_menu.dart`): the right click and the ⋯ button of a row, a picture's hover
     caption and the viewer's bar offer Open, Show in Finder, Save as…, Copy image, Copy path, Safe preview and Cancel
     sending, each only where it can work. Open, Show in Finder and Copy path need the file on this computer: a
     received one where the daemon saved it, a sent one where the person's own file was. Save as… copies that file, or
     saves the picture shown as a PNG; Copy puts the picture shown on the clipboard. Nothing reads a received file the
     daemon has not saved.
  5. **The viewer** has a bar with the name, size, position and zoom level, zoom buttons and keys (+, −, 0), and the
     file's actions; Previous and Next by the arrows and the keys; a tap beside the picture or Escape closes it, a tap
     on the picture does not (zooming and panning should not close it).
  6. **Attachments before Send.** A picture waiting in the composer is a 72 px square of the picture itself with its ✕;
     any other file stays a chip. A click or Space opens a picture in the viewer over the composer's pictures and a
     file with its app; dragging changes the order, which is the order of sending and so of the contact's album. A
     refused one stays a chip with its reason or "Approve and send".
  7. **Media and files** of a chat, from its header, its menu and the contact card: Images as a grid of squares, Files
     and Text as rows, newest first, with a search by name; in a chat with one of the contact's agents that chat's
     files first (those whose offer is a message of it, as far as its history is loaded), all with the contact one
     click away.
  8. **The Files screen**: what needs the owner first as full cards with their buttons, then what is downloading, then
     every other file newest first, pictures as a dense grid (or everything as a list) and the rest as rows; filters
     for Images, Files and Text and the same search.
  9. **An own computer's file settings** on its card (level 5 only): where its files and each of its agents' files are
     saved (Choose folder…, Default) and which of its programs, installers or extensions are saved without Keep anyway.
     Setting takes the owner (one touch or the password, D-131); going back and taking an entry off do not. The window
     speaks `file_save_dir`, `file_allow` and `file_disallow` and reads `contacts[].save_dirs` and `file_allow`.
- **Why.** The maintainer's words above; space in the conversation goes to what the person reads, and every file can
  be acted on where it shows.
- **Checked** (Linux build server, `flutter test`): `chat_media_test.dart` (7: the picture at its size and the name only
  on hover, bounded sizes and the badge, an album and its viewer, the compact row with its click and menu, Copy image
  of the safe preview, a picture without a preview as a row, the album rules), `image_viewer_test.dart` (3: the bar and
  its actions, Save as… of a picture not saved here, keys), `composer_attachments_test.dart` (3: squares and the
  viewer by click and Space, drag reorder and the send order, ✕), `media_files_test.dart` (3), `files_page_test.dart`
  (2), `file_prefs_test.dart` (3), `client_v7_test.dart` (the three requests on the wire), the earlier file tests
  unchanged in substance (`file_withdraw`, `file_fate`, `file_held`, `file_numbered_name`, `file_rename`, `files`,
  `updates`); the whole suite 1,118 green and the live files and pictures tests; `flutter analyze` clean.
  **Negative controls**, each seen failing once and reverted: pictures shown as cards, albums off, the viewer closing
  on a tap on the picture, the composer's reorder ignored, the search ignoring the name, an agent chat's Media showing
  all files, the Files search ignored, the file settings shown below ∞. Frames: `26_chat_files`, `49_composer_staged`, `50_file_withdrawn`, `63_chat_images`,
  `64_image_viewer`, `24_files`, the new `92_media_files`, and every frame with a conversation header (its Media and
  files button).
- **Not checked yet.** On a real Mac: the drag with a real pointer, Show in Finder (`open -R`), the save dialog, Copy
  image through `osascript`.
- **Not built.** Thumbnails made by the daemon for the size drawn (the window loads the whole safe preview and decodes
  it at the drawn size); a sent file's history after the window restarts (the daemon keeps no record of sent files
  once the contact answered, so the conversation shows them as file lines then); videos.

### D-132 · A local route between two agents of one computer: the owner connects them, the text carries its writer's taint, and what a link would ask is refused (2026-10-06, experimental)
- **Question.** The maintainer, on the first evening with preview.8, expected to connect any two of their agents on the
  agent map "like in a constructor"; two agents of one computer have no link between them, so D-123 drew no line
  there (LOCAL-ASSISTANT §8.3 named a local channel as the direction, with its own threat analysis). How does agent A
  write to agent B of the same node, under the rules a link has?
- **Decision** (CONTROL §32).
  1. **A route is the owner's.** `agent_connect` with `local` (the password or an owner proof) connects two agents of
     this computer, both ways, with whose messages each takes as tasks (`tasks`, `peer_tasks`) and, with `ask`, both
     default counterparts; `agent_disconnect` with `local` (an owner session, no password: it only takes away) removes
     the route, the counterparts along it and the unread messages between the two. A link's wake agent, a team's
     worker and a local-model agent cannot be ends (the daemon decides whom they answer). Agents have no command for
     any of it (`unknown_command`). Schema 15: `local_routes`, `agent_local_counterparts`, `local_messages`.
  2. **The message goes through the daemon** into the recipient's inbox: an agent's `send` with `local`, or without a
     contact when its default counterpart is an agent of this computer; MCP `send_message` with `local_agent`; `antenna
     send --local`. The recipient gets it in `inbox` (after the link messages, within the same budget, marked `local`,
     wrapped as data or as a task the owner authorized), facts in `wait`, its subscription and `agent_watch` (so Code
     mode and `antenna session` wake it with their usual line).
  3. **Taint travels with the text.** The stored message keeps its writer's taint entries (ceiling and isolation) and
     local data label as they were when it wrote; reading it merges them into the reader, in the transaction that
     marks it read (per link the lower level; a label above the reader's becomes a declared read). This is the rule
     tasks already follow in teams (D-111): the reader is limited as if it had read what the writer read.
  4. **The level is the local data label, with no write down.** Both agents are the owner's and local, so the
     comparison is between their local data labels (the owner's baseline and declared reads, SPEC §9): a writer above
     the recipient is refused. Writing up is allowed.
  5. **Refuse where a link would ask.** A message with a secret scanner finding is refused (at every level), and so is
     a write down: there is no approval path for a local message in this round (approvals are bound to a link's
     record, D-100), so it fails closed instead of inventing one.
  6. **Loops are bounded by the daemon, not by the agents.** A message's hop is one more than the highest hop its
     writer read over local routes in the last 10 minutes of its current session: at most 8 (`hop_limit`); at most 30
     messages a minute in each direction (`rate_limited`); at most 100 unread for one recipient. The owner's session
     reset starts a new chain.
  7. **Owner commands never pass.** A local message is text in an inbox, marked as another agent's words; nothing in
     it is executed or interpreted, and the agent protocol has no owner commands (SPEC §9).
- **Threat analysis.**
  - *An injected agent driving a better-privileged one.* A reads a hostile contact's message at level 2 and tells B
    to run commands. B's session gets A's taint on reading, so its ceiling is 2 and `check exec` is denied, writes
    outside the link folder need approval: B acts with what A's sources allow, not with its own clean session. B's
    task flag only changes the wrapper's words ("task" or "data"); the daemon's checks are the same either way.
  - *Exfiltration through a better-connected agent (confused deputy).* A reads link X and asks B, which has link Y, to
    send it there. B's label now has X (isolation), so B's `send` to Y carries `cross_link:X` and needs the owner's
    approval, as if B had read X itself; A's higher local label cannot reach B at all (no write down). Residual: a
    clean A (it read nothing) can still ask B to write to B's own contacts with B's reach. The owner granted that
    when connecting the two, with the password; the line is visible on the map and removed with one click, and B
    treats A's words as data unless the owner ticked tasks.
  - *Loops between two agents (or a ring of them)* that would burn tokens or flood an inbox: the hop limit stops a
    chain at the ninth message within 10 minutes, the rate limit stops a flood at 30 a minute per direction, the
    unread cap at 100. A chain is counted from what each writer read, which an agent cannot reset; only the owner's
    session reset or 10 quiet minutes do.
  - *Secrets passed sideways.* The scanner refuses a message with a finding; a secret that slips past it is still
    data B read, under B's isolation and no-write-down rules when it writes anywhere.
  - *Probing which agents exist.* An agent not connected and one that does not exist get the same `not_found`.
  - *Stale routes.* Removing an agent removes its routes, counterparts and messages (foreign keys); a disconnect drops
    unread messages, and the read path checks the route again, so nothing is delivered after it.
- **What is new and why nothing existing fits** (D-94). Reused: the session label and its ceiling, the scanner, the
  rate limiter's window, the teams' carried-taint rule, the agent inbox and facts, the counterpart of D-123. New and
  experimental: the route record, the local message store with its carried label, and the hop counter. Links do not
  fit (they need two nodes, keys and a history); LOCAL-ASSISTANT §8.3's `ask_local_model` is a narrower call to a
  model, not a channel between two agents. Nothing cryptographic; nothing on the wire between computers.
- **Not in this decision.** Approvals for a local message (it is refused instead); local routes on another own
  computer shown on this map; a history view of the messages between two local agents in the window (the counts are
  in `agent_traffic`); routes for wake agents, workers and local-model agents.
- **Checked (Linux, debug).** `crates/antenna-cli/tests/local_routes.rs` with a real daemon:
  `a_local_route_delivers_with_the_writers_taint` (refused before a connection, the same answer for an agent that does
  not exist, no agent command, the password required, both ways by default, a contact's level-3 message read by A
  makes B's ceiling 3 and its `check exec` denied once it reads A's message, the fact in `wait` without text, read
  once, the task and data flags, an owner command's text delivered as text with nothing run, MCP instructions,
  `get_session` and `send_message` with `local_agent`, the CLI's `send --local`, the traffic pair),
  `write_down_is_refused_and_the_label_travels` (a label of 4 cannot write to 2, writing up passes, a declared read
  opens it, the label arrives with the message after the reader's reset, a private key refused),
  `the_loop_limit_holds` (8 hops of a ping-pong, the ninth `hop_limit`, a reset starts a new chain, 30 a minute then
  `rate_limited`, the other direction its own), `disconnect_stops_delivery` (no password, the unread message gone,
  sends refused, `agent disconnect` without naming the route, one counterpart at a time, a wake agent `denied`).
  Unit tests: `antenna_core::local_routes` (the merge at the lower level, the trust shown, the rate window),
  `antenna_proto::control::connections::the_local_route_fields`, the MCP instructions. Negative controls, each seen
  failing once: the route check of `agent_send_local` removed (delivered before any connection); the carried taint not
  merged (the reader's ceiling stayed `null`); the carried label not declared (the reader's label stayed 2); the
  write-down comparison removed; the secret scan removed; the hop check raised, and the hop counter returning 0 (the
  ninth message delivered); the rate limit not taken (31 delivered); the unread messages kept at disconnect together
  with the read path's route check (the old message was read after the disconnect).

### D-UI-47 · The agent map is an editor: a free layout kept per window, handles draw and bodies move, a click selects a line and Delete disconnects it, recent messages are an optional layer, local lines inside the group (2026-10-06, experimental)
- **Question.** The maintainer, on the first evening with preview.8: he expected the map to work like a constructor,
  where connections are set up and removed by hand and everything is moved around freely; instead it was only
  something to look at. He could not disconnect; two thin "Messages lately" lines from two of his agents to a third
  agent read as connections to the wrong agent, and they could not be removed because they are history, not
  connections; and his own server (∞) was drawn in the right-hand Contacts column.
- **Decision** (DESIGN "The agent map"; the bar is the boards people already know: Node-RED, n8n, Figma, Miro).
  1. **A canvas of its own** that fills the page at any window size: a small viewport (a `Transform` under a
     `Listener`) rather than `InteractiveViewer`, so a drag on a group, a card or a handle is that thing's own
     gesture and a plain mouse wheel pans. Pan: the empty canvas, the wheel, two trackpad fingers; zoom (0.4–2.0,
     around the pointer): a pinch, Ctrl or Cmd with the wheel, − / level / + / **Fit**. Trackpad pan-zoom events
     never drive a card or a group (Flutter's drag recognizers would take them by default).
  2. **A free layout, kept per window.** Groups move by their header anywhere; cards move by their body to another
     slot of their own group (a card dropped on another group stays, and the map says why). From the first move every
     group keeps its place. The arrangement, the view and the layer switch are kept in the window's settings file
     (`agent_map`), never in the daemon: it is this window's way of drawing the daemon's facts. Groups and cards it
     does not know are placed automatically; ones that are gone are ignored; a malformed entry is dropped. **Arrange
     automatically** goes back to the default and fits the view.
  3. **Handles draw, bodies move** (Node-RED's rule): a small circle on the side of every card a line can start
     from, always visible; the whole card no longer draws a line.
  4. **Select, then act.** A click on a line selects it (thicker, a soft glow) and opens a popover under the click
     with what the line means in words and **Disconnect** (the disconnect dialog's defaults: keep the tasks, ask an
     own computer to clear its side) and **Options…** (that dialog with its choices); a waiting line adds **Approve
     now**. Delete or Backspace disconnects the selected line the same way; Escape or a click on the empty canvas
     deselects. Hover shows the same words in a tip. Disconnecting needs no password (D-84).
  5. **Feedback for every action** in a status strip on the canvas: pending (a spinner, the line faded), done (with
     the other side in words and **Approve now** when that computer asks), refused (the reason in words; the
     daemon's own message for a code the window does not know). The connect dialogs report there too once closed.
  6. **Only real connections by default.** Recent messages are a layer, **Show recent messages**, off by default:
     when shown, thin grey lines without arrowheads labelled "messages, not connected · <time>", whose popover
     explains they are history; they are never removable and Delete sends nothing. A team's line is not removable
     either; a line another computer drew to the owner in person says where it was set.
  7. **Two agents of this computer** (with a daemon that sends `session.local_routes`, CONTROL §32, D-132): a line between
     them opens a local connect dialog (the line, then `ask`, `peer_tasks` and `tasks` as three checkboxes, all on,
     and what keeps it safe in the daemon's terms; the password or one touch, D-131); the line is an arc inside the group, in a lane on its side with
     fewer lines leaving it, with arrowheads and tasks marks; disconnecting sends `local` without a password. An older
     daemon gets a note and nothing is sent; one that refuses `local` as an unknown field gets the same words, and its
     other connections stay.
  8. **Own computers always on the left.** The default layout has three columns in map coordinates (own computers,
     this computer, contacts), fitted into the view, whatever the counts; a contact at ∞ whose report is missing is
     still an own computer, with "Waiting for its report" in its header.
- **Prior art.** Node-RED and n8n: nodes move by their body and wires start only at a port; a wire is selected by a
  click and removed with Delete; the canvas pans and zooms, and a layout is saved with the flow. Figma and Miro: a
  board pans with two fingers and zooms with a pinch or Ctrl/Cmd and the wheel, with a zoom level and Fit in a
  corner; a selection shows its own small toolbar. We took those gestures as they are; what differs is that a line
  here is the daemon's record (it takes the password to make), the layout is only the window's, and lines that are
  history (recent messages) are a separate layer that can never be selected for removal.
- **Why.** The owner arranges who works with whom where they look at it, as on any board: connecting and
  disconnecting are one gesture each, and nothing on the map looks like a connection unless it is one. The layout is
  a view, so it belongs to the window; the facts stay the daemon's.
- **What is new and why nothing existing fits** (D-94). Reused: the connect and disconnect commands and dialogs
  (D-123, D-UI-38), the window's settings file (`window.json`, as for Code mode, D-83), Flutter's pointer events.
  New, in the window only: the viewport (`InteractiveViewer` zooms on a plain wheel and competes with the cards' and
  groups' own drags) and the layout kept per window. Nothing cryptographic, nothing on the wire beyond CONTROL §30's
  `local`.
- **Not in this decision.** Lines between two other computers drawn here; several windows editing one arrangement
  (each keeps its own); undo.
- **Checked** (Linux, debug). `test/widget/agent_map_test.dart` (21: the map, connecting by a handle to an own
  computer, a contact's agent and a person, the other side's states, a card's body moving the card, the popover's
  Disconnect with pending then done, Delete and Backspace with a refusal in the daemon's words and Escape, Options…,
  the recent messages layer, hover, moving and keeping the arrangement through the settings file and Arrange
  automatically, pan and zoom by drag, wheel, Ctrl and the wheel, trackpad pan and pinch, the buttons and Fit, the
  placement, two agents of this computer, an older daemon for local connections, a daemon refusing `local`, the
  keyboard path, an older daemon, the agent's card with remote and local connections), `agent_map_graph_test.dart`
  (13), `agent_map_prefs_test.dart` (2), `test/protocol/client_connections_test.dart` (6), the live
  `live_agent_map_test.dart` (two real daemons as before; one daemon: volna connected with reviewer from the window
  client, the route both ways in `agent_list`, the line's default disconnect removing it without a password).
  **Negative controls**, each seen failing: the old balancing put back (an own computer with no contact drawn on the
  right: both placement tests); the recent layer on by default (the map test and the layer test); recent messages and
  a team removable (`defaultDisconnectFor` without its check: the layer test's Delete sent `agent_disconnect`, the
  graph test); a card's body drawing a line (the connect dialog opened); local connections offered without
  `local_routes` (the older-daemon test opened the dialog; two graph tests); "unknown field" marking every connection
  absent; Disconnect not sending the dialog's defaults (`ask: false`, `tasks: false`: the popover and Delete tests);
  the automatic fit left on while a group is dragged (the group moved by more than the pointer); the disconnect not
  marked pending (the line not faded); an arc three times deeper (it left the group: the layout and local tests).
  Frames `86_agent_map` (light, dark, Russian), `87_agent_connect` (light, Russian), `93_map_line_selected` and
  `94_local_connect` (light, Russian). To verify on a Mac: a trackpad's two-finger scroll and pinch, Cmd with the
  wheel, the frames there.

### D-133 · An urgent message from the owner interrupts an agent's turn; the owner's stop switch ends an agent and what it started (PG-58, field feedback, 2026-10-06; experimental)
- **Question.** Field feedback (2026-10-06): an app an agent had started hung and its panel stayed on the owner's
  screen. The owner wrote, urgently, to the agent that had started it, but the agent was in the middle of a long turn
  and Antenna's wake waits for the agent to go idle (D-UI-23, D-UI-25, D-116), so nothing happened until the turn
  ended and the owner had to force-quit the app by hand. Needed: an "urgent, interrupt now" delivery that only the
  owner can send, and a stop switch for an agent and the processes it started.
- **What the agent CLIs offer** (checked 2026-10-06 against their documentation). Claude Code
  (code.claude.com/docs/en/interactive-mode): "Esc: Interrupt Claude, or close a dialog … Stop the current response or
  tool call mid-turn so you can redirect … On a permission prompt, Esc declines the action"; "Esc + Esc … When the
  input is empty, double Esc opens the rewind menu"; a message typed during a turn is queued, not an interrupt. Its
  hooks (…/hooks): no event for an interrupt, and "Stop … does not run if the stoppage occurred due to a user
  interrupt". Headless (`-p --input-format stream-json`, the resident agents of D-93): the `interrupt` control request
  (the Agent SDK's `interrupt()`, "only available in streaming input mode"). Codex: its screen says "esc to interrupt"
  while it works, and its `Interrupt` hook "runs when you interrupt an active turn" (learn.chatgpt.com/docs/hooks);
  `codex app-server` has `turn/interrupt` (not used: Codex resident sessions are not built, D-93). tmux: `send-keys
  Escape` sends the key by name. So the interrupt is one Escape for the interactive CLIs and the control request for
  the daemon's own sessions; no keystroke is invented.
- **Decision: the urgent message.**
  1. **Only the owner's own message.** `send {…, urgent: true}` is an owner command (`Request` only; an agent's `send`
     has no such field and is refused as malformed), for one agent (`to: "agent"`, `bad_request` otherwise) of a
     contact at level 5 here (`forbidden` otherwise: an urgent message is for the owner's own computers). The CLI has
     `antenna send --to agent --to-agent <name> --urgent`; the window a toggle and a long-press on Send in an own
     computer's agent chat (D-UI-48).
  2. **A signed flag behind capability exchange.** `urgent: true` is a field of the text message's `envelope-core`
     (`docs/PROTOCOL.md` §23), so the author's signature covers it, sent only to a node that announced `urgent/0`. An
     older node gets a normal message and the reply says so (`sent.urgent: false`). Only `true`, only on text for one
     agent, only signed by the side's link-root: anything else is a malformed message and refused.
  3. **The recipient decides** (`crates/antenna-core/src/urgent.rs`), never the sender's word: the contact is at
     level 5 here, the message is its owner's (link-root, not one of its agents), it arrived as a new message (not
     history sent again), it is fresh by its own clock (at most 10 minutes old, at most 2 minutes ahead), and at most
     one urgent message per agent of this node is honoured per 30 s. Anything else is delivered as a normal message
     and waits for idle, as before. Either way the link's audit log has an `urgent` entry (`allowed`, or `refused`
     with the reason: `level_3`, `stale`, `rate`, …). The daemon's verdict is the only urgency anyone sees: `urgent`
     in the history item, the owner's `message` event and the agent's own `message_fact` (CONTROL §33).
  4. **What "interrupt" means for each kind of agent.**
     - *Code mode in the window* (D-UI-48) and *`antenna session`* (tmux): one Escape, then the built-in line
       "Urgent Antenna message from <label>: read your inbox now." at the prompt; the message itself is read over MCP,
       as data (D-88). The rules of the key are one module, `crates/antenna-cli/src/session/keys.rs`, mirrored in the
       window: Escape only while the CLI's own screen says "esc to interrupt" and does not show its empty prompt;
       never while a dialog is open (by the hooks, or a numbered choice on screen: Escape would answer it), never over
       the person's draft in the input, never while tmux is in a mode of its own or within 5 s of a key from a person
       attached to the session (their Escape and ours could make a double Escape, Claude Code's rewind menu), and at
       most one per 30 s. Held back, the urgent line waits for the prompt (or goes through the running turn's Stop hook
       like any line); an idle agent gets the line without an Escape. A line left for the Stop hook is taken back
       before the Escape, since an interrupted Claude Code turn runs no Stop hook; after the Escape the state is the
       screen's to decide (Claude Code fires no hook; Codex fires `Interrupt`). The urgent line goes past the 30 s rate
       of ordinary lines once, and covers whatever else waits (it is all in the inbox).
     - *Resident agents* (D-93): the turn in progress gets the `interrupt` control request, and the unread messages
       are the next turn, which begins "[Antenna] Your owner interrupted your previous turn with an urgent message
       from their own computer. Read it before you continue anything else." A one-shot wake run is stopped (its sandbox
       takes its tree down) and runs again on the messages.
     - *Team workers* (D-111): they have no links, so an urgent message cannot be addressed to one; the owner's
       channel to a worker is the review. `task_review {verdict: "changes", urgent: true}` (owner only; a lead's is
       `forbidden`) interrupts the worker's turn and returns the task with the comments at once, also while it is
       assigned, working or returned (a new state-machine operation, `Redirect`, unit-tested in every state).
     - *Local models* already had the owner's interrupt (`local_say {interrupt}`, D-104); *AI apps* the owner runs
       (Claude Desktop, Cursor, ChatGPT) cannot be interrupted from outside: their agents read the message as usual.
- **Decision: the stop switch.**
  5. **`agent_stop {agent}`** (CONTROL §33): an owner session and no password, since stopping only makes things safer
     (D-84). What is stopped depends on how the agent runs, and only what can be attributed to it reliably is ever
     signalled (`crates/antenna-core/src/agent_stop.rs`):
     - `terminal`: the window's Code mode and `antenna session` start the agent CLI in a terminal session of its own (a
       pseudo-terminal whose wrapper, or tmux pane process, leads the session) and tell the daemon so with
       `agent_terminal {agent, pid}`, which the daemon checks against the client's own process tree (the pid is the
       client or its own child, and a session leader). The stop takes every process with that session ID and
       everything under the leader and under the agent's bound process, the leader last;
     - `process`: an agent CLI the owner started in a terminal of their own: the bound process (D-28) and everything
       under it, never the rest of that terminal's session (the owner's shell and its other jobs);
     - `app`: an AI app's host (a GUI app's main process on macOS, a process without a terminal, or several hosts of
       one app, D-97): its processes cannot be told apart from the app's own, so nothing is signalled; the agent is cut
       off instead (a new token nobody holds, the binding removed) until the owner connects the app again;
     - `resident`, `wake`, `worker`: the daemon's own sandboxes, whose supervisor takes the whole tree down (D-71), as a
       stop of the session or `team_stop` of the worker does; what is left after the grace is swept as above;
     - `local`: a local model's agent runs no tools; its turn is stopped. `none`: nothing ran.
  6. **How processes are stopped.** By PID together with the start time (Linux: field 22 of `/proc/<pid>/stat`,
     signalled through a pidfd; macOS: `p_uniqueid`), never by name: SIGTERM, up to 3 s, then SIGKILL for whatever is
     left or appears, for up to 2 s; the session leader last, so orphans that hang off it are still found. Never the
     daemon or its ancestors, never the client that asked or its ancestors, never PID 1, and nothing reached through
     them. The reply says how, how many processes, how many were left and their names.
  7. **What the session cannot hold, the subreaper does (Linux).** A process the agent started that calls `setsid` and
     loses its parent (a server that daemonizes) leaves both the session and the tree; the kernel hands such an orphan
     to the nearest ancestor that is a child subreaper (`PR_SET_CHILD_SUBREAPER`, the mechanism of systemd and container
     inits). Under `antenna session` the CLI runs under a small subreaper (`antenna session-reap`, internal: it starts
     the CLI, reaps, forwards SIGHUP and SIGTERM, ignores the terminal's SIGINT and SIGQUIT, exits with the CLI's code),
     so such a daemon is still under the pane's process when the owner stops it.
  8. **From another own computer.** `device_agent_stop {contact, agent}` asks an own computer over the link
     (`docs/PROTOCOL.md` §24, `stop_agent`, feature `agent-stop/0`): sent only to a contact at level 5 here whose node
     has the feature (`unknown_command` otherwise); the other computer serves it only from a contact it has at level 5
     (checked before anything is decrypted and again when it is carried out), at most 6 a minute per link, and does
     exactly its owner's `agent_stop`; both audit logs have an `agent_stop` entry, and the owner's subscriptions on the
     stopped computer get the `agent` event with `change: "stopped"` and `by` (its label for the asking computer). No
     password and no proof: a stop takes work away, and an own computer is at ∞ anyway (D-99). My devices shows it
     where the other computer says `stop_agents` (D-UI-48).
- **What can and cannot be stopped.**

  | Started by the agent | Linux | macOS |
  | --- | --- | --- |
  | A command, a build, a test run, a server in the foreground or with `&` | ✓ (tree, session) | ✓ (tree, session) |
  | An orphan that stays in the session (`nohup …&`, a shell that exited) | ✓ (session) | ✓ (session) |
  | A daemon: its own session and its parent gone (`setsid`, double fork) | ✓ under `antenna session` (subreaper); in Code mode only while its parent lives | only while its parent lives |
  | A GUI app the agent ran directly (`./MyApp`, a Flutter or Electron build, the app's binary) | ✓ | ✓ |
  | An app opened through LaunchServices (`open -a`, Finder, `osascript … activate`), the iOS Simulator booted by `xcrun simctl` | — | — (its parent is launchd: the owner quits it, Force Quit) |
  | Work handed to another service (`systemctl --user start`, D-Bus activation, a running browser asked to open a tab, `docker run -d`) | — | — |
  | Anything an AI app the owner runs started (Claude Desktop, Cursor, ChatGPT) | — (the agent is disconnected) | — (the agent is disconnected) |

  The reliable way to cover more is the launch through Antenna: a sandbox (resident and team agents already run in
  one, and their stop takes everything in it), or a launch helper that records an app's PID; neither is built for
  interactive agents in this slice.
- **Threat analysis.** Assets: the owner's work in progress (an interrupt cuts it), the agents' availability, the
  owner's other processes (a stop must never take them), the owner's decisions (an interrupt is an instruction to
  drop what the agent does).
  - *A contact abuses the interrupt* (to keep the owner's agent from finishing anything, or to make it drop a task):
    honoured only from a contact at level 5 here, signed by its link-root; a contact's node that claims it (it has this
    node at level 5, the flag goes) is refused by this node's own level (test: `urgent.rs`, a contact at level 3 with
    the flag; negative control: the level check off, the agent is interrupted). A contact's agent cannot mark a message
    urgent (only link-root may; malformed otherwise).
  - *An interrupt storm* from an own computer that is compromised or buggy: at most one honoured per agent per 30 s in
    the daemon, and one Escape per 30 s in the waker and the window; the rest are normal messages.
  - *A forged or replayed flag*: the flag is inside the signed `core`, covered by the message ID; a message sent again
    in a history verification (`resend`) is never urgent, nor one older than 10 minutes by its own clock, nor a
    message that already waits when a watch opens; a duplicate is not stored twice.
  - *An older node*: it gets no flag (`urgent/0`, `agent-stop/0`) and its owner is told the message went as a normal
    one, or that the other computer cannot stop agents; nothing older nodes parse changes.
  - *Escape in the wrong place*: only where the CLI says "esc to interrupt", never into a dialog (it would decline a
    permission the owner may want), never over a draft, never twice in a row; the window and the waker type nothing
    but built-in lines, as before.
  - *A stop that takes the wrong processes*: exact PIDs with their start times (no name patterns, no PID reuse races
    on Linux through pidfd); the terminal session is swept only when the client that started it said so for its own
    child, and only while its leader lives; an agent CLI in the owner's own terminal takes only its own tree; an app
    is never killed; the daemon, the requester and their ancestors are kept. A process may name its own child session
    for an agent (`agent_terminal`), which can only narrow a later stop to its own processes; an agent's process
    cannot (agent role, D-28).
  - *A stop as a weapon*: agents have no stop command (the CLI, the protocol and MCP answer `unknown_command`); an own
    computer at ∞ can stop agents here, as it can already reach them with its tasks (D-99); 6 a minute per link.
  - *Residual*: a turn is cut where it was; the agent CLI keeps the work it had done (Claude Code: "Claude keeps the
    work done so far"), and an interrupted tool call may leave a half-written file. A stopped process loses unsaved
    work. A same-user process outside Antenna could still kill or spawn anything; Antenna's stop does not change that.
- **Prior art.** Terminals interrupt with a key the line discipline turns into a signal (Ctrl-C: SIGINT to the
  foreground process group) and end a session by hanging up its terminal (SIGHUP to the session); the agent CLIs put
  their own interrupt on Escape (Claude Code, Codex) and in their programmatic interfaces (the Agent SDK's
  `interrupt()`, `codex app-server`'s `turn/interrupt`), and an IDE agent's Stop button cancels the request and
  kills the processes of its own terminal. Messengers have urgency for people, not programs: Microsoft Teams repeats
  an urgent message's notification every 2 minutes for 20 minutes, Slack's "Notify anyway" passes Do Not Disturb,
  iOS has Time Sensitive notifications; none of them carries a signed, recipient-checked interrupt. Process
  supervisors stop a whole unit: systemd's `KillMode=control-group` (SIGTERM, then SIGKILL after the timeout, to
  every process of the cgroup), `docker stop` (SIGTERM, 10 s, SIGKILL in the container's PID namespace), container
  inits as child subreapers (tini, dumb-init), launchd's job process group. We reuse the CLIs' own key, the
  terminal's session as the unit, SIGTERM-then-SIGKILL, and a child subreaper; what we add is the owner-only signed
  flag the recipient checks, and the attribution rules for a session we did not create as a cgroup.
- **What is new, and why** (D-94: experimental, labelled so in the window and the guides). New: the urgent flag and
  its rule, the per-CLI interrupt policy (`keys.rs` and the window's copy), the stop's scope rules, `agent_terminal`,
  the subreaper launch of `antenna session`, the `stop_agent` device message. Reused: the signed message and feature
  exchange (D-90), the wake's lines and guards (D-UI-23, D-UI-25, D-116), the resident interrupt (D-93), the sandboxes'
  tree kill (D-71), the device channel between own computers (D-114), the kernel's subreaper. No new cryptography,
  no new dependency. Nothing existing fits: the CLIs' own interrupts need someone at the keyboard, and process
  supervisors (systemd scopes, launchd jobs) are system services Antenna does not own on the owner's computer.
- **Checked** (Linux, debug build). `crates/antenna-cli/tests/urgent.rs` (real daemons at level 5 both ways, a real
  tmux, a stand-in for Claude Code that runs its hooks and ends a turn on Escape without its Stop hook):
  `an_urgent_owner_message_interrupts_a_running_turn_where_a_normal_one_waits` (a 60 s turn; a normal message leaves
  its line for the Stop hook and nothing is typed; the urgent message is interrupted 0.2 s and its line typed 6.0 s
  after it was sent; the continuation was withdrawn; the log has `interrupt` then `urgent`; `urgent` in both
  histories and `allowed` in the audit log), `a_contact_below_level_5_cannot_interrupt_even_with_the_flag` (bob's
  node sends the flag, alice has bob at 3: no Escape, the turn's own end gives the ordinary wake line, `refused …
  level_3` in the audit log; the owner's CLI refuses `--urgent` below level 5),
  `the_stop_switch_ends_the_agents_processes_and_leaves_others_alive` (the stand-in starts a child, an orphan in its
  session and a `setsid` daemon whose parent exits; `antenna agent stop` takes all of them, `how: terminal`, none
  left, the session gone, an unrelated `sleep` of the same user alive; a second stop says `none`),
  `an_own_computer_stops_an_agent_over_the_link` (`antenna devices stop-agent`, both audit logs; refused once the
  agent's computer has the other at 4). `crates/antenna-cli/tests/resident.rs`
  `an_urgent_message_from_an_own_computer_interrupts_the_resident_turn` (a slow turn ends `interrupted`, the next
  turn, on the urgent message and labelled, answers 0.1 s after it); `crates/antenna-cli/tests/teams.rs`
  `the_owners_urgent_changes_interrupt_a_working_worker` (ordinary changes refused on a working task with
  `task_state`; urgent changes interrupt a worker that sleeps through its input, which the daemon then stops after
  the grace, and round 2 is submitted). Unit tests: the rule and the rate (`urgent::tests`), the stop's scope with a session,
  the owner's own terminal, PID reuse and kept processes (`agent_stop::tests`), the key rules (`keys::tests`: busy,
  stale hooks, dialog by hook and by screen, draft, a person's keys, tmux mode, the rate), the waker's urgent flow
  (`waker::tests`), the urgent lines, the wire shapes (`envelope`, `device`, `control::stop`, the stop commands absent
  for agents), the task state machine with `Redirect`. The "no owner API for agents" checks list `agent stop`,
  `devices stop-agent`, `agent_terminal`, `agent_stop`, `device_agent_stop` and refuse an agent's urgent `send`.
  **Negative controls**, each seen failing (a script patches one line, rebuilds, runs the guarding test, puts the line
  back): the level check of the rule loosened to 1 (the contact at level 3 interrupts: no line is left for the Stop
  hook); the subreaper off (the `setsid` daemon survives the stop); the session sweep and the subreaper both off (the
  orphan in the session survives; with only the session sweep off the Linux subreaper still holds it, so the test
  passes, which is why both are kept); both level checks of the remote stop loosened to 4 (the computer at level 4
  stops the agent); no Escape-into-a-dialog rule and no draft rule in `keys.rs` (the unit test presses Escape there);
  the waker not taking back the Stop hook's line before the Escape (the waker test); the resident actor not
  interrupting its turn for an urgent message (the slow turn ends `done`); the worker not interrupted for urgent
  changes (round 2 never comes within the test's time).
- **Limits.** The interrupt depends on the CLI's screen hint ("esc to interrupt") and on Escape keeping its documented
  meaning; the daily canary runs Claude Code, not the interrupt yet. What the agent does after the urgent line is the
  model's. Codex in `antenna session` is interrupted by the same rules but not yet run for real. The window's Code mode
  on Linux has no subreaper (its wrapper is bash): a daemon that left the session and lost its parent survives a stop
  there. macOS: no subreaper; LaunchServices launches are not the agent's (the table). Remote urgent messages and
  stops between two real Macs are still to be recorded.

### D-UI-48 · The window's urgent message and stop switch: a toggle by Send, one Escape through one module, an honest stop dialog (PG-58, 2026-10-07; experimental)
- **Question.** The window's part of D-133: where the owner marks a message urgent, how Code mode interrupts its own
  agents, and where "Stop agent and its processes" lives.
- **Decision.**
  1. **The composer.** In an agent's chat of a contact at ∞ (`ThreadKey.agent`, D-UI-32) a bolt toggle next to Send,
     **Urgent: interrupt now**; a long press on Send sends the text as urgent too. Hidden in a person's chat, for
     everyone, below ∞ and with a daemon before x-control/7; shown off with the reason when the contact's node has no
     `urgent/0` (`peer_urgent`); on, the field's border and a line above it are red. It belongs to one chat and
     recipient and turns itself off after each send. A reply `urgent: false` says the message went as a normal one.
     Bubbles show an "Urgent" mark only where the daemon says so (`urgent` on the history item).
  2. **Code mode** (`lib/state/code_input.dart`, `RunInput`): the one place that decides what the window may put into
     an agent's terminal by itself and puts it there: the fixed lines (typed at the prompt or left for the Stop hook)
     and the one key it presses by itself, Escape for an urgent message. `interruptBlock()` holds the rules of D-133
     item 4 for the window: Claude Code or Codex only, no dialog (by the hooks, or a numbered choice on the screen
     whatever the hooks say), no draft of the owner's, a turn that runs (the hooks, or the CLI's busy hint when they
     cannot say), at most one per 30 s; `screenText()` reads the screen. An urgent message for an agent in the dock
     (the daemon's verdict, the D-91 rule, the wake switch on, each message once) presses one Escape where allowed,
     withdraws a line left for the Stop hook, marks Claude Code's state unknown, then types "Urgent Antenna message
     from <label>: read your inbox now." at the prompt by the usual guards, past the 30 s rate of ordinary lines. The
     dock says "Interrupted at 14:32: urgent message from Mac mini" or why it waits (a question open, unsent text, too
     soon). The quick reply Stop now marks Claude Code's state unknown too.
  3. **Stop agent and its processes…** in the dock tab's menu (next to Stop, which stays as it was), next to a
     running agent in Agents, and on an own computer's agent chip in My devices (off, with the reason, where that
     computer cannot do it). One confirmation that says what is stopped and what is not (apps opened through Finder or
     `open` on a Mac; an AI app's processes), no password (D-131's prompts are for widening, not for stopping). The
     result as a notice: how many processes, or "disconnected" for an app, or "was not running". Every Code mode tab is
     registered with `agent_terminal` after its start and each reconnect, so the stop sweeps its whole terminal
     session; the tab then says "Stopped", or "Stopped from <computer>" after the `agent` event with `by`; an older
     daemon gets the window's own terminal stop, and the notice says only the terminal was stopped.
  4. **Teams**: next to Request changes in a task's review, **Urgent: interrupt the worker now** sends `task_review`
     with `urgent: true`; while it is on, Request changes is offered for an assigned, working or returned task too.
- **Why.** The urgent toggle sits where the message is written, and only where the daemon can honour it; the key
  path is one module so the interrupt's rules cannot drift between call sites, and the next feature that answers a
  terminal from another own computer (PG-59) builds on the same `RunInput`.
- **Checked.** `test/widget/code_wake_urgent_test.dart` (17: one Esc then the line for Claude Code with and without
  hooks and for Codex with its Interrupt hook; a normal message in the same turn only waits for the Stop hook; no Esc
  into a permission dialog, a forged "working" over a numbered choice, a draft or a Codex approval; no second Esc in
  30 s; each message once; the wake switch; no verdict, no interrupt; another agent's message; the sanitized label; a
  restored agent's `message_fact`; the dock's note), `urgent_composer_test.dart` (10), `agent_stop_test.dart` (10:
  `agent_terminal` after start and reconnect, the dialog and Cancel, the sweep and the tab's state, an older daemon,
  the event from another computer, Agents, the notices, My devices and its disabled chip), `teams_urgent_test.dart`
  (3), `client_urgent_stop_test.dart` (3), the live `live_agent_stop_test.dart` (2, real daemons: `agent_terminal`
  takes only the client's own session leader and `agent_stop` sweeps it; an urgent message and a stop between two
  own computers). Frames `95_urgent_composer(_ru)` and `96_agent_stop(_ru)`; `51_code_quick_replies`,
  `67_agent_chats`, `68_chat_menu` change with the composer's and the dock's controls. Negative controls, each seen failing:
  `interruptBlock` without the dialog rule (Esc into a permission dialog and over a numbered choice), without the
  draft rule, without the 30 s rule; the composer's offer without the ∞ check (the toggle in a contact's chat below
  ∞).

## Native Windows (2026-10-13)

### D-134 · Native Windows: an AF_UNIX control socket, process checks that only restrict, AppContainer sandboxes, a per-user installer signed through Artifact Signing, built on GitHub-hosted runners (design, 2026-10-13)
- **Question.** The maintainer asked for a native Windows app with agents working inside it (2026-10-12: WSL2 is not
  native: keyboard layouts do not switch in WSLg, the window froze), and set its order: the window with Code mode
  (Claude Code, Codex), AI apps over MCP and local models on an NVIDIA GPU first. Every Linux- and macOS-specific piece
  needs a Windows counterpart that keeps the protections: the same-user control socket and the D-28 binding, process
  hardening (D-50), the two sandboxes, the quarantine flag, packaging, signing, updates and Touch ID. The item list is
  `docs/PORTABILITY-WINDOWS.md` (WP-1…WP-37), in phases W0…W5.
- **Prior art.**
  - Local IPC: Docker Desktop (`\\.\pipe\docker_engine`), VS Code and 1Password's SSH agent use named pipes on Windows;
    Windows has AF_UNIX since Windows 10 1803; dart:io added AF_UNIX on Windows in Dart 3.11 (2026-02-11) and has no
    named pipe API; tokio has named pipes and no AF_UNIX on Windows. A named pipe's client PID is not an identity:
    Project Zero showed in 2019 how a client chooses it, and a pipe handle outlives its opener.
  - Sandboxes: Chromium on Windows (restricted token, job object, alternate desktop, integrity levels, AppContainer
    and LPAC; `docs/design/sandbox.md`), the AppContainers of Edge and Office; Codex's Windows sandbox (a restricted
    token, or after a one-time administrator setup separate sandbox users with firewall rules, or Microsoft Execution
    Containers on Windows 11 24H2 and later); Claude Code sandboxes only under WSL2 on Windows.
  - Process hardening: KeePassXC sets its own process DACL with an `OWNER RIGHTS` entry so other processes of the user
    cannot read its memory or restore their access.
  - Received files: Chromium and Firefox write the `Zone.Identifier` stream (Mark of the Web) on every download.
  - Packaging and updates: VS Code and Telegram Desktop ship per-user Inno Setup installers; Signal Desktop an
    electron-builder NSIS per-user installer; Slack MSIX and MSI for managed deployment; Squirrel and Velopack keep the
    app in a versioned folder and update it from outside; Claude Desktop's MSIX install reads its MCP settings from
    inside its package folder, which is how its users' settings got lost; WiX 6 and later charge commercial users the
    Open Source Maintenance Fee.
  - Signing: Azure Artifact Signing (formerly Trusted Signing): Authenticode certificates that live three days,
    timestamped; SmartScreen reputation accumulates with downloads, and EV certificates no longer bypass it.
  - Biometrics: KeePassXC and Bitwarden unlock with a Windows Hello `KeyCredential` (RSA-2048): a signature over a
    stored random challenge, hashed into the key that wraps the vault key; Flutter's `local_auth_windows` only asks
    `UserConsentVerifier` for a yes or no.
- **Decision** (team design; the order and the build machine are the maintainer's).
  1. **Targets and machines.** Windows 10 22H2 and 11, x86_64 (MSVC) first, arm64 later. The build and test machine is
     a GitHub-hosted runner (`windows-2025`, pinned; `.github/workflows/windows.yml`, manual and `windows/*` pushes
     only, 60 minutes, one run per branch, every action pinned by SHA); a Windows 11 PC with an RTX 4090 is for the
     hands-on check of each phase and the GPU. Windows-only code is type-checked on Linux first
     (`tools/check-windows.sh`, D-P-7's method).
  2. **Control socket: AF_UNIX** at `%LOCALAPPDATA%\Antenna\antennad.sock` for every client, not a named pipe: the
     window's dart:io client works unchanged, and the peer PID comes from the socket
     (`SIO_AF_UNIX_GETPEERPID`) rather than from what a pipe client may choose. The daemon side is new FFI in
     `antenna-sys` (tokio has no AF_UNIX on Windows), each connection bridged into the existing async handler. The data
     folder gets a protected owner-only DACL, checked at startup (the `0700` counterpart); the client's token user SID
     must equal the daemon's.
  3. **The peer and its chain.** The client process is opened right after the accept and must have been created
     before it (a PID reused after the client exited is refused, which closes D-41's window on Windows); parents are
     linked by PID and an earlier creation time; anything unreadable is refused. Until a FACT test on Windows shows the
     peer PID is the connecting process as the kernel saw it, the D-28 binding is not offered on Windows (agents by
     token only).
  4. **The tree only restricts on Windows.** Any process can name another process of its user as its parent
     (`PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`), so: no agent role is ever granted by the tree without a token (hooks
     carry the token file); a token-less connection from inside an agent's tree is refused rather than given that
     agent's role; anchors exclude `explorer.exe`, shells and terminal hosts, other users and sessions, and the
     daemon's ancestors. The remainders go to CONTROL §11: a stolen token can be used from a process that picks the
     host as its parent; escaping the tree is Windows' form of the double fork.
  5. **No terminal or parent owner sessions on Windows**: a console can be joined (`AttachConsole`) and a parent
     chosen, so neither identifies a terminal; the window's `held` session stays, and the CLI asks per command (the
     password, or Windows Hello from W5).
  6. **Hardening (the D-50 counterpart):** the own process DACL with `OWNER RIGHTS`, WER excluded, mitigation policies
     (extension points, remote and low-label images, strict handles; no dynamic code in release once tested); every
     child gets an explicit handle list (the D-61 counterpart).
  7. **Sandboxes on the experimental track:** the file check worker in a less privileged AppContainer with no
     capabilities, inside a job object (one process, memory and CPU limits, UI limits), proving its isolation from the
     inside; the agent sandbox as an AppContainer with per-run ACEs and the supervisor outside, its proxy bridge chosen
     by FACT tests. Until the probes pass, files are held and the daemon's own agents refuse (`sandbox_unavailable`),
     as on any OS without isolation.
  8. **Files:** saved without following reparse points, created new and renamed without replacing, the final path
     compared; every saved file gets `Zone.Identifier` with `ZoneId=3`.
  9. **The window:** Flutter's Windows runner; Code mode through ConPTY (`flutter_pty`) with `antenna agent-run`
     replacing the bash wrapper (a job object, so Stop ends everything the agent started); hooks call `antenna.exe`;
     AI apps' configs where the installed app reads them (Claude Desktop's MSIX path); local models on the GPU first
     through the owner's LM Studio or Ollama (an MCP host, and PG-65's backend), the built-in CUDA runtime after the
     sandbox.
  10. **Install and update:** a per-user Inno Setup installer into `%LOCALAPPDATA%\Programs\Antenna\current` (no
      administrator), the daemon started at login from the user's `Run` key, the CLI on the user's `PATH`; not MSIX
      (its `AppData` redirection hides the daemon and configs from other programs), not WiX (its fee), not
      Squirrel or Velopack (their update model would sit beside ours). `antenna update` keeps D-82's verification and
      swaps the folder from outside it; automatic installs (D-103) refuse on Windows until the key handover has its
      own review. Every PE and the installer are signed through Azure Artifact Signing from CI over OIDC; the release
      key stays the update's root of trust.
  11. **Windows Hello (W5):** a `KeyCredentialManager` key signs the D-102 message, a prompt per signature; the daemon
      verifies RSA with `aws-lc-rs` (no new crate) under a new optional key algorithm in `owner_key_add`, which older
      daemons refuse, so the window keeps the password with them. Not `local_auth_windows`: a yes or no is a check in
      our own code, not a key.
- **What is new** (the experimental track, `docs/STACK.md` "Principle: proven technology first"): the AF_UNIX transport and its bridge in the daemon
  (FFI of our own, reviewed like D-41), the Windows tree rule of item 4, and both sandboxes' Windows profiles. Each comes
  with FACT tests on the runner, negative controls and a threat analysis before it leaves the experimental track.
- **Why.** The order gives the owner agents inside a native window soonest (W0→W2) without opening anything the
  daemon cannot verify on Windows: what is not ported refuses (`not_implemented`, `sandbox_unavailable`), and every
  choice follows a product that has run it at scale, except where Windows itself forces a stricter rule (items 3–5).
- **Open (for the maintainer).** (1) The CLI asking per command on Windows (item 5). (2) Cryptography for Windows Hello:
  RSA verification for approvals; for unlock, KeePassXC's and Bitwarden's signature-derived key (experimental) or a
  WebAuthn passkey with PRF (Windows 11 25H2 and later). (3) The publishing organization for Artifact Signing. (4) If
  AppContainer cannot carry the agent CLIs: a one-time administrator setup like Codex's elevated mode, or wake off on
  Windows. (5) Whether `release.yml` gets the Windows job at W4.

### D-135 · Windows: the control socket is a named pipe for every client, not AF_UNIX; the window reaches it through `antenna.exe` over stdio (amends D-134 item 2, 2026-10-13)
- **Question.** D-134 item 2 chose AF_UNIX on Windows. On the Windows 11 build machine (25H2, build 26200,
  `afunix.sys` 10.0.26100.8972), the window's protocol tests bugchecked the machine twice. In those tests a dart:io
  AF_UNIX server and client run in one `flutter_tester` process, which is killed when its file ends. Both crash dumps
  show 0xD1 in `afunix!AfUnixTlConnectEndpointDisconnect`, reached when AFD cancels a pending transmit-packets request
  (the `DisconnectEx` path) while the dying process's handles are closed. An unprivileged process gets there. Do we
  keep AF_UNIX?
- **Prior art.**
  - Named pipes are the local IPC of Windows services and their clients: Docker Desktop (`\\.\pipe\docker_engine`),
    Tailscale's `tailscaled`, the Windows OpenSSH agent, 1Password's SSH agent and VS Code.
  - tokio has named pipes (`tokio::net::windows::named_pipe`): first instance only, remote clients rejected, security
    attributes, and the client's impersonation level.
  - dart:io has no named pipe API. For clients that cannot open the daemon's socket, Docker's
    `docker system dial-stdio` carries the connection over a child process's stdio.
  - A pipe client's PID is the client's word (Project Zero, 2019), as D-134 already noted.
- **Decision.**
  1. **No AF_UNIX on Windows**, in the product or its tests. The window's AF_UNIX protocol tests run on Linux and
     macOS only, and the W0 window on Windows does not try to connect.
  2. **The control endpoint on Windows is a named pipe** whose name is derived from the user and the data folder. It
     is created as the first instance (a name someone else holds stops the daemon), rejects remote clients, and has a
     protected DACL for the user's SID only.
  3. **The client's user comes from its token**, read by impersonating at identification level. Another SID, or an
     impersonation that fails, is refused. The client PID is used only to restrict, as D-134 item 4 does for the tree:
     it never grants a role, so the D-28 binding is not offered on Windows, and agents connect by token.
  4. **Clients check the server before they send anything.** The CLI, the MCP server, hooks and the stdio bridge open
     the pipe at identification level, so the server cannot act as them. They then check that the server process runs
     as the same user.
  5. **The window speaks the same line protocol through `antenna.exe` as a child process over stdio**, so the window
     has no native code for the transport. The W1 design note compares this with Dart FFI to the pipe.
- **What is new.** Named pipes are not new. Our combination of checks goes on the experimental track, with FACT tests
  and negative controls, as D-134's AF_UNIX transport would have.
- **Why.** A transport through which an ordinary process can bring down the user's computer is ruled out, whatever
  the cause of the bug. Named pipes are Windows' own local IPC, the most used one, and tokio carries them, so we need
  less FFI of our own than AF_UNIX would. What we lose is a peer PID reported by the kernel, and on Windows that PID
  could only restrict anyway (D-134 items 3 and 4). Team decision; the maintainer is informed.
- **Built (2026-10-13, W1 on the build PC; CONTROL §1, §3, §11 item 15, §34; PORTABILITY-WINDOWS §2.0).** The
  daemon's pipe, the client's checks before it sends anything, the window's bridge, the data folder made and checked,
  and owner commands in a terminal. What the decision left open, and the choices made:
  1. **The pipe's name** is `\\.\pipe\antenna-<SID>-<h>`, where `<h>` is FNV-1a 64 over the UTF-16LE bytes of the data
     folder's canonical path in lower case. Each data folder of a user gets its own pipe, as each gets its own socket
     on unix, and a long or non-ASCII path still gives a short name of fixed form. The hash is not a protection (the
     DACL and the client's checks are): it has no key and no dependency, so every client computes the same name. A
     client that resolved the data folder before it existed names the pipe when it connects.
  2. **The data folder is made for the user alone, and checked when found** (WP-4). antennad makes it owned by the user
     with a protected DACL of one entry, the user. A folder it did not make must be owned by the user, with a
     protected DACL, nothing inherited, and allowing entries for only the user, SYSTEM and the Administrators;
     anything else stops the daemon with each finding, and nothing is changed (TROUBLESHOOTING gives the `icacls`
     commands). Prior art: Win32-OpenSSH refuses a private key or `authorized_keys` file whose access list lets anyone
     else in; ours is stricter about the owner and inheritance. antennad does not run elevated: an elevated daemon
     would own its pipe and files as the Administrators, with its keys in an administrator's process.
  3. **One bridge per window.** `antenna.exe window-bridge` carries all of the window's connections over its stdio
     with a small framing (CONTROL §34), rather than one process per connection. `daemon_untrusted` is the CLI's own
     error (exit 1) for a pipe whose owner or server process is not the user's, never `daemon_unavailable`, so the
     window starts no daemon against a squatter.
  4. **A lifeline.** Windows does not end a child with its parent, so a daemon the window starts gets
     `--exit-with-stdin` and exits, locked, as on SIGTERM, when its stdin closes: when the window ends, even killed.
     Linux does the same.
  5. **Owner commands in a terminal (WP-10).** With no `tty` or `parent` session, the CLI asks for the password for each
     command that needs a session and holds a `held` session for that command alone, on a connection of its own; the
     token never leaves the process. Prior art: UAC and Microsoft's `sudo` for Windows ask each time too.
  6. **A byte order mark.** Windows PowerShell 5.1 sends one before the text it pipes into a program, so the CLI drops
     a leading U+FEFF from each stdin line; before that it became part of a password set with `--password-stdin`.

## Updates from the update address (2026-10-28)

### D-137 · Release builds check a built-in update address once a day; with automatic installs off, a release they find waits for the owner, who installs it with the password (maintainer decision, 2026-10-28)
- **Question.** `antenna update` (D-82) and automatic installs (D-103) can fetch a signed release from an update URL,
  but no build had one: `DEFAULT_UPDATE_URL` was empty while the repository was private, and the daemon checked a URL
  only with automatic installs on. So a preview stayed where it was until the owner downloaded the next one by hand.
  The maintainer wants updates to reach the Mac app the way the project's other Mac apps get theirs. Should the app
  use the update framework of those apps (Sparkle) or our own signed updater, where does it look, and what happens
  when automatic installs are off?
- **Prior art.**
  - Sparkle, which most Mac apps outside the App Store use: a daily check by default (`SUScheduledCheckInterval`
    86400), then "A new version is available" with Install, Skip and Remind me later; the download can be automatic.
  - Signal Desktop downloads updates in the background and offers "Restart to update", with no switch in its settings.
  - Chrome and VS Code also download in the background and say "Restart to update". VS Code turns updates off with
    `"update.mode": "none"` in its settings file, not on a screen.
  - Telegram Desktop checks by itself and puts "Update Telegram" in its menu.
- **Decision.**
  1. **Our own updater, not Sparkle.** Sparkle would replace `Antenna.app` without knowing the daemon's LaunchAgent,
     the key handover or the rollback, so the node would come back locked after every update. It does not cover
     Linux, and it would bring a second signing key and a second trust root next to the release keys that the binaries
     pin (SPEC §13, §15).
  2. **A built-in update URL in release builds:**
     `https://updates.stillbyte.dev/antenna/antenna-preview-manifest.json`, the newest preview, with its `.sig` and the
     release files next to it. A stable release gets `antenna-stable-manifest.json` there. The order is `--url`,
     `ANTENNA_UPDATE_URL`, `~/.config/antenna/update-url`, then the built-in URL, and the CLI and the daemon resolve it
     with the same function (`antenna_update::fetch::update_url`). `off`, or an empty value, in the variable or the
     file turns it off, the built-in URL included. Debug builds have no built-in URL: tests and development builds never
     reach the network by themselves. The release check of the archive confirms that the URL is in the release binary
     and that `off` works (`packaging/linux/check-install.sh`).
  3. **The daemon checks once a day whatever the setting**, and only where the installation can replace itself (the
     macOS app, the `install.sh` layout). A `.deb`/`.rpm` install or a development build never downloads a release.
     What it finds is verified and staged exactly as in D-103.
  4. **With the setting off, a staged release waits for the owner.** Off is the default. For previews it stays the
     default until the second release key exists (D-103, `docs/UPDATES.md` §8.5: one stolen key must not install
     everywhere). The window shows "Antenna <version> is ready to install" in Files and in Settings → Updates.
     **Install** asks for the owner password and sends `update_auto_now {password}`, a new optional field (CONTROL §23).
     The daemon opens the root key with the password for this one restart and installs at once, with D-103's swap and
     handover, so the new version comes up unlocked. The setting stays off, and the key is dropped if the release is
     unstaged, replaced or fails. A proof (Touch ID) cannot stand in for the password, because only the password opens
     the root key. In a terminal: `antenna update --auto now`.
  5. **The release pipeline mirrors each published release to the update host.** `packaging/release-linux.sh` runs
     `ANTENNA_UPDATE_MIRROR` with every file first and the channel manifest and its signature last, so the address
     never announces files that are not there yet; `--mirror-only` repeats this step alone.
  6. **The host is plain storage.** It serves files from object storage behind a CDN, and nothing it serves counts
     before the signature check with the pinned keys. A host that is taken over can hold an update back, or offer an
     older one, which is refused as not newer. It cannot install anything.
- **What it reveals.** One HTTPS request a day from the computer's address to the update host and its CDN: no
  identifier, no version in the request, curl's user agent. Turning it off is a line in a file, as with VS Code: no
  switch in the window, since most people want updates.
- **What is new.** Nothing cryptographic: the signature (D-82), the verification and staging, and the key handover
  (D-103) are the ones already built. New are the default address, the check with the setting off, and the password
  on `update_auto_now`. The password check is the one every owner command uses.
- **Why.** Without a built-in address previews do not reach the people using them, and the bugs they fix stay in the
  field. The daily check with the install left to the owner is what the leaders do when they do not install silently,
  and installing with the password keeps D-103's promise that an update does not leave the node locked.
- **Checked.**
  - `cargo test -p antenna-update`: the order of the sources, `off` and empty values, and that only release builds
    carry the URL.
  - `cargo test -p antenna-proto`: `update_auto_now {password}` takes the password and never a proof, and its `Debug`
    hides the password.
  - `crates/antenna-cli/tests/auto_update.rs`, `with_the_setting_off_the_daily_check_stages_and_install_now_takes_the_password`,
    with a real daemon and a local HTTPS server:
    - with the setting off the release is staged, and nothing installs by itself while agents are idle;
    - Install now without the password is `password_required`, and with a wrong one `wrong_password`; neither changes
      anything;
    - with the password the new version comes up unlocked, with the setting still off and no key kept;
    - a development-build daemon never checks.
  - Negative controls: without the `password_required` check, and without the development-build gate, the test fails.
  - The window: `test/widget/update_auto_test.dart` (the banner with the setting off, Install asking for the password,
    the staged line in Settings).

### D-138 · A stable version checks the stable channel; a stable release is announced on both channels (2026-10-31)

- **Question.** D-137 built one update address into release builds, the preview channel's manifest. The first release
  without a pre-release suffix, `0.1.0`, would be mirrored only to `antenna-stable-manifest.json` (UPDATES §6), which
  no installed preview checks, while `0.1.0` itself would keep checking the preview manifest: previews would never
  learn of `0.1.0`, and `0.1.0` would be offered every later preview.
- **Prior art.** Browsers and editors with channels (Chrome stable/beta, VS Code stable/Insiders, Zed stable/preview):
  a build follows the channel it came from, and a beta channel always carries a build at least as new as stable.
- **Decision.** The built-in address follows the build's own version (`antenna_update::fetch::channel_url`): a version
  with a `-` checks the preview manifest, any other the stable one. `packaging/release-linux.sh` mirrors a stable
  release under both names, a preview under the preview name only. The manifest's own `channel` field is unchanged;
  the signature check and the "only newer" rule decide what installs, as before.
- **Why.** Every existing preview install reaches the first stable release without a manual step, and people on a
  stable release are never moved to a preview they did not ask for. No format, key or protocol change.
- Decided with the move to `0.1.0` (the version is a maintainer decision, 2026-10-31).

