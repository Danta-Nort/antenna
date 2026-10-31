<!-- SPDX-License-Identifier: Apache-2.0 -->
# Signed releases and `antenna update`

Status: **draft, format 1** (2026-10-03, DECISIONS D-82). License: Apache-2.0: this document is enough to verify an
Antenna release without Antenna, or to write another updater. The reference implementation is
`crates/antenna-update` (format, verification, installer), `crates/antenna-release` (the release side) and
`crates/antenna-cli/src/update.rs` (the command). If the code and this document disagree, that is a bug.

SPEC §13: "the release signing key is built into the binary, … and an update is installed only on the owner's
`antenna update` command. Without this, the update channel is remote code execution for whoever takes it over." SPEC
§15: "Substitution of the update channel — built-in signing key, two signatures, update only on command". Amended by
the maintainer (D-103): a signed update may also install by itself when the owner turned that on for the computer
(§8, experimental, off by default).

## 1. What protects what

| Threat | Protection |
| --- | --- |
| A forged release (a file from a contact, a compromised download page, a man in the middle) | The release manifest is signed with a release key whose public half is pinned in the installed binary (§3, §4). Nothing else is trusted: not the file name, not who sent it, not TLS |
| A real file of another release or platform | The manifest lists every file with its size, SHA-256 and BLAKE3; the installer takes only the file for its own OS, architecture and kind (§2) |
| Downgrade to an older signed release with known bugs | Only a strictly newer version is installed (Semantic Versioning precedence, §5.1); going back is the separate, explicit `--rollback` |
| The file is replaced between the check and the install | The installer copies the file into its own staging folder and checks the copy; it never reads the original again (§5.2) |
| An agent installs an update | `antenna update` is an owner command: it is not in the agent CLI or MCP; the daemon checks the owner password or session (§5.3) |
| A contact or an agent makes a computer install something by itself (§8) | Only when the owner turned it on there, with the password; only a release that `antenna update` would accept (pinned key, strictly newer, this platform's file); the files count only from a level-5 contact (the owner's own computer); nothing else is remote: no downgrade, rollback, same version, URL, key, setting or unlock |
| The keys across an automatic install's restart (§8.3) | The root key stays in memory and goes to the new process through one inherited pipe; never written to disk; the new process opens the database with it or stays locked |
| A half-done update | Every replacement is an atomic swap; a journal written before the first change lets the next `antenna update` put the old version back (§5.4) |
| The release key leaks | Rotation: the binary pins a list; a new key is added in one release and the old one removed later (§4). A leaked key still needs a newer version number to be installed, and only on the owner's command, or by itself where the owner turned that on (§8): with one release signature, a stolen key installs on every such computer, so automatic installs in a public release wait for the second key (D-103 item 5) |

**Not covered.** A *freeze*: someone who controls the channel can withhold new releases (an updater that only fetches
on command cannot tell "no update" from "update withheld"). A process with the owner's uid can replace the binaries
directly, signed or not: the signature protects the update channel, file permissions protect the installed files. The
macOS app is ad-hoc signed (no Apple Developer ID yet): `codesign --verify` proves the bundle is intact, not who built
it; that is what the release signature is for. Builds are not reproducible yet (SPEC §15).

## 2. The release manifest `antenna-<version>-manifest.json`

UTF-8 JSON. The signature covers the **exact bytes of the file**; a verifier never re-serializes it.

| Field | Meaning |
| --- | --- |
| `format` | `antenna-release-manifest/1`. Anything else is refused: a change in what a field means is a new format |
| `product` | `antenna` |
| `version` | `MAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH-PRE` (no build metadata), as `antenna --version` prints it |
| `channel` | `preview` or `stable`; a pre-release version is never `stable` |
| `created` | UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `commit` | the build commit as `antenna --version` prints it: lowercase hex, 7–40 characters |
| `assets[]` | 1–64 files: `name` (a plain file name: `[A-Za-z0-9._+-]`, no leading dot, ≤ 200 characters, containing `-<version>-`, unique), `os` (`macos`, `linux`), `arch` (`arm64`, `x86_64`, `universal` for macOS), `kind` (`app`: the window with the core; `cli`: the CLI and the daemon only), `size` (1 byte … 4 GiB), `sha256` and `blake3` (64 lowercase hex) |
| `models[]` | optional (preview.8, D-104): the catalog of local models the release's daemon was built with, the `models` of `packaging/models.json` as is (each with its Hugging Face repository, commit, file, size and SHA-256). `antenna-release manifest --models` copies it in after the daemon's own strict check, `verify --models` refuses a manifest whose list differs; a release without local models has no field, and older readers ignore it |

