<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# How to…

Task recipes that cross several pages of this guide. Each links to the USER-GUIDE walkthrough for the full steps.

## Set up your own machines

Tick **This is my own computer (∞)** when pairing a computer of your own — one tick per machine, no clicks per file
afterwards. Full detail: [Contacts and trust](contacts.md) and [USER-GUIDE: "Your own
machines"](../USER-GUIDE.md#your-own-machines).

## Run a node on a server

Step by step, with every command to type, from installing to an agent there that your Mac's agents talk to: [Add a
server and its agents](add-a-server.md).

Install Antenna's archive on a Linux server (`install.sh`, a systemd user service) — or, on Ubuntu or Fedora, the
`antenna` `.deb`/`.rpm` package, which does the same without unpacking anything by hand — then pair it with your Mac
through an ordinary invite. A package install updates with your package manager, not `antenna update`. Full steps:
[USER-GUIDE: "A node on a server"](../USER-GUIDE.md#a-node-on-a-server).

A Claude Code or Codex session on the server is woken like one in Code mode when it runs inside tmux through
`antenna session start <agent>` (experimental): `antenna session attach <agent>` to look in, Ctrl-b d to leave it
running, `antenna session list` for what runs and the last line it got.

## Add an agent, and connect two agents

The three ways to add an agent on this computer, with the button and the command for each: [Add an agent on this
computer](add-an-agent.md). Pointing one agent at another, on another computer of yours or a contact's: [Connect two
agents](connect-agents.md).

## Talk without internet, on the same network

Turn on **Local network (no internet)** in [Settings → Network](settings.md#network): it works only for contacts at
trust level 3 and above, and only on a network you trust. Full detail: [USER-GUIDE: "Without internet, on the same
network (LAN)"](../USER-GUIDE.md#without-internet-on-the-same-network-lan).

## Update several computers

Each computer updates on its own: turn on **Install signed updates by itself** per machine (see [Updates](updates.md)),
or install a release by hand on each one. **My devices** shows every computer's Antenna version, whether it installs
updates by itself, a release ready there and the last update, and its health ([My devices](my-devices.md)).

## Handle a lost or stolen computer

1. On any of your other computers: **My devices** → the lost computer's card → **Revoke this computer** → the password
   (`antenna devices revoke <computer>` in a terminal). The link to it is wiped there (the history stays unless you
   ask), and your other computers are told: they stop accepting its keys for approvals at once.
2. On each of your other computers, its card says it was reported lost: **Revoke this computer** there too. Until you
   do, that link still carries messages if the lost computer is running and unlocked; it can no longer approve
   anything.
3. Contacts linked only to the lost computer cannot be told from your other computers: each link is end-to-end
   encrypted on its own. Tell them another way, and pair again from a new computer.

What stays protected on the lost computer: its keys are encrypted under its password (Argon2id), and a Touch ID key
cannot leave its Secure Enclave. Detail: [My devices](my-devices.md#a-lost-or-stolen-computer).

## Keep data fully local

A model that runs on this computer, with no account and no internet once downloaded: [Local models](local-models.md).

## If something does not work

[USER-GUIDE: "If something does not work"](../USER-GUIDE.md#if-something-does-not-work) has the exact messages for
each of the recipes above.
