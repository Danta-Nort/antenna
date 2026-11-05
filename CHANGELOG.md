<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Changelog

All notable changes to Antenna are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0, command-line options and
settings may still change between minor versions; the link protocol stays compatible with older nodes through
capability exchange, and the control protocol only adds.

## [Unreleased]

## [0.1.0] - 2026-11-05

The first public release.

### Added
- **Messenger.** One-to-one conversations with people and agents, each over its own link: end-to-end encrypted with
  libsignal (the post-quantum Triple Ratchet) on top of iroh/QUIC with post-quantum TLS. No accounts, no phone numbers,
  no Antenna servers holding messages; a relay is used only when a direct path fails.
- **Pairing** by a one-time invite (link or QR code) and a six-digit verification code read from the other screen. The
  protocol is modelled in ProVerif with negative controls ([`formal/`](formal/)).
- **Trust levels** 1–4 and ∞ (my computer) for every contact, enforced by the daemon: what a contact and its agents may
  send, read and run.
- **Agents.** One-click connection of Claude Code, Codex, ChatGPT, Claude Desktop, Cursor, Gemini CLI and other MCP
  apps (`antenna connect`); an agent gets its own token, never the owner's password, and the owner's commands do not
  exist for it. Messages wake the agent they are addressed to; approvals and agents' questions come to every one of
  the owner's computers.
- **Code mode** in the desktop app: a Claude Code session in a panel next to the conversation, woken by each new
  message; `antenna session start` does the same on a server without a window.
- **Files.** Incoming files wait in quarantine, are checked in a sandbox and shown as rebuilt previews; outgoing files
  and messages are scanned for keys, passwords and tokens before they leave. A shared folder per contact at levels 3–4.
- **History verification.** Both sides keep a signed, hash-linked history and compare it, so a dropped or altered
  message shows up.
- **Desktop app** for macOS (Apple Silicon, signed and notarized) and Linux (x86_64, `.tar.gz` and `.deb`), in English
  and Russian.
- **Server node** for Linux: a one-line install as a systemd user service, no root needed.
- **Signed updates.** Every release has a signed manifest; the app and `antenna update` install only releases whose
  signature checks out.
- **Experimental**, labelled as such in the app: teams of agents, local models, the agent map, approver agents,
  Touch ID, automatic installation of updates.

[Unreleased]: https://github.com/Danta-Nort/antenna/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Danta-Nort/antenna/releases/tag/v0.1.0
