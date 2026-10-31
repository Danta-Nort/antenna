<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Portability to macOS (darwin arm64 and x86_64): audit and list of changes

Status: audit 2026-10-02; **changes M-1…M-18 made 2026-10-02** (M-1/M-2 — slice 3, D-50; the rest — the portability task,
DECISIONS D-P-1…D-P-7); the file sandbox on macOS (M-15) and the agent wake sandbox — Seatbelt, 2026-10-03
(D-P-12…D-P-14, §2.3), waiting for the first CI run on a Mac. SPEC §16 "Platforms v1": macOS (arm64, x64), Linux,
Windows; SPEC §13 explicitly names hardened runtime (instead of `PR_SET_DUMPABLE`) and `sandbox-exec` for macOS. Line
numbers in the §2 table are as of the audit's HEAD (`d43030e`), the status is in §2.0.

> Windows: `docs/PORTABILITY-WINDOWS.md` (the same audit for Windows, WP-1…WP-37; DECISIONS D-134).

> On 2026-10-02 the product was renamed to **Antenna** (DECISIONS "Rename to Antenna and the first release"): crates
> `antenna-*`, binaries `antennad`/`antenna`, data directory `~/.local/share/antenna`, app `Antenna.app`, CI —
> `.github/workflows/release.yml` (job `core`). The §2 audit table describes the code at the time of the audit and keeps the
> old names where it talks about that state.

## 2.0. Status of the changes (2026-10-02)

Checked without a Mac: `tools/check-darwin.sh` (§3.1) — `cargo clippy --all-targets -D warnings` for antenna-sys,
antenna-proto, antenna-core, antennad, antenna-cli and (after the merge with stage B) antenna-files for
`aarch64-apple-darwin` and `x86_64-apple-darwin`, debug and release — clean;
Linux (after the merge with `main`): `cargo test --workspace` — 246 tests + 5 `#[ignore]`, clippy `-D warnings`, fmt —
green, `tools/mcp_smoke.py` passes; the window — `flutter analyze` with no remarks, `flutter test --exclude-tags live
test/widget test/host` — 23 tests green. On a Mac — CI `release.yml` (before the rename, `release-macos.yml`), job `core`
(§5 item 7): build, clippy, all core tests, XNU facts, a live `antenna mcp`.

**First run on a Mac (2026-10-02, `release.yml`, run 37052359720, `macos-14`, macOS 14.8.9 arm64).** Confirmed:
the build of all crates, clippy `-D warnings`, all XNU facts (the `antenna-sys` and `procinfo` tests: `SHORTBSDINFO` and
`UNIQIDENTIFIERINFO` are readable for another uid, `PROC_PIDTBSDINFO` for `launchd` gives `EPERM`, the audit token names
the peer, `kern.bootsessionuuid` is stable, the controlling terminal is visible), the GUI host on a real app (D-P-3),
`PT_DENY_ATTACH` in release, a live `antenna mcp` bound to the host, all core tests except one expectation in a test
(`/bin/sh` on macOS is bash with the same PID, D-62; fixed). The values are in TROUBLESHOOTING "First run of
`release.yml` on GitHub". The "to check" marks in §2 and §2.1 below are audit history; they are closed by this run, except the
experiments with Claude Desktop (§5 step 2) and the `fullfsync` latency (M-11): CI does not check those.

After the merge with stage B and the branch review (2026-10-02): CLOEXEC for inherited descriptors in `antennad` (D-P-8),
the binding does not survive a reboot (`kern.bootsessionuuid` / `boot_id`, D-P-9), nested anchors — the one nearest to
the client (D-P-10), the window — `mcpWorksOnMacos = true` (D-P-11).

| No. | Status | What was done (where) | What CI on a Mac will prove |
| --- | --- | --- | --- |
| M-1, M-2 | ✅ | `harden()` per OS (slice 3, D-50) | the build of `antennad`, `antenna` |
| M-3 | ✅ | `procinfo::darwin::stat` via `antenna_sys::darwin::{uniq_info, short_info}`, `getsid` (D-P-2) | `other_uid_processes_are_readable`, `launchd_is_readable_and_never_an_anchor` |
| M-4 | ✅ | `procinfo::darwin::ancestry`: `p_puniqueid` = the parent's `p_uniqueid` (when the parent > 1), `TRACED` → `None` | `child_links_to_parent_and_dies`, `own_process_is_alive_and_descends_from_parent` |
| M-5 | ✅ | `valid_anchor`: `sid > 0`, not `launchd`; a session leader only if it is a GUI host (`darwin::gui_host`, D-P-3) | `child_is_an_anchor_session_leader_is_not`, `gui_host_accepts_a_launched_app` (informational) |
| M-6 | ✅ | the crate `crates/antenna-sys` (`unsafe` only here, D-P-1) | 8 antenna-sys tests, clippy on macOS |
| M-7 | ✅ | `PT_DENY_ATTACH` in release for `antennad` and `antenna` (D-P-4); hardened runtime — already in `build-dmg.sh` | the "PT_DENY_ATTACH in release" step (lldb, informational), `deny_attach_in_child` |
| M-8 | ✅ | the `token_bound` text: "cannot read the client's process chain" | — |
| M-9 | ✅ | `tty` = `e_tdev` (own uid), the session leader by `p_uniqueid`; `open_held` requires the chain on macOS too | `controlling_terminal_is_seen`; `parent` sessions — in all antenna-cli tests (`login --password-stdin`) |
| M-10 | ✅ | `procinfo::peer_ancestry`: PID and `pidversion` from `LOCAL_PEERTOKEN`, checked against `p_idversion` | `audit_token_of_socketpair_is_self`, `audit_token_names_the_connecting_process`, `peer_chain_of_socketpair_is_self` |
| M-11 | ✅ | `PRAGMA fullfsync`, `checkpoint_fullfsync` under `target_vendor = "apple"` (`store.rs`) | antenna-core/antenna-cli tests on the DB; measure the latency manually |
| M-12 | ✅ | `antennad`: soft `RLIMIT_NOFILE` → `min(hard, 10240)` | the "Runner environment" step prints `ulimit -n` |
| M-13 | ✅ | `antennad`: `tmutil addexclusion <data directory>` in the background, a failure is a warning | (manually: `tmutil isexcluded ~/.local/share/antenna`) |
| M-14 | ✅ | checking the socket path length before `bind` (`control::MAX_SOCKET_PATH`) and a hint in the client | — |
| M-15 | ✅ code, waiting for CI | Seatbelt (2026-10-03, D-P-12): the worker calls `sandbox_init` itself (`antenna_sys::seatbelt`) with the profile `antenna_files::seatbelt::worker_profile`, rlimits, a probe from inside; `WorkerReady.seatbelt`; memory — a daemon watchdog on `phys_footprint`; `av-exec` — Seatbelt too. If it does not come up — still `failed` and a plain message to the owner | the "File check sandbox (Seatbelt)" step: `FACT file worker`, `FACT memory limit`, `FACT worker isolation`; all of `antenna-files` and `tests/files.rs` |
| — | ✅ code, waiting for CI | Agent wake on macOS (2026-10-03, D-P-13; it was fail-closed, D-72): `SandboxKind::Seatbelt`, `antenna_core::sandbox::{macos, seatbelt}` | the "Agent wake sandbox (Seatbelt)" step: `FACT agent sandbox=seatbelt …`, `wake_sandbox.rs`, `wake.rs`; `antenna-sys` — `FACT sandbox_check` |
| M-16 | ✅ decision | the directory `~/.local/share/<name>`, as on Linux (D-P-5); with the rename — `~/.local/share/antenna`, migration from `x` — D-56 | `crates/antenna-cli/tests/migration.rs`, `antennad` `migrate` |
| M-17 | ✅ | `PROTECTED_PATHS` + macOS paths, a test | `policy` unit test |
| M-18 | ✅ | CONTROL §1, §3, §11 items 2 and 10; D-28; doc comments in `procinfo.rs`, `control.rs`, `agents.rs`, `owner.rs` | — |