Fields a reader does not know are ignored, so a later release may add information. Values of `os`, `arch`, `kind` a
reader does not know are skipped: a future `windows` asset does not make the manifest unreadable. A field that appears
twice is an error. At most 64 KiB.

Release files and their platforms (the names `packaging/` produces):

| Name | `os` | `arch` | `kind` | Installed by |
| --- | --- | --- | --- | --- |
| `Antenna-<v>-macos-<arch>.dmg` | `macos` | `arm64` / `x86_64` / `universal` | `app` | `antenna update` from inside `Antenna.app` |
| `antenna-<v>-macos-<arch>-cli.tar.gz` | `macos` | as above | `cli` | `antenna update` from a `bin/` with `antennad` next to it |
| `antenna-<v>-linux-<arch>.tar.gz` | `linux` | `x86_64` / `arm64` | `cli` | `antenna update` in the `install.sh` layout |
| `antenna-desktop-<v>-linux-<arch>.tar.gz` | `linux` | as above | `app` | not yet: unpack the new archive in place |
| `antenna-<v>-linux-<arch>.deb` / `.rpm` | `linux` | as above | `deb_cli` / `rpm_cli` | the package manager (D-109): never `antenna update` |
| `antenna-desktop-<v>-linux-<arch>.deb` / `.rpm` | `linux` | as above | `deb_app` / `rpm_app` | the package manager (D-109): never `antenna update` |

`SHA256SUMS.txt`, `*.sha256`, the manifest and its signature are not assets. The `.deb`/`.rpm` kinds exist only so
these files can be listed, signed and verified like the others; `antenna update`'s own platform matching
(`Platform::fits`, §5.1 item 4) never asks for them, so they can never be chosen as "the asset for this
installation" — a packaged install is found a different way (§5.2) and refuses to update itself.

## 3. The signature `antenna-<version>-manifest.json.sig`

```json
{
  "format": "antenna-release-signature/1",
  "signatures": [ { "key_id": "04e28f3f8c0bb3bf", "sig": "<base64 of 64 bytes>" } ]
}
```

- `sig` is Ed25519 (RFC 8032; verified with strict checks, `ed25519-dalek` `verify_strict`) over
  `"antenna/release-manifest/v1" ‖ 0x00 ‖ <the manifest file bytes>`. The context keeps a release signature from being
  valid as anything else the same key could sign; a plain Ed25519 signature over the file is not a release signature.
- `key_id` is the first 8 bytes of SHA-256 of the 32-byte public key, lowercase hex. It only says which key to try; a
  signature counts only if it verifies with that pinned key.
- 1–16 signatures, one per key. A manifest is accepted when at least `REQUIRED_SIGNATURES` distinct pinned keys signed
  it (today 1; §4). A signature by a key the verifier does not pin is ignored. At most 16 KiB.

Checking a release by hand, with the release's public key in base64 in `$PUB`:

```sh
python3 - "$PUB" antenna-1.0.0-manifest.json <<'EOF'
import base64, json, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
key = Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[1]))
manifest = open(sys.argv[2], "rb").read()
for s in json.load(open(sys.argv[2] + ".sig"))["signatures"]:
    key.verify(base64.b64decode(s["sig"]), b"antenna/release-manifest/v1\x00" + manifest)  # raises if invalid
print("signature ok")
EOF
sha256sum Antenna-1.0.0-macos-arm64.dmg   # compare with "sha256" in the manifest
```

With OpenSSL 3: the message is the context, a zero byte and the file; `openssl pkeyutl -verify -pubin -inkey pub.pem
-rawin -in msg.bin -sigfile sig.bin` (the public key as a PEM SubjectPublicKeyInfo, the signature decoded from base64).

## 4. Keys

- **Release keys are pinned in the binary** (`crates/antenna-update/src/keys.rs`, `RELEASE_KEYS`): a list of
  `{id, public (base64), added (date)}`. A release may be signed by any listed key.
