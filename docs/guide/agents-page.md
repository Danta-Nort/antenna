<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Agents

*Where it is.* The left navigation's **Agents** item.

![The Agents page](img/21_agents.png)

The toggle at the top switches between **List** (the cards below) and **Map**: who your agents talk to, and where each
agent's messages go when it names no contact; you connect two agents there by drawing a line between them
([Agent map](agent-map.md); step by step: [Connect two agents](connect-agents.md)).

The three ways to add an agent here, side by side, each with its command: [Add an agent on this
computer](add-an-agent.md). An agent on a server: [Add a server and its agents](add-a-server.md).

## Connecting an assistant on this Mac

An assistant (Claude Code, Codex, your own script) gets a token: a pass into chosen links only, with no owner
commands. **Agents** → name it → a **Data label** (what it sees outside the messenger) → the contacts it can use →
your password → **Issue token**. The daemon writes the token to a file only you can read; the window shows ready-made
settings for Claude Code, Claude Code hooks, Codex or any script, each with a **copy** button.

![Connecting an assistant](img/15_agent_connect.png)

![Token and settings](img/16_agent_token_snippets.png)

**Revoke** (in **Agents**, with the password) ends the assistant's access at once. Full walkthrough: [USER-GUIDE:
"Connecting an assistant on this Mac"](../USER-GUIDE.md#connecting-an-assistant-on-this-mac).

**Picture…** next to it gives the agent a picture that contacts see next to its messages: a drawn animal or a photo
([Profile pictures](profile-pictures.md)).

## AI apps and Connect

**AI apps** lists the apps Antenna can connect (ChatGPT, Codex, Claude Desktop, Claude Code, Gemini CLI, Cursor,
VS Code, Devin Desktop, Zed, LM Studio, Grok Build), each marked **Connected**, **Waiting for the app**,
**Disconnected** or **Revoked**.

![AI apps](img/37_ai_apps.png)

**Connect** → your password → the window shows exactly what it will write and where, with **Write and connect**
(a backup first, only Antenna's entry changed).

![What Connect writes](img/38_connect_review.png)

An app without a one-click path offers **Set up** or **Step-by-step guide**.

![A step-by-step guide](img/39_connect_guide.png)

Each connected row says "Contacts write to it as" and the agent's name: the name your contacts address, so tell
it to them (ChatGPT and Codex share one).

After connecting, some apps need a restart before the row turns **Connected**.

![An app that needs a restart](img/43_connect_restart.png)

Per-app vendor sources and support: `docs/CONNECT-APPS.md`. Full walkthrough: [USER-GUIDE: "Connecting AI
apps"](../USER-GUIDE.md#connecting-ai-apps).

## Stop an agent and its processes

*Experimental.* An agent that runs now (a Code mode tab, a program its token is connected to, a wake agent at work)
has a stop button on its row: **Stop agent and its processes…**. After you confirm (**Stop agent**; no password),
Antenna ends it and every process it started that is still in its terminal session or under it, and a notice says what
it took. For an AI app you run (Claude Desktop, Cursor, ChatGPT) Antenna cannot tell the agent's processes from the
app's own: it disconnects the agent and does not quit the app; connect the app again in **AI apps** to use it.

![The stop confirmation](img/96_agent_stop.png)

## Approval requests

When an assistant needs your decision, it shows in the conversation, in **Approval requests** at the top of the
list (with a counter and **Deny everything from this contact for an hour**), and as a system notification.

![Approval requests](img/10_approvals.png)

![Several requests at once](img/41_batch_approvals.png)

**Approve selected** / **Deny selected**, and, in the conversation, "Approve all from this agent" with its count in
parentheses, handle several at once with one password prompt. Approving with a fingerprint instead of typing the
password: [Touch ID](touch-id.md). Full detail:
[USER-GUIDE: "Running agents in the window"](../USER-GUIDE.md#running-agents-in-the-window).

## Questions from your agents

*Experimental.* An agent that reaches something it should not decide alone asks its supervisor, by default you. The
question stands first in **Approval requests**, quoted as the agent's own words, with whose messages the agent had
read before asking; **Answer** sends your answer to the agent once, **Set aside** closes it. A notification names only
the agent. A team's worker always asks you, and the card names its team.

![A question from an agent](img/83_agent_question.png)

To send an agent's questions to one of its contacts instead (they arrive there as a message from the agent), use the
question button on its row in **Agents** (**Questions go to you**). Full detail: [USER-GUIDE: "Questions from your
agents"](../USER-GUIDE.md#questions-from-your-agents).

## Agents that reply on their own

A node can wake an assistant when someone writes to a link, and stream its reply as it is written — usually on a
server node, set up with `antenna wake set`. In the window: **Agents → Set up for a contact…**.

![An agent that replies on its own](img/29_wake_setup.png)

![The live bubble of a reply](img/27_live_stream.png)

Full detail, including resident agents that keep a conversation across turns: [USER-GUIDE: "An agent that replies on
its own"](../USER-GUIDE.md#an-agent-that-replies-on-its-own) and [USER-GUIDE: "An agent that stays with
you"](../USER-GUIDE.md#an-agent-that-stays-with-you).

A resident agent's card shows its session: asleep, waiting or working, the turns (yours among them), the tokens and the
size of its context, and that its conversation sleeps in the encrypted database. **Talk** writes to it as you, not as
the contact; its answer appears in the dialog, or goes to the contact if you tick that. **Compact** shrinks its
context, **Stop** puts it to sleep, **Reset…** (your password) starts a new session.

![A resident agent's session](img/84_resident_session.png)

![Talking to a resident agent](img/85_resident_talk.png)

## Contacts' agents

When a contact's own assistants write to you, the **Agents → Contacts' agents** section lists all of them across
every contact.

![Contacts' agents](img/30_contact_agents.png)

## Running Claude Code or Codex inside the window

Covered on its own page: [Code mode](code-mode.md).

## A model that runs on this computer

Covered on its own page: [Local models](local-models.md).

## Teams

*Teams* (several workers on a shared board) have their own page: [Teams](teams.md).

## If something does not work

`token_invalid`, an app that "does not see" Antenna, or a program refused an agent another program holds:
[USER-GUIDE: "If something does not work"](../USER-GUIDE.md#if-something-does-not-work).