## 0. Scope of the audit

- Line numbers are as of **HEAD `d43030e`** (`git show HEAD:<path>`). The working tree has uncommitted changes from slices
  3–4 (`procinfo.rs` with a `tty` field, the new `antenna-core/src/owner.rs`, `statefile.rs`, a separate workspace
  `crates/antenna-files`). They are analyzed separately and marked "working tree": after they are committed the line
  numbers will shift, but the substance will stay.
- Nothing was built for darwin here (no SDK). The APIs were checked against the sources in `~/.cargo/registry` of the
  versions in `Cargo.lock`: `libc 0.2.189`, `rustix 1.1.5`, `tokio 1.53.1`, `aws-lc-sys 0.45.0`,
  `openssl-src 300.6.1+3.6.3`, `libsqlite3-sys 0.38.2`. The behavior of the XNU kernel (`proc_pidinfo` permissions,
  `getsid`, `LOCAL_PEER*`) is stated from memory of the XNU sources and is **marked "to check" everywhere**: on a Mac this is
  the first thing to check (§5, step 2).
- Our crates have no `mlock`, `landlock`, `seccomp`, `memfd`, `pidfd`, `inotify`, `epoll`, `prctl` (except dumpable), `/run`,
  `XDG_RUNTIME_DIR`. The only OS `#[cfg(...)]` is the test at `procinfo.rs:150` (`target_os = "linux"`); the rest is
  `#[cfg(test)]`. Landlock and seccomp exist only in `crates/antenna-files` (working tree, slice 4).

## 1. Summary

**Will not build (HEAD):** `antennad` and `antenna` — one call each to `rustix::process::set_dumpable_behavior` (`prctl`;
in rustix it exists only under `linux_kernel`): `antennad/src/main.rs:62-66`, `antenna-cli/src/main.rs:1356`. No other
compile errors were found in `antenna-proto`, `antenna-core`, `antennad`, `antenna-cli`: everything else from rustix
(`umask`, `geteuid`, `kill_process`, termios) and `std::os::unix` exists on macOS. `antenna-proto` is portable as a whole.

**Will build after M-1/M-2 and work without changes:** the daemon, socket `0600`/directory `0700`/`umask 077`, the uid
check (tokio `peer_cred` on macOS = `getpeereid`), the keystore (Argon2id, atomic write), SQLCipher with vendored OpenSSL,
iroh (QUIC, relay, portmapper), pairing, `send`/`inbox`/`history`/`subscribe`, the owner CLI with a password, the agent
CLI **with a token**, password input without echo (rustix termios), SIGTERM/Ctrl-C, the window (`apps/antenna_desktop`
looks up the socket in the same order).

**Will build, but broken:**
- `antenna mcp` — **will never start**: it sends `bind_parent: true` (`antenna-cli/src/mcp.rs:264-267`), the process chain
  on macOS cannot be read (`procinfo.rs:58` reads `/proc`), and `agents.rs:263-269` honestly refuses: `token_bound`
  "cannot verify the client process (no /proc entry)". The MCP integration of agents on the Mac does not work at all now.
- `antenna hook claude-code` without a token (that is how it is installed in host hooks,
  `antenna-cli/src/main.rs:1361-1367`) — `token_invalid` on every call, i.e. **blocking all** Bash/Write/Read in Claude
  Code (`hook.rs:126-145`). With a token in the hook's environment it works.

**Will build, but without protection (honest):**
- **There is no D-28 at all**: neither binding the token to the MCP host nor the rule "the host's tree is the agent". The
  agent's Bash tool connects to `antenna` as the owner: trust commands will still ask for the password (Q-12a), but
  `send`/`inbox` will go through as the owner, without taint and no-write-down. This is already recorded as a limit
  (CONTROL §11 item 2 "Outside Linux there is no binding"), but on the Mac — the maintainer's first platform — this is the
  main mode. Closed by M-3…M-6.
- **SPEC §13 "no core dumps and no ptrace"** disappears after M-1/M-2: `RLIMIT_CORE=0`, `PT_DENY_ATTACH` and signing with
  hardened runtime (M-7) are needed. The environment of `antenna mcp` (the token in `ANTENNA_AGENT_TOKEN`) on macOS can be
  read by any process of the same uid (on Linux, dumpable hides it) — not a new hole, the tokens lie in plain configs
  anyway (CONTROL §11 item 3).
- **Slice 3 (working tree):** the owner sessions "terminal" and "parent" (`owner.rs:70-93`) will not open on the Mac: no
  `tty`, `sid`, start time. **Slice 4 (working tree):** the file check worker is not isolated → with `require_isolation`
  the check refuses (fail-closed, but files are not accepted).
- **Data:** `PRAGMA synchronous = FULL` on macOS does not give durability on power loss (`fullfsync` is needed, M-11);
  Time Machine backs up the data directory, while SPEC requires "the database outside backups" (§8, §15) because of ratchet rollback
  (M-13).

**After all the changes — parity of protections:**