- **Rotation.** A new key is pinned in release N while the old one still signs; from N on, releases are signed by
  both (the signature file holds several); once the installations that matter run N or later, the old key is removed
  from the list in a later release and stops signing. An installation older than N keeps trusting only the old key,
  so the old key must keep signing until those installations are gone or updated.
- **No key, no update.** With an empty list the binary refuses every update (`no_release_key`): it fails closed.
- **The test key.** Its 32-byte seed is the ASCII string `antenna-update public TEST key!!`; public key
  `oDYEhCKnP+yuyAmJpBTguxGjTqOuDsKDLE/olFiV+Ds=`, id `04e28f3f8c0bb3bf`. It signs test fixtures. Only debug builds
  contain the code that trusts it, and only when `ANTENNA_UPDATE_TEST_KEY=1`; a release build never does
  (`packaging/linux/check-install.sh` checks the built release binary). It can never be put into `RELEASE_KEYS` (a unit
  test and the loader both refuse it).
- **Two keys (SPEC §13).** The format carries several signatures and the threshold is one constant; today one key and
  one signature are required. Raising it to two is open (D-82).

## 5. Installing: `antenna update`

```
antenna update                                    installed version, previous version, pinned keys, update URL
antenna update --from <folder | files…> [--dry-run | --manifest-only]
antenna update --from … [--yes] [--password-stdin]
antenna update --rollback [--yes] [--password-stdin]
antenna update --check [--url <manifest URL>] [--download <folder>]
```

`--from` takes a folder (the newest `antenna-<v>-manifest.json` in it, by version) or the files: the manifest, its
`.sig` (default: next to the manifest) and the asset (default: next to the manifest under its published name; a file
given explicitly is matched by its SHA-256, whatever its name). `--dry-run` verifies and prints the plan;
`--manifest-only` checks only the manifest's signature (the asset may be absent; an older version is reported, not
refused). `--json` prints one JSON object on stdout; progress goes to stderr and to the log.

### 5.1 Verification, in this order

1. The signature over the exact manifest bytes, with the pinned keys (§3).
2. The manifest fields (§2).
3. The version: strictly newer than the running one (SemVer 2.0 §11 precedence: `0.1.0-preview.9 < 0.1.0-preview.10 <
   0.1.0`).
4. The asset for this installation (OS, architecture, kind), and its size, SHA-256 and BLAKE3.

### 5.2 Installation

The installation is found from the running `antenna`: inside `Antenna.app/Contents/Helpers/` → the app; a `bin/`
with `antennad` next to it → the binaries. A development build in `target/`, the Linux window bundle, an app running
from the disk image or from a translocated copy cannot update itself (the reason is shown); neither can a `.deb`/
`.rpm` install (D-109): it looks exactly like the `bin/` layout above (`antennad` next to `antenna`), so it carries
one extra file, `bin/.antenna-package` (`antenna_update::install::target::PACKAGE_MARKER`), that the two packages'
build scripts add and the archives never do — its presence, not its content, tells `antenna update` to refuse
(`unsupported_install`) and name the package manager instead of touching files `dpkg`/`rpm` track.

Next to what is replaced (on the same file system, so that the swap is atomic) the installer creates a private
staging folder `.antenna-update/` (0700, locked: one update at a time), copies the asset there and checks the copy.

**macOS app.** Mount the `.dmg` read-only (`hdiutil attach -readonly -nobrowse -noautoopen`), copy `Antenna.app` into
the staging folder (`ditto --noqtn`: the copy carries no quarantine flag; the image was verified instead), unmount;
check the copy: `codesign --verify --deep --strict`, `CFBundleIdentifier` is `io.github.danta-nort.antenna`,
`CFBundleShortVersionString` is the numeric part of the version, and the bundled `antenna` and `antennad` print exactly
the manifest's version and commit. Then close the window if it runs (SIGTERM), stop the daemon (`launchctl bootout` of
the window's LaunchAgent `io.github.danta-nort.antenna.daemon`), swap the bundles atomically (`renamex_np(RENAME_SWAP)`),
keep the old one as `Antenna.app.previous` (one previous version is kept), start the daemon (`launchctl bootstrap`) and
wait until it answers with the new version, then open the window again if it was running.

