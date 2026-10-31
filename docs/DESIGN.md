# DESIGN: the visual interface

Source: the maintainer's mockup `docs/design/north-mockup-v1.webp` (2026-10-02).
The brand on the mockup is **NORTH · Message beyond borders**, tagline "Encrypted · Private · Global · Human".

## What the mockup shows

| Area | Contents |
| --- | --- |
| Header | NORTH logo, tagline, the badges ENCRYPTED · PRIVATE · GLOBAL · HUMAN |
| Left column | Search (`/`), tabs All / Direct / Channels / Groups, `+`; the chat list: groups (Global Ops, Research, Team), direct (Sofia), family, **the North AI agent**, channels (#General), Archive; unread counts, an "online" dot |
| Center | The chat "Global Ops · 12 members · Encrypted · Online 5"; call and video; messages from people with roles; a file `route_north.pdf · Encrypted`; a location with a map; **arctic-bot (System)** creates a task with a checkbox, a due date and an assignee; delivery statuses ✓✓ |
| Input | A field "Type a message or command…", attachment, microphone, send; slash commands `/file /location /task /remind /ai /search /secure /clear` |
| Right column | The chat card (description, members with roles and Online/Away status, Add member); tabs Members / Files / Tasks / Links; "Shared in this chat" |
| Style | Dark theme, deep blue + a cold light-blue accent, monospaced digits/time, a mountain landscape, thin glowing borders |

## What matches the spec
- People and agents in one contact graph (SPEC §1, §11): North AI and arctic-bot next to people.
- E2E files (§7, §10), tasks for agents and `task` messages (§7, type `task`), slash commands on top of the CLI (§12).
- The emphasis on encryption and privacy.

## What is missing (the core of the product per the spec must be visible in the interface)
| Required by the spec | Where to show it (proposal) |
| --- | --- |
| **Trust level 1–5 for every contact and agent** (§9), the product's main difference | A level badge on the avatar in the list and in the card; a 1–5 slider in the contact card (changing it requires the owner password, Q-12) |
| **History verification** (§8): "History verified" + a 3-emoji fingerprint; a red banner on divergence | A line in the chat header next to "Encrypted" |
| **File quarantine** (§10): manifest → check → preview → explicit accept | A file card with the status "in quarantine / checked / accepted", buttons Preview / Accept / Reject |
| **Approval requests** (§9): a structured display of permissions, separate from the contact's text | A separate panel/notification "Bob asks: Read shared/report.pdf · Write: no · Commands: no" |
| **Pairing with a verification code** (§6): link/QR, entering 6 digits or emoji (Q-6), confirmation by both | An "Add contact" screen instead of "Add member" |
| **Agent: permissions and taint** (§9, §11): which links the agent sees, the permission ceiling after reading | An agent card: level, links, action history (audit log `antenna log`) |
| **Presence by level** (§4, Q-8): levels 1–2 do not see "online" | Show the "Online" status only for 3+; for 1–2, no status |
| **Network mode** (§4): relay only / direct / Tor | An icon in the link card |

## What goes beyond the v1 scope (SPEC §1 "not in v1")
- Voice and video calls (the icons in the chat header).
- Channels (`#General`, the Channels tab): public channels are outside v1.
- Groups (Global Ops, 12 members): v2 (MLS).
- Location: not in the spec; technically it is a message with coordinates, but it is sensitive data (by default, only levels 4–5?).
- Mobile clients: v1.x.

## Maintainer decisions (2026-10-02)
- **The mockup is about style and meaning, not details.** Take the mood (dark theme, cold blue, "mountains/north",
  a calm premium presentation, people and agents side by side), not specific features and not the NORTH label. The product name is
  **Antenna** (maintainer decision 2026-10-02, closes the question of SPEC §19; before that, the working name `x`).
- **The scope follows the spec.** Calls, channels, groups and location from the mockup are not in v1 and are not brought into the interface.
  The core of the product (trust levels, history verification, quarantine, approval, pairing by code) is mandatory in the interface: the table above.
- **The visual version: now, in parallel with the MVP**, on top of the working daemon.
- **Technology: Flutter + a Rust core** (maintainer decision 2026-10-02 after comparing with Tauri 2, native UIs and Electron).
  Why: one codebase for 5 platforms; no browser engine through which text sent by a contact could become an attack (the XSS class,
  as in Signal Desktop in 2018); the same look everywhere; it matches SPEC §14 for mobile. The price is Dart and a bridge to Rust.
  Architecture: on a computer the interface is a client of the control socket of the `antennad` daemon (protocol `antenna_proto::control`); keys and networking
  stay in the daemon; on phones (v1.x) the Rust core is embedded in the app through flutter_rust_bridge.

---

## Visual version · stage 1: the desktop app (2026-10-02)

Code: `apps/antenna_desktop` (Flutter 3.47.6 stable, Dart 3.13, macOS and Linux, AGPL-3.0-only). Screenshots for the maintainer:
`docs/design/screens/`; all screens (regression): `apps/antenna_desktop/test/goldens/`. Decisions: DECISIONS D-UI-1…D-UI-8.

### How it is built
| Layer | Where | What |
| --- | --- | --- |
| Protocol client | `lib/protocol/` | Pure Dart (only `dart:io`), without Flutter: x-control/1 over a unix socket (docs/CONTROL.md). The `XDaemon` interface: currently implemented by `XControlClient` (the `antennad` socket), in tests by a fake, on phones (v1.x) by the embedded Rust core through flutter_rust_bridge, without reworking the screens |
| State | `lib/state/` | `AppModel`: `contacts` → `subscribe` (one long-lived connection) → `approvals`, `pairings`, the last message of each link; the feed is `history` in pages of 50 + `message`/`message_status` events; E2E/transport facts come from polling `contacts` every 10 s. The window does not call `inbox`: it marks messages as read, and unread messages are the queue of the CLI and agents |
| Screens | `lib/ui/` | gate (the daemon isn't responding / init / unlock), the main screen in three columns, the pairing, approval and owner password dialogs |
| Design system | `lib/theme/` | tokens of the light and dark palettes, ThemeData, shadows and glow, the Antenna mark (since v2, without mountains) |

Keys, networking, encryption and permissions live only in the daemon. The interface stores neither the password, nor the history, nor links: everything comes
from the daemon and lives in the window's memory.

### Design system
> **Since 2026-10-02 (evening), the v2 reference applies:** the light theme by default, dark as an option; the accent is the logo blue
> #1560F6; the Antenna mark instead of the peak; no more mountains. Tokens and colors: the "Brand" and "Window in the v2 style" sections below.
> The table below is the first dark version (history).

| Token | Value (before v2) | Why |
| --- | --- | --- |
| Background | `bg0 #050A14` → `bg1 #08111F` → `bg2 #0C172A` → `bg3 #112038` | Deep blue, depth through layers rather than shadows (kept in the v2 dark theme) |
| Accent | `#6CC6FF` (cold light blue) | replaced by the logo blue: on dark, `#7AA7FF` for text, `#1560F6` for fills |
| Fonts | IBM Plex Sans (interface), IBM Plex Mono (codes, keys, facts; tabular digits) | Cyrillic support; OFL, embedded in the app, so the look is the same on all OSes (unchanged) |
| Code emoji | a subset of Noto Emoji (monochrome, the 10 animals of `antenna_proto::sas::EMOJI`, 9.6 KB) | The verification code looks the same on both sides (unchanged) |
| Mark | was: a peak in a frame (`PeakMark`), mountains (`RidgePainter`) | removed in v2: the mark is the maintainer's logo (`AntennaMark`) |

The contact's text is data only: no markup, links or formatting; in an approval it is shown as a monospaced quote
(SPEC §9, UI injection; there is no browser engine at all, per the "Flutter" decision).

### What is shown and what is hidden (and why)
| Screen / element | Source of facts | Note |
| --- | --- | --- |
| Gate: unlock / init / "The daemon isn't responding" | `hello`, `status`, `unlock`, `init` | The socket path can be changed on the screen (forwarding over ssh); a role other than `owner` (a process in an agent's tree, D-28) gets a separate refusal screen |
| Link list | `contacts`, `history limit 1`, events | Level badge 1–5; the delivery status of the last outgoing message; "N queued", "N not delivered"; presence only `online/offline` for 3–5 (`not_tracked` for 1–2: no dot); approval requests and live invites on top |
| Agent mark | `peer_kind` | The daemon currently always returns `unknown` → no agent badge in the working window; the agent look exists only in mockup D3 |
| Chat | `history`, `message`, `message_status` | Statuses: sending → queued → delivered / not delivered; "start of history · linked …"; a secret in the text → an "Approve and send" button (approve + `approval_id`) |
| The "E2E · PQ" badge | `contacts`: `transport.*_kx_group`, `e2e.session_version`, `e2e.pq_ratchet`, `last_rx_*` | "PQ" only if TLS = `X25519MLKEM768` and the session is v4; the tooltip lists the facts |
| Link card | `contacts`, `trust`, `log` | Level (changed with the owner password; a warning if the network mode changes), network mode and path, PQ facts, link ID and endpoints, heads and lamport, the action log |
| Level permissions | the text of SPEC §9 in the interface | The daemon returns structured `Rights` only to the agent; for the owner, see "needed from the daemon" item 6 |
| Pairing A | `invite` (follow), events, `pairing_confirm {id, code, password}` | Link + QR + TTL; the code as digits or animals (a toggle, because the daemon returns `emoji`). At the confirmation step the code is **not shown**. When the daemon offers `confirm_without_code` (B entered the code and no other invite showed one meanwhile, D-95), one button, "The contact confirmed — codes match", next to "Doesn't match — decline"; otherwise, or when the daemon answers the click with `code_required` (with the reason) or `bad_request` (older daemons), the owner enters the code that B read out to them; the window never fills in the code (D-UI-4, F-4); a wrong code is an error and the invite stays alive; "Doesn't match" is a refusal; "Cancel invite" requires the password |
| Pairing B | `join`, `input sas_code` | The code is entered as digits or by tapping the 10 animals; a wrong code means "the invite burned" |
| Invites from the CLI | `pairings`, the `invite` event, `pairing_confirm` with the entered code | The window shows and confirms invites created by `antenna invite`. The daemon returns the link and the code only with the owner password (`pairings` + `password`), and events do not carry them, so the window asks for the password before showing them; confirmation is the same button (with the password, `pairing_confirm` without `code`) or the same code entry field as an invite from the window |
| Approval | `approvals`, `approve`, `deny`, the `approval` event | Permissions structurally (Read · Write · Commands · Send), the reason, the fingerprint, the expiry; the text as a quote; exactly the options the daemon supports: once / deny / deny for an hour. There is no "Always allow": the daemon does not have it. Approve asks for the password, Deny does not (D-84); a request from an agent also stands in the conversation it concerns (section "Approvals where the owner looks") |
| Slash commands | only real `antenna` commands | `/invite /join /trust /approvals /pairings /log /contacts /status /lock`; plain text = `antenna send`; `//` escapes; `/inbox` is intentionally absent |

### Mockups of future states (golden "DESIGN · NOT YET IMPLEMENTED IN THE DAEMON")
| Frame | What | Component |
| --- | --- | --- |
| D1 | "History verified" + a 3-emoji fingerprint in the chat header; a red divergence banner with the exact place and "whose copy was changed" (in deniable mode, honestly "cannot tell") | `HistoryVerifiedChip`, `HistoryMismatchBanner` |
| D2 | A file in quarantine: manifest (type by signature, size, BLAKE3) → quarantine → check → preview → accept; ClamAV/YARA/secret results; Reject / Preview / Accept | `QuarantineFileCard` |
| D3 | The agent's reply stream (v0.2): a "live" bubble, text growing with a cursor, "typing…", a line "what the agent is busy with" (levels 4–5 only), "interrupted · N chars received"; agents in the shared list with an agent badge | `MessageBubble` (`ChatEntry.stream`), API `AppModel.beginStream/appendStream/setStreamActivity/endStream` |

The 3-emoji history fingerprint is drawn with the same 10 animals as the SAS; the fingerprint alphabet is an open question (3 of 10 is
only 1000 variants; that may not be enough for comparison by voice).

### API for the interface: needed from the daemon
Slice 2 already provided the main things (history with pagination, subscribe, presence, emoji SAS, invites in the daemon, approve, log:
docs/CONTROL.md, D-35). What the window still lacks:

| # | Method / field | Fields | Why |
| --- | --- | --- | --- |
| 1 | `mark_read` + `unread` in `contacts` | `{contact, up_to_seq}`; `ContactInfo.unread: u64` | The window's unread counters currently live only from the moment the window starts; `inbox` is not suitable for this (it is the queue of the CLI and agents) |
| 2 | `peer_kind` = `human`/`agent` and the sub-identity name in `HistoryItem` (`via_agent`) | — | The agent mark in the list and in the feed ("Bob / claude-backend", SPEC §5): v0.2 |
| 3 | History verification | `history_status {contact} → {state: verified/syncing/mismatch/no_checkpoint, fingerprint, at, where?, who_changed?}` + the `history` event | Frame D1 (SPEC §8) |
| 4 | Files | `files_pending`, `files_preview {id}`, `files_accept/reject {id}` + the `file` event (manifest, stage, check results) | Frame D2 (SPEC §10) |
| 5 | Reply stream | the event `message_stream {link_id, id, seq, text, done, interrupted, activity?}` | Frame D3 (DECISIONS "streaming agent replies", v0.2); the window's model already accepts chunks |
| 6 | `rights` in the owner's `ContactInfo` | like the agent's `Rights` | The card shows the level's permissions from the daemon rather than spec text from the interface |
| 7 | An event with link facts | `contact_facts {link_id, e2e, transport, outbox, failed}` on change | Remove the polling of `contacts` every 10 s |
| 8 | Several requests in one connection | `req.id` + responses with the same `id` (x-control/2) | Over ssh forwarding each request opens a new ssh channel: +1 RTT to the server per action |
| 9 | `revoke`, renaming the label | `revoke {contact, password}`, `label {contact, label, password}` | Delete a link and fix its name from the window (SPEC §12) |
| 10 | `verify`, `rotate` | — | Buttons in the link card (SPEC §12) |
| 11 | A response to rejected input in a dialog | the event `input_rejected {what, code, message}` on the `invite --follow` connection | The daemon silently ignores a "yes" with a wrong code on the watching connection (only a debug log); so the window confirms through `pairing_confirm` and asks for the password a second time. With `input_rejected` the password would not need to be asked again on confirmation |

### How to run it on a Mac
1. Install Xcode (App Store) and Flutter: `brew install --cask flutter` (or `git clone -b stable https://github.com/flutter/flutter ~/flutter`
   and `export PATH=~/flutter/bin:$PATH`), then `flutter doctor`: the Flutter and Xcode items are needed; CocoaPods is not needed (there are no plugins).
2. Get the code: `git clone <user>@<server>:<path-to-repo>` (or `rsync`).
3. Connect to a daemon:
   - **to antennad on a server (tested):** on the server `antennad` is running (for example in tmux) and unlocked (`antenna unlock`). On the Mac:
     `ssh -N -o StreamLocalBindUnlink=yes -L /tmp/antenna-remote.sock:<home>/.local/share/antenna/antennad.sock <user>@<server>`; keep it open;
   - **antennad on the Mac itself:** `cargo build -p antennad -p antenna-cli`, `antennad &`, `antenna init`; building the core on macOS has not been tested yet.
4. Start the window: `cd apps/antenna_desktop && flutter run -d macos --dart-define=ANTENNA_SOCKET=/tmp/antenna-remote.sock` (without
   `--dart-define` the window looks for the socket like the CLI: `ANTENNA_SOCKET`, `ANTENNA_DATA_DIR`, `~/.local/share/antenna/antennad.sock`; the path can also be changed on the "The daemon isn't responding" screen).

Forwarding was tested on the server (OpenSSH 9.6, a separate sshd in a temporary directory): `antenna status`, `hello` (role `owner`,
`x-control/1`) and `subscribe` work through the forwarded socket; status takes a median of 1.8 ms versus 1.4 ms directly (localhost).
Conditions: the ssh user is the same uid that `antennad` runs as (the daemon checks SO_PEERCRED: the connecting process is
that user's sshd), otherwise `forbidden`; the server must not have `AllowTcpForwarding no`/`DisableForwarding yes`
(they also forbid forwarding unix sockets; on the test server it is `yes`); the forwarded socket on the Mac is `0600` (`StreamLocalBindMask 0177`).
Security: whoever can log in over ssh as this user is the owner of the daemon, just as locally; trust commands still
require the owner password.

---

## User path: installation, first run, connecting an assistant (2026-10-02)

The path is the one an ordinary user takes: install x on a Mac, create a node and a link and connect one's own assistant,
following `docs/USER-GUIDE.md`. Decisions: D-UI-10…D-UI-12;
portability of the core to macOS: `docs/PORTABILITY.md`.

| Step | What the window does | Source | Screenshot |
| --- | --- | --- | --- |
| Installation | `Antenna-<ver>-macos-arm64.dmg` with `Antenna.app` (the core in `Contents/Helpers`), "Read me.txt" | `packaging/macos/build-dmg.sh`, `release.yml` | — |
| Terminal command | the terminal icon at the top → "Install the antenna command in the terminal": a link `~/.local/bin/antenna` → the CLI from the app, a hint about PATH; on macOS, optionally `/usr/local/bin` through a macOS password prompt | `lib/host/cli_install.dart`, `lib/ui/cli/cli_dialog.dart` | — |
| First run | the daemon isn't responding → the window starts its own `antennad` (macOS: a LaunchAgent, Linux: a child process) → "New node" | `lib/host/`, `AppModel.startDaemon` | `13_first_run_starting`, `02_init` |
| Start error | "The daemon didn't start": the message, the exit code, the log tail, a hint about the cause, "Try again" | `DaemonStartException` | `14_daemon_start_error` |
| Daemon | the version pill at the top → socket, log, who starts it, "Stop daemon" | `showDaemonDialog` | — |
| Agents | the "Agents" button / `/agent`: name, data label (mandatory), links, password → the token once, and snippets; the agent list, revocation | `agent_add/agent_list/agent_remove` | `15_agent_connect`, `16_agent_token_snippets` |
| Node on a server | not the window: `install.sh` (systemd user), the link with the Mac is an ordinary invite | `packaging/linux/` | — |

What the owner needs to know (and what is visible on screen): label 5 on the assistant = replies to contacts below 5 only through
approval (no write down, tested against a live daemon: the agent's `antenna send` → code 77, an approval request with the reason
`no_write_down:local_5>contact_3`). This is not a bug but protection of private data from being retold.


---

## x-control/2 in the window: session, history verification, rekey (2026-10-02)

Slice 3 of the core delivered what used to be a mockup or an item in "needed from the daemon" (CONTROL §12–§13). The window speaks
`x-control/2`; decisions: D-UI-4 (revised), D-UI-13, D-UI-14.

| What | How it looks in the window | Source | Frame |
| --- | --- | --- | --- |
| Owner session | one password: `unlock` + `login {hold}`; the daemon is already running → "Sign in"; the session is closed → "Sign in" again | `login`, the `session` event, `hello.session` | `20_login` |
| Pairing confirmation on A | the code as told by B, on the watching connection, without a second password; a wrong code gives `input_rejected`; since D-95 one button when the daemon offers it | `input confirm {yes, code}`, `input confirm {yes}` | `08_invite_confirm`, `42_invite_confirm_button` |
| "History verified" | a badge in the chat header: the 3 fingerprint animals (the same on both sides) and the verification time; clicking it runs `verify` | `contacts[].history`, the `history` event, `verify` | `04_home_chat` (was mockup D1) |
| Divergence | a red banner: the place (whose message #, time, lamport), whose copy was changed, the reason; "Restore my copy" (`repair`), "Accept…" (password, `accept`), "Verify again"; the input line → "Read-only" | `history.state = mismatch`, `send_blocked` | `17_history_mismatch` |
| Rollback and rekey | on one's own side (`rolled_back`): "Propose a rekey" (password) → code #1 large, "read it out" → on the `confirm_contact_code` event, a field for the contact's code + password → done. On the contact's side (`requested_by_contact` / `peer_rolled_back`): a field for code #1 + password → code #2 large, "read it back". `conflicting_offers`: a red banner "someone else may have the keys" | `rekey`, the `rekey` event | `18_rekey_contact_asks`, `19_rekey_my_code` |
| Unread | `contacts[].unread`; selecting a link sends `mark_read` | `mark_read` | `04_home_chat` |
| Level permissions | in the card, `contacts[].rights` from the daemon (spec text only for a v1 daemon) | `rights` | `11_trust_change` |
| Rename / delete a link | a pencil next to the name (no password); "Remove contact…" with the password and a "delete the history" checkbox | `rename`, `revoke` | — |
| Receipts | a service line in the feed ("claude · read the messages: allowed"); in the log, `→`/`←`/`·` | `kind: receipt`, `log.source/author` | `04_home_chat` (Jordan's feed) |

Status of the "API for the interface: needed from the daemon" items after v2: 1 (`mark_read`/`unread`), 3 (verification), 6 (`rights`),
9 (`revoke`, `rename`), 10 (`verify`), 11 (`input_rejected`) are **done and wired up**; 2 (`peer_kind`), 4 (files),
5 (reply stream), 7 (`contact_facts`), 8 (several requests per connection) are not yet (CONTROL §13). Frame D1 was removed:
history verification is live.

Forwarding over ssh was retested with v2 (a separate sshd, as before): without a session, `login_required`; `login {hold}` through
the forwarded socket gives `hello.session = held`, `contacts` and `subscribe` work, and after the session connection is closed it is
`login_required` again. To the daemon, all forwarded connections are one process (the sshd of that ssh session), so the token works
for all of the window's connections; without the token (it exists only in the window's memory) other processes on the Mac do not become the owner.

### The MCP switch on macOS (2026-10-02)
As long as the core on macOS cannot bind an agent to the MCP host process (docs/PORTABILITY.md, M-3…M-6), `antenna mcp` does not
start there. All window behavior that depends on this hangs on **one constant**,
`mcpWorksOnMacos` in `apps/antenna_desktop/lib/state/agent_snippets.dart`:
- `false` (before the core port was merged): on macOS the agents screen opens on the "Any script" tab; the Claude
  Code, `.mcp.json` and Codex tabs carry the note "will work after the core changes", and the hook commands include the token;
- `true` (**now**, since the core port was merged, DECISIONS D-P-2): no notes, the default tab is Claude Code, hooks without
  a token, everything as on Linux (the test "the macOS core port is merged…" checks that the macOS and Linux snippets are identical).
The tests do not depend on the OS: the tab is chosen explicitly, and the test "one switch decides the default tab…" checks both values.
The first CI build on macOS (run 37033353199) failed exactly here: the test expected Claude Code as the default tab.

In the history divergence banner, the daemon's technical explanation (in English) is no longer duplicated under the localized text;
it opens through the "details (daemon message)" link.

### Compatibility with the x-control/3 daemon (slice 4, files)
The window speaks `x-control/2`; a v3 daemon accepts it. Tested against a clean HEAD (`915fc6e`): all 71 tests, including
`live_v3_compat_test`: a contact sends a file through the CLI, and the window receives a `kind: file` message as the line
"file: report.txt (3400 bytes, text/plain, blake3 …)" in the feed and a `file` event (ignored for now); the session and subscription stay alive.
The files screen (quarantine, preview, accept) is a separate task; mockup D2 remains a mockup until then.


## Reference v2: light minimalism (maintainer decision, 2026-10-02)
File: `docs/design/reference-light-v2.webp` (a site + the window on a laptop + a phone).
The maintainer liked this design for the site and asked for the site to follow this style; the app design was liked too:
concise and minimal, yet the functionality and where to click are visible at once.
- **Style (we take it):** the light theme by default, plenty of air, a white/very light blue background, a large dark heading,
  the single bright color is the logo blue #1560F6, soft shadows, rounded corners, simple line icons. In the window: on the left,
  navigation between sections (Chats, Agents, Files, Settings), in the middle the chat list with avatars, on the right the conversation; the assistant
  is marked with the Antenna mark. The dark theme is an option (following the system or by a toggle).
- **Content (honestly, as with the first mockup, "style and meaning, not details"):** no "Sign in" (we have no accounts;
  on the site, "Join the beta"); platforms only those that really exist; "Spaces"/groups are v2: not brought into the interface, or
  marked "soon"; the core of the product (trust level, E2E·PQ, "History verified", quarantine, approval) stays, but quietly,
  as small labels, with details in the card.

## Brand: logo and colors (2026-10-02)
The maintainer supplied the logo and decided that its colors may be used in the interface too. The source is
`docs/design/logo/antenna-logo-source.webp` (raster 1254×1254). The vector and **all** derivatives (SVG, macOS and Linux icons,
favicon, Open Graph, geometry for the window) are generated by one script, `docs/design/logo/build.py`; do not edit SVG/PNG by hand:
change a constant in the script and rerun it (the command is in the script header; cairosvg and Pillow are needed, installed with `pip --target`
without apt).

### The mark
An antenna tower in the shape of an "A" made of dashed strokes with rounded ends, a dashed crossbar, a solid circle on top,
two pairs of dashed wave arcs on the sides. How the vector was traced: each stroke was fitted by least squares to the smoothed
coverage of the source (a straight stroke is a segment with round ends, a wave stroke is an arc with its own center: the waves in the source are not
concentric circles, they straighten toward the ends), the left/right pairs were averaged and mirrored about the canvas axis
x = 627. Stroke width 48.3 px (the crossbar 45.6: in the source it is noticeably thinner, and that was kept), circle r = 90.8.
Match with the source (`build.py --check`): IoU 0.982 over pixels "whiter than 50 %", contour deviation: median 0 px,
99 % ≤ 1 px, maximum 2 px on the 1254 canvas.

| File (`docs/design/logo/`) | What | When to use |
| --- | --- | --- |
| `antenna-mark.svg` | white mark, transparent background | on the brand blue and on dark backgrounds |
| `antenna-mark-blue.svg` | blue mark #1560F6, transparent background | on white and light backgrounds: the site header, the window navigation, documents |
| `antenna-icon.svg` | the original composition: the mark on a blue square | an avatar in social networks and stores, apple-touch-icon; with rounding, the favicon |
| `antenna-app-icon-macos.svg` | the app icon on Apple's grid (Big Sur and later): canvas 1024, a 824×824 plate with a margin of 100, radius 185.4 with continuous corner curvature (like "60 % smoothing" in Figma), the mark at 70 % of the plate height, centered, a soft shadow (down 10, σ 10, 30 % black) | macOS AppIcon (`Assets.xcassets`, 16…1024), the Linux window icon (without the shadow, 256 px) |
| `png/*.png` | raster for viewing | to show people, to paste into a document |

Elsewhere: the window draws the mark as a vector from `lib/theme/logo_geometry.dart` (generated by the same script): `AntennaMark`
(the mark) and `AntennaAppIcon` (the mark on a blue plate); there are no raster copies in the app. The site: `favicon.svg`, `favicon-32.png`,
`apple-touch-icon.png` (180, opaque), `og.png` (1200×630), `assets/mark-blue.svg`, `assets/mark-white.svg`.
macOS 26: the icon in the standard shape and grid; an Icon Composer file (`.icon`, "Liquid Glass") when the build moves to Xcode 26.

### Colors
The single bright color is the logo blue. Everything is done with `XPalette` tokens in `apps/antenna_desktop/lib/theme/tokens.dart`
(light and dark); there are no colors in the screen code. Text-to-background contrast ≥ 4.5:1 (WCAG AA) for **all** pairs that occur
in the window is checked by `test/widget/contrast_test.dart` (text and accent on every surface, on the selection, on the soft state
plates, white on blue, captions of the outgoing bubble, level badges, avatars).

| Token | Light (default) | Dark | Where | Contrast (text) |
| --- | --- | --- | --- | --- |
| `brand` / `accentFill` | `#1560F6` | `#1560F6` | fill of primary buttons, counters, outgoing bubbles, the icon, the mark | white on it **5.20:1** |
| `accentFillHover` | `#0F55E0` | `#0F55E0` | button hover and press | white 6.18:1 |
| `accent` | `#1458E4` | `#7AA7FF` | accent text, links, icons: the selected section, PQ, "change" | light: 5.92 on white, 5.18 on `accentSoft`; dark: 7.92 on `#08111F`, 6.22 on `accentSoft` |
| `accentSoft` | `#E9F0FE` | `#12274A` | the background of the selection (section, link), soft badges | — |
| `accentLine` | `#ADC6FA` | `#2D5294` | the focus and selection outline (not text) | — |
| `outText` / `outMeta` | `#FFFFFF` / `#F0F5FF` | the same | text and time/status in the outgoing bubble | 5.20 / 4.76 |
| `text` / `textDim` / `textMute` | `#0B1B3A` / `#475570` / `#5B6880` | `#E3ECF8` / `#9EB0CA` / `#8396B6` | primary / secondary / captions and time | light: 17.0 / 7.50 / 5.62 on white (mute ≥ 4.91 everywhere); dark: 15.9 / 8.57 / 6.31 (mute ≥ 4.89 on hover) |
| `bg0` / `bg1` / `bg2` / `nav` | `#F5F7FB` / `#FFFFFF` / `#F1F4F9` / `#F5F7FB` | `#050A14` / `#08111F` / `#0C172A` / `#060D19` | window background / panels / fields and incoming bubbles / navigation | — |
| `line` / `lineStrong` | `#E5EAF1` / `#D2DBE7` | `#182842` / `#24406A` | 1 px dividers and borders | — |
| `ok` / `warn` / `danger` / `agent` | `#0B7A55` / `#975800` / `#C42338` / `#6447D4` | `#5CD6A9` / `#E7B867` / `#FF7A87` / `#A79BFF` | delivered, queue/approval, error/divergence, agent stream | ≥ 4.5 on all surfaces and on their own plates |
| levels 1–5 | `#5B6880` `#3B64A0` `#1458E4` `#087570` `#0B2F8A` (5 is a filled badge) | `#8395B3` `#7FA9DB` `#6CC6FF` `#4FDDD6` `#E6F6FF` (the glow grows) | the trust level badge | ≥ 4.5 on white and on its own plate |

Shadows (light theme only): soft, text color at 4–7 %, blur 24, offset down 6, on cards, dialogs and the sign-in screen.
In the dark theme depth comes from layers and a thin accent glow, as before.

### Clear space, minimum size
- **Clear space** around the mark is at least the diameter of its circle (≈ 16 % of the mark's height); around the icon, 10 % of its side.
- **The minimum size of the mark** on screen is 20 px high (stroke ≈ 0.85 px; below that the dashes merge). Smaller only
  as part of the icon on the blue plate (favicon 16/32, the Finder list): there the plate shape and the silhouette are recognizable.
  In the window: navigation 30 px, the agent avatar 60 % of its side (at least 34 px), the sign-in screen icon 64 px.

### Don'ts
Do not distort the proportions or rotate the mark; do not change the thickness, length and rhythm of the strokes or "fill in" the dashes with a solid line;
do not recolor the mark (only blue `#1560F6` or white; no other colors, no gradients); do not add a shadow, glow or
outline to the mark (a shadow only on the macOS icon, per Apple's grid); do not put the mark on a busy background or photo without a blue/white plate;
do not crop the mark with a plate closer than the clear space; do not bring back the old peak mark.

## The window in the v2 style (2026-10-02)
Layout per the maintainer's reference, the core per the spec. Frames: `docs/design/screens/` (light; dark ones are `*_dark`);
all screens: `apps/antenna_desktop/test/goldens/`.

| What | How | Code |
| --- | --- | --- |
| Navigation on the left (220 px) | mark + ANTENNA; sections **Chats** (unread counter) · **Agents** · **Files** · **Settings**; at the bottom, the daemon card (version, relay, number of contacts; click for daemon details) and "Lock keys". No "Spaces"/groups: v2 | `ui/home/home_screen.dart` |
| Chats | the link list, 340 px: "Chats", "New contact", search, filter pills, approval requests and invites on top, initials avatars (an agent gets the Antenna mark on blue once the daemon returns `peer_kind`), level badge, time, status, unread; the conversation: a header with small labels (level, E2E · PQ, "History verified" with the fingerprint, network mode, presence), clean bubbles (incoming light gray, outgoing in brand blue), a pill-shaped input line with a round button | `ui/home/contact_list.dart`, `ui/chat/` |
| Link card | via the ⓘ button in the conversation header (hidden by default): trust and changing it with the password, network, encryption, history, log, ID, removal | `ui/contact/contact_panel.dart` |
| Agents | a section: connected agents (revocation), "Connect an agent" → the previous dialog (label, links, password, token, snippets), the rules "the daemon checks permissions" | `ui/agents/agents_page.dart` |
| Files | honestly: the files screen in the window is the next task; the daemon already accepts into quarantine, the commands are `antenna files …` | `ui/files/files_page.dart` |
| Settings | theme: **System / Light / Dark** (default "System"; with a light system, light); language: **System / English / Russian** (each language name is shown in its own language, see `GLOSSARY-ru.md`); daemon details, stopping it, the antenna command in the terminal; "Lock keys". Since preview.4 in sections (General, Interface, Network, Security, Agents, Advanced), see "Code mode" | `ui/settings/settings_page.dart` |
| Theme | `XColors.*` are getters of the current palette; `XApp` chooses the palette (the choice or the system brightness) and rebuilds the tree without losing state; the theme and language choice is stored in `window.json` as `{"theme": …, "lang": …}` (macOS: `~/Library/Application Support/Antenna/`, Linux: `$XDG_CONFIG_HOME/antenna/`); the window stores nothing else | `lib/theme/tokens.dart`, `lib/state/appearance.dart`, `lib/ui/app.dart` |
| Language | English by default, Russian if the system is in Russian or it is chosen explicitly; strings via ARB + gen-l10n (the "Languages" subsection below) | `lib/l10n/`, `lib/state/appearance.dart`, `lib/ui/app.dart` |
| Sign-in screen | a light background with a soft brand blot, the Antenna icon, a white card with a shadow | `ui/gate/gate_screen.dart` |
| Dialogs | white, corner radius 18 and a soft shadow, an icon in an `accentSoft` circle, dimming with `scrim` | `ui/widgets/dialog_shell.dart` |

Checks: `test/widget/contrast_test.dart` (contrast of both themes), `test/widget/appearance_test.dart` (light by
default, "System", switching in "Settings" without losing the selected link, saving and a broken `window.json`;
language by system and by choice, an old `window.json` without `lang`), `test/widget/l10n_guard_test.dart` (the string guard),
golden: 32 frames: English, dark `04_home_chat_dark`, `10_approvals_dark`, Russian `*_ru` (5 key ones).

### Languages (2026-10-02)
The window speaks English by default and Russian if the system language is Russian; an explicit choice in "Settings" (**System
/ English / Russian**) overrides the system and is stored in `window.json` next to the theme (`"lang": "system|en|ru"`;
an old file without `lang` and a broken file → "System").

**How it is built.**
- Flutter's official gen-l10n: `apps/antenna_desktop/l10n.yaml`, the strings are `lib/l10n/app_en.arb` (the template: English,
  descriptions and placeholder types) and `lib/l10n/app_ru.arb`. Generation happens by itself on `flutter pub get` / `flutter test` /
  `flutter run` (`flutter: generate: true`), manually with `flutter gen-l10n`. The generated `lib/l10n/app_localizations*.dart`
  **are committed**: the synthetic package `flutter_gen` was removed in Flutter 3.32+, the code goes into `lib/l10n`, and without it in the tree
  `flutter analyze` and CI without a generation step would not pass. The file of untranslated strings is `lib/l10n/untranslated.json`
  (it must be `{}`).
- Language choice: `resolveLanguage` in `lib/state/appearance.dart`: "System" takes the first language from
  `PlatformDispatcher.locales` (in order of preference) that the window knows (`en`, `ru`), otherwise English. `XApp`
  passes it to `MaterialApp.locale` and listens for system language changes (`didChangeLocales`). Switching does not lose
  state: strings come from `Localizations` (an InheritedWidget), and only the dependent widgets are rebuilt.
- Access: in widgets, `context.l.key` (`lib/l10n/l10n.dart`). There are no strings in `lib/state`: functions that need text
  (`describeError`, `netModeLabel`, `TrustLevel.name`, `PqFacts.lines`, `formatDate`/`dayLabel`, `agentSnippets`,
  `SlashCommand.help`…) take `AppLocalizations` as a parameter, with no global state and no `BuildContext`;
  `lib/host` throws exceptions with a reason code (`DaemonStartFailure`, `CliInstallFailure`), and the screen builds the text.
  Outside the widget tree (tests, utilities): `l10nFor('en')`.
- Dates: the pattern is in the ARB (`datePattern`: en `MMM d, yyyy` → Oct 2, 2026; ru `dd.MM.yyyy` → 02.10.2026), formatted with intl
  `DateFormat` in the window's language; the intl locale data is loaded by `format.dart` itself (`initializeDateFormatting`, synchronously).
  Time is 24-hour in both languages.
- Plurals: ICU plural in the English template (`{count, plural, =1{1 contact} other{{count} contacts}}`);
  the Russian text is kept verbatim, phrased so that the word form does not depend on the number ("contacts: 5", "interrupted · 42 chars received").

**How to add a string.** (1) The key and the English text go into `app_en.arb`, with `@key` (`description`, `placeholders` with a
type); (2) the same key into `app_ru.arb`; (3) `flutter gen-l10n`; (4) in code, `context.l.key` or `l.key(…)`;
(5) commit the ARB files and `lib/l10n/app_localizations*.dart`. Keys are camelCase with a screen prefix (`gate…`, `chat…`,
`pair…`, `card…`, `approvals…`, `agent…`, `settings…`, `err…`, `common…`). Placeholders are named, with a type
(`String`, `int`). The guard `test/widget/l10n_guard_test.dart` checks identical keys and placeholders in both ARB files,
an empty `untranslated.json`, the freshness of the generated class and the absence of Cyrillic in string literals in `lib/`
(except `lib/l10n/`; comments are not checked). A temporary exception is `lib/ui/files/files_page.dart` (it is being
rewritten by the files screen work; the guard will ask to remove the exception once no Cyrillic is left there).

**What is not translated:** CLI commands and arguments (`antenna invite …`, `--trust`), protocol identifiers and fact
values (`X25519MLKEM768`, `v4 · PQXDH + SPQR`, error codes), the texts of agent config snippets (in the script example only the comments and the example
reply are translated), the daemon's own messages (in English, under "details"), link names and
conversations.

**Russian glossary:** the terms of the Russian localization, with the English they correspond to, are in
[`apps/antenna_desktop/lib/l10n/GLOSSARY-ru.md`](../apps/antenna_desktop/lib/l10n/GLOSSARY-ru.md).

## Streaming replies and wake in the window (x-control/4, 2026-10-03)
The window speaks `x-control/4` (CONTROL §15–§16). Mockup D3 ("the agent's reply stream") became live; frames D2/D3 and
`lib/ui/future/` were removed (files: the "Files" section; the stream: `27_live_stream`).

| What | How | Code |
| --- | --- | --- |
| Live bubble | the `message_stream` event by `stream_id`: `streaming` appends `delta` (a skipped `seq` or a mismatch of `text_len` in UTF-8 bytes means re-reading `streams`); a cursor, "typing…" / "replying…", "using <tool>…" from `activity`; `out` is on the right, with the caption "<agent> (your agent)" if the link has a wake rule; `live: false` gives "the contact will see only the final message" | `lib/state/streams.dart`, `ui/chat/stream_bubble.dart` |
| Final message | `final` + the message `message_id`: the bubble goes away, the message stays; `final` before the message gives the bubble "saving the final message…" until it arrives; `end: interrupted` puts the mark "interrupted" on the message | the same, `message_bubble.dart` |
| Break | `interrupted`: the text from `text`, the reason in words (the connection was lost, the time ran out, …); `cut` on one's own stream gives "waiting for your approval" and a requests button; after `approve` the final message is recognized by its text (the sender's daemon does not send `final`; see TROUBLESHOOTING) | the same |
| Wake | "Agents" → "Agents that reply on their own": this OS's sandbox in words (bwrap / Landlock / none on macOS), the rule (command, mode, limits, hosts, sign-in files, secret names), the last run, "Run log" (`wake` records from `antenna log`), "Change", "Turn off"; in the contact card, "Agent replies" | `ui/agents/wake_ui.dart`, `lib/state/wake.dart` |
| Setup | contact, preset (Claude Code / Codex / own script), a command without a shell (parsed like `--cmd`), a secret variable with hidden input (sent to the daemon once, the window does not store it), "do not show my CLI sign-in" (`home_files: []`), extra proxy hosts, time limit and runs per hour, the owner password; the errors `denied` and `sandbox_unavailable` in words | `WakeDialog` |

Checks: `test/widget/streams_test.dart`, `wake_test.dart` (both languages), live `test/protocol/live_stream_wake_test.dart`
(a fake agent as in `crates/antenna-cli/tests/wake.rs`: the bubble grows, the final message, a crash → "interrupted", a secret → "waiting for
approval" → approval → the final message, the log, turning off), golden `27_live_stream(_ru)`, `28_wake_agents`, `29_wake_setup(_ru)`.


## Updates in the window (D-82, 2026-10-03)
The window never checks a signature itself: it runs the bundled `antenna update` (`docs/UPDATES.md`, CONTROL §19) and
shows what it says.

| What | How | Code |
| --- | --- | --- |
| Settings → "Updates" | the window version and commit, the installed version and location, the release key (or "none: this build can't verify updates"), the previous version, from `antenna update --json`; an installation that cannot update itself shows the CLI's reason and no install button | `ui/settings/settings_page.dart`, `lib/host/updater.dart` |
| Install update from file… | a manifest file or a folder → `--dry-run`: version, channel, build date, "Signed by Antenna release key <id>", the file and its size, where it goes, the plan; errors by code in words | `ui/updates/update_dialog.dart` |
| Install and restart | the owner password goes to the CLI's stdin only (`--password-stdin`); the CLI is started detached with its own stdio, because on a Mac it closes the window, swaps the app and opens the new one; the dialog cannot be closed while installing and says that the keys will be locked after the restart | the same |
| Check for updates | shown only when the CLI reports an update URL | the same |
| Files | an accepted file named `antenna-<version>-manifest.json` is checked with `--manifest-only` (once per path); if the signature is valid: "Signed Antenna update <version> (verified)" with "Install"; a file in quarantine whose BLAKE3 equals an asset of a verified manifest: "Part of the signed Antenna update <version>" | `lib/state/updates.dart`, `ui/files/file_card.dart` |

Checks: `test/host/updater_test.dart` (JSON, arguments, the password only on stdin, a real detached start),
`test/widget/updates_test.dart`, golden `32_update` (Settings scrolled to "Updates" with the dialog open; the
Settings frame `22_settings` did not change: the card is below the fold).

## Approvals where the owner looks (D-84, D-UI-15, 2026-10-03)
A request nobody sees expires, and both sides go silent; refusing should cost nothing. Frame: `33_approval_in_chat(_ru)`.

| What | How | Code |
| --- | --- | --- |
| Card in the conversation | a pending request from an agent stands at the end of the conversation with the contact it is about (`link_id`) and with the recipient of a send (`target_link_id`; older daemons: by label), at most 560 px wide: the agent's avatar, "Waiting for your approval", "<agent> wants to <action> → <recipient>", the countdown pill, "Triggered by" with the reasons, the permissions on one wrapped line ("Read none · Write none · Commands none · Send …"), the quote (3 lines), then **Approve** (primary) and **Deny** (secondary) side by side, the fingerprint and **Details** (the full list). The owner's own requests stay in their bubble or file card ("Approve and send") | `AppModel.approvalsFor`, `ApprovalCard(inChat: true)` in `ui/chat/chat_view.dart` |
| List and counter | the counter stays at the top of the link list; each request is a panel: the agent's avatar and "<agent> wants to <action> → <recipient>", the countdown pill, "Triggered by" <contact> with the trust badge, the reasons and the time, "Permissions requested" in four columns, the request text in its own box, the fingerprint, **Deny everything from this contact for an hour** (destructive text), **Deny** (secondary) and **Approve** (primary). Deny and "deny for an hour" without a password; a daemon older than D-84 (`bad_request`, missing `password`): the password dialog, then a retry | `ui/approvals/approvals_view.dart` |
| Buttons (reference v3) | primary: solid `#1560F6`, hover `accentFillHover`, pressed a step darker; secondary: neutral fill with a 1 px border; destructive: red text; tertiary: accent text; radius 8; keyboard focus is a 2 px ring outside the button. Only the approval UI used them at first; since preview.6 the theme gives them to every button (section "Visual polish to reference v3"). Approve says "Approve" (the password is asked), not "with Touch ID", until that exists | `ui/widgets/x_buttons.dart`; state colors `accentFillPressed`, `dangerHover`, `dangerPressed` in `lib/theme/tokens.dart` (contrast test) |
| Expiry | the daemon's `approval{expired}` removes the card; a timer re-reads `approvals` 1.5 s after the earliest expiry; a late decision answered with `approval_expired` drops the card | `lib/state/app_model.dart` |
| System notification | a new request from an agent while the window is not focused (`AppLifecycleState` ≠ `resumed`): "Antenna: approval needed" / "<agent> is waiting for your approval: <action> → <recipient>", never the request text; quiet requests, repeats and the owner's own requests do not notify. Linux: `org.freedesktop.Notifications.Notify` over the session bus (`dbus` package); macOS: `osascript` `display notification` with the texts as arguments | `lib/host/notifier.dart`, `ui/app.dart` |
| Connecting an agent | one line on the form and on the result screen: the agent sees only messages that arrive after it is connected; to give it an earlier one, paste it into its session or ask the contact to send it again | `NewMessagesOnlyNote` in `ui/agents/agents_dialog.dart` |

Checks: `test/widget/approvals_test.dart`, `test/host/notifier_test.dart`, live `test/protocol/live_approvals_test.dart`.
Changed frames: `10_approvals(_ru, _dark)` (the panel in the reference v3 layout with "Approve"; the open conversation,
behind the dialog, shows the same request as a card), `15_agent_connect` and `16_agent_token_snippets` (the new
line), `22_settings` and `31_lan(_ru)` (the window version, now `0.1.0-preview.3`). The reference v3 is style and
meaning, not a pixel copy; the rest of the window keeps its look until the polish pass.

## Code mode: agents in the window (preview.4, 2026-10-03)
Maintainer decisions: the agent's terminal is built into the window, connecting an agent takes one click, several
agents run from one window; two interface modes, Chat and Code (DECISIONS D-83, D-UI-16). Style and meaning follow the
reference v3 (`Agents`: "Detected on this computer", "Role preset"; `Settings`: a section list on the left); nothing
is drawn that the product does not do.

| What | How | Code |
| --- | --- | --- |
| Interface switch | Settings → Interface: **Chat / Code**. Chat is the default; `window.json` stores `"ui": "code"` only when Code is chosen. An owner with agents sees a one-time banner "Run your agents in this window" (Switch to Code mode / Not now); without a settings file there is nothing to remember the answer in, so no banner | `ui/settings/settings_page.dart`, `ui/code/code_offer.dart`, `state/appearance.dart` |
| Layout (Code) | navigation as icons (64 px; since preview.6 the labelled navigation, icons only below 1,400 px), the chat list 300 px, the conversation, and on the right the agents' **dock** in every section; the dock's width is dragged at its left edge (from 380 px; the conversation keeps 500 px next to the list) and it folds to a 48 px strip (a dot per agent, expand, +). A window too narrow for the dock shows only the strip. The ⓘ card opens when there is room (fold the dock) | `ui/home/home_screen.dart`, `ui/code/agent_dock.dart` |
| Dock | tabs: one per agent, a status dot (running green, stopping amber, failed or non-zero exit red, finished gray), × to close a finished one; "+" starts another; a status line: agent · program, folder, status ("running", "exited with code N", "ended by signal N", "stopped", "did not start"), **Restart** and **Stop** (destructive color); the terminal below | `ui/code/agent_dock.dart`, `ui/code/code_text.dart` |
| Terminal | `xterm` on a pseudo-terminal (`flutter_pty`); always dark (Claude Code and Codex draw for a dark terminal), the app's Plex Mono 12.5 px; Cmd+C / Cmd+V / Cmd+A on a Mac, Ctrl+Shift+C / Ctrl+Shift+V on Linux; copying keeps the blanks a TUI leaves between words | `ui/code/terminal_theme.dart`, `ui/code/terminal_text.dart` |
| Quick replies (preview.6) | a bar under a running agent's terminal: **Approved**, **Check the chat**, **Yes, go ahead** (secondary buttons, 30 px) and **Stop** (red text). A click types a fixed English phrase and Enter ("Approved — continue.", "Check the Antenna chat: read your inbox and continue.", "Yes, go ahead."), the tooltip shows it; Stop sends Escape (Ctrl+C for an own command) and types nothing. Under the buttons, a meta line: the last automatic line ("Woken at 14:32: new messages from Jordan Lee", "Typed “Approved — continue.” at 14:35") or "A wake waits until the agent is idle at its prompt". Frame `51_code_quick_replies(_ru)` | `ui/code/agent_dock.dart` (`QuickReplyBar`) |
| Wake (preview.6, D-UI-23, experimental) | the tab's **⋮** menu: "Wake on new messages" (checked by default, the Experimental tag, the rule in one paragraph); the same switch in each agent row of Agents while Code mode is on, the rule and "Experimental" in its tooltip; kept in `window.json` as `code_wake_off`. The window types one built-in line when a message the agent reads arrives, or "Approved — continue." after an approval, only at Claude Code's empty prompt after 5 s of quiet, at most once per 30 s | `state/code_wake.dart`, `ui/code/agent_dock.dart`, `ui/agents/agents_dialog.dart` |
| Start agent | agent (existing, or "New agent…" with name, role and contacts), program (Claude Code / Codex / own command; the found path or "not found"), working folder (Choose… opens the system folder dialog), owner password (not asked when this window already holds the agent's token), and the note that the token is not shown, copied or saved. Errors in words before any token is issued: CLI not found, no folder, empty command, the agent already running elsewhere (`bound_to`) | `ui/code/start_agent_dialog.dart` |
| Agents section | "Detected on this computer": Claude Code and Codex with **Connect** (opens Start agent; switches to Code mode), Claude Desktop and Cursor, if installed, with **Coming soon**; apps that are not installed are not listed. "Role preset (applies to new agents)": Assistant with access to my projects (label 5) / Front desk: messages only (label 0); nothing preselected until chosen. Footnote "The daemon checks permissions. Agents have no owner commands." In Code mode each agent row has "Start in terminal" | `ui/code/agents_detected.dart`, `ui/agents/agents_page.dart` |
| Settings | sections on the left: General (theme, language), Interface (Chat / Code), Network (local network), Security (lock keys), Agents (role preset), Advanced (daemon, `antenna` command, updates) | `ui/settings/settings_page.dart` |
| Closing the window | with agents running: "Stop the running agents?" → Stop and quit / Cancel | `ui/code/code_offer.dart`, `main.dart` |

What runs, exactly (`lib/state/agent_launch.dart`): `bash -c <wrapper> antenna-agent <folder> <program> <args…>` in a
new pseudo-terminal, with `ANTENNA_AGENT_TOKEN`, `ANTENNA_SOCKET` (the window's socket), `PATH` (the program's folder
first, the usual install folders after), `TERM=xterm-256color`, `COLORTERM=truecolor` and a UTF-8 `LANG` on top of the
window's environment. The program is found in PATH and in the usual folders (`~/.local/bin`, `~/.claude/local`,
`/opt/homebrew/bin`, `/usr/local/bin`, …), since a window started from Finder has a short PATH. The program and the
folder last used for each agent are remembered in `window.json` (`agent_runs`), never the token.

Checks: `test/widget/code_mode_test.dart` (15 scenarios), `test/host/agent_launch_test.dart`, live
`test/protocol/live_code_mode_test.dart`; golden `34_code_mode` (light, dark, Russian), `35_start_agent`,
`36_agents_detected`; `22_settings`, `31_lan(_ru)` and `32_update` were redrawn for the Settings sections.

## Threads, addresses, authorship and batch approvals (x-control/6, D-UI-18, 2026-10-04)
Maintainer decisions: a task for one agent of a contact must not mix with a conversation with another agent of the
same contact or with the person; the owner's own messages must not look like their agent's; several requests are
approved with one password. The window speaks `x-control/6` (CONTROL §20) and falls back to `x-control/5` when the
daemon refuses the newer hello (then: no addresses are sent, threads follow `via_agent` only, several approvals are
decided one by one with the password typed once). Frames: `40_threads` (light, dark, Russian), `41_batch_approvals`.
Since D-UI-32 (below) the thread chips are gone: each counterpart is its own chat in the list, and only the filters
stay inside a chat; the rows "Threads", "Which thread opens" and "Unread" describe that split, now made by the daemon.

| What | How | Code |
| --- | --- | --- |
| Threads | a link's messages are grouped by the counterpart on the contact's side: an incoming message by its author (`via_agent`, or the person), an outgoing one by its addressee (`to_agent` for `to: "agent"`, the person otherwise, `everyone` and unaddressed included). Receipts stay in the person's thread; the window's notes in the thread they were written in. A bar under the header: one chip per thread, the person first ("Jordan Lee", a person icon), then each agent of the contact ("Jordan Lee / claude-backend", the agent mark), each with its unread count; chips radius 8, the selected one on `accentSoft` with an `accentLine` border (reference v3). Shown only when there is a choice: a conversation with a person alone looks as before | `lib/state/threads.dart`, `ui/chat/thread_bar.dart` |
| Filters | inside the open thread: **All**, each topic met in it ("# Avatars") and each of my agents that wrote there or was written to ("builder" with the agent mark), smaller chips on a second line; the default is All | the same |
| Which thread opens | the one with the latest message; the choice is kept per link while the window runs; a stream's live bubble has no address and stands in the open thread; approval cards stand at the end of whichever thread is open | `AppModel.openThreadOf`, `defaultThread` |
| Unread | per thread from `unread` on incoming history items; showing a thread marks exactly its unread messages (`mark_read {up_to_seq: 0, ids}`); a new message in the open thread is marked at once, one in another thread adds to that thread's count and to the link's count in the list. A daemon without v6, or a chat where nothing is flagged while the link counts unread messages, is marked up to the last incoming message, as before | `AppModel._markThreadRead` |
| Composer | an address line above the input when there is a choice: **To** (the person; each active agent of the contact and agent names met in the history; **Everyone**), each item with one line on who reads it; a topic chip once a topic is chosen. The **#** button in the input line opens the topic menu (No topic, the link's topics from `topics` and the history, **New topic…** with a title field, up to 120 characters). Defaults: the open thread's counterpart, and the topic of the topic filter that is on. `send` carries `to`, `to_agent` and `topic_id` (an existing topic) or `topic` (a new title); the reply's topic ID is then kept for the next message. Sending to another counterpart opens that thread, so the owner sees what they sent | `ui/chat/address_line.dart`, `ui/chat/composer.dart`, `AppModel.send` |
| Older contact | when the contact's node does not understand addressing (`peer_addressing: false`) and it has agents, one line under the address: the address is not sent and all of the contact's agents can read the message | `AddressLine` |
| Authorship | in a link where agents take part on either side (or a message went to everyone), the first bubble of each group is signed (since preview.6 the owner's own messages are not, and every other sender also has a picture: "Visual polish to reference v3"): **You**; my agent's name with the agent mark and "your agent"; the contact's label; "<contact> / <agent>" with the agent mark. The addressee follows when it is not the thread's obvious one: "→ everyone", or "→ builder" for an incoming message addressed to one of my agents. My agent's bubble uses the agent tint (`agentFill`: the agent color at 9 % on white, 14 % on the dark surface) with a thin agent-colored border; mine stays solid brand blue. A conversation between two people keeps its unsigned bubbles | `ui/chat/message_bubble.dart` (`AuthorLine`), `lib/theme/tokens.dart` |
| Service logo | the mark before an agent's name comes from `agentServiceLogo(AgentRef)`, built on the AI-apps marks (`AiLogo`, D-UI-17): only for one's own agent and only from what the window knows (the CLI it started in Code mode: claude → Claude Code, codex → OpenAI; otherwise the AI app it connected); nothing is guessed from a name. A contact's agent always gets the neutral agent mark, here and in its avatar (the contact chooses the name, D-UI-18). A brand without a usable mark keeps the neutral icon | `ui/widgets/agent_logo.dart` |
| New agent | Connect an agent, Connect an AI app and Start agent show the switch **Sees messages to everyone**, off by default, with one line ("Off: this agent sees only messages addressed to it by name." / "On: it also sees messages to everyone and messages without an address."); `agent_add` carries `everyone` only for a v6 daemon | `ui/agents/everyone_switch.dart` |
| Batch approvals | with two or more requests the list gets a bar: **Select all** (tri-state), "N selected", **Deny selected** (secondary) and **Approve selected** (primary), and a checkbox before each panel. Approve asks for the password once ("Approve N requests", the fingerprints listed, the `antenna approve <id> <id>…` line) and calls `approve_many` with each request's `fingerprint`; deny calls `deny_many` without a password. The result stays above the list: "2 approved · 1 not decided:" and one red line per request that failed alone (who, what, ID, the reason: expired, changed after it was shown) | `ui/approvals/approvals_view.dart`, `AppModel.approveMany` / `denyMany` |
| In the conversation | when one agent has several pending requests about this conversation, its last card (the one nearest the input line) also offers **Approve all from this agent (N)**: one password for all of them; requests that fail alone are reported in a short message | `ApprovalCard(sameAgent:)` in `ui/chat/chat_view.dart` |
| Agents | each agent row has the switch **Sees messages to everyone** (from `agent_list.everyone`) with one line on what the agent reads; turning it on asks for the owner password (`agent_set`), turning it off does not. Hidden for a daemon older than v6 | `AgentRow` in `ui/agents/agents_dialog.dart` |

Checks: `test/widget/threads_test.dart` (15 scenarios: thread split and filters, no bar between two people, the
recipient and topic defaults and what `send` carries, a new topic continued by ID, labels in English and Russian, unread
per thread and the `mark_read` IDs, the older-contact note, approve-many with one password and fingerprints, a failed
item alone, a wrong password approving nothing, deny-many without a password, "Approve all from this agent", the agent
switch, and a v5 daemon: no addresses, threads by `via_agent`, approvals one by one, a wrong password stopping at the
first request), `test/protocol/client_v6_test.dart` (a stand-in daemon on a real unix socket: the fallback to v5 and
the v6 requests on the wire), `test/widget/contrast_test.dart` (`agentFill`), the live
`test/protocol/live_threads_test.dart` (two real nodes). Changed frames: every frame with a composer gains the **#**
button in the input line (`04`, `06`–`12`, `16`, `23`, `27`, `33`–`35`, ≈ 1,300 px each); the gate and the daemon facts
show `x-control/6` (`01_unlock`, `02_init`, `20_login`, `32_update`); `24_files` and `25_file_preview` show the Chats
counter, since Jordan's agent thread stays unread after his person thread is read; `26_chat_files` and
`30_contact_agents` show Jordan's conversation in threads; `21_agents` shows the new switch.

## Experimental features (D-94, 2026-10-04)
A mechanism of our own design ships marked experimental until it has had its review and time in use (DECISIONS
D-94). The window shows a small **Experimental** tag (`ui/widgets/experimental_tag.dart`): a neutral pill (radius 20
like the other chips, `bg2` fill, a 1 px `lineStrong` border, `textDim` text at 10.5 px, a flask icon), never amber,
accent or the agent violet (it is not a warning, a selection or an agent) and never dashed. Its tooltip: "New in this
preview: tested, still being reviewed." It stands once next to the control or its heading, never on every repeated row.

| Feature | Where the tag is | Code |
| --- | --- | --- |
| Addressing and topics | after the **To** and topic pickers of the composer's address line; the first line of the **#** topic menu, so a conversation between two people keeps its input line without a tag | `ui/chat/address_line.dart` |
| Task authority | AI apps → ⋯ → **Takes tasks from…** and the title of its dialog; Connect, next to "This agent will do tasks from: …". On the agents' rows only a tooltip on "takes tasks from …" and on its edit button | `ui/agents/ai_apps_card.dart`, `ui/agents/tasks_from.dart`, `ui/agents/connect_app_dialog.dart`, `AgentRow` |
| Resident agents, `share_file_content` | not in the window (no controls yet); the user guide says they are experimental | — |
| Local models (D-104, D-UI-31) | the heading of Agents → **Local models** | `ui/agents/local_models_card.dart` |

Checks: `test/widget/experimental_tag_test.dart` (each place with its tooltip, English and Russian; no tag between two
people), `test/widget/contrast_test.dart` (the tag's text on its fill). Changed frames: the tag in the address line of
`26_chat_files`, `30_contact_agents(_ru)` and `40_threads` (light, dark, Russian).

## Attachments wait for Send (2026-10-05)
Maintainer decision: like every messenger, an attached file does not leave at once. The paperclip, a drop on the
conversation or the composer, and a pasted image all put the file above the input as a chip; several can wait at once;
nothing is sent until **Send** (or Enter). Frame: `49_composer_staged`.

| What | How | Code |
| --- | --- | --- |
| Chip | a thumbnail for an image (decoded from the window's own copy, up to 32 MiB; an icon by type otherwise), the name, the size, an ✕ that removes the file and deletes the copy. One line under the chips says who gets them and that the text goes after them as the caption | `ui/chat/attachments.dart` |
| Send | the files first, one `share_file` each in the order they were added, then the text as a message: messengers show the caption under the media, and it never arrives without them | `FilesMixin.sendStaged`, `ui/chat/composer.dart` |
| A refused file | stays on its chip with the reason in the warning color (quota, level, not found); a secret shows "Looks like a secret" and **Approve and send** (the owner password, then that file with `approval_id`). The other files still go; the caption stays in the field until no file is left | `AttachmentChip`, `approveStaged` |
| Per contact | the chips belong to the link they were added for: another chat shows its own; a link whose history is read-only takes no drops | `FilesMixin.staged` |
| Copies | dropped and picked files up to 64 MiB and pasted images are copied into the window's staging folder at once; a copy is deleted after its send, with its chip, on lock, or after a day | `lib/host/outgoing_staging.dart` |

Checks: `test/widget/composer_input_test.dart` (nothing before Send, ✕, the order of files and caption, a refused file
keeping its chip and the caption, approval on the chip, chips per contact), `test/widget/files_test.dart` (the
paperclip and a drop through Send).

## Withdrawing a sent file (preview.5, CONTROL §14, 2026-10-05)
Maintainer decision: a sent file the contact has not answered must not hang as "offered" with no way back. Frame:
`50_file_withdrawn`; `26_chat_files` shows the button on a sent file.

| What | How | Code |
| --- | --- | --- |
| Sender | **Cancel sending** on a sent file's card until the contact accepts or rejects it (`file_withdraw`, no password). When the contact's node cannot delete its copy (`peer_file_withdraw` absent), one line next to the button says a copy it already downloaded would stay there. After it: "Withdrawn: no longer offered to the contact", plus that line again for `contact_cannot_withdraw` | `_OutStatus`, `_WithdrawRow` in `ui/files/file_card.dart`, `FilesMixin.withdrawFile` |
| Receiver | the card says "Withdrawn by the sender: the copy here was deleted", without the verdict, the stages, Preview or Accept | `FileCard` |
| After a reload | the `withdraw_file` / `withdrawn` receipt in the shared history marks the file it refers to (ours or the contact's); its line reads "withdrew a file: withdrawn" | `FilesMixin.applyFileReceipts`, `receiptActionLabel` |
| Answered meanwhile | `not_found`: "Nothing to withdraw: the contact has already answered, or the offer is over"; the receipt then shows the answer | `withdrawFileFlow` |
| Older daemon | `unknown_command`: "This daemon can't withdraw files yet: update Antenna", and the button is no longer offered | `FilesMixin.fileWithdrawSupported` |

Checks: `test/widget/file_withdraw_test.dart` (both answers, the receiver's card, the receipts after a reload,
`not_found`, an older daemon), live `test/protocol/live_file_withdraw_test.dart` (two real daemons).

## Visual polish to reference v3 (preview.6, D-UI-24, 2026-10-05)
Maintainer decision: the window follows the reference v3 style guide closely in style and layout, light and dark (not
a pixel copy); every behaviour, keyboard path and both languages stay. Frames: every regression golden and showcase
frame was redrawn; the ones to look at first are `04_home_chat` (header and bubbles), `40_threads` (a group chat of
agents), `22_settings` and `31_lan` (minimal settings), `17_history_mismatch` and `18_rekey_contact_asks` (the
indicator's warnings), `12_slash_commands` (commands on "/"), `34_code_mode` (the labelled navigation next to the dock);
new: `52_secure_details` (light, dark, Russian: the indicator's popover open) and `53_settings_help` (light, Russian: the
local network's "?" open).

| What | How | Code |
| --- | --- | --- |
| Type scale | H1 28/36 (page titles, empty states), H2 20/28 (conversation and dialog titles), H3 16/24 (card titles), Body 14/20 (messages, main text), Caption 12/16 (secondary text, labels), Small 11/14 (times, metadata, tags); semibold headings (the app ships Plex Sans 300–600). Font size literals in `lib/ui` use only these; the verification code (40 and 34 px, read out loud) and the terminal (12.5 px, its cell grid) are the exceptions | `XType`, `XText` in `lib/theme/tokens.dart` |
| Spacing | an 8 px grid with a 4 px half step for tight inline gaps (4, 8, 12, 16, 24, 32, 48); up to 2 px only as an optical nudge. Every spacer, inset and Wrap gap in `lib/ui` is on it | `XSpace`; `test/widget/design_tokens_test.dart` |
| Radii, motion | 4 (tags), 8 (controls, rows), 12 (cards, panels, popovers), 16 (dialogs, bubbles), 24; hover 0.15 s, popover 0.2 s ease | `XRadius`, `XMotion` |
| Buttons | the theme maps FilledButton → primary, OutlinedButton → secondary, TextButton → tertiary, IconButton → a quiet square (hover fill, press fill, a 2 px focus ring, a selected state for toggles such as the card button); labels on the Body size; no ripple anywhere. Destructive: red text (Stop, Revoke, Deny everything for an hour); the one action that removes something for good (Remove contact, accepting a file despite a threat): red on a soft red fill. The round Send button is the primary style | `lib/theme/buttons.dart` (screens import `ui/widgets/x_buttons.dart`), `lib/theme/x_theme.dart` |
| Conversation header | the avatar with presence, the name (H2), the level badge with its name, then one **Secure** indicator, the network mode and presence as quiet text, the queue if any. The indicator's word and color: **Secure** (green), **Encrypted** (no post-quantum facts), **Not confirmed** (no session facts), **History differs** (red), **Rekey needed** (amber) | `ui/chat/secure_indicator.dart`, `SecureState` in `lib/state/facts.dart` |
| Secure popover | on hover (after 0.3 s), a click or keyboard focus: "Secure connection" and one line per fact in plain words: end-to-end encrypted, post-quantum (or SPQR negotiating, not confirmed), the network mode and what it means, the history (verified with the three animals, their names and digits and the time; or verifying, differs, rolled back, not verified yet); **Verify now**, **Contact card**; **Technical details** opens the raw facts (TLS at pairing and on the connection, the libsignal session, SPQR, incoming) and their source | the same |
| Popover | a card next to its anchor (radius 12, soft shadow, the raised surface in the dark theme), below it or above it when the anchor sits low, aligned to the right edge near the window's edge; it stays while the pointer is over the anchor or the card, closes on leaving (after 0.15 s), Escape, a tap outside or an action in it; Enter and Space toggle it; the anchor shows the focus ring | `ui/widgets/popover.dart` (`XPopover`, `HelpHint`) |
| Group chat | in a link where agents take part: my own messages without a picture or a name; every other sender's picture (28 px) beside the first bubble of its group, its name above (my agent: name, "your agent", **this Mac**); the following bubbles keep the picture's column; my agents' pictures on my side. A group: one sender, one addressee, the same day, under 3 minutes apart, no file card between. Two people: unsigned bubbles as before | `ui/chat/message_bubble.dart`, `continuesGroup` in `lib/state/threads.dart` |
| Agent pictures | `AgentPicture`: the AI's mark (my agent, from the CLI the window started, remembered across restarts, or the AI app it connected) or a neutral monogram on a neutral tile with a small agent badge (every other agent, a contact's always). Photos and a character set come later, as another case ahead of these (*since D-UI-35 they do: "Profile pictures" below*) | `ui/widgets/agent_avatar.dart` |
| This Mac | "this Mac" (macOS) or "this computer" after the name of my agent that was started in this window's terminal (now or remembered) or that an AI app's configuration on this computer names; not for an agent that only holds a token, never for a contact's agent | `agentOnThisComputer`, `ThisComputerTag` |
| Minimal settings | each setting one line: the name (H3), a 16 px **?** and the control on the right; the old hint is the **?**'s text. The role preset: one line per role with its own **?** (the dialogs that create an agent keep the hints inline). The LAN privacy note is behind the **?** and in the page while the owner turns the local network on | `SettingRow` in `ui/settings/settings_page.dart`, `RolePresetChoice(compact:)` |
| Navigation | the labelled navigation (216 px) in both modes; Code mode folds it to icons below 1,400 px | `ui/home/home_screen.dart` (`navCompactBelow`) |
| Composer | the field ("Message or /command…"), the paperclip, the topic button and Send; the commands appear when the owner types "/" | `ui/chat/composer.dart` |
| Thread bar | lighter: the counterparts as outlined chips (the selected one on the soft brand fill), the filters as plain text tabs, no divider under it; shown only when there is a choice, as before | `ui/chat/thread_bar.dart` |
| Chat list | the reference's rows: a 40 px avatar, the name, the level, the time, a one-line preview and the unread count | `ui/home/contact_list.dart` |
| macOS title bar | follows the app's theme and the navigation's color, not the system's appearance (a light window under a dark system had a dark band) | `lib/host/window_chrome.dart`, `macos/Runner/MainFlutterWindow.swift` |

To verify on a Mac: the title bar in both themes under both system appearances; the popovers with a trackpad and with
Tab; the "this Mac" mark next to a Claude Code agent started in Code mode and next to Claude Desktop connected there.
Next: the navigation under the traffic lights (a full-size content view) once a Mac can check window dragging; pictures
for agents and contacts (the character set or a photo) through `AgentPicture`.

Checks: `test/widget/design_tokens_test.dart`, `secure_indicator_test.dart`, `group_chat_test.dart`,
`settings_help_test.dart`, `test/host/window_chrome_test.dart`, `code_mode_test.dart` (the navigation by width),
`contrast_test.dart` (the indicator's words on their tints, the popover, the monogram).

## Check panel and screenshots for Code mode agents (preview.6, D-UI-25…27, 2026-10-05)
The fix-it buttons of the local assistant's first phase (D-96, no model) and a screenshot button for an agent in Code
mode; the wake now follows Claude Code's hooks. Frames: `54_check_panel` (light, dark, Russian),
`55_code_screenshot` (English, Russian); redrawn for the new entries: the sign-in screens (`01_unlock(_ru)`,
`03_unreachable`, `14_daemon_start_error`, `20_login`: "Check Antenna"), the Settings frames (`22_settings`,
`31_lan(_ru)`, `32_update`, `53_settings_help(_ru)`: the "Check" section) and `51_code_quick_replies(_ru)` (the wake
switch's hint).

| What | How | Code |
| --- | --- | --- |
| Check panel | Settings → **Check**; as a dialog from "Check Antenna" on the sign-in screen (the daemon down, the keys locked, signed out) and from "Check" in the daemon details. A line of what it does, **Check again** (secondary, with a spinner while it runs), "Checked at 14:32", then one row per check: a status icon (green check, red error, gray info or "?"), the title (H3 14), the facts in Caption and monospace, the code on the right (`relay_unreachable`…), and the fix as a primary button (secondary where it is optional). A problem row has a soft red border | `ui/settings/check_panel.dart`, `state/doctor.dart` |
| Rows | Antenna's service (daemon); Keys; Relay (links without it: contact · level · relay only, the relay, the error; "The same report in a terminal: `antenna doctor`" with Copy); `<app>: command-line program` for Claude Code, Codex and the CLI apps the owner connected; `<app> needs a restart`; Agent tokens (who holds the agent, who was refused, when) | the same |
| Fixes | Start Antenna; Unlock / Sign in (the password prompt); Turn on the local network (only when a level 3+ link lost its relay; the password); Install guide for `<app>` (opens the vendor's page, copies the link when no browser opens); Add `<folder>` to PATH (a dialog shows the profile file and the two lines before anything is written; a snackbar names the backup); Restart `<app>` (a confirmation: it may ask to save work); Start `<program>` as a new agent / Open AI apps | the same, `host/shell_path.dart` |
| Screenshot button | under a running agent's terminal, after the quick replies: **Screenshot** (secondary, a screen icon; a spinner while the system tool is open); the tooltip says what happens for Claude Code (the image goes into its prompt) or for another program (the path is shown, nothing typed). Hidden when the system has no screenshot tool. "Screenshot attached to Claude Code's prompt: add what to do and press Enter" as a snackbar; under the buttons, "The screenshot waits until Claude Code is back at its prompt" with Cancel, or the kept file's path with Copy and × | `ui/code/screenshot_button.dart`, `state/code_shot.dart`, `host/screenshot.dart` |
| Wake note | the dock's meta line adds "Wake is unavailable for this Claude Code version: its hooks do not report and its screen is not recognised. New messages wait in the chat." when a line waits and neither the hooks nor the screen tell when to type | `ui/code/agent_dock.dart`, `state/code_wake.dart` |
| Settings sections | General, Interface, Network, Security, Agents, **Check**, Advanced | `ui/settings/settings_page.dart` |

To verify on a Mac: the Screen Recording question on the first `screencapture -i`, the paste into Claude Code there,
"Restart Claude Desktop" from the panel, the PATH line in `~/.zprofile` with a new Terminal.

## Local models in the window (preview.8, D-UI-31, 2026-10-06, experimental)
Models and local agents are apart (the maintainer's direction: several local agents at once, each its own agent): a
model is a file on this computer with a download and a state; a local agent runs on a ready model and has its own
conversation. Frames: `65_local_models` (the card, light, dark, Russian), `66_local_chat` (a local agent's
conversation, light, dark, Russian).

| What | How | Code |
| --- | --- | --- |
| The card | Agents → **Local models** with the Experimental tag: one line about this computer; the recommended model with maker, size, memory, estimated speed and a license link; **Download** after a confirmation that names the host; a progress bar with done/size, speed, time left and **Cancel**; **Checking the file…**; **Create agent** and **Remove** when ready; the reason by error code and **Try again** after a failure; **Other models (N)** behind a disclosure, each with its fit in words; one "Coming next" line | `ui/agents/local_models_card.dart` |
| Local agents | under the card: name, model, state in words, the Local badge, **Chat**, a ⋯ menu with **Remove agent** (the password); they leave the general agent list, since they hold no token or app | `ui/agents/local_models_card.dart` |
| Create agent | a name prefilled from the model and made unique, checked against `[A-Za-z0-9._-]{1,64}` and the existing names; the password once, never kept | `ui/agents/local_agent_dialog.dart` |
| Chats | a section **On this computer** above the contacts, one row per local agent | `ui/home/home_screen.dart` |
| Conversation | history from `local_history`; the reply streams into the live bubble; "Loading the model…", "Waiting for memory…"; **Stop**; **New conversation** after a confirmation; a failed turn shows the daemon's reason; the standing line under the field; the model's text plain (control characters and direction overrides removed, no links fetched, no images) | `ui/chat/local_chat_view.dart` |
| Local badge | "Local · runs on this Mac" / "… on this computer" by the daemon's `hardware.os`, with the tooltip of design §7.5; only for `runtime: "local"`; on the row, the header, the author line and the chats list ("Local") | `ui/widgets/local_badge.dart` |
| Older daemons | no card and no section for a daemon below v7, or a v7 daemon without local models (`unknown_command`) | `state/local_models.dart` |

Checks: `test/widget/local_models_test.dart` (every card state, the dialog, streaming, Stop, reset, a failed turn,
plain text, Mac and Linux wording, Russian, an older daemon), `test/protocol/client_local_test.dart`,
`test/protocol/live_local_models_test.dart` (a real daemon with the stand-in runtime), `contrast_test.dart` (the
badge). To verify on a Mac: the card on a 16 GB M1 Pro (the 4B recommended), a download and a chat with Metal.

## Chats per agent (0.2.0, D-113, D-UI-32, 2026-10-06)
Each agent of a contact is its own chat (the maintainer: a chat per agent session that the owner can rename, so that
"Antenna development" and "Volna development" never mix). The daemon sorts the messages and keeps the owner's settings
(CONTROL §26); the window shows them. Frames: `67_agent_chats` (the list with agent chats, renamed, muted and archived
ones, and an agent's chat open; light, dark, Russian), `68_chat_menu` (the chat menu; light, Russian).

| What | How | Code |
| --- | --- | --- |
| The list | the contact's row is the person chat; under it, indented by 24, one row per agent of the contact that wrote or was written to (or that the owner started a chat with): the agent's picture (32), the local name or the agent's name, the agent's name small beside a local name, the latest message, its unread count, a struck bell when its notifications are off, and an always visible **⋮** (right-click opens the same menu on any row). The most recent agent chat first under its contact. Local agents keep their own section **On this computer** (D-UI-31) | `ui/home/contact_list.dart` (`_AgentChatTile`) |
| Archived | **Archived (N)** folds at the end of the list (a tap shows or hides it); an archived row stands alone and says whose agent it is ("Jordan Lee · design-bot"); a new message in it brings it back to its contact | `_ArchivedHeader` |
| The chat menu | from a row's **⋮**, its right-click, or the **⋮** in the conversation header: **Rename…** (**Rename contact…** for the person chat), **Notifications** with **All messages**, **Only when it asks for me**, **Off** (a check on the current one, one hint line each), and **Archive** / **Unarchive** for a chat with an agent. A bordered panel without elevation, 320–360 wide | `ui/home/chat_menu.dart` |
| Rename | a dialog with the name field, "Only you see this name; it is never sent to <contact>.", the name it falls back to, **Remove name**; the dialog owns its text controller (a controller disposed by the caller while the dialog's exit animation still painted it threw) | `showChatRename` |
| New chat | the button **New chat with an agent** next to the list's title opens a dialog: the agents of the contacts that announced themselves or wrote, each with **Start chat** (`chat_set` with no settings) or **Open** for one already listed; when there are none, a line on how one appears (it writes; on a server `antenna connect … --hello`) | `showNewChatDialog` |
| An agent's chat | the header shows the agent's picture, the chat's name and "<contact> · <agent>" under it; the owner's message goes to that agent (`to: agent`), so there is no To line; topics and the filters by the owner's agents stay inside; history pages and the read mark are per chat (`history.chat`, `mark_read.chat`) | `ui/chat/chat_view.dart`, `state/conversation.dart` |
| The person chat | the To line offers the person (the default) or "Everyone on <contact>'s computer", with "every agent there that reads messages to everyone gets it" | `ui/chat/address_line.dart` |
| Search and filters | **Search chats** finds a chat by the contact, the agent's name or the local name; **Unread** and **Queued** count per chat; an open chat stays under Unread until another is opened | `contact_list.dart` |
| Notifications | by the chat's setting (`all`; `asks`: only messages to the owner in person; `off`), only when the window is not in front, at most one per chat in 10 seconds, the text "New message in <chat name>" and never the message (SPEC §11); approval requests notify as before | `ui/app.dart` (`_onNewMessage`), `state/chat_list.dart` (`chatNotifies`) |
| No such agent | under an outgoing bubble whose contact's node has no agent by the addressed name: "No agent named X at <contact>: nobody there reads this message." and "Their agents: …" (or "They have announced no agents yet."), in the warning colour with a struck person icon; the receipt reads "message to an agent: no agent by that name" | `ui/chat/message_bubble.dart` (`_NoAgentLine`) |
| The name to write to | each AI apps row on the Agents page: "Contacts write to it as <name>", selectable | `ui/agents/ai_apps_card.dart` |
| Older daemons | a daemon below v7 or without `chats`: the rows come from the loaded history (the first page of each link), the settings in the menu are disabled with "Needs a newer Antenna daemon on this computer"; renaming the contact still works | `state/chat_list.dart` (`chatsSupported`) |

Checks: `test/widget/chats_test.dart` (9 scenarios: rows and unread per chat, rename, notifications and archive from
the menu, a new agent and New chat, notifications, the no-agent line, search and filters, counts read elsewhere, two
older daemons), `threads_test.dart` (the To line of the person chat, the filters inside a chat, sending from each),
`ai_apps_test.dart`, `test/protocol/live_chats_test.dart` (two real daemons with two agent sessions). To verify on a Mac: the system notification text and its rate, the right-click
menu.

## Teams in the window (0.2.0, D-111, D-UI-34, 2026-10-06, experimental)
A team's lead directs workers on one project; the owner watches the board and approves what the rules keep for the
owner. The window draws the daemon's records (CONTROL §25) and sends the owner's commands; the board is derived state.
Frames: `71_teams` (the list; light, dark, Russian), `72_team_board` (a board with a worker writing live; light, dark,
Russian), `73_task_detail` (a blocked task's conversation; light, dark, Russian), `74_task_changes` (a result's diff),
`75_new_team` (light, dark, Russian), `76_team_apply` (applying with the password; light, Russian),
`77_code_team_worker` (a worker's read-only tab in the Code mode dock).

| What | How | Code |
| --- | --- | --- |
| Navigation | **Teams** after Chats (icon `groups_2`), only for a daemon that has teams; its badge counts the leads' requests to apply and, in teams the owner leads, the results to review and questions to answer | `ui/home/home_screen.dart` |
| The list | the page title and the Experimental tag; one card per team: the name, Active/Stopped, "Waiting for you: apply to main" when the lead asked, the project folder in monospace, the lead ("Led by you"), the workers (and how many work), the tasks per column; the empty state explains a team in three steps with **New team** | `ui/teams/teams_page.dart` |
| The board | ← All teams, the name in H1, the state, Experimental; **New task**, **Add worker**, "Apply to main" and the ⋮ menu (**Log**, **Stop all workers** or **Make active again**, **Remove team**); under 980 px the actions go under the title. The facts line: folder, `antenna/web → main`, the lead, whether workers run commands, who applies, the checks, Local only | `ui/teams/team_board.dart` |
| The request to apply | an accent-tinted banner: "claude asks to put the team's work on main", the commit and when, "Only you can approve it", **Review and apply** | `ApplyBanner` |
| Capacity | a bordered strip of labelled cells in overline captions: the machine with its sandbox and the workers of all teams against its limit, the team's workers at once, each budget line used and free (amber, with the daemon's reason in the tooltip, when it cannot start), **Models in memory**, **Waiting**, **Your other computers** (the own computers that lend themselves, from `team_capacity`); "This computer" with a tooltip when the daemon does not report capacity | `ui/teams/capacity_strip.dart` |
| Workers | a chip per worker: monogram, name, state dot, what it does now, kind and model, state and task; a click opens its panel (facts, live output, **Stop worker**) | `WorkersStrip`, `ui/teams/worker_view.dart` |
| Columns | Open, Working, In review, Blocked, Accepted, Applied (Cancelled only when there are some), on bg2 with radius 12, gaps of 8; filling the width when each column gets 184 px, otherwise 232 px columns that scroll sideways | `team_board.dart` |
| A card | bg1, a 1 px line (amber for a blocked task); the title (3 lines), `#id`, Returned/Assigned, Round N, "Level 2: no commands"; the worker's short name, state dot and a computer icon ("This computer"); the worker's current line while it writes, otherwise the last note (2 lines); the check chip with its time, `+42 −8 · 3 files`, tokens, when | `ui/teams/task_card.dart` |
| A task | a dialog up to 880 × 760: the title in H2, the state chip, the ID, the team, the round, the ceiling; tabs **Overview** (facts, what done means, the live output, the conversation of the task as a timeline with each step's words in a bg2 box, notes), **Changes** (base → commit, the stat, the diff with added and removed lines on their tints, Copy), **Checks** (outcome, command, exit, time, sandbox, who, refused hosts, the sandbox note, the output), **Log**; at the bottom one line of what happens next and the actions of the state, the comment box for Request changes and Answer | `ui/teams/task_dialog.dart` |
| New team | a dialog with sections **Project**, **Lead**, **Workers**, **Rules**, **Machines**; budget lines on bg2 (count, kind, role, the command or the model with its class; the roles a local model's class takes), list fields with chips for checks, registries, toolchain folders and variables; **Limits** folded; the own computers (trust ∞) with whether each lends itself as My devices reports it ("Lends itself to your teams; workers there come in a later version", "Not lending: …"), the switch disabled since it is that computer's own; the form checks before the daemon, then the password prompt | `ui/teams/new_team_dialog.dart` |
| Apply | the dialog says what merges where and that uncommitted changes stay, who asked and when, a moved branch, the tasks in the team's branch (each opens its changes), the CLI line, the password field, "Apply to main"; done: "antenna/web is now in main." | `ui/teams/team_dialogs.dart` |
| Live output | a bg2 box with a status line (a spinner and "Writing…" or "uses Bash", "Turn ended: done", "turn 7"), the text in monospace, selectable, following the end unless the owner scrolled up | `LiveOutput` |
| Code mode | worker tabs after the terminals (state dot, a team icon, the name; tooltip "A worker of the team web: its output, read-only"), the worker's view with **Open board** and **Stop worker**; the lead's built-in line by the wake's rules | `ui/code/agent_dock.dart`, `state/code_wake.dart` |
| Words | the daemon's states and outcomes by code; a word the window does not know shows as the daemon's own | `ui/teams/team_widgets.dart` |
| Older daemons | no section below v7 or without teams; without `team_capacity` the strip is derived and says so; without `team_watch` the live box shows the worker's last detail, "this daemon does not stream workers" | `state/teams.dart` |

Checks: `test/widget/teams_test.dart`, `teams_code_test.dart`, `test/protocol/client_teams_test.dart`,
`test/protocol/live_teams_test.dart` (a real daemon), `contrast_test.dart` (the chips use the "Secure" indicator's
tints). To verify on a Mac: the folder picker and macOS's question for the project folder, a real Claude Code worker's
tab, the lead's line in a real Claude Code.

## Profile pictures (0.2.0, D-115, D-UI-35, 2026-10-06)
The owner chooses a picture for themselves and for each of their agents: an animal of the drawn sets bundled with the
window (`assets/avatars/`: three sets, 55 animals, a cover icon per set) or their own photo; contacts announce theirs.
The daemon lists them (`pictures`, CONTROL §28) and rebuilds every photo; the window only draws. Frames:
`78_picture_picker` (light, Russian; dark on the Modern set, whose dark backgrounds meet the dark theme),
`79_chat_pictures` (Jordan's group chat with pictures; light, dark, Russian), `80_settings_profile`, `81_picture_crop`;
every Settings frame shows the new first section.

| What | How | Code |
| --- | --- | --- |
| Settings → Profile | the first section and the one Settings opens on: one line, the picture as contacts see it (64 px; a neutral person without one, since the window has no name of the owner's to make initials from), "Fox · Soft" / "A photo" / "No picture: contacts see your initials", the **?** with what travels to contacts, **Change…** and **Remove** (red text, only when a picture is set) | `ui/pictures/profile_card.dart` |
| The picker | "Your picture" or "Picture for <agent>": the current picture and one line on what contacts see; a tab per set with its cover (48 px, transparent) and name; the set's animals in a grid of 64 px circles (the 128 px files), seven a row, a tooltip and a screen reader label with the animal's name, the current one with a 2 px brand ring and a check; a click applies at once (`picture_set {drawn}`); **Use my photo…**, **Remove**, **Done**; an error in red under the grid, in words by code (`picture_refused`, `sandbox_unavailable`, `not_found`, `bad_request`) | `ui/pictures/picture_picker.dart` |
| Own photo | the system file dialog (JPEG, PNG, WebP, GIF, BMP, HEIC); the window decodes it at most 2,048 px on its shorter side and shows it in a 320 px square (drag, the wheel or a pinch, a zoom slider up to 4 ×; the image always covers the square; the circle contacts see is outlined, the corners dimmed). **Use photo** draws the visible square at 512 × 512, encodes a PNG (pixels only), writes it into a folder of its own in the window's staging root (`OutgoingStaging`: readable by the daemon, outside macOS protected folders) and sends `picture_set {photo: path}`; the folder is deleted when the daemon answers, success or not. What shows afterwards is the daemon's rebuilt photo | `ui/pictures/photo_crop.dart` |
| Drawing | `PictureFace`: a drawn picture from the window's assets by id (the 128 px file up to 64 px, the 512 px one above), a photo only from the daemon's `picture_photo` bytes, fetched once per id; a circle with a thin ring (`line`, `lineStrong` in dark); an agent's picture keeps the small agent badge (on the left when a presence dot takes the right) | `ui/widgets/profile_picture.dart`, `state/pictures.dart` |
| What wins | people: the picture, else initials as before; my agents: the picture I chose, else the AI's mark the window knows, else the monogram; a contact's agent: the picture its contact announced for it in that link, else the monogram (never from a name, D-UI-18). `AgentPicture` has a drawn and a photo case ahead of the others; `XAvatar` takes the picture | `ui/widgets/agent_avatar.dart`, `ui/widgets/badges.dart` |
| Never drawn | an id the bundled manifest does not know, a contact's photo the daemon withheld (trust level 1, a refused image, no check sandbox here), a photo whose rebuilt bytes have not come, the file the owner chose: initials or the marks as before | `state/pictures.dart` |
| Where | the chat list (contact 40 px, agent rows 32), the conversation header, group chat bubbles (still nothing on my own messages, D-UI-24), the contact card and its agents, the Agents page (my agents with **Picture…**, a local agent's menu, contacts' agents), approval cards for a request of my agent, local agents, My devices (an own computer shows the person picture chosen there, its agents and their requests theirs), the new chat and level notice dialogs | the places' widgets |
| Older daemons | a daemon without `pictures` (`unknown_command`): nobody has a picture, **Picture…** is not offered, Profile says "Needs a newer Antenna daemon on this computer" with **Change…** disabled | `picturesSupported` |

Checks: `test/widget/pictures_test.dart` (14: the protocol shapes; the picker and Remove; errors in words; the photo flow
with a 512 × 512 PNG from the staging folder, deleted after the reply, and the daemon's bytes shown; a refused photo;
a file the window cannot open; every place; My devices; what is never drawn, and the events; three older daemons; every
bundled picture decoding at its size), `settings_help_test.dart` (the Profile **?**),
`test/protocol/live_pictures_test.dart` (two real daemons: a drawn picture and a photo reach the contact's window, the
photo as a JPEG the daemon made). Negative controls seen failing: the staged file drawn instead of `picture_photo`, a
picture on my own messages, an unknown id drawn, a withheld photo fetched, the picker's actions on an older daemon. To
verify on a Mac: the file dialog's image filter, HEIC decoding, a phone photo's EXIF orientation, the pinch zoom.

## The agent map (0.2.0, D-123, D-UI-38, D-UI-47, 2026-10-06, experimental)
Who works with whom, and an editor to change it: lines drawn between agents to connect them, a click on a line to see
what it does or to disconnect it, groups and cards arranged as the owner likes. The map draws the daemon's facts
(CONTROL §30: `agent_list` with each agent's `counterpart` and `local_routes`, `devices` with what the own computers
report, `contacts`, the teams, `agent_traffic`); the window keeps only the ID of a request it caused on another own
computer (to draw that line as waiting) and how the owner arranged the map (its settings file). Frames:
`86_agent_map` (light, dark, Russian), `87_agent_connect` (light, Russian), `93_map_line_selected` (light, Russian),
`94_local_connect` (light, Russian); the Agents frames with the header toggle (`21`, `28`, `36`, `37*`, `65*`).

| What | How | Code |
| --- | --- | --- |
| Where | Agents → **List** \| **Map**, a two-way toggle in the header next to **Connect an agent**, kept while the window runs; not a navigation item (the map is a view of the agents, and an item would redraw every frame); in Map the page is the header, the Experimental tag with one line on how to use it, the legend, and a canvas that fills the rest of the page at any window size | `ui/agents/agents_page.dart`, `ui/widgets/section_page.dart` (`body`) |
| The canvas | its own small viewport (a `Transform` under a `Listener`), not `InteractiveViewer`, so a drag on a group, a card or a handle is that thing's own gesture and a plain mouse wheel pans: a drag on the empty canvas, the wheel and a two-finger trackpad scroll pan; a pinch and Ctrl or Cmd with the wheel zoom around the pointer; the controls − / level / + / **Fit** (bottom right; a click on the level is 100 %); zoom 0.4–2.0, Fit at most 100 % | `ui/agents/agent_map_canvas.dart` |
| Groups | **This computer** in the middle, the own computers (∞) on the left, the contacts (the person, then their agents) on the right: three columns in map coordinates whatever the window's size or the counts, fitted into the view when the map opens; an own computer is never placed among the contacts, also when it is the only other computer or has not reported itself ("Waiting for its report" in its header, with a tooltip; online or offline when known) | `ui/agents/agent_map_layout.dart` (`defaultPositions`), `state/agent_map_graph.dart` |
| Free layout | a group moves by its header (grab cursor) anywhere on the canvas; a card moves by its body to another slot of its group, the others making room; a card dropped on another group stays and the status strip says "An agent stays on its computer…"; from the first move every group keeps its place; **Arrange automatically** (top right) puts groups and cards back and fits the view | `ui/agents/agent_map_view.dart` |
| Kept per window | `agent_map` in the window's settings file: `{"clusters": {id: [x, y]}, "order": {id: [node…]}, "view": [scale, dx, dy], "recent": bool}`, never in the daemon; written when a move ends and shortly after the view settles; read leniently (a malformed entry is dropped, the zoom clamped); a group or card it does not know is placed automatically (a new group below what is already in its column), one that is gone is ignored | `state/agent_map_prefs.dart`, `state/appearance.dart` |
| Cards | the agent's picture (`AgentAvatar`, with main's profile pictures), its name, a status dot, the kind (the app, "Local model", "Replies on wake", "Worker · <team>", "In person"); the ⋯ menu (**Connect to…**, **Disconnect…**); cards that cannot be connected (a wake agent, a team's worker, a local-model agent, you in person) carry a crossed-link icon and say why in the tooltip | `ui/agents/agent_map_widgets.dart` |
| Handles | a small circle (port) on the side of every card a line can start from, always visible: this computer's agents on both sides, another computer's agents and persons on the side facing this computer; dragging from a handle draws a line, dragging the body moves the card (Node-RED's rule); no handles with a daemon that knows no connections | `agent_map_view.dart` (`_handles`), `MapHandle` |
| Lines | a line leaves each card on the side facing the other group and ends at the handle's edge, so its arrowheads show; between two agents of one group (a team, a local connection, their recent messages) it is an arc in a lane inside the group, on the side with fewer lines leaving it; connected: solid accent 2 px with arrowheads where messages without an address go (both ends when each side points at the other); waiting: the same line muted, "Waiting for approval on <computer>"; a team: thin violet with the team's name; **tasks** at the end that takes the other end's messages as tasks; never dashed; a legend under the header | `agent_map_layout.dart` (`MapLinesPainter`) |
| Recent messages | a layer, **Show recent messages** (top right), off by default and kept with the arrangement: thin grey lines without arrowheads, labelled "messages, not connected · 2 h ago", only where nothing is set between the two; never removable | `agent_map_view.dart`, `agent_map_popover.dart` |
| Selecting a line | a click on a line (or its dot or label) selects it: drawn thicker with a soft glow, and a popover under the click (above it near the bottom) says in words what the line does (its ends and computer, where each side's messages without an address go, who takes tasks); **Disconnect** (red), **Options…** (today's disconnect dialog with its choices) and, for a waiting line, **Approve now**; "Delete or Backspace disconnects it."; Escape, the ×, or a click on the empty canvas deselects | `agent_map_popover.dart` (`mapLineText`, `MapLinePopover`) |
| What cannot be disconnected | recent messages (the popover: "<a> and <b>: messages, not connected", the counts and the last time, "This is not a connection: there is nothing to disconnect.", "To send <agent>'s messages without an address somewhere, draw a line from its handle."), a team's line (set by the team), a line another computer drew to you in person ("Set on <computer>"): no Disconnect, and Delete sends nothing | `state/agent_map.dart` (`defaultDisconnectFor`) |
| Hover | a line under the pointer is drawn a little thicker, and a tip near the pointer says the same as its popover | `MapLineTip` |
| Feedback | a status strip on the canvas (bottom left) says every action: a drop that sends nothing and why; "Disconnecting <a> and <b>…" with a spinner while the line is drawn faded; "Disconnected <a> and <b>" with the other side in words (and **Approve now** when that computer asks); "Could not disconnect…" with the reason in words (the daemon's own message for a code the window does not know), kept until closed; after the connect dialogs close, "Connected <a> and <b>" or why not | `MapStatusStrip`, `agent_map_view.dart` (`_report`) |
| Connect | drawing a line to another computer's agent or person opens "Connect volna and session-2": both ends with their computers; **On this computer** (where volna's messages without an address go; "Messages from Mac mini are tasks for volna", on by default for an own computer or a contact it already takes tasks from, off for a contact, with a hint that tasks are for people you trust; `tasks` is sent only when it changes the state, so a default list stays the default); **On Mac mini** for an own computer's agent (its counterpart, "Messages from this computer are tasks for session-2", on by default, and that Mac mini asks you to approve it, there or in My devices); for a contact's agent only "Bob's side is Bob's decision"; for a person, where the messages go; the owner password, the CLI line, **Connect** with a spinner | `ui/agents/agent_connect_dialog.dart`, `state/agent_map.dart` (`connectRequestFor`) |
| Two agents of this computer | with a daemon that sends `local_routes`: a line from one of this computer's agents to another opens "Connect docs-bot with reviewer on this computer": "Messages from docs-bot without an address go to reviewer." (the line), then three checkboxes, all on: "Messages from reviewer without an address go to docs-bot" (`ask`), "Messages from docs-bot are tasks for reviewer" (`peer_tasks`), "Messages from reviewer are tasks for docs-bot" (`tasks`); in a box, what keeps it safe: the messages stay on this computer, a message carries what its writer has read, a more sensitive agent cannot write to a less sensitive one, chains between agents are limited (8 in a row within 10 minutes, 30 a minute); the Experimental tag, the password, the CLI line; "Connected on this computer." The line is drawn inside the group; disconnecting sends `agent_disconnect` with `local`, no password, and its popover and dialog say that the unread messages between the two are dropped. An older daemon: "Connecting two agents of this computer needs a newer Antenna on this computer.", nothing sent; one that answers `local` with "unknown field" gets the same words and keeps its other connections | `ui/agents/local_connect_dialog.dart`, `state/agent_map.dart` (`DropConnectLocal`, `localConnectionsSupported`) |
| After | "Connected on this computer." and the other side in words: waiting for your approval on Mac mini with **Approve now** (the request's own card from My devices, with Touch ID or the password, answered there), already so, the contact's decision, not reachable with **Ask again**, an Antenna there that does not know connections, a refusal with the daemon's words | `agent_connect_dialog.dart` |
| Disconnect | from a line's popover (the defaults: keep the tasks, ask an own computer to clear its side) or Delete; **Options…** or the agent's card: what goes away, "Also stop taking tasks from Mac mini" (off), "Ask Mac mini to disconnect session-2 too" (on; an approval request there), "Also ask session-2 to stop taking tasks from this computer" (off, only while asking); no password; a red **Disconnect** | `agent_connect_dialog.dart`, `local_connect_dialog.dart` |
| The agent's card | in **List**: "Default counterpart: session-2 · Mac mini" (or "· This computer") with **Disconnect…**, "Connected on this computer: …" for another agent here it is connected to, "Connected from: …" for a line only another computer drew | `ui/agents/agent_connection_line.dart` |
| Approval cards | `connect_agent` and `disconnect_agent` requests (made by another own computer) have their own titles and reason ("a connection between agents"); the requester is drawn as a computer, not as an agent | `ui/approvals/approval_card.dart`, `ui/devices/device_request.dart` |
| Refresh | when the map shows and every 15 s while it does, and on the owner's `agent` (also `connection`) and `device` events | `state/agent_map.dart` |
| Older daemons | `agent_traffic` answered `unknown_command` or `bad_request` (unknown variant): the agents without connections, no handles, "Connecting agents needs a newer Antenna on this computer", nothing sent; the arrangement still works | `state/agent_map.dart` |

Checks: `test/widget/agent_map_graph_test.dart` (the graph, the drops, the placement, the arrangement, local
connections, what Disconnect sends), `test/widget/agent_map_test.dart` (the map, connecting by a handle, the dialogs'
requests, the popover and Delete with pending, done and failed feedback, recent messages, hover, moving and keeping
the arrangement, pan and zoom, the placement, two agents of this computer, older daemons, the agent's card),
`test/widget/agent_map_prefs_test.dart`, `test/protocol/client_connections_test.dart`,
`test/protocol/live_agent_map_test.dart` (two real daemons; one daemon with two local agents). To verify on a Mac:
a trackpad's two-finger scroll and pinch, Cmd with the wheel, the frames there.

## Setting up an agent's folder, and approvals that do not expire unnoticed (0.2.0, D-124, D-UI-39, 2026-10-06)
What needs the owner's authority in an agent's working folder is set by the owner in **Start an agent**, shown before
it is written and done once; and an approval request reaches the owner wherever their window is before it runs out.
Frame: `35_start_agent` (the compact line of the section, the subtitle).

| What | How | Code |
| --- | --- | --- |
| Where | **Set up this folder**, under the working folder, for Claude Code and Codex (not for an own command); compact: one line of what Start will do first ("Before the start: write AGENTS.md, write CLAUDE.md, add 1 permission rule."), "This folder is set up for the agent." or "Nothing in this folder will be changed." | `ui/code/agent_setup_section.dart` |
| Choices | **Instructions for the agent** (`AGENTS.md`, and for Claude Code a `CLAUDE.md` with `@AGENTS.md`, from the CLI's own template; an existing file is kept and shown as kept); **Git identity for this folder** (name and email; `git init` first when the folder has no `.git`; a value git already has there is not set again); for Claude Code, one checkbox per rule: Antenna's tools (`mcp__antenna`), the antenna command (`Bash(antenna:*)`), git (`Bash(git:*)`) | `state/agent_setup.dart` |
| Defaults | in the agent's own folder (`~/Antenna/agents/<name>`): the instructions while `AGENTS.md` is missing and Antenna's tools; in a project folder the owner chose: nothing (its repository is the owner's); git never | `AgentSetupController` |
| What will be written | the exact plan in monospace: paths, file contents, commands, the rules added and the new settings file | `agent_setup_section.dart` |
| Start | the plan is made again from the folder as it is then and applied before the token is issued; nothing that exists is overwritten (exclusive create, never through a link); `.claude/settings.json` stays strict JSON or is not touched, keeps its keys in order, and is copied to `settings.json.antenna-backup` first; a temp file and a rename; a refusal or a failing git shows the reason and starts nothing | `host/agent_folder.dart` |
| One source | the templates and the rules are the CLI's (`antenna agent setup`, `setup.rs`), compared byte for byte by a Rust unit test | `agentsMdTemplate`, `claudeMdTemplate`, `agentSetupRules` |
| Approval notifications | while the window is not in focus: a new request here ("Antenna: approval needed") or in an own device's status ("Antenna: approval needed on *computer*"; requests already there at the first `devices` read are not news); once per request, about two minutes before it runs out and while still pending, "Antenna: an approval expires soon" (or "… on *computer* …"); every body "*agent* is waiting for your approval: *action* → *target* · expires in N min" (whole minutes, rounded up). A device's time left is counted in that computer's clock from when its status arrived, so the clocks are never compared. Facts only: the alert type has no field for the request text (SPEC §11); a reminder that falls while the window is in focus is not shown later | `state/approval_alerts.dart`, `ui/app.dart`, `approval_card.dart` |

Checks: `test/host/agent_setup_test.dart` (8, with a real temp folder and the real git once), `test/widget/start_agent_setup_test.dart`
(7: defaults, git without a name, the exact preview, Start applies then launches, non-strict settings refused and
nothing started, a failing git, a set-up folder untouched, Codex and an own command, a chosen project folder with
nothing ticked, a new agent), `test/widget/approval_alerts_test.dart` (5), `approvals_test.dart` (the time left, no
request text). To verify on a Mac: `/usr/bin/git` without the developer tools (it should show "git … ended with code
N" and start nothing), the notifications' text there.

## Approver agents (0.2.0, D-127, D-UI-40, 2026-10-06, experimental)
An agent the owner trusts can answer the owner's other agents' approval requests, only inside the owner's own
computers. The window keeps the person in the loop at three moments: naming (warned and authenticated), deciding (who
decided and why, on the card itself) and reviewing (one list with Revoke). Nothing is drawn until the daemon has
answered `approvers`, so an older daemon shows nothing that does nothing. Frames: `88_approver_warning` (light,
Russian), `89_approver_card` (light, dark, Russian), `90_approvers_list` (light, Russian).

| What | How | Code |
| --- | --- | --- |
| Naming | an agent's **Can approve for…** (a person-with-check icon, next to "Takes tasks from…" and "Questions go to…") opens "Can <agent> approve for you?" with the Experimental tag: No / Yes, **Whose requests** (All my agents, or chosen ones; the approver itself is never listed), **Which requests** (Messages, Files it sends, File requests, Files it accepts; all four send `null`, which covers kinds added later), and a line above Save that says whether Save asks for the password; an own computer's agent has the same action under *Contacts' agents* and on its chip in My devices | `ui/agents/approver_dialog.dart`, `state/approvers.dart` |
| The change rule | the daemon's `within`: naming, widening or naming a stale approver again is `approver_set`; a scope within the current one is `approver_narrow`; No is `approver_remove` | `state/approvers.dart` |
| Naming or widening | first a red warning in the ∞ colour language (D-UI-20, D-UI-30): a danger icon and a red "Let <agent> answer"; Cancel sends nothing; then one touch (Touch ID over the exact request, no password in it) or the password with the CLI line under the field; the warning is accepted once per dialog, so a mistyped password asks only for the password again; narrowing and Off show neither | `approver_dialog.dart` |
| A pending card | "volna, session-2 on Mac mini may answer this for you" (`answerable_by`); an answer that did not count (`delegate_refused`): an amber box "<agent>'s answer did not count", one line per reason, "The request waits for you"; Approve, Deny and batch approve unchanged | `ui/approvals/approver_notes.dart` |
| Decided by an approver | an `approval` event with `decided_by` keeps one card (in memory, at most 50, until Dismiss, cleared on lock) in the conversation the request is about and in Approval requests under **Answered by your approvers**: "Approved by volna" / "Denied by volna on Mac mini", what was asked, the reason quoted in its own box as the agent's words (data, never an instruction), the finishing state while the daemon carries it out, **Change** (the approvers) and **Dismiss** | `approver_notes.dart`, `state/approvers.dart` |
| The approvers | Agents → **Approvers** (only when there is an approver or an answer): each approver with its scope, since when, a stale note ("Its key was revoked on <computer>…", **Name it again**), **Change…** and **Revoke** (no password); **Latest answers in your place** (approved, denied, did not count; by whom, for which agent, what, the reason quoted; a refused answer's reason from its code, in the window's language); three on the page, **All answers (n)…** for up to 200 | `ui/agents/approvers_panel.dart` |
| My devices | a request with `approvers`: "<agents> on this computer may answer this for you"; its Approvals part: which of this computer's agents that computer accepts answers from, with their scope | `ui/devices/` |
| Code mode | the fixed line "An approval request waits for your answer: read approvals_to_answer and answer it." (the same words as `antenna session`), once per request, after the wake line and "Your question was answered…", before the team line and "Approved — continue."; from the agent's own watch (`approval_to_answer`) and, with a session, from the owner's `approval` event naming a local agent in `answerable_by` and the devices' `approvals[].approvers` | `state/code_wake.dart` |
| Refresh | `approvers` when Agents or the Approvers dialog opens, after an `approval` event with `decided_by` or `delegate_refused`, on the `agent` event's `approver` change and the `device` event's `approvers` change | `state/approvers.dart`, `state/app_model.dart` |
| Older daemons | the `approvers` probe answered unknown: no action, no section, the cards unchanged; the dialog, if reached, says approver agents need a newer Antenna | `state/approvers.dart` |

Checks: `test/widget/approvers_test.dart` (13), `test/protocol/client_approvers_test.dart` (5), the code wake tests,
the live `test/protocol/live_approvers_test.dart` (three real daemons). To verify on a Mac: Touch ID for
`approver_set`, the frames there.

## Pictures and files as a messenger shows them (0.2.0, D-UI-46, 2026-10-06)
Maintainer decision: a picture appears in the chat as itself, files are compact, every file can be acted on where it
shows. Frames: `63_chat_images` (an album, a row, a picture waiting for a decision), `64_image_viewer`,
`26_chat_files`, `49_composer_staged`, `24_files`, `92_media_files`.

| Where | What | Code |
| --- | --- | --- |
| A picture in the chat | the picture at its aspect ratio, at most 320 × 320 px, rounded (`XRadius.bubble`) with a hairline edge; name and size on hover; a 22 px badge only for something to say (checking, waiting, a label, a sent file's fate), its words in the tooltip; decision buttons under one waiting for the owner; no picture to show: the compact row | `ui/chat/chat_media.dart` (`ChatPicture`) |
| Albums | pictures sent the same way within two minutes, same day, up to ten: one 320 px grid (2; 1 over 2; rows of 2 and 3), 2 px gaps | `ChatAlbum`, `state/media.dart` (`joinsAlbum`, `albumRows`) |
| A file in the chat | one row at most 440 px: type icon, name, size, short state; one line under it at most (the card's words for the state, "Saved to ~/…" with Show in Finder, Cancel sending, a text file's first line); the full card only for a decision with something to read first and for a release manifest | `FileRowCompact`, `FileStatusNote` |
| Actions | right click and ⋯: Open, Show in Finder, Save as…, Copy image, Copy path, Safe preview, Cancel sending, each only where it works | `ui/files/file_menu.dart` |
| The viewer | black at 92 %, a top bar (name, size, position, zoom level; zoom out, fit, zoom in; Save as…, Copy, Show in Finder, Open; close), side arrows; keys ← → + − 0 Esc; a tap beside the picture closes it | `ui/files/image_viewer.dart` |
| The composer | a picture is a 72 px square with its ✕, a file a chip; click or Space opens; drag reorders (the sending order) | `ui/chat/attachments.dart` |
| Media and files | from the header's pictures button, the chat menu and the contact card: Images grid, Files and Text rows, newest first, search by name; an agent chat starts with its own files | `ui/files/media_files.dart` |
| The Files screen | what needs the owner as cards on top, then downloading, then All files: pictures as a grid (or a list), the rest as rows; filters Images, Files, Text; search | `ui/files/files_page.dart` |
| An own computer's card | Files from this computer: save folders for it and each agent (Choose folder…, Default), Saved without asking (Programs, Installers and disk images, an extension) | `ui/contact/file_prefs_section.dart`, `state/file_prefs.dart` |

Checks: `chat_media_test.dart`, `image_viewer_test.dart`, `composer_attachments_test.dart`, `media_files_test.dart`,
`files_page_test.dart`, `file_prefs_test.dart`. To verify on a Mac: dragging attachments with a real pointer, Show in
Finder, the save dialog, Copy image.
