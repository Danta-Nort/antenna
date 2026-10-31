<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# The Antenna guide

One short page per window section and per function, so a reader can find "where is it" and "how do I…" without
reading the whole manual. `docs/USER-GUIDE.md` is the other kind of page: a narrative walkthrough (install, first
link, update, what to do when something goes wrong) that this guide links into instead of repeating.

*How a page is built.* Each page names the window's own English labels in bold (`**Settings**`,
`**Settings → Advanced → Updates**`), exactly as `apps/antenna_desktop/lib/l10n/app_en.arb` has them, and shows the
window's own golden frame for the screen it describes — never a hand-made screenshot. `tools/guide_check.py` fails
the build if a label is wrong, an image is missing or stale, or a navigation item has no page; `tools/guide_shots.py`
keeps `img/` exactly in step with `docs/design/screens/`. Both run on every build (`packaging/release-linux.sh`, the
`linux` job of `.github/workflows/release.yml`).

*Status.* The pages below cover what is on `main` today. A page for a feature still being built says so plainly,
instead of describing something a reader cannot yet click.

## The window's own navigation

| Page | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | Install, first run and the password, your first contact |
| [Chats](chats.md) | The list, chats per agent (rename, notifications, archive), a conversation, the Secure indicator and history verification, images and files, approvals in the chat, topics and the To line |
| [Teams](teams.md) | A lead agent and workers on one project: New team, the board, a task's changes and checks, review, applying to your branch, workers in Code mode |
| [The conversation header and the contact card](contact-card.md) | The header chip row, the ⓘ contact card, rename, remove |
| [Contacts and trust](contacts.md) | Invite, join, the one-button confirm, trust levels 1–4 and ∞, rekey, history divergence |
| [Agents](agents-page.md) | Connecting an assistant on this Mac, AI apps and Connect, approval requests, agents that reply on their own, the List and Map views |
| [Add an agent on this computer](add-an-agent.md) | The three ways, step by step: Connect an agent (a token file), AI apps → Connect, Start an agent in Code mode with Set up this folder; the command for each |
| [Connect two agents](connect-agents.md) | Draw a line on the map or Connect to…, what the dialog changes on each side, the approval on your other computer, disconnecting, the commands |
| [Add a server and its agents](add-a-server.md) | Install on Linux, `antenna init`, pair with the Mac, ∞ on both sides, an agent on the server (MCP or a session Antenna wakes), My devices and the map, an offline server, the relay, a link that is not direct |
| [Approver agents](approvers.md) | An agent that answers your other agents' approval requests in your place, only inside your own computers: naming one, its scope, the warning, why an answer did not count, the list and Revoke |
| [Agent map](agent-map.md) | Agents → Map: which agent talks to whom, connecting two agents by drawing a line, tasks, the approval on your other computer, disconnecting |
| [Local models](local-models.md) | A model that runs on this computer: the catalog, download, a local agent's chat |
| [My devices](my-devices.md) | Your own computers in one place: versions, health, agents, their requests answered from here, lending to teams, a lost computer |
| [Code mode](code-mode.md) | Running Claude Code or Codex inside the window: start, status, wake, quick replies, Screenshot |
| [Files](files.md) | Quarantine, previews, accept and reject, the secret scanner, images in a file card |
| [Settings](settings.md) | All eight sections: Profile, General, Interface, Network, Security, Agents, Check, Advanced |
| [Profile pictures](profile-pictures.md) | Your picture and your agents': a drawn animal or your own photo, what contacts see, why photos are rebuilt |
| [Check](check.md) | The Check panel's fixed checks and their one-click fixes |
| [Touch ID](touch-id.md) | Approving and unlocking with a fingerprint instead of the password |
| [Updates](updates.md) | Installing a signed release, and letting your own computers install one by themselves |
| [How to…](how-to.md) | Your own machines, a node on a server ([Add a server and its agents](add-a-server.md)), adding an agent ([Add an agent on this computer](add-an-agent.md)) and connecting two ([Connect two agents](connect-agents.md)), without internet, a lost computer |
| [Reference](reference.md) | Where things are on disk, CLI commands, MCP tools, error codes |

## Planned, not built yet

Named here so a reader looking for them finds a straight answer instead of silence:

- *Teams on other computers* (your own computers lending capacity, remote spawn). Teams on this
  computer work today (experimental): [Teams](teams.md).
- *Moving a link to a new computer* while keeping the contact's name and settings: pair
  again from the new computer today.

Details of both: the product plan §3 and §6.

## In the app

The window's own "?" hints (`HelpHint`, next to a setting's name) are inline text today, with no link out of the
window; wiring one to a guide page's URL is a change to the window itself and is not done yet.