**`install.sh` layout (Linux, and the macOS CLI archive).** Unpack the archive in the staging folder, check that
`bin/antenna` and `bin/antennad` print the manifest's version and commit; stop the systemd user service
`antennad.service` if `install.sh` installed it for this `antennad` and it runs; swap `antennad`, then `antenna`
(`renameat2(RENAME_EXCHANGE)`), keep the old ones as `antennad.previous` and `antenna.previous`; when the archive has
the local model runtime (`bin/llama/`, D-104), swap the folder `llama/` the same way and keep `llama.previous` (a
rollback brings it back); start the service and wait until the daemon answers with the new version. A daemon started by hand is left running (the installer does not
know its arguments): restart it.

A daemon that does not answer with the new version within 30 s means the old version is swapped back and started
again. **After a restart the daemon's keys are locked, as after a reboot.**

### 5.3 Who may update

Installing needs a running, unlocked daemon: the CLI sends the owner command `update_authorize` (CONTROL §19) with the
owner password (`--password-stdin`, or asked in a terminal) or within an owner session, and the daemon also says which
executable it runs, so the installer knows whether it belongs to the installation being replaced. A rollback goes
ahead without a daemon (it is often needed because the new daemon does not start; it restores a version that was
installed before). Agents have no `update` command at all.

### 5.4 Interruptions and rollback

Before the first change the installer writes `.antenna-update/journal.json`: for every path it replaces, the device
and inode of what was there and the places it can move to. A failure after that point swaps the old version back at
once; if the process dies, the next `antenna update` (any form, including the status) finds the journal and does the
same, then starts the daemon again. `antenna update --rollback` swaps the `.previous` version back in (the newer one
becomes `.previous`, so a second rollback goes forward again).

Every step goes to the log: `~/Library/Logs/Antenna/update.log` on macOS, `${XDG_STATE_HOME:-~/.local/state}/antenna/
update.log` on Linux.

### 5.5 `--check`

Fetches `<URL>` and `<URL>.sig` over HTTPS (`curl --proto =https --proto-redir =https`), verifies them as in §5.1 and
reports whether a newer version is out and which file this installation needs (`<URL without its last segment>/<asset
name>`); `--download <folder>` fetches and checks that file too, for `--from <folder>`. The URL: `--url`, else
`ANTENNA_UPDATE_URL`, else the first line of `~/.config/antenna/update-url`, else the one built into release builds
(D-137, D-138): the manifest of the build's own channel, `https://updates.stillbyte.dev/antenna/antenna-preview-manifest.json`
for a pre-release version (`0.1.0-preview.11`) and `…/antenna-stable-manifest.json` for any other (`0.1.0`), with its
signature and its files next to it. `off` (or an empty value) in the variable or the file turns the URL off, the built-in one
included. Debug builds have no built-in URL, so tests and development builds never reach the network by themselves.

## 6. Releasing

`antenna-release` (the build machine that holds the release key; never shipped):

```
antenna-release keygen --key <file>              # 0600, never overwritten; prints the public key and the line to pin
antenna-release manifest --version V --commit C --out antenna-V-manifest.json <release files or folder>
antenna-release sign --key <file> antenna-V-manifest.json     # writes or adds to antenna-V-manifest.json.sig
antenna-release verify --pinned --all antenna-V-manifest.json  # with the keys pinned in this build
```

The key file path can also come from `ANTENNA_RELEASE_KEY`. `packaging/release-linux.sh` runs `manifest`, `sign` and
`verify --pinned` over every file of the draft release (as GitHub serves it) and uploads the manifest and its
signature next to `SHA256SUMS.txt` before it publishes; the release workflow always creates a draft, because the key
never goes to CI. Then it mirrors the published release to the update host behind the built-in URL (D-137;
`ANTENNA_UPDATE_MIRROR`, the command that uploads to it; `--mirror-only` repeats this step alone): every release file
first, then `antenna-preview-manifest.json` and its `.sig`, copies of the release's own manifest and signature, last;
a version without a `-` also goes to `antenna-stable-manifest.json`, so preview installs follow stable releases while
stable installs never see a preview (D-138). The host is plain storage: what it serves counts
only after the signature check with the pinned keys, so a host that is taken over can hold an update back or offer an
older one (refused as not newer), never install anything.

