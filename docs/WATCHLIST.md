# WATCHLIST — "Waiting for"

Technologies the project lacks that, as of 2026-10-02, are not publicly available or are immature.
Why: not to invent what is about to ship, and not to wait for what nobody is building.

**How to maintain.**
- Once a week: `python3 tools/watchlist_check.py`. It polls the machine-checkable sources from `docs/watchlist.json`
  (crates.io, GitHub, IETF datatracker, text markers on pages) and prints what changed. No LLM needed.
  Exit code 1 = there are changes: open the item below, recheck it by hand, update the status and date.
  After the review: `python3 tools/watchlist_check.py --update`.
- Once a month: the non-machine items (marked "manual"). They are checked by hand.
- Every status comes with a date and a link to a page that was actually opened. A search snippet is not a source.
- An item triggers ("adopt") → a decision in `docs/DECISIONS.md`, the item here moves to "Closed".

Current schedule: the list is checked twice a week (Mondays and Thursdays) by `tools/watchlist_check.py`, plus a manual
web review of the non-machine items on Mondays. Each check is logged; an entry that meets an
"adopt when…" condition or is otherwise significant is marked `ATTENTION MAINTAINER:`.

Last full check: **2026-10-26**. Last machine check: **2026-10-26**. Machine checks: 48, errors: 0.

## Summary