| Protection | Linux (now) | macOS (after the changes) | Remainder |
| --- | --- | --- | --- |
| Client uid | `SO_PEERCRED` | `getpeereid` (tokio) | the same |
| Client PID | `SO_PEERCRED`, PID at the time of `connect` | `LOCAL_PEEREPID` (tokio) + `LOCAL_PEERTOKEN` (M-10) | macOS returns the last process that worked with the socket (to check); no new bypass class — it needs an external process, which is a bypass anyway (double fork) |
| PID reuse between connect and reading | open (D-41, `SO_PEERPIDFD` not done) | closed by `pidversion` from the audit token (M-10) | — |
| Process chain | `/proc/<pid>/stat` | `proc_pidinfo` (`PROC_PIDT_SHORTBSDINFO` + `PROC_PIDUNIQIDENTIFIERINFO`), `getsid` | macOS is stronger: `p_uniqueid` instead of the start time, the link to the parent is checked by `p_puniqueid` |
| Where an orphan goes | init or a subreaper (`systemd`) | `launchd` (PID 1); macOS has no subreaper | double fork is a limit on both OSes |
| core dump | `PR_SET_DUMPABLE=0` | `RLIMIT_CORE=0` | the same |
| ptrace and reading memory | dumpable=0 | `PT_DENY_ATTACH` + hardened runtime | without signing with `--options runtime`, a debugger with DevTools rights will attach (via `task_for_pid`) |
| DB `fsync` | fsync | `F_FULLFSYNC` (M-11) | — |
| Backups | no automatic backup | excluded from Time Machine (M-13) | — |
| File sandbox (slice 4) | Landlock + seccomp + rlimits | Seatbelt (`sandbox_init` in the worker itself) + rlimits + a daemon memory watchdog (M-15, D-P-12) | threads are not forbidden (Seatbelt has no system call filter); memory — a watchdog with a 50 ms step, not a kernel limit |
| Agent sandbox (wake, v0.2) | bwrap + Landlock + seccomp; without bwrap — Landlock + seccomp (D-71) | Seatbelt + rlimits, a supervisor with a lifeline, orphans found by the sandbox itself (`sandbox_check`) (D-P-13) | file metadata is visible everywhere; an orphan is not an agent for the daemon until the end of the run; the bridge to the proxy is on the host's loopback |

## 2. Table of changes

Priority: **P0** — will not build without it; **P1** — will build, but broken or without the D-28/SPEC §13 protection;
**P2** — data durability and protection; **P3** — convenience and documents.

