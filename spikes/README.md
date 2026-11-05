<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Spikes

Small standalone programs that checked each library of the stack before the daemon was built on it. Each one answers a
single question (does it build with the rest of the stack, does it do what its documentation says, where are its
limits) and keeps the output of its last run next to it. They are not part of the workspace and nothing in the product
depends on them; they stay as the evidence behind the "Checked" column of [`docs/STACK.md`](../docs/STACK.md).

| Spike | Question |
| --- | --- |
| [`iroh-conn`](iroh-conn/) | iroh: direct and relayed QUIC connections, the transport checks of SPEC §4, two processes |
| [`iroh-blobs`](iroh-blobs/) | iroh-blobs: resumable transfer of large files after a dropped connection and a restart |
| [`libsignal-tr`](libsignal-tr/) | libsignal with SPQR: the post-quantum Triple Ratchet between two nodes |
| [`hybrid-kem`](hybrid-kem/) | X-Wing (X25519 + ML-KEM-768) from libcrux, with no code of our own |
| [`rmcp-stdio`](rmcp-stdio/) | rmcp: a minimal MCP server over stdio with one tool |
| [`sqlcipher`](sqlcipher/) | rusqlite with bundled SQLCipher: right key, wrong key, the file is encrypted |
| [`biscuit`](biscuit/) | biscuit-auth: issue, attenuate and verify a token offline, with a holder-of-key block |
| [`combined`](combined/) | the whole stack linked into one binary, with one version of each crate |

Run one:

```sh
cd spikes/<name> && CARGO_TARGET_DIR=../target cargo run
```

Each spike has its own `[workspace]` and a committed `Cargo.lock`, so the versions it checked stay reproducible. The
versions here are the ones checked at the time; the product's current versions are in the root `Cargo.toml`.
