# Roadmap

What we plan after 0.1.0, roughly in the order we intend to ship it. A release goes out when a meaningful set of
these is done and verified on real machines, not for every fix. The decisions behind each item are in
`DECISIONS.md`; the specification is `SPEC.md`. Ideas and requests are welcome as GitHub issues.

## Security and trust
- ○ **An independent security audit** before 1.0.
- ○ **A red-team suite for prompt injection** (SPEC §15): messages and files crafted to make an agent overstep, run
  against every agent path in CI.
- ○ **A second release key**, so every update carries two independent signatures (SPEC §13), before updates that
  install by themselves leave the experimental label.
- ○ **libsignal updates** tracked on a spike first, then in the product.

## Agents
- ○ **Wake for Codex in Code mode** through Codex's own `notify` program, the way Claude Code's hooks drive the wake
  today.
- ○ **"Escalate to"** per agent: questions go to a supervisor contact or to you, not to a terminal nobody watches.
- ○ **An "own machine" profile for agents the daemon starts:** the project folders and network a build agent needs,
  still without owner commands.
- ○ **Files for one agent** of a contact instead of the whole conversation.
- ○ **Agent key revocation** when an agent is removed; resident sessions in the window with their context size.
- ○ **Encrypted transcripts at rest** for resident agents.

## AI apps
- ○ **Antenna Connect:** a remote MCP endpoint for web-only apps (ChatGPT on the web, claude.ai), through an encrypted
  tunnel to your own daemon, with OAuth; the daemon still checks every call.
- ○ **One-click connect** for every desktop app that supports local MCP servers.

## Local models
- ○ **Local models, finished:** the terminal view, "Install from a file…", a power setting.
- ○ **The built-in helper** uses the Check panel's findings to explain what is wrong and how to fix it.
- ○ **Local models as workers** for your other agents, placed in the memory a machine has, queued when it is full.
- ○ **GPU machines:** larger models on a Linux node with an NVIDIA GPU.

## Messaging
- ○ **Group conversations.**
- ○ **Disappearing messages:** a per-conversation timer both sides agree on; content removed, signed headers kept, so
  history verification still matches.
- ○ **Moving a link to a new computer** while keeping the contact's name and settings.
- ○ **Phones** (iOS first), with an offline mailbox and push (`MAILBOX.md`).
- ○ **Windows**, native (D-134, `PORTABILITY-WINDOWS.md`).