| No. | P | File:lines (HEAD) | Now (Linux) | On macOS (API) | Proposed option | Risk / to check on a Mac |
| --- | --- | --- | --- | --- | --- | --- |
| M-1 | P0 | `antennad/src/main.rs:61-66` | `rustix::process::set_dumpable_behavior(NotDumpable)` (`prctl`) | no `prctl`; the replacement is M-7 | `#[cfg(target_os = "linux")]` around the call; `#[cfg(not(linux))]` → `harden()` from M-7 | Without M-7 we lose SPEC §13 — make them together. **✅ Done in slice 3 (D-50):** `fn harden()` — Linux: dumpable=0; otherwise `RLIMIT_CORE=0` (core dump); against a debugger — M-7 later |
| M-2 | P0 | `antenna-cli/src/main.rs:1355-1356` | the same (protecting the password and the token in the memory of `antenna`) | the same | the same | the same. **✅ Done in slice 3 (D-50)**, like M-1. `cargo check --target aarch64-apple-darwin -p antenna-cli -p antennad`: `antenna-proto` and `antenna-cli` — no errors; beyond that — the C dependencies (aws-lc-sys, ring, blake3, openssl-sys: no macOS SDK) |
| M-3 | P1 | `antenna-core/src/procinfo.rs:5-7, 53-77` | `stat()` reads `/proc/<pid>/stat`: ppid, sid, comm, starttime | `proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO=13)` → `pbsi_ppid`, `pbsi_comm` (15 characters, as on Linux), `pbsi_uid`, `pbsi_flags`; `proc_pidinfo(pid, PROC_PIDUNIQIDENTIFIERINFO=17)` → `p_uniqueid`, `p_puniqueid`, `p_idversion`; `rustix::process::getsid(Some(pid))` → sid | `#[cfg(target_os = "macos")] fn stat()` on top of `antenna_sys::darwin` (M-6): uniqid → short → uniqid, different `p_uniqueid` → `None`; `ProcStat.start = p_uniqueid` (on macOS this is the "process incarnation", not a time) | **Do not use `PROC_PIDTBSDINFO`**: it (per XNU `proc_info.c`, `CHECK_SAME_USER`) gives `EPERM` for another uid — the chain through root processes (`login` in Terminal.app, `launchd`, `sudo`) breaks, and with "fail-closed" (D-38) everyone is refused. `SHORTBSDINFO` and `UNIQIDENTIFIERINFO` have no uid check — to check; the constant 17 and the struct (56 bytes) — per `<sys/proc_info.h>`, to check |
| M-4 | P1 | `procinfo.rs:79-105` (`ancestry`, `is_descendant_or_self`) | walking ppid down to 0, depth ≤ 4096 | the same + a child's `p_puniqueid` = the parent's `p_uniqueid` (if ppid > 1); any process in the chain with `PROC_FLAG_TRACED` → `None` | a macOS branch of the walk with these two checks; the rest is shared | Whether XNU updates `p_puniqueid` on re-parenting to launchd — to check (if not, compare only when ppid > 1, as proposed). Under a debugger BSD ptrace changes the parent — hence the refusal on `TRACED`; the value of `PROC_FLAG_TRACED` (2) — to check |
| M-5 | P1 | `procinfo.rs:123-132` (`valid_anchor`) | not PID 1, not `systemd`, not a session leader, not an ancestor of the daemon | `systemd` → `launchd` (PID 1 is cut off anyway); sid unknown (0) → not an anchor | `s.pid > 1 && s.sid > 0 && s.sid != s.pid && comm not in {systemd, launchd} && …` | **Check first:** GUI hosts (Claude Desktop, Cursor) launched by launchd are most likely session leaders (`sid == pid`). If `antenna mcp` is launched directly by the app's main process, the binding will be rejected. Then refine rule D-38 no. 7 for both OSes: cut off a session leader **with a controlling terminal** (`PROC_FLAG_CONTROLT` or `e_tdev != NODEV`), while a leader without a terminal with ppid = 1 is fine. The decision is for the team and the review |
| M-6 | P1 | a new crate `crates/antenna-sys` (+ workspace `Cargo.toml`) | — | FFI: `libc::proc_pidinfo`, `libc::getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`, `libc::ptrace(PT_DENY_ATTACH)` | The crate is AGPL-3.0-only, `[lints.rust] unsafe_code = "deny"` (not `forbid`: a local `#[allow(unsafe_code)]` on 3–4 functions with `// SAFETY:`), `libc` only under `cfg(target_os = "macos")`; it exposes safe functions (§2.1) | The workspace has `unsafe_code = "forbid"` (root `Cargo.toml`): FFI without `unsafe` does not exist, and ready-made crates do not fit (§2.2). Needs a team decision and a separate review of the crate (like D-41). Size — about 150 lines |
| M-7 | P1 | `antennad/src/main.rs:61-66`, `antenna-cli/src/main.rs:1355-1356`; packaging | dumpable=0 | `rustix::process::setrlimit(Resource::Core, Rlimit { current: Some(0), maximum: Some(0) })` (no unsafe); `ptrace(PT_DENY_ATTACH, 0, null, 0)` via `antenna_sys::darwin::deny_attach()` (release only: under a debugger the process exits); signing with `codesign --options runtime` | a shared `fn harden()` in both binaries | `PT_DENY_ATTACH` does not prevent reading memory via `task_for_pid` — the real barrier is the hardened runtime (SPEC §13). Whether ad-hoc + runtime signing is enough — to check: `lldb -p $(pgrep antennad)` must be refused |
| M-8 | P1 | `antenna-core/src/agents.rs:263-271` (+ doc at `agents.rs:7-9`) | the message "no /proc entry", the comment "no /proc (not Linux)" | — | text: "cannot read the client's process chain" | Text only; do not touch the behavior (fail-closed) |
| M-9 | P1 | working tree: `procinfo.rs` field `tty` (lines 29-30, 46), `owner.rs:70-93` | `tty_nr` (0 — none), sid, the leader's start time; `systemd` is the parent of orphans | `tty`: `e_tdev` from `proc_pidinfo(pid, PROC_PIDTBSDINFO=3)` (own uid only; `NODEV` = `u32::MAX` → 0); the leader's start — `p_uniqueid` via `UNIQIDENTIFIERINFO` (the leader in Terminal.app is the root process `login`, `PROC_PIDTBSDINFO` will not read it); `launchd` instead of `systemd` | fill `tty` in the macOS `stat()` only for processes of our own uid, otherwise 0 | Check that in Terminal.app, iTerm2 and the VS Code terminal `timed_key` gives `Tty`, and in Claude Code's Bash tool — `Parent` |
| M-10 | P2 | `antenna-core/src/control.rs:173-175` | `peer_cred()` → pid → `ancestry` | `antenna_sys::darwin::peer_audit_token(stream.as_fd())`: `val[5]` = pid, `val[7]` = pidversion; compare with the `p_idversion` of the same PID read together with `p_uniqueid` | `#[cfg(macos)]`: take the pid from the token; pidversion mismatch → `chain = None` | Closes the PID reuse window (the D-41 remainder) on macOS. The moment at which the kernel takes the token (connect or the last process) — to check. The Linux analog is `SO_PEERPIDFD` (kernel ≥ 6.5), a separate task |
| M-11 | P2 | `antenna-core/src/store.rs:416` | `journal_mode = WAL; synchronous = FULL` | SQLite on macOS does `fsync` by default, not `F_FULLFSYNC`: on power loss a commit may be lost → a rollback of the ratchet state (SPEC §7 "Rollback protection") | `#[cfg(target_vendor = "apple")] PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON;` | The cost is commit latency (units to tens of ms on an SSD), measure on a Mac. The keystore and the statefile are written with `File::sync_all`: in std for Apple that is `fcntl(F_FULLFSYNC)` (to check in the std 1.99 sources) |
| M-12 | P2 | `antennad/src/main.rs` after line 60; related to `control.rs:51` | the fd limit is usually 1024 | the soft `RLIMIT_NOFILE` of macOS processes is 256 by default — exactly `MAX_CONNECTIONS` (256), with no headroom for iroh and SQLite | `#[cfg(macos)]`: `getrlimit(Nofile)` → `setrlimit(Nofile, current = min(max, 10240))` (rustix, no unsafe; above `OPEN_MAX` — `EINVAL`) | Check `ulimit -n` in Terminal and for a process launched by the window; whether std raises it by itself — to check |
| M-13 | P2 | `antennad/src/main.rs:93-97` (creating the data directory) | — | Time Machine backs up `~/.local/share/x` → a restore would bring back the old ratchet and link state | `#[cfg(macos)]` once: `Command::new("/usr/bin/tmutil").args(["addexclusion"]).arg(&data_dir)` (no unsafe) | Without `sudo` it sets a "sticky" exclusion as an attribute — check with `tmutil isexcluded <dir>`. A failure is a warning in the log, not an error |
| M-14 | P2 | `antenna-core/src/control.rs:35-48` (`bind`); client `antenna-cli/src/client.rs:219-234` | socket path ≤ 107 bytes (`sun_path` 108) | `sun_path` is 104 bytes → path ≤ 103 bytes; otherwise std/tokio: "path must be shorter than SUN_LEN" | a length check before `bind` with a clear error and the hint `--socket /tmp/…` (the limit per OS) | By default `/Users/<name>/.local/share/antenna/antennad.sock` ≈ 46 bytes — there is headroom; the risk is a long `--data-dir`/`X_DATA_DIR` and the temporary directories `/var/folders/…/T/` (tests ≈ 75 bytes, to check) |
| M-15 | P2 | working tree: `crates/antenna-files/src/sandbox_linux.rs`, `worker.rs:83-89, 447, 581`, `Cargo.toml` (Landlock, seccompiler) | the worker isolates itself: rlimits, dumpable, Landlock, seccomp; `is_isolated()` requires all of them | Seatbelt: launching the worker via `/usr/bin/sandbox-exec -p '<SBPL: deny default, no network and no FS>'` (no unsafe) or `sandbox_init()` (FFI, deprecated but works); rlimits (`CPU`, `FSIZE=0`, `NOFILE`, `CORE=0`) via rustix | `sandbox_macos.rs` + a macOS branch of `is_isolated()` (`seatbelt == true` instead of Landlock/seccomp) | `sandbox-exec` is marked deprecated but exists in macOS 15 — to check. Memory limit: `RLIMIT_AS`/`RLIMIT_DATA` do not work on macOS (to check) → a watchdog in the parent via `proc_pid_rusage` (`ri_phys_footprint`). YARA-X on Pulley without JIT is compatible with hardened runtime (D-F-6) |
| M-16 | P3 | `antennad/src/main.rs:47-55`, `antenna-cli/src/client.rs:219-234` | `$XDG_DATA_HOME/x` or `~/.local/share/x` | the Apple style is `~/Library/Application Support/x` (a space in the path) | **Keep `~/.local/share/x`** on macOS too: the window looks it up the same way (`apps/antenna_desktop/lib/protocol/src/socket_path.dart`), CONTROL §1, D-UI-7, the `ssh -L` instructions | A team decision. Pitfall: apps started from the Dock/Finder do not see variables from `.zshrc` (`XDG_DATA_HOME`, `X_DATA_DIR`) — the window and `antennad` started from a terminal will diverge. An option: ignore `XDG_DATA_HOME` on macOS |
| M-17 | P3 | `antenna-core/src/policy.rs:161-185` (`PROTECTED_PATHS`) | `.config/`, `.bashrc`, `.local/share/x/` … | MCP host configs on macOS live in `~/Library/Application Support/Claude/` (tokens are there), `…/Code/User/`; autostart — `~/Library/LaunchAgents/`; zsh — `.zprofile`, `.zshenv`, `.zlogin` | add (in lower case: `protected()` lowercases): `library/application support/claude/`, `library/application support/code/user/`, `library/launchagents/`, `.zprofile`, `.zshenv`, `.zlogin` | Now it affects only the reason (`tainted:protected_path`), the verdict is the same — approval (`policy.rs:212-224`). On case-insensitive APFS, `in_link_folder` (`policy.rs:188-197`) is stricter, not looser — safe |
| M-18 | P3 | `docs/CONTROL.md` §1, §3, §11 item 2; D-28 (the last sentence); doc comments in `procinfo.rs:5-7`, `control.rs:2`, `agents.rs:7` | "SO_PEERCRED", "start time from `/proc`", "Outside Linux there is no binding" | — | "SO_PEERCRED / `getpeereid` + `LOCAL_PEEREPID`"; "`/proc` (Linux) or `proc_pidinfo` (macOS, `p_uniqueid` instead of the start time)"; "outside Linux and macOS" | Only after M-3…M-6, otherwise the document would lie |

