<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Security policy

Antenna exists to keep conversations and the work of AI agents private and under their owner's control, so we treat
security reports as the most important issues we get.

## Reporting a vulnerability

**Please do not open a public issue, discussion or pull request for a security problem.**

Report it privately through GitHub: on this repository's **Security** tab choose **Report a vulnerability**
([direct link](https://github.com/Danta-Nort/antenna/security/advisories/new)). Only the maintainers see the report.

Please include what you can of:
- the version (`antenna --version`) and the system;
- what an attacker can do, and from which position (a contact at which trust level, an agent, someone on the network,
  someone with access to the computer);
- the steps to reproduce, or a proof of concept;
- whether you want to be credited, and how.

What to expect:
- we confirm that we received the report within **3 working days**;
- we tell you our assessment and the plan within **10 working days**;
- we fix confirmed issues in a signed release, publish a GitHub security advisory and credit you unless you ask us not
  to. We ask you to keep the details private until the fixed release is out, or for 90 days at most.

## What is in scope

Everything in this repository: the daemon `antennad`, the `antenna` command and its MCP server, the desktop app, the
link and pairing protocols, the file checks and sandboxes, the update mechanism and the release packaging. Examples of
what we especially want to hear about:
- anything that lets a contact or an agent do more than its trust level allows (SPEC §9), including through prompt
  injection that reaches a permission decision;
- a way to pair, read, alter, replay or drop messages without being noticed;
- a file that escapes quarantine or the check sandbox;
- an update that installs without a valid release signature.

Bugs in the libraries we build on (libsignal, iroh, rustls, SQLCipher…) belong upstream; tell us too if Antenna is
affected, and we will coordinate.

## Supported versions

Security fixes go into the newest release. Antenna checks for signed updates once a day, so please stay on it.

## How Antenna is built to be safe

No custom cryptography; the pairing protocol is modelled in ProVerif (`formal/`); permissions are enforced by the
daemon, never by a model; checks fail closed. The design and its threat model are in `SPEC.md` (§7, §9, §15),
`docs/PROTOCOL.md` and `docs/UPDATES.md`. There has been no independent audit yet; one is planned before 1.0.