| # | What we wait for | SPEC | How we cover it now | Adopt when… | Frequency |
| --- | --- | --- | --- | --- | --- |
| W-01 | A `libcrux-ml-kem` release > 0.0.10 with the `incremental`+`rand` fix; X-Wing (`libcrux-kem`) next to SPQR | §6 item 4, §14; Q-2 (II), D-9 | Hybrid from TLS 1.3 `X25519MLKEM768` (Q-2 I) | a release on crates.io **and** `spikes/combined` option B builds without `[patch]` | week (script) |
| W-02 | X-Wing as an RFC | §6, §7 | Not needed with Q-2 I | the RFC is out and the maintainer wants option II | month (script) |
| W-03 | `iroh-blobs` 1.x | §10, §14 | `iroh-blobs 0.103` pinned, fallback `bao-tree` | 1.0 on crates.io or the "not production quality" warning removed | week (script) |
| W-04 | iroh Tor transport on Arti, mature Arti onion services | §4 (Tor mode, v0.3) | "Relay only" mode | Arti onion services without the "testing only" caveat **and** a transport without an external `tor` | month (script) |
| W-05 | libsignal: support outside Signal / crates.io; stable ML-KEM-1024 in PQXDH; full verification of SPQR | §7, §14, §16; D-4, D-8, Q-3 | git rev, `MLKEM1024`, the SPEC wording refined | the ML-KEM caveat removed; `lax` = 0; a publication appeared | week (script) |
| W-06 | QUIC Multipath and NAT Traversal as RFCs | §4 | iroh 1.3's own implementation (`noq`) | Multipath — RFC (soon); NAT Traversal — not even a WG draft | month (script) |
| W-07 | PQ transport authentication (ML-DSA in TLS 1.3, PQ identity in iroh) | §4, §5, §7 | PQ signature of the link-root (Ed25519 + ML-DSA-65) under SAS at the application layer | an iroh major with PQ identity or the CRQC threat has come closer | month (script + manual) |
| W-08 | An audited PQ PAKE for spoken codes | §6 (alternative), §14 | The code only authenticates; keys come from PQ TLS; the code is one-time | CFRG adopted a PQ PAKE **and** there is an audited Rust implementation | month (script) |
| W-09 | MLS with PQ suites | §7 (groups in v2), §17 | No groups until v1.0 | an RFC for the PQ suites and a stable feature in openmls | month (script) |
| W-10 | Claude Code Channels → GA, our own channel without a dev flag | §11, §17 (v0.2) | `wait_for_message` (long-poll), hooks | GA **and** our own MCP server is accepted by `--channels` without the Anthropic allowlist | week (script) |
| W-11 | A2A 1.x and the official Rust SDK | §11 (v0.3) | — (A2A in v0.3) | `a2a-lf` ≥ 1.0 by the start of v0.3 | month (script) |
| W-12 | Trust/sensitivity labels in MCP (SEP-1913) | §9, §11 | The "external data, not instructions" wrapper in the text | SEP accepted → we put labels on contact data | month (script) |
| W-13 | `biscuit-auth` with ed25519-dalek 3 | §9, §14 | `biscuit-auth 6.0.0` + PoP third-party block (D-11) | a release with ed25519-dalek 3 is out | week (script) |
| W-14 | An open embeddable CDR (disarming PDF/Office/images) | §10, §19 | Our own assembly of known parts | Dangerzone gets a library/headless mode, or another open CDR appears | month (script + manual) |
| W-15 | vTPM on a VPS (Hetzner) | §5, §8, §13; Q-4 | Password + Argon2id, `x unlock` | the target VPS has a vTPM | quarter (script) |
| W-16 | Usable IFC implementations for LLM agents (CaMeL, FIDES…) | §9 | Session-level taint in the daemon | a maintained library with a label format compatible with MCP | month (manual) |
| W-17 | Post-quantum deniable authentication | §8 (deniable history) | MAC on the shared link key (messages are deniable) | an audited PQ-deniable AKE implementation | quarter (manual) |
| W-18 | iroh mobile bindings (Flutter) | §14 (v1.x) | — | needed by v1.x; more likely our own Rust core via FFI | quarter (script) |
| W-19 | A standard hybrid signature format; `libcrux-ml-dsa` ≥ 0.1 | §5, §7, §8 | Two signatures side by side (Ed25519 + ML-DSA-65) | RFC composite-sigs; libcrux-ml-dsa leaves 0.0.x | month (script) |
| W-20 | IETF standards for agents (agentproto, dmsc, dawn, wimse) | §9, §11 | — | a WG is chartered and covers cross-owner authorization | month (script) |
| W-21 | Audited anonymous credentials in Rust: an audit of `privacypass` (RFC 9576/9578) or a public audit of `zkgroup` from libsignal | MAILBOX §6 (Cloud anti-spam, anonymous tokens) | Write capability for the mailbox + adaptive PoW + quotas (MAILBOX) | An independent audit of a Rust implementation is published | month (script + manual) |
| W-22 | File inputs for MCP tools (the experimental `io.modelcontextprotocol/files` extension, successor of SEP-2631; SEP-2356 `inputFiles` closed) | §10, §11 | `share_file_content`: base64 in a tool argument (D-87); `share_file` with a path for local agents | a SEP (or the files extension) is accepted and the apps (ChatGPT, Claude, Cursor…) pass files to local servers | month (manual) |
| W-23 | Flutter on macOS: flags-only Cmd+V and accessibility text input reach the text field (flutter/flutter#184571, PR #190539; #191503); an `xterm` release that parses colon SGR parameters and `CSI > … m` | — (window) | A paste bridge in the macOS Runner (D-UI-22); an SGR filter in front of `xterm` 4.0.0 (TROUBLESHOOTING "Code mode terminal: underlined lines") | the fix ships in a stable Flutter we pin → remove the paste part of the bridge; an `xterm` release (or the maintainer accepts the `xterm2` fork) → remove the filter | month (manual) |
| W-24 | Claude Code channels open to third-party MCP servers (`claude/channel` capability, `--channels`) | — (window, Code mode) | The window types built-in lines into an idle agent's terminal (D-UI-23) | a user can enable a third-party server's channel without the vendor's allowlist or the `--dangerously-…` flag → `antenna mcp` pushes "new messages" through the channel and the typed wake for Claude Code goes | month (manual) |

---

## Items

### W-01 · libcrux-ml-kem > 0.0.10 and X-Wing next to SPQR
- **Why.** SPEC §6 item 4: hybrid X25519 + ML-KEM-768 at pairing. DECISIONS Q-2 option II: an additional X-Wing inside the channel on top of TLS.
- **Status 2026-10-02.**
  - The build fix for the `incremental` and `rand` features enabled together was **merged into main** on 2026-09-10 (PR #1584 "Fallible rng"). In the `libcrux-ml-kem` CHANGELOG it is under `[Unreleased]`: "Fixed a pre-existing build failure when combining the `incremental` and `rand` features" — [CHANGELOG](https://github.com/celabshq/libcrux/blob/main/libcrux-ml-kem/CHANGELOG.md), [PR #1584](https://github.com/celabshq/libcrux/pull/1584).
  - The same PR breaks the API: `incremental::KeyPairCompressedBytes::generate` now returns a `Result`. SPQR will have to change its code when it upgrades.
  - On crates.io: `libcrux-ml-kem 0.0.10` (2026-07-15), `libcrux-kem 0.0.9` (2026-07-15) — [crates.io API](https://crates.io/api/v1/crates/libcrux-ml-kem).
  - SPQR v1.6.0 requires `libcrux-ml-kem = "0.0.10"` (for 0.0.x this means exactly 0.0.10) — [Cargo.toml](https://github.com/signalapp/SparsePostQuantumRatchet/blob/main/Cargo.toml).
  - The libcrux repository moved: `cryspen/libcrux` → `celabshq/libcrux`. CE Labs is a Cryspen spin-off since 2026-06-25, led by Franziskus Kiefer — [Cryspen announcement](https://cryspen.com/post/announcing-ce-labs/).
- **Update 2026-10-08.** Released: `libcrux-ml-kem 0.0.11` and `libcrux-kem 0.0.10` (both 2026-10-07). The 0.0.11
  CHANGELOG lists the fix ("Fixed a pre-existing build failure when combining the `incremental` and `rand` features")
  and the breaking RNG changes of PR #1584 (`mlkem768::rand::*` and `incremental::KeyPairCompressedBytes::generate` now
  return `Result`) — [CHANGELOG](https://github.com/celabshq/libcrux/blob/main/libcrux-ml-kem/CHANGELOG.md).
  `libcrux-kem 0.0.10` requires `libcrux-ml-kem =0.0.11` ([crates.io deps](https://crates.io/api/v1/crates/libcrux-kem/0.0.10/dependencies));
  SPQR main still requires `libcrux-ml-kem = "0.0.10"` ([Cargo.toml](https://github.com/signalapp/SparsePostQuantumRatchet/blob/main/Cargo.toml)),
  and so does libsignal v0.105.0.
  **Measured:** a scratch copy of `spikes/combined` with `libcrux-kem = "=0.0.10"` and no `[patch.crates-io]` builds
  with `--features xwing` (`Finished dev profile … in 1m 49s`, Rust 1.99.0, Linux x86_64) and runs: `xwing pk 1216B`,
  the ML-DSA-65 checks pass. As predicted below, the tree holds two of each libcrux crate (`libcrux-ml-kem` 0.0.10 for
  SPQR and 0.0.11 for `libcrux-kem`; likewise `sha3`, `sha2`, `traits`, `secrets`, `intrinsics`, `platform`,
  `hacl-rs`, `macros`). The spike's own X-Wing code needed no change. Two of the three conditions are met; the third
  (the maintainer wants option II) is a decision, not a release.
- **Subtlety.** When `libcrux-kem` ships on `libcrux-ml-kem 0.0.11` while SPQR stays on 0.0.10, Cargo will take both versions. There will be no feature conflict, but the binary will contain two libcrux-ml-kem. It becomes clean only when SPQR upgrades.
- **How we cover it.** TLS 1.3 `X25519MLKEM768` (aws-lc-rs) — maintainer decision Q-2 I. This group is now RFC 10024 (W-02).
- **Adopt when:** a new version on crates.io **and** `spikes/combined` option B builds without `[patch.crates-io]` **and** the maintainer wants option II.
- **Where to check:** crates.io API `libcrux-ml-kem`, `libcrux-kem`; the version marker in SPQR's `Cargo.toml`; SPQR tags. Script: `w01-*`.
- **Frequency:** week.

### W-02 · X-Wing in the IETF
- **Status 2026-10-02.**
  - `draft-connolly-cfrg-xwing-kem-11` (2026-09-23) goes **not through CFRG but through the Independent Submission stream**. ISE state: "Submission Received", no RFC status assigned — [datatracker](https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/).
  - The general CFRG combiners `draft-irtf-cfrg-hybrid-kems-12` are waiting for a shepherd.
  - The hybrid for TLS 1.3 is already a standard: **RFC 10024** "Post-Quantum Traditional (PQ/T) Hybrid Key Agreement Mechanisms for TLS 1.3" (X25519MLKEM768 and others) — [rfc-editor](https://www.rfc-editor.org/info/rfc10024). Our transport relies on an RFC, not on a draft.
- **How we cover it / adopt when:** as W-01. X-Wing is needed only for option II.
- **Where:** datatracker API. Script: `w02-*`. **Frequency:** month.

### W-03 · iroh-blobs 1.x
- **Status 2026-10-02.**
  - `iroh-blobs 0.103.0` (2026-06-15) — [crates.io](https://crates.io/api/v1/crates/iroh-blobs).
  - README: "this version of iroh-blobs is **not yet considered production quality**. For now, if you need production quality, use iroh-blobs 0.35" — [README](https://github.com/n0-computer/iroh-blobs/blob/main/README.md).
  - 0.35 does not suit us. `iroh-blobs 0.35.0` (2025-05-12) requires `iroh ^0.35`, not iroh 1.x ([crates.io deps](https://crates.io/api/v1/crates/iroh-blobs/0.35.0/dependencies)). n0's public relays keep 0.35 only until 2026-12-31 ([iroh 1.0](https://www.iroh.computer/blog/v1)).
  - The iroh 1.0 announcement gives no date for iroh-blobs 1.0.
- **Update 2026-10-08.** `iroh-blobs 0.103.1` (2026-10-06), still 0.x; the README warning is still present (script
  marker `w03-iroh-blobs-readme`). The release fixes the `EventMask` pitfall we work around in `antenna-files`
  (TROUBLESHOOTING, "iroh-blobs 0.103"): `EventSender::request` matched every request kind on `mask.get`, so with
  `EventMask::DEFAULT` "any peer that could connect to a provider with the default config could write blobs into its
  store"; each kind now uses its own mode — [PR #270](https://github.com/n0-computer/iroh-blobs/pull/270),
  [CHANGELOG](https://github.com/n0-computer/iroh-blobs/blob/main/CHANGELOG.md). Our mask sets every mode explicitly
  and rejects everything but an allowed `get`, so the fix changes nothing for us functionally; moving the pin to
  `=0.103.1` adds the library-level refusal of push under our own check. The "adopt when" condition is not met.
- **Update 2026-10-29.** `iroh-blobs 0.104.0` (2026-10-28), still 0.x: robustness fixes in the fs store, the
  API and the protocol (non-canonical `RangeSpecSeq` rejected, invalid hashes no longer panic, truncated export streams
  detected), lazy hash-seq reads, `Downloader::builder` with a custom ALPN; breaking: `Hash::fmt_short` returns
  `impl Display`, `bao-tree` 0.17, `iroh-util` 0.7; lockfile updates for RUSTSEC-2026-0346…0348, -0381…0383,
  -0385, -0386 ([compare](https://github.com/n0-computer/iroh-blobs/compare/v0.103.1...v0.104.0)). Not met.
- **Takeaway for STACK.** The authors themselves do not consider 0.103 production quality. This is a bigger risk than "0.x, the API may break". The fallback `bao-tree` over our own stream (STACK b) is worth keeping alive.
- **How we cover it:** `=0.103.0` (D-4), we transfer STREAM ciphertext, BLAKE3/bao verification.
- **Adopt when:** 1.0 on crates.io or the warning disappears from the README.
- **Where:** crates.io; the README marker. Script: `w03-*`. **Frequency:** week.

### W-04 · Tor: iroh-tor-transport and Arti onion services
- **Status 2026-10-02.**
  - `iroh-tor-transport 0.1.0` (2026-06-15), repository `n0-computer/iroh-tor-transport` marked "Experimental" — [README](https://github.com/n0-computer/iroh-tor-transport).
  - The transport goes through an **external C tor daemon** over the control port, cookie authentication is off. Arti — only "in the future" — [n0 blog, 2026-01-27](https://www.iroh.computer/blog/tor-custom-transport).
  - Arti 2.7.0 (2026-10-01): vulnerabilities from low to high fixed, those running onion services are advised to upgrade immediately — [Tor blog](https://blog.torproject.org/arti_2_7_0_released/).
  - The Arti README: a full-featured client, "can run and connect to onion services".
  - But `doc/OnionService.md`: "**suitable for testing and experimentation only** … may even compromise the privacy of your other uses of the same Arti instance" — [GitLab](https://gitlab.torproject.org/tpo/core/arti/-/blob/main/doc/OnionService.md).
- **How we cover it:** Tor mode — v0.3. Until then, "relay only" for levels 1–2.
- **Adopt when:** the "testing only" caveat is removed from Arti onion services **and** there is an iroh transport over Arti (from n0 or our own custom-transport adapter, which needs a separate review).
- **Where:** crates.io `iroh-tor-transport`, `arti-client`; the marker in OnionService.md. Script: `w04-*`. **Frequency:** month (Arti ships monthly).

### W-05 · libsignal: publication, ML-KEM-1024, completeness of SPQR verification
- **Status 2026-10-02.**
  - libsignal v0.103.1 (2026-09-22). README: "Use outside of Signal is unsupported" — [README](https://github.com/signalapp/libsignal).
  - The name `libsignal-protocol` on crates.io is taken by a third-party crate 0.1.0 from 2019 (Michael-F-Bryan). Signal does not publish there.
  - `rust/protocol/Cargo.toml`: "ML-KEM matches the NIST standard version of Kyber. It may still change incompatibly until the final version of the standard is published" — [Cargo.toml](https://github.com/signalapp/libsignal/blob/main/rust/protocol/Cargo.toml). The caveat is outdated: FIPS 203 was published on 2024-08-13 ([NIST](https://csrc.nist.gov/pubs/fips/203/final)). But the `mlkem1024` feature is still separate, and Signal's default is Kyber1024.
  - SPQR v1.6.0 (tag 2026-09-16). Exactly one function is marked `verification_status(lax)`: the top-level `send` in `src/lib.rs`. Another 14 items are `hax_lib::opaque`, i.e. their bodies are not verified: `kdf.rs`, `incremental_mlkem768.rs`, `chain.rs`, `encoding/polynomial.rs` (counted in the sources of tag v1.6.0). ProVerif models exist for ML-KEM Braid and the symmetric ratchet — [SPQR README](https://github.com/signalapp/SparsePostQuantumRatchet).
- **Update 2026-10-08.** libsignal v0.104.0 (2026-10-02) and v0.105.0 (2026-10-07). v0.105.0 touches no file under
  `rust/protocol` (net, bridge and client API changes only); the workspace still pins `libcrux-ml-kem` 0.0.10 and SPQR
  tag v1.6.0, and the ML-KEM caveat is still in `rust/protocol/Cargo.toml`; `lax` count still 1 —
  [compare v0.104.0…v0.105.0](https://github.com/signalapp/libsignal/compare/v0.104.0...v0.105.0),
  [RELEASE_NOTES](https://github.com/signalapp/libsignal/blob/v0.105.0/RELEASE_NOTES.md). Not met.
- **Update 2026-10-19.** libsignal v0.105.1 (2026-10-15): zkcredential presentation simplification, new typed
  donation and entitlement APIs, a flattened backup proto, and a rustls bump to 0.23.46
  ([release](https://github.com/signalapp/libsignal/releases/tag/v0.105.1)). The workspace still pins `libcrux-ml-kem`
  0.0.10 and SPQR tag v1.6.0 ([Cargo.toml](https://github.com/signalapp/libsignal/blob/v0.105.1/Cargo.toml)); the
  ML-KEM caveat is still in `rust/protocol/Cargo.toml`. GitHub did not render the file diff, so whether a file under
  `rust/protocol` changed is not verified; no commit title targets it. Not met.
- **Update 2026-10-22.** libsignal v0.105.2–v0.105.4 (2026-10-20…22): no release notes; the commits are
  `Accounts.getCapabilities`, SVR2 cleanup, a rustls-webpki and webpki-root-certs update and distrust of compromised
  weak intermediate certificates; no file under `rust/protocol` changed
  ([compare](https://github.com/signalapp/libsignal/compare/v0.105.1...v0.105.4)). Still `libcrux-ml-kem` 0.0.10 and
  SPQR v1.6.0 ([Cargo.toml](https://github.com/signalapp/libsignal/blob/v0.105.4/Cargo.toml)); the ML-KEM caveat stays
  in `rust/protocol/Cargo.toml`. Not met.
- **Update 2026-10-26.** libsignal v0.106.0 (2026-10-23), no release notes. It adds the **Tahini** session
  management protocol (commit "Tahini session management protocol", 2026-10-22): sessions are kept as one active and
  one inactive, and an active session is archived after 5 missed chances to run the DH ratchet; a Tamarin analysis of
  post-compromise security ships in `rust/protocol/models/tahini/`. Many files under `rust/protocol` changed (`session.rs`,
  `state/session.rs`, `session_management.rs`, the new `tahini.rs`); the public API drops `process_prekey` and adds
  `initiate_session` and `PreKeyDecryptResult`, while `process_prekey_bundle`, `message_encrypt` and `message_decrypt`
  (all we call) stay ([compare](https://github.com/signalapp/libsignal/compare/v0.105.4...v0.106.0),
  [Tahini models](https://github.com/signalapp/libsignal/tree/v0.106.0/rust/protocol/models/tahini)). Still
  `libcrux-ml-kem` 0.0.10 and SPQR v1.6.0 ([Cargo.toml](https://github.com/signalapp/libsignal/blob/v0.106.0/Cargo.toml)),
  the ML-KEM caveat stays, `lax` = 1. **Measured:** a scratch copy of `spikes/libsignal-tr` on tag v0.106.0 builds
  without code changes and passes (PQXDH with `MLKEM1024`, SPQR negotiation complete, five SPQR epochs over 400
  messages, restore, replay and tamper rejected, a non-pinned identity rejected; release build, Rust 1.99.0, Linux
  x86_64). We pin v0.103.1; when we move past v0.106.0, check how Tahini's archiving interacts with our one session per
  link. Not met.
- **Update 2026-10-29.** libsignal v0.106.1 (2026-10-28); release notes only about Swift Package Manager. Under
  `rust/protocol` only refactors (let-chains in `state/session.rs`, `as_chunks` in `fingerprint.rs`, edition and
  `rust-version` 1.93.1 from the workspace); no API change. Still `libcrux-ml-kem` 0.0.10 and SPQR v1.6.0
  ([compare](https://github.com/signalapp/libsignal/compare/v0.106.0...v0.106.1)); `lax` = 1. Spike not rerun (no
  protocol change since v0.106.0, which passed). Not met.
- **How we cover it:** git rev (D-4, Q-3a), `MLKEM1024` (D-8), the refined wording about verification (DECISIONS, deviations from §14).
- **Adopt when:** the ML-KEM caveat is removed; `lax` = 0; Signal publishes the crates. There are no signs of the latter — do not wait, revisit decision Q-3 before v1.0.
- **Where:** GitHub releases of libsignal, markers in `Cargo.toml` and `src/lib.rs`. Script: `w05-*`, `w01-spqr-tag`. **Frequency:** week.

### W-06 · QUIC Multipath and NAT Traversal in the IETF
- **Status 2026-10-02.**
  - `draft-ietf-quic-multipath-21`: Proposed Standard, sent to the IESG, at the RFC Editor "In Progress (First Edit)". An RFC is likely in the coming months — [datatracker](https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/).
  - **NAT Traversal: there is no working group draft.** There is the individual `draft-bruynooghe-n0-quic-nat-traversal-00` (2026-07-06, n0): "A description of how noq performs NAT traversal for iroh, including all current bugs. This is not yet a specification" — [datatracker](https://datatracker.ietf.org/doc/draft-bruynooghe-n0-quic-nat-traversal/).
  - The QUIC WG has only `draft-ietf-quic-address-discovery-01` (WG Document). The earlier `draft-seemann-quic-nat-traversal` expired in 2024.
  - iroh 1.0 (2026-06-15) contains its own multipath and NAT traversal in `noq` — [iroh 1.0](https://www.iroh.computer/blog/v1).
- **Correction to SPEC §4.** "QUIC-NAT-Traversal (an emerging IETF standard)" is an individual n0 draft, neither a standard nor a WG draft.
- **Update 2026-10-22.** `draft-ietf-quic-multipath-21`: RFC Editor state "Blocked", RPC status "Final Approval
  Pending" since 2026-10-19 (after "In Final Review" on 2026-10-16) — the last step before publication, not a new
  blocker on content ([history](https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/history/)). iroh 1.4.0
  (2026-10-20): rustls bump for RUSTSEC-2026-0346…0349, an `X-Iroh-Endpoint-Id` relay header, immediate address
  updates on relay-less local networks, bounded path queues; 1.4.1 (2026-10-22): rustls-webpki update, test timeouts
  ([1.4.0](https://github.com/n0-computer/iroh/releases/tag/v1.4.0),
  [1.4.1](https://github.com/n0-computer/iroh/releases/tag/v1.4.1)). Nothing on PQ identity. Our `Cargo.lock` pins
  iroh 1.3.0 and rustls 0.23.45. Not met.
- **Update 2026-10-27.** iroh 1.4.1 adopted (iroh-relay 1.4.1, noq 1.4.0), with rustls 0.23.46, rustls-webpki 0.103.16
  and webpki-roots/webpki-root-certs 1.0.11: RUSTSEC-2026-0346…0349 and 0381…0383 no longer match our `Cargo.lock`.
  No code changes were needed. The condition is unchanged: not met.
- **How we cover it:** iroh 1.4 (spike a was on 1.3).
- **Adopt when:** there is nothing to adopt. When the Multipath RFC is out, check that `noq` follows the final text.
- **Where:** datatracker API. Script: `w06-*`. **Frequency:** month.

### W-07 · PQ transport authentication
- **Status 2026-10-02.**
  - iroh identity is Ed25519 only. n0's position (Floris Bruynooghe, 2026-09-15): "we are preferring to not build in crypto-agility … stay on ed25519 for identity until it is realistic that it is broken … a new major version would need to be released" — [discussion #4532](https://github.com/n0-computer/iroh/discussions/4532).
  - An experimental Cachix PR with ML-DSA-65 identity ([#4534](https://github.com/n0-computer/iroh/pull/4534)) was closed without merging on 2026-09-15.
  - rustls 0.23.44+ enabled ML-DSA by default in the aws-lc-rs provider ([PR #3249](https://github.com/rustls/rustls/pull/3249), 2026-09-07). The current version is 0.23.45.
  - `draft-ietf-tls-mldsa-06` is in the RFC Editor queue, state "blocked". ML-DSA in X.509 — RFC 9881.
  - Update 2026-10-08: `draft-ietf-tls-mldsa-06` is no longer blocked; RFC Editor status "Awaiting Editor Assignment"
    (datatracker, last updated 2026-10-05) — [datatracker](https://datatracker.ietf.org/doc/draft-ietf-tls-mldsa/).
    Not an RFC yet; it does not change the condition (iroh identity).
  - Update 2026-10-12: the discussion is still open; n0 (2026-09-16) says a long-term PQ identity "belongs" in the
    authentication layer above iroh, and (2026-09-20) suggests to "sign that ed25519 key with the PQ identity and send
    that over as a handshake in the first stream" — the shape of our link-root signature. iroh 1.1–1.3 release notes
    say nothing on PQ identity. Condition not met; our application-layer approach is the one upstream recommends.
  - Update 2026-10-15: rustls 0.23.46 (2026-10-14) is a security release; nothing on PQ signatures or raw public keys
    in the notes — [release](https://github.com/rustls/rustls/releases/tag/v%2F0.23.46). Relevant to our TLS hybrid:
    [GHSA-w44r-93j7-qv28](https://github.com/rustls/rustls/security/advisories/GHSA-w44r-93j7-qv28) (low, CVSS 3.7,
    all versions below 0.23.46): with resumption enabled, an unauthenticated ServerHello can make later ClientHellos
    to the same name carry only an X25519 share; if the server accepts it instead of sending a HelloRetryRequest, the
    handshake is classical only, with no error. Our `Cargo.lock` pins 0.23.45. Condition not met (no PQ identity).
  - Cloudflare plans full PQ, including authentication, by 2029 — [blog, 2026-07-09](https://blog.cloudflare.com/ml-dsa-will-have-to-do/).
- **How we cover it.** Authentication is not retroactive: "harvest now, decrypt later" does not apply to it. Apple reasons the same way in PQ3 ([Apple](https://security.apple.com/blog/imessage-pq3/)). We have a PQ signature of the link-root (Ed25519 + ML-DSA-65) pinned by SAS; confidentiality — the TLS hybrid + SPQR.
- **Adopt when:** iroh ships a major with PQ identity or a reliable estimate of a near CRQC appears. Until then, do not expect it from n0.
- **Where:** crates.io `iroh`, `rustls`; datatracker; discussion #4532 — manually. **Frequency:** month.

### W-08 · PQ PAKE for spoken codes
- **Status 2026-10-02.**
  - Classical: CPace `draft-irtf-cfrg-cpace-21` sent to the RFC Editor ([datatracker](https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/)); SPAKE2 — RFC 9382.
  - PQ: `draft-vos-cfrg-pqpake-02` (2026-07-06; Vos, Wood — Apple; Jarecki — UC Irvine). Hybrids CPaceOQUAKE / CPaceOQUAKE+ on ML-KEM. Individual, not adopted by CFRG — [datatracker](https://datatracker.ietf.org/doc/draft-vos-cfrg-pqpake/).
  - Meta `pake-kem 0.1.0-pre.7`: "has not been audited", "This is NOT a post-quantum PAKE … appropriate if … one-time-use passwords" — [README](https://github.com/facebook/pake-kem).
  - CPaceOQUAKE implementations on GitHub — a handful, without stars or audits (search of 2026-10-02).
  - Update 2026-10-15: `draft-vos-cfrg-pqpake-03` (dated 2026-10-13, datatracker updated 2026-10-14); still an
    individual draft, not adopted by CFRG, intended status Informational; no implementations named on the page —
    [datatracker](https://datatracker.ietf.org/doc/draft-vos-cfrg-pqpake/). Condition not met.
- **How we cover it.** In the SPEC scheme the code only authenticates the meeting, the keys then come from TLS `X25519MLKEM768` + SAS (steps 4–11). A passive quantum adversary can brute-force from a recording only the one-time, already burned code. The remaining risk is only an active quantum MITM in real time.
- **Adopt when:** CFRG adopted a PQ PAKE (a `draft-irtf-…` draft) **and** there is an audited Rust implementation. Until then — CPace per the RFC.
- **Where:** datatracker, crates.io `pake-kem`. Script: `w08-*`. **Frequency:** month.

### W-09 · MLS with PQ suites (groups in v2)
- **Status 2026-10-02.**
  - `draft-ietf-mls-pq-ciphersuites-06` (2026-10-01) — in **WG Last Call**. `draft-ietf-mls-combiner-02` has expired and is waiting for the chair.
  - openmls 0.9.0 (2026-08-25): "Added P-384, ML-DSA and additional PQ ciphersuites (including the draft-ietf-mls-pq-ciphersuites draft v5 code points), behind the `draft-ietf-mls-pq-ciphersuites` feature flag"; X-Wing — an experimental suite — [CHANGELOG](https://github.com/openmls/openmls/blob/main/CHANGELOG.md).
  - `mls-rs 0.56.0` (AWS) with the PQ feature `mls-rs-crypto-awslc` — used by AGNTCY SLIM.
  - Update 2026-10-08: openmls 0.9.1 (2026-10-07) is a security fix only ("Unbounded recursion while decoding invalid
    nested extensions can abort the process", GHSA-gc79-23g3-8g52, plus GREASE handling); PQ suites still behind the
    `draft-ietf-mls-pq-ciphersuites` feature — [CHANGELOG at v0.9.1](https://github.com/openmls/openmls/blob/v0.9.1/CHANGELOG.md).
    Not met.
  - Update 2026-10-22: `draft-ietf-mls-pq-ciphersuites-06` left WG Last Call: on 2026-10-19 "Submitted to IESG for
    Publication", IESG state "Publication Requested", shepherd write-up filed
    ([history](https://datatracker.ietf.org/doc/draft-ietf-mls-pq-ciphersuites/history/)). Not an RFC yet. Not met.
  - Update 2026-10-26: openmls 0.9.2 (2026-10-22) is security fixes only (GHSA-p276-g3f3-wwgh, rejected private
    messages advancing the sender ratchet; GHSA-94v4-rg25-x625, removed leaves reappearing after an external commit);
    PQ suites still behind the feature flag — [CHANGELOG at v0.9.2](https://github.com/openmls/openmls/blob/v0.9.2/CHANGELOG.md).
    Not met.
  - Update 2026-10-29: `mls-rs 0.57.0` (2026-10-28): `MlsMessage::from_bytes` rejects trailing data, a `roster()`
    accessor on `GroupState`, dependency updates, `mls-rs-codec` 0.7.1; nothing on PQ suites or an audit
    ([commits](https://github.com/awslabs/mls-rs/commits/main)). Not met.
- **How we cover it:** no groups until v1.0.
- **Adopt when:** an RFC for the PQ suites and a stable openmls feature.
- **Where:** datatracker, crates.io. Script: `w09-*`. **Frequency:** month.

### W-10 · Claude Code Channels and MCP revisions
- **Status 2026-10-02** ([Channels](https://code.claude.com/docs/en/channels), [MCP in Claude Code](https://code.claude.com/docs/en/mcp), [MCP changelog 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/changelog)).
  - Still a **research preview**.
  - Requires claude.ai authentication **or a Console API key**. This is broader than SPEC §11 "requires a claude.ai login". Does not work on Bedrock, Vertex and Foundry.
  - **While the preview lasts, `--channels` accepts only plugins from the Anthropic allowlist** (or from the organization's allowlist). Our own server can be connected only via `--dangerously-load-development-channels`. The flags are not shown in `--help`.
  - **MCP revision 2026-07-28 does not carry channel messages.** Claude Code on the v2 runtime "Doesn't register a channel server that connects on the newer revision, because that revision can't carry channel messages".
  - The revision 2026-07-28 itself: stateless, no `initialize`, push only through `subscriptions/listen` for list-changed. Roots, Sampling and Logging are declared deprecated.
- **Update 2026-10-08.** `rmcp 3.5.1` (2026-10-05): fixes only (discover lifecycle, in-band invalid-params errors,
  default cache hints for 2026-07-28 peers, `object!` export) — [release](https://github.com/modelcontextprotocol/rust-sdk/releases/tag/rmcp-v3.5.1).
  Nothing on channels; we pin `=3.5.0`. Not met.
- **Update 2026-10-22.** `rmcp 3.6.0` (2026-10-20): cancellation of abandoned `tools/call`/`prompts/get`/
  `resources/read`, a non-blocking `stdio_pipes` transport, bounded incoming line buffer, stricter JSON-RPC parsing,
  and "reject requests to 2026-07-28 clients" on the server
  ([release](https://github.com/modelcontextprotocol/rust-sdk/releases/tag/rmcp-v3.6.0)). Nothing on channels; we pin
  `=3.5.0`. Not met.
- **Update 2026-10-26.** `rmcp 3.7.0` (2026-10-22): OIDC ID-token subjects in enterprise exchange, auth and transport
  fixes ([release](https://github.com/modelcontextprotocol/rust-sdk/releases/tag/rmcp-v3.7.0)), and two advisories:
  [GHSA-5p52-q7pq-9fq2](https://github.com/modelcontextprotocol/rust-sdk/security/advisories/GHSA-5p52-q7pq-9fq2)
  (medium, OAuth metadata SSRF filter, `>= 2.0.0, <= 3.6.0`, fixed in 3.7.0) and
  [GHSA-4432-vg92-fqh6](https://github.com/modelcontextprotocol/rust-sdk/security/advisories/GHSA-4432-vg92-fqh6)
  (high, unbounded cache growth in the Streamable HTTP server transport, `>= 3.0.0, < 3.6.0`, fixed in 3.6.0). Our
  `=3.5.0` is in both ranges, but we enable only `server`, `transport-io` and `macros` (stdio, no OAuth client, no
  Streamable HTTP server). Nothing on channels. Not met.
- **Consequence for us (for TROUBLESHOOTING/STACK — to be decided).** The Channels adapter in `x mcp` must negotiate a revision no newer than 2025-11-25. Check what `rmcp 3.5` negotiates (STACK records: 2026-07-28 by default).
- **Update 2026-10-29.** `rmcp 3.8.0` (2026-10-26): body-free HTTP status errors in the transport, the client stops
  SSE reconnects on permanent GET errors ([release](https://github.com/modelcontextprotocol/rust-sdk/releases/tag/rmcp-v3.8.0)).
  HTTP client paths only, our stdio server is untouched; spike not rerun. Nothing on channels. Not met.
- **How we cover it:** `wait_for_message` (long-poll) and client hooks. For Claude Code in v0.2 — the dev flag or the organization allowlist.
- **Adopt when:** Channels GA **and** our own channel without the Anthropic allowlist. The alternative is our plugin in `claude-plugins-official`, but that is external publication, only on the maintainer's decision.
- **Where:** markers in `channels.md`/`mcp.md`, the `schema/` directory of the MCP specification, crates.io `rmcp`. Script: `w10-*`. **Frequency:** week.

### W-11 · A2A
- **Status 2026-10-02.**
  - Specification v1.0.0 (2026-03-12), v1.0.1 (2026-05-28) — [releases](https://github.com/a2aproject/A2A/releases). v1 has `AgentCardSignature`.
  - On 2026-08-27 A2A was accepted into the **Agentic AI Foundation** (Linux Foundation) as Growth Stage — [A2A blog](https://a2a-protocol.org/latest/blog/2026/08/27/a-new-chapter-for-a2a-joining-the-agentic-ai-foundation/).
  - Official Rust SDK `a2a-lf 0.4.1` (2026-09-30, repository `a2aproject/a2a-rs`).
  - Update 2026-10-19: `a2a-lf 0.4.2` (2026-10-16), a patch release: an omitted empty security scope list is accepted,
    security requirements serialize in the v1.0 shape ([CHANGELOG](https://github.com/a2aproject/a2a-rs/blob/main/a2a/CHANGELOG.md)).
    Still 0.x with breaking changes in minor releases; no 1.0 timeline in the README or changelogs. Not met.
  - No E2E at the A2A level, only transport TLS. There are individual drafts `draft-chapman-a2a-mls-03` and `draft-chapman-a2a-offline-delivery-00`.
- **How we cover it:** A2A — v0.3. The transport is ours, A2A is only the task language (SPEC §11).
- **Adopt when:** `a2a-lf` ≥ 1.0 by the start of v0.3; otherwise our own types from the proto.
- **Where:** GitHub releases, crates.io. Script: `w11-*`. **Frequency:** month.

### W-12 · Trust labels in MCP (SEP-1913)
- **Status 2026-10-02.** SEP-1913 "Trust and Sensitivity Annotations" open since 2025-11-27, labels `draft`, `roadmap/security`. Proposes `sensitiveHint`, `privateHint`, `openWorldHint`, `attribution` with the rule "sensitivity within a session only grows" — [issue](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1913). The neighboring SEP-3140 and SEP-3193 are closed.
- **How we cover it:** the "external data, not instructions" wrapper for incoming data (SPEC §9) and taint in the daemon.
- **Adopt when:** the SEP is accepted. Then `x mcp` marks everything that came from a contact with the standard labels, and client-side IFC gateways (fides-gateway and others) can take them into account.
- **Where:** GitHub issue. Script: `w12-*`. **Frequency:** month.

### W-13 · biscuit-auth with ed25519-dalek 3
- **Status 2026-10-02.**
  - The last release is 6.0.0 of 2025-07-16, more than 14 months ago. main already has an abstraction over the cryptography (PR #334, breaking, 2026-06-24), but `Cargo.toml` still has `ed25519-dalek 2`, `rand 0.8`.
  - PR [#349](https://github.com/eclipse-biscuit/biscuit-rust/pull/349) (2026-09-30) moves to ed25519-dalek 3 and rand 0.10. Open.
- **Status 2026-10-12.** PR [#349](https://github.com/eclipse-biscuit/biscuit-rust/pull/349) was merged into main on
  2026-10-08 (ed25519-dalek 3, rand/rand_core 0.10, p256 0.14; breaking, since `rand` types are in the public API of
  `new_with_rng`/`build_with_rng`). No release yet: crates.io still ends at 6.0.0 (2025-07-16); in the PR a maintainer
  says one datalog evaluation patch goes first, then "we want to cut a release soon". Condition not met.
  - There is **no need** to wait for holder-of-key "out of the box". The maintainers themselves described PoP through a third-party block — ["DPoP demon hunters", 2025-09-19](https://www.biscuitsec.org/blog/dpop-demon-hunters/). This is exactly our D-11.
- **How we cover it:** `biscuit-auth =6.0.0`, a duplicate Ed25519/curve25519 in the tree (STACK).
- **Adopt when:** a release with ed25519-dalek 3 is out.
- **Where:** crates.io, PR #349. Script: `w13-*`. **Frequency:** week.

### W-14 · An open CDR for the §10 pipeline
- **Status 2026-10-02.**
  - Dangerzone 0.11.0 (2026-07-02), AGPL-3.0, Python. Conversion in a container (podman/docker) with gVisor: pixels → PDF + OCR.
  - Since 0.11 the Linux CLI does not include the sandbox image itself, `dangerzone-image upgrade` is needed — [release](https://github.com/freedomofpress/dangerzone/releases/tag/v0.11.0).
  - No library or headless API. Issue #215 "Use container library instead of subprocess" has been open since 2022.
  - YARA-X 1.21.0 (2026-09-29), Rust, BSD-3-Clause — embeddable.
  - ClamAV 1.5.4 (2026-08-07), GPL-2.0, C — only as a separate process (`clamd`). Linking with AGPL-3.0 is apparently not allowed (not confirmed by a lawyer).
  - No open embeddable CDR for PDF/Office in Rust was found.
  - Update 2026-10-22: YARA-X 1.22.0 (2026-10-20): 64-bit integer functions, `pe.offset_to_rva`, robustness fixes
    for rule size and deserialized rule data ([release](https://github.com/VirusTotal/yara-x/releases/tag/v1.22.0)).
    No CDR change. Not met.
  - Update 2026-10-26: Dangerzone 0.11.1 (2026-10-22): `dangerzone-cli` reads a document from stdin and writes the
    safe PDF to stdout (`-` and `--output-filename -`), update checks can be turned off, two fixes in
    `dangerzone-image load-archive` (GHSA-m282-wfqf-935m, GHSA-pfm5-gp85-8g5p)
    ([release](https://github.com/freedomofpress/dangerzone/releases/tag/v0.11.1),
    [CHANGELOG](https://github.com/freedomofpress/dangerzone/blob/v0.11.1/CHANGELOG.md#0111)). A pipe-friendly CLI,
    but still a container runtime and no library; issue #215 still open. Not met.
- **Update 2026-10-29.** YARA-X 1.22.1 (2026-10-26): two compiler panic fixes (fullword masked literals, deeply
  nested fixed repetitions) ([release](https://github.com/VirusTotal/yara-x/releases/tag/v1.22.1)). No CDR change.
- **How we cover it:** our own assembly of known parts: a bubblewrap + Landlock + seccomp sandbox, rasterization, image re-encoding, YARA-X.
- **Adopt when:** Dangerzone gets an embeddable mode without a GUI and without the docker daemon, or another open CDR with a sandbox appears.
- **Where:** GitHub releases of Dangerzone, crates.io `yara-x`. Script: `w14-*`. **Frequency:** month.

### W-15 · Hardware key storage on a VPS
- **Status 2026-10-02.**
  - Hetzner Cloud: "our cloud servers do not support vTPM (Virtual Trusted Platform Module) or TPM", no Secure Boot either — [FAQ](https://docs.hetzner.com/cloud/servers/faq/).
  - AWS has NitroTPM (TPM 2.0, free, on Nitro instances) — [AWS](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nitrotpm.html).
  - GCP has Confidential VM on AMD SEV / SEV-SNP / Intel TDX with vTPM — [GCP](https://docs.cloud.google.com/confidential-computing/confidential-vm/docs/confidential-vm-overview).
- **Caveat.** The vTPM of an ordinary VM is provided by the hypervisor. It protects against a disk copy but not against the provider. Only confidential VMs protect against the provider.
- **How we cover it:** Q-4 — password + Argon2id, `x unlock`.
- **Adopt when:** the VPS where the agents live gets a vTPM. Then seal the key with TPM2 (systemd-creds / tss-esapi) and use the TPM monotonic counter against rollback (SPEC §8).
- **Where:** the marker in the Hetzner FAQ. Script: `w15-*`. **Frequency:** quarter.

### W-16 · Information flows for LLM agents (manual)
- **Status 2026-10-02.**
  - CaMeL (Google, [repository](https://github.com/google-research/camel-prompt-injection), Apache-2.0) — code accompanying the paper, last push 2025-06-20.
  - FIDES (Microsoft, [repository](https://github.com/microsoft/fides), MIT) — a tutorial notebook, last push 2025-05-30.
  - **fides-gateway** (Microsoft, created 2026-06-01, push 2026-09-30) — a "research prototype" MCP proxy. Rego policies (regorus), IFC labels in `_meta["com.github.ifc/labels"]` — [README](https://github.com/microsoft/fides-gateway).
  - Meta "Agents Rule of Two" (2025-10-31) — a design rule, not a library — [Meta AI](https://ai.meta.com/blog/practical-ai-agent-security/).
  - 2026 papers (SPA, APPA, MNC and others) work inside one system and one owner.
- **How we cover it:** coarse session-level taint in the daemon (SPEC §9) and launching the agent on wake in our sandbox.
- **Adopt when:** a maintained library appears with a label format aligned with MCP (related to W-12). Nobody builds the cross-owner part.
- **Frequency:** month, manual (GitHub, arXiv, MCP SEP).

### W-17 · Post-quantum deniable authentication (manual)
- **Status 2026-10-02.**
  - Fiedler, Janson (PoPETs 2024): "PQXDH does not meet the same deniability guarantees as X3DH due to the signature on the ephemeral key" — [ePrint 2024/741](https://eprint.iacr.org/2024/741).
  - Katsumata, Niot, Tucker, Wiggers (PQShield; USENIX Security 2025): describe under which conditions PQXDH is deniable against a "quantum judge"; propose RingXKEM on deniable ring signatures from Falcon/MAYO — [ePrint 2025/1090](https://eprint.iacr.org/2025/1090). This is research, there is no implementation.
- **How we cover it.** SPEC §8: in the deniable mode messages are authenticated by a MAC on the shared link key. This is deniable even against a quantum adversary. The fact of the link itself is provable: the pairing transcript is signed by the link-root. This should be stated plainly in the threat model.
- **Adopt when:** an audited implementation of a PQ-deniable AKE (RingXKEM, K-Waay and the like).
- **Frequency:** quarter, manual (ePrint, USENIX, PETS).

### W-18 · iroh mobile bindings
- **Status 2026-10-02.**
  - Official bindings for Swift, Kotlin, Python, JS (2026-06-18). QUIC streams only, "In the future … gossip, blobs". mDNS and Bluetooth — Rust only for now. No Dart/Flutter — [n0 blog](https://www.iroh.computer/blog/iroh-language-support).
  - `iroh-ffi v1.1.0` (2026-07-16).
  - Update 2026-10-26: `iroh-ffi v1.2.0` (2026-10-22): JS packaging, Android 16 KB pages, authenticated relay presets;
    the README now links community-maintained Dart and Flutter bindings and still says `iroh-blobs`, `iroh-docs` and
    `iroh-gossip` are out of scope ([README](https://github.com/n0-computer/iroh-ffi/blob/v1.2.0/README.md)). The
    Flutter plugin [`iroh_flutter`](https://pub.dev/packages/iroh_flutter) 1.3.0 (2026-10-26, community) builds the
    Rust core into the app for Android, iOS, macOS, Linux and Windows; QUIC streams and relays only, no blobs or mDNS.
- **Takeaway.** SPEC §14 "Flutter through ready-made iroh bindings" is wrong as of today. Our core (libsignal, policy) is Rust anyway, so the mobile client will embed our own Rust core via FFI rather than the iroh bindings.
- **Where:** GitHub releases of `iroh-ffi`. Script: `w18-*`. **Frequency:** quarter.

### W-19 · Hybrid signature format and libcrux-ml-dsa
- **Status 2026-10-02.**
  - `libcrux-ml-dsa 0.0.10` (2026-07-15), still 0.0.x.
  - `draft-ietf-lamps-pq-composite-sigs-19` is in the RFC Editor queue. RFC 9881 (ML-DSA in X.509) and RFC 9955 (the spectrum of hybrid signatures) are already out.
  - Update 2026-10-08: `libcrux-ml-dsa 0.0.11` (2026-10-07), changelog "Update workspace dependencies" only, still
    0.0.x — [CHANGELOG](https://github.com/celabshq/libcrux/blob/main/libcrux-ml-dsa/CHANGELOG.md). Not met.
  - Update 2026-10-22: `draft-ietf-lamps-pq-composite-sigs-19`: RFC Editor state "Blocked", RPC status "Final
    Approval Pending" since 2026-10-19 — the final approval step, not an RFC yet
    ([history](https://datatracker.ietf.org/doc/draft-ietf-lamps-pq-composite-sigs/history/)). Not met.
- **How we cover it:** link-root = Ed25519 + ML-DSA-65 as two signatures side by side (SPEC §7). The exact format is fixed in `PROTOCOL.md`.
- **Adopt when:** the composite-sigs RFC is out — compare the format and decide whether to move to the composite. libcrux-ml-dsa ≥ 0.1.
- **Where:** crates.io, datatracker. Script: `w19-*`, `w07-composite-sigs`. **Frequency:** month.

### W-20 · IETF standards for agents
- **Status 2026-10-02** ([agentproto](https://datatracker.ietf.org/group/agentproto/about/), [dmsc](https://datatracker.ietf.org/group/dmsc/about/), [dawn](https://datatracker.ietf.org/group/dawn/about/)).
  - **agentproto** — proposed WG, ART area. A protocol for managing agent dialogs: dialog identifiers, lifecycle, context through intermediaries. Out of scope — "AI agent behavioral security".
  - **dmsc** (Dynamic Multi-agent Secured Collaboration) — a BoF at IETF 126, no charter.
  - **dawn** (agent discovery) — proposed.
  - Active: webbotauth (signatures of agents' HTTP requests), wimse (workload identity; `draft-ni-wimse-ai-agent-identity-03` of 2026-10-01).
- **Status 2026-10-12.**
  - **agentproto is chartered**: [charter-ietf-agentproto-01](https://datatracker.ietf.org/doc/charter-ietf-agentproto/)
    approved, WG state "Active" (charter updated 2026-10-08). Deliverables: an Agentic Dialog Management Protocol
    (Standards Track; dialog identifiers, lifecycle, context propagation, bindings over HTTP/QUIC/WebTransport/WebRTC/MoQ),
    a reference architecture and use cases (Informational); no milestones listed. Security: agents authenticated
    independently of their delegating users, delegated authorization protected across agent chains, existing building
    blocks reused (OAuth, webbotauth, WIMSE; SCITT, RATS). Authorization between different owners is not addressed
    explicitly; "AI agent behavioral security" stays out of scope.
  - **dmsc**: "BOF Concluded", "Not chartered yet" ([about](https://datatracker.ietf.org/group/dmsc/about/), group
    updated 2026-10-08). No WG formed.
  - "Adopt when": half met — a WG is chartered, but its charter does not cover cross-owner authorization. Next: read
    agentproto's first drafts when they appear and compare their delegation model with our trust levels.
- **Adopt when:** a WG takes on work on cross-owner agent authorization. Compare with our permission model, do not duplicate.
- **Where:** datatracker API. Script: `w20-*`. **Frequency:** month.

### W-22 · File inputs for MCP tools (manual)
- **Status 2026-10-05.** The MCP specification has no file input for tools. One proposal is left in play: SEP-2631
  ("File Objects and Transfer", `x-mcp-file`, `files/authorizeUpload`,
  [PR 2631](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2631)) — open, still a draft PR, last
  updated 2026-10-02, labelled `documentation`, no milestone.
  SEP-2356 (declarative `inputFiles`, RFC 2397 data URIs,
  [PR 2356](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2356)) was closed unmerged on
  2026-06-26 by its own sponsor, "in favor of #2631 which will likely be the more durable solution"; our earlier status
  still listed it as open. Only hosted ChatGPT apps have a documented mechanism,
  `_meta["openai/fileParams"]` with a download URL, for remote servers
  ([reference](https://developers.openai.com/plugins/reference)).
- **Status 2026-10-19.** SEP-2631 was closed unmerged on 2026-10-14 "in favor of the extension": the File Uploads
  Working Group continues it as the experimental extension `io.modelcontextprotocol/files`
  ([repository](https://github.com/modelcontextprotocol/experimental-ext-file-uploads), created 2026-10-14;
  [PR 1](https://github.com/modelcontextprotocol/experimental-ext-file-uploads/pull/1), open, updated 2026-10-17).
  The draft keeps `x-mcp-file` on file arguments; a large file is announced by metadata in `_meta`, the server answers
  `upload_required` with an HTTPS upload target and a file URI, the client uploads and retries with the URI; files under
  the inline limit go as `data:` URIs. It is meant to become an Extensions Track SEP once a reference implementation
  exists. Not met: an experimental extension, not an accepted SEP, and no app passes files through it yet. When it
  settles, check how its HTTPS upload target maps onto a local stdio server such as `antenna mcp`.
- **Status 2026-10-26.** [PR 1](https://github.com/modelcontextprotocol/experimental-ext-file-uploads/pull/1) still
  open (updated 2026-10-24). Merged into it: [PR 2](https://github.com/modelcontextprotocol/experimental-ext-file-uploads/pull/2)
  (2026-10-20), the marked file argument now carries required `id`, `mimeType`, `size` and SHA-256 `digest` and
  optional base64 `data`, so the server sees the intended call before choosing an upload target; then "Allow gateways
  to relay any upload target" and "Propose a download shape" (2026-10-21). On 2026-10-22 a third-party MCP server
  reported a server-side implementation of the draft. Not met: still a draft extension, no app passes files through it.
- **How we cover it:** `share_file_content` takes base64 in a tool argument (D-87); local agents send by path.
- **Adopt when:** a SEP is accepted and the apps that run local servers (ChatGPT desktop, Claude, Cursor, VS Code) pass
  files through it: then `antenna mcp` declares the file input and the bytes take the same path as today. Not met: the
  one remaining proposal is a draft, and the data-URI shape of SEP-2356 is off the table, so keep `share_file_content`
  as the single path.
- **Where:** PR 2631 (closed), the `experimental-ext-file-uploads` repository, the MCP changelog. **Frequency:** month.

### W-23 · Flutter macOS text input and `xterm` SGR parsing (manual)
- **Status 2026-10-12.** Flutter: latest stable 3.47.7 (2026-10-08, the
  [release list](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)); we pin 3.47.6.
  [#184571](https://github.com/flutter/flutter/issues/184571) open (P2, assigned), PR
  [#190539](https://github.com/flutter/flutter/pull/190539) still a draft without reviews,
  [#191503](https://github.com/flutter/flutter/issues/191503) open without a linked PR. `xterm`: pub.dev latest is
  still 4.0.0 (2024-02-27); two upstream PRs opened 2026-10-02 cover exactly our filter —
  [#245](https://github.com/TerminalStudio/xterm.dart/pull/245) "support ':' sub-parameters in SGR" and
  [#244](https://github.com/TerminalStudio/xterm.dart/pull/244) "ignore CSI sequences with a private prefix in SGR" —
  both open, not merged; the default branch has had no commit since 2025-06-19.
- **Status 2026-10-26.** Flutter stable 3.47.8 and beta 3.50.0-0.2.pre (both 2026-10-23, the release list above);
  #184571 and #191503 open, PR #190539 still a draft; `xterm` still 4.0.0, PRs #244/#245 open, unchanged since 2026-10-02.
- **Adopt when:** see the summary row. Not met on either side.
- **Where:** the Flutter issues and PR above, pub.dev `xterm`, xterm.dart PRs #244/#245. **Frequency:** month.

### W-24 · Claude Code channels for third-party servers (manual)
- **Status 2026-10-05.** Source: the messages of the `claude` 2.1.233 binary itself (its strings; no documentation
  page checked yet). An MCP server that declares the `claude/channel` capability can push inbound messages into a
  session started with `--channels`, and relay permission prompts (`notifications/claude/channel/permission_request`).
  A server not on the vendor's approved channels list is refused ("use `--dangerously-load-development-channels` for
  local dev"); claude.ai Teams and Enterprise organizations have channels off unless an administrator sets
  `channelsEnabled: true`; not on Bedrock, Vertex or Foundry.
- **Status 2026-10-12.** The documentation now exists and confirms the binary's messages
  ([channels](https://code.claude.com/docs/en/channels),
  [reference](https://code.claude.com/docs/en/channels-reference)): channels are a research preview; custom channels
  are not on the approved allowlist and need `--dangerously-load-development-channels`, even from one's own plugin
  marketplace; the default allowlist is the channel plugins of `claude-plugins-official`, which Team and Enterprise
  admins can replace with their own `allowedChannelPlugins`. Condition not met.
- **How we cover it:** the window types one built-in line into the agent's terminal when Claude Code waits at its
  empty prompt (D-UI-23); the daemon's own wake agent for other cases (D-68).
- **Adopt when:** a user can enable a third-party server's channel without the vendor's allowlist or a
  `--dangerously-…` flag: then `antenna mcp` declares the capability, pushes a notice (never the message text) when a
  message for the agent arrives, Code mode starts Claude Code with `--channels`, and the typed wake goes for Claude
  Code.
- **Where:** Claude Code's changelog and documentation; `claude --help`. **Frequency:** month.

### W-25 · Codex `queue` for a running session (manual)
- **Status 2026-10-06.** The Codex CLI 0.160.1 has `codex queue --thread <id> --message <text>` (the app-server's
  `thread/queue/add`): it queues a message into an existing session through Codex's shared local app-server. Reports of
  integrators say that since 0.157 a queued message no longer starts a turn in an idle session by itself (it waits for a
  person's "Steer"), and that a message queued into a thread that ends without running it is lost.
- **Status 2026-10-26.** Codex 0.164.0 (2026-10-23,
  [release](https://github.com/openai/codex/releases/tag/rust-v0.164.0)): "Queued prompts now wait for pending
  permission selections to resolve before continuing", and a disabled-by-default `wake_on_agent_messages` feature
  ([PR 54961](https://github.com/openai/codex/pull/54961)) that starts a new root turn when mail from Codex's own
  agents arrives in an idle session (not in interrupted sessions, Plan mode or child agents). That is Codex's internal
  agent mail, not `codex queue`; nothing says a queued message starts a turn in an idle session. Not met.
- **How we cover it:** Codex's documented hooks and `notify` say when it waits, the window and `antenna session` type
  one built-in line at its empty composer, and its Stop hook continues a running turn (D-117).
- **Adopt when:** the documentation says a queued message starts a turn in an idle session and is kept until it runs:
  then the wake queues the same built-in line instead of typing it, for Codex in the window and in `antenna session`.
- **Where:** `codex queue --help`, the Codex changelog, learn.chatgpt.com/docs. **Frequency:** month.

The MCP revision 2026-07-28 (W-10) also makes `server/discover` mandatory for servers; check whether `rmcp` answers it
before clients drop the `initialize` fallback (`docs/CONNECT-APPS.md`, "Changes in the MCP specification").

---

## Dropped during the check of 2026-10-02

| Was on the initial list | Why we do not wait for it |
| --- | --- |
| Holder-of-key in biscuit "out of the box" | Not planned. The maintainers recommend PoP through a third-party block — our D-11 (W-13) |
| PQ identity in iroh in the foreseeable future | n0 explicitly refused until there is a real threat to Ed25519 (W-07). We do not wait, we cover it at the application layer |
| RustCrypto `x-wing` as an audited alternative | 0.1.1 is out (2026-10-01), but the README still says "has never been independently audited" |
| "Channels work only with a claude.ai login" | Outdated: a Console API key works too. The new restrictions are the plugin allowlist and the MCP revision (W-10) |
| NAT Traversal "an emerging IETF standard" | There is no WG draft, only n0's description of its implementation (W-06) |

## Closed

*Empty for now. An item moves here when the technology is adopted (with a link to DECISIONS).*