In total: **18 changes** (2 — P0, 7 — P1, 5 — P2, 4 — P3) plus tests (§4). Of these, M-9 and M-15 concern the code of slices
3–4, which is not in HEAD yet.

### 2.1. Sketches (pseudocode, not to be copied without checking)

The `libc` signatures were checked against `libc 0.2.189` (`proc_pidinfo(pid, flavor, arg: u64, buf, size) -> c_int`, the
structs `proc_bsdshortinfo`/`proc_bsdinfo`, `LOCAL_PEERTOKEN = 6`, `SOL_LOCAL = 0`, `PT_DENY_ATTACH = 31`,
`ptrace(c_int, pid_t, *mut c_char, c_int)`). `libc` does **not** have `PROC_PIDUNIQIDENTIFIERINFO`,
`proc_uniqidentifierinfo`, `audit_token_t`, `PROC_FLAG_*`, `kinfo_proc` — we declare them ourselves (to check against the
SDK).

```rust
// crates/antenna-sys/src/darwin.rs — a crate with unsafe_code = "deny"
const PROC_PIDUNIQIDENTIFIERINFO: c_int = 17;   // <sys/proc_info.h> — to check
pub const PROC_FLAG_TRACED: u32 = 0x2;          // to check
#[repr(C)] struct UniqInfo { uuid: [u8; 16], uniqueid: u64, puniqueid: u64,
                             idversion: i32, _r2: u32, _r3: u64, _r4: u64 }   // 56 bytes

fn pidinfo<T>(pid: i32, flavor: c_int) -> Option<T>        // #[allow(unsafe_code)]: zeroed T,
                                                           // proc_pidinfo(...) == size_of::<T>() → Some
pub struct Short { pub ppid: i32, pub uid: u32, pub flags: u32, pub comm: String }
pub fn short(pid: i32) -> Option<Short>                    // PROC_PIDT_SHORTBSDINFO (13), any uid (to check)
pub struct Uniq { pub id: u64, pub parent: u64, pub idversion: i32 }
pub fn uniq(pid: i32) -> Option<Uniq>                      // flavor 17, any uid (to check)
pub fn tty_dev(pid: i32) -> Option<u32>                    // PROC_PIDTBSDINFO (3): e_tdev, own uid only
pub fn peer_audit_token(fd: BorrowedFd<'_>) -> io::Result<[u32; 8]>   // getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN), len == 32
pub fn deny_attach() -> io::Result<()>                     // ptrace(PT_DENY_ATTACH, 0, null_mut(), 0)
```

```rust
// crates/antenna-core/src/procinfo.rs — the macOS branch (the Linux branch does not change)
#[cfg(target_os = "macos")]
pub fn stat(pid: i32) -> Option<ProcStat> {
    if pid <= 0 { return None; }
    let u1 = darwin::uniq(pid)?;
    let s  = darwin::short(pid)?;
    let u2 = darwin::uniq(pid)?;
    if u1.id != u2.id || s.flags & darwin::PROC_FLAG_TRACED != 0 { return None; }   // PID changed / under a debugger
    let sid = rustix::process::getsid(rustix::process::Pid::from_raw(pid))          // EPERM for another uid → 0 (to check)
        .map_or(0, |p| p.as_raw_nonzero().get());
    Some(ProcStat { pid, comm: s.comm, ppid: s.ppid, sid, start: u1.id /*, tty: slice 3, M-9 */ })
}
// ancestry (M-4): as on Linux, plus for ppid > 1: uniq(ppid).id == u1.parent, otherwise None.
```

```rust
// antennad/src/main.rs and antenna-cli/src/main.rs (M-1, M-2, M-7, M-12)
fn harden() {
    #[cfg(target_os = "linux")]
    let r = rustix::process::set_dumpable_behavior(rustix::process::DumpableBehavior::NotDumpable);
    #[cfg(not(target_os = "linux"))]
    let r = rustix::process::setrlimit(rustix::process::Resource::Core,
                                       rustix::process::Rlimit { current: Some(0), maximum: Some(0) });
    #[cfg(all(target_os = "macos", not(debug_assertions)))]
    let r = r.and_then(|()| antenna_sys::darwin::deny_attach());
    if let Err(e) = r { eprintln!("warning: cannot disable core dumps / debugger attach: {e}"); }
}
```

### 2.2. Why not ready-made crates and not `ps`

| Option | License | Why not |
| --- | --- | --- |
| `libproc` (libproc-rs) | MIT | A safe API, but from memory it generates bindings with `bindgen` in build.rs (needs libclang) and reads `PROC_PIDTBSDINFO` — `EPERM` on root ancestors (M-3). Whether it has flavors 13 and 17 — to check. Fits only if it supports both |
| `sysinfo` | MIT | Heavy (refreshes the list of all processes), start time in seconds, inside the same `proc_pidinfo` with the uid check |
| `ps -o ppid=,lstart=,comm= -p <pid>` as a subprocess | — | No unsafe and works for any uid, but a fork+exec for every ancestor (tens of ms per connection), text parsing, one-second precision |
| The private TCC "responsible process" (`responsibility_get_pid_responsible_for_pid`) | — | A private API, it points to the app (`.app`), not to the CLI host |
| Endpoint Security | — | Needs an entitlement from Apple, a system extension and root |

The best of what is available is what `ps` and Activity Monitor do: `proc_pidinfo` plus the audit token, as in XPC. That
is what is proposed (M-3, M-6, M-10); `libc` is MIT OR Apache-2.0 and is already in the dependency tree transitively.

### 2.3. The macOS sandbox — Seatbelt (2026-10-03; DECISIONS D-P-12…D-P-14)