## 7. Updates received over Antenna

A contact may send the manifest, its signature and the asset as ordinary files. Any contact can deliver an update;
none can forge one (a level-5 contact's files may also start an automatic install where the owner turned that on, §8). The file check treats them like any other files (D-82): the `.dmg` is of an unknown type and the
`.tar.gz` contains scripts and strings that look like secrets, so both are **suspicious**; at level 2 and above they
wait in quarantine for the owner (an agent cannot accept them), at level 1 no files arrive at all. Nothing is weakened
for them: the signature is checked by `antenna update` after the owner accepts the files. The window recognizes an
accepted, verified manifest and offers to install it.

## 8. Updates that install by themselves (D-103, experimental)

Off by default. The protocol is `docs/CONTROL.md` §23; the window's part is D-UI-29. Since 0.1.0-preview.11 the daily
check of the update URL runs with the setting off too, and what it finds waits for the owner (§8.4, D-137).

### 8.1 The setting

"Install signed updates by itself", per computer: `antenna update --auto on|off` (the owner password, both ways), or
Settings → Updates in the window. It is kept in the node's encrypted database. `antenna update --auto status` shows it,
the staged release, the last results and the versions that failed. It can be turned on only where `antenna update` can
replace the installation (the macOS app, the `install.sh` layout); a development build or the Linux window bundle
answers `unsupported_install`.

### 8.2 What starts an install

- **Release files from the owner's own computer.** A file that the daemon accepted by itself from a level-5 contact
  (D-99) and whose name is part of a release (`antenna-<v>-manifest.json`, its `.sig`, `antenna-…`/`Antenna-…` with
  `.tar.gz`/`.dmg`) makes the daemon look at that link's folder: the newest manifest there with its signature and this
  installation's file. A file the owner or an agent accepts, or a file from a contact at level 1–4, starts nothing.
- **The update URL**, once a day: the same URL as `--check` (§5.5), from the daemon's environment
  (`ANTENNA_UPDATE_URL`), `~/.config/antenna/update-url` or the build; the manifest and its signature first, the asset
  only when they verify and announce a newer release. Only where the installation can replace itself (§5.2): a package
  or a development build never downloads a release.

The verification is §5.1, in the same order, with the same code (`antenna-update`). The release is copied into
`<data-dir>/updates/<version>/` (0700), and the copy is checked again: the link folder can change afterwards without
effect. The same version as the running one, or as the staged one, is ignored without a record (re-sent files);
anything else that fails (`bad_signature`, `not_newer`, `wrong_platform`, `hash_mismatch`, …) is recorded as refused.
A version whose install failed on this computer is never tried again by itself.

### 8.3 When, and how

**When.** After 10 minutes in which no agent called the daemon, no wake or resident turn ran or waited, no incoming
file was being downloaded or checked, and no approved request was being carried out. If a window holds an owner
session, it gets the `update_auto` event `soon` five minutes before; "Later" moves the install an hour, "Install now"
starts it at once (the same checks).

**The swap.** The daemon starts the `antenna` next to it: `antenna update --from <data-dir>/updates/<version> --yes
--json --handover`, in its own process group (launchd kills a job's group when its process ends) and, when the daemon
runs as the `install.sh` systemd unit, in its own scope (`systemd-run --user --scope`: the unit's processes are killed
when its main process ends; without `systemd-run` the install is refused). The installer verifies the release again,
stages it and swaps the files exactly as in §5.2 and §5.4 (journal, `.previous`); on macOS it closes the window before
the swap and opens it again at the end. It refuses to run unless its parent is the daemon that described itself on its
stdin.

**The restart with the keys (R2).** Instead of stopping and starting the daemon, the installer tells it on stdout
(`{"step":"swapped"}`). The daemon shuts down as on SIGTERM (links closed, database closed, the socket removed),
writes into a new pipe `0x01 ‖ root key (32 bytes) ‖ installer PID (4 bytes, big endian)`, closes the write end, makes
only the read end inheritable, wipes the key from its memory and `execve`s the new `antennad` at the same path with
its own arguments and `--handover-fd <n>`: the same PID, so launchd and systemd keep tracking it, and the installer
stays its child. The new daemon makes itself non-dumpable (Linux) before anything else, takes the descriptor (only a
pipe, only once), reads exactly those bytes, closes it, and opens the database with the key before its socket answers;
a wrong key does not open it and the daemon stays locked. `status.updated {from, to, at_ms, unlocked}` says what
happened. Owner sessions do not cross the restart: the owner signs in again.

**When the new version fails.** The installer waits up to 30 s for the new version to answer. If it exits or never
answers, the installer swaps the old version back and starts it the way it is kept: `systemctl --user restart`,
`launchctl kickstart -k`, or, for a daemon started by hand, the old binary with the same arguments and working folder.
It comes up locked; when the owner unlocks it, the version is recorded as failed. The installer signals only its own
parent or a process of this installation's `antennad`, never whatever holds that PID later.

**Records.** Every step is in the update log (§5.4); the daemon keeps the last 20 results (`update_auto_status`),
sends `update_auto` events, and writes an `update_install` entry (`installed`, `failed`, `refused`) into the audit log
of the link that delivered the release.

### 8.4 With the setting off (D-137)

The daily check runs all the same and stages a newer release exactly as above, but nothing installs by itself. The
window shows "Antenna <version> is ready to install" in Files and in Settings → Updates; **Install** asks for the owner
password and sends `update_auto_now {password}` (`antenna update --auto now` in a terminal, or with
`--password-stdin`). The daemon opens the root key with the password for this one restart and starts the install at
once, with the swap and the handover of §8.3, so the new version comes up unlocked; the setting stays off and the key
is not kept afterwards. Without the password the daemon answers `password_required` and nothing changes. A touch
cannot stand in for the password here: the root key opens only with the password.

What a check tells the update host: the computer's address and the time, once a day, and nothing else (no identifier,
no version in the request; the user agent is curl's). To turn it off: `off` in `~/.config/antenna/update-url` or in
`ANTENNA_UPDATE_URL`.

### 8.5 Not covered

One release signature is enough for previews; a stolen release key would install on every computer that has this
turned on, so a public release waits for the second key before it offers automatic installs (D-103). After a reboot or
a crash the daemon is locked as before: unlocking from this computer's key store comes later, with a Developer ID and
FileVault (D-103 item 4). Test switches (debug builds and hidden flags) only shorten the waits
(`--update-quiet-ms`, `--update-tick-ms`, `--update-notice-ms`) or drop the key from the handover
(`ANTENNA_HANDOVER_TEST_DROP_KEY=1`, debug builds only).

## Appendix A. Test vector

Asset: a file `antenna-1.0.0-linux-x86_64.tar.gz` with the 11 bytes `test asset\n` (SHA-256
`9a87a1af731a430631c61724944994aece748e045626e75dc8956af26d97e665`, BLAKE3
`2638e610be653e7d589e3127f8eac7bc8e4fce9167b3a197bd4ef7c7b05ca352`). Manifest (512 bytes, ends with a newline; SHA-256
`5a5423e41cbcfe3419301ecae3efa8e26cbcd6af54729f622a41d862ef63d898`):

```json
{
  "format": "antenna-release-manifest/1",
  "product": "antenna",
  "version": "1.0.0",
  "channel": "stable",
  "created": "2026-10-03T12:00:00Z",
  "commit": "0123456789ab",
  "assets": [
    {
      "name": "antenna-1.0.0-linux-x86_64.tar.gz",
      "os": "linux",
      "arch": "x86_64",
      "kind": "cli",
      "size": 11,
      "sha256": "9a87a1af731a430631c61724944994aece748e045626e75dc8956af26d97e665",
      "blake3": "2638e610be653e7d589e3127f8eac7bc8e4fce9167b3a197bd4ef7c7b05ca352"
    }
  ]
}
```

Signed with the test key (§4): `key_id` `04e28f3f8c0bb3bf`, `sig`
`eAknF5J9KwNA/BdDJ9ceX7C9OqR8ONEvFYNOUmZtkOX+FBbgQQ6Rv0xkT4I1qOV5WKKq18UiOdiwxgDa5626Dw==`. Ed25519 is
deterministic: the same key and bytes give the same signature. Checked by `antenna_update::sig::tests::documented_vector`
and, independently, with Python `cryptography` and `openssl pkeyutl -verify -rawin`.
