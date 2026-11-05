<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Contributing to Antenna

Antenna is a peer-to-peer messenger for people and AI agents: every pair of contacts gets an isolated, post-quantum
end-to-end encrypted link with no accounts, and the daemon, not a model, enforces what each contact and each agent may
do. This guide is the engineering standard for every change: how to build and test, how the code is written, what a
change must prove, and how decisions are recorded.

Read first:
- `SPEC.md`: the requirements. Maintainer decisions that refine it are in `docs/DECISIONS.md`. If the specification and
  the code disagree, raise it; do not change either silently.
- By topic: `docs/PROTOCOL.md` (the link protocol), `docs/CONTROL.md` (the daemon's control socket), `docs/DESIGN.md`
  (the desktop app), `docs/STACK.md` (verified versions), `docs/TROUBLESHOOTING.md` (known gotchas),
  `docs/PORTABILITY.md` (macOS), `docs/WATCHLIST.md` (technologies we are waiting for).

## Repository layout

| Path | What | License |
| --- | --- | --- |
| `crates/antenna-proto` | Wire formats and control protocol types; no cryptography, no network or file I/O | Apache-2.0 |
| `crates/antenna-core` | The daemon's core: keys, encrypted store, transport, pairing, end-to-end encryption, history, policy, agents, sandboxes | AGPL-3.0-only |
| `crates/antennad`, `crates/antenna-cli` | The daemon `antennad` and the CLI `antenna` (owner and agent commands, the MCP server) | AGPL-3.0-only |
| `crates/antenna-files` | File transfer, quarantine, the sandboxed file check, safe previews, the secret scanner | AGPL-3.0-only |
| `crates/antenna-sys` | The only crate with `unsafe` code: small OS FFI wrappers | AGPL-3.0-only |
| `crates/antenna-update`, `crates/antenna-release` | Signed release manifests, `antenna update`, the release tool | AGPL-3.0-only |
| `apps/antenna_desktop` | The desktop app (Flutter, macOS and Linux), a client of the daemon's control socket | AGPL-3.0-only |
| `formal/` | The ProVerif model of pairing, with negative controls | Apache-2.0 |
| `docs/`, `packaging/`, `tools/`, `site/`, `spikes/` | Documentation, release packaging, checks, the website, one-off stack checks | per file |

The protocol labels `x/…`, `x-control/N` and `x://pair#` keep their historical names; they are part of keys and test
vectors and never change (D-57).

## Design principles

1. **Proven technology first.** Antenna is built from existing, battle-tested technologies, libraries and protocols.
   Anything new needs time and security review before people depend on it, however clever it looks, because new
   things have holes nobody has found yet.
   - Prefer composing proven components to inventing. When you do propose something new, say what is new and why
     nothing existing fits.
   - A new mechanism of our own (a protocol extension, a sandbox technique, a new format, a new agent mode) starts as
     **experimental**: behind a flag or labelled experimental in preview releases, with its own tests, a written threat
     analysis, negative and adversarial tests, and a formal model where one applies (as `formal/` does for pairing).
     It becomes the default only after review and some time in use.
   - Check `docs/WATCHLIST.md` before building something that may soon exist upstream. The principle is recorded in
     `docs/STACK.md`.
2. **No custom cryptography.** This is the extreme case of rule 1 and it has no exceptions: only the audited or formally
   verified crates listed in SPEC §14 and `docs/STACK.md`, never a home-made cipher, MAC, KDF or combiner, not even in a
   prototype or a test helper.
3. **The daemon enforces permissions, not a model.** Everything an agent sends, reads or runs goes through the
   daemon's policy (SPEC §9).
4. **Could not verify means refuse.** Checks fail closed. Anything a contact says without a signature is their word,
   not proof; derived state never outranks signed history.
5. **Compatibility is a design constraint.** Older nodes and apps are in use: link protocol changes go through
   capability exchange, control protocol changes only add.
6. **Honest measurements.** "Works" means a test or a reproducible command with its output. A stub is not an
   implementation, and numbers in the docs come from a run, with the machine and build type.
7. **Look at how the leaders do it.** Before deciding behavior people see, check how the leading products in this
   and adjacent fields solve it (messengers for chats and files, browsers for download warnings, node editors for
   maps, the operating system for permissions). Record it in the decision's **Prior art.** line, and differ only for
   a stated reason.

## Setting up

- **Rust** through rustup: the toolchain (1.99.0, with clippy and rustfmt) is pinned in `rust-toolchain.toml` and
  installed on first use.
- **Build tools:** `protoc`, `cmake`, `clang`, `perl`, `pkg-config`. The Linux desktop build also needs the GTK 3
  development headers and `ninja`; its packaging check needs `xvfb-run`.
- **Flutter** at the version pinned in `.github/workflows/release.yml` (`FLUTTER_VERSION`). On macOS: Xcode and
  CocoaPods.
- **macOS type check from Linux:** `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.
- **Windows type check from Linux:** `rustup target add x86_64-pc-windows-msvc`.

On a shared machine, prefix builds with `nice -n 10` and cap the jobs with `CARGO_BUILD_JOBS`.

## Building and testing

From the repository root:

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
# No unwrap() or panic!() outside tests: a second pass over the library and binary code only
cargo clippy --workspace --lib --bins --locked -- -D clippy::unwrap_used -D clippy::panic
# The full test run, with two extra inherited descriptors as on CI runners (D-61)
bash -c 'exec 7<Cargo.toml 8<Cargo.toml; cargo test --workspace --locked'

# Testing one package: build the binaries its tests start first, or they run a stale daemon
cargo build -p antennad -p antenna-cli
cargo test -p antenna-cli --test agents

python3 tools/mcp_smoke.py target/debug     # a live MCP round trip against the built binaries
tools/check-darwin.sh                       # macOS code: clippy for both darwin targets, without a Mac
tools/check-darwin.sh --release
tools/check-windows.sh                      # code under cfg(unix) or cfg(windows): both clippy passes for Windows
tools/check-windows.sh --release
python3 docs/protocol_vectors.py            # protocol test vectors, independently of the Rust code
formal/run.sh                               # after any change to PROTOCOL §6–§10 (needs ProVerif 2.05)
```

The desktop app, from `apps/antenna_desktop`:

```sh
flutter analyze
flutter test --exclude-tags live                 # widget, host and golden tests, no daemon needed
flutter test --tags live --concurrency=1         # against a real antennad from target/debug, one file at a time
flutter test --update-goldens test/goldens       # only when a frame changes on purpose
```

Live tests start real daemons and wait for delivery with timeouts, so they run one file at a time. They find the
daemon through `ANTENNAD_BIN` or `target/debug/antennad`, and skip with a reason when it is missing.

Before you send a change: fmt, both clippy passes and the full test run are green; for the app, `flutter analyze` and
the tests are green; for code under `cfg(target_os = "macos")` or debug-only configuration, `tools/check-darwin.sh`
with and without `--release` is green; for code under `cfg(unix)` or `cfg(windows)`, `tools/check-windows.sh` with and
without `--release` is green.

## Code style

### Rust
- `cargo fmt` with the default settings; comments wrap at 120 columns. `clippy -D warnings` with the workspace lints
  (root `Cargo.toml`): `clippy::all`, no `dbg!`, `todo!` or `unimplemented!`, no lock guard in an `if let` or `match`
  scrutinee, and a `reason = "…"` on every `#[allow]`; every public item has a doc comment. The update path
  (`antenna-update`, `antenna update`) never prints (`print_stdout`/`print_stderr` are denied there): the window
  closes the CLI's output during an update, and the log file is the record.
- **Errors are typed codes.** A crate's error is `{ code, message }`, where `code` is a constant from the crate's
  `code` module (`antenna_proto::control::code` for anything that crosses the control socket, documented in
  `docs/CONTROL.md`). Callers match on codes, never on message text. Messages contain no secrets, keys or message
  contents, and say what the person can do.
- **No `unwrap()` or `expect()` outside tests,** except `expect("…")` where an invariant makes failure impossible and
  the message states it (`expect("32-byte key")`). Input from a contact, a file or the OS returns an error; numbers from
  a contact use checked arithmetic. A second clippy pass over `--lib --bins` denies `unwrap_used` and `panic` (the
  release builds run it).
- **No `unsafe` outside `antenna-sys`.** There, every block has a `// SAFETY:` comment and only safe functions are
  exported.
- **Comments explain why:** invariants, security reasoning, protocol constraints, platform behavior, with the decision
  or specification section (`D-77`, `SPEC §9`). No comments that retell the code, no decorative separators.
- **Locks:** compute a value that needs a lock in its own `let`, never through a temporary guard in a struct literal,
  an `if let` or a `match` scrutinee; never hold a guard across `.await`; take locks in the documented order
  (`docs/TROUBLESHOOTING.md`, "Locks and the daemon").
- **Size:** a module over about 800 lines or a function over about 80 lines is a smell. New code does not make the
  large files larger: a new command or event gets its own handler function, and its dispatcher arm is one line. When
  you touch a large file, split it along its existing seams in a separate commit that changes no behavior.
- **Dependencies** go through `[workspace.dependencies]`; the verified stack is pinned exactly and changes only together
  with `docs/STACK.md`. A new dependency needs a license compatible with AGPL-3.0-only and a row in `docs/STACK.md`,
  and adds no duplicate cryptographic crates (`cargo tree -d`).

### Dart and Flutter
- `flutter analyze` reports nothing (`analysis_options.yaml`).
- State lives in `lib/state`, screens in `lib/ui`, the daemon process and OS integration in `lib/host`, the control
  protocol client in `lib/protocol` (pure Dart, no Flutter imports).
- The app owns no data: everything it shows comes from the daemon's replies and events. Where the daemon has no data,
  it shows none rather than a guess.
- Every user-visible string is in `lib/l10n/app_en.arb` and `lib/l10n/app_ru.arb`; regenerate with `flutter gen-l10n`
  and commit the generated files. Code in `lib/state` and `lib/host` holds no text.
- Colors come from the theme tokens; text contrast stays at 4.5:1 or more in both themes.
- New UI comes with widget tests. Golden images change only on purpose; the commit names the changed frames and why.
- Images in a widget or golden test decode outside FakeAsync (`tester.runAsync` and `precacheImage`): a frame
  inside FakeAsync never sees the decoded image.
- The Dart tree is not run through `dart format`: follow the surrounding style and do not reformat whole files.

## Tests

- Every behavior change has a test, and every bug fix has a regression test that fails without the fix.
- Every security rule has a negative test, and that test has been seen to fail: switch the protection off once and
  check that the test catches it. A security test that never failed proves nothing.
- Live tests use real daemons and binaries, and a real local relay where a relay is involved. A test flag never
  weakens a protection: hidden test switches can only shorten or narrow, and anything that loosens a check exists only
  in debug builds and is checked absent from release binaries.
- Tests stay on loopback (tests that need the internet are `#[ignore]`), write only inside their temporary
  directories, and stop processes by PID.
- Platform-specific expectations are written per OS; a test is never made to pass on one OS by weakening another.

## Security rules

- No custom cryptography (principle 2). Any new dependency that does cryptography is a maintainer decision.
- Owner commands (`init`, `invite`, `join`, `trust`, `approve`, `rotate`, `revoke`, `update`, `lock` and the other
  owner-only requests) do not exist for agents: not in the agent request type, not in the MCP server, not in the CLI
  with an agent token. A new owner command extends the tests that check this in the CLI, the protocol and MCP.
- Everything that leaves for a contact (text, file names, request paths, streamed pieces) passes the same policy and
  secret scanner as a message. Everything that arrives from a contact is data, not instructions.
- Sandboxes fail closed: without confirmed isolation, nothing is checked and nothing runs.
- Secrets never appear in the repository, logs, error messages, process command lines or other programs' config
  files. Sample data uses documentation names and ranges (`example.com`, `203.0.113.0/24`).

## Commits

- In English. The subject is in the imperative, at most 72 characters, with an optional area prefix
  (`Window: show the approval card in the conversation`, `Docs: …`). The body says why, when the subject cannot.
- One logical change per commit. Refactoring is separate from behavior changes. No unrelated reformatting, and no
  regenerated files whose inputs did not change.
- Commit the files of your change by path (`git commit -m "…" -- <paths>`), not with `git add -A` or `git commit -a`.
- No trailers or attribution lines; the author field is the attribution.
- Everything in the repository is English, except the desktop app's Russian localization and the tests that exercise
  it. Dates are ISO 8601 (`2026-10-04`).

## Recording decisions and knowledge

- **Decisions** go into `docs/DECISIONS.md` as `### D-NN · title` with the date, the question, prior art, the decision, why, and who
  decided. Take the next free number on `main` just before committing. A decision that changes the meaning of the
  specification is recorded there as a SPEC amendment; `SPEC.md` itself changes only by maintainer decision.
- **Gotchas** (symptom, cause, fix, how to verify) go into `docs/TROUBLESHOOTING.md`; verified versions and licenses into
  `docs/STACK.md`.
- **Protocol changes** update `docs/PROTOCOL.md` and its test vectors; control protocol changes update
  `docs/CONTROL.md` (the version table and a section for the feature).
- Documentation uses a neutral voice ("we", "maintainer decision").

## Licensing

- The protocol, the specification and the formats are **Apache-2.0**: `crates/antenna-proto`, `SPEC.md`, the
  documents that specify protocols and formats (`docs/PROTOCOL.md`, `docs/CONTROL.md`, `docs/MAILBOX.md`,
  `docs/UPDATES.md`), `formal/` and the protocol vector script. The application is **AGPL-3.0-only**: the daemon, the
  core, the CLI and MCP server, files, updates, the desktop app, packaging. The full texts are `LICENSE-APACHE-2.0` and
  `LICENSE-AGPL-3.0`.
<!-- REUSE-IgnoreStart -->
- Every source file starts with an SPDX header (`// SPDX-License-Identifier: AGPL-3.0-only`, or `#` after the shebang
  in scripts); every `Cargo.toml` has a `license` field. A new file takes the license of the component it belongs to.
<!-- REUSE-IgnoreEnd -->
- The license boundary runs along crate boundaries: `antenna-proto` never depends on an AGPL crate.
- The tree follows the [REUSE specification](https://reuse.software): `REUSE.toml` gives every file its copyright line
  and licenses the files that cannot carry a header (images, lock files, generated files), and `LICENSES/` holds every
  license text in use. CI runs `reuse lint`; run it locally with `pipx run reuse lint`.