| What | How |
| --- | --- |
| Mechanism | `sandbox_init(profile, 0, &err)` — SBPL text, the process and its descendants are in the sandbox forever (`antenna_sys::seatbelt::apply`, the only FFI). `sandbox-exec` is not used: the same engine, and self-isolation from inside is the same model as Landlock |
| File check worker | the profile `antenna_files::seatbelt::worker_profile` — `(deny default)`, reading only system libraries and its own binary; rlimits; a probe from inside (`/` — `EPERM`); memory — a daemon watchdog (`phys_footprint`, 50 ms) |
| Antivirus (`av-exec`) | the profile `av_exec_profile`: system paths and `--ro` — reading and executing, writing — the check directory, no network |
| Agent on wake | the supervisor outside the sandbox (the bridge to the proxy, the lifeline) → stage 2: `setsid`, rlimits, the profile `antenna_core::sandbox::seatbelt::agent_profile`, a probe → `exec`; orphans — `sandbox_check` by the run label |
| Paths | real ones (`/var` → `/private/var`, `/tmp`, `/etc`): every path in two forms (`seatbelt::path_forms`) |
| Checking without a Mac | the profile text — unit tests on Linux (`cargo test -p antenna-files --lib seatbelt`, `-p antenna-core --lib sandbox::seatbelt -- --nocapture` prints the agent profile); types — `tools/check-darwin.sh` |

**Assumptions checked by the first CI run** (the `FACT` lines, the "Sandbox …" steps of the `core` job): (1) `sandbox_init`
with flag 0 compiles the SBPL text and refuses a malformed profile (`antenna-sys` `apply_denies_what_the_profile_denies`);
(2) the operations and filters of the profiles (`file-map-executable`, `sysctl-name-prefix`, `require-not`, `(literal …)`
on `network-outbound` for a unix socket, `(remote ip "localhost:PORT")`, `(target same-sandbox)`) are known to the
macOS 14 kernel; (3) `sandbox_check` is exported and sees a child's profile (`FACT sandbox_check …`); (4)
`ri_phys_footprint` grows with written memory (`FACT phys_footprint`); (5) ordinary programs (`/bin/sh`, `curl`, `perl`,
`grep`, `antenna`) work under the agent profile — whether `SYSTEM_READ`/`ETC_READ`/sysctl/Mach are enough (the `wake*.rs`
tests); (6) a real `claude -p` in Seatbelt — only manually on the maintainer's Mac (CI does not spend the subscription):
login via `CLAUDE_CODE_OAUTH_TOKEN` (the keychain is closed).

## 3. Dependencies and building on macOS

| Dependency | What is needed on a Mac | Note |
| --- | --- | --- |
| Toolchain | `rustup`; `rust-toolchain.toml` pins 1.99.0 (`minimal`, clippy, rustfmt) | `rustup toolchain install` without arguments installs the version from the file (rustup ≥ 1.28; in older ones — `rustup show`; check on the runner image). Targets: `rustup target add aarch64-apple-darwin x86_64-apple-darwin` (do not add them to `rust-toolchain.toml` — Linux would download extra) |
| Xcode Command Line Tools | `xcode-select --install`: clang, `make`, `ar`, `lipo`, `codesign`, SDK | Needed by all the C parts below |
| `aws-lc-sys 0.45.0` (rustls, iroh) | only a C compiler | On macOS the default is `CcBuilder`, with ready bindings for both darwin targets — **neither cmake nor bindgen/libclang is needed** (`builder/main.rs`: cmake only for FIPS, `AWS_LC_SYS_CMAKE_BUILDER=1`, no-asm, sanitizers). Jitterentropy needs the CoreServices header (in the SDK). Auto-detection of a system AWS-LC via `OPENSSL_DIR`/pkg-config — for reproducibility, `AWS_LC_SYS_USE_SYSTEM=0` |
| `libsqlite3-sys 0.38.2` (`bundled-sqlcipher-vendored-openssl`) → `openssl-sys 0.9.117` → `openssl-src 300.6.1` | `perl` (the system `/usr/bin/perl`) and `make` from the CLT | Targets `darwin64-arm64-cc` / `darwin64-x86_64-cc`; openssl-src removes the `-arch` flag itself. The first build ≈ 50 s (TROUBLESHOOTING). Do not set `OPENSSL_DIR` in the environment |
| `libsignal-protocol`, `spqr` (git) | `protoc`: `brew install protobuf` (or `PROTOC=<path>` to the official `osx-universal_binary`) | prost-build 0.14 does not ship protoc (TROUBLESHOOTING "Build and environment", the entry "libsignal and spqr need `protoc`"). Git dependencies are fetched from github.com — the runner needs network access |
| `libcrux-*`, `blake3`, `ring` | a C compiler | SIMD is selected at runtime. Under Rosetta 2 AVX2 may be missing — a fallback to portable code (check the test speed) |
| `iroh 1.3`, `netwatch`, `netdev`, `n0-dns-resolver`, `rustls-platform-verifier` | the SystemConfiguration, Security, CoreFoundation frameworks (in the SDK) | iroh officially supports macOS. **macOS 15 "Local Network":** `antennad` launched by the window counts as part of the app; without the permission, direct LAN addresses and UPnP/NAT-PMP silently do not work (the relay works). To check; `NSLocalNetworkUsageDescription` may be needed in `apps/antenna_desktop/macos/Runner/Info.plist` |
| `crabgrind` (bindgen) | — | Only under `cfg(valgrind_ct_test)` in `libcrux-secrets` — not built |
| `rmcp 3.5`, `tokio 1.53`, `rustix 1.1`, `clap`, `tracing` | — | Pure Rust, they support darwin |

**Build environment variables:** `MACOSX_DEPLOYMENT_TARGET=12.0` (as for the window, `Runner.xcodeproj`: 12.0; otherwise
Rust takes 11.0 for arm64 and 10.12 for x86_64, and the C parts — whatever the SDK gives), `AWS_LC_SYS_USE_SYSTEM=0`.

### 3.1. Type checking for macOS from Linux (`tools/check-darwin.sh`, D-P-7)

`cargo check --target aarch64-apple-darwin` on Linux fails on the build scripts of C dependencies: `ring`, `blake3` (`cc`
without `-arch`), `aws-lc-sys` (no SDK), `openssl-sys` → `openssl-src` (configure/make for darwin), then `libsqlite3-sys`
(SQLCipher). The script works around this with standard Cargo means, without touching the manifests:

| Dependency | How | Why it is honest |
| --- | --- | --- |
| `aws-lc-sys` (`links = "aws_lc_0_45_0"`) | overriding the build script: `rustc-cfg = ["aarch64_apple_darwin"]` → the crate takes the ready bindings for this target from its sources; `include` — for `aws-lc-rs` | the same bindings as on a Mac (`CcBuilder` does not generate them) |
| `ring`, `openssl-sys`, `libsqlite3-sys` | overriding the build script (`rustc-link-lib = []`; for `openssl-sys` — the OpenSSL 3.6 cfg); `libsqlite3-sys` — the ready bindings `bindgen_bundled_version.rs` in OUT_DIR | the Rust API of these crates does not depend on the C build; there is no linking during check |
| `blake3` | `--features blake3/pure` (no C/NEON) | changes only the hash implementation, not our code |
| `wasmtime` (YARA-X in antenna-files, after stage B) | `CC_<target>=clang`, `CFLAGS_<target>=-ffreestanding -isystem <stub stdlib.h>` for `helpers.c` | the object is only needed by the build script; without clang, antenna-files is skipped with a warning |

Result: `tools/check-darwin.sh [clippy|check] [--release] [target…]` checks the types and clippy of our code for both darwin
targets. It does not check: building the C parts, linking with frameworks, behavior — that is CI. Time: ≈ 15 s per target
after the first run.

**Cross arm64 ↔ x86_64.** On an arm64 runner (macos-14/15) x86_64 is built with the same Xcode:
`--target x86_64-apple-darwin`, the C parts get `-arch x86_64` from `cc`. x86_64 tests — on an Intel runner (label
`macos-15-intel`, GitHub's last Intel image — check that it is current) or under Rosetta 2
(`softwareupdate --install-rosetta --agree-to-license`, if it is not on the image — to check). Building darwin from Linux
is not possible: the build.rs of `aws-lc-sys`/`openssl-src` compile C against Apple's SDK (osxcross and cargo-zigbuild are
not considered: the SDK license, and aws-lc disables jitterentropy).

**Universal.**

```sh
cargo build --release --locked -p antennad -p antenna-cli --target aarch64-apple-darwin --target x86_64-apple-darwin
mkdir -p dist
for b in antennad antenna; do
  lipo -create -output "dist/$b" "target/aarch64-apple-darwin/release/$b" "target/x86_64-apple-darwin/release/$b"
  lipo -info "dist/$b"                                   # Architectures in the fat file: x86_64 arm64
  codesign --force --options runtime --sign - "dist/$b"  # ad-hoc + hardened runtime; for distribution — Developer ID
  codesign -dv --verbose=4 "dist/$b" 2>&1 | grep -i flags   # expect adhoc,runtime
done
```

For the window bundle, the binaries go into `Antenna.app/Contents/Helpers/` (`apps/antenna_desktop/lib/host/binaries.dart`)
and are signed before the `.app` itself. After `strip` or any change to a binary the signature is re-created
(`codesign -v` must pass).

**Signing and notarization — a question for the maintainer.** Without notarization, a binary downloaded by a browser gets
the quarantine attribute, and Gatekeeper will not run it (workaround — "Open Anyway" in the settings or
`xattr -d com.apple.quarantine`); what is downloaded with `curl` does not get quarantined. Notarization requires an Apple
Developer ID in the **real name** of a person, or of an organization with a D-U-N-S number, and that name is visible in
the signature (`codesign -dv`). The way out is an organization under the project's name (SPEC §16).

## 4. Tests

**Mark or rewrite:**

| Test (HEAD) | What it does | What to do |
| --- | --- | --- |
| `antenna-core/src/procinfo.rs:150-174` `own_process_is_alive_and_descends_from_parent` | our own chain up to PID 1, liveness, a forged start time | already `cfg(target_os = "linux")` → `any(target_os = "linux", target_os = "macos")` together with M-3. On macOS `start + 1` is a different `p_uniqueid`, the test logic is the same |
| `antenna-core/src/procinfo.rs:138-148` `parses_comm_with_spaces_and_parens` | parsing the `/proc/<pid>/stat` line | works everywhere; `parse_stat` can stay shared |
| `antenna-cli/tests/agents.rs:77-211` `agent_has_no_owner_api_in_cli_protocol_mcp_or_its_process_tree` | part 3 — `Mcp::start` (line 121), part 4 — the MCP host's tree via `sh` (lines 149-210) | needs M-3…M-5. If the port lags behind CI on a Mac — `#[cfg_attr(not(target_os = "linux"), ignore = "D-28: needs procinfo for this OS")]`; better to make the port and enable the test in one change |
| `antenna-cli/tests/agents.rs:213-317` `mcp_over_stdio_reads_wrapped_messages_taints_the_session_and_replies` | real MCP over stdio | the same (`antenna mcp` with `bind_parent`) |
| `antenna-cli/tests/agents.rs:861-1031` `claude_code_hook_enforces_the_session_ceiling` | the hook with a token (portable), without a token outside the tree (portable), without a token **inside the tree** of `antenna mcp` (lines 997-1020) | move lines 997-1020 into a `#[cfg(any(target_os = "linux", target_os = "macos"))]` block or into a separate test |
| `antenna-cli/tests/common/mod.rs:317-343` `Mcp::start` | `sh -c '"$X_BIN" … mcp; e=$?; exit $e'`, so that the parent is `sh` | on macOS `/bin/sh` is a shim that launches bash 3.2 via exec: the PID is the same, `comm` = `bash`; the construct without the exec optimization works. No need to change it |
| `antenna-cli/tests/history.rs` `owner_needs_a_session…` (slice 3) | `Command::new("setsid")` — a util-linux program | **Done 2026-10-02:** macOS has no `setsid` program — the same via `/usr/bin/python3 -c 'os.setsid(); os.execvp(…)'` |

**Portable as is:** `antennad/tests/daemon.rs` (permissions `0600`/`0700`, files without group access — the same on
macOS; a tempdir under `/var/folders/…` fits into 104 bytes), `antenna-cli/tests/control.rs`, `link.rs`, `cli.rs`,
`relay.rs` (`#[ignore]`, network), `common/mod.rs:145-163` (SIGTERM via `rustix::process::kill_process`), the rest of the
`agents.rs` tests (token, policy, approval, presence), the unit tests of `antenna-proto`, `antenna-core` (except
`procinfo`), the working tree's `owner.rs` (synthetic `ProcStat`).

**New (together with M-3…M-10, macOS only):**
1. `stat(getpid())` — the `comm` of our binary (≤ 15 characters), `ppid == getppid()`, `uid == geteuid()`.
2. `stat(1)` — readable (`launchd`, root) without `EPERM`; `ancestry(getpid())` ends at PID 1. This is the check of the
   key assumption of M-3 — on a CI runner the chain goes through processes of another uid.
3. `is_alive` for our own anchor, and `false` for `start + 1`; a child (`sh -c 'sleep 5'`) is a descendant; after it dies
   `is_alive` is false even if the PID is reused (by `p_uniqueid`).
