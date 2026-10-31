<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Antenna desktop app

A window client of the `antennad` daemon: keys, networking, encryption and permissions live in the daemon, and the
app talks to it over the control unix socket (`x-control/5`; the `x-` prefix is the protocol's historical name,
`docs/CONTROL.md`). Flutter, macOS and Linux. License: AGPL-3.0-only (`LICENSE`). Design and decisions:
`docs/DESIGN.md` and DECISIONS D-UI-1…D-UI-14; the rename to Antenna and the first release: D-55…D-60.

```
lib/protocol/  control protocol client: pure Dart, no Flutter (the XDaemon interface)
lib/host/      the daemon started by the app (LaunchAgent / child process), finding binaries, the antenna terminal
               command, antenna:// links (links.dart), updates through `antenna update` (updater.dart)
lib/state/     app state: subscription, history, pairing, approvals, files, streams (streams.dart), wake (wake.dart),
               theme and language
lib/ui/        screens: navigation (Chats, Agents, Files, Settings), the live streaming bubble, agent wake
lib/theme/     design system
lib/version.dart  app version (= pubspec.yaml = Cargo.toml) and build commit (--dart-define=ANTENNA_COMMIT)
```

In a built app the core sits next to the window: on macOS `Antenna.app/Contents/Helpers/{antennad,antenna}`
(`packaging/macos/build-dmg.sh`), on Linux `bin/{antennad,antenna}` next to `antenna-desktop`. The terminal icon
button in Settings installs the `antenna` command for the terminal (a symlink at `~/.local/bin/antenna`).

Updates (Settings → Updates) go through that bundled CLI: `antenna update --json` for the installed version and the
pinned release key, `--from <folder or files> --dry-run` to verify a release, `--yes --password-stdin` to install it
(started detached, because on macOS the CLI quits and relaunches the window), `--check` only when an update URL is
configured. The window checks no signatures itself and shows only what the CLI reports. An accepted file in Files that
is named like a release manifest (`antenna-<version>-manifest.json`) and has a `saved_path` is checked with
`--manifest-only`; only when the CLI confirms the signature does the card say "Signed Antenna update … (verified)".

Code mode (Settings → Interface → Code) runs agent CLIs (Claude Code, Codex, an own command) in terminals inside the
window: `lib/state/agent_launch.dart` builds what runs (a bash wrapper that forks the CLI, the token only in its
environment, the Antenna MCP server on the command line), `lib/host/pty.dart` is the pseudo-terminal (`flutter_pty`),
`lib/ui/code/` the dock with the terminals (`xterm`), "Start agent" and the detected AI apps. On macOS `flutter_pty` is
built through CocoaPods (`brew install cocoapods`).

Invite links `antenna://pair#…` open the app: on macOS through the scheme in `Info.plist`; on Linux run
`build/linux/x64/release/bundle/install-desktop-entry.sh` once after building (menu entry, icon and
`x-scheme-handler/antenna` in `~/.local/share`, no root; `--remove` undoes it). Files are attached with the
paperclip button, by drag and drop or by pasting an image (plugins `file_selector`, `desktop_drop`; on macOS via Swift
Package Manager, no CocoaPods; clipboard images through the Runner, `antenna/clipboard`); they wait above the input as
chips and leave on Send, the text after them as the caption (`lib/ui/chat/attachments.dart`). An attached file is copied into the window's staging folder
first (`lib/host/outgoing_staging.dart`): its source may delete it right after the drop. On macOS the Runner takes
drops itself (`macos/Runner/ComposerInput.swift`: file promises, image data, the screenshot thumbnail) and passes text
pasted by dictation apps to the composer, which Flutter 3.47 loses. Manual checks for a Mac:
`test/macos/drop_check.swift`, `test/macos/paste_check.swift`.

## Running on a Mac (development)
1. Xcode and Flutter (`brew install --cask flutter`), `flutter doctor`.
2. Daemon on a server (tested): `antennad` runs on the server and is unlocked (`antenna unlock`); on the Mac keep
   `ssh -N -o StreamLocalBindUnlink=yes -L /tmp/antenna-remote.sock:/home/user/.local/share/antenna/antennad.sock user@server.example.com`
   open.
3. `flutter run -d macos --dart-define=ANTENNA_SOCKET=/tmp/antenna-remote.sock`
   (without `--dart-define` the app finds the socket the same way as the `antenna` CLI: `ANTENNA_SOCKET`,
   `ANTENNA_DATA_DIR`, `~/.local/share/antenna/antennad.sock`; the old `X_SOCKET`, `X_DATA_DIR` are fallbacks).

The ssh user must have the same uid that `antennad` runs under (the daemon checks SO_PEERCRED).

## Tests
```
nice -n 10 flutter analyze
nice -n 10 flutter test --exclude-tags live test/widget test/host      # no daemon needed
ANTENNAD_BIN=<path to antennad> nice -n 10 flutter test --tags live     # against real antennad (with antenna next to it)
nice -n 10 flutter test --update-goldens test/goldens                  # update screenshots (test/goldens, docs/design/screens)
```
The live Code mode test (`test/protocol/live_code_mode_test.dart`, Linux) builds `flutter_pty`'s C code with `cc` itself
and also runs the real Claude Code if `claude` is installed.
`antennad` for tests: `nice -n 10 cargo build -p antennad -p antenna-cli` at the repository root (by default
`target/debug/antennad` is used).
