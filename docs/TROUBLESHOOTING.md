# TROUBLESHOOTING

Gotchas, workarounds, incompatibilities. Format: date · symptom · cause · fix.

## 2026-10-02 · Stage 0: stack gotchas (spikes `spikes/*`, details in `docs/STACK.md`)

### Build and environment
- **libsignal and spqr need `protoc`.** Both build.rs files call `prost_build::compile_protos`. Without `protobuf-compiler`
  the build fails. The build server has protoc 3.21.12.
- **libsignal as a git dependency.** `[patch.crates-io]` from the libsignal workspace (their `boring` fork) does not apply
  to us: patches only take effect in the root workspace. `libsignal-protocol` does not need boring and builds without it.
  Their `rust-toolchain` 1.98.1 is also ignored for a git dependency — we built with 1.99.0, all fine.
- **A spike inside the project tree.** Without its own `[workspace]` in the spike's `Cargo.toml`, cargo looks for the
  parent workspace and complains. Every spike has an empty `[workspace]`, and the root has `exclude = ["spikes"]`. The
  root `rust-toolchain.toml` applies to the spikes too — that is intended.
- **Size.** The shared `spikes/target` weighs 5.7 GB (debug) after all spikes. The `spike-combined` binary in debug is
  338 MB. The directory is in `.gitignore`.

### iroh 1.3
- **ProtocolHandler serves one bi-stream and hangs on the second.** If `accept` calls `accept_bi` once and then waits
  for `closed()`, nobody accepts the client's second `open_bi`: a 64 KiB echo hung until the timeout (we concluded that
  "the relay doesn't work"). Fix: a loop `while let Ok(..) = connection.accept_bi().await`.
- **`presets::N0` publishes addresses.** It contains PkarrPublisher, PkarrResolver and DnsAddressLookup with n0's servers.
  SPEC §4 needs `presets::Minimal` with an explicit `relay_mode`.
- **iroh's TLS is not post-quantum by default.** The default features give `tls-ring`, which has only X25519. PQ: the
  feature `tls-aws-lc-rs`, your own `CryptoProvider` with `kx_groups = [X25519MLKEM768, X25519]`, passed to
  `Builder::crypto_provider`.
- **PQ-only breaks the n0 relay.** With `kx_groups = [X25519MLKEM768]`, `endpoint.online()` never completes: TLS to
  the relay goes through the same provider, and the n0 relay does not support PQ. Fix: prefer-PQ mode (see above).
- **Relay+IP reveals all local addresses.** Even when dialing only by relay URL, iroh used hole punching and chose a path
  to the build server's Tailscale interface address. Levels 1–2 (the contact must not see the IP) need an endpoint with
  `clear_ip_transports()`.
- **Log noise in relay-only mode.** With `clear_ip_transports`, iroh logs DEBUG
  `failed to initiate NAT traversal: Not enough addresses` every 100 ms. Harmless, but keep this level out of the daemon's
  logs.
- **An accept-list over direct UDP is not "no response".** The client ID arrives only in TLS (raw public key in the
  certificate). `after_handshake` → `Reject` sends CONNECTION_CLOSE (403) after ServerHello has already gone out. A
  silent drop is possible only via the relay (`IncomingFilterOutcome::Ignore` on `IncomingAddr::Relay { endpoint_id }`).
- **`Incoming::decrypt().alpns()` is unreliable.** It is "best-effort" and does not parse a ClientHello spread over several
  Initial packets. In the spike it failed to parse even a paired client's classic ClientHello, and with a PQ share
  (1184 B) it never succeeded. A filter on a secret in ALPN is not viable.
- **ERROR "Endpoint dropped without calling `Endpoint::close`".** Always call `endpoint.close().await` or
  `router.shutdown().await` before drop.
- **The HandshakeData type.** To learn the negotiated group (`negotiated_key_exchange_group`) you need to downcast
  `conn.handshake_data()` to `noq::crypto::rustls::HandshakeData`, i.e. a direct dependency `noq = "=1.3.0"`
  (iroh does not re-export this type).
- **noq's version is not iroh's version (iroh 1.4).** iroh 1.4.1 depends on noq 1.4.0; there is no noq 1.4.1, so
  bumping both pins to the same number fails with "failed to select a version for `noq = \"=1.4.1\"`". Take noq's
  version from iroh's own dependency (`cargo tree -i noq`). Keep exactly one noq in the tree (`cargo tree -d`): a second
  version would make the `HandshakeData` downcast return `None`, and the TLS group would go unreported without an error.
- **The rustls advisory chain does not end at rustls.** Moving to iroh 1.4.1 brings rustls 0.23.46 (RUSTSEC-2026-0346…
  0349), but `cargo update -p iroh` leaves rustls-webpki 0.103.15 and webpki-roots/webpki-root-certs 1.0.9, which are
  still under RUSTSEC-2026-0381…0383. Update them explicitly: `cargo update -p rustls-webpki@0.103.15 -p webpki-roots -p
  webpki-root-certs`. Without `cargo audit` on the host, check the lock against a shallow clone of
  `rustsec/advisory-db` (the `[versions]` ranges of each advisory).
- **The rest of the advisory list for preview.11 (wasmtime, zip, ctutils, tokio).** wasmtime comes only through
  `yara-x`, whose `^45.0.3` requirement keeps it below every fixed line: `cargo update -p wasmtime` changes nothing,
  move `yara-x` to 1.22.1 (wasmtime/pulley 48.0.7, RUSTSEC-2026-0222…0379; the 0379 fix is 48.0.7, not 48.0.6). The
  eight wasmtime advisories are about WASI, the component model and Cranelift on aarch64, none of which the worker uses
  (core modules in Pulley, rules are ours), but the lock still has to be clean. zip 9 is a major release: `file_names()`
  now yields `ZipResult<Cow<str>>` (names are decoded on demand), so `.map(str::to_string)` stops compiling
  (`cdr.rs`, skip names that do not decode). The zip advisories (0367…0369) are about `extract()`, which we never call.
  ctutils 0.4.6 and tokio ≥ 1.53.3 come with `cargo update -p ctutils -p tokio`; from 1.53.3 tokio deprecates
  `AsyncFd::new` (0386), which would fail `clippy -D warnings` if we used it (we do not).

### iroh-blobs 0.103
- **Double store shutdown.** `Router::shutdown()` calls `BlobsProtocol::shutdown()`, which shuts the store down itself.
  A second `store.shutdown()` → `Oneshot recv error: Sender closed`. Call it once.
- **Corrupted data at the provider.** The provider's FsStore verifies data on read and resets the stream
  (`stream reset … error 3`). The receiver is left with a verified prefix; the blob is incomplete. The spike did not test
  the "malicious provider sends garbage" scenario.
- **The store keeps what we pass to it in plaintext.** So we send an already encrypted (STREAM) file through iroh-blobs;
  otherwise the quarantine would be unencrypted.

### libsignal / SPQR
- **There is no public API for "a session from my own secret".** The `Handshake` trait is `pub(crate)`;
  `initialize_*_session_record` accept only PQXDH parameters. Solution: bundles inside a verified channel (DECISIONS D-8).
- **Hidden aliases.** `AliceSignalProtocolParameters` / `BobSignalProtocolParameters` are `#[doc(hidden)]`, kept
  "for the transition period". Use `libsignal_protocol::pqxdh::{InitiatorParameters, RecipientParameters}` or
  `process_prekey_bundle`.
- **`Kyber1024` ≠ ML-KEM-1024.** `kem::KeyType::Kyber1024` is `libcrux_ml_kem::kyber1024`, pre-standard Kyber.
  FIPS 203 is `KeyType::MLKEM1024`, available only with the `mlkem1024` feature of `libsignal-protocol`.
- **How to see that SPQR works.** `SessionRecord::current_pq_state()` + `spqr::current_version()` →
  `NegotiationComplete(V1)`. The epoch number comes from the `SignalMessage::pq_ratchet()` header:
  `[version=1][epoch varint][index varint][type][chunk]` (spqr v1.6.0, `src/v1/chunked/states/serialize.rs`).
- **The first message is large.** `PreKeySignalMessage` is 1759 B (KEM ciphertext 1568 B). After that, 105 B for a short
  text. Session state is 2–6 KB; the SPQR part grows to ~4.8 KB.

### libcrux (hybrid KEM, ML-DSA)
- **libcrux-kem 0.0.9 + spqr do not compile in one tree.** `libcrux-ml-kem 0.0.10` with the features `incremental`
  (spqr) and `rand` (libcrux-kem, via `default-no-std`) fails: `unresolved import rand::RngCore / rand::TryRngCore`
  (`src/mlkem.rs:161, 372`). Already fixed in main (`cryspen/libcrux@c938b46`, `use ::rand::TryCryptoRng`), but not
  released. Patching only `libcrux-ml-kem` to main breaks `libcrux-kem 0.0.9`
  (`no associated function keygen/encaps/decaps for MlKem768`). Patching both builds, but with duplicates of every
  libcrux-* crate (registry + git). Reproduction: `spikes/combined/variants.sh`.
- **`PublicKey::decode(Algorithm::XWingKemDraft06, …)` panics on short input.** It does `bytes[0..1184]` without a length
  check. Check `len == 1216` before decode. `Ct::decode` on short input correctly returns `InvalidCiphertext`.
- **ML-KEM implicit rejection.** A tampered ciphertext (in the ML-KEM or the X25519 part) yields `Ok` with a different
  secret, not an error. Key confirmation (a MAC over the transcript) during pairing is mandatory.
- **`X25519MlKem768Draft00` is not a combiner.** It returns two separate secrets; gluing them together ourselves would be
  homemade cryptography. Use only X-Wing.
- **ML-DSA: the caller supplies the randomness.** `ml_dsa_65::generate_key_pair([u8; 32])`,
  `sign(.., randomness: [u8; 32])` — take it from the OS RNG. An ML-DSA-65 signature is 3309 B, the verification key
  1952 B.

### rmcp 3.5
- **`#[tool_handler]` without an argument** uses `Self::tool_router()`, and the `tool_router` field stays unused
  (warning). Write `#[tool_handler(router = self.tool_router)]`.
- **The default serverInfo is `{"name":"rmcp","version":"3.5.0"}`.** It reveals the implementation. Provide your own
  `get_info()`.
- **stdout is the protocol.** Any `println!` in a stdio server breaks JSON-RPC; logs go to stderr only.

### rusqlite + SQLCipher
- **SQLCipher writes errors to stderr.** Wrong key → `ERROR CORE sqlcipher_page_cipher: hmac check failed for pgno=1`.
  Per SPEC §13 logs are under our control: configure `PRAGMA cipher_log_level` / `cipher_log` or redirect them.
- **Raw key.** `PRAGMA key = "x'<64 hex>'"` — no PBKDF inside SQLCipher. With a string password SQLCipher runs its own
  PBKDF2 on every open.
- **The first build of vendored OpenSSL takes about 50 s** (perl + make). Needs `perl`.

### biscuit-auth 6
- **No holder-of-key.** Solved with a third-party block with PoP (DECISIONS D-11). A PoP block transplanted onto another
  token is rejected already at `append_third_party` (`error deserializing or verifying the token`).
- **Old dependencies.** `ed25519-dalek 2`, `curve25519-dalek 4`, `rand 0.8` — second copies next to the versions used by
  iroh and libsignal. Last release 2025-07-16. A future-incompat warning from `proc-macro-error2 v2.0.1`.
- **Path traversal is not the token's job.** `"../etc/passwd".starts_with("shared/")` is false, so the denial here is
  accidental. The daemon normalizes paths before calling the authorizer.

### Building the stack together (`spikes/combined`)
- 580 packages. Duplicate crypto crates: ed25519-dalek 2.2+3.0, curve25519-dalek 4.1+5.0,
  sha2 0.9+0.10+0.11, rand 0.8+0.9+0.10, rand_core 0.6+0.9+0.10, getrandom 0.2+0.3+0.4, digest 0.9+0.10+0.11,
  hmac 0.12+0.13, aes 0.8+0.9, signature 2+3. That means a larger audit surface and `cargo-deny multiple-versions` warnings.

---

## 2026-10-02 · v0.1, slice 1 "link": implementation gotchas (decision details in DECISIONS D-13…D-24)

### Pairing and QUIC
- **At the end of pairing both sides waited 5 s for each other.** Symptom: `pairing_ms` ≈ 5100 on a fast machine.
  Cause: both A (sent M8) and B (received M8) called `finish()` = "close sending and wait until the other side closes"
  with a 5 s timeout. Fix: whoever **received** the last message closes the connection immediately
  (`Chan::close_now`); whoever **sent** it waits for the close (so the last message is guaranteed to have arrived).
  Check: `cargo test -p x-cli --test link -- --nocapture` → `PAIRING: … pairing_ms A≈20 B≈110`.
- **`read_exact` is not cancel-safe.** You cannot wait for a frame from the peer and for owner input at the same time
  with `tokio::select!`: if the input wins, the partly read frame is lost and the stream desynchronizes. Fix: a separate
  pairing frame reader task puts complete messages into an `mpsc`, and `select!` waits on `mpsc::recv` (which is
  cancel-safe).
- **Pairing via relay took ~4 s.** Four endpoints (a pairwise and an ephemeral one on each side) waited for `online()` at
  the relay one after another (~1 s each). Fix: each side brings up both of its endpoints in parallel (`tokio::join!`).
- **A burned invite answers instantly over localhost but with a timeout over the relay.** Locally a closed UDP port
  produces ICMP and connect fails immediately; over the relay there is no answer, and `x join` waits for
  `--connect-timeout` (20 s by default). Tests use `--connect-timeout 5s`. Both outcomes are `invite_unavailable`.
- **While a pairing session is running, other connections to the invite would hang until timeout.** Fix: `accept()` runs
  in parallel with the session, and everything extra gets `Incoming::refuse()` — a refusal without a TLS handshake and
  without any crypto work.

### libsignal
- **`InMemSignalProtocolStore` is TOFU.** `is_trusted_identity` returns `true` for an unknown address. During pairing the
  contact's identity from the transcript is written with `save_identity` **before** any operations, so a substitution is
  rejected (`untrusted identity`, unit test `bundle_with_foreign_identity_is_rejected`). The database-backed store does
  not accept an unpinned key at all and does not allow a pinned one to be replaced (`DbIdentity::save_identity`).
- **libsignal addresses go into PreKey messages.** `message_encrypt` puts the (local, remote) pair into
  `PreKeySignalMessage` (address binding). The names on the two sides must mirror each other: `hex(link_id).a` on A and
  `.b` on B (PROTOCOL §10).
- **API v0.103.1:** `SignedPreKeyRecord::new` / `KyberPreKeyRecord::new` are methods of the `GenericSignedPreKey` trait
  (import the trait); `PublicKey::deserialize` and `calculate_signature` return `CurveError`, not
  `SignalProtocolError` — `?` into a function returning `SignalProtocolError` does not work, so we convert manually.
  `IdentityKeyPair` is `Copy` (clippy `clone_on_copy`).
- **An unacknowledged session ages out.** Until Alice gets a reply from Bob, all her messages are PreKey messages, the
  session counts as "unacknowledged", and after `MAX_UNACKNOWLEDGED_SESSION_AGE` it stops encrypting. That is why
  pairing has M8: A answers B with an encrypted `L_ACK ‖ TH`, and B's session is acknowledged before activation. After
  pairing, prekeys are not stored, and PreKey messages over the link are rejected (`NoPreKeys`).
- **How to see facts rather than code:** `x --json contacts` → `e2e.session_version` (from `SessionRecord`),
  `e2e.pq_ratchet` (`spqr::current_version` over `current_pq_state()`), `e2e.last_rx_version` and `last_rx_pq_len`
  (header of the last received message); `transport.last_kx_group` is `negotiated_key_exchange_group` from rustls. For
  SPQR to reach `NegotiationComplete(V1)`, messages must flow in both directions.

### Formats, serde, CBOR
- **`ciborium::from_reader` silently ignores trailing data.** `from_cbor` now reads through `&mut &[u8]` and rejects
  extra bytes (test `trailing_bytes_are_rejected`).
- **`#[serde(tag = "cmd", deny_unknown_fields)]` does not apply to unit variants.** `{"cmd":"lock","x":1}` was accepted.
  Fix: variants without fields are declared as `Lock {}`.
- **Message ID without CBOR canonicalization.** Exactly the transmitted `core` bytes are hashed (envelope =
  `{id, core, auth}`), so an independent implementation does not need to reproduce the CBOR key order (D-20).

### Daemon, files, tests
- **SQLite creates `-wal`/`-shm` with mode 0644.** The 0700 data directory protected them, but that is not enough on a
  multi-user machine. Fix: `xd` sets `umask 077` before opening anything; the test `crates/xd/tests/daemon.rs` checks
  that no file in the directory has group or other permissions.
- **`CARGO_BIN_EXE_<name>` exists only for binaries of your own package.** Integration tests in `x-cli` take `xd` from
  the same directory as `x`. That works with `cargo test` from the workspace root (the `xd` package has its own
  integration tests, so cargo builds the `xd` binary). For `cargo test -p x-cli` in a clean target, run
  `cargo build -p xd` first.
- **Unix socket path ≤ 108 bytes.** A deeply nested scratch directory is too long for `…/xd.sock`; tests create their
  directories with `tempfile` under `/tmp` (the equivalent of `mktemp`).
- **Dependency cryptography is slow in debug (-O0)** (Argon2id 64 MiB, ML-KEM, ML-DSA; in the spike, PQXDH in debug took
  33–39 ms). To keep tests fast, `[profile.dev.package."*"] opt-level = 2` was set in advance in the root
  `Cargo.toml` (our own code stays debug, with debug assertions). With it, `x init` (Argon2id 64 MiB, t = 3) ≈ 0.2 s.
  The variant without the profile was not measured in this slice.
- **Logs.** By default `XD_LOG=warn,x_core=info,xd=info`: libsignal INFO lines (addresses, base key) do not reach the log.
  Message text and keys are not logged anywhere; the `Debug` output of requests with a password/code and of the invite
  link is redacted.

## 2026-10-02 · Formal model of pairing (ProVerif, `formal/`): installation and modeling gotchas

### Installation without system packages
- **No OCaml, and we don't install system packages on the build host.** The opam 2.6.0 binary from GitHub releases →
  `~/.local/bin/opam`; `OPAMROOTISOK=1 opam init --bare --disable-sandboxing` (bubblewrap is not installed, and opam's
  sandbox does not work without it); `opam switch create pv ocaml-base-compiler.4.14.2` — about 4 minutes on
  16 cores. Everything lives in `~/.opam`.
- **`opam install proverif` pulls in `lablgtk` → GTK2 → system packages.** Build from source instead: `proverif2.05.tar.gz`
  (sha256 `4871f53c…eabc4`, matches opam), `./build -nointeract` — needs only `ocamlopt`, no ocamlfind and no GTK;
  the interactive simulator is not built and not needed. Binary: `~/.local/opt/proverif2.05/proverif`, symlink in
  `~/.local/bin/proverif`. To check: `proverif --help | head -1` → `Proverif 2.05`.

### Memory and time
- **The first version of the model ate 8 GB in 2 minutes and did not finish** (the build server had 5 GB left — the
  process was killed manually). Cause: a "weak SAS" with guessing over 7 fields, a TH of 9 arguments,
  `preciseActions = true` (names drag along all previous inputs). Fix: the TH fields are grouped
  (`th(pre, N_A, N_B, pp)`), guessing only over `N_A`/`N_B` (the argument why that suffices is in `formal/README.md`),
  `preciseActions = trueWithoutArgsInNames`. **Every ProVerif run only under `ulimit -v` and `timeout`** (this is what
  `formal/run.sh` does: 6 GB, 3600 s).
- **Every Diffie–Hellman equation multiplies the time.** PQXDH with DH1+DH2+KEM: query Q2 did not finish in 10 min and
  2 GB; with DH1+KEM the whole main scenario takes 1.5 min. The model keeps DH1 and ML-KEM: the omitted DH2–DH4 are only
  extra obstacles for the attacker, so what is proven also holds for full PQXDH (`formal/README.md`, "Assumptions"
  item 8). The ephemeral X25519 in TLS is modeled as a KEM (`dhpk`/`dhct`/`dhdec`) without an equation: with the
  equation, the `tls` scenario produced no result at all in 4 minutes (2.4 GB, stopped).
- **A revealed nonce inflates saturation.** The "no commitment" negative controls on the full model did not saturate in
  7 minutes (25 thousand clauses and growing): an attacker who knows `N_B` in advance keeps generating new guessing and
  key terms. With the processes pruned after the checked events (the controls don't need libsignal), the attack is found in
  0.3 s.
- **Don't kill runs with `pkill -f <pattern>` from the same shell command.** The pattern ("run.sh", "xargs -P") matches
  the command line of the shell itself — the shell kills itself (exit 144), and the rest of the command does not run.
  Kill by PID: `ps -C proverif -o pid=,args=`, then `kill <pid>`.

### ProVerif syntax and semantics
- **`*)` inside a comment closes it.** The comment "(functions forge_*)" produced a "Syntax error" on the next line.
  Do not write `*)` in comments, and `(*` only in pairs.
- **A destructor (`reduc`) cannot be used in a query** ("function sasOf is defined by "reduc"…"). A value that has to
  be compared in a query is passed as an event argument (`A_ShowSAS(t, code)`).
- **Output to a private channel is synchronous.** `out(voiceAB, code); P` blocks `P` until someone receives the message;
  this does not affect proofs, but ProVerif could not reconstruct the attack trace ("cannot be proved" instead of
  "false"). The human channel is modeled asynchronously: `(out(voiceAB, code) | P)` — the node does not wait for the
  human to finish speaking.
- **`run.sh` counts `EXPECT` markers over the whole scenario file, including prose in comments.** The word "EXPECT" in a
  scenario description (`replay_tnull.pv`, v1) gave "3 queries, 6 markers" while the results were correct. In prose,
  write "expected".
- **A voice channel shared by all of the owner's invites (v1) doubled the time of the main scenario** (≈1.5 → ≈3 min)
  and of `neg_nopin` (≈1 → ≈4 min): ProVerif enumerates which invite receives the "match". Memory did not grow.
- **Without `preciseActions`, commit-then-reveal cannot be proved** ("cannot be proved"): ProVerif's abstraction allows
  one B session to receive two different M2 messages — learn `N_B` from the first and fit `N_A'` in the second. With
  `preciseActions` (an input of one session receives exactly one message) the result is `true`; on a minimal prototype
  in 0.02 s.

## 2026-10-02 · v0.1, slice 2 "agents and rights": implementation gotchas (decisions in DECISIONS D-27…D-37)

### Agents, processes, MCP
- **Claude Code runs every Bash tool command in a new `bash`** (`setsid`, no tty, the parent is the claude process;
  checked: the shell PID differs on every call). Binding a token to "the agent's process" by client PID is impossible —
  every `x` is a new process. Fix: `x mcp` binds the token to its **parent** (the MCP host), and the daemon accepts
  descendants of the host (D-28). To check: `echo $$; cat /proc/$$/stat | cut -d' ' -f1-8` twice in a row from the agent.
- **A test as the MCP host.** If a test starts `x mcp` itself, the test process becomes the host — and the daemon then
  treats all further owner commands from the test as agent commands (`forced`). Fix: `x mcp` under
  `sh -c '"$X_BIN" … mcp; e=$?; exit $e'` (`tests/common/mod.rs`, `Mcp::start`): the host is a separate `sh`, which dies
  together with `x mcp`.
- **`sh -c 'cmd'` execs the last simple command** (dash and bash): the parent of `cmd` is then the caller, not `sh`.
  The tail `; e=$?; exit $e` disables this optimization.
- **rmcp 3.5 + schemars via the re-export:** `#[derive(JsonSchema)] #[schemars(crate = "rmcp::schemars")]` — no separate
  `schemars` dependency is needed. A tool error is returned with `CallToolResult::structured_error` (the client sees
  `isError: true` and JSON); the protocol error `-32602 tool not found` is for a nonexistent tool.

### Tests, build
- **`cargo test -p x-cli` picks up a stale `xd`** (a repeat of the slice 1 gotcha; it cost one false failure): after
  x-core changes run `cargo build -p xd` first, or go straight to `cargo test --workspace`.
- **Levels 1–2 cannot be created without a relay** (relay only, SPEC §4). Fix: a local iroh relay in a test thread
  (`iroh-relay` 1.3, feature `server`; `ServerConfig` is `#[non_exhaustive]`, hence `Default` + field assignment),
  nodes with `--relay http://127.0.0.1:PORT`. iroh accepts an HTTP relay, `online()` completes, level 2 pairing ≈ 0.6 s.
- **clap took the text `-----BEGIN OPENSSH PRIVATE KEY-----` for a flag** → `x send` failed with a parse error, and the
  scanner test got an empty stdout. Fix: `#[arg(allow_hyphen_values = true)]` on the message text.
- **`watch::Ref` inside `tokio::select!` makes the future non-`Send`** (`tokio::spawn` does not compile). Fix: wait in
  `async { rx.wait_for(..).await.map(|v| v.clone()) }` — the `Ref` does not live across the `await`.
- **clippy `result_large_err`**: `ApprovalInfo` inside the CLI error and `ErrorBody` inflated `Err` to 392 bytes → `Box`.

### Policy
- **The secret scanner did not see `OPENAI_API_KEY=sk-…`**: the whole word started with the variable name. Fix: values
  inside a word are split on `=`, `:`, `#` and checked separately.
- **Seed phrases and ordinary English.** BIP-39 contains many ordinary words (`about`, `only`, `then`, `account`…):
  11 consecutive words from the list + "then" already make 12, a false alarm in a test. The threshold is 12 consecutive
  words; the prose test is in `policy::tests`.
- **The limit burned an approval**: if the limit was counted after approve, an approved message could hit the limit
  and lose its approval. Fix: the limit is checked before approve (`RateLimiter::check`) and counted after it.
- **A closed connection stayed in the cache** — presence showed `online`. `live_conn` filters by `close_reason`, and the
  end of `serve` removes the connection from the cache only if it is the same connection (`stable_id`).

### Slice 2 security review (2026-10-02)
- **Process checks "failed open".** `is_descendant_or_self` returned "not a descendant" both at depth > 64 and when
  `/proc/<pid>` had disappeared — i.e. "owner". The reviewer obtained the owner role from an agent's process tree with a
  chain of 70 `bash` processes. Rule for any permission check: "could not check" = deny. The chain is read in full up to
  PID 1 right at accept.
- **The password was checked against a file on disk.** An agent with the same uid replaced `keystore.cbor` with its own
  and passed the "password check". The secret the password is checked against must live in the daemon's memory from the
  moment of unlock.
- **Binding the SAS code and the invite at confirmation.** A "yes" without a code confirmed whichever invite happened to
  be pending; after a failed attempt `x pairing` showed the old code. Now "yes" carries the code, and the stage resets
  on failure.
- **Scanner on a stream.** The first test failure was a `usize::MAX` overflow when slicing chunks (`i + size`); the
  second — the stream stops at the **first** finding, and its kind may differ from the kind found in the whole text
  (`KEY=` comes before the `sk-` prefix). What matters is not "the same kind" but "found, and the substance not let out".


## 2026-10-02 · v0.1, slice 3 "history and integrity": gotchas (decisions in DECISIONS D-42…D-51)

### Locks and the daemon
- **Deadlock in `x contacts`: a temporary `MutexGuard` inside a struct literal.** `ContactInfo { unread: self.db.lock()…
  .unread_count()?, history: rt.status(), … }` — the temporary `self.db.lock()` lives until the end of the **whole
  statement** `out.push(ContactInfo{…})`, and `status()` takes the same (non-reentrant) `std::sync::Mutex` again.
  Symptom: `x contacts` and the tests hang without errors, and the daemon doesn't respond even to SIGTERM (exit also
  waits for the lock). Fix: values that need the lock are computed in separate `let`s before the literal. Rule of the
  `linksync` module: lock order "DB → history/rekey/block", and never call a function that takes the DB while a
  `MutexGuard` from an expression is alive.
- **A hung test can't be killed with `pkill -f`.** The pattern `pkill -f 'target/debug/xd --data-dir /tmp/.tmp'` matches
  the command line of the shell that runs it — the shell kills itself (code 144), and the daemons remain. Fix: a pattern
  with a character class (`pgrep -f '[t]arget/debug/xd'`) or a PID; a daemon hung on a deadlock only dies with `kill -9`.
- **`cargo test -p x-cli` picks up a stale `xd`** — for the third time (slices 1, 2, 3): rekey "didn't work", but the test
  was running the `xd` from before the change. Before `cargo test -p x-cli`, run `cargo build --workspace`.

### SQLite and history
- **`||` over a BLOB in SQLite yields TEXT**: `UPDATE … SET core = core || x'00'` turned the column into text, and
  `rusqlite` answered `Invalid column type Text`. For bytes use `CAST(core || x'00' AS BLOB)` (and `substr` on a BLOB
  also goes through `CAST`).
- **Copy verification was quadratic.** The first version read the history in batches
  `WHERE (author, n, seq) > (…) ORDER BY author, n, seq LIMIT 4096`: the partial unique index (`WHERE n > 0`) is not used
  by this query, so each batch sorted the whole history. 100,000 messages took 5.4 s, 1 million — minutes. Fix: an
  index `messages(link_id, author, n, seq)` and a single pass without sorting — 1.4 s per 100,000, linear.
- **Recomputing the heads over a damaged copy is wrong**: a broken `core` doesn't yield its `parents`, so its parent
  "becomes" a head. Heads are rewritten only after a clean copy check; on damage, the location is shown.
- **Recognizing a `(link_id, author, n)` uniqueness violation**: `rusqlite` returns `ConstraintViolation` for `id` as
  well; we tell them apart by the text (`UNIQUE constraint failed: messages.link_id, messages.author, messages.n`).

### Rollback and rekey
- **After a rekey, a side blocked itself again with "rollback by numbers".** Right after a rekey the contact naturally
  has more of this side's messages (the lost ones) — the very first verification counted this as a new rollback. Fix:
  after a rekey with this contact, lagging behind on one's own messages is "recovery" (`recovering`): no block, and new
  messages wait until resending returns what was lost (otherwise their `n` would collide with the lost ones).
- **After a rekey, history verification did not start** if the queue was empty: the delivery worker wakes up, has
  "nothing to deliver" and does not connect. Fix: a `sync_requested` flag — verification as a separate reason to connect.
- **Verification failed — the queue does not go out.** Otherwise blobs encrypted with a rolled-back (but not yet
  detected) state would go out before the contact reports the rollback.
- **"Both owners confirm" does not mean "both pressed a button" but "each entered the other's code"** (D-54). First
  version: the side with the rollback accepted the reply to its own offer without a code — and the rollback flag
  `contact_numbers` is set on the contact's word, so whoever held the contact's stolen keys forced a rekey and answered
  it himself. A check for the future: for every protocol step ask "who, besides the real peer, could have sent this
  message, and what does a human confirm here".
- **A second run of `x rekey` burned its own first offer** (the contact sees "two different ones" → conflict), and so
  did a restart of the receiving side (a new reply instead of the previous one). A repeat within the window sends the same
  offer; the accepted offer and the reply are stored in the DB (`links.rekey_pending`). Rule: anything compared as
  "same / different" to raise an alarm must survive an honest repeat and a restart — otherwise the alarm is false, and
  people stop believing it.
- **A code without a commitment protects only as long as you remember all codes.** Burning codes only on conflict is not
  enough: a bundle fitted to an overheard code kept the slot even after the real offer simply expired. Remember the codes
  of all offers. The trial decryption of the reply runs in a transaction that `drop(tx)` rolls back (rusqlite defaults to
  `Rollback`): the libsignal session is not saved until the second code.

### Tests
- **Owner session and tests.** Tests run `x` without a terminal: the session is opened for the parent — the test process
  (`Node::login` after `init`/`unlock`). Raw connections from the test process itself get a `held` session
  (`Node::held_session`). The check "no session — not the owner" goes through `setsid sh -c '…'` (no terminal and a
  different parent); `setsid x …` does not work: `setsid` does an `exec`, and the parent remains the test process.
- **Confirming with "yes" in the pairing test** stopped working (F-6): the CLI in watch mode asks for the code, "yes" is
  a wrong code, `input_rejected`, the CLI asks again, and the test waits forever. The test enters the dictated code.
- **BLAKE3 and Ed25519 vectors in Python**: the standard library has neither, and the build server has `python3-venv`
  without `ensurepip` — so `python3 -m pip install --target <scratch>/pylib blake3` and `PYTHONPATH=<scratch>/pylib`
  (the system Python is not touched); Ed25519 comes from the already installed `cryptography`.

## 2026-10-02 · Visual version, stage 1 (Flutter, `apps/x_desktop`): gotchas (decisions in DECISIONS D-UI-1…D-UI-9)

### Flutter on a build host without system packages
- **Installation.** `git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter`, then
  `flutter --disable-analytics`, `flutter config --no-cli-animations`; the first run downloads the Dart SDK and the
  artifacts itself (~1 min). No apt needed. `flutter doctor` complains about GTK 3 dev and ninja — they are needed only
  for `flutter build linux`/`flutter run -d linux`, not for `flutter test` (including golden tests) and
  `flutter analyze`. We did not build the window on the build server.
- **"Woah! You appear to be trying to run flutter as root"** — a warning; it does not affect anything.
- **python3 -m venv without pip** (the host has no `python3-venv`/ensurepip). We needed fonttools to subset a font:
  download the wheel `fonttools-*-py3-none-any.whl` from PyPI, unpack it into a scratch directory and run with
  `PYTHONPATH` — no system packages.

### Golden screenshots
- **Text and icons are black rectangles.** flutter_test draws with the Ahem font by default. Cure:
  `test/flutter_test_config.dart`: read `FontManifest.json` from `rootBundle` and load every family with `FontLoader`
  (including MaterialIcons). The UI fonts are bundled in the app — the same ones are used in the tests.
- **"Tofu" squares instead of a character.** The glyph is missing from the font: `▍` (the stream cursor) is not in
  IBM Plex — the cursor is drawn by a widget; the build server has no emoji font at all — for the 10 SAS animals we
  bundle our own subset font (D-UI-6).
- **`pumpAndSettle` never finishes** with infinite animations (`CircularProgressIndicator`, a blinking cursor) — golden
  scenarios use only `pump(Duration)`.
- **PNG size.** The sign-in screen with a gradient and mountains is ~0.45 MB at DPR 1 and ~0.85 MB at DPR 1.5; regression
  tests use DPR 1, showcase frames DPR 1.5 (`showcase_test.dart`).

### Tests against a live daemon
- **Unix socket path ≤ 108 bytes.** The scratch directory path is long (~95 bytes) — `…/alice/xd.sock` does not fit.
  Test nodes live in `/tmp/xdesk-XXXX` (`Directory('/tmp').createTemp`, deleted in `tearDownAll`).
- **Uncommitted changes in `crates/`.** While slice 2 was in progress in the same working tree, `xd` could not be built
  from the working copy (unfinished code). Fix: `git archive HEAD … | tar -x` into a scratch directory with a separate
  `target` (first build 4 min, after a new commit 1.3 min); the tests take the binary from `XD_BIN`.
- **A broadcast stream loses events emitted before the subscription.** The pairing dialog emits events through a
  single-subscription `StreamController` — it buffers until the screen subscribes.
- **"Unhandled error" from a `Completer`** if nobody is awaiting the error of the dialog's result yet (the test waits for
  B, but A has already failed): an empty `onError` is attached right at creation; a later `await result` still gets the
  error.

### Layout
- **A name in the list was cut in half.** `Flexible` and `Spacer` in one row split the free space equally. Correct:
  `Expanded(Row([Flexible(name), badge]))`, then the time.

### Socket forwarding over ssh (Mac → xd on a remote server)
- **`channel 1: open failed: connect failed: open failed`**, and the sshd log shows `Received request to connect to path …, but the
  request was denied`. Cause: `AllowTcpForwarding no` in sshd also forbids forwarding unix sockets
  (`-L socket:socket`), even with `AllowStreamLocalForwarding yes`. You need `AllowTcpForwarding yes`/`local` and
  `DisableForwarding no` (the build server has exactly that: `sshd -T`). The role after forwarding is `owner`:
  SO_PEERCRED sees the sshd process of the same user.
- **`pkill -f '<pattern>'` killed its own shell** — the pattern matched the command line of the bash it was written in.
  Stop test processes by their saved PIDs.

### User journey (the window starts xd, agents, packaging) — 2026-10-02
- **Testing `x mcp` from the test process turns the test itself into an agent.** `x mcp` binds the token to its parent
  (D-28): if the parent is `flutter_tester`, the daemon treats the test's owner connections as agent connections too.
  Start it via `bash -c '"$X" mcp; exit $?'` (not `exec`: the anchor would then be bash, and the test is its ancestor,
  not a descendant).