4. The link to the parent: a child's `p_puniqueid` = the test's `p_uniqueid`.
5. `peer_audit_token` on a `UnixStream::pair()`: `val[5] == getpid()`.
6. `getsid(1)` — record the actual behavior (a number or `EPERM`) in the test and in TROUBLESHOOTING.

## 5. The order of the changes (after slices 3–4) and checking on a Mac

1. **Wait for slices 3 and 4 to be committed** (owner.rs, `tty` in procinfo, antenna-files stage B in the root workspace).
   Until then, do not touch `crates/`.
2. **Manual experiments on the maintainer's Mac (before the code, 10 minutes).** They confirm or refute the "to check"
   assumptions; the results go into TROUBLESHOOTING:
   ```sh
   ps -o pid,ppid,user,comm -p $$ -p $PPID      # in Terminal.app, is the shell's parent the root process login?
   python3 -c 'import os; print(os.getsid(1), os.getsid(os.getppid()))'   # getsid for another uid: a number or PermissionError
   ulimit -n; launchctl limit maxfiles          # expect a soft limit of 256
   # Claude Desktop: a temporary MCP server that records its parent and the parent's session
   #   "command": "/usr/bin/python3", "args": ["-c", "import os;p=os.getppid();open('/tmp/mcp-parent.txt','a').write(f'{p} {os.getsid(p)}\\n')"]
   #   then: ps -o pid,ppid,comm -p <p>   — is the main process a session leader (M-5)?
   ```
3. **P0 (M-1, M-2 + the safe part of M-7: `RLIMIT_CORE`).** Only `cfg` and rustix, no new crate. Check:
   `cargo build --workspace --locked` and `cargo test --workspace --locked` on a Mac (the §4 tests with `antenna mcp` are
   `ignore` for now). A cheap preliminary check from Linux was **done 2026-10-02** (HEAD `fa00839`, in a `git archive`
   copy):
   `rustup target add aarch64-apple-darwin && cargo check --target aarch64-apple-darwin -p antenna-proto -p antenna-cli`
   — no SDK was needed; `antenna-proto` checks clean, `antenna-cli` fails exactly on M-2
   (`E0425 set_dumpable_behavior`, `E0433 DumpableBehavior`, `antenna-cli/src/main.rs:1356`) — no other errors.
   `antennad` and `antenna-core` cannot be checked this way (C dependencies).
4. **P1 (M-6 → M-3, M-4, M-5, M-8, M-9, the rest of M-7).** The `antenna-sys` crate as a separate commit, then procinfo and
   the §4 tests. Mandatory — an independent security review (like D-38/D-41): the unsafe code, fail-closed, the anchor rule.
   Check on a Mac: `cargo test -p antenna-core procinfo`, `cargo test -p antenna-cli --test agents`, then manually — Claude
   Code with `antenna mcp` in `~/.claude.json`: `antenna agent list` shows `bound_to: <pid> claude`; from the agent's Bash
   tool `antenna trust bob 5` → "no such command here … process tree of agent"; `lldb -p $(pgrep antennad)` on a release
   build — refused.
5. **P2 (M-10…M-15).** `fullfsync` with a measurement of the `antenna send` latency before/after;
   `tmutil isexcluded ~/.local/share/antenna`; a long `--data-dir` → a clear error; the fd limit
   (`lsof -p $(pgrep antennad) | wc -l` under load); antenna-files selftest under Seatbelt.
6. **P3 and documents (M-16…M-18):** CONTROL §1/§3/§11, new DECISIONS and TROUBLESHOOTING entries (§7).
7. **CI (the workflow is prepared locally, not pushed yet).** Matrix: `macos-15` (arm64, `cargo test` + clippy) and an
   Intel runner or Rosetta (x86_64, `cargo test`); a separate job — universal + signing (§3). On the runner: the CLT is
   already there, `brew install protobuf`, `rustup toolchain install`, `rustup target add …`, the variables from §3.
   `cargo clippy --workspace --all-targets --locked -- -D warnings` is needed on both OSes: clippy on Linux does not see
   the `cfg` branches of the other OS. **Done 2026-10-02:** the `core` job (now in `release.yml`) — `macos-14` (arm64)
   always and `macos-15-intel` (x86_64) by the `intel` flag on a manual run; steps: the runner environment (`ulimit -n`,
   `getsid`), the build, clippy `-D warnings`, XNU facts (`cargo test -p antenna-sys`, `-p antenna-core procinfo` with
   `--nocapture`), all core tests, `tools/mcp_smoke.py` (a live `antenna mcp`: initialize, tools/list, `get_session`, the
   binding to the host in `antenna agent list`, no owner commands), informational — the GUI host on Calculator and `lldb`
   on the release `antennad`.

## 6. Questions for the team and the maintainer

1. **unsafe in the workspace** (`unsafe_code = "forbid"`): allow a separate crate `antenna-sys` with `deny` + local
   `allow`s and a mandatory review (recommended), or live on macOS without D-28 (as currently recorded in CONTROL §11)?
2. **The anchor rule for GUI hosts** (M-5): if Claude Desktop or Cursor on a Mac are session leaders, refine D-38 no. 7
   ("a session leader with a terminal")? Decide after the experiment from §5 step 2.
3. **The data directory** (M-16): decided — `~/.local/share/<name>` on macOS too (D-P-5); after the rename —
   `~/.local/share/antenna` with a one-time migration from `~/.local/share/x` (D-56).
4. **Notarization and the name in the signature** (§3): a Developer ID requires a real name — whose name goes into the
   signature?
5. **Time Machine** (M-13): exclude the directory automatically (recommended, per SPEC §8 and §15, "the database outside backups") or
   ask during `antenna init`?

**Answers (2026-10-02):** item 1 — team: `antenna-sys` (D-P-1); item 2 — team: the conservative option, done (D-P-3: a
session leader only if it is a GUI host `.app` launched by launchd without a terminal); items 3 and 5 — the audit's
recommendations were accepted (D-P-5), to be revisited on the word of the team or the maintainer; item 4 — open (for the
maintainer).

## 7. What to move into DECISIONS and TROUBLESHOOTING after checking on a Mac

- DECISIONS — **moved** (D-P-1…D-P-7, 2026-10-02). The facts of the first CI run on a Mac (`FACT …` of the `core` job) —
  **moved** into TROUBLESHOOTING "First run of `release.yml` on GitHub" (2026-10-02), the confirmed "to check" marks were removed
  (§2.0).
- TROUBLESHOOTING: `set_dumpable_behavior` exists only on Linux (rustix `prctl` under `linux_kernel`); `antenna mcp` on
  macOS without procinfo is always `token_bound`; tokio `peer_cred().pid()` on macOS is `LOCAL_PEEREPID`; `sun_path` is 104
  bytes; the soft `RLIMIT_NOFILE` is 256; SQLite without `fullfsync` is not durable on power loss; the results of the
  experiments of §5 step 2.
