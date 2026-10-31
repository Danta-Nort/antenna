#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Release notes (English) for `gh release create --notes-file`: what is inside, how to install, what has not been
# verified, link to the user guide. Usage: packaging/release-notes.sh <tag> <commit> <repository URL> > notes.md
# LINUX_PENDING=1: a draft that has only the macOS files so far; the notes say that the Linux files follow (D-81).
# SIGNATURE_PENDING=1: a draft whose signed release manifest is not there yet (D-82).
# packaging/release-linux.sh regenerates the notes without either when it publishes the release.
set -euo pipefail
TAG="${1:?tag, e.g. v0.1.0-preview.1}"
COMMIT="${2:?commit}"
REPO="${3:?repository URL, e.g. https://github.com/owner/repo}"
VERSION="${TAG#v}"
GUIDE="$REPO/blob/$TAG/docs/USER-GUIDE.md"
PRE=""
case "$VERSION" in *-*) PRE=1 ;; esac

cat <<EOF
**Antenna $VERSION** is a messenger for people and their AI assistants: every pair of contacts gets its own encrypted
direct channel (end-to-end, with post-quantum protection), with no accounts and no third-party servers. What an
assistant may do is enforced by the program, not by the model. Commit \`$COMMIT\`.
EOF
if [ -n "${LINUX_PENDING:-}" ]; then
  cat <<'EOF'

> **Linux files follow.** This draft has the macOS files so far; the Linux archives are added once they are built and
> checked, together with a `SHA256SUMS.txt` that covers every file, and then the release is published.
EOF
fi
if [ -n "${SIGNATURE_PENDING:-}" ]; then
  cat <<'EOF'

> **The signed release manifest follows.** It is made on the build machine that holds the release key, together with
> the final `SHA256SUMS.txt`, and then the release is published.
EOF
fi
if [ -n "$PRE" ]; then
  cat <<'EOF'

> **Preview release.** The protocol and data formats are not frozen yet, and there has been no independent security
> audit. Use it only for conversations you are willing to risk.
EOF
else
  cat <<'EOF'

> **Status: early.** The cryptography is Signal's own library and the pairing protocol is formally verified, but the
> whole has not had an independent security audit yet (planned before 1.0). Report security issues privately, as
> `SECURITY.md` describes.
EOF
fi
cat <<EOF

## Downloads

| File | What it is for |
| --- | --- |
| \`Antenna-$VERSION-macos-arm64.dmg\` | Mac with Apple Silicon (M1 or later): the app, signed and notarized, with \`antenna\` (commands) and \`antennad\` (daemon) built in |
| \`antenna-$VERSION-macos-arm64-cli.tar.gz\` | Mac without the app: just \`antenna\` and \`antennad\` (the same signed binaries as in the .dmg) |
| \`antenna-desktop-$VERSION-linux-x86_64.tar.gz\` | Linux desktop (GTK 3): the app, with \`antenna\` and \`antennad\` built in |
| \`antenna-desktop-$VERSION-linux-x86_64.deb\`, \`antenna-$VERSION-linux-x86_64.deb\` | Ubuntu and Debian: the app and the node as packages (install both for the app) |
| \`antenna-$VERSION-linux-x86_64.tar.gz\` | Linux server or headless machine: \`antenna\`, \`antennad\`, \`install.sh\`, a systemd user service |
| \`antenna-$VERSION-manifest.json\` and \`.sig\` | The signed release manifest: what \`antenna update\` checks before it installs anything (sizes, SHA-256 and BLAKE3 of every file, signed with the release key) |
| \`SHA256SUMS.txt\` | Checksums: \`shasum -a 256 -c SHA256SUMS.txt\` (Mac) or \`sha256sum -c SHA256SUMS.txt\` (Linux) |

## Install

**Mac.** Open the .dmg, drag **Antenna** to Applications and start it from there. The app starts its daemon itself
and asks you to create your node with a password. To get the \`antenna\` command in Terminal: Settings → "antenna
command in the terminal…". \`antenna://\` invite links open the app.

**Linux desktop.**

\`\`\`
tar xzf antenna-desktop-$VERSION-linux-x86_64.tar.gz && cd antenna-desktop-$VERSION-linux-x86_64
./antenna-desktop               # the app starts the daemon itself and asks you to create your node
./install-desktop-entry.sh      # optional: app menu entry and antenna:// links (in ~/.local/share, no root)
\`\`\`

**Linux server.**

\`\`\`
tar xzf antenna-$VERSION-linux-x86_64.tar.gz && cd antenna-$VERSION-linux-x86_64
./install.sh            # ~/.local/bin, systemd user service antennad, antenna init
\`\`\`

**Then:** invite your other computer or a person (**New contact → Invite** in the app, \`antenna invite\` in a
terminal), read the six-digit code to them, and connect an AI agent (**Agents → AI apps → Connect**, or
\`antenna connect claude-code --agent <name>\` in your project folder).

**Updates.** Once a day Antenna checks for a newer signed release. When there is one, a banner says so; **Install**
asks for your password, and Antenna comes back unlocked after the restart. Nothing installs before you press
Install. To turn the check off, put \`off\` into \`~/.config/antenna/update-url\`. Packages installed with \`apt\`
update with \`apt\`.

Guide: [getting started]($REPO/blob/$TAG/docs/guide/getting-started.md) · [user guide]($GUIDE).

## Known limits

- Apple Silicon Macs and x86_64 Linux only; Windows and phones are not available yet.
- The Linux app is verified by automation (build, launch under a virtual display, an antenna:// link); Linux
  desktops have had less hands-on use than macOS.
- Features marked *experimental* in the app (teams, local models, the agent map, approver agents, Touch ID, updates
  that install by themselves) are new mechanisms of our own and stay labelled until they have had more review.
EOF