- **An assistant with label 5 "doesn't reply" to a level 3 contact.** Not a bug: no write down (SPEC §9) — the agent's
  `x send` exits with code 77, and an approve request `no_write_down:local_5>contact_3` is created. The test of the bot
  snippet uses label 3.
- **Golden tests on macOS.** The screenshots are rendered on Linux; on macOS fonts rasterize differently — so
  `release-macos.yml` runs only the widget and host tests, and the golden tests run in `release-linux.yml`.
- **We don't touch the real user systemd on the build server.** `install.sh` was checked with `--no-systemd` /
  `--no-start --unit-dir` in a temporary HOME (the unit with `systemd-analyze verify`); the daemon was started manually
  from `/tmp`.
- **Signing the .dmg without a Developer ID.** Hardened runtime enables library validation: with an ad-hoc signature
  `Flutter.framework` has no Team ID, and an app with `--options runtime` would not load it (dyld "mapped file has no
  Team ID"; according to Apple's documentation — to be checked on a Mac). So the runtime is only on `xd` and `x` in
  `Contents/Helpers`, and `x.app` itself has a plain ad-hoc signature (packaging/macos/build-dmg.sh).
- **Checking compilation for darwin from Linux.** `rustup target add aarch64-apple-darwin` +
  `cargo check --target aarch64-apple-darwin -p x-proto -p x-cli` works without the SDK (no C dependencies): x-proto is
  clean, x-cli only hits `set_dumpable_behavior` (PORTABILITY M-2). `xd`/`x-core` can't be checked this way (aws-lc and
  OpenSSL need Apple's SDK) — **now they can**: `tools/check-darwin.sh`, see the "macOS portability of the core" section
  below.

## 2026-10-02 · macOS portability of the core (`crates/x-sys`, `procinfo`; decisions in DECISIONS D-P-1…D-P-7)

### Checking without a Mac
- **`cargo check --target aarch64-apple-darwin -p x-core` fails before it reaches our code** — in build scripts: `ring`
  and `blake3` (`cc: error: unrecognized command-line option '-arch'` — the system gcc), `aws-lc-sys` (no SDK),
  `openssl-sys` (`openssl-src` builds OpenSSL for darwin), and after them `libsqlite3-sys`
  (`couldn't find file …/out/bindgen.rs`). Fix: `tools/check-darwin.sh` — overriding build scripts via
  `[target.<target>.<links>]` (`tools/darwin-check.toml`), `--features blake3/pure`, prebuilt SQLCipher bindings in
  OUT_DIR (the script places them itself based on the error text and retries). `aws-lc-rs` requires
  `DEP_AWS_LC_*_INCLUDE` ("missing DEP_AWS_LC_ include") — that is why the override has `include`. To check:
  `tools/check-darwin.sh` → `OK: clippy aarch64-apple-darwin x86_64-apple-darwin` (and with `--release`: the
  `PT_DENY_ATTACH` branch exists only there). The keys `aws_lc_0_45_0`, `ring_core_0_17_14_` are the `links` field;
  update them when these crates are updated.
- **Only the darwin check found this bug:** the closure `|p: Option<&Path>| … .to_str()` in the macOS branch of
  `procinfo` — "lifetime may not live long enough" (no lifetime relation between the closure's input and output is
  inferred). The Linux build does not compile this code at all. Fix: a nested `fn`. Takeaway: check the cfg branch of the
  other OS with `check-darwin.sh` before committing.
- **x-files under darwin** (its own workspace until stage B): with the same override and
  `--no-default-features --features sandbox-bin,blake3/pure`, clippy `-D warnings` is clean (after two `cfg` fixes in
  `worker.rs`: `unused_mut`, an unused `with_seccomp` outside Linux). With the `yara` feature, `wasmtime` builds a C
  helper (`helpers.c`) with the system gcc (which does not know `-arch`), and clang without the SDK can't find the
  headers (`bits/libc-header-start.h`). **Solved after the merge with stage B:** `tools/check-darwin.sh` sets
  `CC_<target>=clang` and `CFLAGS_<target>=-ffreestanding -isystem <stub>` with a stub `stdlib.h`
  (`#include <stddef.h>`: the helper only needs `NULL`) — x-files is checked with all features.
- **`check-darwin.sh` silently exited with code 1** without a message: `grep` without a match returns 1, and under
  `set -euo pipefail` the substitution `$(grep … | head | sed)` aborts the script before it shows cargo's error. Fix:
  `|| true` on the `grep`. Takeaway: in scripts with `pipefail`, a search that "may find nothing" always gets `|| true`.
- **YAML: `#` in a GitHub Actions step name** after a space starts a comment: "… they #[ignore])" was cut to "… they".
  Put names containing `#` in quotes. To check:
  `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release-macos.yml'))"`.

### Processes on macOS (assumptions checked by CI — `FACT` in the `core` job log)
- **`PROC_PIDTBSDINFO` for a process of another uid gives `EPERM`** (XNU `proc_info.c`, `CHECK_SAME_USER`), and the chain
  of `x` in Terminal.app goes through the root processes `login` and `launchd`. So the chain uses
  `PROC_PIDT_SHORTBSDINFO` + `PROC_PIDUNIQIDENTIFIERINFO` (no uid check); full information (`e_tdev`) only for one's own
  uid. Test `other_uid_processes_are_readable`.
- **There is no start time with `/proc` precision** — `p_uniqueid` is used instead (64-bit, not reused until reboot);
  `UNIQIDENTIFIERINFO` also contains the parent's `p_puniqueid` — a "same parent" check that Linux doesn't have. `libc`
  has neither the constant 17 nor the struct (56 bytes) — both are declared in `x-sys` with a size check.
- **tokio's `peer_cred().pid()` on macOS is `LOCAL_PEEREPID`** (the last process that worked with the socket), without a
  PID version. The client chain is taken from the audit token (`LOCAL_PEERTOKEN`: `val[5]` is the PID, `val[7]` is
  `pidversion`) with a check against `p_idversion`. Token not read — no chain — deny (if there are bound agents).
- **A traced process** (`PROC_FLAG_TRACED`) is reparented by XNU to the debugger — its chain is not the real one:
  `ancestry` → `None`. But `is_alive` does not check tracing: otherwise an agent that attaches a debugger to its host
  would "end" the binding.
- **`/bin/sh` on macOS is a shim** (`/private/var/select/sh`) that starts bash via exec: same PID, `comm` = `bash` —
  **confirmed** by the first run (`bound_to: "67095 bash"`, 2026-10-02). Tests check the anchor by PID, not by name
  (D-62). `tools/mcp_smoke.py` also accepts a `sh` child as the host, just in case.
- **`PT_DENY_ATTACH` only in release**: the kernel terminates a process that is already under a debugger when it makes
  this call (`ENOTSUP`); debug builds don't have it, otherwise a developer couldn't debug `xd`. The barrier against
  memory reads is the hardened runtime at signing, not this call.

### Data and environment
- **The window from the Dock and `xd` from a terminal can disagree about the data directory**: apps started by launchd
  don't see variables from `.zshrc` (`XDG_DATA_HOME`, `X_DATA_DIR`). By default both use `~/.local/share/x` (D-P-5); if a
  variable is needed — `launchctl setenv X_DATA_DIR …` (apps see it too) or an explicit `--socket` for `x`.
- **`sun_path` on macOS is 104 bytes** (Linux: 108): the socket path must be ≤ 103 bytes, otherwise an error before
  `bind` with a hint (M-14). The tests' temporary directories `/var/folders/…/T/…` fit (≈ 75 bytes);
  `tools/mcp_smoke.py` uses `/tmp`.
- **The soft `RLIMIT_NOFILE` on macOS is 256** (= `MAX_CONNECTIONS`): `xd` raises it to `min(hard, 10240)`.
- **SQLite on macOS without `fullfsync` is not safe against power loss** (`fsync` does not flush the disk cache):
  `PRAGMA fullfsync` and `checkpoint_fullfsync` under `target_vendor = "apple"`. Commit latency is to be measured on a Mac.

## 2026-10-02 · v0.1, slice 4 "files and quarantine", stage A (`crates/x-files`; decisions in DECISIONS D-F-1…D-F-12)

### Build
- **STREAM ran at 7 MB/s in debug.** Symptom: 64 MiB took 9 s to encrypt with `opt-level = 2` for all dependencies.
  Cause: `EncryptorBE32<ChaCha20Poly1305>` is generic, so the cipher code is instantiated in **our** crate and built
  with `-O0`. Fix: `[profile.dev.package.x-files] opt-level = 2` (116 ms per 64 MiB). Check:
  `cargo run --example bench_crypt`. In stage B the same has to go into the root `Cargo.toml`.
- **Working tree shared with slice 3.** A crate in the root workspace would share `target` (build lock) and break slice
  3's `cargo test` while it was unfinished. A separate `[workspace]` + `CARGO_TARGET_DIR=target/x-files`; the core is a
  git revision of this same repository (`x-core = { git = "file://<repository path>", rev = … }`), so that slice 3's
  changes in the working tree didn't break our build.

### iroh-blobs 0.103
- **`EventMask.push/get_many/observe` are not read.** According to the code of `provider/events.rs::request()`, all
  request kinds are decided by `mask.get`: the default mask does **not** forbid push into our store (the stock push
  client currently aborts by itself — the server calls `writer.sync()` after the client has called `recv.stop` — but
  that is an accident, not a policy). Fix: `get = Intercept` and an explicit `Err(Permission)` for push/get_many/observe
  in the interceptor (`blobs.rs`), test `only_offered_whole_blobs_are_served_push_observe_and_hashseq_are_refused`. Not
  reproduced with a separate client that omits `recv.stop` (we would have had to write the push protocol by hand).
- **The push client returns `Ok` before the server's response**, and its statistics are always zero. Push can only be
  judged by the receiver's store (the test polls `has()` for 2 s).
- **Every `FsStore` starts its own multi-threaded tokio runtime** (a thread per core: 16 threads on the build server).
  So a per-link store (SPEC §10) is opened for the duration of transfers and closed when idle (stage B), not kept open
  for all links.
- **`Router::shutdown` closes the store** (`BlobsProtocol::shutdown`) — a second `store.shutdown()` returns an error
  (known since the spike).
- **A blob can't be deleted directly** (`delete` is `pub(crate)`; there is only tag-based garbage collection). Rejecting
  a file = erasing the secret (the quarantine record) + removing the tags; the ciphertext is useless without the key.

### Sandbox
- **`RLIMIT_FSIZE = 0` kills the worker (SIGXFSZ) if stdout is a file.** Running `x-files-sandbox selftest …` manually
  with output to a file (including when a tool captures the output) fails with "File size limit exceeded". The daemon
  passes a pipe, where the limit doesn't apply. Manual check: `x-files-sandbox selftest read_file | cat`.
- **The error code shows the layer.** With seccomp, `open` → `EPERM` (allowlist); with Landlock only
  (`selftest-landlock-only`) → `EACCES`. Sockets, `execve`, threads → the process is killed with SIGSYS (31) — the
  probe prints nothing, the answer is the signal.
- **`abort()` without `tgkill` gives SIGSEGV instead of SIGABRT** (the out-of-memory message was printed, and the process
  died with 139). `tgkill` is allowed only for one's own PID (a condition on the argument).
- **YARA-X and seccomp.** Without the `pulley` feature, wasmtime generates machine code (it needs `mmap/mprotect` with
  `PROT_EXEC`, which the filter forbids). With `pulley` it is an interpreter, and no JIT is needed.
  `Scanner::set_timeout` starts a timer thread (`clone3` → SIGSYS) — don't call it; time is limited by `RLIMIT_CPU` and
  the daemon's timeout.
- **Landlock on kernel 6.8 is `partial`, ABI 4**: ABI 6 is requested (scoping of signals and abstract sockets from 6.12,
  `IoctlDev` from 6.10). FS and TCP are fully closed; signals to other processes are blocked by seccomp
  (`kill`/`tgkill` are not in the allowlist).

### File parsing
- **quick-xml 0.42:** names are `&str` (not `&[u8]`), `BytesText` is already a string (`Deref<Target = str>`), entity
  references are separate `GeneralRef` events (`resolve_char_ref` + the built-in `&amp;` and the like); DTD entities are
  not expanded.
- **hayro:** glyph space is 1000 units per em (`glyph_transform` = size × 0.001); spaces between words are reconstructed
  from the glyph width `OutlineGlyph::advance_width()`, otherwise the text comes out as "H e l l o".
  `Page::initial_transform` returns its own `Transform` — convert it to `kurbo::Affine` with `TransformExt::to_kurbo()`.
- **PngSuite `xlfn0g04.png` passed as "clean":** a broken signature → type "unknown", and the unknown type had neither an
  extension check nor a finding. Now the extension is checked against the expected type (`.png` but not a PNG inside is
  a risk), and an unknown type is always "suspicious".

### After the stage A security review (2026-10-02)
- **iroh-blobs 0.103: a blob can't be deleted either directly or by a one-off garbage collection** — `Blobs::delete` and
  `store::gc::gc_run_once` are not public. Only periodic collection works:
  `FsStore::load_with_opts(dir/blobs.db, Options { gc: Some(GcConfig { interval, add_protected: None }), .. })`.
  Deletion = remove the tags and wait for the interval (a test with a 1 s interval: `oversized_blob_is_cut_and_collected`).
- **`O_TMPFILE` + a name without privileges:** `linkat(fd, "", dir, name, AT_EMPTY_PATH)` requires
  `CAP_DAC_READ_SEARCH`; `linkat(AT_FDCWD, "/proc/self/fd/<fd>", dir, name, AT_SYMLINK_FOLLOW)` works. `linkat` does not
  replace an existing file (`EEXIST`). File systems without `O_TMPFILE` answer `EOPNOTSUPP`/`EISDIR`/`EINVAL` — the
  fallback path uses a hidden name.
- **quick-xml 0.42, attributes:** `a.key.local_name().as_ref()` is `&str`; the value `a.value` dereferences to `str`.
- **hayro 0.7:** the paint color is `Color::to_rgba().components()` (the field is private). Invisible text arrives in
  `draw_glyph` with `GlyphDrawMode::Invisible` — without dedicated handling it ends up in the extracted text.
- **Antivirus under isolation:** the seccomp filter is inherited across `execve`, so an external program gets a separate
  profile (`av-exec`: kill only network access and sandbox escape; `execve`/`clone` allowed), and Landlock defines what
  it may read (`path_beneath_rules`; nonexistent paths are skipped — otherwise creating the rule fails).
- **`mmap(MAP_SHARED|MAP_ANONYMOUS)` is not counted in `RLIMIT_DATA`:** seccomp gets a condition on the mapping type
  (`flags & 0x0f == MAP_PRIVATE`). The reviewer found the breach without it (768 MiB with a 512 MiB limit); there is no
  probe in the tests — it would need `unsafe` (`mmap`), and the crate has `forbid(unsafe_code)`.

### Reviewer's re-check (2026-10-02)
- **hayro-syntax 0.7: walking all objects (`Pdf::objects()`) is quadratic on an object stream** — every object from an
  `/ObjStm` re-parses the stream's offset table (`xref.rs`). 5,000 objects (34 KB) take 0.6 s, 60,000 (445 KB) take
  101 s. Rendering touches only the objects it needs. Any PDF walk of our own only with limits on time and object count.
- **A seccomp "kill" on `socket` breaks ordinary programs:** `getpwuid` in glibc goes through NSS to systemd-userdb over
  AF_UNIX (`id`, `bash`). For external programs, sockets give `EPERM` rather than a kill; the network is closed anyway
  (`connect` and the like — kill, TCP — Landlock).
- **Landlock on kernel 6.8 does not restrict signals** (scoping arrives with 6.12): a sandboxed process can send signals
  to any process of the same uid. Close this with seccomp: `kill`/`tgkill`/`rt_sigqueueinfo` with the condition
  `arg0 == own pid`, `tkill` and `pidfd_send_signal` — kill. After `exec` the pid is the same, so the condition keeps
  working.
- **x32 and seccomp denylists:** `seccompiler` filters check the `AUDIT_ARCH_X86_64` architecture, and x32 calls come
  with the same architecture and the number `| 0x40000000` — a denylist doesn't see them. An allowlist (the worker) is
  safe (`EPERM` for everything else); a denylist needs a separate filter on the x32 bit. On the build server x32 is
  disabled in the kernel.
- **`/tmp` on the build server is a disk** (`/dev/sda1`), not tmpfs; temporary plaintext copies go to `/dev/shm`.
- **Invisible PDF text is more than `3 Tr`:** white paint, a font size < 4 pt, `Tz` 1 %, a 1×1 clip, a group with zero
  opacity — hayro draws all of these through `draw_glyph` as ordinary text; we have to check these signs ourselves
  (`TextDevice` in `cdr.rs`). Text covered by an opaque shape can't be told apart without a raster.

### Window on x-control/2 (owner session, history verification, rekey) — 2026-10-02
- **`login_required` in tests against the daemon.** Since v2, every owner client without a session gets
  `login_required` for almost everything. In the Dart tests: `openOwnerSession(client, password)` (`login {hold}` → token
  in `hello.session`). The token is valid only for the process that opened the session (PID + start time) — within one
  test process it can be passed to another client; after a daemon restart (or `lock`) the session is closed — open it
  again.
- **A receipt instead of a reply.** A read by an agent writes a signed receipt into the shared history — the contact
  receives it as a `message` event with `kind: "receipt"` before the reply. Wait for the reply with `!message.isReceipt`.
- **Sending right after a node restart gives `queued`.** The link's connection is not up yet: a `send` with a 2 s wait
  may not make it. In tests where delivery matters before the next step, use `wait` 15 s.

## 2026-10-02 · v0.1, slice 4 "files and quarantine", stage B — integration (decisions in DECISIONS D-F-15…D-F-22)

### Daemon
- **Tests created `~/X/links` on the build server.** At first the link folders were created at `unlock`, and any daemon
  without `--links-dir` (`crates/xd/tests/daemon.rs`, the window's live tests) touched the home directory. Now the folder
  is created only before the first file is **accepted**; the tests pass `--links-dir` / `X_LINKS_DIR` pointing to a
  temporary directory anyway (`tests/common` in x-cli — `Node::links()`). Check: after `cargo test --workspace` there is
  no `~/X` directory.
- **`destination base is not a plain directory`.** Accepting opens the base of the link folders with `O_NOFOLLOW`, and the
  directory did not exist yet. Fix: `Files::ensure_links_dir` creates `--links-dir` (`0700`) before accepting; an
  existing directory is resolved to its real path at startup (`canonicalize`), so that a symlink to the directory itself
  (another disk) works, while symlinks inside it don't.
- **Inherited descriptors → "the file changed while it was being prepared".** If `xd` was started by a parent that left an
  fd open without CLOEXEC (the Flutter window, `flutter_tester` — fd 9; a script), the check worker inherits it and
  refuses to work without isolation (`extra_fds > 0`). The check did not read the file to the end, the hashes didn't
  match the sender's, and a misleading `bad_state` went out. Fixed: the hash is read to the end in any case, and an
  isolation failure gives the verdict `failed` with the text "the check did not run: the worker is not isolated (it
  inherited N open file descriptor(s) …)". **Also fixed in the daemon (merge of the macOS branch, D-P-8):**
  `x_sys::fds::cloexec_inherited_fds()` (Linux: `close_range(3, ~0, CLOSE_RANGE_CLOEXEC)` with a fallback via
  `/proc/self/fd`; macOS: `fcntl(F_SETFD)` over `/dev/fd`) is called in `xd` right after the worker mode is parsed; the
  test `inherited_descriptor_does_not_reach_the_worker` — `xd` with an open fd 9 checks a file (`clean`). The honest
  `failed` remains in case marking fails; the window's workaround (`withoutInheritedFds`) is the second line of defense.
- **`cargo test -p x-cli` picks up a stale `xd`.** The x-cli tests run `xd` from `target/debug` next to `x`, and `-p x-cli`
  does not rebuild it: after daemon changes the test failed with "xd alice did not start" (the stale `xd` didn't know
  `--links-dir`). Fix: `cargo build -p xd -p x-cli` before a selective run, or `cargo test --workspace`
  (TROUBLESHOOTING 1.9).
- **`x share` on a FIFO would hang the daemon.** `open` of a FIFO for reading waits for a writer. The file to send is
  opened with `O_NONBLOCK | O_NOFOLLOW`, followed by the "regular file" check.
- **The worker is `current_exe`.** If the `xd` binary is replaced on disk while the daemon is running (an update),
  `/proc/self/exe` points to a deleted file, and starting the worker from it may fail — the check gives `failed` (fail
  closed). After an update, restart `xd`.
- **The `av-exec` mode would have bypassed the hidden argument.** `Checker` ran `<worker> av-exec …`, but `xd`'s worker
  modes start with `--x-files-worker`. Fix: `CheckerConfig::worker_prefix` (empty for `x-files-sandbox`).

### Tests
- **A level 1 refusal is not visible in `files pending`.** A refusal by manifest stores nothing (D-F-18) — wait for it
  via the receipt `reject_file`/`denied` in the sender's history (or the event `file{state:"refused"}`), not via the
  quarantine list.
- **`x agent add` without `--local-level` is a parse error** (D-49): the file tests use `--local-level 0`.
- **Moving the scanner broke a core test.** The streaming scanner test in `x_core::policy` took `floor_boundary` from a
  module that moved to `x-files`; now it is `pub fn x_files::secrets::floor_boundary`.
- **Stopping the receiver in the middle of a download.** Locally 64 MiB download in a fraction of a second; the test waits
  until the size of `<data>/quarantine` exceeds 1/8 of the file (polling every 5 ms) and sends SIGTERM; 1 GiB is
  `--ignored`.


### Window and daemon x-control/3 (files, slice 4) — 2026-10-02
- **`x share` from under the window/test process: "the file changed while it was being prepared" (`bad_state`).** The real
  cause is not the file: `xd` started by a Flutter process (`flutter_tester`, the Linux window in child-process mode)
  inherits descriptors without CLOEXEC (for `flutter_tester`, fd 9 on the `build/unit_test_assets` directory) and passes
  them on to the x-files check worker; a worker with extra descriptors does not consider itself isolated
  (`extra_fds > 0`), the check doesn't run and reads nothing — length and hash don't match. Under `dart run` or from a
  terminal everything works. Workaround in the window and the tests: start `xd` via `bash -c 'close fd 3…255; exec "$@"'`
  (`withoutInheritedFds` in `lib/host/daemon_host.dart`; dash can't handle fd > 9 — bash is needed). The right place is
  the daemon itself: at startup, close or mark CLOEXEC the inherited fds > 2 (or close them when starting the worker), and
  an honest message "check not performed: the worker is not isolated" instead of `bad_state`. Handed over to the daemon
  side.
- **Tests must not touch `~/X/links`.** daemon v3 creates the link folders at `unlock` (by default `~/X/links`): the tests
  use `X_LINKS_DIR` in a temporary directory (the harness and `ChildProcessHost(environment:)`).

### After the stage B security review (2026-10-02; DECISIONS D-F-24)
- **Files turned out to be a side channel for sending.** `request_file` carried up to 1024 bytes of path to the contact,
  bypassing no-write-down and the secret scanner, and so did the file name; a link's `shared/` was served on the
  contact's request together with everything an agent had written there. Lesson: any text that goes to a contact (a
  path, a name, a file in the link folder) is sending and is checked like `send`.
- **The `share_file approval_required` receipt went into the shared history** via the common `receipt_worthy` — together
  with its meaning "the agent read another link / there is a secret in the file". Send approvals are not written to the
  DAG (PROTOCOL §18) — `share_file` and `request_file` were removed from `receipt_worthy`.
- **Sent blobs were never deleted**, and every request from `shared/` re-encrypted the file (6 requests of 4 MiB → 24
  MiB forever). Now: kept until the contact replies or 14 days, a repeat of the same file is refused, and unanswered data
  is capped at the daily volume of the contact's level.
- **Two links — one folder.** "José" in NFC and NFD (and "Bob"/"bob" on macOS) normalize to one name. Folder names are
  computed over all links at once: colliding ones (`fold_key`) after the oldest get a suffix from the link ID.
- **An agent's `files reject` returned the name without taint** and deleted a threat that waits 7 days for the owner's
  decision.


## 2026-10-02 · Renaming to Antenna and the first release (decisions in DECISIONS D-55…D-60)

The entries above are history: they use the names of their time (`x`, `xd`, `x-core`, `~/.local/share/x`, `X_*`). Mapping:
`x` → `antenna`, `xd` → `antennad`, `x-<crate>` → `antenna-<crate>`, `~/.local/share/x` → `~/.local/share/antenna`,
`~/X/links` → `~/Antenna/links`, `X_*` → `ANTENNA_*` (the old ones are fallbacks), `XD_BIN` (window tests) → `ANTENNAD_BIN`,
`apps/x_desktop` → `apps/antenna_desktop`, `release-macos.yml`/`release-linux.yml` → `release.yml`.

### Bulk rename
- **The replacement must not touch protocol labels.** The labels `x/pair/v0/…`, `x/link/0`, `x 2026-10-02 …`, `x-control/N`,
  `x://pair#`, `xat_`/`xos_` go into keys, MACs, vectors and the keystore (`x/device/v0/…`: change it and the device key
  won't open). The replacement ran as a script with narrow rules (crate and module names, `xd`, `` `x `` and
  `x <command>`), followed by a check of the diff for `"x/`, `x-pair`, `EXPORTER`, `x-control`, `xat_`, `x://`: zero matches.
- **What the narrow rules missed** (fixed by hand): `crates/x-proto` in paths and `[profile.dev.package.x-files]` (a `/`
  or `.` before the name), `--x-files-worker`, `CARGO_BIN_EXE_xd` (`\bxd\b` doesn't see `_xd`: `_` is a word character),
  `"x"` literals (the clap name, the MCP server, the hook `mcp__x__*`). Signs of a miss: a failed hook test
  (`mcp__x__send_message` is no longer our server) and a `grep` for `x-`/`"x"` after the replacement.
- **`git mv` of the crate directories** preserves history; `Cargo.lock` is updated by `cargo metadata` without
  `--locked` — we verified that only workspace packages changed (external dependency versions are the same).
- **`std::env::set_var` is not allowed** (edition 2024 makes it `unsafe`, and the workspace has
  `unsafe_code = "forbid"`), so "slipping" `X_SOCKET` under clap's `env = "ANTENNA_SOCKET"` won't work: clap reads the
  new name, and the old one is read after parsing (`EnvVar::legacy_only`, with a warning).

### Window
- **APFS is case-insensitive.** The window on macOS is `Contents/MacOS/Antenna`; a search for the `antenna` CLI "next to
  the window" would find the window itself. The core in the macOS bundle is looked up only in `Contents/Helpers`, and the
  comparison with the window's path is case-insensitive.
- **Flutter and a version with a suffix.** Flutter for macOS turns `--build-name 0.1.0-preview.1` into `0.1.0.1` (it
  strips everything except digits and dots). `build-dmg.sh` uses `--build-name 0.1.0`; the full version and the commit
  are in `lib/version.dart` (`--dart-define=ANTENNA_COMMIT`).
- **The top bar overflowed** (by 127 px in the mockup frames): "Antenna" is wider than "x", plus the terminal button,
  plus the version with the commit on the pill. The caption and the mockup label are `Flexible` (they shrink first); the
  pill shows the version without the commit (the commit is in the daemon window).
- **Import order.** `package:antenna_desktop` sorts before `package:flutter` — `flutter analyze` reports
  `directives_ordering`; cured with `dart fix --apply --code=directives_ordering`.
- **The command dialog widget test** saw "…" instead of the status: the status is read asynchronously (login shell), and
  `setState` arrives after the frame — one more `pump()` is needed.

### Release and installation
- **Checking `install.sh` must not touch the user's real systemd.** With `--no-systemd` the installer does not stop the
  old build's service (it only deletes the unit file and says what to do), and `check-install.sh` checks both the unit
  and the cleanup of the old build in a temporary `$HOME` and prefix (`--dry-run` for the unit text).
- **Only "our own" old binaries are removed:** `~/.local/bin/x` could be anything; `install.sh` removes `x`/`xd` only if
  `--version` prints `x 0.0.…`/`xd 0.0.…`, and for the window only a symlink to `…/x.app/Contents/Helpers/x`.
- **Tag and version.** `release.yml` stops if the tag ≠ `v` + the version in Cargo.toml, and `build-tarball.sh`/
  `build-dmg.sh` stop if `antenna --version` is not `antenna <version> (<commit>)`: a binary from another commit cannot
  get into the release.

### First run of `release.yml` on GitHub (2026-10-02, run 37052359720; decisions D-61, D-62)
- **The runner passes extra descriptors to the tests.** The `cargo test` process on `ubuntu-24.04` inherited 2 open fds
  without CLOEXEC; `antenna-files` started the worker bypassing `antennad` — the worker is "not isolated"
  (`extra_fds=2`), and 13 tests of `corpus.rs` gave `sandbox_unavailable`. Reproduce locally with
  `bash -c 'exec 7<file 8<file; cargo test …'` (reading from a regular file is safe). Fixed where the worker is started:
  CLOEXEC in the child between `fork` and `exec` (D-61). Lesson: put protection against inherited state where the child
  is started, not only in the `main` of one of the binaries.
- **macOS: the `comm` of the `/bin/sh` shim is `bash`** (D-62): the check "the anchor is `sh`" by name failed although the
  behavior was correct.
- **macOS: there is no `O_TMPFILE`** — while a file is being accepted, the link folder shows a hidden `.antenna-incoming-…` (by
  design: fallback path D-F-13 #12); the unit test `accept::commit_does_not_replace_and_has_no_exec` expected an empty
  folder and failed in an informational step. Now it is strictly "nothing" on Linux and exactly one hidden temporary name
  elsewhere. The prefix was renamed (`.x-incoming-` → `.antenna-incoming-`), and leftovers of both are removed
  (`stale_incoming_of_both_builds_is_removed`).
- **XNU facts from the `macos-14` runner (macOS 14.8.9, arm64, uid 501 `runner`; `FACT` in the `core` job log):**
  - `kern.bootsessionuuid = E5D46D9E-…` — readable, stable within a boot (D-P-9 works);
  - a child in a pty: short flags `0x404090`, bsd flags `0x4040f0`, `tdev` = `Some(268435456)` — the controlling terminal
    is visible via `SHORTBSDINFO` (the owner session `tty` on macOS relies on it);
  - `launchd`: `unique_id=1`, `id_version=7`, path `/sbin/launchd`; `PROC_PIDTBSDINFO` for PID 1 from uid 501 gives `EPERM`
    (`Operation not permitted`), as the audit predicted: the chain via `SHORTBSDINFO` + `UNIQIDENTIFIERINFO` is
    mandatory (D-P-2); `getsid(1)=1`, `getsid(parent)=1`;
  - the test process: `sid: 1`, `tty: 0` — the runner has no terminal, and the session belongs to `launchd` (launchd
    starts the runner as a service): the rule "a session leader is not an anchor" does not get in the way here — the
    leader is PID 1, which is never an anchor;
  - GUI host: Calculator started with `open -a` — `ppid: 1, sid: 1, tty: 0`, `gui_host true, valid_anchor true`
    (D-P-3 confirmed on a real application);
  - environment: `ulimit -n` = 10240 (not 256: the runner has already raised it), `id`: uid 501, group `admin`; the
    step's shell is `/bin/bash` with the parent `Runner.Worker`.
- **`PT_DENY_ATTACH` works in release:** a control `lldb` attaches to an ordinary `sleep` (`stopped`, `detached`), and
  to the release `antennad` it gives `error: attach failed: lost connection` (M-7, D-P-4).
- **Live `antenna mcp` on macOS:** `initialize` in 16 ms, all 13 tools, no owner commands, the token is bound to the
  host process (D-28 on macOS via `proc_pidinfo`).
- **clippy `-D warnings` on macOS** (all crates, all targets) is clean: `tools/check-darwin.sh` on Linux missed nothing.
- A runner warning: `actions/checkout@v4` and `actions/cache@v4` on Node.js 20 are being forcibly moved to Node.js 24 —
  this works; update the action versions once releases on Node 24 are out.

## 2026-10-02 · Logo, light window theme v2 (`docs/design/logo/build.py`, `apps/antenna_desktop/lib/theme/`)

- **Rasterizing SVG without apt.** `pip install --target <scratch-dir>/pylib cairosvg pillow numpy scipy` and running with
  `PYTHONPATH=<scratch-dir>/pylib` (no venv is created on the host — there is no ensurepip, see above). cairosvg uses the
  system `libcairo.so.2`, which the build server already has. resvg/cargo were not needed.
- **A vector traced "by eye" from the source raster does not match:** the source's waves are not concentric circles
  (they straighten toward the ends), so one circle per wave gives an offset of up to ~10 px. Fix: fit each stroke to the
  smoothed coverage (`scipy.optimize.least_squares`: a segment with round caps or an arc with its own center), then
  enforce the symmetry of the pairs. Result: the contour is within 2 px at 1254 px (`build.py --check` prints IoU and
  deviation, `--check out.png` writes an overlay).
- **A "color with transparency → opaque background" gradient in Flutter tints half the screen.** `RadialGradient([brand@7 %,
  bg0])` interpolates channels without premultiplication: the middle comes out almost pure blue with alpha ~50 % — the
  spot was 3–4 times brighter than intended. Blend in advance: `Color.alphaBlend(brand.withValues(alpha: .08), bg0)` → a
  gradient between two opaque colors.
- **Theme switching with `const` widgets.** Colors are getters of the current palette (`XColors.*`), and Flutter does not
  rebuild `const` widget instances (it is the same object). After a palette change `XApp` marks all elements with
  `markNeedsBuild()` (like a hot reload) — the state (selected link, input fields, scroll position) is preserved; a
  `KeyedSubtree` keyed by brightness would reset it. Material's theme transition is off
  (`themeAnimationDuration: Duration.zero`); otherwise for 200 ms the widgets use the new palette and the buttons a mix of
  old and new. Removing `const` from expressions with `XColors.*` (≈ 50 places) was done by a script driven by the
  `invalid_constant` errors from `flutter analyze`.
- **The Linux window can't be built on the build server** (no GTK 3 dev): the window icon code
  (`g_file_read_link`/`gtk_window_set_icon_from_file`) was checked by compiling the GLib part against a GTK stub; the
  full check is the first build of the window on Linux.

## 2026-10-02 · Agent sandbox for wake (bwrap + Landlock; `antenna_core::sandbox`, tests `crates/antenna-cli/tests/wake_sandbox.rs`)

Scheme: daemon → `[bwrap …] antennad --antenna-wake-exec` (supervisor: bridge to the proxy, lifeline = stdin) →
`antennad --antenna-wake-exec exec` (stage 2: rlimits, capabilities, Landlock, seccomp) → `exec` of the agent. Every
protection below is verified by a test and a negative control (without the protection the test fails).

### bwrap
- **The inner pidns survives a killed bwrap.** Symptom: `kill -9` to the outer bwrap — the agent inside keeps running.
  Cause: `--new-session` moves the sandbox into its own process group and session, so a signal to bwrap's group doesn't
  reach it. Fix: `--die-with-parent` (the sandbox's PID 1 gets SIGKILL when the outer bwrap dies, and the kernel tears
  down the whole pidns). Check: `bwrap --unshare-pid --as-pid-1 --new-session --ro-bind / / -- sleep 31.5`, then
  `kill -9` to the outer one — without the flag `sleep` stays alive, with the flag it doesn't (experiment of 2026-10-02,
  bwrap 0.9.0). The concern "PDEATHSIG will fire when the daemon *thread* that started bwrap exits" was not confirmed:
  the outer bwrap 0.9.0 does not set PDEATHSIG on itself (started from a Python thread, the thread finished — bwrap is
  alive); the flag affects only the processes inside.
- **Threat: the agent kills or stops the supervisor** (`kill -9 $PPID`, `kill -STOP`) and escapes the lifeline. Fix:
  `--as-pid-1` — the supervisor itself is PID 1 of its pidns: signals from inside the pidns are not delivered to it
  (SIGKILL and SIGSTOP never are), and when it exits the kernel kills everyone (a double fork and `setsid` don't help).
  Symptom in a test: `kill -9 $PPID` in bwrap returns 0, but nothing happens — exactly as it should be
  (`agent_cannot_kill_its_supervisor`).
- **root reads `/etc/shadow` and `/etc/ssl/private` even without capabilities** (it owns the files). So only a selected
  list is taken from `/etc` (`ETC_ALLOW` in `sandbox/linux.rs`): `ssl/certs`, not `ssl`; `resolv.conf` is not needed —
  names are resolved by the daemon's proxy. Check: the unit test `bwrap_args_layer_mounts_from_shallow_to_deep` (no
  `/etc`, `/etc/ssl`, `private`), the integration test `files_only_what_the_spec_allows` (`R no shadow`).
- **The mount order decides what is "read-only".** `--bind` on top of `--ro-bind` makes the nested path writable again,
  and vice versa. The spec's paths are sorted by depth (shallow first), and at equal depth "read-only" goes later:
  `ro /proj` → `rw /proj/link/shared` → `ro …/CLAUDE.md` works as intended.
- **bwrap is looked up only in system paths** (`/usr/bin`, `/usr/local/bin`, `/bin`), and the file and its directory
  must be owned by root and not writable by group/others: through `PATH`, an agent of the same uid could plant its own
  "bwrap" without isolation. Then a functional probe (`--unshare-all … -- bwrap --version`): on Ubuntu 24.04 AppArmor
  (`kernel.apparmor_restrict_unprivileged_userns=1`) does not give an ordinary user unprivileged userns — bwrap is
  present but doesn't work (on the build server as `nobody`: `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`);
  the probe sees this and chooses Landlock (`Support.detail` explains why). Landlock mode as `nobody` was checked
  manually: capabilities 0, `/etc/shadow` and `/root` — denied, `kill -9 $PPID`/`-1` — `EPERM`, UDP — denied, an orphan
  after `setsid` cleaned up, `ulimit -n` from the spec. `--disable-userns` (bwrap ≥ 0.8) is probed separately: on
  0.6/0.7 we run without it.
- **Landlock inside bwrap forbids `ls /`** (the root is not in the rules) — this is defense in depth, not a breakage;
  bwrap's own `/tmp` and `/dev/shm` are added to the write rules.

### Landlock without bwrap
- **"Read-only" inside a writable directory is impossible.** Landlock rules only add rights down the hierarchy: if `cwd`
  is rw, a file under it can't be made ro. `launch` refuses (`sandbox_unavailable`, "bubblewrap required") instead of
  starting with a hole. `ro_binds` (credentials in `HOME`) are done as a symlink from the destination to the source:
  reads go through the source's rule, writes get `EACCES`, and the owner's original is not changed.
- **Finding out the ABI without restricting yourself.** `landlock` 0.4.7 has no public "current ABI";
  `RestrictSelf::default().no_new_privs(false).apply()` without flags only asks the kernel (no `landlock_restrict_self`
  and no `no_new_privs`) — test `landlock_abi_does_not_restrict`.
- **`landlock=partial abi=4` in the note is normal** on kernel 6.8: we request ABI 6 rights (device ioctl, scoping of
  signals and abstract sockets), and the kernel gives 4. The mandatory conditions for Landlock mode are ABI ≥ 4 and the
  rules being in effect.
- **root in Landlock mode stays root.** Without dropping capabilities the agent could load kernel modules
  (`init_module` is not FS) and open raw sockets bypassing the TCP rules. Stage 2 clears the bounding set
  (`PR_CAPBSET_DROP`, if `CAP_SETPCAP` is present), ambient, effective/permitted/inheritable; with `no_new_privs`, `exec`
  gives no more than there was (`CapBnd/CapEff = 0` in the agent's `/proc/self/status` — checked manually).
- **Orphans go to init.** Without its own pidns, a double fork + `setsid` took `sleep` out from under the supervisor;
  negative control: without reaping descendants `orphans_die_with_the_agent` hangs for 60 s (the orphan holds stdout),
  and `lifeline_…` leaves 2 processes. Fix: `PR_SET_CHILD_SUBREAPER` + a walk of `/proc` and SIGKILL via a pidfd with a
  start time check (no race with PID reuse), repeated until there are no descendants left.
- **`kill_on_drop` would kill the supervisor before it cleans up the tree** (in Landlock mode the orphans would stay
  alive). `Drop` for `Running` first walks the descendants of the direct child (`/proc`), then SIGKILLs the child and its
  group.
- **Threat: the agent's `kill(0, …)`, `kill -9 $PPID` or `kill -9 -1` hit the supervisor and all processes of the uid**
  (on the build server that uid is root, i.e. the whole server; check — `agent_cannot_kill_its_supervisor`, `ppid rc=1`,
  `all rc=1`). The agent is in its own process group; seccomp: `kill(-1)`, signals to the PID and group of the
  supervisor and of the daemon, `tkill`, `pidfd_open` on them and on a thread (`PIDFD_THREAD`) — `EPERM`. NOT closed
  before Landlock ABI 6: signals to other processes of the same uid and `kill(<supervisor thread tid>)` (tids are
  unpredictable); with ABI 6 `Scope::Signal` closes this.
- **Unix sockets of the same user are reachable** (Landlock before ABI 6 does not control `connect` to a socket): dbus,
  ssh-agent, other sockets in `/run/user`. The test `spec_socket_is_reachable` prints a `NOTE` instead of checking. If
  isolation is needed — bwrap.
- **The bridge listens on the host's loopback**, not in its own network: another local process can use it (only towards
  allowed hosts). The port is `0` (any free one), otherwise two agents would collide.

### seccomp and network
- **UDP (and DNS bypassing the proxy) is closed by seccomp, not by Landlock:** Landlock ABI 4 controls only TCP.
  `socket()` is allowed for `AF_UNIX`, TCP (`SOCK_STREAM`, protocol 0/6 — no SCTP and MPTCP, which the TCP rules don't
  see), `NETLINK_ROUTE` (getifaddrs); everything else — `EPERM`. `io_uring_setup` — `EPERM` (`IORING_OP_SOCKET` creates
  a socket bypassing the filter); x32 syscall numbers — kill (as for the file worker). `libc::SOCK_PACKET` is marked
  deprecated, so it is written as the number 10.
- **curl and the proxy in tests:** for `http://` through the proxy you need `-p` (otherwise curl sends `GET http://…` and
  the proxy answers 403); a direct request needs `--noproxy '*'`, otherwise `http_proxy` from the environment routes it
  into the proxy. curl ignores the upper-case `HTTP_PROXY` (httpoxy) — the supervisor sets both forms and `ALL_PROXY`.
- **The agent's stdin is `/dev/null`, not the lifeline:** a program that reads stdin when it is not a TTY (`claude -p`
  does this with a pipe) would wait for its end forever, and the agent would be holding one end of the lifeline.

### Tests
- `cargo test -p antenna-cli --test wake_sandbox` **does not rebuild `antennad`** (it is not a dependency of
  antenna-cli): after core changes — `cargo build -p antennad` or the test from the workspace root, otherwise the
  supervisor is stale.
- Negative controls leave live `sleep 6xx.<label>`/`7xx.<label>` processes: find them with
  `pgrep -af '^sleep (60|70)[0-9]\.'` and kill them (don't leave them running on the build server).
- `claude --version` in the sandbox (no network, doesn't spend subscription usage) starts in both modes:
  `2.1.233 (Claude Code)`.
- **Not verified (needs a live `claude -p`):** refreshing the OAuth token — `.credentials.json` is mounted read-only
  (bwrap: `EROFS`; Landlock: a symlink, `EACCES`), so Claude Code will not be able to save a refreshed token.

## 2026-10-03 · macOS sandbox — Seatbelt (`antenna_sys::seatbelt`, `antenna_files::{seatbelt, sandbox_macos}`, `antenna_core::sandbox::{macos, seatbelt}`; decisions D-P-12…D-P-14)

Scheme: the file check worker calls `sandbox_init` itself (as with Landlock); the agent at wake — a supervisor outside
the sandbox → stage 2 (`setsid`, rlimits, `sandbox_init`) → `exec`. None of this has been run on a Mac yet: everything
below marked "to check" is an assumption that the first run of the `core` job will confirm or refute (`FACT …`).

### SBPL profiles
- **Paths in rules are the real ones.** The kernel checks the vnode path after resolving symlinks: a rule on
  `/var/folders/…/T/x` won't fire, you need `/private/var/folders/…/T/x`; likewise `/tmp` → `/private/tmp`, `/etc` →
  `/private/etc`. Test temporary directories on macOS are exactly in `/var/folders`. Fix: every path in two forms
  (`seatbelt::path_forms`: as given and `canonicalize`; for a nonexistent path — the real parent + the name). Symptom of
  the error: `EPERM` on an "allowed" path.
- **`(allow op)` without filters allows the operation everywhere.** An empty path list (no `rw`, no sockets) would turn
  "write only here" into "write anywhere". `seatbelt::allow` does not write a rule without filters at all (test
  `empty_filters_never_allow_everything`).
- **"Read-only" inside a writable directory** — `(require-all (subpath W) (require-not (subpath R)))` (Codex does the
  same): independent of rule order. Unlike Landlock (whose rules only add rights), Seatbelt can do this, so the
  "bubblewrap required" mode is not needed on macOS.
- **SBPL strings** are TinyScheme literals: `\` and `"` are escaped; a newline and other control characters — refusal
  (fail closed); a non-UTF-8 path — refusal.
- **Homebrew keeps service data next to the programs:** `/opt/homebrew/var` (PostgreSQL, Redis databases…),
  `/opt/homebrew/etc` (their configs, sometimes with passwords); on Intel — `/usr/local/{var,etc}`. They are excluded
  from system reads (`require-not`), and from `etc/` only the root certificates are allowed. ClamAV from Homebrew gets
  its config and databases explicitly (`AvHook::clamscan`).
- **Viewing the profile without a Mac:** `cargo test -p antenna-core --lib sandbox::seatbelt -- --nocapture` prints the
  whole agent profile.

### Processes and resources
- **`RLIMIT_DATA`/`RLIMIT_AS` on macOS do not limit `mmap` memory** — the `big_alloc` test (2 GiB with a 512 MiB limit)
  does not fail there. The worker's memory limit is a watchdog in the daemon (`MemoryWatchdog`:
  `proc_pid_rusage(RUSAGE_INFO_V2).ri_phys_footprint` every 50 ms, SIGKILL with a `p_uniqueid` check). `bytearray(n)` in
  Python does not increase the footprint (zero calloc pages) — the `antenna-sys` test fills the memory (`b'x' * n`).
- **No pidns and no subreaper:** a double fork and `setsid` hand a process over to launchd, and it can't be found by its
  parent. The sandbox's launch processes are found with `sandbox_check` (SPI, `dlsym`): in a sandbox, allows the launch
  label (a Mach name), denies a second random name, created after the supervisor, same uid. We don't keep a killer
  inside the sandbox (`kill(-1)`): an agent in the same sandbox would kill it first.
- **`SANDBOX_CHECK_NO_REPORT` is an exported constant symbol** (WebKit `sandboxSPI.h`), not a `#define`: it is read via
  `dlsym`, and only if it looks like a single bit flag; otherwise 0 (check denials then end up in the log — noise, not an
  error).
- **A process group leader can't call `setsid`** (`EPERM`). Stage 2 on macOS is started without `process_group(0)` and
  calls `setsid` itself (new session = new group): the agent's `kill(0)` does not hit the supervisor, the agent has no
  daemon terminal, and its orphans won't coincide with the owner's `tty` session (D-46).
- **`kill(-1, …)` on macOS (POSIX, libc `kill`) includes the calling process itself**; in a sandbox with
  `(allow signal (target same-sandbox))` it kills exactly the processes of its own sandbox — the agent kills itself, and
  the supervisor and the user's other processes are not touched. The `agent_cannot_kill_its_supervisor` test on macOS
  expects exit code 0 or 137 and a live unrelated process.
- **Seatbelt does not forbid threads** (there is no syscall filter like seccomp): the `thread` probe is not in `PROBES` on
  macOS. Forbidden operations give `EPERM`, not `SIGSYS`: test expectations are per OS.

### Tests on macOS (what is missing there)
- **No `/proc`:** descriptors via `/dev/fd`, processes via `ps -axo pid=,command=` (`wake_sandbox.rs::procs_with`).
- **No `setsid` utility** — `perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV'` (`wake_sandbox.rs::setsid`).
- **No `/bin/true`, `/usr/bin/cat`, `/usr/bin/bash`, `/etc/hostname`, `/dev/shm`** — use `/usr/bin/true`, `/bin/cat`,
  `/bin/bash`, `/etc/hosts`, the user's temporary directory (the antivirus check directory).
- **To check (first run):** that `/bin/sh`, `curl`, `perl`, `grep`, `antenna`, `antenna mcp` under the agent profile
  don't run into anything closed (`SYSTEM_READ`, `ETC_READ`, sysctl, Mach); that `(literal …)` for `network-outbound`
  lets them through to the daemon's unix socket; that `localhost` in `(remote ip "localhost:PORT")` covers `127.0.0.1`.
  If a program fails with `EPERM` while reading a system path — add the path to `SYSTEM_READ`/`ETC_READ` (only paths
  without user data) and record it here.
- **Claude Code on a Mac keeps its login in the keychain** (not in `~/.claude/.credentials.json`), and the keychain is
  closed to the agent (`com.apple.SecurityServer` is not in the profile): for wake on a Mac use
  `--secret-env CLAUDE_CODE_OAUTH_TOKEN --no-home-files`. A real `claude -p` under Seatbelt is to be run manually on a
  Mac.

## 2026-10-03 · v0.2: streaming messages and agent wake (`stream.rs`, `wake.rs`; decisions in DECISIONS D-63…D-72)

### Daemon
- **A lock taken in an `if let` condition lives until the end of the block** (a repeat of gotcha 3.12). `wake_loop` had
  `if let Ok(r) = self.db.lock()…wake_rules() { let db = self.db.lock(); … }` — a second `lock` of the same `std::Mutex`
  on the same thread waits forever. Caught by reading the code before running it. Rule: a value taken under a lock goes
  into a separate `let`.
- **A `MutexGuard` across `.await` makes the future non-`Send`, so `tokio::spawn` does not compile.** In `serve_stream`
  the duplicate check and `drop(g)` before `await` in one branch — the compiler still considers the guard alive. Fix:
  compute a flag inside a block (the guard dies at the end of the block), and `await` after it.
- **`tokio::pin!` does not let you drop the future.** `drop(reader)` after a `select!` on a time limit dropped only a
  `Pin<&mut _>`: the reader of the agent's output stayed alive and could hold the reply writer slot (clippy: "drop of a
  value that does not implement Drop"). Fix: `Box::pin` and `drop` of the box; the writer lives in a shared
  `Arc<Mutex<Option<_>>>`, and a reply started after the time limit ends with the final message "interrupted".
- **The agent's grandchild holds stderr — the log waits for it for minutes.** Without a sandbox (a temporary stub),
  `sleep 60` from the agent's script outlived the killed `bash` and held the stderr pipe; reading the log tail waited for
  it. Fix: the stderr tail is read for no longer than 3 s after the agent exits; the real sandbox kills the whole tree
  (lifeline, pidns).
- **The secret scanner holds back a tail of ≥ 48 bytes** (PEM markers with spaces, D-40): a short text in a stream shows
  up only at the end. Tests use chunks longer than 48 bytes; for an LLM the lag is a fraction of a second. Not a bug;
  keep it in mind when measuring the first chunk.

### CLI and tests
- **`antenna --json send --stream` did not print `stream_started`** — the test "level 2: no live display" could not
  check the reason. Now the event is printed as a JSON line before the final response (the last line is still the
  response).
- **A fake agent instead of `claude`.** Wake tests don't call the real `claude` (it spends subscription usage): a bash
  script prints `stream-json` events (`stream_event`/`text_delta`) with pauses and reads incoming messages with
  `antenna --json inbox` using its token. The scenario is the first argument (`reply`, `crash`, `slow`, `secret`,
  `plain`, `escape`), the daemon's prompt is the last. The script lives in a separate directory (`agent-bin/`): the
  sandbox mounts the directory of the agent's program read-only, and the test's forbidden paths must not end up inside it.
- **The fallback sandbox mode on a machine with bwrap** — the hidden daemon flag `--wake-landlock-only` (tests
  `*_landlock_only`); `Node` in `tests/common` has `extra_args`.

## 2026-10-02 · Window localization: English and Russian (`apps/antenna_desktop/lib/l10n/`, DESIGN "Languages")

- **The synthetic package `flutter_gen` has been removed (Flutter 3.32+; we use 3.47.6).** `synthetic-package: true` in
  `l10n.yaml` is an error, `false` a warning. gen-l10n puts the code into `arb-dir` (`lib/l10n/app_localizations*.dart`),
  imported as an ordinary relative/`package:` import. We commit the generated code: otherwise `flutter analyze` on a
  clean tree (CI without a generation step) can't find `AppLocalizations`. The guard `l10n_guard_test.dart` catches a
  forgotten regeneration (the ARB key exists, but the class doesn't have it).
- **English template with an ICU plural, Russian as a plain string.** gen-l10n accepts this (each language is parsed
  separately): `"{count, plural, =1{1 contact} other{{count} contacts}}"` in en and a plain string with `{count}` in ru
  (`navContactsCount` in `app_ru.arb`) — so the Russian text stayed verbatim. Text around a plural
  (`"antenna contacts → {count, plural, …}; …"`) is supported too.
- **intl `DateFormat` with a locale outside the widget tree.** Locale date data is loaded by
  `GlobalMaterialLocalizations` only when `MaterialApp` is built; in unit tests and in state code without it,
  `DateFormat('MMM d, yyyy', 'en')` runs into unloaded data. `format.dart` calls `initializeDateFormatting()` once
  (`date_symbol_data_local`: the data comes from the package, synchronously — the Future is a formality). The order
  relative to Flutter does not matter: both loads add locales rather than replace them.
- **Strings and `const`.** Text via `context.l` makes an expression non-constant: `const Text('…')` →
  `Text(context.l.…)`, `const _Steps([...])` → without `const`. Unlike a palette change (static getters, which need
  `markNeedsBuild` over the tree), a language change needs nothing special: `Localizations` is an InheritedWidget, the
  dependent widgets rebuild themselves, and state is preserved (the test "Settings → Russian / English" — the "Settings"
  section stays open).
- **`context` after `await`.** In handlers with awaits (`_submit` of the input line, `_act` of the CLI dialog) the strings
  are taken before the first `await` (`final l = context.l;`), otherwise `use_build_context_synchronously`.
- **Long English words in narrow places.** "Acquaintance" in the level picker (a 360 px card) was truncated with an
  ellipsis: the name in the cell is now `FittedBox(scaleDown)`, and an invisible line of normal height holds the space
  (the level digits stay on one line). The banner "Design · not implemented in the daemon yet" was shortened to
  "Design · not in the daemon yet".
- **`prefer_initializing_formals` on a named parameter going into a private field.** Dart 3.13 allows private named
  parameters: `Appearance({this._lang = LangChoice.system})` is called as `lang:` from outside.
- **Golden tests in two languages.** The test system is `en-US`, so all frames are English; the Russian variant of a
  frame uses `t.platformDispatcher.localesTestValue = [Locale('ru', 'RU')]` (which also checks the "as in the system"
  path) plus Russian demo data (`fixtures.dart`, the global `demoLang` — reset it in `addTearDown`, otherwise the language
  "leaks" into the following scenarios of the same file). Verbatim check: the Russian frames `*_ru` matched the frames
  from before the localization byte for byte.
- **Cyrillic in literals — a guard, not grep.** A line-based `grep` confuses end-of-line comments and literals inside
  interpolation; `l10n_guard_test.dart` has a small Dart lexer (`//`, nested `/* */`, raw and triple-quoted strings,
  `${…}` with nested strings), with its own test on a sample.
- **The `activity` leak test was insensitive** (the negative control — without the fix — stayed green): the sender glues
  chunks together within 30 ms, and the secret `activity` in the same frame was overwritten by the next one (`""` when
  the text starts). The fake agent now pauses 0.3 s around it, so it goes out in a separate frame; without the fix the
  test fails. Lesson: for streaming paths a negative control is mandatory — gluing hides exactly what the test needs to
  see.
- **The sandbox start gate.** The wake agent starts only after the line `go` on the lifeline (`start_gate`): the daemon
  first binds the agent to the sandbox root and enables the launch token. The `wake_sandbox.rs` tests run without the
  gate (`start_gate: false`); a forgotten `go` with the gate on — the agent does not start, and the launch ends at the
  time limit.

## 2026-10-03 · Window on x-control/4: live bubble and wake (`apps/antenna_desktop`)

- **The final message of one's own stream after approve arrives without `final`.** A secret in one's own agent's reply →
  `interrupted{cut}`; after `antenna approve` the daemon sends the final message itself (D-70), but the deferred final
  message (`stream_pending`) does not remember the `stream_id`, and one's own window never gets the `final` event
  (d0ce41d) — the "awaiting your approval" bubble would hang until the window is closed. The window recognizes the final
  message by its text: one's own outgoing message on this link that starts with the bubble's text closes the bubble
  (`StreamsMixin.onOutgoingMessage`). The right way is `final` with a `stream_id` from the daemon (a core task;
  CONTROL §15 promises it). **Fixed in the core on 2026-10-03 (D-76):** the deferred final message remembers the
  `stream_id`, and after approve the subscribers get `final` with `stream_id` and `message_id`; the window's workaround
  is a fallback.
- **The secret is visible to one's own window.** In `interrupted{cut}` the sender's `text` is the whole text, including
  what the scanner held back: it is one's own agent and one's own owner; the contact gets the secret neither in the
  bubble nor in the history (the live test checks both sides).
- **`ChangeNotifier` after `dispose`.** Daemon responses (`streams`, `wake_list`) arrive even after the model has been
  closed (the test closes the window while `resyncStreams` is in flight): the mixins notify via `safeNotify()`, which in
  `AppModel` stays silent after `dispose`.
- **`CheckboxListTile` in a dialog.** The dialog panel is a filled `DecoratedBox`; `ListTile` paints its background on the
  nearest `Material` → the assertion "ListTile background color or ink splashes may be invisible". Wrap it in
  `Material(type: transparency)`.


## 2026-10-03 · LAN, invite links via the website, contact agents (`lan.rs`, `agentid.rs`, `invite.rs`; DECISIONS D-74…D-77)

- **`cargo test -p antenna-cli --test …` does not rebuild `antennad`.** The tests take the daemon next to `antenna`
  (`target/debug/antennad`), and `-p antenna-cli` builds only its own package: a change in `antenna-core` got into the
  CLI but not into the daemon — the LAN test showed 4.2 s instead of 1.1 s, and debug lines "weren't printed". Before
  `-p antenna-cli`, run `cargo build -p antennad` (or `cargo test` from the root over the whole workspace).
- **mDNS in tests on the build server.** Multicast from the host would go out to the public network (the server's
  `eth0`). The test moves into its own network namespace:
  `unshare -rn sh -c 'ip link set lo up && ip link set lo multicast on && ip route add 224.0.0.0/4 dev lo && exec <test>'`
  — there is only `lo` there, no default route; without `multicast on` and a 224/4 route via `lo`, swarm-discovery can
  neither send nor receive. The daemon's unix sockets (files) are visible from inside too. Without `unshare -rn`
  (Ubuntu 24.04 AppArmor for an ordinary user) the test prints SKIP.
- **swarm-discovery repeats `Discovered` on every response.** `Peer` is compared together with `last_seen: Instant`, so
  "already known" never triggers: an event every second for every announcement. Connecting by a found alias — at most
  once per 3 s; the subscription channel holds 20 events with `try_send` (a lagging subscriber loses events), so read it
  immediately.
- **A link without a relay did not come up.** `transport::bind` waited 20 s for `ep.online()` and returned an error on
  failure; `start_saved_link` retried on a random port (another 20 s) — without internet every link cost 40 s and still
  didn't work, even on a LAN. Saved links now use `bind_saved` (≤ 2 s, a relay is not required), and links start in
  parallel.
- **Waiting for delivery hid the LAN.** The delivery loop waits for a dial to old addresses until `dial_timeout`; a
  `kick` is not heard meanwhile. The LAN announcement is set before the dial (there is something to deliver but no
  connection) and right at `lan on` — otherwise the node would stay silent on the network for the first 3–10 s.
- **preview.1 is strict about anything new.** A new message body, a new type or a foreign `author` gives
  `bad_request`/`rejected`, after 5 refusals `failed`, and an endless divergence when resending. That is why everything from
  PROTOCOL §21 is sent only after `features` with `agents/0`; preview.1 answers an unknown request with
  `rejected{malformed}` (visible in the tag's sources). Compatibility is checked with the tag's real binaries:
  `git archive v0.1.0-preview.1 | tar -x -C <dir>`, there `cargo build -p antennad -p antenna-cli` with a **separate**
  `CARGO_TARGET_DIR` (a shared one would overwrite `target/debug/antennad` — the package names are the same), then
  `ANTENNA_LEGACY_BIN_DIR=<target>/debug cargo test -p antenna-cli --test peer_agents -- --include-ignored`. Building the
  tag from scratch takes 6.5 min on the build server.

## 2026-10-03 · Release `v0.1.0-preview.2` on GitHub runners: test output, rustdoc, Seatbelt profiles

The tag `v0.1.0-preview.2` (on 7c5fe9e) failed twice in CI because of one libtest detail; the fixes are on `main`
(f1cd42f, d7f1d4a, 01571c3), and the release is re-tagged from `main`.

- **With `--nocapture`, a child test's first line is glued to libtest's `test <name> ... `.** libtest prints
  `test <name> ... ` without a newline and the result (`ok`) only when the test ends, so whatever the re-run child test
  prints first lands at the end of that line rather than on a line of its own. Two tests read the child's output line by
  line and broke on it:
  - Linux (`crates/antenna-cli/tests/wake_sandbox.rs`, the inherited descriptors test): `starts_with("SKIP")` missed the
    child's first line, a `SKIP` line (GitHub's ubuntu runner has no bwrap), so the SKIP/RESULT count came out wrong and
    the test failed.
  - macOS (`crates/antenna-sys/src/seatbelt.rs`, the `sandbox_check` test): the parent waited for a line with
    `trim() == "READY"`, which never matched, so the parent and the child waited for each other until the job was
    cancelled after 80 minutes.
  - Fix: match with `contains`/`ends_with` (`l.contains("SKIP: ")`, `l.trim_end().ends_with("READY")`), never with an
    exact match or `starts_with` on the first line of a child's output. In `release.yml` every step of the macOS `core` job now has
    its own `timeout-minutes` (10–30) and the job 75 minutes in total (was 120), so a hang costs
    minutes, not the macOS quota.
- **rustdoc reads ``[`x`]: …`` at the start of a doc line or list item as a link reference definition.** A doc comment
  line such as ``/// [`fds`]: closes inherited descriptors`` defines a link instead of being text, and clippy's
  `doc_nested_refdefs` fails the build (`-D warnings`). In macOS-only code (`#[cfg(target_os = "macos")]`) this shows up
  only through `tools/check-darwin.sh` (or in CI on a Mac), not in the Linux build. Rephrase so the line does not start
  with ``[`…`]:`` (for example ``/// `fds`: …`` or put the link inside the sentence).
- **The Seatbelt profile tests forbid words, not rules.** The profile tests check the whole profile text with
  `!p.contains(…)` for `network`, `file-write`, `process-exec`, `process-fork`, `mach-lookup` and others
  (`worker_profile_is_closed_and_balanced`, `av_profile_writes_only_to_its_scratch`, the agent profile without a proxy).
  The header comment is part of that text: a comment that mentions "network" fails the test as if the profile allowed
  it (0f391b7). Keep these words out of profile comments; say "connections", "writes", "launching programs".
- **Seatbelt on a real Mac (GitHub `macos-14` runner):** `sandbox_init` works; a malformed profile is rejected with
  libsandbox's error text; a `file-read` deny holds; a second `sandbox_init` in an already sandboxed process is refused; `sandbox_check` is available through `dlsym`. This confirms
  the corresponding "to check" assumptions of the section "macOS sandbox — Seatbelt" above.

## 2026-10-03 · Self-hosted macOS runner and Linux files outside GitHub Actions (D-81)

What differs from a GitHub-hosted runner, and what `release.yml` and `packaging/release-linux.sh` do about it.

- **The workspace persists between runs.** A self-hosted runner reuses `_work/<repo>/<repo>` for every job of every run.
  `actions/checkout` cleans it by default with `git clean -ffdx`, which would also delete `target/`; with `clean: false`
  nothing is cleaned, and an old `dist/*.dmg` would be uploaded with the new one, or a deleted test file would still
  run. So every job checks out with `clean: false` and then runs `git clean -ffdx -e /target/` (with `-x`, git still
  honors `-e` patterns). target/ only grows: clear it on the Mac now and then (`rm -rf ~/actions-runner/_work/*/*/target`).
- **One runner, one job at a time.** `version` → `core` → `macos` → `publish` run one after another on the same Mac and
  in the same directory, so they share target/. A job that finds no online runner waits in the queue; GitHub fails it
  after 24 hours.
- **`PATH` under launchd.** The runner service does not read the shell profile. Its environment comes from two files in
  the runner directory, written by `config.sh` from the shell it was run in: `.path` (one line, the `PATH`) and `.env`
  (`NAME=value` lines). If Homebrew or rustup was not on `PATH` at that moment, jobs do not see `brew`, `protoc` or
  `cargo`. Fix: edit `.path` (or run `./env.sh` from a shell that has them), then `./svc.sh stop && ./svc.sh start`.
  The workflow also adds `/opt/homebrew/bin` and `~/.cargo/bin` to `GITHUB_PATH` when they exist.
- **Installed tools stay installed.** `brew install` of an existing formula is not an error, but if the formula is
  outdated it upgrades it (and `brew` may update itself first). The workflow installs only what `brew list` lacks, with
  `HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_INSTALL_CLEANUP=1`.
- **Flutter is not cloned into `~/flutter`.** A second `git clone` into an existing directory fails, and on a desktop Mac
  `~/flutter` may be the user's own SDK at another version. The `macos` job keeps its own checkout in
  `$RUNNER_TOOL_CACHE/flutter` (`~/actions-runner/_work/_tool/flutter`): reused when `git describe --exact-match` is the
  pinned tag, otherwise the tag is fetched and checked out. `flutter config --no-analytics` (in `build-dmg.sh`) still
  writes the user's Flutter settings.
- **`actions/cache` is not needed** (target/ and `~/.cargo` are already on disk) and would upload gigabytes to the
  repository's cache storage: the cache steps run only when `runner.environment == 'github-hosted'`.
- **Tests that touch the desktop session.** The jobs run as the Mac's user, in their GUI session. The D-P-3 test opens
  Calculator and kills the process named `Calculator` (it would close the user's window): GitHub-hosted only. An
  `lldb -p` attach with developer mode off asks for a password on screen and waits until the step's timeout: the
  `PT_DENY_ATTACH` check runs only when `DevToolsSecurity -status` says it is enabled. If the macOS firewall is on,
  watch the first run for "accept incoming connections" prompts from freshly built test binaries.
- **`sha256sum` is not on every Mac**: `publish` uses `shasum -a 256`, which prints the same format on macOS and Linux.
- **Linux files without a GitHub runner.** `packaging/release-linux.sh` refuses to run if `xvfb-run` is missing, because
  `check-desktop.sh` silently skips the window launch without it. It builds in a temporary `git worktree` with its own
  `target/` (`CARGO_TARGET_DIR` is set to it: `build-tarball.sh` expects `target/release` inside the checkout), so a
  release never picks up uncommitted files or another build's artifacts; the worktree and its target are removed on
  exit, also after a failure. A draft release has no tag lookup in the REST API (`releases/tags/<tag>` returns only
  published ones); `gh` 2.97 falls back to a draft lookup by tag name, so `gh release view/upload/download/edit <tag>`
  work on the draft.

## 2026-10-03 · Signed releases and `antenna update` (`crates/antenna-update`, `crates/antenna-release`, D-82)

- **A deleted file's inode number comes back.** The install journal identifies "the old version" by device and inode.
  A unit test that deleted the original and wrote a new file at the same path saw the new file get the same inode, so
  "restore" found nothing to do. In the installer the original is never deleted during a transaction (it is kept at
  the staging path or as `.previous`), so identity is stable; tests that need "the original is gone" move it away
  instead of deleting it.
- **`cfg(debug_assertions)` code and `-D warnings` in release builds.** `let mut s = …; #[cfg(debug_assertions)] if … {
  s.add_test_key() }` is fine in debug and an `unused_mut` error in release; only `tools/check-darwin.sh --release`
  showed it (the Linux run is debug). Shadow inside the `cfg` block instead (`#[cfg(debug_assertions)] let s = { let mut
  s = s; …; s };`), and run a `--release` clippy for code with debug-only branches.
- **`antenna` and `antennad` from different commits.** `cargo test -p antenna-cli` rebuilds `antenna` (its build commit
  comes from `git rev-parse` at build time) but not `antennad` (N.7). The update test compares both `--version` lines
  with the manifest's commit and failed with "reports … the manifest says …". The test now asserts that both binaries
  are from one commit and says `cargo build -p antennad`.
- **A detached CLI must not print with `println!`/`eprintln!`.** When the window starts `antenna update`, the CLI closes
  the window on macOS; its stdout and stderr are pipes to a process that is gone, and `println!`/`eprintln!` panic on
  `EPIPE` (Rust ignores `SIGPIPE`, so writes return an error, and the macros turn it into a panic). The update path
  writes with `let _ = writeln!(…)` and keeps the log file as the record.
- **`ps -o comm` differs by OS.** On Linux `comm` is the 15-character process name; on macOS it is the executable path,
  which is what the installer matches to find a running window. `packaging/macos/check-update.sh` checks this on a Mac
  (a `FACT` line); the unit tests use a fake `ps`.
- **The release binary must never trust the test key.** It is a branch compiled into debug builds only. A unit test
  cannot run as a release build, so `packaging/linux/check-install.sh` runs the release `antenna update --json` with
  `ANTENNA_UPDATE_TEST_KEY=1` and requires `"test_key":false`.
- **The window could not tell where an accepted file is.** `FileInfo` had `dest` and `saved_as`, but the link folder name
  depends on label collisions (`-<8 hex>` suffixes) known only to the daemon. Accepted files now carry `saved_path` in
  owner replies; agent events still have neither the name nor the path.
- **"Text file busy" in parallel tests.** The installer tests write small shell scripts as stand-in binaries and run
  their `--version`. Once in a full workspace run a script could not be executed: a parallel test's `fork` held the
  just-written file open for writing for a moment (`ETXTBSY` on `exec`), so the fake daemon had no version. The test
  helpers retry `exec` on `ExecutableFileBusy` (40 runs of the suite with 16 threads, no failure). The installer itself
  runs binaries unpacked by a finished `tar`, from a single thread.
- **Independent check of the signature construction.** The documented vector (`docs/UPDATES.md` appendix A) gives the
  same Ed25519 signature in Rust and in Python `cryptography`, and `openssl pkeyutl -verify -pubin -rawin` accepts it
  over `"antenna/release-manifest/v1\0" ‖ manifest`; with one extra byte it says "Signature Verification Failure".

## 2026-10-03 · macOS 26 on a real Mac (D-P-12, D-P-13, D-P-15, D-P-16, D-F-25)

The first run of the sandbox suites on a real Mac (macOS 26.5.2, build 25F84, arm64, Xcode 26.4) rather than a CI
runner. Build, clippy, `antenna-sys`, the profile unit tests, `tools/mcp_smoke.py` and the window tests were green; the
three suites that start sandboxed processes were not (`antenna-files --test sandbox`: 8 of 11 failed;
`antenna-cli --test files`: 8 of 11; `antenna-cli --test wake_sandbox`: 7 failed). After the fixes below all of them
pass on that Mac (13 of 13, 11 of 11 with 1 ignored, 12 of 12).

- **`setrlimit(RLIMIT_DATA)` fails with `EINVAL` on macOS 26.** The file check worker treated the error as "no
  isolation" and every check ended as `sandbox_unavailable` (verdict `failed`, so sending needed approval with
  `sender_check:failed` and receiving gave `forbidden`). `RLIMIT_DATA` never held `mmap` memory on macOS (the daemon's
  watchdog enforces the limit), so it is best effort now (fa70b38). Seatbelt itself was never the problem: a trivial
  `sandbox-exec` profile works on this system.
- **Every program started under our Seatbelt profiles aborted inside dyld, before `main`.** Wake agents exited with 134
  and the external antivirus was "killed by SIGABRT 6". The crash report: `EXC_CRASH (SIGABRT)`, termination namespace
  DYLD, the crashing thread `__abort_with_payload ← abort_with_reason ← ignition_halt ← boot_boot ← ignite ←
  dyld4::CacheFinder::CacheFinder ← ProcessConfig::DyldCache ← dyld4::start`. **There is no deny line in the sandbox
  log** (`log show --predicate 'sender == "Sandbox"'` is empty): dyld aborts by itself when an open fails, so the log
  does not point at the missing rule. The worker, which applies its profile to itself after dyld has run, was not
  affected. Found by bisecting with `sandbox-exec -f <profile> /usr/bin/env` and appending one rule at a time: only
  `(allow file-read*)` helped, and narrowing it gave `(allow file-read* (literal "/"))`: libignition (dyld's loader of
  the cryptex-based system volume) opens `/` to use it as the root for `openat(2)`. Apple ships exactly this rule, with a
  comment saying so, in `/System/Library/Sandbox/Profiles/dyld-support.sb` (present on this system; it also covers the
  cryptex graft points, a few file-control commands and system calls). Fix (D-P-15): every profile that starts programs
  imports `dyld-support.sb` when the file exists and also carries the explicit rule.
  `antenna-files --test sandbox` checks both on a Mac: `FACT dyld under a profile (… present: true): import
  Some((Some(0), None, "")), explicit rule (Some(0), None, ""), neither (None, Some(6), "")`. Takeaway: a sandboxed
  child that dies with SIGABRT before `main` and no sandbox denial is dyld; read the crash report's termination
  namespace, then bisect with `sandbox-exec`.
- **The root directory is readable now, so `/` no longer proves isolation from inside the agent sandbox.** Stage 2 of
  wake probed by listing `/`; it lists `/Library` now (always there, readable by any user, not in the profile). The file
  check worker still lists `/`: its profile does not get the rule.
- **One environment variable in a worker started with an empty environment: `__CF_USER_TEXT_ENCODING`.**
  CoreFoundation, loaded with the system frameworks, sets it at startup when it is missing: the process's uid, the
  user's text encoding and region (`0x<uid>:0x<encoding>:0x<region>`). Nothing comes from the daemon: `env_clear()`
  passes an empty environment. The `env` probe now prints names (never values), counts only variables passed in, and
  lists what the system set in the process separately (exactly this name, with this shape and the process's own uid):
  `probe=env result=blocked detail=0 environment variables []; set by the system in this process:
  [__CF_USER_TEXT_ENCODING]`. A negative-control test passes a variable in and expects it to be reported.
- **A write into a link's `shared/` did not count as handing data to that link** (`files.rs`,
  `review_files_are_not_a_side_channel_for_outflow_or_taint`: `check write` answered `allow`, "session has not read any
  contact's data"). It looked like taint attribution through the process tree, but the cause was a path: the links
  folder did not exist yet when the daemon started, so `canonicalize` failed and the daemon kept the path as given
  (`/var/folders/…`), while every path it compared was resolved (`/private/var/folders/…`). Fix: the links folder is
  resolved like those paths, through its deepest existing ancestor. Reproduce on Linux with a temporary directory
  behind a symlink: `R=$(mktemp -d /tmp/atr.XXXX); ln -s $R /tmp/atl; TMPDIR=/tmp/atl cargo test -p antenna-cli --test
  files review_files` (keep the path short: the daemon socket must fit `sun_path`). Unit test:
  `files::tests::links_folder_behind_a_symlink_is_recognized_before_it_exists`.
- **`cargo test -p antenna-cli` ran a stale `antennad` again** (N.7): with the `RLIMIT_DATA` fix in the tree,
  `--test files` still failed 8 of 11 until `cargo build -p antennad -p antenna-cli`, then 10 of 11.
- **A test still expected the macOS answer from before the sandbox existed.**
  `agents.rs::taint_hidden_instruction_from_level_2_cannot_act_above_level_2` expected `sender_check:failed` outside
  Linux; with the worker isolated, the sender's check finds the secret on macOS as on Linux (`secret:private_key`). The
  first run passed only because the isolation was broken (`RLIMIT_DATA`), so the fix exposed the stale expectation.
  When a platform gains a feature, search the tests for per-OS expectations of its absence.
- **`update.rs` read the update log from the Linux path.** `install_restart_rollback_and_interruptions` failed on macOS
  with `NotFound` after a successful install: the installer writes `~/Library/Logs/Antenna/update.log` there. The test
  asks `antenna_update::install::default_log_path` for this OS. It had never run on a Mac (it came with D-82, after the
  last CI run); `--no-fail-fast` showed it, because without it `cargo test` stops at the first failing test binary.
- **The macOS CLI archive carried AppleDouble `._*` entries.** macOS `tar` stores extended attributes (quarantine,
  provenance) as `._<name>` files, which unpack as junk on Linux. `packaging/macos/build-dmg.sh` creates the archive with
  `COPYFILE_DISABLE=1` and `--no-mac-metadata`/`--no-xattrs` when this `tar` has them, and fails if `tar -tzf` lists a
  `._*` entry or the mounted `.dmg` contains a `._*` file.
- **A `.dmg` was reported as `unknown_type` / `application/octet-stream`.** A UDIF image starts with whatever its first
  block holds (raw sectors, zlib or bzip2 data); it is recognized by its 512-byte `koly` trailer at the very end
  (version 4, header size 512). It is `application/x-apple-diskimage` now, still `suspicious` (`disk_image`,
  `no_safe_preview`, `secrets_not_scanned`); a recognized format that also ends with a `koly` trailer is a polyglot
  (`polyglot_dmg_trailer`, a threat). On the Mac a real `hdiutil create -format UDZO` image gives the same result.

## 2026-10-03 · Approvals housekeeping and where the owner sees a request (D-84, D-UI-15)

- **A test process has no owner session of its own.** `antenna login --password-stdin` run by a test opens a `parent`
  session: it covers the processes that the test starts, not the test process itself (its parent is cargo). So a raw
  socket connection made by the test is "owner without a session" (`hello_ok.session: "none"`), which is exactly what a
  test of a command allowed without a session needs. To run the CLI without the session, start it through a shell that
  stays its parent: `sh -c '"$0" "$@"; exit $?' antenna …` (with `exec` the shell would be replaced and the CLI would be
  the test's child again). `tests/control.rs::approval_requests_expire_by_themselves_and_deny_needs_no_password` uses
  both.
- **Expiry needs a clock you can wait for.** An approval lives 10 minutes (SPEC §9), so an end-to-end test cannot wait
  for it. `antennad --approval-ttl-ms <ms>` (hidden, tests only) shortens it; it is clamped to the 10 minutes, so it can
  never be used to make requests live longer. The window's live test uses it through `XdNode(extraArgs: …)`.
- **Every version bump changes three golden frames.** `22_settings` and `31_lan(_ru)` show the window version
  (`lib/version.dart`), one digit of it; `32_update` does not (the line is under the dialog). After changing the
  version, run `flutter test --update-goldens test/goldens` and check that only those frames changed.
- **A card that is also in the conversation doubles widget finders.** With a request about the open conversation, the
  card stands both in the conversation and in the "Approval requests" dialog, so `find.text(…)` and
  `find.byKey(Key('approve-<id>'))` find two widgets. Scope them: `find.descendant(of: find.byType(ApprovalsDialog),
  matching: …)`.
- **The conversation column is narrower than the dialog.** The card's line "asked by <agent> · triggered by <contact> ·
  reasons" overflowed by one pixel in Russian in a `Row`; in the conversation it is a `Wrap`.
- **Is the window in focus?** Flutter reports it through `AppLifecycleState`: on macOS `applicationWillResignActive`
  gives `inactive` (or `hidden` when no window is visible), and on Linux the GTK embedder maps
  `GDK_WINDOW_STATE_FOCUSED` to `resumed` / `inactive` (`fl_window_state_monitor.cc`). The window notifies only when
  the state is not `resumed`. In a widget test: `tester.binding.handleAppLifecycleStateChanged(…)`; `hidden` turns frame
  scheduling off in the binding, so put the state back to `resumed` before the test ends (the platform channel fills in
  intermediate states such as `inactive`; this direct call does not, so the test walks them itself).
- **Linux notifications without a desktop in tests.** The `dbus` package has a bus server (`DBusServer`): the test
  starts one on a unix socket in a temporary directory, registers a stand-in `org.freedesktop.Notifications` object
  with a second client, and points the notifier at that address. The `Notify` call is checked as it arrives
  (signature `susssasa{sv}i`, the texts, the `desktop-entry` hint), with no `dbus-daemon` and no notification server.
  With no session bus or no service, `show` returns without an exception (`lastResult: "not shown: …"`).
- **Seen once, not reproduced: `daemon_host_test.dart` "first run" failed with `Connection reset by peer` (errno 104)**
  while the whole widget and host suite ran in parallel; it passed on its own and in the next full runs. If it comes
  back, look at the moment between the window starting its own `antennad` and the daemon accepting on the socket.

### Live window tests time out on a busy build machine (2026-10-03)
- `release-linux.sh v0.1.0-preview.3` failed once in `live_history_test.dart` with `TimeoutException: timeout: delivered: b2 after backup` while another build ran on the same machine (load average 7–8). The test passed 3 of 3 times on its own. Live tests start real daemons and wait for deliveries with fixed timeouts, and `flutter test` runs test files in parallel by default. The release script and the `linux` job now run widget, host and golden tests first (`--exclude-tags live`) and the live tests one file at a time (`--tags live --concurrency=1`).

## 2026-10-03 · Code mode: agents in the window's terminal (`apps/antenna_desktop/lib/state/{agent_launch,code_mode}.dart`, `lib/host/pty.dart`; D-83, D-UI-16)

- **`antenna mcp` refused to bind under a terminal's first process.** A pseudo-terminal's child is a session leader
  (`forkpty` calls `setsid` and takes the terminal as its controlling terminal), and the daemon never makes a session
  leader an anchor (D-28; on macOS only a GUI app's main process, D-P-3): `antenna mcp: forbidden: cannot bind the token
  to "bash" (pid …)`. The window therefore starts a bash wrapper as the session leader and the wrapper **forks** the
  agent (`"$@"; e=$?; …; exit $e`, never `exec "$@"`). The live test keeps this as a negative control
  (`live_code_mode_test.dart`: `antenna mcp` directly under the session leader is refused).
- **The terminal inherited the window's descriptors.** `flutter_pty` forks the window process and `exec`s without
  closing anything; in `flutter test` the child saw an `eventpoll` descriptor and the assets directory (3, 9), the same
  class as the earlier descriptor leak (D-61). The wrapper closes every descriptor above 2 it finds in `/dev/fd` before it starts the agent. dash
  (`/bin/sh` on Debian/Ubuntu) exits on `exec 12>&-` (it handles only one-digit descriptors), so the wrapper runs under
  bash, and each close is tried in a subshell first. Checked: `agent_launch_test.dart` (descriptors 7 and 12 opened by
  the caller are gone) and the live test (the agent's shell has 0, 1, 2 only).
- **The agent's exit code came out as garbage (`-17`, `-74`) or never arrived.** The Dart VM reaps *any* child with
  `wait()` while the process has children of its own (here the daemon, on Linux the window's child too), so it can
  reap the terminal's session leader before `flutter_pty`'s `waitpid(pid)`; `flutter_pty` then reads an uninitialized
  status and may report nothing at all. Fix: the wrapper prints the agent's exit code in a private OSC sequence
  (`ESC ] 6973 ; <code> BEL`, read through xterm's `onPrivateOSC`), and `SystemPty` probes the session leader every
  250 ms (`kill(pid, SIGCONT)` fails with ESRCH once it is reaped). The live test runs `exit 3` with a daemon child
  present and gets 3.
- **The last output of a short command could be lost.** `flutter_pty` closes the output port when it reports the exit,
  and the exit and the output come from two threads. The wrapper pauses 0.2 s before `exit`.
- **A failed `execvp` in `flutter_pty` 0.4.2 lets the forked child continue as a copy of the window** (it neither
  `_exit`s nor returns an error). The window only ever starts an absolute bash path that it checked exists, so `execvp`
  does not fail; the agent's own program is started by the wrapper, which reports "command not found" (127) normally.
- **Copied terminal text lost its spaces** ("Accessingworkspace:"). xterm 4.0.0's `Buffer.getText` skips cells nothing
  was printed into; TUIs such as Claude Code place words by moving the cursor, so the gaps are exactly such cells.
  The window copies through `terminalText` (a blank cell is a space, except the right half of a wide character); the
  live test reads the screen the same way.
- **On Linux, xterm's default shortcuts take Ctrl+V (paste) and Ctrl+A (select all)** away from the program. The
  window maps copy and paste to Ctrl+Shift+C / Ctrl+Shift+V there (Cmd+C / Cmd+V / Cmd+A on a Mac).
- **Claude Code starts its MCP servers only after "Do you trust the files in this folder?"** is answered. Until then
  `antenna agent list` shows no binding; that is expected. (Checked with Claude Code 2.1.233 in the live test, which
  answers with Enter through the terminal.)
- **A login shell resets PATH.** Debian's `/etc/profile` sets PATH outright, so `bash -lc 'antenna …'` does not find a
  CLI the window put in PATH; use absolute paths in an own command that starts a login shell.
- **`flutter test` cannot load plugin libraries.** flutter_tester does not build an FFI plugin's native code; the live
  test compiles `flutter_pty`'s C file with `cc -shared … -Wl,-soname,libflutter_pty.so` and loads it by its full path
  first, after which the plugin's `DynamicLibrary.open('libflutter_pty.so')` finds the loaded library by its soname
  (`test/support/pty_native.dart`). The release build bundles it as `lib/libflutter_pty.so`
  (`packaging/linux/check-desktop.sh` checks for it).
- **macOS needs CocoaPods for `flutter_pty`.** The app's other plugins come as Swift packages; `flutter_pty` 0.4.2 has
  only a podspec, so `flutter build macos` builds it through CocoaPods (`brew install cocoapods`;
  `packaging/macos/build-dmg.sh` stops early without `pod`). To be confirmed on a Mac.
- **The chat header overflowed when the dock took the width** (the conversation was ≈ 320 px at a 1440 px window). In
  Code mode the navigation becomes icons and the chat list 300 px, and the dock never leaves the conversation less than
  500 px; below that it folds to a strip. The filter row of the chat list scrolls sideways instead of overflowing in
  Russian at 300 px.

## 2026-10-04 · Resident agents (`resident.rs`, `sandbox/{supervisor,macos,common}.rs`, D-93)

- **The agent's first turn vanished when stdin became the agent's.** Stage 2 of the sandbox reads its plan as a JSON
  line from the same pipe that later becomes the agent's stdin. `std::io::stdin().read_line` fills an 8 KiB buffer, so
  it could swallow the start of the agent's input, and that buffer does not survive `exec`. Stage 2 now reads its plan
  one byte at a time (`common::read_line_json_unbuffered`); the supervisor writes the plan first and copies the
  lifeline's bytes only after the start gate.
- **Only one writer for the agent's stdin.** The daemon does not hold a second pipe into the sandbox: the lifeline
  (the supervisor's stdin) carries the turns after `go`, and the supervisor copies them to the agent. EOF on the
  lifeline still means "kill the tree". If the agent stops reading, the supervisor's copy blocks; the daemon gives up
  writing a turn after 10 s and stops the process (`Running::stop` → SIGKILL after its grace).
- **`--session-id` with a session that exists fails, `--resume` with one that does not exist fails.** Claude Code
  refuses both. The daemon marks the session as created on the agent's `system/init` line or its first `result`, and
  resumes from then on; if a resume dies before any output (the transcript was never written), the next start uses
  `--session-id` with the same ID once. The fake agent in the tests refuses both cases the same way, so the tests
  would catch a wrong flag.
- **Claude Code's interrupt is not in its public docs.** `{"type":"control_request","request_id":"…","request":
  {"subtype":"interrupt"}}` on stdin; read in the 2.1.233 binary and tried in the real run.
- **The prompt cache TTL is Claude Code's choice, not ours.** 2.1.233 uses a 1-hour cache for a claude.ai
  subscription login on `-p` turns unless `FORCE_PROMPT_CACHING_5M` is set (or 5 minutes for an API key unless
  `ENABLE_PROMPT_CACHING_1H`); an opt-in compacting timer (`--compact-idle 50m`) assumes the hour. With an API key,
  use `--compact-idle 4m`.
- **A fake agent for bash 3.2.** macOS ships bash 3.2: no fractional `read -t`, so the fake agent's "slow turn" polls
  stdin with `read -t 1`; the orientation text that the daemon prepends to a non-Claude program's first turn mentions
  "[Antenna] Your owner", so the fake recognizes owner turns by "[Antenna] Your owner writes".
- **"Same process" inside bwrap.** The agent's PID inside its PID namespace is the same small number after every
  restart (`pid=3`), so the tests prove "one process" by the process start counter the fake keeps in its HOME, not by
  the PID.
- **Claude Code's `total_cost_usd` is a running total per process, `usage` is per turn** (the real run: the second
  turn reported the first turn's cost plus its own, while its `usage` held only its own two calls). The daemon keeps
  the last total of the running process and adds the difference; the fake agent in the tests reports a running total
  too, so summing the raw values fails the test.
- **The first real resident reply narrated and talked about sending.** With only "your text is the reply" in the turn,
  Claude Code wrote "just a simple acknowledgment task, nothing requiring tool use beyond the reply" and then that it
  lacked permission to send, and all of it went to the contact (the reply is every text block of the turn). The
  orientation and the turn now say that the daemon delivers the text itself, there is no tool for sending, and the
  text goes out as is; the next run's first reply was just the reply.
- **After compacting the context looks tiny.** Claude Code's `compact_boundary` reports `post_tokens` for the
  compacted conversation only (947 in the real run, from 33,166), not its fixed system prompt and tool definitions
  (about 32,000 tokens), so the next turn's context is again above 32,000. `wake list` shows `post_tokens` until the next
  turn.
- **`cargo test -p antenna-cli` ran a stale `antennad` again** (N.7, K.6): after the cost fix the resident test still
  saw the old sums, because the daemon was the earlier build. Build both first: `cargo build -p antennad -p
  antenna-cli`.

## 2026-10-04 · Connecting AI apps, token files, sending by content, task authority (`apps/antenna_desktop/lib/state/{ai_apps,mcp_config,ai_apps_model}.dart`, `crates/antenna-core/src/agents.rs`, `crates/antenna-cli/src/{main,mcp}.rs`; D-85…D-89, D-UI-17)

- **A token pasted into a chat.** The old "Connect an agent" screen showed the token and a `claude mcp add --env
  ANTENNA_AGENT_TOKEN=…` command; such a command ended up in an AI chat. Now the daemon writes the token to
  `<data-dir>/agents/<name>.token` and every config and snippet names the file. If a token was shown anyway (an older
  daemon), revoke it: `antenna agent token <name> --token-file` or "Revoke and create a new token". A leaked token
  works only through this computer's socket and only from the process it is bound to, but there is no reason to keep
  it (CONTROL §11 item 3).
- **`token file …: permissions 644 let other users read the token`.** The CLI refuses a token file that group or
  others can read, a symlink, a file of another user, more than 4 KiB or something that is not a token, like ssh with a
  key: `chmod 600 <file>`, or let the daemon write it (`antenna agent token <name> --token-file`).
- **The app has an Antenna entry but the status stays "Waiting for the app".** Most apps read their MCP file only when
  they start: restart the app (ChatGPT: Settings → MCP servers → Restart; Claude Desktop: quit completely). Claude Code
  starts MCP servers only after the folder trust question. Check the app's own list (`/mcp` in ChatGPT, Codex, Claude
  Code, Gemini CLI; Connectors in Claude Desktop).
- **`token_bound` in an app's MCP log.** One token binds to one MCP host at a time (D-28). The ChatGPT app and a Codex
  CLI session share `~/.codex/config.toml`, so the second one is refused while the first runs; an app that starts a
  server per window gets one working window. Quit the other one, or give one of them its own agent (Code mode does).
- **Environment variables do not reach the server.** Gemini CLI drops `*TOKEN*`, `*KEY*`, `*SECRET*` variables unless
  set in `env`; Codex forwards only `env` and `env_vars`; Claude Desktop passes "a limited subset" and may start servers
  in `/`; Copilot CLI only `PATH`. Use `--token-file` with absolute paths (what Connect writes).
- **"Antenna does not edit … by itself".** The file is not plain JSON (comments, trailing commas: Zed's settings,
  often VS Code's), or Antenna's server is defined in another form in a TOML file. Nothing was changed; add the entry by
  hand from the guide.
- **"The file changed while you were reading it".** Another program saved the file between the review and the click.
  Nothing was written; the review shows the file as it is now.
- **Backups.** Every write keeps `<file>.antenna-backup-<yyyyMMdd-HHmmss>` next to the file (0600 at most: other
  servers' secrets may be in it). They are not removed automatically.
- **Windsurf's file moved.** Windsurf is Devin Desktop now and reads `~/.config/devin/mcp_config.json`; the old
  `~/.codeium/windsurf/mcp_config.json` is ignored.
- **LM Studio on macOS** may keep its MCP file at `~/.cache/lm-studio/mcp.json` (an open LM Studio bug); the install
  link avoids the question.
- **Two Antenna servers in one app.** Grok Build reads `~/.claude.json` and `.cursor/mcp.json`, Warp reads Claude and
  Codex files, VS Code can discover others. Antenna's entry is always named `antenna`, so the app sees one server.
- **`share_file_content` with a large file.** The model has to write the base64 into its tool call; past a few hundred
  KiB that is slow and costly for the model, even under the 25 MiB limit. Agents on this computer should send by path
  (`share_file`).
- **Widget tests: `setState() or markNeedsBuild() called during build`.** Reading the apps' files in a card's
  `initState` and notifying the model rebuilt the tree mid-build: `scanAiApps(notify: false)` there.
- **Widget tests: "Looking up a deactivated widget's ancestor" in a dialog's `dispose`.** Keep the model reference
  taken after the first frame; never look it up from `dispose`.
- **Widget tests: "A TextEditingController was used after being disposed" after the password prompt.**
  `askOwnerPassword` disposed its controller when the dialog's future completed, while the closing animation still drew
  the field; the prompt is now a widget that owns its controller.
- **A `RadioListTile` inside a coloured container** paints its ink on the nearest `Material`, and Flutter asserts
  ("ListTile background color or ink splashes may be invisible"); the choices are `InkWell` rows with a `Radio`, as in
  the role preset.
- **Golden and widget tests: an Agents section taller than the window.** The AI apps card comes first now; a
  `ListView` builds only what is near the screen, so tests that look for agent rows use a tall test view.
- **Gemini CLI's schema rejects unknown top-level keys** (`additionalProperties: false`): the test sample uses
  `{"ui": {"theme": …}}`, not an invented `theme` key.
- **The live history test once timed out (1 min 5 s) on a busy build server** and passed twice right after (7 s); see
  "Live window tests time out on a busy build machine".
- **`agents.rs::invite_lives_in_the_daemon…` failed once with `BrokenPipe` at `tests/common/mod.rs`** (a full workspace
  run while window tests ran on the same machine; 0 failures in the next 12 runs). The helper that feeds a password to
  the CLI panicked on the write when the CLI had already exited, which hid the CLI's own error. The helper now accepts
  `EPIPE` there, and the caller's check of the exit status prints the CLI's output.

## 2026-10-04 · Addressing, topics, what an agent reads, batch approvals (`addressing.rs`, PROTOCOL §23, CONTROL §20; D-90…D-92)

- **An agent's `inbox` / `wait_for_message` stays empty after the contact wrote** (v6). The contact's owner writes to
  the person by default, and an agent never reads what is for the person (D-91). The contact addresses the agent:
  `antenna send <contact> --to-agent <name> <text>` (or the window's "To:" picker, or MCP `send_message` with
  `to_agent`), or writes to everyone (`--to everyone`) and the receiving owner allows that agent messages to everyone
  (`antenna agent set <name> --everyone on`). Integration tests written before v6 that had a contact "talk to the
  agent" needed exactly this (`send_to_agent` in `tests/common`). How to check: `antenna history <contact> --json` shows
  `to` / `to_agent` of each message; an agent with `everyone: false` reads only `to: "agent"` with its own name.
- **An agent created after the upgrade does not see an older node's messages.** A `0.1.0-preview.3` node cannot
  address, so its messages count as to everyone, and a new agent has `everyone: false`. Turn it on for agents that
  talk to such contacts, or update the contact. Agents created before the upgrade kept `everyone: true`.
- **A message addressed on this side arrives unaddressed at the contact.** The contact's node did not advertise
  `addr/0` when the message was written (`sent.addressed: false`, `contacts[].peer_addressing: false`): it is older,
  or the node had not connected since the contact upgraded. The address stays in this node's history only; the contact
  sees an ordinary message. Fields that an older node would refuse are never sent to it (D-90), so nothing is `failed`.
- **The agent's reply went to the wrong counterpart.** Without `to`, an agent's message answers the last message it
  read with `inbox` on that link; reading through `history` does not count. Pass `to_agent` / `to` explicitly when the
  agent starts a new conversation or switches counterparts.
- **`approvals` lists fewer requests than `approve_many` decided.** Over 3 requests from one contact or one agent in 10
  minutes are "quiet" (SPEC §9) and are listed only by `approvals --all`; batch approval takes their IDs all the same.
- **Code note, the agent's cursor.** The agent's cursor moves past messages it may not read (otherwise every `inbox`
  call would rescan them), and the "what does a reply answer" pointer is written only into the cursor row that moving
  the cursor created: inserting a fresh row there would carry cursor 0 and show the agent messages from before it was
  created (D-30).

### Window (x-control/6, D-UI-18)
- **A widget test taps a popup menu item and misses** (the tap lands below a 1000 px test window). After one
  `pump(400ms)` the menu is still sizing; `pumpAndSettle()` after opening it.
- **"A TextEditingController was used after being disposed"** when the topic dialog closes:
  `showDialog(...).whenComplete(c.dispose)` disposed the controller before the closing animation rebuilt the field. The
  dialog's `State` owns the controller now.
- **A live test waits for the 4th approval in the window and times out.** Requests beyond 3 per contact in 10 minutes
  are quiet (no event); decide them by ID or read `approvals --all`.
- **A test that asserts the old "mark read up to seq" rule fails on the fake daemon**: the fake speaks v6 and marks by
  thread; set `FakeDaemon..protoVersion = 5` for the older behavior.
- **"Approve all from this agent" was off screen** on the first card (the list is reversed and lazy): it is offered on
  the agent's last card, the one nearest the input.

## 2026-10-04 · Lints, the dispatcher splits and the Experimental tag (preview.4 polish; D-94)

### Lints
- **`undocumented_unsafe_blocks` fails only in `tools/check-darwin.sh` after adding a `reason` to `#[allow(unsafe_code)]`.**
  rustfmt lays an attribute whose arguments are longer than about 70 characters over several lines, and the lint no
  longer finds a `// SAFETY:` comment that sits above a multi-line attribute on an `unsafe impl`. Put the `SAFETY`
  comment directly above `unsafe impl`, below the attribute (`antenna-sys/src/darwin.rs`). macOS-only code is seen only
  by the darwin check: run it after any lint change.
- **More `#[allow]` attributes than the Linux survey counted.** `allow_attributes_without_reason` on Linux sees 33;
  the macOS-only wrappers of `antenna-sys` and `cfg_attr(not(target_os = …), allow(…))` add 19 more. Grep the source
  (`grep -rn 'allow(' crates`) rather than trusting one target's clippy.
- **A lint for one crate or one module only.** A crate with `[lints] workspace = true` cannot add its own lints in
  `Cargo.toml` (Cargo refuses the mix). The update path's `print_stdout`/`print_stderr` are an inner
  `#![deny(…, reason = "…")]` in `antenna-update/src/lib.rs` and at the top of `antenna-cli/src/update.rs`.
- **The unwrap/panic pass and test code.** `cargo clippy --lib --bins` does not compile `#[cfg(test)]` modules or the
  integration tests, so `-D clippy::unwrap_used -D clippy::panic` there needs no `allow-unwrap-in-tests` config; a
  test helper's `unwrap` never reaches it. How to check: put an `unwrap()` in a `#[cfg(test)]` function, the pass stays
  green; put one in library code, it fails.
- **Moving a match arm into a function surfaces a new lint.** `Ok(s.wake_list().map_err(b)?)` passed clippy inside a
  match arm and failed `needless_question_mark` as a function's tail: return `s.wake_list().map_err(b)`.

### One handler per command
- **rustfmt lays a struct pattern with several fields over several lines** (`struct_lit_width` is 18 by default), so
  "one line per arm" cannot hold for struct variants with long field lists. In the CLI, a clap struct variant becomes
  `Variant(VariantArgs)` with `#[derive(Args)]`, and the arm stays one line; the fields keep their docs and attributes.
  In the core, `Request`'s variants are wire types and stay as they are: an arm is one call, and rustfmt may spread its
  pattern; `send` and `wake_set` (8 and 12 fields) take the request and destructure it, as the invite and join dialogs
  do. A `..` pattern with no bindings does not move the scrutinee, so such an arm can pass `req` on.
- **Proving a CLI refactor changed nothing.** Dump `antenna <command> --help` and `-h` for every command, the agent
  CLI's help (`ANTENNA_AGENT_TOKEN=xat_x antenna <command> --help`) and a few argument errors before and after, from
  binaries with the same file name (clap prints `argv[0]` in the usage line), and `diff -r`: 153 outputs were byte for
  byte equal. For moved bodies, compare each new function's body with the old arm with whitespace removed.

### Window: the Experimental tag
- **`l10n_guard_test` fails on a new test file** ("Russian text lives only in the Russian localization"): a Cyrillic
  literal in the test. Compare with the generated localization (`ru.experimentalTag`), never a literal.
- **A tag after a dialog title left a gap when the title wrapped**: a wrapped `Text` in a `Row` takes the full width.
  Put the tag in a `Text.rich` `WidgetSpan` after the title (`XDialogShell.titleTag`), so it follows the last word.
- **Comparing golden PNGs by file name mixed the two sets** (`test/goldens` and `docs/design/screens` use the same
  names), and `ImageChops.difference(...).getbbox()` returned `None` for opaque RGBA frames (the alpha of the
  difference is 0 everywhere). Key the copies by full path and convert to RGB before `getbbox`.

## 2026-10-05 · macOS 27 on a real Mac (D-95, D-97, D-98; `sandbox/proxy.rs`, `app_hosts.rs`, `invites.rs`, the test harness)

The first full `cargo test --workspace` on a clean Mac with macOS 27.0.1 (build 26A434, arm64), from tag
`v0.1.0-preview.4`: 381 passed, 10 failed, 9 ignored, 2 hung. The suites that failed had never run on a Mac (resident
agents came after the macOS 26 round) or assumed Linux.

- **Every resident-agent test failed on macOS: the proxy socket path was 105 bytes, macOS allows 103.** Symptom: an owner
  turn ended with empty text (`resident.rs:472`, `:533`) and a contact's message got no reply ("timeout waiting for reply").
  Cause: the resident agent's CONNECT proxy listens on `<data>/wake/resident/<16 hex>/proxy.sock`; the tests' data folder
  lies under macOS's `$TMPDIR` (`/var/folders/4x/…/T/`, 49 bytes on that Mac), so the path was 49 + 11 (`.tmpXXXXXX/`) +
  4 (`bob/`) + 41 = 105 bytes, over `sun_path` (104 including the terminating zero); a one-shot run's socket
  (`wake/runs/<12 hex>/proxy.sock`) is 4 bytes shorter and still fit. The bind error went into the turn's `detail`, which
  the test did not print. Reproduced on Linux with a long `TMPDIR` (`TMPDIR=/tmp/<46 characters>`: "proxy bind …: path must
  be shorter than SUN_LEN"). Fix: a socket path that does not fit becomes `/tmp/antenna-<uid>/<hash of the path>.sock`
  (a private directory created with `mkdir` 0700 and checked to be ours; a squatted name falls back to a random one; stale
  sockets there are removed). Test: `sandbox::proxy::tests::a_long_socket_path_moves_to_a_short_private_directory`; the
  resident and wake suites pass with the long `TMPDIR`. Takeaway: every unix socket the daemon creates must fit `sun_path`
  on macOS from a `$TMPDIR` data folder, not only the control socket (which `control::bind` already checked).
- **macOS has no `/bin/true`** (only `/usr/bin/true`, as in every macOS): two agent tests set a wake rule with
  `--cmd /bin/true`, which the daemon refuses as a missing program. The tests use `common::true_bin()`.
- **`/bin/sh` runs bash on macOS**, so the bound MCP host (`sh -c '… mcp'`) is named `bash`; two tests expected `sh`. They
  compare the bound PID with the `sh` they started (`Mcp::host_pid`) and keep the name check on Linux only.
- **The suite run from inside an agent's session hit the agent's variables.** The Mac's agent ran the tests in the window's
  Code mode, where `ANTENNA_AGENT_TOKEN` is set (and an agent CLI may get `ANTENNA_SOCKET`): every `antenna` the tests
  started acted as that agent, `init` failed in all 15 tests of `agents.rs`, and `ANTENNA_SOCKET` (which wins over
  `--data-dir`) could have pointed a test at the owner's real daemon. The harness and every raw spawn now drop those
  variables first (`common::CleanEnv`); checked by running the suites with `ANTENNA_SOCKET`, `ANTENNA_AGENT_TOKEN`,
  `ANTENNA_AGENT_TOKEN_FILE` and `ANTENNA_DATA_DIR` set to bogus values.
- **`cargo` was not on PATH in the Code mode terminal** (a window started from the Dock has launchd's PATH; `~/.cargo/bin`
  is added by the shell profile). The window now starts agents with the login shell's PATH (window TROUBLESHOOTING section
  below); until then, prefix commands with `export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"`. Agents started on wake
  now also get `/opt/homebrew/bin` and `/opt/homebrew/sbin` on macOS (the sandbox already lets them read `/opt/homebrew`,
  except its `var/` and `etc/`).
- **Two installer flow tests "hung"** (`install::flow_tests::app_failure_points`,
  `bindir_a_failure_at_any_point_leaves_the_old_version`). Run alone on the same Mac they passed in about 2 s, so no stack
  could be sampled, and the cause is not known yet: the guards below name it on the next full run. Every flow test now runs on its own thread and fails
  after `ANTENNA_TEST_TIMEOUT_SECS` (120 s here) with "did not finish … it hangs", and every integration test node has a
  watchdog (600 s by default) that prints the test's name and the daemon log tail, kills the daemon, and exits the test
  process with 124 if that does not end the test. A failing integration test now prints the tails of its daemons' logs and
  of the wake logs (the temporary directory is gone afterwards).
- **Claude Desktop starts several `antenna mcp` from one config entry** (its chats, and a pool for Cowork and Code
  sessions), each under another process of the app; the first bound the token and the others got `token_bound`, so Claude
  Desktop said "Couldn't start for Cowork and Code sessions". An MCP host of the same running app now joins the agent
  (D-97); a refused process's chain is logged with command names, which shows on a Mac where a host sits in the app's tree.

## 2026-10-05 · Window fixes from the macOS 27 run (`apps/antenna_desktop`: `lib/host/{program_locator,app_connect}.dart`, `lib/ui/pairing/`, `lib/ui/agents/connect_next_steps.dart`; D-95)

- **The status line said "relay n0 · 0 contacts" after a pairing.** It showed `links` from the `status` reply, which
  the window reads once when it connects (and on `/status`); the 10 s poll refreshes `contacts`, not `status`. It now
  counts the window's contact list, which is re-read right after every new link. Verify: `status_line_test.dart`
  (inviter, joiner, pending invite).
- **AI apps said "Not found on this computer" for a CLI that is installed.** A window started from Finder or the Dock
  has launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). Causes the old search did not cover: the list was scanned
  only when the Agents page opened (a CLI installed while it was on screen stayed "not found"), a non-executable file
  earlier in the list won over the real program, and CLIs reachable only through the user's shell setup (nvm, a custom
  npm prefix) were never found. One locator now serves AI apps, Code mode and the agent's PATH (CONNECT-APPS "Finding
  the apps"); the list scans again when the window comes back to the front. Check on the Mac: `ls -l
  ~/.local/bin/claude; stat -L ~/.local/bin/claude` (a link to a removed version is skipped on purpose), and the
  window's own environment:
  `ps -E -ww -o command= -p "$(pgrep -x Antenna)" | tr ' ' '\n' | grep -E '^(HOME|PATH|SHELL)='`.
- **Reading the login shell's PATH.** `$SHELL -ilc` (interactive, so `.zshrc` and nvm count) prints greetings and
  prompts too: only the marker lines are read. `printenv PATH` rather than `"$PATH"`, which fish joins with spaces. A
  process the profile leaves in the background can keep the output pipe open: the window waits for the shell to exit
  (5 s at most, then kills it) and only 300 ms more for the pipe.
- **"Restart <app> now" and macOS Automation.** Quitting another app gracefully is an Apple Event (`osascript -e 'tell
  application id "<id>" to quit'`); the first time, macOS asks whether Antenna may control the app, and only if the
  app's Info.plist has `NSAppleEventsUsageDescription` (without it the event fails with -1743 and no prompt). The
  osascript child counts as Antenna (its responsible process). A refusal is -1743: the window says so and keeps "Open"
  (the owner can allow it later in System Settings → Privacy & Security → Automation). The app may also cancel its
  quit (-128) or ask something: the window then says it is still open. `application id "<id>" is running` needs no
  permission and does not launch the app. With a hardened-runtime signature (a Developer ID build) the app would also
  need the `com.apple.security.automation.apple-events` entitlement; the ad-hoc build has no hardened runtime.
- **Claude Code in Code mode warned "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION", and `cargo` was
  not found in the agent's terminal.** The window had been started from another Claude Code session, and flutter_pty's
  child keeps the window's whole environment (it only adds variables with `putenv`), launchd's short PATH included.
  The wrapper now removes every variable of the window that is not on an allowlist (`agentEnvKeep` in
  `agent_launch.dart`: home, user, locale, display, SSH agent, proxies, certificates, vendor API settings) before it
  starts the agent, so `CLAUDECODE`, `CLAUDE_CODE_*`, `CODEX_*`, `GEMINI_CLI*`, other agents' tokens and the like never
  arrive; the agent's PATH is the login shell's PATH (only PATH is taken from it), then the standard tool folders
  (`~/.cargo/bin`, `~/.local/bin`, `/opt/homebrew/bin` and `sbin`, `/usr/local/bin`, the npm prefix). Check in a Code
  mode terminal: `env | grep -E '^(CLAUDE|CODEX|GEMINI)'` prints nothing; `which cargo brew claude` resolve.
- **A D-95 daemon accepts `pairing_confirm` with `code: ""` as a confirmation without the code** when the invite
  offers it (the CLI drops an empty `--code`). The window never sends an empty code (it refuses one locally), and
  `live_daemon_test.dart` checks the empty and missing code only against daemons that do not offer the confirmation.

## 2026-10-05 · Code mode terminal: underlined lines (`apps/antenna_desktop/lib/state/terminal_sgr.dart`)

- **Symptom.** In Code mode every line of Claude Code's screen was underlined (found on a clean Mac, preview.4), and
  everything after the first bold word was bold; the TUI looked broken. Plain shell output looked fine.
- **Cause: xterm 4.0.0 misreads SGR sequences that modern CLIs write**, and since these CLIs end an attribute with its
  own code (`CSI 22 m`, `CSI 24 m`, `CSI 39 m`) rather than `CSI 0 m`, the wrong attribute sticks to every following
  cell:
  - `CSI > 4 ; 2 m` and `CSI > 4 m` (xterm's modifyOtherKeys, XTMODKEYS) and `CSI ? 4 m` (XTQMODKEYS) are not SGR, but
    xterm 4.0.0's `_csiHandleSgr` ignores the `>` / `?` and reads SGR 4 (underline) and 2 (dim). Claude Code 2.1.233
    writes `CSI > 4 m` on exit, when it leaves the alternate screen and when it leaves raw input mode, and
    `CSI < u CSI > 1 u CSI > 4 ; 2 m` at start whenever its environment names iTerm2, kitty, WezTerm, Ghostty, tmux,
    Windows Terminal or Warp (`TERM_PROGRAM`, `TMUX`, `KITTY_WINDOW_ID`… inherited from the window: `flutter_pty`
    merges the window's whole environment into the child's). Recorded in a pseudo-terminal with
    `TERM_PROGRAM=iTerm.app`: the very first SGR is `CSI > 4 ; 2 m`, and fed to xterm 4.0.0 all 755 text cells of the
    main screen come out underlined.
  - `CSI 22 m` (normal intensity) ends dim but not bold (4.0.0 maps 21 to "bold off" and 22 to "dim off").
  - Colon sub-parameters lose the colon: `CSI 4:3 m` (curly underline) and `CSI 4:0 m` (no underline) become 43 and
    40, background colors; `CSI 38:2::R:G:B m` becomes one unknown number.
  - `CSI 58 ; 5 ; N m` (underline color) is unknown, so its arguments run as SGR codes of their own (5 blink, 1 bold,
    4 underline), and `CSI 59 m` does not undo them. `CSI 38 ; 5 m` without the index throws `RangeError` in the parser.
  xterm's latest release is still 4.0.0 and its main branch has the same parser; the maintained MIT fork `xterm2`
  (≥ 5.0.0, 2026-07) parses all of these.
- **Fix.** `SgrFilter` sits between the UTF-8 decoder and `Terminal.write` (one per process, in `AgentRun._attach`) and
  rewrites only these sequences into codes 4.0.0 reads as meant: private `CSI <|=|>|? … m` are dropped; `22` becomes
  `21;22`; `4:0` becomes `24` and `4:1`…`4:5` become `4` (one underline style); `38:5:N`, `38:2::R:G:B` and
  `38:2:R:G:B` become their semicolon forms; `58`/`59` and their arguments are dropped; a color with missing or out of
  range values is dropped; a leading empty parameter gets its default 0. Everything else passes byte for byte; a
  sequence split between two reads is held until its end (at most 256 characters). The filter relies on 4.0.0's own
  readings (`21` = bold off): remove it when the terminal package changes (STACK "Code mode").
- **How to verify.** `flutter test test/widget/terminal_sgr_test.dart` (the first test pins what 4.0.0 misreads and
  fails once a package upgrade parses SGR differently; the last one sends Claude Code's start sequence through Code
  mode's real output path and fails without the filter); golden `44_code_terminal_attrs` (only the words "underlined"
  are underlined; without the filter the whole terminal is underlined and bold, and `4:3` paints a yellow
  background). On a computer: start an agent with the own command `bash` in Code mode and run
  `printf '\033[>4;2m\033[1mbold\033[22m plain \033[4:3mcurly\033[4:0m plain\n'`: only "curly" is underlined and
  only "bold" is bold. For Claude Code's own path, start the window from an iTerm2 shell
  (`/Applications/Antenna.app/Contents/MacOS/Antenna`, so `TERM_PROGRAM=iTerm.app` reaches the agent) and start Claude
  Code in Code mode: no line is underlined.
- **Verified on a real Mac** (macOS 27.0.1, 0.1.0-preview.5, 2026-10-05): Claude Code in Code mode shows no underlined
  lines.

## 2026-10-05 · Own computers and approvals the daemon carries out (`approvals.rs`, `policy.rs`, `antenna-cli/src/hook.rs`; D-99, D-100)

- **Every accept from a level-5 contact failed: "level 5: the owner has not set a project folder".** Level 5 saves
  into `--project-dir`, and the desktop app never sets one. Without a project folder, level 5 now saves into the link's
  `shared/` (D-99). How to check: a file from a level-5 contact ends up in `~/Antenna/links/<contact>/shared/`.
- **The update to preview.5 could not be accepted on a preview.4 node whose sender is at level 5.** The fix above is
  inside the update, so the update files hit the same error. Workaround: lower the sender to level 4 for a moment
  (the files go to `shared/`), accept them, install from the manifest card, then set level 5 again in the new
  version. Lesson: before sending an update over a link, check that the receiving version can accept files at that
  link's level.
- **A host hook that waits longer than the host lets it does not block the tool.** Claude Code gives a command hook
  60 s by default and treats a hook that runs out of time as a non-blocking error: the tool runs. `antenna hook
  claude-code` therefore waits for the owner's decision at most `--approval-wait-secs` (50 by default) and then
  blocks with a message; raise both the host's `timeout` and this flag together, never this flag alone.
- **The agent's repeat raced the daemon's run of the same approved request.** If the approval was only marked
  approved and the daemon's task started a moment later, an agent repeating the call in between used the approval
  itself, and the daemon's run then failed with `approval_used`. The approval is now claimed for the daemon's run in
  the same step as the approval (`claim_completion`), and a repeat waits for that run's result (D-100).
- **"another text" with an approval ID was sent instead of refused.** A request that needs no approval at all (no
  secret, no flow between links) ignores an `approval_id`, as before; only a request that needs approval is checked
  against the ID's binding (`approval_mismatch`). Tests that expect a mismatch must send something that needs
  approval.
- **The daemon carried out an accept, and the agent's repeat got "already accepted".** The state check came before
  the approval check. A repeat of an accept the daemon carried out is now answered from the stored result first (with
  or without the approval ID).
- **Checking an older commit in a copy of the tree with the same `CARGO_TARGET_DIR` made later builds stale.** Cargo
  names workspace crates' artifacts by a hash of the path relative to the workspace root, so a copy of the tree
  elsewhere writes the same artifact names; its sources then count as the up-to-date ones and edits in the real tree
  are not rebuilt ("no `ApprovalResolution` in `control`" while the source plainly has it). Give the copy its own
  target directory, or `touch` every source file of the real tree afterwards (`find crates -name '*.rs' -exec touch
  {} +`).

## 2026-10-05 · Composer: dropped screenshots and dictation (`apps/antenna_desktop`: `lib/host/{outgoing_staging,window_drop,paste}.dart`, `macos/Runner/ComposerInput.swift`)

Found on a clean Mac (macOS 27, Antenna 0.1.0-preview.4). Stack choices: STACK "Composer: files and text from other
apps".

### Drops
- **A screenshot dragged from the floating thumbnail: "Not sent: file not found".** The path was
  `/var/folders/…/T/TemporaryItems/NSIRD_screencaptureui_…/Screenshot … .png`. The thumbnail offers a file promise and a
  file URL to a temporary copy, and deletes that copy as soon as the drag ends. `desktop_drop` prefers the URL and hands
  it to Dart only after `performDragOperation` has returned; `share_file` makes the daemon open the path when the
  request arrives, by then it is gone (`not_found`). Fix: on macOS the Runner's drop view stages before the drop ends
  (promises first, received into the window's staging folder; files cloned with `clonefile(2)`, or copied up to
  64 MiB; image data written as `image-<date>-<time>.png`) and the window sends the copies; on Linux the window opens
  each dropped file before its first `await` and copies it. Tests: `test/host/outgoing_staging_test.dart` (the source
  deleted right after the call, and 100 ms later), `test/widget/composer_input_test.dart` (with a negative control: the
  same drop without staging reaches the fake daemon as a missing file). On a Mac:
  `apps/antenna_desktop/test/macos/drop_check.swift` drags a picture into the window as a URL, a promise, both, or
  data, and deletes its file N ms after the drag ends.
- **The staging folder cannot be inside the daemon's data directory**: `share_file` refuses those paths (`forbidden`,
  "files of the Antenna daemon … are never shared"). It is `~/Library/Application Support/Antenna/outgoing` on macOS
  and `$XDG_CACHE_HOME/antenna/outgoing` on Linux (`OutgoingStaging.forEnv`, tested).
- **A copy may be deleted only after the daemon's reply, not after the request.** The owner's approval for a file with
  a secret is bound to the path, the name and the BLAKE3 (CONTROL §14), and the retry sends the same path: the copy
  stays while the card waits for approval or a retry, and goes on success, on "Don't send"/"Dismiss", on lock, or after
  a day (the sweep).
- **One file promise can deliver several files into one folder**: deleting the folder after the first send would take
  the others. `release` deletes the file, then the folder only when it is empty.
- **`dart:io` makes folders with the umask's mode and has no chmod**: `Directory.createTemp` gave 0755 on the build
  server, not the 0700 of `mkdtemp(3)`. The staging folder is set to 0700 with `/bin/chmod` when its mode is looser
  (once per installation), and each copy sits in a folder of its own inside it.
- **`desktop_drop` adds its own drop view on macOS** when the plugins are registered. Two views registered for the same
  types: the window's view is added above it and unregisters the others' dragged types
  (`registeredDraggedTypes`), so only one takes the drop.
- **Async file IO does not complete in `testWidgets`** (fake async): a widget test that stages a real file wraps the
  drop in `tester.runAsync`.
- **A golden with an `Image.file` thumbnail hung for minutes** (the attachment chips, frame `49_composer_staged`): the
  frame started loading the file inside fake async, and `precacheImage` under `runAsync` then waited for that same
  cached load, whose completion sits in the fake zone. Load the image into the cache under `runAsync` before the
  frame is pumped, with the same provider the widget makes (`ResizeImage(FileImage(file), width: 80)` for
  `Image.file(…, cacheWidth: 80)`): `_cacheThumb` in `test/goldens/file_scenarios.dart`.

### Dictation and paste
- **Text from Superwhisper (Wispr Flow, Raycast, text expanders) "just disappears".** They put the text on the
  pasteboard and post a Cmd+V with Command only in the event's flags, with no Command key press before it. Flutter
  3.47 drops that event (flutter/flutter#184571); it ends in Edit > Paste, whose `paste:` goes to
  `FlutterTextInputPlugin`, an `NSTextView` the engine keeps for accessibility; the inherited `paste:` changes only that
  view. Fix: a local event monitor in the Runner catches a Cmd+V with no Command press seen in the event stream (no
  `flagsChanged`), reads the pasteboard text at once (the app may put the old clipboard back a moment later:
  Superwhisper's "Restore clipboard") and hands it to the window over `antenna/paste`, which inserts it at the cursor;
  the Runner also gives `FlutterTextInputPlugin` its own `paste:` and `pasteAsPlainText:` (Edit > Paste from the menu
  bar) and `setAccessibilitySelectedText:` (tools that write AXSelectedText, flutter/flutter#191503).
- **An accessibility read-back of the field is not proof**: the text sits in the accessibility view while the Flutter
  field stays empty, so the dictation app reports success. Check visually, or send the text and read it back:
  `apps/antenna_desktop/test/macos/paste_check.swift` posts each shape (flags-only Cmd+V, a discrete one, an
  AXSelectedText write, rich pasteboard types, a restored clipboard), presses Return, and
  `antenna history <contact> --limit 1` shows what arrived.
- **Telling a synthetic Cmd+V from a typed one**: `CGEventSource.keyState` reports Command as down during exactly the
  synthetic events (posting an event with the flag updates the source's state), so it cannot tell them apart. Track
  `flagsChanged` instead, and forget Command when the app resigns active (a release in another app never arrives).
- **Text next to an image on the clipboard** (a spreadsheet cell, a word processor selection, a file copied in Finder:
  its name as text and its icon as an image): the text goes into the field and the image is ignored, as in a native
  text field; an image alone becomes an attachment that waits above the field for Send. The composer overrides
  `PasteTextIntent` from an `Actions` above its `TextField` (`EditableText` makes its paste action overridable):
  `callingAction`, the field's own paste, is valid only during `invoke`, so it runs first and the image check follows.
- **Reading a clipboard image on Linux**: `gtk_clipboard_wait_for_image` spins a nested main loop, which must not run
  inside a platform message handler; `linux/runner/clipboard_channel.cc` uses `gtk_clipboard_request_image` and replies
  from its callback. Text-only clipboards give a null pixbuf (no image). Checked under Xvfb with a GTK process owning an
  image (`Gtk.Clipboard.set_image`): the window got a PNG; with text only, `null`.
- **Verified on a real Mac** (macOS 27.0.1, 0.1.0-preview.5, 2026-10-05): a screenshot dragged straight from its
  floating thumbnail attaches without the "not found" error, and Superwhisper dictation lands in the message field.

## 2026-10-05 · Code mode wake (`apps/antenna_desktop/lib/state/{code_wake,code_mode}.dart`; D-UI-23)

- **Text and Enter in one write do not send in Claude Code.** Writing `"<line>\r"` into Claude Code 2.1.233's terminal
  in one piece left the line in its input box with a line break after it: Claude Code reads a burst of input as a
  paste, and a carriage return inside a paste is a new line, not "send". **Fix:** `AgentRun.typeLine` writes the text,
  then Enter as a write of its own 300 ms later. **Verify:** in a pseudo-terminal running `claude`, write the text and
  `\r` together (it stays in the box), then the text and, after a pause, `\r` (it is sent); the live
  `live_code_wake_test.dart` and the widget tests check the two writes.
- **A permission dialog has the same `❯`.** Claude Code marks the selected option of a dialog with `❯` too
  (`❯ 1. Yes`), and Enter there answers "Yes". The idle check therefore requires the prompt row between two
  horizontal rules, nothing typed after `❯` (or "? for shortcuts" below), no "esc to interrupt", and at most four rows
  under the box; a dialog has no rule under its options. While a turn runs the prompt box stays on screen (typed input
  is queued), so "esc to interrupt" and 5 s without output are what mark a turn. **Verify:** `code_wake_test.dart`,
  group "the idle check", on the rows of a real 2.1.233 screen (`test/support/claude_screens.dart`).
- **Rules wider than the terminal break the check.** The check matches a row made only of `─`; a rule drawn for a
  wider terminal wraps into two rows and no longer matches. Claude Code redraws at the new width on resize; test
  stand-ins must draw rules that fit the dock (the fixtures use 40 columns).
- **Wake after the cooldown takes up to 35 s.** The 30 s rate limit ends, then the 5 s quiet check runs, so a second
  wake comes 35 s after the first at the earliest. Expected, not a lost wake.

## 2026-10-05 · Visual polish to reference v3 (`apps/antenna_desktop`: `lib/theme/{tokens,buttons,x_theme}.dart`, `lib/ui/widgets/{popover,agent_avatar}.dart`, `lib/ui/chat/secure_indicator.dart`; D-UI-24)

- **A `const` set of doubles does not compile.** `static const sizes = {28.0, 20.0, …}` fails with "The element '28.0'
  does not have a primitive equality": a constant set needs elements with primitive `==`, and `double` does not
  qualify. **Fix:** a `const` list (`XType.sizes`); `contains` works the same.
- **Re-exporting the button styles from the theme trips `unnecessary_import`.** With `x_theme.dart` exporting
  `buttons.dart`, every screen that imports `ui/widgets/x_buttons.dart` gets the info, and removing those imports would
  break branches that add new ones. **Fix:** the styles live in `lib/theme/buttons.dart` (so `buildXTheme` can map
  Filled, Outlined, Text and Icon buttons to them), `x_theme.dart` imports it without exporting, and
  `ui/widgets/x_buttons.dart` stays the one import for screens (it re-exports the file).
- **Spacing literals cannot be fixed by hand reliably** (about 600 spacers, insets and Wrap gaps). **Fix:** a one-off
  rewrite to the 4 px half step of the 8 px grid (nearest step; a tie such as 6, 10 or 14 goes to the multiple of 8; up
  to 2 px stays as an optical nudge) and `test/widget/design_tokens_test.dart`, which scans `lib/ui` for off-grid
  spacing and font sizes off the type scale, with a negative control of its own. **Verify:** add `SizedBox(width: 7)`
  anywhere in `lib/ui` and the guard names the file and line.
- **The verification code and a QR code are not layout.** The rewrite first shrank the rekey code to 28 px and the QR
  paper margin to 8 px (the quiet zone a camera needs). **Fix:** `XText.sasCompact` keeps 34 px outside the scale; the QR
  margin is 12 px.
- **`FocusableActionDetector` reports hover only in keyboard highlight mode.** Its `onShowHoverHighlight` stays silent
  until a mouse event switched the focus manager to "traditional", so a popover hooked to it missed the first hover in
  tests. **Fix:** the popover takes hover from its own `MouseRegion` and uses the detector for focus, Enter/Space and
  Escape only. **Verify:** the hover steps of `secure_indicator_test.dart` and `settings_help_test.dart` (a mouse
  gesture with `addPointer`, then a wait past the 300 ms delay).
- **An overlay child gets the whole overlay's size.** `OverlayPortal` lays its child out like `Positioned.fill`, so the
  card under a `CompositedTransformFollower` is placed with an `Align` inside an overlay-sized box; opening above the
  anchor flips the target and follower anchors and the alignment together. **Verify:** `settings_help_test.dart`, "near
  the bottom right corner the card opens above the "?" and stays in the window".
- **The labelled navigation takes room from the Code mode dock.** At 1,440 px the dock can grow only to about 420 px
  next to a 216 px navigation, 300 px of chats and 500 px of conversation, so the dock's resize test (a 100 px drag)
  needs a 1,700 px window; below 1,400 px Code mode folds the navigation to icons. **Verify:** `code_mode_test.dart`,
  "the labelled navigation in both modes; icons only when Code mode leaves it no room".
- **The macOS title bar followed the system, not the app.** AppKit draws the title bar from the system appearance, so a
  light window under a dark system had a dark band over it (seen on a real Mac). **Fix:** `WindowChrome` sends
  the app's theme and the navigation's color over `antenna/window`; `MainFlutterWindow.swift` sets the window's
  appearance and background. **Verify:** `test/host/window_chrome_test.dart` for the window side; the Runner change
  needs a build and a look on a Mac (light app under a dark system, and the other way round).

## 2026-10-05 · Claude Code 2.1.289: hooks, the idle prompt, images, the first run (`apps/antenna_desktop/lib/{host/code_hooks,host/screenshot,state/claude_state,state/code_wake,state/code_shot}.dart`; D-UI-25, D-UI-27)

- **Claude Code updates itself.** On the build server the installed `claude` went from 2.1.233 to 2.1.289 between two
  runs on the same day (its native installer updates in the background). Anything recorded from its screen is a fact
  about one version; write the version next to it (`test/support/claude_screens.dart` does).
- **No "? for shortcuts" in auto mode.** 2.1.289 with auto mode on shows `⏵⏵ auto mode on (shift+tab to cycle) · ←
  for agents` under the prompt box instead of "⏸ manual mode on · ? for shortcuts", and the empty prompt shows a
  placeholder (`❯ Try "fix lint errors"`). A check that took "anything after `❯`" as a draft unless "? for shortcuts"
  was shown never saw the prompt idle. **Fix:** the hooks decide (D-UI-25); the screen fallback reads two things a
  draft cannot fake: the terminal cursor stands right after `❯ ` (Claude Code moves it to the end of what was typed) and
  the rest of the row is drawn faint (SGR 2: the placeholder; typed text is normal). **Verify:**
  `code_wake_test.dart`, group "the screen fallback" (2.1.289 manual and auto mode, a draft `Try "fix lint errors"`, the
  cursor moved to its start, faint text with the cursor elsewhere).
- **What the hooks report** (2.1.289, session settings through `--settings`): SessionStart at start (with the "trust
  this folder" question answered); UserPromptSubmit then Stop for a turn; PreToolUse then PermissionRequest when a tool
  needs permission (the Notification `permission_prompt` had not come 4 s later: do not rely on it); **an Esc that
  interrupts a turn or closes a dialog fires no hook at all**, so the window treats the owner's keys as "state
  unknown"; SessionEnd at exit. Hooks from `--settings` are added to the user's and the project's own (a project hook
  ran next to them). Each hook gets JSON on its standard input, compact (`"stop_hook_active":false`).
- **A Stop hook that continues shows as an error.** A Stop hook that prints `{"decision":"block","reason":"…"}` makes
  Claude Code go on with the reason, and its transcript shows "Stop hook error: <reason>" and "Stop hook error occurred
  · ctrl+o to see". It is not an error: that is how 2.1.289 labels a blocking Stop hook. The next stop carries
  `"stop_hook_active":true`; the hook must not continue again then (loops).
- **Images reach Claude Code as a pasted path.** A bracketed paste (`ESC[200~/abs/path.png ESC[201~`) of an image's
  path becomes "[Image #1]" in the prompt and the model sees the image. Typed key by key, the path stays text, a leading
  `/` opens the command menu, and the model may open the file with its Read tool, which asks for permission outside the
  working folders ("Do you want to proceed?"). Even after a paste the model sometimes reads the file as well, so Code
  mode passes `--add-dir` on the agent's screenshot folder. **Verify:** `code_shot_test.dart`; with the real CLI, paste
  a PNG's path and ask its color.
- **The folder trust dialog now preselects "No, exit".** 2.1.233 preselected "Yes"; 2.1.289 lists "❯ No, exit" first and
  "Yes, I trust this folder" second, so Enter alone exits. An arrow key sent at once after the dialog appears may be
  lost: wait a moment, press Down, check that "❯ Yes" is selected, then Enter (`live_code_mode_test.dart`).
- **A new HOME asks for sign-in before any MCP server starts.** With an empty HOME, 2.1.289 shows the text-style choice
  and then "Select login method"; no MCP server starts until someone signs in. A test that needs `antenna mcp` bound
  must use a signed-in HOME, or skip with that reason.
- **The screenshot tool and Screen Recording (macOS).** `screencapture -i` started by the app captures other apps'
  windows only after macOS allowed Screen Recording for Antenna (it asks on first use); without it the picture shows the
  desktop. To verify on a real Mac.

## 2026-10-05 · The doctor's facts (`crates/antenna-core/src/{transport,app_hosts,agents,node}.rs`, `crates/antenna-cli/src/owner/doctor.rs`; D-101)

- **The home relay is empty until chosen, then kept.** iroh 1.3's `Endpoint::home_relay_status()` is empty until its net
  report has chosen a home relay; after that it keeps the chosen relay while the relay is down (the net report falls
  back to the current one), so the URL stays known. `last_error()` is `None` while connected and before any attempt
  failed. Format the error with `{:#}` for the whole chain; it can quote the relay server, so control characters are
  replaced before it reaches a client.
- **How fast "not connected" shows.** When the relay closes the connection, `connected` turns false at once (3 ms after
  the local test relay stopped, the error 12 ms later). When the network drops silently, iroh notices through its
  relay ping (every 15 s, 5 s timeout): up to about 20 s (from iroh's source, not measured).
- **Every link reports on its own.** Each link has its own endpoint, so `transport.relay` is per link: group by the URL
  for one message.
- **A refused process names itself.** `refused_comm` is whatever the refused process calls itself; clients escape it
  before showing it (the window replaces control, format and bidi characters).

## 2026-10-05 · The Check panel (`apps/antenna_desktop/lib/{state/doctor,host/shell_path,host/program_locator}.dart`; D-UI-26)

- **"Not on PATH" is about a new terminal.** Antenna finds a CLI in the usual install folders even when the user's
  terminal does not (Claude Code's native installer puts it in `~/.local/bin`, which a new macOS account's zsh does not
  have on PATH). The check compares the program's folder with the login shell's PATH (`$SHELL -ilc`), read once per
  window session and again after the fix; when that PATH cannot be read the row says "not checked".
- **Appending keeps a dotfiles link.** Rewriting a profile through a temporary file and a rename would replace a
  `~/.zprofile` that links into a dotfiles folder with a plain file; the fix appends (after a backup copy next to the
  profile), which writes through the link like `>>` does.

## 2026-10-05 · Claude Code changed: how to read a canary failure (`tools/claude-canary.sh`, `apps/antenna_desktop/test/protocol/live_code_real_claude_test.dart`)

Claude Code updates itself (2.1.233 → 2.1.289 within one day on the build server, then 2.1.290 between two canary
runs an hour later), and the Code mode wake depends on
its hooks and, as the fallback, on its screen (D-UI-25). `tools/claude-canary.sh` runs the wake against the real,
signed-in Claude Code found on this computer: it builds `antennad` and `antenna` (debug), runs the test above with
`ANTENNA_REAL_CLAUDE=1` (without that variable the test is skipped, so ordinary live runs and the release script never
start it) and prints one line, `claude-canary <UTC> claude <version> PASS|FAIL <short reason>`, exit code 0 or 1. On
FAIL the test's output comes first on standard error: the hook events in the order they arrived and the screen rows as
the wake reads them (row numbers, invisible characters spelled out as `<U+XXXX>`, faint columns, the cursor). It costs a
few Haiku turns: the throwaway project's settings choose Haiku, allow Antenna's MCP tools and deny the tools that could
stop a turn at a permission dialog.

What the stage in the reason means (the test names the stage it was in):
- **`prerequisites`, `two daemons and a link`, `Start agent`:** our side or this computer (no `claude`, no C compiler
  for the terminal library, a daemon that did not start). `Start agent` with Claude Code exiting at once and its usage
  text on screen means it rejected a flag the window passes (`--mcp-config`, `--strict-mcp-config`, `--settings`,
  `--add-dir`): check `claude --help` and `agentCommand` in `lib/state/agent_launch.dart`.
- **`the folder trust question`:** the trust dialog changed its wording or its default, or Claude Code is not signed in
  for this HOME ("first-run screens"). Only the test answers this dialog (a person does in the window), so the wake
  itself may still work; fix the test's answer and run again.
- **`SessionStart`:** no hook event arrived: session hooks from `--settings` no longer run, or an event was renamed.
  The window then falls back to the screen check after 20 s for every agent, and says so in the dock when that fails
  too. Compare Claude Code's hooks documentation with `claudeStateHooks` in `lib/host/code_hooks.dart`.
- **`turn 1 (quick reply "Yes, go ahead.")`:** "no hook event prompt" with the line still in the prompt box means Enter
  did not send it (the paste detection of "Code mode wake", CW.1, changed); "out of order" means UserPromptSubmit or
  Stop changed meaning.
- **`idle after Stop (hooks)`:** the state machine (`lib/state/claude_state.dart`) did not reach idle from the events
  shown.
- **`idle after Stop (screen fallback)`:** `claudeCodeReady` does not recognise the empty prompt on this version's
  screen. Compare the printed rows with `test/support/claude_screens.dart`, add the new screen there as a fixture with
  its version, change the check in `lib/state/code_wake.dart` until it passes, and keep every draft, dialog and busy
  fixture failing (`code_wake_test.dart`, group "the screen fallback").
- **`turn 2 …`, `a message for the agent during turn 2`, `the continued turn`:** the Stop hook continuation. "Line left
  for the hook: never" means the window did not offer the line while the turn ran (our side, or a turn shorter than the
  message's way through two daemons); a time there means Claude Code ignored `{"decision":"block","reason":…}` or
  changed `stop_hook_active`.
- **`nothing typed after the continuation`:** the window typed a line it should have left to the Stop hook, or the hook
  continued more than once.
- **"a permission dialog opened":** the model used a tool that the project settings in the test do not deny, or the
  format of `permissions` changed; widen the deny list or fix the rule.

Side effects: the test removes the throwaway folder and its transcripts (`~/.claude/projects/<folder>`); the folder's
entry under `projects` in `~/.claude.json` stays (one per run), because every running Claude Code rewrites that file and
an edit from outside could undo the write of another Claude Code running at the same time.

- **First finding (2.1.289, the first run; 2.1.290 the same):** the screen fallback did not recognise the empty prompt after a turn. The
  rows showed `❯<U+00A0>`: 2.1.289 draws its empty prompt with a no-break space after `❯` (seen with
  `"tui": "fullscreen"` in the account's settings; the fixtures recorded earlier had lost it to `trimRight`, which
  treats U+00A0 as whitespace). The hooks were unaffected, so the wake worked whenever they knew the state; after the
  owner's keys made it unknown, nothing would have been typed. **Fix:** `_emptyInput` accepts a no-break space in the one
  column right after `❯`; one typed into the prompt is still a draft. **Verify:** `code_wake_test.dart`, "the empty
  prompt drawn as "❯" and a no-break space is idle; a no-break space typed after it is not" (fixture
  `claude289AfterTurnNbsp`), seen failing without the fix and with a rule that accepts the character anywhere.
- **2.1.306: a new dialog, "Read outside the working directories" (2026-10-22).**
  - Symptom: the canary failed at turn 1 with "a permission dialog opened"; the hook events ended with `tool
    permission`, and the screen showed "Allow this read outside the working directories?" with four numbered answers
    (`❯ 1. Yes, and keep allowing any reads outside the working directories`).
  - Cause: 2.1.306 adds the setting `permissions.blockReadsOutsideWorkingDirectories`. While it is unset, a file tool
    (Read, Glob, Grep) that reads outside the session's working directories asks this question; the first answer
    writes the setting into the user's settings for good. The model globbed the throwaway folder's parent
    (`/tmp/xdesk-…`, where the test daemons live), which is outside the project folder.
  - Fix: the canary's project settings (`live_code_real_claude_test.dart` and `real_claude_code_in_a_session_is_woken`
    in `crates/antenna-cli/tests/session.rs`) add the test's folder to `permissions.additionalDirectories` and set
    `blockReadsOutsideWorkingDirectories: true`, so a read further out is refused (an error to the model, the turn goes
    on) instead of asking. The window needed no change: the dialog fires PermissionRequest (state "dialog", nothing
    typed) and draws a numbered choice with the cursor hidden (`screenGuard` and the screen fallback say "not ready").
    Real users will meet this dialog; it is theirs to answer, and the window never types into it.
  - Verify: the fixture `claude306ReadOutside` (`test/support/claude_screens.dart`) in `code_wake_test.dart` ("2.1.306:
    the dialog …") and the recorded hook sequence in `claude_state_test.dart` ("2.1.306 "Read outside the working
    directories" …"); the same screen in `session/screen.rs` (`claude_drafts_turns_and_dialogs_are_not_ready`). Seen
    failing with the dialog state and the screen guard disabled. Then `tools/claude-canary.sh` against 2.1.306: PASS.

## 2026-10-06 · macOS asks Antenna for Documents, Photos, Music… (`apps/antenna_desktop/lib/{state/code_mode,ui/code/start_agent_dialog}.dart`)

- **Symptom.** On a real Mac, every ad-hoc-signed update of the app asked again for access to Documents, Downloads,
  Desktop, Photos and Music, right after the first Code mode agent of that update ran.
- **Cause.** "Start agent" defaulted an agent's working folder to the owner's home folder (`~`) whenever nothing more
  specific was chosen. A Code mode agent (Claude Code, Codex) scans its working folder on start, so scanning `~`
  touches Photos, Music and the rest; macOS attributes that access to the parent app (Antenna), not to the CLI inside
  it. Each ad-hoc-signed build is a new app identity to macOS (no stable signing identity across updates outside a
  notarized release), so the question comes back on the next update even though the owner already answered it once.
- **Fix.** A Code mode agent never starts in the home folder by default any more: `AgentHost.ownFolder(name)` is
  `~/Antenna/agents/<agent name>/`, created 0700 on first use (`AgentHost.prepareOwnFolder`, only when the agent
  actually starts, not merely while the dialog shows it as a hint). "Start agent" leaves the folder field blank until
  the owner picks one; a folder remembered from before this fix as exactly the home folder reads the same way ("not
  chosen"), migrating to the agent's own folder instead of repeating the old default forever. Picking the home folder
  on purpose still works, with a one-line warning next to the field (`codeFolderHomeWarning`) that says what macOS
  will ask for.
- **Verify.** `apps/antenna_desktop/test/widget/code_mode_test.dart`: "a new agent defaults to its own folder, never
  the home folder" (the hint, the created folder, 0700 via the fake's `createdFolders`), "a folder remembered as the
  home folder from before this fix migrates to its own folder", "picking the home folder on purpose warns, once it is
  actually chosen" (and not for a subfolder of home). To see the permission dialogs themselves needs a real Mac and an
  ad-hoc-signed build (not yet run; the fix removes the only known trigger — scanning the whole home folder — rather
  than claiming the dialogs were reproduced here).

## 2026-10-06 · A reversed ListView's `maxScrollExtent` is an estimate once content exceeds the cache window (`apps/antenna_desktop/lib/ui/chat/chat_view.dart`)

- **Symptom.** Compensating a reversed, bottom-anchored `ListView`'s scroll offset by `maxScrollExtent`'s growth
  (the standard trick for "keep the reader's position when new content is inserted at the anchored end") left a
  residual drift of a few percent of the scrolled distance — small at first, worse further from the bottom. A widget
  test caught it exactly (`chat_scroll_test.dart`, scrolled away from the bottom, `tester.getTopLeft` of a known
  message before/after a new one arrived): `jumpTo(pixels + grew)` moved the position, just not by quite enough.
- **Cause.** `RenderSliverList` only lays out children within its cache area (viewport height plus ~250 px by
  default on both sides). A reader scrolled away from the bottom is, by construction, usually past that window for
  the newest rows, so `maxScrollExtent` (and the size Flutter would report for any row outside the window) comes
  from `SliverChildManager.estimateMaxScrollOffset`, interpolated from the rows it *has* measured — not their real
  height. Correct on average, wrong by a few pixels for any one delta, which is exactly what a scroll-position
  compensation needs to be exact about.
- **Fix.** Two changes, together: (1) `scrollCacheExtent: ScrollCacheExtent.pixels(50000)` on the `ListView` — large
  enough to keep a full page's worth of history (`AppModel.pageSize` 50) laid out exactly regardless of scroll
  position, so `maxScrollExtent` stops being an estimate; (2) stop reading `maxScrollExtent` for the compensation
  amount at all, and instead measure the bottom-most row's own `RenderBox.size.height` directly through a
  `GlobalKey` wrapping whichever row is currently newest (`_MessagesState._bottomBox`) — exact by construction, and
  it also distinguishes "a new row was inserted" (compensate by its own full height) from "the same row grew in
  place, a stream or an image's preview" (compensate by the height difference only), which a single extent number
  cannot. Needs a stable identity per row (`KeyedSubtree(key: ValueKey('chat-row-<id>'))`) so Flutter's own element
  diffing does not shuffle which row holds which `RenderBox` across a rebuild.
- **Verify.** `chat_scroll_test.dart`: at the bottom a new message follows without a jump button; scrolled away, a
  short message, a long one and a growing stream bubble each leave a tracked message's `getTopLeft` unchanged to the
  pixel; the jump button carries the right count and clears on tap or on reaching the bottom by hand. Seen failing
  without `scrollCacheExtent` (the residual drift above) and without the `GlobalKey` measurement (reading
  `maxScrollExtent`'s delta instead reproduced the same drift even with the larger cache).

## 2026-10-06 · Owner keys and unlock slots (`crates/antenna-core/src/{owner_keys,keystore/slots,node/owner_proof,control/auth}.rs`; D-102, CONTROL §22)

- **A new keystore format would lock out a rollback.** Every released daemon parses `keystore.cbor` strictly
  (`deny_unknown_fields`, `v == 0`), so a v1 file with a second slot would be "unsupported keystore format" to the
  version `antenna update --rollback` brings back, and the owner could not unlock at all. **Fix:** the unlock slots live
  in their own file, `keyslots.cbor`; `keystore.cbor` is never rewritten (a test compares its bytes before and after
  enrolling). **Verify:** `keystore::slots::tests`, `tests/owner_keys.rs::an_unlock_slot_opens_the_keys_and_nothing_else`.
- **Hash what you parse, not a re-encoding.** The window (Dart), the Secure Enclave helper (Swift) and the daemon would
  each need the same canonical encoder of every request to agree on a hash, and a disagreement makes a valid touch
  fail (or, worse, two encoders read one request differently). **Fix:** the proof covers SHA-256 of the exact bytes of
  the `req` value on the line (`serde_json`'s `RawValue`, feature `raw_value` in `antenna-proto`); the client sends the
  string it signed, and the daemon parses those same bytes. **Verify:** `owner_keys::tests::a_proof_line_keeps_the_request_bytes`.
- **`aws-lc-rs` with default features pulls a new crate.** Its defaults add `ring-io`/`ring-sig-verify` (the `untrusted`
  crate); rustls builds it with `aws-lc-sys` only. **Fix:** the workspace dependency is `default-features = false,
  features = ["aws-lc-sys"]`, the same version (`=1.18.1`), so `Cargo.lock` gains only the edges. **Verify:** `git diff
  Cargo.lock` after a build shows only `"aws-lc-rs"` under `antenna-core` and `antenna-cli`.
- **`ParsedPublicKey::new` accepts more than a raw point.** For ECDSA it tries a SubjectPublicKeyInfo DER first, then
  a SEC1 point (compressed or not). **Fix:** `owner_keys::parse_public` takes exactly 65 bytes starting with `0x04` before
  calling it. **Verify:** `owner_keys::tests::public_keys_are_checked` (compressed, short, off-curve refused).
- **CryptoKit has two signature forms.** `rawRepresentation` is 64 bytes `r ‖ s` (what `ECDSA_P256_SHA256_FIXED`
  verifies); `derRepresentation` is ASN.1 and is refused (`proof_invalid`). A Mac client that sends DER fails every
  proof. **Verify:** `a_signature_verifies_only_for_its_key_nonce_and_request` (the DER form refused) and the vector
  from Python `cryptography` in `a_vector_from_another_implementation_verifies`.
- **Proof failures share the password limiter.** Three failures in a row pause passwords and proofs for 1 s (then 2,
  4 … 60 s) and make `owner_challenge` answer `password_required`. A test that walks through several refusals must use
  the password between them (`antenna login`) or wait out the pause, or later steps fail with `rate_limited` or
  `password_required` instead of the code they test.
- **The challenge is bound to the process.** A nonce asked for by one process (PID and start time, read from the socket
  at connect) is refused from another, and one asked for with a `hello.session` token is refused without it. A test
  that gets the challenge from a child process and sends the request from the test itself fails with
  `challenge_invalid`; the window's connections all come from its one process.
- **A slot can outlive its key.** If `keyslots.cbor` is restored from a copy (or a crash falls between the database and
  the slot file), a slot for a removed key still opens the root key. The database is the source: after the slot opens,
  `open_session` checks the key is still enrolled with `unlock` before anything starts, refuses with
  `owner_key_unknown` and deletes the slot. **Verify:** the "slot left behind" step of
  `an_unlock_slot_opens_the_keys_and_nothing_else`, seen failing with the check skipped.

### The window's side (`apps/antenna_desktop/lib/{host/touch_id,state/touch_id}.dart`, `macos/Runner/TouchID.swift`; D-UI-28)

- **A 64-bit hash printed with a minus sign.** A Dart `int` is signed 64-bit, and `toUnsigned(64)` changes nothing on
  the VM, so the FNV-1a folder name came out as "-340d631b…". **Fix:** print the two 32-bit halves
  (`touchIdFolderName`).
- **Sign-in signed out after a slow touch.** The owner session dialog waits 15 s for its `session` event; with the
  touch inside it, a slow finger timed the dialog out. **Fix:** touch and sign first, then open the `login {hold}`
  dialog with the finished proof. **Verify:** the "slow touch" widget test.
- **`login_required` in a live test after `lock`.** A lock closes every owner session, the test client's own too:
  after unlocking, the test signs in again (as the window does).
- **`find.text(title)` finds no dialog title with a tag.** `XDialogShell` draws a title with the Experimental tag as
  `Text.rich` with a `WidgetSpan`; find it by widget type.

## 2026-10-06 · Updates that install by themselves (`crates/antenna-core/src/autoupdate/`, `crates/antennad/src/handover.rs`, `crates/antenna-update/src/install/handover.rs`; D-103)

- **A re-sent identical file could not be accepted at all** (a real Mac, preview.5 window): the server sent the
  preview.7 release files again, the same BLAKE3, and they were already in the link's `shared/`. The accept answered
  `file_name_taken`, the window's "Another name" dialog came prefilled with the same name and its Accept did nothing,
  and at level 5 the daemon left the copies in quarantine (`accept_own` gave up on the taken name). **Fix:** the
  quarantine compares the existing file (same name ignoring case and Unicode form, regular file, not followed if a
  symlink) by size and BLAKE3 and accepts the copy as that file (`duplicate: true`, nothing written);
  `file_name_check` tells a client `free` / `taken` with a free name / `same_file` / `invalid` before it accepts.
  **Verify:** `tests/duplicates.rs` (both tests seen failing with the comparison switched off: the second accept was
  `file_name_taken`, and at level 5 the second copy stayed `checked`).
- **The installer must outlive a new daemon that fails.** The daemon starts the installer as its child; if the new
  binary exits, its service manager cleans up what it started: systemd kills every process of the unit's cgroup when
  the main process ends (`KillMode=control-group`), and launchd kills the job's process group (`AbandonProcessGroup`
  false). The installer that should put the old version back would die with it. **Fix:** the installer runs in its
  own process group (`process_group(0)`) and, when the daemon is the `install.sh` unit (`/proc/self/cgroup` ends in
  `/antennad.service`), in its own scope (`systemd-run --user --scope --collect --`, which executes the command in
  place, so it stays the daemon's child); without `systemd-run` the install is refused. **Verify:** the fake-OS tests
  in `install/handover_tests.rs`; on a real systemd user session and under launchd: not yet.
- **After the swap, `/proc/self/exe` names `antennad.previous`.** A swap renames directory entries; the running
  process's executable link follows its inode. The daemon must `exec` the path it was started from, so it records its
  canonical executable, arguments and working folder first thing in `main` (`handover::Me::now`); a hand-started
  daemon with relative arguments (`--data-dir data`) keeps working.
- **Owner sessions do not cross the handover.** They live in the old process's memory; after the `exec` every client
  signs in again (`login_required`), as after any restart. The window does it through its gate; scripts call
  `antenna login` again. The keys are unlocked, only the owner session is new.
- **A new daemon that came up locked is kept.** If the key did not arrive (an older version that does not read
  `--handover-fd`, or a wrong key), the new version still answers: the installer keeps it, and it waits for the
  password as after any restart (`status.updated.unlocked: false`). Rolling back would also come up locked and lose
  the update. **Verify:** `auto_update.rs::without_the_handover_pipe_the_new_version_comes_up_locked`
  (`ANTENNA_HANDOVER_TEST_DROP_KEY=1`, debug builds only).
- **Tests: the old daemon that a failed install starts again is not the test's child.** It runs detached, in its own
  process group, from the installer; the harness's `Node` does not know it. `auto_update.rs` ends it by its PID (found
  by `--data-dir` in `/proc/*/cmdline`) in `World`'s `Drop`, also when the test fails; never by a pattern. The
  temporary folder is the last field of `World`, so a failing test still shows the daemon logs.

## 2026-10-06 · The window side of automatic updates (`apps/antenna_desktop`: `lib/ui/files/rename_dialog.dart`, `lib/state/{code_restore,auto_update,files}.dart`; D-UI-29)

- **Accept in "Another name" did nothing** (a received file whose name was taken, preview.5 window on a Mac).
  **Cause:** two at once. The accept flow sent the name the daemon had refused again, up to three times, each time
  opening an identical dialog (it looked as if the dialog stayed), and after the third ended without a word; and the
  dialog's `TextEditingController` was disposed as soon as the dialog returned its answer, while the closing animation
  still drew the field (in a debug build the framework then throws and the dialog stack breaks). **Fix:** the dialog is
  a widget that owns its controller and accepts the file itself; a refused name is never sent again as it is; every
  refusal is shown in the dialog. **Verify:** `test/widget/file_rename_test.dart`, "the Mac finding", seen failing on the
  old flow.
- **A daemon older than v7 answers a v7 command with `bad_request`, not `unknown_command`:** its strict parser does not
  know the variant. The window never sends a v7 command to a daemon whose `hello_ok.proto` is below 7; a v7 daemon that
  has not built a command yet answers `not_implemented`, which the window treats as "not available".
- **Test data that repeats a few words is held by the secret scanner as a seed phrase** (`secret:seed_phrase`,
  `approval_required` on `share_file`). Live tests that send text files use numbered lines with varying numbers.
- **A golden frame scrolled before late content arrived stays at the top:** the CLI's facts in Settings → Updates
  arrive after the card's first frame, so the list's `maxScrollExtent` is still 0 when a test scrolls right after
  opening the section. Pump once more, then scroll the `Scrollable` that is an ancestor of the target
  (`test/goldens/update_scenarios.dart`, `61_update_auto`).
## 2026-10-06 · Local models (`crates/antenna-core/src/local/`, `crates/antenna-cli/src/local_agent.rs`, `packaging/llama/build.sh`; D-104)

- **`llama-server` exits at once: "couldn't bind HTTP server socket, hostname: …/llm.sock".** The socket path is
  longer than `sun_path` (108 bytes on Linux, 104 on macOS). The daemon puts the run folder in `/tmp/antenna-<uid>/lm-…`
  when `<data>/local/run/<model>/llm.sock` would be too long (`local::socket_dir`, as the proxy does). Check: a data
  directory with a long path still answers (`antenna local say`).
- **A local model answers 5–7 times slower than expected on a shared server.** llama.cpp's threads wait by spinning;
  with as many threads as vCPUs on a busy host they fight the other work (measured: 16 threads at load 11, 4.5
  tokens/s; 8 threads, 30). A machine that reports no SMT (every thread its own core: most VMs) gets half its threads;
  `antennad --local-threads N` sets it. Check: `antenna local say`'s last line, `reply N tokens at X tokens/s`.
- **The runtime is killed after a few minutes of answers.** `RLIMIT_CPU` counts the CPU time of all threads: at 8
  threads an hour of it is gone in 7.5 minutes. The runtime's sandbox has no CPU limit (it is unloaded when idle); its
  memory is capped by `RLIMIT_DATA` instead, which does not count the read-only mapped model.
- **The runtime does not start: "the runtime's sandbox lets it connect to a unix socket".** Stage 2 of the listen-only
  sandbox proves from the inside that `socket(AF_INET)` and a unix `connect` fail with `EPERM`; if seccomp did not
  load (an old kernel, a missing rule), the runtime is refused rather than run with a way out. Check: `antenna local
  models` → `runtime.detail`, the daemon log's `local model …` line.
- **`cargo test -p antenna-cli --test local` runs an old daemon.** As in RA.8: the tests start `target/debug/antennad`,
  which `cargo test -p antenna-cli` does not rebuild. Run `cargo build -p antennad -p antenna-cli` first.
- **A model's memory is about 1.6 times its file on Linux.** The CPU backend repacks Q4_K weights for AVX2 into
  anonymous memory, next to the file's mapping (2B: 2.1 GB in use for a 1.28 GB file; 9B: 8.9 GB for 5.68 GB). The
  catalog's `memory` is the measured figure; `memory_metal` (no repacking) is an estimate until measured on a Mac.
- **`antenna local install --wait` in a script says `login_required`.** The owner session of a script is bound to the
  command's parent process; `echo pw | antenna login --password-stdin` runs `antenna` in a subshell of the pipeline,
  so the next command (another child of the script) has no session. Use `antenna login --password-stdin <<< "$PW"`.
- **The download fails at once with "the proxy refused <host>".** A redirect led to a host outside the hub's list
  (`huggingface.co`, `*.hf.co`): the daemon's proxy refuses it and the download is not tried again (a 4xx is final
  too). If the hub moves its CDN, the list in `local/download.rs` changes with a release.

## 2026-10-06 · Teams of agents (`crates/antenna-core/src/teams/`, `crates/antenna-cli/src/{agent_teams,mcp/teams,owner/teams}.rs`; D-111)

- **A lead does not see the team tools.** `antenna mcp` asks the daemon for the agent's team once, at its start; an
  agent that became a lead after its MCP server started gets `worker_spawn` and the rest only after its host restarts
  (Claude Code: start it again; Code mode: reconnect). Check: `tools/list` has `team_info`.
- **`team create` says the project has no branch checked out.** The project is at a detached HEAD: name the branch the
  team's work goes to with `--target`.
- **A merge fails with "teams need git 2.38 or later".** Merging a result into a branch that moved uses `git
  merge-tree --write-tree` (git 2.38); fast-forwards work with older git. Apple's git has it from Xcode 14.3. Check:
  `git --version`.
- **`team apply` refuses: "the project's working folder … could not move to the result".** The target branch is
  checked out in the project folder and the merge would overwrite changes not committed there; the daemon moves the
  branch as `git merge --ff-only` would, so it changes nothing then. Commit or stash them and apply again.
- **A submit is refused: "the folder holds another git repository".** There is a `.git` (a folder or a file) in the
  worker's checkout: a worker ran `git init`, or copied a repository in. The daemon records files, never submodules or
  another repository's files. Check: the path in the message, inside `<data>/teams/<team>/w/<id>/tree`.
- **A check fails with "command not found" or a missing toolchain.** The check sandbox sees the system folders, the
  checked folder and nothing else of the owner's: name the toolchain's folders with `--check-path` (read-only), its
  variables with `--check-env` (`RUSTUP_HOME=/home/me/.rustup`), and the registries it downloads from with
  `--check-host`. Every run starts with an empty HOME, so dependencies are fetched again.
- **A check's output names `/…/teams/<team>/c/<task>/tree/…`.** bwrap binds the checked folder at its own path; the
  path is shown, nothing else of the data folder is visible to the check.
- **A task is `blocked` with "the worker ended two turns without reporting".** The worker's CLI ended its turn without
  `task_report`; the daemon reminded it once. Answer with `task_review … changes` (the worker gets a turn with the
  comments) or assign the task to another worker.
- **`antenna agent token` refuses a worker.** A worker's token exists only inside its sandbox, new at every start;
  nobody, the owner included, gets one. Stop a worker with `antenna team stop <team> --worker <name>`.
- **A fake worker's `antenna task report` exits 77, not 1.** In the agent CLI `forbidden` and `denied` exit 77,
  `unknown_command` 2, `not_found` and `task_state` 1 (D-23); a script that drives the CLI should read the JSON
  `error`, not the exit code alone.
- **A task stays assigned after the daemon restarted while the worker was starting.** The worker's turn is sent again
  at unlock only for tasks that are `assigned`, `working` or `returned`; a worker killed before its first instruction
  of the turn starts the turn over (the fake worker in `tests/teams.rs` waits for its own mark before the test stops
  the daemon, which is why the restart test looks for it).
- **`antenna events` (without `--json`) crashed with "has overflowed its stack" on a `team` event.** Fixed in
  preview.8. The two human formatters of `output.rs` passed every kind they did not know to each other: the subscription
  formatter's wildcard went to the pairing formatter, whose wildcard went back, so the v7 kinds a subscription carries
  (`team`, `local_model`, `local_agent`, `update_auto`) recursed until the stack overflowed. The subscription
  formatter now has an arm for every kind and names the pairing kinds instead of a wildcard, so a new kind does not
  compile until it has a line. Check: `cargo test -p antenna-cli --bin antenna every_event_kind_prints`.
- **`antenna team watch` shows nothing for a turn that was already running.** It does: a watch opened mid-turn starts
  with a `snapshot` (`[<worker> is in turn N …; so far:]` and the text so far, its last 16 KiB). A turn that ended
  before the watch opened is not replayed; read the worker's `detail` in `antenna team show`, or the task's report.
- **A watch says "missed N pieces".** The terminal (or the window) fell more than 1,024 pieces behind; open the watch
  again for a fresh snapshot.

## 2026-10-06 · Linux packages (`packaging/linux/{build-deb,build-rpm,check-deb,check-rpm,pkg-common}.sh`; D-109, D-112)

- **`.deb`/`.rpm` look exactly like the `install.sh` layout to `antenna update`.** Both put `antennad` next to
  `antenna`, which is the only thing `antenna_update::install::target::Target::detect` used to check. A package now
  ships one extra file, `bin/.antenna-package` ([`PACKAGE_MARKER`]), and `detect` refuses with `unsupported_install`
  when it is there — seen failing first (the refusal said "the Linux window bundle" instead, from an unrelated
  earlier check) when testing with binaries built before this file was added. Check: build a package from a fresh
  `cargo build -p antennad -p antenna-cli` (not an old cached archive — see the next entry) and run `antenna update
  --json` from its `bin/`; `"kind":"unsupported"` and the reason names the package manager.
- **Repackaging an old cached release archive proves the packaging scripts, not a fix to the binaries inside it.**
  `~/.cache/antenna-release/v0.1.0-preview.7/` predates the `.antenna-package` marker and the local-model runtime
  (D-104): `build-deb.sh`/`build-rpm.sh` ran on it without complaint (both handle a missing `bin/llama/` the way
  `install.sh` already does), but `antenna update --json` on the result still showed the old refusal text. Rebuilt a
  throwaway `antenna-<version>-linux-<arch>` tree by hand from `target/debug/{antenna,antennad}` (same version
  string, mismatched commit, which the packaging scripts never check — only `build-tarball.sh`/`build-desktop.sh` do)
  to see the fix for real.
- **`tar -tzf … | grep -qx …` under `set -o pipefail` can report `tar`'s SIGPIPE, not `grep`'s match.** `grep -q`
  exits as soon as it finds a line; if `tar` is still mid-write when `grep` closes the pipe, `tar` gets SIGPIPE and
  exits 141, which `pipefail` reports instead of grep's success — `check-rpm.sh`'s payload-contents check failed
  this way even though the line was there (confirmed with a plain `tar -tzf … | grep -qx …` by hand). Fix: capture
  the listing into a variable first (`list="$(tar -tzf …)"`), then `grep -qx … <<< "$list"` — no pipe, no race. A
  short, buffered single write (`echo "$var" | grep -q …`, used throughout `check-install.sh`/`check-desktop.sh`)
  does not hit this: the whole string clears the pipe before grep has anything to quit early on.
- **`rpmbuild`, `rpm2cpio` and `desktop-file-validate` are not installed on the build server (checked 2026-10-06).** Per
  CLAUDE.md, agents do not install system packages; `build-rpm.sh` treats this as expected (writes the `.spec` files
  and their source payloads to `OUT/rpm-sources/` instead of a `.rpm`, exit 0) and `check-rpm.sh`/`check-deb.sh` skip
  the checks that need them, named plainly in their output, rather than failing the whole packaging run over a tool
  nobody asked to install. Decide before adding `rpm-build`/`desktop-file-utils` to the build machine if a real
  `.rpm` build or a `desktop-file-validate` pass becomes a release requirement.

## 2026-10-06 · Chats per agent (`crates/antenna-core/src/chats.rs`, `crates/antenna-cli/src/{connect,owner/chats}.rs`, `apps/antenna_desktop/lib/{state/chat_list,ui/home/chat_menu}.dart`; D-113, D-UI-32)

- **A message to an agent shows "delivered", yet nobody there ever answers.** The name is only the sender's guess: the
  contact may have no agent by it (an app connected under another name; ChatGPT's app and Codex share one agent).
  Since 0.2.0 the contact's node says so when it can: "No agent named X at <contact>" under the message, with their
  agents' names. It cannot when the contact's Antenna is older than 0.2.0 or trusts you below level 3 (it does not tell
  a contact it trusts less which names exist). Check: `antenna contacts` lists the agents the contact announced;
  the contact can read the name on **Agents → AI apps** ("Contacts write to it as …").
- **A new agent of a contact has no chat yet.** A chat appears when the agent first writes (its announcement comes
  with its first message) or when it was written to. On the contact's side, `antenna connect … --hello <contact>`
  makes a new session say one line at once. **New chat with an agent** lists only agents that announced themselves or
  wrote: `antenna chats new` refuses any other name (`not_found`), so no chat exists for a name nobody has.
- **`antenna connect … --hello` says the hello waits for approval.** The agent's local level is above the contact's
  trust level, so the daemon holds its first message as for any agent (no write down, SPEC §9): `antenna approve
  <id>`, or connect with a lower `--local-level`. The connection itself is done either way.
- **Archive does nothing on a contact's own row.** The person chat is the contact itself; archive the chats with its
  agents, or remove the contact. A chat with an agent comes back from **Archived** by itself when something new is
  written in it.
- **Local names, notifications and archive are greyed out ("Needs a newer Antenna daemon on this computer").** The
  window talks to a daemon older than 0.2.0 (it groups the chats from the loaded history itself); update this
  computer's Antenna. Renaming the contact works with any daemon.
- **`antenna events` of 0.1.0-preview.8 crashed (stack overflow) on an automatic update event, and stops on a `chat`
  event.** Its human printer handed an event kind it did not format back to the general printer, which handed it back;
  `update_auto` looped until the stack overflowed. Since 0.2.0 any such event is printed as its JSON line. A
  preview.8 CLI does not know the `chat` event at all and ends there; use the CLI of the daemon's version.
- **Flutter: "A TextEditingController was used after being disposed" when a rename dialog closes.** The caller disposed
  the controller right after `showDialog` returned, while the dialog's exit animation still painted the field. The
  dialog widget now creates and disposes its own controller (`_ChatRenameDialog`, the contact rename too). Check: the
  rename test in `chats_test.dart`.
- **Golden frames: a popup menu draws a thick black outline.** With `debugDisableShadows` (set by the golden tests) a
  `PopupMenu`'s elevation is painted as a solid black border. The chat menu has elevation 0 and its own bordered
  shape, which also matches the window's flat panels; check `68_chat_menu.png`.
- **Tests: the agent role refuses a token that works in another test.** A token is bound to the first MCP host that
  used it (D-28); a test that checks "no owner command for agents" after an MCP session uses a third agent, not one
  of the two bound tokens. Trust levels 1–2 are relay only, so a test at level 2 needs the local relay (`LocalRelay`).

## 2026-10-06 · Agent sessions in tmux, the Codex wake, installers in a terminal (`crates/antenna-cli/src/session/`, `apps/antenna_desktop/lib/{host/code_hooks,state/code_wake,state/cli_installer}.dart`; D-116, D-117, D-UI-36)

- **`antenna session …` with an agent token answers "unexpected argument".** The agent CLI has a command of its own
  named `session` (the agent's taint and reads), so clap took `session start` for that command with an extra
  argument. The agent CLI now recognises the owner's subcommands (`start`, `list`, `attach`, `stop`, `wake`, `run`)
  and answers `unknown_command` like for any owner command. Check: `ANTENNA_AGENT_TOKEN=xat_x antenna --json session
  list` exits 2 with `unknown_command`.
- **`tmux -t name` hits the wrong session.** tmux matches a target as a prefix (`antenna-dev` also finds
  `antenna-dev2`) and turns `.` and `:` in names into `_`. Targets are exact (`=antenna-<agent>`), names are mapped the
  same way tmux maps them, and the waker types only into its own pane (`$TMUX_PANE`).
- **Keys sent to a pane in copy mode go to tmux, not to the program.** `send-keys -l` while the person scrolls back
  (copy mode) would drive copy mode. The screen check refuses when `#{pane_in_mode}` is set.
- **A person attached to the session typed a moment ago.** The waker cannot see a person's keys the way the window
  does; tmux's `#{session_activity}` moves on every key from an attached client (seconds), so a line waits until 5 s
  after the last key, and the screen must show the empty prompt in any case (a draft is never typed over).
- **`antenna session start` fails with "longer than this OS allows".** The tmux socket is `<data-dir>/sessions/tmux.sock`
  and must fit `sun_path` (108 bytes on Linux, 104 on macOS). Use a shorter `--data-dir`. A tmux error "File name too
  long" from a hand-made socket path is the same limit.
- **A session's agent was not woken by a message that came before the session started.** Until x-control/7's backlog
  (D-116) the waker got only new facts; now `agent_watch` sends the unread ones first. A message that arrives between
  `start` and the CLI's MCP server binding the token is covered by that backlog when the watch opens. Check: `antenna --json
  session list` shows `"watch": "watching"` once the CLI is connected.
- **Codex shows "Hooks need review" at every start.** Codex asks to trust every new or changed hook definition and
  keeps the trust by a hash of the hook's text in `$CODEX_HOME/config.toml` (`[hooks.state]`). A hook command that
  contains a per-run folder path is a new definition every run. Antenna's Codex hooks name their folder through
  `$ANTENNA_CODE_HOOKS`, so the text is constant: choose "Trust all and continue" once. Until the owner answers, nothing
  is typed (the review hides the cursor and lists `› 1. …`); with "Continue without trusting" the wake falls back to
  `notify` and the screen.
- **Codex's `notify` ran with another thread ID than the conversation's.** Codex 0.160.1 names a new conversation in a
  helper thread whose turn completes during the person's first turn, and runs `notify` for it. Its `turn-complete`
  does not count once a hook has reported, and its ID goes to `session.notify`, which the restore uses only when no
  hook recorded the conversation's own ID in `session`.
- **Codex draws its composer for a moment before a dialog.** At start Codex paints its empty composer for a frame and
  then the hooks review over it. The wake needs 5 s without screen changes, so a frame like that never types; a test
  that waits for the composer must wait for it to stay.
- **The real-Codex window test created `~/.codex`.** The agent's terminal inherits the window process's real
  environment (flutter_pty only adds to it), so `HOME` in the test's `AgentHost` environment does not reach Codex. Run
  the test with `CODEX_HOME` set to a throwaway folder (the test refuses one with a `config.toml` in it); `CODEX_HOME`
  now passes to agent CLIs like the user's other settings.
- **Codex's first screen is a sign-in, not the composer.** A Codex without an account or an API key shows "Sign in
  with ChatGPT" (`> 1. …`, the cursor hidden): a dialog for the screen check. The real-Codex tests use a provider in
  `CODEX_HOME/config.toml` that points at a stand-in endpoint on loopback (`requires_openai_auth = false`).
- **An installer from the Check panel says `npm: command not found`.** It runs in the login shell (`$SHELL -l -c`), so
  the profile's PATH is there; a Node installed only for interactive shells (`.zshrc`, `.bashrc` without a login
  profile) is not. The output shows it in the dialog; install Node for login shells, or use the vendor's other
  installer from the guide.
- **An agent does not see a file the contact sent** (0.2.0). The offer is addressed to another of your agents, or to
  you in person (D-120): `antenna history <contact>` shows `to`/`to_agent` on the `file` line. Your own list (`antenna
  files pending`) shows every offer. To let the agent handle it, accept it yourself into the link folder.
- **A resident agent's conversation is on disk while it sleeps** (0.2.0). Over 64 MB a session is not moved into the
  database (the log says "over the limit to keep it in the encrypted database"); `antenna wake session <contact>
  compact` or `reset` makes it smaller. After the daemon was killed with the agent running, the files stay until the
  next unlock moves them. Check: `antenna wake list` shows `parked` for the sleeping session.
- **Two `antenna request` in a row: the second is refused** ("one at a time, 20 per hour"). The contact's node serves
  one request per link at a time; send the next after the first file arrived.
- **Adding a node feature (`features`, PROTOCOL §21).** The contact's features are bits of `LinkShared::peer_feat`
  (16 bits since 0.2.0: `picture/0` took 64, `stream-agent/0` 128 and `file-addr/0` 256). Parallel branches have taken the same bit
  before: take the next free one from `main` right before merging, and add the name to `FEATURES` and to PROTOCOL's
  list.

## 2026-10-06 · My devices (`crates/antenna-core/src/{devices,node/own_devices}.rs`, `crates/antenna-cli/src/owner/devices.rs`, `apps/antenna_desktop/lib/{state/devices,ui/devices/}`; D-114, D-UI-33)

- **An own computer is listed but shows nothing ("Not heard from yet" or "Antenna there does not tell…").** Both sides
  must have each other at ∞ (each checks its own level), and both need 0.2.0 or later (`device/0`). A freshly paired
  link has no connection until something is sent; the daemon now dials an own device without a connection every 30 s,
  so the first status comes within half a minute once both are online. Check: `antenna devices` on each side;
  `antenna contacts` shows the level of each.
- **"<computer> does not accept approvals from this computer yet".** Approvals from another device count only with keys
  the asking computer's owner confirmed there: on that computer, **My devices** → this computer → **Accept approvals
  signed with …** (the password, once), or `antenna devices confirm <this computer>`. Touch ID turned off and on again
  makes a new key, which needs confirming again; so does lowering the device below ∞ and raising it back.
- **An approval from another device is refused with `challenge_invalid`.** The challenge is good for 60 s and one
  decision; the window asks for a fresh one with every click. Three failed proofs in a row pause that device's
  approvals for a minute (`rate_limited`).
- **A request's text reads "The text is not shown here: it contains a secret".** By design: the secret scanner found
  something in it, so the text never leaves the computer that asked; the reasons say what kind. Read it there, or
  approve knowing the kind.
- **A computer shows "reported this computer as lost".** Another own computer revoked it as lost; its keys no longer
  approve anything here. Revoke it here too, or **It is not lost** to clear the mark (its keys stay removed: accept
  them again if it was a mistake).
- **Tests: a widget test cannot find a card further down My devices.** The page is a `ListView`, which builds only what
  is on screen; `scrollUntilVisible` on the page's own `Scrollable` (an ancestor of `this-computer`) builds it first.
- **Flutter: "ListTile background color or ink splashes may be invisible" in a dialog.** A `CheckboxListTile` inside
  `XDialogShell`'s decorated panel; the revoke dialog uses a plain `Checkbox` with its label instead.
- **Tests: a raw socket line from the test process gets `login_required`.** `antenna login` opens a session for the
  CLI processes the test starts (bound to their parent), not for the test process's own connections; the device test
  holds a session per node with `login {hold}` (`Held`) and sends its token in `hello.session`.
- **Merging parallel work: two features took the same bit.** `no-agent/0` and `device/0` were both `peer_feat` bit 16;
  the second became 32. The control section numbers collided twice (§25 teams, §26 chats): My devices is §27.
## 2026-10-06 · Teams in the window (`apps/antenna_desktop/lib/{state/teams,ui/teams/*}.dart`, `tools/guide_check.py`; D-UI-34)

- **A `RadioListTile` or `SwitchListTile` in a dialog throws "ListTile background color or ink splashes may be
  invisible".** The dialog's panel (`XDialogShell`) is a decorated box with a fill, and a list tile paints on the
  nearest `Material`. Wrap the tiles (or the dialog's content) in `Material(type: MaterialType.transparency)`; New team
  and Add worker do. Check: `test/widget/teams_test.dart` "New team …" fails with the assertion without it.
- **A default picked during `build` overrode the owner's choice of the team's lead.** `RadioGroup` calls `onChanged`
  only for a different value: tapping "I lead it myself" while it was already the default (the agents not read yet)
  changed nothing, and the next build picked the agent again. The default is now set once, after `agent_list`
  answered, and never in `build`. Check: the test "New team, I lead it myself and local only".
- **A test expects the lead's line 5 s after the prompt came back, and it comes later.** The wake's quiet check that
  runs when the output stops sees the change of the redraw and starts again: the line comes within two periods
  (5–10 s) of the prompt's return, by design. Tests wait 11 s after the redraw (`teams_code_test.dart`).
- **`tools/guide_check.py` reports a label that is half a sentence.** A bold label that wraps inside a list item
  ("the **Registries" / "checks may reach**") is read without its continuation line, so the check pairs the wrong
  stars. Keep a bold label on one line in list items (re-wrap the item before the label).
- **After Add worker the new worker was missing from the board (seen in the live test).** A read of the board started
  by an event was still running, and the action's own read only marked it to repeat and returned at once, with the
  board from before the action. An action now waits for the running read and for one more round when that read ended
  before it saw the request. Check: `teams_test.dart` "an action while a slow read of the board runs" (the fake
  answers `team_show` late with the board as it was when asked).
- **An older v7 daemon answers the newer team commands with `bad_request`, not `unknown_command`.** `team_capacity`,
  `team_watch` and the owner's `task_assign` are owner requests it cannot parse ("bad message: unknown variant
  …"). The window treats both answers as "this daemon does not have it" (`state/teams.dart` `_unknown`): the capacity
  strip is derived from the budget, the live box shows the worker's last detail.

## 2026-10-06 · Profile pictures (`crates/antenna-core/src/pictures.rs`, `crates/antenna-files/src/picture.rs`, `tools/avatars.py`; D-115)

- **A contact still shows initials after you chose a picture.** Pictures go only to a contact whose Antenna is 0.2.0
  or newer (`picture/0`); an older one keeps showing initials and gets nothing it could refuse. A contact's agent gets
  its picture only on links where the agent has written (the contact does not learn of an agent from its picture),
  right after its first message there. Check: `antenna picture` on the contact's side lists what arrived.
- **A picture chosen right after pairing did not reach the contact at first.** Its features (`picture/0`) are learned
  on the first connection, and a fresh link may not have one yet. `picture_set` now connects to such a contact first;
  the features exchange queues the picture. Check: `a_drawn_picture_reaches_the_contact_as_its_id_and_follows_changes`.
- **A contact's photo shows initials ("withheld").** `level`: the contact is at trust level 1, which takes no files
  (SPEC §9): raise it to 2 to see the photo. `refused`: the photo did not pass the image check (not the type it claims,
  malformed, something after the image). `unavailable`: this computer's check sandbox is not working (`antenna
  doctor`); it is tried again on the next look. A drawn picture is shown at every level.
- **"This image cannot be used" (`picture_refused`) for a photo that opens fine elsewhere.** The check is strict on
  purpose: a picture is shown to every contact, so only a clean PNG, JPEG, WebP, GIF or BMP whose content matches its
  name is taken (HEIC is not decoded by the check worker: export the photo as JPEG). The window crops and re-encodes
  the photo as PNG before the daemon sees it, so this mostly happens with the CLI.
- **A portrait photo came out lying on its side.** The check worker now applies the EXIF orientation to the preview
  pixels (it did not before 0.2.0, also for received files' safe previews). Check: the orientation part of
  `an_own_photo_loses_its_metadata_and_keeps_its_orientation` (the negative control without it fails).
- **`tools/avatars.py` stops with "no Russian name for: …".** The repository keeps Russian only in `app_ru.arb`, so a new
  animal's Russian name is given once on the command line: `--ru wolf=<name>`; the script writes it into
  `pictureAnimal` there. A set's name the same way (`--ru set4=<name>`).
- **An animal id with a hyphen (`snow-leopard`).** The ARB select messages write it with `_` (`snow_leopard`), as ICU
  select cases are identifiers, and the window looks names up with `-` replaced by `_`.
## 2026-10-06 · The agent map's connections (`crates/antenna-core/src/connections.rs`, `crates/antenna-cli/tests/connections.rs`; D-123)

- **An approved connect left its approval reusable.** `policy::Approvals::finish_completion` records a continuation's
  result (`Done`) only when the approval was used (`State::Used`); every other continuation uses it by calling its
  action again with the approval's ID, through the gate. The connect continuation applied the change directly, so its
  approval stayed `Approved`: the same ask later (after the line was removed there) was "allowed" by the old approval
  and refused as already carried out. `connect_apply` now goes through the gate with the approval's ID first, and a
  repeat of an ask whose approval was carried out is salted into a new request. Check: `connections.rs`
  `own_computers_set_the_other_side_through_an_approval_there` ("the first ask again"); with the gate call removed it
  fails with `refused` / `approval_used`. Any new continuation must use its approval the same way.
- **A `connect` refused by the other computer comes back as `rejected`.** `device_send` maps only the codes its own
  requests return; a refusal's code arrives as the link's `rejected{reason}`, and an unknown one becomes `rejected`.
  The receiving daemon logs "a connection asked by that computer refused: <code>" at info: read the other computer's
  log for the real code.
- **The MCP test helper's `call` returns `(is_error, …)`, not `(ok, …)`.** `common::Mcp::call` gives
  `result.isError` first; an assertion `assert!(ok)` on it passes only for failed calls.
## 2026-10-06 · What a real agent hit in two days (`crates/antenna-core/src/{agents,file_notices,files}.rs`, `crates/antenna-cli/src/{main,mcp,output,setup,connect}.rs`; D-124, D-125, D-126)

- **`antenna inbox` showed "… N more characters not shown" and the message counted as read.** The agent CLI quoted a
  message through the owner screens' quote, cut at 4,000 characters, after the daemon had marked it read; the agent
  had to find the rest in `history --json`. An MCP host does the same to a long tool result at its own limit. Now one
  reply holds at most 32,000 characters (the first message whole), the rest stays unread with `more: true`, and the
  agent CLI prints every message whole. Check: `tests/agent_view.rs`
  `an_agent_gets_every_message_whole_and_the_rest_waits_unread`; with `AGENT_INBOX_CHARS` set to `usize::MAX` it fails
  (three messages in the first reply).
- **A command in a message did not copy: every 72 columns a line break and `│`.** The quote wrapped at a fixed width
  for the owner's terminal. Into a pipe (an agent's tool call, a file) it now keeps each line whole after the frame; in
  a terminal it wraps at the terminal's width; `--json` gives the text exactly. Check: `output::tests`
  `a_quote_into_a_pipe_keeps_lines_whole_and_uncut`.
- **A file from an own computer (level 5) is in `shared/` but the agent does not know.** The daemon accepts it by
  itself (D-99); `files_pending` lists only what waits and the agent's history left unaddressed offers out (the
  message rule of D-91 instead of the offers' rule of D-120). Now each agent that may see the offer gets it in its next
  `inbox` (`files`, with `saved_path` and hashes), a fact in `wait`, `antenna files list` / MCP `list_files` list saved
  files, and the history has the offer. The notices are in memory: after a daemon restart, `files list`. Check:
  `files_saved_for_an_agent_reach_it_with_their_path_and_hashes`.
- **The sender's agent never learnt that its file was accepted.** The contact's `accept_file` receipt reached the
  sending node, which only stopped serving the file. Agents' offers are signed by link-root, so the history does not
  say which agent sent one: the outgoing record now keeps the agent's name (records from before have none, and their
  answer tells nobody).
- **`b3sum: command not found` on a Mac.** Files carry `sha256` next to `blake3` (the CLI prints both whole): `shasum -a
  256 <file>` on macOS, `sha256sum <file>` on Linux. The value is computed on each computer (the receiver's after its
  check: a file still downloading has none); it is not in the history line, which comes from the signed manifest.
- **`antenna --data-dir X agent …` with a token: "no such command: X".** The parse was right (`agent` is an owner
  command and an agent has none); the refusal took the first word that is not an option, and the value of
  `--data-dir` is such a word. It now skips the values of `--data-dir`, `--socket`, `--token-file`, `--agent-token`
  and says "`antenna agent tasks` is the owner's command … ask with `antenna escalate`". Check: `main.rs` unit tests
  `values_of_global_options_are_not_command_words`, `an_owner_command_is_named_as_the_owners`.
- **An agent was told by another agent to run `antenna agent tasks …`, and to change its own settings; its runtime
  refused (rightly).** What needs the owner is set when the owner makes the agent: `antenna agent setup`, `agent add
  --dir …`, `connect … --instructions --git-name … --git-email … --allow …`, and the window's Start an agent (D-124).
  The MCP instructions, tool descriptions, the agent CLI's help and the template are checked against the owner's
  commands by unit tests.
- **`~/Antenna/links/atlas server/` broke shell commands.** New links' folders are the label as one shell word
  (`atlas-server`, D-125); an older folder under the label as it is keeps working, so nothing moves. An agent finds the
  folder in `list_contacts` (`folder`). Check: `a_label_with_spaces_gets_a_folder_a_shell_takes_as_one_word`.
- **`.claude/settings.json` "not strict JSON": the folder setup refused to add rules.** The file has comments or another
  shape of `permissions`/`allow`; Antenna changes another program's config only when it can keep everything else
  exactly (D-85). Add the rules by hand (`"permissions": {"allow": ["mcp__antenna"]}`), or remove the comments and run
  it again; a backup of a file it did change is `settings.json.antenna-backup`.
- **Tests: `Fail` has no `Debug`.** `antenna-cli`'s `Fail` can hold an approval, and is not `Debug`: in unit tests
  unwrap a `CliResult` with `unwrap_or_else(|f| panic!("{}: {}", f.code, f.message))`.
- **Tests: a raw agent command with `--data-dir` before the command.** `Node::cmd()` already passes `--data-dir`, and
  clap refuses the option twice: build the command from `x_bin()` with `clean_env()` instead.
- **Window tests: `await sub.cancel()` on a broadcast stream's subscription hangs `testWidgets` until its 10-minute
  timeout.** Do not await the cancel in the test body (or close the controller instead), as `approval_alerts_test.dart`
  does.
## 2026-10-06 · Approver agents (`crates/antenna-core/src/delegation/`, `crates/antenna-core/src/node/own_devices/delegated.rs`, `crates/antenna-cli/tests/approvers.rs`; D-127)

- **`antenna approver set <agent> --on <computer>` answers `not_found`.** An own computer's agent becomes known here
  with its first message on the link (its key is announced then, PROTOCOL §21); before that this computer has no key
  to check its answers against. Let the agent write once to this computer (`antenna send <this computer> "hello"` as
  the agent there), then name it. `bad_request` "does not know approver agents yet" means the other computer runs an
  older Antenna, or has not connected since this daemon started: wait for the connection (My devices shows it online).
- **The approver's answer is `forbidden` and the request is still pending.** The answer did not count; the request's
  card (`antenna approvals`) says why under "Not counted" (`delegate_refused.why`): `tainted` (the approver read a
  message of a contact at levels 1–4 in this session: only the owner starts a clean session, `antenna agent reset
  <approver>`), `outside` (the asking agent read such a contact, or the request goes to one), `level_changed` (a level
  of a link it touches changed after the request was made, also down and back up: ask again), `scope`, `self`,
  `chain`, `unverified`. Answer it yourself, as before.
- **A request of another computer does not show in the approver's `approval list` yet.** Requests reach an approver on
  another computer with that computer's status, at most 2 s after they are made, and only while both computers are
  connected; `wait` (or the `approval_to_answer` event) says when one arrives.
- **The approvers list shows `stale` for an agent of another computer.** That agent was removed there (its key is
  revoked on the link, D-119); an agent made again under the same name has a new key and is another agent. Name it
  again with `antenna approver set`. The same after the computer was lowered below ∞: its delegations are gone and a
  raise back to ∞ does not restore them.
- **`antenna approver set` without a terminal stops with the warning.** As for level 5, a script passes `--yes` to
  accept it; the password is asked as for every widening (`--password-stdin` in scripts).
- **`#[serde(tag = "cmd")]` on a struct with `deny_unknown_fields` refuses its own tag.** serde reports "unknown field
  `cmd`" when a struct, not an enum, carries an internal tag together with `deny_unknown_fields`. The agent decision
  text has an explicit `cmd` field checked after parsing; the owner proof's `RemoteRequest` is an enum, where the tag
  works. Check: `antenna_proto::device` test `agent_decisions_are_strict_and_have_their_own_context`.
- **A test that counts received messages with `antenna inbox` sees none the second time.** The owner's `inbox` marks
  messages read; count them from `antenna history <contact>` (incoming items), which consumes nothing.
## 2026-10-06 · Approver agents in the window (`apps/antenna_desktop/lib/{state/approvers,ui/agents/approver_dialog,ui/agents/approvers_panel,ui/approvals/approver_notes}.dart`; D-UI-40)

- **`find.text` misses the title of a dialog with an Experimental tag.** `XDialogShell` with `titleTag` renders the
  title as `Text.rich` with a `WidgetSpan`, whose plain text carries U+FFFC, so `find.text(title)` finds nothing. Use
  `find.textContaining` or a key. Check: `approvers_test.dart`.
- **Lists inside a Dart record fail `expect`.** `expect((x.stale, x.kinds), (true, ['a']))` fails although both print
  the same: a record compares its fields with `==`, and two lists are equal only when they are the same object. Expect
  the lists separately. Check: `client_approvers_test.dart`.
- **Re-dumping an ARB file reformats unrelated lines.** `json.dumps(indent=2)` over `app_en.arb` expands the
  hand-written one-line placeholder objects and `@` descriptions, so the diff shows hundreds of changed lines. Append
  new entries as text before the closing brace; `git diff` then shows only additions.
- **A golden scenario's tap fails on a row below the fold.** On the 1440×900 frame the Agents page is a `ListView` that
  builds only the visible rows, so a tap on a lower row finds nothing. `scrollUntilVisible` first, as
  `approver_scenarios.dart` does.

## 2026-10-06 · A taken name in the link folder (`crates/antenna-files/src/{accept,quarantine}.rs`, `crates/antenna-core/src/files.rs`, `apps/antenna_desktop/lib/ui/files/file_card.dart`; D-128)

- **A re-sent file with the same name and new content is never saved; the sender sees "sent".** Symptom: an agent
  sends `DECISIONS.md` again to an own computer (level 5); the recipient's `shared/` keeps the first copy and no
  `DECISIONS (2).md` appears; on the Mac, "Another name" came back with the same name. Cause: the accept refused a
  taken name (`file_name_taken`); the daemon's own accept at level 5 logged it at `info` and left the file in
  quarantine, and the window could only ask for a name. Fix: an accept without the owner's own name saves under the
  next free number; the sender's node gets the number in the receipt (`file-saved-as/0`); a level-5 file that still
  cannot be saved keeps the reason in `held`. Check: `tests/duplicates.rs`
  `at_level_5_new_content_under_a_taken_name_is_saved_under_the_next_number`; with numbering off it times out.
- **A numbered name must be claimed, not chosen.** Picking the first free name from a listing and then renaming is a
  race: two accepts of the same name (two versions downloaded back to back, or the owner's Accept next to the daemon's
  own) both see `(2)` free. The claim is the exclusive step itself (`linkat` of the `O_TMPFILE` file, or
  `renameat2(RENAME_NOREPLACE)`), which fails with `EEXIST`, and the loop moves on to the next number. A plain
  `rename` (or any replacing step) would make the second accept overwrite the first. Check: `accept::tests`
  `a_name_taken_between_the_look_and_the_claim_moves_on_and_replaces_nothing` and
  `concurrent_numbered_commits_get_distinct_names`; with an `unlinkat` before the `linkat` both fail.
- **`files pending --all` says `duplicate` only in the accept's own answer.** `duplicate` is a property of that accept
  (nothing new was written), not of the stored record, so the list shows the accepted file without it. Tests that want
  to know whether a copy was made look at the folder.
- **`O_TMPFILE`'s `linkat` needs the file open.** The unnamed file is linked through `/proc/self/fd/N`, so the
  descriptor has to stay open across every attempt of the numbering loop, and only then be closed.

## 2026-10-06 · Pictures that never show (`crates/antenna-files/src/quarantine.rs`, `apps/antenna_desktop/lib/{protocol/src/client,state/files,state/pictures,ui/files/image_thumbnail}.dart`)

- **Every received picture from an own computer shows "Couldn't show the preview image".** Symptom: on a Mac, images an
  agent on the owner's server sent (level 5, "Accepted into shared/") show the error on the Files screen and in the
  chat, while the same files had a preview on the Linux check. Cause, on every OS: the accept deleted the safe preview
  and `file_preview` refused an accepted file (`bad_state: the file is not checked yet`). At level 5 the daemon
  accepts right after the check (D-99), before the window ever asks, so no picture from an own computer could show.
  Fix: the accept keeps the preview and `file_preview` answers for an accepted file; a file accepted by preview.8 or
  earlier has none left and shows its type icon. Check: `tests/pipeline.rs` `an_accepted_picture_keeps_its_safe_preview`
  and `live_files_test.dart` "a picture from an own computer"; with the old accept both fail with `bad_state`.
- **The window refused any reply line over 256 KiB.** `file_preview` carries its PNG images inline as base64, and the
  daemon's PNG of a screenshot or a detailed 1024-pixel logo is already more than that (a 640 × 480 noisy picture:
  1.06 MB of PNG, 1.4 M base64 characters). The window's client checked every line it read against `MAX_LINE`, the
  limit for lines a client sends, and threw "line too long"; the CLI reads any line, so `antenna files preview` worked.
  Fix: replies are read up to 64 MiB (`maxReplyLine`); requests stay within 256 KiB. Check: `client_v7_test.dart` "a
  file_preview reply longer than 256 KiB" and the live test above; with the old limit both fail with `line too long`.
- **The sender's own screenshot shows "Couldn't show the preview image".** A different cause (a sent picture's
  path is gone after the send): see "The sender's own image" below (D-UI-42).
- **A contact's photo picture stays initials while drawn ones show.** A photo arrives unchecked (the `picture` event
  says `withheld: unavailable`); the daemon checks it in the sandbox only on the next `pictures` (CONTROL §28), and
  the window asked for `pictures` only at unlock and after `lagged`. Fix: the window asks for `pictures` at once on
  such an event (one at a time). Check: `pictures_test.dart` and `live_pictures_test.dart`, which no longer asks the
  daemon itself first; without the call the live test times out on "B's window shows the photo by itself".
- **When no picture can be shown, nothing large says so.** The thumbnail takes no space; the card keeps its type icon,
  name and size, and Open and Show in Finder (Show in folder elsewhere) for a file that is on this computer. The
  daemon logs a WARN for a checked picture without a safe preview, with the verdict, the finding codes and the sandbox
  line (`a picture got no safe preview`): the first place to look on a Mac (a `polyglot_html` threat, for example).

## 2026-10-06 · macOS asks for Screen Recording after every update (`apps/antenna_desktop/lib/{host/screen_permission,state/code_shot,state/doctor,ui/code/screen_permission_sheet}.dart`, `macos/Runner/ScreenAccess.swift`; D-UI-41)

- **Symptom.** After an update, **Screenshot** in Code mode runs `screencapture -i` and macOS asks again whether
  Antenna may record the screen, although System Settings → Privacy & Security → Screen & System Audio Recording shows
  Antenna switched on; without the permission the picture holds only the desktop. Other permissions (Documents,
  Downloads, Desktop…) come back after updates the same way.
- **Cause.** macOS keeps a privacy grant with the app's designated requirement and checks each new version against it
  (Apple TN3127). The app is signed ad hoc (`packaging/macos/build-dmg.sh`), so its requirement is its cdhash, which
  every build changes: the switch shown is the previous build's entry, and the new build does not satisfy it. Toggling
  the switch keeps the old entry. Separately, `CGPreflightScreenCaptureAccess()` caches "no" for the life of the
  process: a grant made while Antenna runs is seen after a restart.
- **Fix.** The window checks with `CGPreflightScreenCaptureAccess()` (never prompts) before the tool runs and, when the
  permission is missing, shows its own sheet instead: the reason, the steps, **Open Screen Recording settings** and
  **Try again** (check again, then ask macOS once with `CGRequestScreenCaptureAccess()`; the tool runs only when
  allowed). Settings → Check shows the same state and fix (`screen_recording_missing`). For the owner: in Screen &
  System Audio Recording select Antenna, remove it with −, add it back with + and switch it on, then quit and reopen
  Antenna. From Terminal the stale entry can also be removed with `tccutil reset ScreenCapture
  io.github.danta-nort.antenna` (then Antenna asks once more). The lasting fix is a stable signing identity (Developer
  ID; a self-signed interim is evaluated in D-UI-41).
- **Verify.** `test/widget/screen_permission_test.dart` (allowed: the tool runs; missing: the sheet, no tool, the pane's
  URL opened, one question to macOS on **Try again**; the Check row in each state, none on Linux) and
  `test/host/screen_permission_test.dart`. With the check removed from `takeScreenshot` 5 of them fail. On a Mac
  (not run yet): install a new build over a granted one; **Screenshot** shows the sheet; after −, +, the switch and a
  restart it captures other apps' windows.

## 2026-10-06 · The sender's own image: "Couldn't show the preview image" (`apps/antenna_desktop/lib/{host/sent_previews,state/files,ui/files/image_thumbnail}.dart`; D-UI-42)

- **Symptom.** A screenshot sent in a chat arrived and the contact accepted it, but the sender's own bubble showed
  "Couldn't show the preview image".
- **Cause.** The sender's bubble read the original file again, through a path the window kept in memory, and there
  was none to read: an image sent from the composer (attach, drop, paste; the way images go since D-UI-21) never had
  its path recorded; a staged send recorded the original's path, and a macOS screenshot dragged from its floating
  thumbnail is a temporary file that macOS deletes a moment later; after a restart no sent image had a path. The
  safe-preview path of the daemon was not involved: an outgoing image never asked for one.
- **Fix.** The window reads the bytes it is about to send, rebuilds them with the engine (at most 1600 px, PNG, pixels
  only) and keeps that copy per link and file ID in its own folder (macOS `~/Library/Application Support/Antenna/
  sent-previews`, Linux `~/.cache/antenna/sent-previews`, 0700). The bubble and the viewer show only that copy. A link
  removed with its history takes its copies; copies older than 30 days and the oldest over 256 MiB go.
- **How to verify.** `flutter test test/widget/image_thumbnail_test.dart test/host/sent_previews_test.dart` (the
  original deleted after the send, the copy still shown; no text chunk of the original in the copy; the size bound);
  with the copy not kept, or the original bytes kept instead of the rebuilt ones, they fail. Live:
  `test/protocol/live_sending_test.dart`.

## 2026-10-06 · A long pasted text: "not sent: bad_request" (`crates/antenna-core/src/node/text_limit.rs`, `apps/antenna_desktop/lib/{state/long_text,ui/chat/composer,ui/chat/message_bubble}.dart`; D-UI-42)

- **Symptom.** A macOS crash report (well over 64 KB) pasted into a chat: the bubble showed only "not sent:
  bad_request" with Retry, and Retry failed the same way.
- **Cause.** One message holds at most 64 KiB of UTF-8 (`link::MAX_TEXT`); the daemon refused more as `bad_request`
  with the English message "text must be 1..65536 bytes", and the bubble showed only the code.
- **Fix.** The daemon refuses a text over the limit with its own code `text_too_long`, naming the size and the limit
  (an empty text stays `bad_request`). The composer counts bytes near the limit and over it turns Send into **Send as
  a file**: the text goes as a `.txt` named after its first line, in the same chat, with the chat's address. A bubble
  refused as too long (also an older daemon's `bad_request` for such a text) offers **Send as a file**; any other
  refusal shows its explanation with the daemon's own text.
- **How to verify.** `cargo test -p antenna-core --lib text_limit`; `flutter test test/widget/long_text_test.dart`
  (the negative controls: the long text sent as a message; the older daemon's code not read as too long); live
  `test/protocol/live_sending_test.dart`: `text_too_long · the text is 71695 bytes and a message holds at most 65536:
  send it as a file`, then the contact has `Process-Antenna-4127.txt`, 71695 bytes.

## 2026-10-06 · Selecting a long message lost its start (`apps/antenna_desktop/lib/ui/chat/bubble_text.dart`; D-UI-42)

- **Symptom.** A selection started at the top of a message taller than the screen and dragged to its bottom: the list
  scrolled, and only the last lines stayed selected.
- **Cause.** A bubble was a `SelectableText`. During a drag, Flutter's `TextSelectionGestureDetectorBuilder`
  (`onDragSelectionUpdate`) corrects the drag's start for a scroll of the surrounding `Scrollable` by
  `pixels - pixelsAtStart`, as if the list grew downwards; the chat's list is reversed (`AxisDirection.up`), so the
  correction has the wrong sign and the start slides towards the pointer by twice the scroll. It was not the lazy list
  disposing the row (the chat keeps 50,000 px of rows laid out).
- **Fix.** A bubble's text is a `SelectionArea`, which keeps the start as a position in the text. Every message also
  has **Copy text** (its right-click menu, and beside the bubble on hover), and a message taller than 60% of the chat
  is cut with **Show all**: a reader with one selectable text in a list that grows downwards, and **Copy all**.
- **How to verify.** `flutter test test/widget/message_text_test.dart`: a drag from line 1 with the list scrolled
  120 px during it copies from "line 1"; with a `SelectableText` bubble it copies from "line 13".

## 2026-10-06 · Scrolling back in the dock's terminal (`apps/antenna_desktop/lib/{state/terminal_mouse,ui/code/agent_terminal}.dart`; D-UI-42)

- **Symptom.** In Code mode the agent's terminal could not be scrolled back: Claude Code asked something, the output
  went on, and the question was gone.
- **Cause.** Recorded in a pseudo-terminal (`TERM=xterm-256color`, 2026-10-06), Claude Code 2.1.291 switches to the
  alternate screen (`CSI ? 1049 h`, after the folder trust question) and asks for mouse reports (`CSI ? 1000 h`,
  `1002`, `1003`, SGR `1006`). The alternate screen has no scrollback in the terminal: the program scrolls its own
  transcript when the terminal reports the wheel. xterm 4.0.0 reports the wheel as buttons 68 and 69 (`64 + 4`,
  `64 + 5`); the protocol's wheel is 64 and 65, and adding 4 is the Shift bit, so Claude Code read Shift + wheel and
  ignored it (after `!seq 1 150`: five `CSI < 68 ; 20 ; 10 M` gave 87 bytes of output and no scroll; five
  `CSI < 64 ; 20 ; 10 M` redrew the earlier lines, 1883 bytes).
- **Fix.** The agent's terminal reports the wheel with the protocol's codes in every report mode (normal, UTF-8,
  SGR, urxvt) through the package's `mouseHandler` hook (`WheelMouseHandler`; clicks stay the package's). A program
  that did not ask for the wheel gets arrow keys in the alternate screen, as in other terminals. On the main screen
  (a shell, a CLI that prints): a bounded scrollback of 10,000 lines, scrolled by the trackpad, the wheel and the
  scrollbar; new output keeps the view while the person reads back (xterm's own rule) and **Jump to the latest
  output** brings it to the end. Whether Claude Code keeps its own view while it writes is Claude Code's behaviour.
  Remove the handler when the terminal package reports the wheel right.
- **How to verify.** `flutter test test/widget/agent_terminal_test.dart` (the wheel in the alternate screen reaches
  the program as `CSI < 64` and `CSI < 65`; with the package's handler, 68 and 69; scrolled back, 40 new lines do not
  move the view). On a Mac: start Claude Code in Code mode, let it write more than a screen, and scroll back with the
  trackpad.

## 2026-10-06 · A file attached in one chat waited in another; a chat opened in the middle (`apps/antenna_desktop/lib/{state/drafts,state/files,state/conversation,ui/chat/chat_view,ui/chat/composer}.dart`; D-UI-42)

- **Symptom.** A screenshot attached in one chat was still in the composer after opening another chat ("Nothing is
  sent yet: on Send (Enter) these go to “atlas server”…"), where Enter would have sent it. A chat left at its end opened
  in the middle, at an old message, after visiting another chat.
- **Cause.** The composer was one widget for every chat, and the waiting files were kept per contact, not per chat:
  a contact's person chat and its agents' chats shared them, and the hint named only the contact. The chats of a
  contact also shared one message list, which kept the other chat's offset and moved it further by the height of
  the other chat's last row (`_compensate` read the new last row as a new message).
- **Fix.** Each chat has its own draft (text, files, To and topic choices), its own composer and its own list with
  its reading position (drafts.dart). The hint names the exact recipient; the chat list says "Draft: …".
- **How to verify.** `flutter test test/widget/drafts_test.dart test/widget/reading_position_test.dart`: with drafts
  keyed per contact the file shows in the other chat; with one list per contact the person chat opens at 558 px
  instead of its end.

## 2026-10-06 · A generated PNG held as `polyglot_html` (`crates/antenna-files/src/detect.rs`; D-129)

- **Symptom.** An icon made by an image generator, sent between own computers (∞), was held as a threat on both
  sides: `threat polyglot_html: binary image/png file contains HTML/script markup in its first 1 KiB`; the sender's
  window said "The contact declined the file".
- **Cause.** The PNG carries an XMP packet (`iTXt`, keyword `XML:com.adobe.xmp`) and content credentials (C2PA: a
  JUMBF box in a `caBX` chunk, ~23 KB) before the pixels. The polyglot heuristic searched the raw first KiB for
  `<svg`, `<html`, `<script`… and matched text inside that metadata.
- **Fix.** The HTML part of the check walks the image container (PNG chunks, JPEG segments, WebP RIFF chunks) by its
  own lengths and leaves out the format's metadata (C2PA, XMP, EXIF, ICC and the JPEG APP segments with a known
  identifier). Markup in any other chunk, a comment, an unknown chunk or after the image's end is still a threat.
- **How to verify.** `cargo test -p antenna-files --lib image_metadata jpeg_and_webp_metadata
  a_generated_png_with_xmp`; with `without()` in `detect.rs` returning the bytes unchanged, all three fail.

## 2026-10-06 · A ZIP of web pages "sent [threat]", the same pages as `.txt` "sent [suspicious]", and "declined" for a held file (`crates/antenna-files/src/{kinds,inspect,worker}.rs`, `crates/antenna-core/src/file_fate.rs`; D-130, D-UI-45)

- **Symptom.** Between own computers (∞) a ZIP of three HTML prototypes showed "sent [threat]" and the same pages as
  `.txt` "sent [suspicious]"; the sender's window said "The contact declined the file" for a file the contact's
  computer only held.
- **Cause.** The ZIP was written stored (Python's `zipfile` default): the first page's markup lay in the archive's
  first KiB and `polyglot_html` fired, a threat; the `.txt` pages are HTML by content (`active_content`). The CLI's
  "sent [verdict]" was this computer's own check, which read like the outcome. A threat was answered with
  `reject_file` / `denied`, which the window showed as declined, though the file waited 7 days for the owner.
- **Fix.** From trust level 3 the check's heuristics are labels (D-130): such files are saved at ∞ and accepted by an
  agent at 3–4. Programs, installers, disk images, archives holding them and antivirus hits wait for **Keep anyway**.
  The sender is told `check_file` / `held` (with `file-fate/0`) and reads "waiting for the contact to decide"; the CLI
  says "sent, waiting for the contact's check" and lists its own findings as labels.
- **How to verify.** `cargo test -p antenna-cli --test file_kinds` (two daemons at ∞, 3 and 2); with `LABELS_FROM` set
  to 6 in `kinds.rs` three tests fail.

## 2026-10-06 · "Owner password" though Touch ID is on (`apps/antenna_desktop/lib/{state/touch_id,state/owner_auth,protocol/src/proving_daemon,ui/security/owner_confirm}.dart`, `crates/antenna-proto/src/control.rs`, `crates/antenna-cli/src/{touch_id,owner/touch}.rs`; D-131)

- **Symptom.** With Touch ID on, **Agents → Start an agent** (and every other prompt except approvals, unlocking and
  signing in) still showed **Owner password**; the window asked for the password when it opened; `antenna trust …` in
  the Terminal too.
- **Cause.** D-102 wired Touch ID into the approval cards and the gate only; the other places passed a password string
  straight into the model's typed daemon calls, so there was no way to send them with a proof. The daemon refused a
  proof for `local_agent_add`, `update_authorize`, the device commands and turning automatic installs off. The gate
  started Touch ID only on a click. The CLI had no access to the window's Secure Enclave key.
- **Fix.** The model's owner commands take an `OwnerAuth` and go through `ownerOp`: the password, or a `ProvingDaemon`
  that signs exactly one typed request over a fresh challenge (a second request through it is refused before anything
  is signed). A trap on the way: the model methods catch only `XClientException`, so a cancelled Touch ID sheet
  (`TouchIdException`, a host exception) would escape them: the proving view wraps it as `XProofException`, which
  `fallbackFor` unwraps. The daemon's `accepts_proof` list grew (D-131). The first gate
  opens the sheet by itself once per run (`touchIdAtStart`). The CLI runs `antenna-touchid`, built next to it; `antenna wake set
  --password-stdin` still reads the password before the secrets' values (the first line of stdin), so scripts keep
  working.
- **How to verify.** `flutter test test/widget/touch_id_everywhere_test.dart test/protocol/proving_daemon_test.dart`;
  `cargo test -p antenna-cli --test owner_keys` (`every_password_command_takes_a_proof_except_three`,
  `the_cli_confirms_with_touch_id_when_it_is_on_here`). On a Mac with Touch ID on: open Antenna locked (one sheet,
  then signed in), Agents → Start an agent (no password field, one sheet "start the agent …"), and `antenna trust <contact>
  4` in Terminal.app (a sheet naming the command).

## 2026-10-06 · Pictures and files in the window (`apps/antenna_desktop/lib/ui/{chat/chat_media,chat/attachments,files/image_viewer,files/media_files}.dart`; D-UI-46)

- **A widget test hangs on a picture read from a file.** `Image.file` started by a frame inside FakeAsync never
  completes, so `precacheImage` inside `runAsync` waits forever (the test times out with no output). Load the file
  image into the cache outside FakeAsync before the first frame: `ResizeImage(FileImage(file), width: …)` resolved in
  `runAsync`, with the same width the widget asks for (`composer_attachments_test.dart`, `_cacheThumb` in the golden
  scenarios).
- **The viewer cannot find the model in a test.** The viewer is pushed on the root navigator; a test that puts
  `AppScope` inside `MaterialApp.home` leaves the viewer without it ("AppScope is missing"), while the app has it above
  `MaterialApp`. Put `AppScope` above `MaterialApp` in such a test (`image_viewer_test.dart`).
- **A fake daemon's reply and real file I/O in one action.** Save as… waits for the daemon (a fake: FakeAsync) and then
  writes a file (real I/O): waiting only in `runAsync` never lets the fake reply. Alternate `pump()` and a short
  `runAsync` delay until the file appears (`_until` in `image_viewer_test.dart`).
- **`ReorderableListView.onReorder` is deprecated** (Flutter 3.41): `onReorderItem` gives the index the item ends up at,
  so `reorderStaged` takes that index, not the "before removal" one.
- **A horizontal `ReorderableListView` stretches its items to its height.** A chip of 56 px in a 76 px list became
  76 px tall; wrap it in `Center`.
- **Spacing off the 8 px grid fails `design_tokens_test.dart`.** 6, 10 or 3 px and a 13 px font are refused; use 4, 8,
  12 and the type scale.

## 2026-10-06 · The agent map as an editor (`apps/antenna_desktop/lib/{state/agent_map_graph,state/agent_map_prefs,ui/agents/agent_map_*}.dart`; D-UI-47)

- **An own computer at ∞ is drawn among the contacts, on the right.** Symptom: a Mac whose only other computer is its
  own server (∞) shows that server in the right-hand column, where the contacts go. Cause: `layoutAgentMap` balanced
  the clusters over both sides whenever there was only one kind of them ("ties go right"), and below about 900 px it
  put everything that was not this computer on the right; the graph itself had the server right
  (`MapClusterKind.ownComputer`). Fix: the automatic arrangement always has three columns in map coordinates and the
  canvas fits them into the view: own computers left, this computer in the middle, contacts right, whatever the
  counts. A contact at ∞ whose report is missing (not in `devices`, or `status` absent) is still an own computer, with
  "Waiting for its report" in its header. Check: `agent_map_graph_test.dart` "placement: own computers always on the
  left…" (one own computer and no contact, no `devices`, several own computers, only contacts, a level-4 contact) and
  `agent_map_test.dart` "own computers on the left whatever else there is…"; with the old balancing put back both fail.
- **The map refits under the pointer while a group is dragged.** Fitting the view whenever the map's extent changes
  (until the owner moves the view) also fired while a group was being dragged, because the extent grows with it: the
  group moved by more than the pointer did. Any arrangement gesture now ends the automatic fit. Check:
  `agent_map_test.dart` "groups and cards move…" (the group moves by exactly the drag over the zoom).
- **A drag on the canvas loses its first few pixels.** `GestureDetector` reports a pan from the point where the slop
  was passed, so a drag of 60 px moved the view or a card by about 52. The map's detectors use
  `DragStartBehavior.down`. Check: the pan and the arrangement tests compare exact offsets.
- **A trackpad's two-finger scroll over a card drags the card.** Flutter's drag recognizers accept trackpad pan-zoom
  events by default. Every detector on the map lists its devices without the trackpad (`mapDragDevices`); the
  canvas's `Listener` pans and zooms with `PointerPanZoom*` instead. To verify on a Mac: a two-finger scroll and a
  pinch over a card move and zoom the map, a click-drag on the card moves the card.
- **A widget test opens the map with a settings file and every tap misses.** `Appearance.load` of a new file shows the
  one-time notices (the Code mode offer, the level 5 notice) over the window. Write `code_offered` and
  `self_notice_shown` into the test's `window.json` first.

## 2026-10-06 · Local routes between two agents of one computer (`crates/antenna-core/src/local_routes.rs`; D-132, CONTROL §32)

- **An agent's message to another agent of this computer is refused with `hop_limit`.** Cause: it would be the ninth
  message in a chain between agents of this computer within 10 minutes (each message counts one more than the
  highest one its writer read), so the daemon stops what looks like two agents answering each other forever. Fix:
  wait 10 minutes with no new local message read, or reset the writer's session (`antenna agent reset <name>`). Check:
  `tests/local_routes.rs::the_loop_limit_holds`.
- **It is refused with `forbidden` "no write down".** The writer's local data label (its baseline from `agent add
  --local-level` and what it declared with `mark_read`) is above the recipient's. A higher agent cannot write to a
  lower one over a local route, and there is no approval for it in this version. Fix: the owner gives the recipient
  the label it needs, or resets the writer's session; writing the other way is allowed.
- **The recipient's session became tainted although it read nothing from a contact.** That is the rule, not a bug: a
  local message carries what its writer had read, and reading it gives the reader the same taint and label. `antenna
  session` shows the contact under `tainted_by`; the owner's `agent reset` cleans the session.
- **The two transactions of an inbox read.** The link messages' cursor and the local messages marked read share one
  transaction with the label they taint; a second `unchecked_transaction` inside the first fails in SQLite ("cannot
  start a transaction within a transaction"), so `agent_inbox` opens one and both parts use it.

## 2026-10-06 · Urgent messages and the stop switch (`crates/antenna-core/src/{urgent,agent_stop}.rs`, `crates/antenna-cli/src/session/{keys,reap,waker}.rs`; D-133, CONTROL §33)

- **An urgent message did not interrupt the agent.** Look at the agent's computer: `antenna log <your other
  computer>` has an `urgent` entry. `refused level_N`: that computer does not have yours at level 5 (∞); urgency is
  honoured only from an own computer, checked there. `refused stale` / `ahead`: the message was more than 10 minutes
  old (or dated more than 2 minutes ahead) by its own clock when it arrived; check both clocks. `refused rate`: the
  agent was interrupted by an urgent message less than 30 s before. No entry and `sent.urgent: false` on your side:
  the other Antenna is older and got a normal message. An AI app's agent (Claude Desktop, Cursor, ChatGPT) cannot be
  interrupted from outside at all.
- **The urgent message was honoured but nothing was pressed yet.** The Escape goes only where it can do nothing but
  interrupt: the CLI's own screen says "esc to interrupt". It waits while the agent asks a question in its terminal
  (Escape would answer it), while text you typed stands in its input, within 5 s of a key from a person attached to
  the `antenna session`, while tmux is in copy mode, and within 30 s of the last interrupt. `antenna --json session
  list` shows the reason in the session's `hold` (`dialog`, `draft`, `person`, `mode`, `rate`); the window says it
  under the terminal. Answer the question or clear the draft, and the urgent line follows.
- **After the interrupt Claude Code shows its rewind menu.** Two Escapes close together open it ("Esc + Esc … When the
  input is empty, double Esc opens the rewind menu"). Antenna presses one Escape at most every 30 s and not within
  5 s of a person's key, so a second one came from the keyboard; press Escape to close the menu.
- **A stop left an app open on a Mac.** An app opened through LaunchServices (`open -a`, Finder, `osascript …
  activate`, the iOS Simulator booted by `xcrun simctl`) is started by launchd, not by the agent: it is in neither the
  agent's terminal session nor its process tree, so the stop cannot attribute it. Quit it yourself (Force Quit,
  Option-Command-Esc). An app the agent ran directly (its binary, `flutter run -d macos`) is the agent's and stops.
- **A stop left a detached server running on Linux.** A process that called `setsid` and lost its parent leaves the
  session; it stays in the agent's tree only under a child subreaper. `antenna session` runs the CLI under one
  (`antenna session-reap`: in `ps` it stands between the pane's `antenna session run` and the CLI; that is expected);
  the window's Code mode does not yet. Find it with `ps -eo pid,ppid,sid,comm` and stop it by its PID.
- **The stop says `how: app`.** The agent's MCP host is an app you run (a GUI app, a process without a terminal, or
  several hosts of one app): Antenna does not quit your app; it replaced the agent's token, so the app's next call
  through Antenna is refused. Connect the app again in Agents → AI apps (or `antenna agent token <name>`) to use it.
- **The stop says `how: process`, not `terminal`, for a Code mode or `antenna session` agent.** The window or the pane
  process did not tell the daemon its terminal (an older window, or the daemon restarted and nothing reconnected yet):
  only the agent's process and what is under it stopped. A reconnect says it again.
- **Tests: an Escape is not a line.** The stand-ins read their input line by line (canonical mode), so an Escape
  never reaches them until Enter. `tests/urgent.rs`'s stand-in switches its terminal to non-canonical mode while a
  turn runs and reads keys with `select`, as Claude Code reads its keys during a turn, and puts the mode back after.
- **Feature bits** (`LinkShared::peer_feat`): `urgent/0` is 8192, `agent-stop/0` 16384; one bit of the 16 is left (32768), then the field must widen.

## 2026-10-13 · A test that reads a source file fails only on Windows (`.gitattributes`; D-134)

- **Symptom.** On a Windows build machine, `setup::tests` failed while comparing the `AGENTS.md` template with the
  constant in `apps/antenna_desktop/lib/state/agent_setup.dart`; the same commit passed on Linux and macOS.
- **Cause.** Git for Windows checks text files out with CRLF line ends by default (`core.autocrlf=true`), and so do
  the hosted Windows CI runners. The test reads the Dart file at run time and gets `\r\n`, while the Rust constant it
  compares with has `\n`.
- **Fix.** `.gitattributes` sets `* text=auto eol=lf`: every text file has LF in every checkout, whatever the local
  setting. Test fixtures (`crates/antenna-files/tests/corpus/`, PDFs) and the vendored font licenses (CRLF upstream)
  are `-text` and stay byte for byte; `.bat` and `.cmd` get CRLF. Adding the file renormalized nothing: the index
  already had LF everywhere else. The template test also normalizes CRLF, for checkouts made before this change.
- **How to verify.** `git ls-files --eol | grep -v "attr/-text" | grep crlf` prints nothing; on Windows, a fresh
  clone has LF in `apps/antenna_desktop/lib/state/agent_setup.dart` (`git ls-files --eol` shows `w/lf`).

## 2026-10-13 · Type checking for Windows from Linux (`tools/check-windows.sh`, `tools/windows-check.toml`; WP-32, D-134)

- **Symptom.** `cargo check --workspace --target x86_64-pc-windows-msvc` on Linux stops before any of our code, in the
  build scripts of `blake3`, `ring`, `openssl-sys` (`openssl-src`) and `aws-lc-sys` (`failed to run custom build
  command`; `ring` reports `VCINSTALLDIR = None`); `libsqlite3-sys` (SQLCipher) waits behind `openssl-sys`.
- **Cause.** These build scripts compile C for the target, which needs MSVC and the Windows SDK; neither is on a Linux
  machine, and `cargo-xwin` (which downloads them) is not used for their license (WP-32). check and clippy never link,
  so only the scripts' output is needed: cfg flags and bindings.
- **Fix.** `tools/check-windows.sh`, the method of D-P-7 (`tools/check-darwin.sh`): `tools/windows-check.toml` replaces
  the build scripts of `aws-lc-sys`, `ring` and `openssl-sys` with what they print for this target, and `blake3` runs
  with `pure`. `libsqlite3-sys` keeps its own build script: `LIBSQLITE3_SYS_USE_PKG_CONFIG=1` sends it down its
  "linked" path, which copies the same prebuilt `sqlcipher/bindgen_bundled_version.rs` its bundled build copies and
  prints link lines that check never uses. That replaces the macOS script's two runs (fail, take `OUT_DIR` from the
  `couldn't find file …/bindgen.rs` error, copy the bindings, retry). `wasmtime` compiles its `helpers.c` for Windows
  only with `debug-builtins`, which our tree leaves off, so no C stub is needed here.
- **Two cfg values that differ from the macOS overrides.** `aws-lc-sys` 0.45 without its `all-bindings` feature (off:
  `aws-lc-rs` turns its default features off) prints `universal` for x86_64 Windows, as for x86_64 Linux, not the
  target's name: target-named bindings come only with `all-bindings`, prefixed ones only for Apple and 32-bit
  Windows. `openssl-sys` prints the same cfg as on Linux, `ossl350` and the five `osslconf` values included:
  `openssl-src` adds only `no-capieng` on Windows, which `openssl-sys` does not probe. Both are taken from the build
  scripts' sources and from a Linux build's `target/debug/build/*/output`.
- **Each run takes ≈ 30 s (debug) or ≈ 55 s (`--release`) even when nothing changed.** The two clippy passes give
  clippy different arguments, which are part of each workspace crate's fingerprint, so each pass re-lints our eight
  crates (one pass repeated is cached: 0.5 s). Dependencies are not checked again. The Linux passes behave the same.
- **How to verify.** `tools/check-windows.sh` and `tools/check-windows.sh --release` end with `OK: clippy
  x86_64-pc-windows-msvc`. Negative controls (`main` at abd64f6): `use std::os::unix::fs::PermissionsExt` with
  `.permissions().mode()` outside `cfg(unix)` in `antenna-core` fails with E0433 "could not find `unix` in `os`" and
  exit code 101, while the same change passes `cargo check` on Linux; a `#[cfg(windows)]` function nobody calls
  fails the first pass (`dead_code` under `-D warnings`); a `#[cfg(windows)]` `.unwrap()` in library code passes the
  first pass and fails the second (`clippy::unwrap_used`). A bump of `aws-lc-sys` or `ring` changes their `links`
  key: the old override no longer applies, the real build script runs and fails as in the symptom; update the key
  and compare the cfg with the new build script.

## 2026-10-13 · Windows bugchecks (0xD1, `afunix.sys`) while the window's protocol tests run (D-135)

- **Symptom.** A Windows 11 build machine (25H2, build 26200) stopped with a bugcheck twice while
  `flutter test` ran: `DRIVER_IRQL_NOT_LESS_OR_EQUAL` (0xD1) with process `flutter_tester` and
  `AV_afunix!AfUnixTlConnectEndpointDisconnect` (`afunix.sys` 10.0.26100.8972).
- **Cause.** The stack is the process teardown closing an AFD socket handle (`AfdCleanupCore` →
  `AfdCancelTPackets` → `AfdAbortConnection` → `afunix!AfUnixTlConnectEndpointDisconnect`, then a call through a
  null pointer). This most likely happens when a connected AF_UNIX client still has a disconnect pending when its
  process is killed. The tests under `apps/antenna_desktop/test/protocol/` that open a dart:io AF_UNIX server and
  client do exactly that when `flutter test` ends each file. The exact trigger has not been reproduced, and a repro
  would crash its machine.
- **Fix.** Windows uses no AF_UNIX (D-135): those tests run on Linux and macOS only, and the control socket on Windows
  is a named pipe.
- **How to verify.** Run `flutter test` in `apps/antenna_desktop` on Windows: it runs no test that opens an AF_UNIX
  socket (`grep -rl "InternetAddressType.unix" test/` lists only files marked `@TestOn('!windows')`). Never reproduce
  the bugcheck on a machine you need: use a disposable VM.

## 2026-10-13 · The window bridge (`crates/antenna-cli/src/window_bridge.rs`, `apps/antenna_desktop/lib/protocol/src/bridge_mux.dart`; D-135, CONTROL §34)

- **A console window opens next to the Antenna window on Windows.**
  - Cause: a GUI process that starts a console program (`antenna.exe`) with `Process.start` in the normal mode makes
    Windows give the child a new console.
  - Fix: on Windows the bridge is started with `ProcessStartMode.detachedWithStdio`. In that mode `Process.exitCode`
    is not available, so the bridge's end is the end of its stdout, after which the window starts a new one on the
    next connection.
  - How to verify: start the Windows window; no console window appears, and `tasklist /fi "imagename eq antenna.exe"`
    shows one bridge.
- **E0515 "cannot return value referencing local data `path`" in the bridge's connect closure.**
  - Cause: in Rust 2024 a returned `impl Trait` captures every lifetime in scope, so the stream halves that
    `connect_raw(&Path)` returns counted as borrowing the path.
  - Fix: `+ use<>` on both `impl` types: the halves own everything they need.
  - How to verify: `cargo build -p antenna-cli`.
- **A closed connection's last bytes could reach the next connection with the same id.**
  - Cause: the first design freed an id at the window's `close`, while the bridge could still have that connection's
    frames queued for stdout.
  - Fix: each side sends one `close` per id, first or in answer, and an id is free only after both. The bridge
    answers from its main loop after stopping the connection's task; the window counts ids up.
  - How to verify: `an_id_is_reused_only_after_both_closes` (Rust) and "at most 256 connections in use, counting a
    closed one until the bridge answers" (Dart); the latter fails when the window frees the id at its own close.
- **Two traps in the Dart tests.**
  - `StreamSubscription.asFuture` replaces the subscription's `onError`, so the error a test wants to see completes the
    future with an error instead: wait on `onDone` with a `Completer`.
  - A record with a `List` field compares the list by identity, so `expect((1, 2, [3]), (1, 2, [3]))` fails: the
    fake bridge records content as Latin-1 text.

## 2026-10-13 · Two daemons on one data folder (`--socket` got around the socket guard; `antennad.lock`; D-135)

- **Symptom.** On Linux and macOS `antennad --data-dir D` and `antennad --data-dir D --socket /elsewhere.sock` (or
  `ANTENNA_SOCKET`) both started and ran. Two processes then worked on one database, one keystore and one set of
  ratchet states, and neither knew of the other. Windows had refused the second one since D-135.
- **Cause.** The only guard on unix was the control socket inside the folder: `control::bind` refuses a socket that
  still answers. A second daemon on another socket path never looks at the first one's socket, so nothing tied the
  data folder to one process.
- **Fix.** The lock of Windows is now one portable function, `antenna_core::data_lock::lock`, used by `antennad` on
  every system: `<data-dir>/antennad.lock` is created `0600` (`owner_only`) and locked with `File::try_lock`
  (`flock(2)` on unix) right after the folder is made and set to `0700`, before anything else in it is read or
  written, and held until `run()` returns. A second daemon on the folder exits with status 1 and says "another
  antennad is using the data folder D (it holds antennad.lock): stop it first, or give this one another --data-dir",
  the words of Windows. What to know:
  - The lock belongs to the open file, not to the name: a crash or `kill -9` frees it, and the file left behind
    blocks no one (a restored backup or a copied folder may hold the file too; it is only an unlocked file). Nothing
    reads or writes its contents.
  - Do not delete `antennad.lock` while a daemon runs: that daemon keeps the lock on the removed file, and a second
    daemon then makes and locks a new one. Windows holds the file with a share mode that forbids deleting it; unix has
    no equivalent, and the folder is `0700`, so only its owner can do it.
  - Children do not inherit the lock: Rust opens the file close-on-exec, so the file check worker, a wake agent and
    the installer never keep a dead daemon's lock alive. The daemon that replaces itself by `execve` after an
    automatic update (D-103) returns from `run()` first, which closes the file, and takes the lock again as the new
    image.
  - The one-time move of the preview build's folder (`resolve_dirs`) runs before the lock, as on Windows; it renames
    one folder and refuses while the old daemon's socket answers.
  - A filesystem that cannot lock at all would stop the daemon with the system's error and the lock file's name (the
    check could not be made, so the answer is no): put `--data-dir` on a local disk. By construction, not seen so
    far.
- **How to verify.** `cargo test -p antennad --test daemon`: `a_second_daemon_on_the_same_data_dir_is_refused` starts a
  daemon, then a second on the same `--data-dir` with another `--socket`, which exits 1 with the message above and
  makes no socket, while the first still answers `status`; after the first is killed (its socket file stays) a new
  daemon starts on the folder; `socket_and_data_dir_are_private` checks the lock file is `0600`. Unit tests:
  `cargo test -p antenna-core --lib data_lock`. Negative controls (`main` at 9478a07): with `file.try_lock()` replaced
  by an unconditional success the daemon test fails after 20 s ("the second daemon on the same data folder must
  refuse and exit": it started) and `the_lock_keeps_a_second_daemon_out` fails on `unwrap_err()` of an `Ok` value;
  without `.owner_only()` `the_lock_file_is_owner_only` fails with mode `100644` under umask `022`. By hand:
  `antennad --data-dir /tmp/d --relay disabled &` then `antennad --data-dir /tmp/d --socket /tmp/d2.sock --relay
  disabled` prints the refusal and exits 1; `kill` the first and the second command starts.

## 2026-10-13 · antennad on Windows: the data folder, elevation, the pipe and the first package (`crates/antenna-core/src/{data_folder,control}.rs`, `crates/antennad/src/main.rs`, `crates/antenna-cli/src/client.rs`, `apps/antenna_desktop/lib/host/{daemon_host,binaries}.dart`; D-135)

- **"The data folder is not yours alone".**
  - Symptom: antennad does not start and lists what it found, each line with a SID and its rights. For example:
    "its access list takes the entries of the folder above it", or "S-1-5-32-545 (Users) has rights 0x001200a9
    (read and execute)". Nothing in the folder was changed.
  - Cause: the folder existed before antennad made it (made by hand, copied, restored), so it carries entries
    inherited from `%LOCALAPPDATA%` or entries for other accounts. antennad makes its folder for the user alone, and
    it checks a folder it did not make by the rule in `data_folder::check`. That rule follows Win32-OpenSSH for its key
    files, and is stricter:
    - the owner is you;
    - the access list is protected, and no entry in it is inherited;
    - entries may allow only you, SYSTEM and the Administrators;
    - deny entries are fine.
  - Fix: in a normal (not elevated) PowerShell, give the folder your own protected list:
    `icacls "$env:LOCALAPPDATA\Antenna" /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F"`. Then remove each other
    SID the message named: `icacls "$env:LOCALAPPDATA\Antenna" /remove:g "*S-1-5-32-545"`. If the message says the
    owner is not you: `icacls "$env:LOCALAPPDATA\Antenna" /setowner "$env:USERNAME"`. A folder you no longer need can
    simply be moved away: antennad then makes a new one for you alone, but the old folder's keys and history stay in
    the old folder.
  - How to verify: `icacls "$env:LOCALAPPDATA\Antenna"` shows only your account, `(OI)(CI)(F)`, without `(I)`, and
    antennad starts. This was tried on a scratch folder made the ordinary way with an extra Users entry: refused
    before the two icacls commands, started after them.
- **"antennad does not run elevated" (antennad runs elevated).**
  - Symptom: antennad stops at once with that message. Started by the window, the window shows the daemon's message
    under "daemon did not start".
  - Cause: the process has an elevated token (TokenElevation). It was started with "Run as administrator", from an
    elevated terminal or a program that runs elevated, or User Account Control is off: then every program of an
    administrator account runs elevated. An elevated daemon would make its pipe and files as the Administrators, and
    its keys would sit in an administrator's process.
  - Fix: start Antenna from the Start menu or the desktop shortcut, or from a terminal that was not opened "as
    administrator". If UAC is off, turn it back on (Settings → User Account Control; a restart follows), or use
    Antenna from a standard account. Antenna never changes this setting itself.
  - How to verify: in the terminal you start it from, `whoami /groups | findstr Mandatory` shows "Medium Mandatory
    Level", not "High".
- **The window started its daemon, then never reached it ("not a local pipe name").**
  - Cause: the window's bridge (`antenna.exe window-bridge`) resolves the daemon's address once, when it starts.
    That is before the window starts the daemon, so before the data folder exists, and there is no pipe name without
    the folder's canonical path. The CLI gave the folder's own path for later, and every later connect of that bridge
    got the folder, not the pipe.
  - Fix: on Windows `connect()` takes an existing data folder as its pipe and names the pipe when it connects
    (`pipe_of_folder`).
  - How to verify: `a_folder_resolved_before_it_existed_names_its_pipe_later` (Rust), and the window-flow test
    `test/protocol/live_bridge_windows_test.dart` (first connect, then start, then connect).
- **A password set from PowerShell is "wrong" in the window.**
  - Cause: Windows PowerShell 5.1 sends a UTF-8 byte order mark (EF BB BF) before the text it pipes into a program. So
    `$pw | antenna init --password-stdin` made the mark part of the password, and every later CLI command repeated it.
  - Fix: the CLI drops one leading U+FEFF from each line it reads from stdin (`stdin_line`). A password set before
    the fix keeps the mark: change it, or start that data folder again.
  - How to verify: `a_byte_order_mark_and_the_line_end_are_not_part_of_the_line`. By hand:
    `'abc' | python -c "import sys; print(sys.stdin.buffer.read())"` in Windows PowerShell shows
    `b'\xef\xbb\xbfabc\r\n'`.
- **Owner commands in a Windows terminal say login_required, and `antenna login` opens no session.**
  - Cause: a console can be joined by another process and a parent can be chosen, so neither names a terminal, and
    the daemon opens no terminal or parent session on Windows (WP-10).
  - Fix: in a terminal, a command that needs a session asks for the password and holds a session for itself until
    it ends (`client::hold_session`): one password per command. A script without a terminal has no such way yet.
  - How to verify: `an_owner_command_holds_a_session_for_itself`.
- **Connect would write apps' files at the drive's root.**
  - Cause: on Windows `HOME` is unset, so the home folder the window used was `/`, and the Linux paths of the apps'
    files (`.config/…`) landed at `C:\.config\…`.
  - Fix: on Windows a file is only written where its path was checked on a PC (`AppConfigSpec.windows`): Claude
    Desktop inside its MSIX package (`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\…`) when
    that package is installed, otherwise `%APPDATA%\Claude\…`. Every other app gets the manual steps.
  - How to verify: the Windows test in `test/host/mcp_config_test.dart`.
- **A force-closed window left antennad running.**
  - Cause: Windows does not end a child with its parent.
  - Fix: the window starts its daemon with `--exit-with-stdin` and keeps its stdin open. When the window is gone, even
    killed, the daemon reads end of file, locks and exits as on SIGTERM. Linux had the same orphan and gets the same
    fix.
  - How to verify: `a_daemon_on_a_lifeline_exits_when_its_stdin_closes`; by hand, end the window in Task Manager and
    no `antennad.exe` is left.
- **The release antennad.exe prints nothing.**
  - Cause: it is a GUI-subsystem program (WP-28), so the window that starts it opens no console window.
  - Fix: started from a terminal with no standard error of its own, it attaches to that terminal's console
    (`attach_parent_console`), so `antennad.exe --version` prints there. The terminal does not wait for it, so the
    prompt can come back before its output.
- **The daemon's log.** `%LOCALAPPDATA%\AntennaLogs\antennad.log`, beside the data folder and never inside it. If the
  window made the data folder for its log, the folder would inherit `%LOCALAPPDATA%`'s entries, and antennad would
  rightly refuse it.

## 2026-10-13 · Code mode's terminal on Windows: flutter_pty, the job, inheritance, Ctrl+C (`crates/antenna-sys/src/windows/{job,conpty,spawn}.rs`, `crates/antenna-cli/src/agent_run.rs`; D-134)

- **flutter_pty 0.4.2 cannot start an agent CLI on Windows.**
  - Cause (`src/flutter_pty_win.c` and `lib/flutter_pty.dart` in the package):
    - the command line is the arguments joined with spaces, unquoted, so `--settings <json>` or a path with a space
      falls apart, and the executable appears twice;
    - every string goes from UTF-8 to UTF-16 one byte at a time, so non-ASCII folders, names and values are garbled;
    - the environment holds only what Dart passes: `PATH` is copied by a case-sensitive name, but Windows' is `Path`,
      and `SystemRoot`, `TEMP` and `APPDATA` are missing;
    - it sleeps 1 s before each start, never closes the pseudoconsole and makes no job, and `kill()` is dart:io's
      `killPid`, which on Windows ends one process.
  - Fix: on Windows the window starts `antenna agent-run`, which hosts the pseudoconsole and the job itself and
    speaks frames with the window. flutter_pty stays on Linux and macOS.
  - How to verify: `arguments_come_back_unchanged` (antenna-sys) and
    `the_agent_gets_its_folder_arguments_and_environment_unchanged` (`antenna-cli --test agent_run`). Each has a
    control that does what flutter_pty does and gets something else back.
- **Stop left the agent's children running.**
  - Cause: ending a process by its PID ends that process alone. On Windows a process is not ended with its parent.
  - Fix: everything a run starts is in one job, from its creation (`PROC_THREAD_ATTRIBUTE_JOB_LIST`). The job ends
    every process in it when its last handle closes, and it lets nothing break away. Stop terminates the job; the
    window's end (the host's stdin closes) and the host's own end do the same.
  - How to verify: `terminating_the_job_ends_every_process_in_it`, `closing_the_last_handle_ends_every_process_in_it`
    and `nothing_breaks_away_from_the_job` (antenna-sys), `stop_the_windows_end_and_the_hosts_end_end_everything`
    (agent_run). Each has its control without the job's guarantee.
- **FACT: with `bInheritHandles=TRUE` the pseudoconsole's output never ends.** An inherited copy of a pipe end keeps
  it open after the console is closed, so the host waits forever for the end of the screen. The hang is what the test
  shows; which handle it is was not pinned down. Processes are started with nothing inherited (WP-12): the
  pseudoconsole test failed with inheritance turned on, and `no_handle_is_inherited` shows that std's `Command` passes
  inheritable handles on.
- **Ctrl+C in the terminal ended the run instead of reaching the agent.**
  - Cause: the console sends Ctrl+C to every process attached to it, `agent-run --inner` included, and the default
    handler ends a process. `SetConsoleCtrlHandler(NULL, TRUE)` would protect the inner, but the agent would inherit
    that "ignore Ctrl+C" flag.
  - Fix: the inner installs a handler of its own that says Ctrl+C and Ctrl+Break are handled
    (`console::survive_ctrl_c`). A handler is not inherited, so the agent gets Ctrl+C as usual, and the inner lives to
    report its exit code.
  - How to verify: `ctrl_c_reaches_the_agent_and_the_run_reports_its_code`. Its control is a program without a
    handler, which Ctrl+C ends with `STATUS_CONTROL_C_EXIT`. With the inner's handler removed, the test gets
    `0xC000013A` instead of the agent's 42.
- **FACT: cmd.exe runs a program found in the current folder before `Path`.** Code mode's hooks run a bare `antenna`
  in the agent's folder, which is often a repository; an `antenna.cmd` there would run in place of Antenna's hook.
  cmd skips the current folder when `NoDefaultCurrentDirectoryInExePath` is set, to any value. PowerShell and Git Bash
  never look there. The agent's environment sets it, and its `Path` starts with Antenna's own folder
  (`windowsAgentEnvironment`, `agent_launch.dart`).
  - How to verify: `cmd_runs_antennas_hook_not_one_planted_in_the_folder` (`antenna-cli --test hook_signal`) and, with
    the launch the window builds and the real `antenna agent-run`, "a hook as Code mode writes it runs antenna from
    the Path" (`test/protocol/live_agent_run_windows_test.dart`, on Windows). Without the variable, both run the
    planted script instead.

## 2026-10-22 · The auto-update tests left an `antennad` running (`crates/antenna-cli/tests/auto_update.rs`; D-103)

- **Symptom.** After full workspace runs, orphaned daemons (parent PID 1) stayed on the build machine, one per run or
  so, with a command line like `/tmp/.tmpXXXXXX/prefix/bin/antennad --data-dir /tmp/.tmpXXXXXX/own … --update-quiet-ms
  1500 …` and the test's temporary folder already gone.
- **Cause.** The world of these tests ended only the daemon, by its data folder. The installer of an automatic update
  runs in its own process group (so that launchd does not take it down with a failing new daemon) and, when the
  daemon it waits for disappears, it puts the old files back and starts the old daemon again, detached
  (`restart_old`, `install/handover.rs`). Several tests stop as soon as the new version answers, while the installer
  is still polling; ending the daemon then looked to the installer like a new version that died, and the old one it
  started was nobody's child. Whether it leaked depended on timing: when the restart came after the end of the test,
  nothing killed it.
- **Fix.** `World::end` (also run from `Drop`, so a failing test is covered) kills by PID every process whose command
  line names a path in the world's own temporary folder: installers first, then daemons, then it reaps the nodes'
  children (a zombie still counts as running for the installer's `kill(pid, 0)` check), and repeats until two scans in
  a row find nothing. Matching on the world's unique temporary path, read from `/proc/<pid>/cmdline`, never touches
  another test's or a real node's processes; there is no `pkill -f` pattern.
- **How to verify.** `cargo test -p antenna-cli --test auto_update`:
  `a_test_that_ends_during_an_install_leaves_no_process_behind` delivers a release, waits until the `--handover`
  installer runs, ends the world while keeping its folder, and fails if any process of the folder shows up in the
  next 8 s. Negative control: with `end` reduced to the old "kill the daemon, reap the children", the test fails with
  the installer alive, and within the 8 s the installer starts `prefix/bin/antennad --data-dir …/own …`, the exact
  orphan seen on the machine. After the fix, three full runs of `auto_update` and one of `update` left no
  `/tmp/.tmp…` process and no new `antennad` (`pgrep -x antennad` before and after).

## 2026-10-22 · A build Mac without Homebrew, and the main branch's first full run on macOS 27 since preview.9 (`packaging/macos/build-dmg.sh`, the test harness)

The Mac (Apple Silicon, macOS 27.0.1, Xcode 27.1) has no Homebrew and no administrator rights for the build. Main at
3b1a16a, built and tested there end to end; no notarization, no release.

- **The tools `build-dmg.sh` needs, without Homebrew.** rustup in `~/.cargo` (`rust-toolchain.toml` picks 1.99.0),
  Flutter 3.47.6 in `~/flutter`; `protoc` and `cmake` from their official release archives (protobuf v36.2
  `protoc-36.2-osx-aarch_64.zip`, CMake 4.4.4 `cmake-4.4.4-macos-universal.tar.gz`) unpacked under `~/.local/opt` and
  linked into `~/.local/bin`. The build worked with protoc 36.2 and CMake 4.4.4, newer than the Linux ones (3.21,
  3.28).
- **CocoaPods does not install on the system Ruby.** Symptom: `gem install --user-install cocoapods` stops with
  "ffi requires Ruby version >= 3.0" (macOS 27 still ships Ruby 2.6.10). Fix: Homebrew's relocatable Ruby
  (`portable-ruby-3.4.5.arm64_big_sur.bottle.tar.gz` from Homebrew/homebrew-portable-ruby, no Homebrew needed) under
  `~/.local/opt/ruby-3.4.5`, then `gem install cocoapods` with it (1.17.0).
- **A symlink to `pod` runs the wrong Ruby.** RubyGems' `pod` is a shell stub that looks for `ruby` next to `$0`; called
  through a symlink in `~/.local/bin` it falls back to the `ruby` on PATH, the system 2.6. Use a two-line wrapper
  script (`exec "$HOME/.local/opt/ruby-3.4.5/bin/pod" "$@"`) instead of a symlink. Verify: `pod --version` from a
  shell without the portable Ruby on PATH.
- **`flutter pub get` with CocoaPods present edits two tracked files.** It adds `#include? "Pods/Target Support
  Files/Pods-Runner/Pods-Runner.{debug,release}.xcconfig"` to `macos/Flutter/Flutter-{Debug,Release}.xcconfig`. The
  build is fine either way (`#include?` is optional); do not commit the change from a build machine by accident.
- **Three Rust tests and two live window tests failed only on macOS** (782 core tests passed, 17 ignored):
  - `agent_view::a_label_with_spaces_gets_a_folder_a_shell_takes_as_one_word` compared a folder from the daemon
    (`/private/var/…`) with one built from the test's temporary folder (`/var/…`, a symlink there). Both sides are
    canonicalized now.
  - `local_routes::disconnect_stops_delivery` set a wake rule with `/bin/true`, which macOS does not have (the same
    trap as the 2026-10-05 entry above). It uses `common::true_bin()`.
  - Both tests of `live_agent_stop_test.dart` started a session leader with the `setsid` program, which macOS does not
    have (`ProcessException: No such file or directory`). On macOS the test starts it with
    `perl -MPOSIX -e 'POSIX::setsid() or die; exec @ARGV' sh -c …`, which keeps the PID as `setsid` does; Linux keeps
    `setsid`.
  - `file_kinds::save_folders_per_own_computer_and_per_agent` saved an agent's file to the contact's folder instead of
    the agent's once, in the full run under load (the Mac's load average was about 20); it passed 2 of 2 alone. Not
    fixed: watch it on the next runs before calling it a race.
  - Verify: `cargo test -p antenna-cli --test agent_view --test local_routes` and `flutter test --tags live
    test/protocol/live_agent_stop_test.dart` pass on the Mac and on Linux.
- **Window tests on macOS:** 917 passed, 5 skipped; the 326 golden failures are expected (the goldens are rendered on
  Linux, see "Golden tests on macOS" above). The live files: 45 passed, the 2 above failed before the fix.
- **The package:** `build-dmg.sh` made `Antenna-0.1.0-preview.9-macos-arm64.dmg` and the CLI archive in about 8
  minutes; `codesign --verify --deep --strict` on the mounted `Antenna.app` passes (ad-hoc signature). The Developer ID
  signature (the identity is in that Mac's keychain) and notarization are the next step.

## 2026-10-22 · Developer ID signing on a build Mac reached over ssh (`packaging/macos/{build-dmg,notarize}.sh`, D-105)

- **`codesign` fails with `errSecInternalComponent` over ssh although `security find-identity` lists the Developer ID.**
  The login keychain is locked in an ssh session even while the user is logged in at the screen: the unlocked keychain
  of the GUI session is not visible to the ssh session (`security show-keychain-info` says "User interaction is not
  allowed"), and nobody can answer the unlock dialog. Fix: unlock it in the same ssh command that signs,
  `security unlock-keychain -p "$(cat <a 0600 password file on the Mac>)" ~/Library/Keychains/login.keychain-db && …`;
  the password is read on the Mac and never printed or passed from the build host. Do not add
  `security set-keychain-settings -lut …`: it would make the keychain lock on sleep and after a timeout in the GUI
  session too. The notarytool keychain profile in the same keychain works after the same unlock. (A separate signing
  keychain with its own password, as CI systems use, was tried first and turned out unnecessary on a Mac whose login
  keychain can be unlocked this way.)
- **`codesign --force` drops the entitlements Xcode embedded.** Re-signing the app with a Developer ID passes
  `--entitlements Runner/Release.entitlements` explicitly; it now also has `com.apple.security.automation.apple-events`,
  because under the hardened runtime the window's osascript calls (restarting an AI app) are refused without a prompt.
- **Xcode signs the frameworks of a Flutter app ad hoc** (`CODE_SIGN_IDENTITY = "-"`). With a Developer ID every Mach-O
  in `Contents/Helpers` and `Contents/Frameworks` and every framework bundle is signed again, inside out, with
  `--options runtime --timestamp`; one Team ID everywhere lets library validation load Flutter.framework.
- **Stapling changes the .dmg**, so `notarize.sh` writes its `.sha256` again. The CLI archive's binaries are the same
  files as in the app: the .dmg's ticket covers them online (a bare Mach-O cannot hold a stapled ticket).
- **Checked end to end (0.1.0-preview.9, arm64, macOS 27.0.1, Xcode 27.1):** `build-dmg.sh` with `SIGN_IDENTITY`,
  then `notarize.sh`: notarization `Accepted` ("Ready for distribution", no issues), stapled, `stapler validate` OK;
  `spctl -a -vv -t install` on the .dmg and `spctl -t execute` on the app inside it say `source=Notarized Developer ID`;
  the app's entitlements are exactly `app-sandbox` (false) and `automation.apple-events`; the app opened from the
  mounted image and started its `antennad` under the hardened runtime.
- **A smoke run from a mounted image: stop `antennad` before detaching it.** The daemon outlives the window by design;
  after `hdiutil detach -force` its executable's pages are gone and it spins, ignoring SIGTERM (only SIGKILL by PID
  ends it). Quit the window, `kill` the daemon by PID, then detach.

## 2026-10-27 · Checking a long-running node after an upgrade: a scripted pairing with release binaries (`crates/antenna-cli/src/owner/pairing.rs`)

When the node's contacts are all offline, "messages still go" is checked with a throwaway node paired with it. Release
builds make this deliberately harder than the tests do:
- **`antenna invite --confirm` is refused** (`forbidden: --confirm is disabled … --allow-auto-confirm is for tests
  only`): only a test daemon confirms by itself. The inviting owner confirms in the invite's own dialog: with `--json`
  the invite prints `{"kind":"invite_created",…}`, `sas`, `waiting`, `peer_entered_code`, then `need_input`
  (`what: confirm`) and reads the answer, `yes` or the code that was read out, from its stdin; the final reply has
  `"type":"linked"`. Events carry `kind`, replies carry `type`. A separate `antenna pairing confirm <id>` returned 0 in
  our run, but the invite went on waiting for its own answer: answer in the dialog that asks.
- **A throwaway node needs a short data folder.** Its control socket is `<data-dir>/antennad.sock`, so a deep scratch
  folder breaks the socket length limit (see above): use `mktemp -d /tmp/…`.
- **Level 1 is relay only**, so one message each way also checks the node's path through the relay; `antenna send`
  returns once the message is delivered. Read the result with `antenna history <probe>`, not `antenna inbox`, which
  would mark other contacts' messages as read.
- **Clean up:** `antenna revoke <probe> --delete-history` on the node (the contact disappears from `antenna contacts`),
  then stop the throwaway daemon by PID and delete its folder.

## 2026-10-28 · A notarized app with one replaced helper never starts: its binaries wait at `_dyld_start` (`packaging/macos/check-update.sh`, macOS 27)

`check-update.sh` puts the debug `antenna` into a copy of the app, which then acts as "the installed version" (the
debug build trusts the test key and accepts failure injection). With the ad-hoc signed previews this worked. With the
Developer ID build and the hardened runtime (0.1.0-preview.10 on) it fails with "the daemon did not start", and the log
is empty. The daemon of that copy is alive but never runs a line of its own: `sample <pid>` shows only `_dyld_start`,
and `codesign --verify --deep --strict` on the copy says "nested code is modified or invalid". The kernel holds every
binary of a bundle whose seal is broken, even ones that were not touched, with no message on the terminal and no end.
The same copy without the replaced helper starts in seconds.
- **Fix:** sign the throwaway copy again, as a whole and ad hoc, after replacing the helper (`codesign --force --deep
  --sign -`). The new version from the `.dmg` keeps its Developer ID signature, and the installer checks that one.
- **Not a product issue.** `antenna update` replaces the whole bundle (`renamex_np` swap) and never edits a signed one.
  Nothing else in Antenna writes into `Antenna.app` either: the terminal command is a symlink outside the bundle.
- **A related trap over ssh:** `Antenna.app/Contents/MacOS/antenna --version` does not print a version. On the
  case-insensitive file system it is the window's executable (`Antenna`), so over ssh the window starts with no
  screen, never exits, and starts a daemon. The CLI is `Contents/Helpers/antenna`.
- The first start of a notarized binary from a new path can take several seconds while the system assesses it, so
  the script waits up to a minute for the socket.
- **`ps -axo pid=,comm= | grep -q …` under `set -o pipefail`** failed while the path was there. `grep -q` exits at
  the first match, `ps` (a long list on a busy Mac) gets SIGPIPE, and pipefail reports the pipeline as failed. The
  script now reads the list into a variable first. The installer reads `ps` output in full in Rust and is not
  affected.
- **First full run on a real Mac (2026-10-28):** macOS 27, the notarized `Antenna-0.1.0-preview.11-macos-arm64.dmg`,
  EXIT 0. It covered the mount, the copy, `codesign --verify --deep --strict`, the swap with `.previous`, the restore
  after an error at `swap1`, the rollback, and the recovery after a crash.

## 2026-10-31 · `antenna login` in a script, then the last command says `login_required` (`crates/antenna-core/src/control/auth.rs`)

- **Symptom.** A script without a terminal runs `antenna login --password-stdin`, then a few owner commands; the
  middle ones work, the last one fails with `login_required: no owner session`. Over `ssh host 'a; b; c'` the same.
  Inside `( … )` with `echo pw | antenna login` the session seems not to open at all.
- **Cause.** Without a terminal the owner session belongs to the CLI's parent process ("this parent process"; D-46,
  CONTROL §3: by PID and start time, like `sudo` with `timestamp_type=ppid`), not to the script as a whole.
  `bash -c 'a; b; c'` runs its last simple command with `exec`, so `c`'s parent is whatever started bash (sshd, the CI
  runner), not the shell that ran `login`. A pipeline `echo pw | antenna login` inside a subshell runs `antenna` in yet
  another forked shell. Each of those is a different parent, with no session.
- **Fix.** In a terminal nothing is needed: the session belongs to the terminal. In scripts, give each owner command
  the password itself where it takes one (`--password-stdin`), or keep the commands in one long-lived shell, feed the
  password with a here-string (`antenna login --password-stdin <<< "$PW"`, no pipeline fork) and end the script with
  a command that is not an owner command (`true`), so bash cannot `exec` the last one.
- **Not a weakness to fix by widening the session.** Binding it to the exact parent keeps another process of the same
  user from borrowing an owner session it did not open.
