<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Antenna: user guide

**Antenna** is a messenger for people and their AI assistants. Every pair of people talking has its own
encrypted direct channel, with no accounts, no phone numbers and no third-party servers. An assistant (Claude Code, Codex, your own script)
writes on your behalf only in the links and with the permissions you gave it; the permissions are checked by the program,
not by the model.

> **Status: first public release (0.1.0).** The window and the core run on Mac and Linux and are covered by tests. File
> checks and assistant wake on the Mac run in the macOS sandbox (Seatbelt). If the sandbox does not come up, Antenna says
> so plainly: the file will not be checked (an agent will not accept it, and you only with `--force` and the password),
> and the assistant will not start.
>
> If something goes wrong, see the section ["If something does not work"](#if-something-does-not-work).

Contents: [Where things are in the window](#where-things-are-in-the-window) ·
[Installing on a Mac](#installing-on-a-mac) · [First run](#first-run) ·
[Connecting with a person](#connecting-with-a-person) · [Trust levels](#trust-levels) ·
[Your own machines](#your-own-machines) ·
[Connecting AI apps](#connecting-ai-apps) · [Connecting an assistant on this Mac](#connecting-an-assistant-on-this-mac) ·
[Approve with Touch ID](#approve-with-touch-id) ·
[Running agents in the window](#running-agents-in-the-window) · [Questions from your agents](#questions-from-your-agents) ·
[Chats per agent, addresses and topics](#chats-per-agent-addresses-and-topics) ·
[Profile pictures](#profile-pictures) ·
[A node on a server for an assistant that is always on](#a-node-on-a-server) ·
[An agent that replies on its own](#an-agent-that-replies-on-its-own) ·
[An agent that stays with you](#an-agent-that-stays-with-you) · [Local models](#local-models) ·
[Teams of agents](#teams-of-agents) ·
[The antenna command in the Terminal](#the-antenna-command-in-the-terminal) ·
[Errors](#if-something-does-not-work) · [Where things are (files on disk)](#where-things-are)

A shorter reference page per window section and per function, each with the window's own screenshot, lives in
[`docs/guide/`](guide/README.md): good for "where is the thing that does X", while this page stays the walkthrough
for install, first contact, and what to do when something goes wrong. Relative repository links for now — the
product site does not host it yet.

---

## Where things are in the window

A map of the window itself — the labels below are the exact English text (`lib/l10n/app_en.arb`); the on-disk locations
(logs, keys, link folders) are in the [last section](#where-things-are) instead.

**Left navigation** (the narrow column on the left): **Chats** (a badge for unread), **Teams** (when this computer's
Antenna has teams; a badge for what waits for you, see [Teams of agents](#teams-of-agents)), **Agents**, **My devices**
(a badge for requests waiting on your other computers), **Files** (a badge for files waiting on your decision),
**Settings**. Below them: a small coloured dot — the daemon's status, tap for details
(version, relay, socket) — and a lock icon, **Lock keys** (`antenna lock`): contacts pause until you type the password
again.

**Chats list**: **Search chats** and the filters **All**, **Unread**, **Queued** at the top, and the button **New
chat with an agent** next to the title. A section **On this computer** above the contacts holds your local agents (one
row each, with the **Local** mark; see [Local models](#local-models)); the contacts follow. A contact's own row is the
chat with the person; under it, indented, one row per agent of theirs, each with its unread count, a struck bell when
its notifications are off, and **⋮** (**Chat options**; a right-click on any row opens the same menu): **Rename…**
(**Rename contact…** on the person's row), **Notifications** (**All messages**, **Only when it asks for me**, **Off**),
**Archive**. Archived chats fold into "Archived (N)" at the end of the list, with **Unarchive** in the same menu. See
[Chats per agent](#chats-per-agent-addresses-and-topics).

**Agents page**: each of your agents has **Picture…** (a local agent has it in its row's menu), see [Profile
pictures](#profile-pictures).

**Agents page → Map** (the **List** / **Map** toggle in the header; tagged **Experimental**): an editor. Your other
computers (∞) on the left, this computer's agents in the middle, your contacts (the person and their agents) on the
right; lines for connections (**tasks** marks the end that takes the other end's messages as tasks), requests waiting
for your approval on another computer and teams, explained in the legend under the header. Drag the background (or
scroll, or two fingers on a trackpad) to pan, pinch or Ctrl/Cmd and scroll to zoom, and use **−**, **+** and **Fit**
at the bottom right; drag a group by its header and a card by its body to arrange them; **Arrange automatically**
puts them back. Drag from an agent's handle (the small circle on its side) to another agent or a person (or use the
agent's **Connect to…**) to open the dialog with what changes on each side and **Connect**; click a line to see what
it does, with **Disconnect** (or Delete) and **Options…**. **Show recent messages** adds grey lines between agents
that wrote to each other without being connected; they are history and cannot be disconnected. A strip at the bottom
says how each action went. Each agent's card in **List** says "Default counterpart: …". See [Agent
map](guide/agent-map.md) and [Connecting your agents](#connecting-your-agents).

**Agents page → Local models** (tagged **Experimental**): "This computer: *cpu* · *memory* memory · *free* free"; the
model **Recommended for this computer** with **Download**, then its progress and **Cancel**, **Checking the file…**,
**Create agent** and **Remove** once it is ready, **Try again** after a failure; **Other models (*N*)** for the rest
(**Fits this computer**, **Slow on this computer**, **Needs *X* of memory**, **Not for this computer**); then **Local
agents**, each with its model, its state (sleeping, loading the model, ready, working, waiting for memory, model
missing), the **Local · runs on this Mac** mark and **Chat**. A local agent's conversation has **Stop** while it
answers, **New conversation** (deletes the old one) and the line "Runs on this computer without internet access. It can
be wrong." under the message field.

**A conversation header** (top of a chat): the avatar and the contact's name both open the **contact card** (trust,
network, encryption, the pairing log); so does the **ⓘ** button on the right, which also closes it. Next to the name, the
trust badge (a number 1–4, or **∞** for your own computer, see [Trust levels](#trust-levels)). In an agent's chat
the header shows the chat's name with "contact · agent" under it, and **⋮** (**Chat options**) opens the chat's menu.
Below the name: the **Secure connection** chip — click it for the details popover and **Verify now** (re-checks the safety number by hand);
the network mode (Direct or Relay only); online/offline (or "hidden" when presence is off for this contact); a queued
count when messages are still waiting to send.

**Settings**, eight sections down the left side of the page:
- **Profile** — **Your picture**: **Change…** (a drawn animal or your photo, see [Profile pictures](#profile-pictures)) ·
  **Remove**.
- **General** — Appearance (System/Light/Dark) · Language (System/English/Russian).
- **Interface** — Interface (Chat/Code): switches the whole window between the chat layout and Code mode.
- **Network** — the local network (LAN) card: discovered devices on the same network, **Turn on**.
- **Security** — **Use Touch ID** (Mac only, experimental) · **Keys**: **Lock keys**.
- **Agents** — the role preset for new agents · **Open Agents** (switches to the Agents page).
- **Check** — the Check panel: fixed checks with one-click fixes.
- **Advanced** — daemon facts and **Stop daemon**, the **antenna command in the terminal…** button · **Updates**: the
  per-computer "install signed updates by itself" switch and its status.

**Teams page** (tagged **Experimental**): **New team**, then one card per team (its project, lead, workers, tasks per
column, and "Waiting for you: apply to main" when its lead asked). A card opens the team's board: **New task**, **Add
worker**, "Apply to main" and the ⋮ menu (**Log**, **Stop all workers** or **Make active again**, **Remove team**);
the lead's request with **Review and apply**; the capacity strip (**Machine**, **Workers**, each kind of worker used
and free, **Models in memory**, **Waiting**); the workers (a click: its live output and **Stop worker**); and the
columns Open, Working, In review, Blocked, Accepted, Applied. A task opens with **Overview**, **Changes**, **Checks**
and **Log**, and the actions its state allows: **Accept**, **Request changes**, **Answer**, **Assign**, "Apply to
antenna/web", **Cancel task**. In Code mode, the workers Antenna runs appear as read-only tabs after the terminals.

**Files page**, files grouped top to bottom: **Waiting for your decision** · **Downloading and checking** · **Sent** ·
**Decided**. A banner above the list, "Antenna *version* is ready to install", appears whenever a newer signed release
can be installed (**Install**, or **Install now** / **Later** for a release the daemon staged itself). A file card's
usual buttons: **Reject**, **Safe preview** (the daemon's rebuilt pixels, before you decide), **Accept** / **Accept into
*folder*/**, **Cancel sending** (an offer still waiting), **Retry**, **Dismiss**; a file the secret scanner held at Send
offers **Approve and send** / **Don't send**. A picture's card also shows an inline thumbnail (the safe preview once
checked, incoming; the local file, outgoing) — click it for the full-screen viewer (Previous/Next, Escape or a tap to
close).

**Code mode panel** (bottom of the window in Code mode): **Start agent** opens a new terminal tab; each running
agent is its own tab, named after the agent, showing its state (running / stopping… / stopped / did not start / ended).
Per tab: **Restart**, **Stop**, a **Screenshot** button (attaches to Claude Code's prompt, or saves and shows the path
for another program), and the **⋮** menu ("Agent options") with **Wake on new messages** and **Restore after an
update**. Quick replies above the terminal type a fixed phrase and Enter: **Approved**, **Check the chat**, **Yes, go
ahead**, **Stop** (interrupts the turn, types nothing). **Hide terminals** / **Show terminals** folds the whole panel
away without stopping anything running in it.

## Installing on a Mac

1. Download `Antenna-<version>-macos-arm64.dmg` (a Mac with Apple Silicon: M1 and later) from the repository's releases page:
   **Releases** → the latest release → **Assets**. Next to it are `SHA256SUMS.txt` (to check: `shasum -a 256 -c SHA256SUMS.txt --ignore-missing` in the folder
   with the download) and `antenna-<version>-macos-arm64-cli.tar.gz`, the command line only, without the window. There is no build for Intel Macs
   yet.
2. Open the `.dmg` and drag **Antenna** into **Applications**. Start it from Applications, not from the `.dmg`
   window.
3. First run. The app is signed with a Developer ID and notarized by Apple: macOS asks only the usual "downloaded from
   the Internet. Are you sure you want to open it?" → **Open**.
4. Rare: if the daemon does not start, or an assistant "does not see" antenna, even though the app is in Applications,
   macOS may have left its quarantine mark on the helper programs inside. Removing the mark from the whole app fixes
   that (Terminal):

   ```
   xattr -dr com.apple.quarantine /Applications/Antenna.app
   ```

Handy (optional): the `antenna` command in the Terminal: the button with the terminal icon at the top of the window, see the section
["The antenna command in the Terminal"](#the-antenna-command-in-the-terminal).

## First run

Inside the app there are two helper processes: **antennad** (the daemon: it keeps the keys, holds the links, encrypts and checks
permissions) and **antenna** (commands for the Terminal and for AI assistants). The window is only a window onto the daemon.

1. **The window starts the daemon itself.** On a Mac it keeps running after the window is closed (it starts when you log in
   to the system), so the assistants on this Mac and incoming messages do not depend on the window. To stop it, click the daemon version
   at the top of the window → **Stop daemon**.

   ![Starting the daemon](design/screens/13_first_run_starting.png)

2. **Create a node.** Think of an owner password (at least 8 characters) and enter it twice. The password encrypts the keys on
   this Mac. **It cannot be recovered**: if you forget it, you will have to create the node and all links again. The password is asked
   after every reboot and for every trust action (invite, confirm, grant permissions to an assistant).

   ![Creating a node](design/screens/02_init.png)

3. After the Mac reboots, the window will ask for the password; until then the links are silent (the keys are locked).

   ![Keys are locked](design/screens/01_unlock.png)

4. **Every time the window opens** it asks for the password too ("Sign in"), even if the daemon kept running the whole time: without the password the window is not
   the owner (this protects against programs running on your behalf on the same Mac). One entry unlocks both the keys and
   the window; once the window is closed, the sign-in ends, while assistants and message delivery keep working.

## Connecting with a person

A link is created with a one-time invite link and a **verification code** that you compare by voice, over video or in person. This
protects against substitution: whoever intercepted the link does not know the code.

**You invite** (the **New contact → Invite** button):

1. Name the contact (only you see the name), choose a trust level (see below) and the link's lifetime, enter the password.
2. Pass on the link or show the QR code, in person or over a trusted channel. The link looks like
   `https://antenna.contact/#…`: it can be opened anywhere; the site will show an "Open in Antenna" button, and everything after
   `#` is not sent to the server by the browser (the site never sees the invite secret). Next to it is the same link for the app,
   `antenna://pair#…`.

   ![Link and QR](design/screens/06_invite_link_qr.png)

3. When the other person opens the link, a code appears: 6 digits or the same 6 animals. **Read it out**.

   ![Code](design/screens/07_invite_code_emoji.png)

4. The other person enters the code on their side; their Antenna checks it. When it matched, your window shows **The contact
   confirmed — codes match**: press it once they tell you the code matched (no second password needed). If it does not match:
   **Doesn't match — decline**. When two of your invites showed codes at the same time, the window asks you to type the code you
   read out instead (a spoken "it matched" could be about either invite); if you mistype it, the window says "That's not this
   invite's code", and you enter it again.

   ![Confirmation](design/screens/08_invite_confirm.png)

**You were invited** (the **New contact → Join** button, or open the link and the window opens by itself): paste the link
as you received it, `https://antenna.contact/#…`, `antenna://pair#…` or `x://pair#…` (these are the same invite),
name the contact, choose a level, the password → enter the code read out to you (as digits or by tapping the animals), and
read it back.

![Entering the code](design/screens/09_join_code_animals.png)

From then on it is an ordinary chat. The marks on a message: ✓✓ means the other person received it, a clock means queued (the other person is offline,
and Antenna will retry by itself). Under the contact's name, one green **Secure** means the channel is end-to-end encrypted and
protected, among other things, against future quantum computers. Hover over it (or click it, or reach it with Tab) for the
details in plain words: end-to-end encryption, post-quantum protection, the network mode and the history verification; the
raw TLS and session facts are behind **Technical details** there. When something is not in order the word changes: **Encrypted**
(no post-quantum protection confirmed), **Not confirmed** (no session facts yet), **History differs** or **Rekey needed** (see
below). A blue number in the list is unread messages; opening the chat marks them read (for `antenna inbox` too). Commands
are offered when you type `/` in the message field.

![Chat](design/screens/04_home_chat.png)

**History verified.** In the **Secure** details, "History verified" with **three animals** (the fingerprint, with their names
and digits). Your copies of the conversation match: the other person has the same three animals, and you can compare them by
voice. **Verify now** there checks again.
Lines like "claude · read the messages: allowed" are **receipts**: what assistants did with the messages of this link
(signed and visible to both sides).

**If the history diverges**, a red banner appears: where exactly (whose message and when) and whose copy was changed.
If your copy is damaged: **Restore my copy** (it is taken from the other person, and the author's signature is checked). Until
the divergence is resolved, the link is **read-only**; **Accept…** (with the password) lifts this, and the divergence stays
on record.

![History divergence](design/screens/17_history_mismatch.png)

**Rekey after restoring from an old copy.** If the Antenna database was restored from a backup or a snapshot (Time Machine,
a disk copy), the old keys cannot be used: Antenna stops sending and asks for a rekey. This takes two codes; each person enters the other's
code:
1. the one with the rollback: **Propose a rekey** (password) → read the code shown out to the other person;
2. the other person sees "The contact asks for a rekey": they enter your code and the password → they get **their own** code
   and read it out to you;
3. you enter their code and the password → done; the messages missed in the rollback come back by themselves.

![Rekey](design/screens/18_rekey_contact_asks.png)

A red "**Two different rekey proposals — both burned**" means that someone else may have this link's keys:
talk to the other person by voice before you continue.

**Who is writing on the other side.** If the other person also uses Antenna and their assistant replies to you, the message shows
"Bob / claude-backend" above it: the name Bob gave his assistant. This is not taken from the text: the name comes in a signed
announcement from Bob's node, and an outsider cannot forge it. The contact card lists their assistants. The trust level
is one per link: Bob's assistants get the same permissions as Bob himself. Your assistants are visible to the other person by name in the same way
(an assistant that replies on its own appears as "wake": it does not see the label under which you saved the other person).

In the window: above such a message, "Bob / claude-backend"; above a message from your assistant, "your agent …"; in the list, a
contact with assistants gets the label "+ agents" (or "agent" if only an assistant writes); in the contact card (ⓘ in the conversation
header), **"Contact's agents"**; and all of your contacts' assistants are in the **Agents → "Contacts' agents"** section.
Right after linking, and while the other person's Antenna is an older version that does not say, the kind of contact is unknown: their assistants write in their name.

![Contact's agents](design/screens/30_contact_agents.png)

**Rename** a contact: the pencil next to the name in the card on the right (only you see the name). **Remove contact**: at the bottom
of the card, with the password; the history can be deleted together with the link.

## Trust levels

Each person you talk to, human or assistant, gets a level 1–5 from you. A level is a ready-made set of permissions that
the program enforces. You can change it in the link card (on the right), with the password.

| Level | For whom | What is allowed |
| --- | --- | --- |
| 1 · Observer | strangers, other people's agents | text only, incoming messages marked "untrusted"; an assistant replies only in words |
| 2 · Acquaintance | new contacts (default) | text; files go into quarantine; tasks for an assistant need your approval |
| 3 · Colleague | work contacts | the shared folder is read-only; writing needs approval |
| 4 · Partner | close colleagues, your own server | the shared folder is read and write; builds and tests in a sandbox |
| ∞ · My computer (level 5) | **only your own computers** | files and messages go without asking, including ones with keys, passwords or tokens; files you receive from it are accepted by themselves (a threat still waits for you); its tasks run without confirmation. See "Your own machines" |

Levels 1–2 cannot see whether you are online, and the link with them goes only through a relay (they cannot see your IP address). With 3–5,
it goes directly (faster, but the other person sees the IP).

## Your own machines

Level 5, shown in the window as **∞ · My computer**, is for your own computers: your laptop, your second Mac, your
servers. In the level picker it sits apart from the people's levels 1–4, under **My devices**, and is red while you
choose it. Choosing it shows one warning you accept: "∞ 'My computer' is for your own computers only. This contact will
get files and messages without asking, including ones with keys, passwords or tokens, and its tasks run without
confirmation." (**Use ∞ My computer**). Afterwards the contact shows a quiet ∞ badge. Choose it for another person's
computer and they get your secrets without asking: keep other people at 1–4.

**When you pair a machine of your own,** tick **This is my own computer (∞)** in the invite or join form (or
choose ∞ in its level picker); with twenty machines that is one tick each, and no clicks per file afterwards. For a
contact you already have, choose ∞ in its card. In the Terminal: `antenna trust <contact> 5` asks the same question
(`--yes` answers it in a script), and so do `antenna invite --trust 5` and `antenna join --trust 5`. The password is
asked as for any change of level.

**What changes at level 5:**
- Messages and files go without an approval request, also when Antenna finds a key, a password or a token in them,
  also files from outside the contact's folder. Antenna still checks every one and writes what it found into the
  contact's activity log (the contact card → **Activity log**, or `antenna log <contact>`): what, where, and which
  assistant sent it.
- Files that arrive from the machine are accepted by themselves, whatever the check noticed (an unknown type, a script
  in a web page, an archive of code: it shows as labels on the card): into the folder you chose for that machine or its
  agent (`antenna files save-to`), the project folder if you set one, otherwise the contact's `shared/` folder. What
  can run or install software waits for you with **Keep anyway** and **Delete**: a program, an installer or disk image
  (not a signed Antenna update), an archive holding one, a file your antivirus flags (see Files in the guide). A new version under a name that is already
  there is saved as `name (2).ext` (the next free number), the same file again is not copied, and the machine that
  sent it is told the name; a file that still cannot be saved waits for you with the reason on its card.
- An assistant doing a task from that machine runs its commands and edits without asking you (each one is in the
  activity log). Changes to its own instructions and settings (`CLAUDE.md`, `.claude/`, shell profiles, keys) still
  ask you.

**What does not change:** levels 1–4 work as before. An assistant that has also read a message from someone at a
lower level keeps that lower level's limits (no commands after reading a level-3 contact). Passing data from another
person's conversation to your machine still asks you.

If some of your contacts were already at level 5 before this version, the window asks you once: "Level 5 now also
sends secrets without asking: keep it or lower to 4". Keep it for your own machines, lower everything else to 4.

**All your machines in one place: My devices** (experimental; both computers need Antenna 0.1.0 or later). Each of
your own computers tells the others its system, Antenna version and updates, health, agents and the requests waiting
for your approval, over the link between them. Answer a request of one computer from another: **Approve with Touch
ID**, or with the password of the computer you are at, or **Deny**; the computer that asked checks the answer itself,
against keys you accepted there once with the password (its card → **Approvals**). Turn on **Lend this computer to my
teams** on a computer your teams may use. For a lost or stolen computer, **Revoke this computer** on another one: your
other computers stop accepting its keys and show it as lost, so you revoke it on each. In the Terminal: `antenna
devices`. The whole page: [My devices](guide/my-devices.md).

## Without internet, on the same network (LAN)

At home or in the office Antenna can find the people you talk to **on the same network without internet**: for example, when there is no internet
but you and a colleague are connected to the same router. This is **off** by default: on someone else's network (a café, an airport) there is no
need to announce yourself.

- Turn on: `antenna lan on` (asks for the password); turn off: `antenna lan off`; check: `antenna lan`.
- It works only for contacts at levels **3–5** (with 1–2 the link goes only through a relay, and not over the LAN either).
- Antenna does not shout about itself all the time: it listens to the network and announces itself only when there is something to deliver and the other person
  does not answer at the known addresses, and not under its own address but under an alias that only this contact understands and that
  changes every hour. Neighbors on the network see "some device is looking for something" and do not learn who you are or whom you are linked with (but
  an attentive neighbor will recognize the same device on another network by its port number).
- Only local addresses (`192.168…`, `10…`) go onto the network, without the relay address and without VPN/Tailscale.
- Turn it on on trusted networks: on someone else's Wi-Fi a neighbor will still see that your device is there and from time to time
  looks for someone.
- In the window: **Settings → "Local network (no internet)"**: a toggle (turning it on needs the owner password; the
  privacy note above is shown right there, and behind the **?** next to the name), and below it the state ("Listening on
  the local network") and which of your level 3–5 contacts were found nearby. Every setting is one line: its name, a small
  **?** with the explanation (hover, click or Tab), and the control.

  ![Local network](design/screens/31_lan.png)

## Connecting AI apps

Antenna connects the AI apps you already use, with your own subscription and no API keys:
ChatGPT, Codex, Claude Desktop, Claude Code, Gemini CLI, Cursor, VS Code, Devin Desktop (formerly Windsurf), Zed,
LM Studio and Grok Build. Each app then talks to your contacts through Antenna, with the permissions of each contact's
trust level. What each app supports, with the vendors' sources: `docs/CONNECT-APPS.md`.

**Agents → AI apps** lists them all, the ones found on this computer first. Each row says whether the app is really
connected:

| Status | What it means |
| --- | --- |
| **Connected** ✓ | The app runs Antenna right now (the row shows its process and when it last called Antenna) |
| **Waiting for the app** | Antenna is set up, but the app has not used it yet: open the app and start a chat (or task) that uses Antenna |
| **Disconnected** | The app used Antenna and has since closed it; it reconnects by itself the next time |
| **Revoked** | The app's settings still name Antenna, but its agent was revoked: **Reconnect**, or **Disconnect** to remove the entry |

![AI apps](design/screens/37_ai_apps.png)

**Connect** (one click, then your confirmation):

1. **Connect** next to the app. Antenna creates the app's own agent (for example `chatgpt`), with the role you choose
   (**Assistant with access to my projects** or **Front desk: messages only**) and its contacts. It also says whose
   messages this agent will do as tasks: by default your contacts at trust level 5 (**Change…** to pick others, or
   nobody).
2. Your **owner password** → **Continue**. The daemon issues the agent's token and keeps it in a file only you can
   read; the app's settings will name that file, never the token.
3. Antenna shows **exactly what it will add and where**, for example to `~/.codex/config.toml` for ChatGPT and Codex or
   to `claude_desktop_config.json` for Claude Desktop. **Write and connect** saves a backup of the file next to it and
   changes only Antenna's entry. For Cursor, VS Code and LM Studio, Antenna opens the app's own install link instead,
   and the app asks you to confirm.

   ![What Connect writes](design/screens/38_connect_review.png)

4. Restart the app if it says so (Claude Desktop, Cursor, Gemini CLI, Devin Desktop read the file when they start;
   ChatGPT: Settings → MCP servers → **Restart**). The status turns to **Connected** as soon as the app calls Antenna.

Apps without a one-click path (Zed), and any app if you prefer to do it yourself, have **Set up** or **⋯ → Step-by-step
guide**: step 1, step 2… in plain words, with **copy** buttons for the command, its arguments and the settings entry.

![A step-by-step guide](design/screens/39_connect_guide.png)

Claude Code and Codex can also run **in Antenna's window** (**Start in Code mode**, see
[Running agents in the window](#running-agents-in-the-window)): that is the simplest way for Claude Code. ChatGPT's
desktop app and Codex share one settings file, so connecting one connects both; they then use the same agent, which
works in one of them at a time.

Each connected row also says "Contacts write to it as" and the agent's name: that is the name your contacts address
(the **To** line, `--to-agent`); ChatGPT and Codex share one. Tell it to the people who write to it, or a message to
another name reaches nobody (the window then says so, see [Chats per agent](#chats-per-agent-addresses-and-topics)).

**Disconnect** (**⋯ → Disconnect**, password): Antenna removes its entry from the app's file (after a backup) and
revokes the app's agent, so its token stops working at once.

**Tasks or data.** An agent treats messages from the contacts it takes tasks from as work you authorized: it carries
them out within its permissions, and the daemon still checks every action. Messages from anyone else are data: the
agent summarizes them for you and acts only on your word. Change it per agent with **⋯ → Takes tasks from…** (or the
✓ icon next to an agent in the list), with your password.

**Keep tokens out of chats.** An AI does not need to see a token, and a pasted token is a pass to your contacts. The
window never shows one, except when it talks to an older daemon that cannot write token files; then the token comes with
the warning "Paste this only into the app's settings, never into a chat" and a **Revoke and create a new token** button.
If a token was shown somewhere it should not have been, use that button (or revoke the agent): a leaked token works only
through this computer's daemon socket and only from the process it is bound to, but there is no reason to keep it.

**Files from an AI's own cloud.** An agent can send a file it made (for example an image) by its content
(`share_file_content`), not only by a path on this computer. The file goes through the same check, rules and approvals
as any other. The AI has to write the file's content into its request, so this suits small files.

> **Experimental:** whose messages are tasks (**Takes tasks from…**) and sending a file by its content
> (`share_file_content`). Both are tested and still being reviewed (DECISIONS D-94); the window marks the tasks setting
> **Experimental**.

## Connecting an assistant on this Mac

An assistant is a program with a model (Claude Code, Codex, your script or your personal assistant) that reads and writes on
your behalf. It is given a **token**: a pass into the chosen links only, without owner commands: an assistant cannot invite, raise
trust or approve its own request.

1. **Agents** (at the top of the window) → the assistant's name (in Latin letters, for example `jarvis`).
2. **Data label**, mandatory: what the assistant sees on this Mac outside the messenger.
   - **5 · Projects and memory**: a personal assistant with access to your files, mail, memory. It can write to contacts with
     a level below 5 **only with your approval**, so that it does not accidentally retell something private.
   - 3: an assistant for work conversations; 0: a "front desk" without access to your data.
3. **Agent's contacts**: all or selected ones. Password → **Issue token**.

   ![Connecting an assistant](design/screens/15_agent_connect.png)

4. The daemon keeps the token in a file only you can read (`<data folder>/agents/<name>.token`); the window shows the
   file's path, never the token, and ready-made settings that name the file, each with a "copy" button:
   - **Claude Code**: run the shown `claude mcp add …` command in the Terminal (the same on a Mac and on a Linux
     server);
   - **Claude Code hooks**: paste into `~/.claude/settings.json`: before every action Claude Code asks Antenna whether
     it is allowed (for example, after reading a stranger's message it may not run commands);
   - **Codex**: a snippet for `~/.codex/config.toml`;
   - **Any script**: a bash loop: it waits for messages (`antenna --json inbox --wait`) and replies (`antenna --json send`); suitable
     for your own assistant that can run commands.

   ![Token and settings](design/screens/16_agent_token_snippets.png)

   The assistant sees only messages that arrive **after** it is connected; what came earlier stays between you and the
   contact. To give it an earlier message, paste it into the assistant's own session (its terminal or chat), or ask the
   contact to send it again.

5. **Approval requests.** If an assistant wants to do something that needs your decision (reply to a contact below its
   label, forward data from one link to another, send something that looks like a password), you see it where you look:
   - a card **"Waiting for your approval"** at the end of the conversation with the contact the request is about
     (and with the recipient, if it is about sending to someone else), with **Approve** and **Deny**;
   - "Approval requests" with a counter at the top of the link list: all pending requests, with **Deny everything from
     this contact for an hour** as well;
   - a system notification when the window is not in front (macOS and Linux): only who asks and what, and how long
     it has left ("expires in 9 min"), never the request text. Also for a request waiting on another of your
     own computers (**My devices**: "Antenna: approval needed on *computer*"), and once more about two minutes before a
     request runs out ("Antenna: an approval expires soon"), so a request does not expire unnoticed.

   Each shows structurally what exactly will be allowed, and the request text separately, as a quote (it is data, not
   instructions). **Approve** allows this one request, once, and asks for your password every time. **Deny** needs no
   password: refusing can only reduce what happens. **After you approve, Antenna finishes the request itself:** it
   sends the message or the file, or accepts the file, exactly as you saw it, and tells the assistant the result, so
   you never have to go to the assistant's terminal and say "approved". The card shows "Approved — Antenna is finishing
   it…" until it is done; if it could not be done (the file changed after you saw it), the card says why. A tool the
   assistant wanted to run goes ahead too: the hook waits for your answer for up to 50 seconds; later, the assistant
   learns it from Antenna and runs the tool again. A request nobody answers closes by itself after 10 minutes: it
   disappears from the window and stays in the contact's activity log (the contact card → **Activity log**, or
   `antenna log <contact>`).

   ![A request in the conversation](design/screens/33_approval_in_chat.png)

   ![Approval](design/screens/10_approvals.png)

   **Several requests at once.** With two or more pending requests, the list has checkboxes and **Select all**:
   **Approve selected** asks for your password once and approves each selected request on its own, exactly as it is
   shown (each with its fingerprint); **Deny selected** needs no password. A request that cannot be decided any more
   (it expired, or it changed after you saw it) is reported on its own line, and the others still go through. In the
   conversation, when one agent waits with several requests, its last card offers **Approve all from this agent (N)**,
   also with one password. In the Terminal: `antenna approve <id> <id>…` (one password prompt) and
   `antenna deny <id> <id>…`.

   ![Several requests](design/screens/41_batch_approvals.png)

A token is like a password: never paste it into a chat or publish a config that contains it (with a token file the
config holds only a path). To revoke: **Agents → Revoke** (the assistant loses access immediately). It also
tells every contact the agent wrote to that its key in your link is revoked: their Antenna accepts nothing more signed with
it, and lists the agent as revoked. An agent you create later under the same name gets a new key.

## Approve with Touch ID

*Experimental (DECISIONS D-94), on a Mac with Touch ID: the built-in sensor or a Magic Keyboard
with Touch ID.*

Once Touch ID is on, your fingerprint stands in for the password wherever Antenna asked for it: approvals (one touch
for one request, or for a listed batch: **Approve selected**, **Approve all from this agent**), starting and connecting
agents and their tokens, trust levels, invites and links, files kept anyway, **My devices**, teams and approvers. A key
in this Mac's Secure Enclave signs exactly the request you confirmed (an approval's ID and fingerprint, every item of a
batch, the level of a trust change), and Antenna's service checks the signature, so a touch cannot confirm anything
else. The key never leaves this Mac. When Antenna opens with its keys locked, the Touch ID sheet appears by itself once
(one touch unlocks the keys and signs you in); after **Lock keys** the window offers **Unlock with Touch ID**, and a
window that only needs to sign in offers **Sign in with Touch ID**. **Settings → Security** lists what Touch ID
confirms.

![Approve with Touch ID](design/screens/58_approval_touch_id.png)

**Turn it on:** **Settings → Security → Use Touch ID**. The window says what changes and asks for your password; then
touch the sensor once. Unlocking with Touch ID needs macOS 14 or later; on macOS 12 and 13 approvals and signing in
use Touch ID and unlocking keeps the password. To turn it off, switch it off: the key is removed from Antenna's service
and from this Mac, with no password.

**The password is still asked:**
- when you turn Touch ID on;
- to turn on **Install signed updates by itself** (Antenna's service needs the password itself there; turning it off
  takes a touch);
- every 14 days (the **?** next to **Use Touch ID** shows the date);
- after a fingerprint is added or removed in System Settings: the old key stops working; turn Touch ID on again with
  your password;
- after three failed Touch ID attempts;
- when Touch ID is unavailable: the lid is closed, the Touch ID keyboard is not connected, or macOS locked Touch ID after
  failed touches.

The password field stays under the Touch ID button, every request keeps **Use password**, and a form that had a
password field shows **Use password** next to the Touch ID line. Cancelling the sheet asks for the password; it never
confirms anything. In the Terminal on this Mac, `antenna` asks for Touch ID too once it is on (`antenna trust`,
`antenna approve`, `antenna unlock`, a sign-in, …); scripts with `--password-stdin` keep the password, and so does
Linux. `antenna owner-key list` shows the enrolled keys (it needs an owner session), and `antenna owner-key remove <key
ID>` removes one and its unlock slot without the password, for example for a lost Mac.

Every Touch ID prompt from Antenna starts with your click (or with opening Antenna, for the unlock) and names what it
confirms, for example "“Antenna” is trying to approve sending a message to Bob"; in the Terminal the sheet names the
command you typed. **If a Touch ID prompt appears at any other time, or names something you did not choose, cancel
it.** A program running as you on this Mac can ask for a touch with Antenna's key; it cannot use the key
without your finger.

## Running agents in the window

Antenna can run Claude Code, Codex or a command of your own **in a terminal inside the window**,
next to the conversation, and connect it to your contacts by itself: no token to copy, no `claude mcp add`, no
settings files to edit. Several agents run side by side, one tab each.

1. **Switch to Code mode:** Settings → **Interface** → **Code** (Chat stays the default; if you have agents, the window
   offers Code once). On the right of the window appears the agents' panel.
2. **Start an agent:** the **+** in the panel (or **Agents → AI apps → Start in Code mode** next to Claude Code
   or Codex, or **Start in terminal** next to an agent):
   - **Agent:** one of your agents, or **New agent…**: a name, its role (**Assistant with access to my projects** =
     data label 5: replies to contacts below level 5 need your approval; **Front desk: messages only** = data label 0;
     or any other data label) and its contacts;
   - **Program:** Claude Code, Codex or **Own command**; the window shows where it found the program, or says it is not
     installed;
   - **Working folder:** the project the agent works in (**Choose…**); left empty, the agent's own folder,
     `~/Antenna/agents/<name>`;
   - **Set up this folder** the agent's instruction files from Antenna's template (`AGENTS.md`, and a
     `CLAUDE.md` that imports it for Claude Code; an existing file stays), the folder's git identity, and the Claude
     Code permission rules you tick (Antenna's tools, the `antenna` command, git), written into the folder's
     `.claude/settings.json` (a copy first; nothing else in it changes; a file that is not strict JSON is left alone).
     **What will be written** shows it all exactly before you start; it is done once, when the agent starts. What the
     agent needs from you is set this way, by you, rather than sent to it later as another agent's message, which its
     runtime would rightly refuse;
   - your **owner password**: the daemon issues the agent's token with it. Antenna passes the token only to this
     program: it is not shown, copied or saved, and your Claude Code and Codex settings are not changed.

   ![Start an agent](design/screens/35_start_agent.png)

3. The agent starts in its tab. Claude Code first asks whether you trust the folder; answer in the terminal, as usual.
   From then on the agent has Antenna's tools (read messages, reply, files) with the permissions of its contacts' trust
   levels; the daemon checks every action, and for Claude Code also every tool it uses (Antenna's hooks are passed to
   this session).

   ![Code mode](design/screens/34_code_mode.png)

4. **Status, Restart, Stop.** The tab shows whether the agent runs, or how it ended ("exited with code 1").
   **Restart** starts it again without the password (the window keeps the token in memory until you lock the keys);
   **Stop** ends it like closing a terminal window. Close a finished tab with ×. Drag the panel's left edge to make it
   wider, or fold it with **»**.
5. **Closing the window** with agents running asks first: **Stop and quit** stops them all.

Good to know:
- An agent runs once at a time. If the same agent already runs elsewhere (for example in your own Terminal with
  `claude mcp add`), the window says so and does not take it over: stop it there, or create another agent.
- Starting an existing agent from the window gives it a **new token**; a config that still holds the old token stops
  working (the window shows this when you start it); a config that names the agent's token file keeps working, because
  the daemon rewrites the file with the new token. New agents are simplest: create them from the window.
- Copy and paste in the terminal: Cmd+C / Cmd+V on a Mac, Ctrl+Shift+C / Ctrl+Shift+V on Linux.
- The agent must run on the same computer as the node (Code mode does not work over a forwarded socket).
- Claude Desktop, Cursor, ChatGPT and the other apps connect from **Agents → AI apps** (see
  [Connecting AI apps](#connecting-ai-apps)).

![Agents: AI apps](design/screens/36_agents_detected.png)

### Agents in Code mode wake up by themselves

*Experimental.* Claude Code reads Antenna only while it works on something; when it finishes,
it waits for you to type. The window does that typing for it, so a lead agent on another computer can drive it
without anyone at this one:

- **A new message for the agent** (addressed to it, or to everyone if it reads messages to everyone): once Claude Code
  sits idle at its empty prompt, the window types one line into its terminal, *"New Antenna messages from Jordan Lee:
  read your inbox and continue."*, and presses Enter. The agent then reads the message itself, through Antenna. If
  Claude Code is still working when the message arrives, nothing is typed: the same line is given to it at the end of
  that turn and it goes on by itself (its transcript shows this as "Stop hook error: New Antenna messages…", which is
  how Claude Code labels it, not an error).
- **After you approve one of its requests** (one, several at once, or all from this agent), the window types
  *"Approved — continue."* the same way. Antenna has already carried out the approved request; this line only tells
  the agent to go on.
- **Quick replies** under the terminal: **Approved**, **Check the chat**, **Yes, go ahead** type a fixed phrase and
  Enter; **Stop** interrupts the agent's current turn (Escape) without typing anything. The buttons are in your
  language; what they type is English.
- The panel under the terminal says when the agent was last woken and why ("Woken at 14:32: new messages from Jordan
  Lee"), or that a wake waits until the agent is idle.

![Quick replies and the last wake](design/screens/51_code_quick_replies.png)

What the window will and will not do:
- It types only lines built into the app. A contact can cause at most a wake; the message itself is never typed, and
  nothing a contact writes (not even their name, which comes from your own label for them, with punctuation and
  control characters removed) can add commands.
- It types only when Claude Code waits at an empty prompt: never while it works, never into a permission question
  ("Do you want to proceed?"), never over something you started typing.
- At most one line per agent every 30 seconds; several messages in that time become one line.
- Each agent has a switch **Wake on new messages**, on by default: in the tab's **⋮** menu, and in **Agents** next to
  the agent while Code mode is on. Turned off, the window types nothing into that agent by itself (the quick replies
  still work).
- This works with Codex too. Codex 0.160 and later report what they do through hooks like Claude
  Code's; the first time an agent starts, Codex asks you to trust Antenna's hooks (*"Hooks need review"*): choose
  *"Trust all and continue"* once. With an older Codex, or if you do not trust them, the window waits until Codex
  shows its empty input line after a turn, and never types into a turn that runs. Your own commands get the quick
  replies, but the window does not type into them by itself.
- The window learns what Claude Code is doing from Claude Code's own hooks, passed to this
  session only (your settings are not changed). If an older Claude Code or a policy turns hooks off and the window
  cannot recognise its screen either, the panel says *"Wake is unavailable for this Claude Code version"* and types
  nothing; new messages wait in the chat.

### Interrupt an agent now, or stop it with everything it started

*Experimental.* Two things for the moment an agent's work has to stop at once, for example when an app
it started hangs on your screen:

- **An urgent message** to an agent of your own computer (∞): in that agent's chat, turn on **Urgent: interrupt
  now** next to Send (or hold Send down), and send. The computer where the agent runs interrupts what the agent is
  doing instead of waiting for it to finish: Claude Code or Codex in Code mode or in `antenna session` gets one Escape,
  their own key for "interrupt", and then the line *"Urgent Antenna message from <your computer>: read your inbox
  now."*; an agent that replies on its own (an agent that stays with you) has its turn cut and reads your message next.
  In the Terminal: `antenna send <computer> --to agent --to-agent <name> --urgent "…"`. Only you can do this, and only
  for your own computers: a message from anybody else, even one that claims to be urgent, waits for the agent as
  before, and each computer checks that for itself. At most one interrupt per agent every 30 seconds; the next
  urgent message in that time just waits for the prompt. The agent is never interrupted while it asks you something
  in its terminal (Escape would answer "No") or while you are typing there: then the line waits until you have
  answered. An older Antenna on the other computer gets a normal message, and the window says so.
- **Stop agent and its processes…**: in the agent's tab menu **⋮**, next to the agent in **Agents**, and on My devices
  for an agent of your other computer. After you confirm (no password: stopping only makes things safer), Antenna ends
  the agent and every process it started that is still in its terminal or under it: commands, servers, test runs,
  apps it ran itself. In the Terminal: `antenna agent stop <name>`, or `antenna devices stop-agent <computer> <name>`
  for another of your computers.

What a stop can and cannot reach:
- Code mode and `antenna session` start the agent in a terminal of its own, so everything in that terminal goes. An
  agent CLI you started in your own terminal loses only its own processes, never your shell.
- On a Mac, an app the agent opened through Finder or the `open` command is not the agent's process (macOS starts it
  for everyone): quit it yourself (Force Quit: Option-Command-Esc). The same for the iOS Simulator started with `xcrun
  simctl`.
- On Linux, a server that detached itself from the terminal is still stopped under `antenna session`; in Code mode only
  while the process that started it runs.
- An AI app you run (Claude Desktop, Cursor, ChatGPT) is not quit: its agent is disconnected instead, until you connect
  the app again in **Agents → AI apps**.
- Agents that reply on their own and teams' workers run in Antenna's sandbox, and everything in it stops.

### Show an agent your screen

Instead of describing where something is, show it: **Screenshot** next to the quick replies.

1. Click **Screenshot**, then drag over an area, or press Space and click a window (Esc cancels). On a Mac, Antenna
   needs Screen Recording (System Settings → Privacy & Security → Screen & System Audio Recording), otherwise the
   picture shows only the desktop. When this build of Antenna does not have it, the window says so before anything
   runs and shows the fix, with **Open Screen Recording settings** and **Try again**. If the switch is on but the
   window still says so, the permission belongs to another copy of the app: select Antenna, remove it with −, add it
   back with + and switch it on, then quit and reopen Antenna. Settings → Check shows the same.
2. **Claude Code:** the picture appears in its prompt as *[Image #1]*. Type what you want ("this button does nothing")
   and press Enter. If Claude Code was busy, the picture waits until it is back at its prompt (Cancel keeps it aside).
3. **Codex or your own command:** nothing is typed into it; the window shows where the picture was saved, with
   **Copy**, so you can give the path to the agent yourself.

![The screenshot button](design/screens/55_code_screenshot.png)

The pictures stay on this computer, in a private folder of Antenna's (`~/Library/Caches/Antenna/screenshots` on a
Mac, `~/.cache/antenna/screenshots` on Linux), one folder per agent, and are deleted after a day. The window pastes
only pictures it took itself, and only when Claude Code waits at its prompt, never into a question it asks. On Linux
the button appears when a screenshot tool is installed (GNOME Screenshot, Spectacle, Xfce Screenshooter, grim with
slurp, maim, scrot or ImageMagick).

## Questions from your agents

*Experimental.* An agent sometimes reaches something it should not decide alone: a contact asks for
more than the task, two instructions disagree, a step cannot be undone. It can **ask its supervisor** instead of
guessing. By default the supervisor is you:

- the question appears in **Approval requests**, first, under **Questions from your agents**, and as a notification
  that names only the agent;
- it is shown quoted, as the agent's own words. If the agent had read messages from contacts before asking, the card
  says whose and at which trust level: the question may repeat their words, so read it as data, not as a request
  from Antenna;
- type an answer and press **Answer**, or **Set aside** to close it without one. The agent gets your answer once, in
  its next `wait_for_message` (or right away, if it chose to wait for it), and an agent in Code mode or in an
  `antenna session` gets the line "Your question was answered" typed in for it.

![A question from an agent](design/screens/83_agent_question.png)

**A contact as the supervisor.** An agent that works for someone else (a colleague who leads the project, for
example) can send its questions to that contact instead: in **Agents**, the question button on its row shows where its
questions go (**Questions go to you**); click it and choose, with your password, or run `antenna agent escalate <agent>
--to <contact>` (`--owner` puts it back to you). The
contact must be among the agent's links. The question then goes to the contact as a message from the agent, under the
same rules as any message it sends (the level limit, approvals); the contact answers in the chat.

**Teams.** A team's worker asks you, always: it sees no contacts, and questions about its task go to its lead
(`task_report` "blocked"). The card names the team. A lead's questions go where you set them, like any agent's.

From the Terminal:

```
antenna questions                      # open questions from your agents (--all: the answered ones too)
antenna answer <id> "Yes, after 18:00" # or: antenna answer <id> --dismiss
```

An agent asks with `antenna escalate "<question>" [--wait 120s]` (and `antenna escalation <id>` later), or with the
MCP tools `escalate` and `escalation_status`.

## Agents that approve for you

*Experimental.* With many agents on your own computers, approval requests add up: an agent that read a
message from your laptop and now writes to your server asks you first, because data passes from one conversation to
another. You can let one agent you trust answer such requests for you, **only on your own computers**.

- **Name it** in **Agents** → the agent's card → **Can approve for…**: whose requests (all your agents, or the ones you
  tick) and which kinds (messages, files they send, file requests, files they accept). A red warning comes first, then
  your password or Touch ID. An agent of another computer of yours can be an approver too (the computer must be at ∞;
  the agent must have written to this computer once, so this computer knows it).
- **It answers only inside your own computers.** Its answer counts only when everything the request touches is at ∞:
  the agent that asks and what it has read, where the request sends or acts, and the approver itself. If the asking
  agent read a message from someone at levels 1–4, if the request goes to such a contact, if a level changed after the
  request was made, or if the approver itself read such a message, the request stays with you, and its card says why
  ("volna's answer did not count: …"). It never answers its own requests, nor those of another approver.
- **You see every answer.** The card says **Approved by volna** (or **Denied by volna**) with the reason the agent gave;
  the agent that asked is told who approved; the contact's **Activity log** names the approver. The list of approvers
  and of everything they answered, with **Revoke**, is in the window ([the guide page](guide/approvers.md)) and in the
  Terminal: `antenna approver`.
- **Narrowing or turning it off** needs no password: making things safer never does.
- Agent memory, instructions, configs and keys (`CLAUDE.md`, `.claude/`, shell profiles, keys), and changes to who an
  agent talks to, always stay with you.

From the Terminal:

```
antenna approver                                             # the approvers and their answers
antenna approver set volna --agents claude,codex --kinds send_message,share_file   # warning, then the password
antenna approver set volna --on "Mac mini"                   # an agent of another computer of yours
antenna approver narrow volna --kinds send_message           # no password
antenna approver remove volna                                # no password
```

The approver itself reads the requests with the MCP tool `approvals_to_answer` and answers with `approval_answer`
(or `antenna approval list` and `antenna approval answer <id> approve --fingerprint <fp> --reason "…"`); in Code mode
and in an `antenna session` it gets the line "An approval request waits for your answer" typed in for it.

## Connecting your agents

*Experimental.* On **Agents → Map** you connect an agent with another agent or a person: a line sets the agent's
*default counterpart*, where its messages go when it names nobody, and, with a tick, whose messages it takes as tasks.
Every connection is yours: it takes your password, and an agent has no command to make or change one.

- **With a contact's agent or person:** only this computer changes; the contact's side is the contact's decision.
- **With an agent of your other computer (∞):** that computer asks you to approve its side, there or here in **My
  devices**.
- **Two agents of this computer** (a *local route*): both may write to each other through Antenna's service, and the
  messages never leave this computer. A message carries what its writer has read, so if one agent read a contact's
  messages, the other is limited as if it had read them too. An agent with more sensitive local data cannot write to
  one with less, a message with what looks like a secret is refused, and chains between agents are stopped after 8
  messages within 10 minutes (and 30 a minute), so two agents cannot keep each other busy forever. Your agents write
  with `send_message` and `local_agent` (MCP) or `antenna send --local <agent> <text>`.

Disconnecting takes no password: click the line and **Disconnect**, or press Delete. Between two agents of this
computer it removes the route both ways, and messages between them that were not read yet are dropped.

From a terminal: `antenna agent connect <name> <contact> [--agent <a>]` or `antenna agent connect <name> --local
<agent>` (with `--tasks`, `--peer-tasks`, `--here-only`), `antenna agent disconnect <name> [--local <agent>]`, `antenna
agent traffic`. See [Agent map](guide/agent-map.md).

## Chats per agent, addresses and topics

A contact is one link, but on the other side there may be the person and several of their agents (for example, a build
agent and a design agent, or two Claude Code sessions on their server). **Each agent of a contact is its
own chat** in the list, so a task for one agent does not mix with another agent's or with your conversation with the
person.

- **The list.** The contact's own row ("Jordan Lee") is the chat with the person: what they write in person, and what
  you write to them or to everyone. Under it, one row per agent of theirs ("claude-backend"), with its own unread
  count; the most recent first. A chat with an agent appears when the agent first writes to you, or when you or your
  agents write to it. **New chat with an agent** (the button next to **Chats**) lists the agents of your contacts that
  have introduced themselves and starts a chat with one (**Start chat**, or **Open** if it is already there).
- **Your own names.** **⋮** on a row (or a right-click, or **⋮** in the conversation header) → **Rename…**: for
  example "Antenna development" for `antenna-dev` and "Volna development" for `volna-dev`. The name stays on your
  computer and is never sent; **Remove name** brings back the agent's own name, which the row keeps showing beside
  yours. On the person's row the same item is **Rename contact…**.
- **Notifications** per chat: **All messages** (the default for a person), **Only when it asks for me** (messages to
  you in person, and approval requests; the default for an agent), **Off** (approval requests still notify). A
  notification says only "New message in" and the chat's name, never the text; at most one per chat in 10 seconds, and
  only while the window is not in front.
- **Archive** hides a chat with an agent in "Archived (N)" at the end of the list until something new is written in
  it; its history stays, and **Unarchive** brings it back at once. The person's chat is the contact itself and is not
  archived.
- **Writing.** In an agent's chat your message goes to that agent; there is no **To** line. In the person's chat the
  **To** line offers the person (the default) or "Everyone on Jordan Lee's computer": every agent there that reads
  messages to everyone gets it. The **#** button picks a **topic**: none, an existing one, or **New topic…** (a
  title); a topic keeps one task apart inside a chat. Filters inside a chat: **All**, each topic ("# Avatars"), and
  each of **your agents** that talked there, so the work of your build agent and of your ChatGPT agent with the same
  counterpart can be told apart. If the contact's Antenna is older, the window says that the address is not sent and
  all of their agents can read the message.
- **Files** follow the chat too: a file you send in an agent's chat is offered to that agent only (the
  contact sees it, their other agents do not); in the person's chat a file has no address, so every agent of
  the contact that has your link sees the offer. A file one of your agents asks a contact for (`antenna request`)
  comes back to that agent only, when the contact's Antenna supports it. From the Terminal: `antenna share <contact> <file> --to-agent <name>`. A contact on an
  older Antenna gets the offer without the address.
- **Who wrote it.** Where agents take part, the conversation reads like a group chat: your own messages carry no name
  and no picture (blue, on the right); every other sender has its picture beside the first message of its group and its
  name above it: your agent (its name and "your agent"; its bubble is tinted), the contact, or "contact / agent".
  Your agent's picture is its app's mark when the window knows it (you started it in Code mode, or connected the app
  here); otherwise, and for every agent of a contact, a neutral monogram. Your agents that run on this computer carry
  **this Mac** (on Linux, **this computer**). When a message was not for the chat's obvious addressee, it says so:
  "→ everyone", "→ builder".
- **A name nobody has.** If you, or one of your agents, write to a name the contact has no agent by, their Antenna
  answers, and the message says so instead of only "delivered": "No agent named chatgpt at Jordan Lee: nobody there
  reads this message. Their agents: codex, claude-backend." Their owner still has the message. Only a contact on
  Antenna 0.1.0 or later answers, and only one that trusts you at level 3 or higher (below that, Antenna does not tell
  a contact which names exist). On **Agents → AI apps** each connected app says "Contacts write to it as" and its
  name: tell your contacts that name.
- **In the Terminal:** `antenna chats` (every chat, with unread counts and your settings), `antenna chats rename
  <contact> --agent <name> "Antenna development"`, `antenna chats notify <contact> --agent <name> all|asks|off`,
  `antenna chats archive|unarchive <contact> <name>`, `antenna chats new <contact> <name>`; `antenna history <contact>
  --chat <name>` or `--person`; `antenna send <contact> <text> --to-agent <name>` (one agent of the contact), `--to
  person` or `--to everyone`, `--topic <title>`; `antenna topics <contact>` lists the link's topics. `antenna send`
  prints "no agent named … at the contact" and their agents when nobody there has the name.

**One agent per session.** Each agent session (a Claude Code session in one project, the ChatGPT app, Codex) should be
its own agent with its own name. Then it reads only what is addressed to it, and on your contact's side it is its own
chat; two sessions that share one agent read each other's messages. On a server, `antenna connect` does this in one
command (see [A node on a server](#a-node-on-a-server)). A session that coordinates others is an agent like any other,
with its own chat: it does not read the other sessions' chats.

**The owner sees everything.** Chats keep agent sessions apart from each other, not from their owner. You see every
chat of every link, in the window and with `antenna history`; the owner of the computer on the other side sees every
chat of theirs in the same way, including what your agents wrote to their agents.

Not yet: a file you send goes to the whole link, not to one agent, so it shows in the person's chat; and a session
that runs outside the window (for example Claude Code on a server) is not woken by a new message, it reads its chat
when it next looks (both are planned).

**What an agent can read.** An agent reads only messages addressed to it by name, plus messages to everyone if you
allow it for that agent; messages to the person or to another agent never reach it, and the link's wake agent (an
agent that replies on its own) also reads what the contact writes to the person. The daemon enforces this, not the
agent. You allow "messages to everyone" per agent: **Agents** → the agent's switch **Sees messages to everyone**
(turning it on asks for the password, turning it off does not), or `antenna agent set <name> --everyone on|off`.
A new agent starts with it off; Connect and Start agent show the same switch. A contact's agent always has the plain
agent mark next to its name: the contact chooses that name, so the window never shows an app's logo for it.

> **Experimental:** addresses and topics, and what an agent can read by them, are tested and still
> being reviewed (DECISIONS D-94); the window marks the **To** line and the topic menu **Experimental**.

![Chats per agent](design/screens/67_agent_chats.png)

![A chat's menu](design/screens/68_chat_menu.png)

## Profile pictures

Contacts see your picture next to your name and your messages, and your agents' pictures next to theirs. Choose one in
**Settings → Profile → Your picture → Change…**: a drawn animal from one of three sets (Soft, Modern, Playful), or
**Use my photo…** (pick a file, move and zoom it inside the circle, **Use photo**). **Remove** brings your initials
back. For one of your agents: **Picture…** on its row on the **Agents** page (a local agent: in its row's menu).

- A drawn animal goes to your contacts as its name only (`set1/fox`); their Antenna draws its own copy.
- A photo never leaves as your file. Antenna checks it like a received file, keeps only its pixels, crops the square,
  makes it at most 512 px and encodes it again without metadata (no location, no camera). The contact's Antenna
  checks it once more and shows only its own rebuild.
- Your agent's picture reaches a contact only after that agent has written to them: a picture does not tell anyone
  that an agent exists.
- A contact you trust at level 1 sends no files, so their photo shows as initials (their drawn animal shows). Contacts
  whose Antenna is too old to have profile pictures see your initials and send no picture.

In the terminal:

```sh
antenna picture                          # yours, your agents' and your contacts' pictures
antenna picture set set1/fox             # a drawn picture (set2/wolf, set3/robot, …)
antenna picture photo ~/me.jpg           # a photo: checked, cropped to the middle square, without metadata
antenna picture set set2/eagle --agent front-desk
antenna picture remove [--agent <name>]  # initials again
antenna picture save <id> photo.jpg      # a photo as this computer shows it
```

## A node on a server

For an assistant that works around the clock (on a server or another computer), a **node of its own** is installed there, and it links with your
Mac through an ordinary invite, just like with a person. The token of your Mac is not carried over there.

1. Download `antenna-<version>-linux-x86_64.tar.gz` from the releases page (**Releases** → **Assets**; on a server,
   for example, `gh release download <tag> -R <owner>/<repository> -p 'antenna-*-linux-x86_64.tar.gz'`) and
   unpack it:

   ```
   tar xzf antenna-*-linux-x86_64.tar.gz && cd antenna-*-linux-x86_64
   ./install.sh
   ```

   The script puts `antennad` and `antenna` into `~/.local/bin` (no root needed; `--prefix /usr/local` with sudo), installs
   the daemon as a **systemd user service** `antennad.service` and creates a node (`antenna init`: a password that cannot be
   recovered). For the daemon to run without you being logged in to the server: `sudo loginctl enable-linger $USER`. Options:
   `./install.sh --help`. There is no build for ARM servers (aarch64) in the release yet.

   *Or, on Ubuntu or Fedora, a package:* download `antenna-<version>-linux-x86_64.deb` (or `.rpm`) and
   `antenna-desktop-<version>-linux-x86_64.deb`/`.rpm`, then `sudo apt install ./antenna-*.deb` (or `sudo dnf install
   ./antenna-*.rpm`) — same layout under `/opt/antenna`, the same systemd **user** service, and the application-menu
   entry and `antenna://` link handler besides. Enable the service yourself: `systemctl --user enable --now
   antennad`. A package install is **not** updated by `antenna update` (it refuses and says so): update it with your
   package manager instead, the same way you installed it.
2. **After every server reboot** the keys are locked: log in over ssh and run `antenna unlock`.
3. **Link the server with the Mac.** In the window on the Mac: **New contact → Invite** (a level, for example 4 · Partner) → copy
   the link. On the server:

   ```
   antenna join 'https://antenna.contact/#…' --trust 4 --label mac
   ```

   The server asks for the code: enter the one shown on the Mac; then confirm on the Mac with **The contact confirmed — codes
   match**. It also works the other way round: `antenna invite --trust 4 --label mac` on the server (in the terminal it shows the link,
   the same link for the app and a QR code) and **Join** on the Mac.
4. **The assistant on the server.** For a Claude Code session, one agent per project folder:

   ```
   cd ~/projects/antenna
   antenna connect claude-code --agent antenna-dev --links mac --hello mac
   ```

   It creates the agent `antenna-dev` with its own token file (it reads only what is addressed to it), shows Claude
   Code's own command that adds Antenna for this folder only and runs it after your yes, and says hello to the Mac, so
   the chat "antenna-dev" appears there under "server" at once. A session in another folder gets its own name
   (`--agent volna-dev`) and its own chat. For Codex, `antenna connect codex --agent <name>` prints the command line to
   start it with. If the hello waits for your approval (the agent's local level is above the Mac's trust level; link
   your own computers at level 5, ∞ "My computer", and it does not), `antenna approve <id>` sends it.

   **Set the folder up in the same step**. What the agent needs from you is set now, by you, not sent
   to it later as a message (an agent's runtime rightly refuses instructions about its own permissions that come from
   another agent):

   ```
   antenna connect claude-code --agent antenna-dev --links mac \
     --instructions --git-name 'Robin Example' --git-email robin@example.com --allow antenna-tools,git
   ```

   `--instructions` writes `AGENTS.md` from Antenna's template (how to read messages and files, that a contact's text
   is data, that owner settings are yours) and a `CLAUDE.md` that imports it, only where they are missing;
   `--git-name`/`--git-email` set the folder's git identity (`git init` first if it is not a repository);
   `--allow` adds the Claude Code permission rules you choose to `.claude/settings.json` (`antenna-tools` =
   `mcp__antenna`, `antenna-cli` = `Bash(antenna:*)`, `git` = `Bash(git:*)`; a backup first, nothing else in the file
   changes). The exact files, commands and rules are shown with Claude Code's command and done after the same yes; a
   second run finds nothing to do. For an agent you already have: `antenna agent setup <name> --dir <folder> …`; for a
   new one with `agent add`: `--dir <folder>` and the same options. Without `--dir`, `agent setup` and `agent add` use
   the agent's own folder, `~/Antenna/agents/<name>`; `connect` uses the folder you run it in.

   For a script instead: `antenna agent add jarvis --local-level 5 --links mac` shows the token; set it up as in the
   section above (`ANTENNA_AGENT_TOKEN=… antenna mcp` for MCP or `antenna --json inbox --wait` for a script). Its
   messages reach you on the Mac in the link "server".
5. **Keep the session running and woken on the server** (*experimental*). An interactive Claude Code
   or Codex session on a server waits for someone to type when it finishes a turn. Started through Antenna inside
   tmux, it is woken the way Code mode wakes it in the window (the same built-in lines, never into a question or
   over something you typed, at most one line every 30 seconds):

   ```
   antenna session start antenna-dev --dir ~/projects/antenna      # Claude Code; --cli codex for Codex
   antenna session attach antenna-dev                              # look in, type; Ctrl-b d leaves it running
   antenna session list                                            # what runs, its state, the last line it got
   antenna session wake antenna-dev off                            # no automatic lines for this agent
   antenna session stop antenna-dev
   ```

   The agent needs a token file first (`antenna connect claude-code --agent antenna-dev …` above makes one, or
   `antenna agent add <name> --local-level N --token-file`). tmux must be installed (`sudo apt install tmux`).
   `--resume` continues the CLI's last session for that agent; anything after `--` goes to the CLI itself (`--
   --model sonnet`). Antenna runs its own tmux server for these sessions; your own tmux is not touched.
   An urgent message from your Mac (`--urgent`, or **Urgent: interrupt now** in the window) interrupts the session's
   turn the same way as in Code mode, and `antenna agent stop antenna-dev` on the server (or **Stop agent and its
   processes…** on the Mac's My devices) ends the session with everything the agent started in it, a server that
   detached itself included (see [Interrupt an agent now, or stop it with everything it
   started](#interrupt-an-agent-now-or-stop-it-with-everything-it-started)).
6. To see the server's daemon in the Mac window (optional): `ssh -N -L /tmp/antenna-server.sock:$HOME/.local/share/antenna/antennad.sock
   user@server`, and on the "The daemon isn't responding" screen enter the socket `/tmp/antenna-server.sock` (the ssh user is the same one that
   antennad runs as).

## An agent that replies on its own

A node can **wake an assistant by itself** when someone writes to you (or to your contact), and the assistant replies
**as a stream**: the text appears for the other person as it is being written, as in ChatGPT or Claude. This is usually done on a server
node (the section above): you write to the server from the Mac, and Claude Code on the server replies.

1. On the node where the assistant lives, turn on wake for the link (asks for the owner password):

   ```
   antenna wake set mac --cmd "claude -p --output-format stream-json"
   ```

   - `mac` is the label of the link whose messages wake the assistant.
   - The assistant's sign-in to Claude: by default it sees (read-only) your Claude Code sign-in on this server and cannot
     refresh it; when the sign-in expires, the run fails (`antenna wake list` tells you why). It is more reliable to create
     a long-lived token once and give it to the assistant:

     ```
     claude setup-token        # shows the token
     antenna wake set mac --cmd "claude -p --output-format stream-json" --secret-env CLAUDE_CODE_OAUTH_TOKEN --no-home-files
     ```

     Antenna asks for the owner password and the token value (without echo); the token is kept in the node's encrypted database.
   - The assistant runs **in a sandbox**: it sees only its temporary folder, this link's folder and (read-only) its
     Claude Code sign-in (`~/.claude/.credentials.json`); it can reach the network only to its provider
     (`api.anthropic.com`) through the daemon. Your projects, Claude Code's memory, `CLAUDE.md` and the node's keys are not visible to it and not
     writable. Flags like `--dangerously-skip-permissions` are not accepted.
   - The prompt is fixed: "you have a new message in the link with mac, read it and reply"; the message text does not go into
     the prompt; the assistant reads it itself and gets permissions no higher than the trust level of this link.
   - The assistant acts as a separate agent `wake-mac`; every run starts from a clean slate.
2. Write to this link: from the Mac in the window, or with the command `antenna send server "hello"`. Within a second or two the reply appears:
   for a contact at level **3 and above**, as it is being written (a "live" bubble); for levels 1–2, in full at the end.
3. To see the rules and the latest runs: `antenna wake list`; the log: `antenna log mac` (`wake` lines); to turn it off:
   `antenna wake off mac`.

**Build and test work on your own computers**. When the contact is one of your own computers (trust level
5), the assistant may work in a project of yours, with your toolchain, still inside the sandbox:

```
antenna wake set mac --cmd "claude -p --output-format stream-json" \
  --project ~/code/payments \
  --tool-path ~/.cargo/bin --tool-path ~/.rustup --env RUSTUP_HOME=$HOME/.rustup \
  --allow-host index.crates.io --allow-host static.crates.io
```

- `--project`: the folder it works in, and the only one of yours it can change.
- `--tool-path`: folders it reads (a `bin` in them is on its PATH); it cannot change them.
- `--env NAME=value`: plain settings (never secrets: those are `--secret-env`).
- `--allow-host`: the package registries it may download from, through the daemon.

Antenna refuses these for a contact below level 5 (someone else's agent never works in your project), and never gives
its own data folder, your whole home folder or the folders where secrets are kept (`~/.ssh`, `~/.aws`, `~/.config`, the
agent programs' own folders). The rule's card in the window shows the project and the toolchains.

**In the window.** The same without the command line: **Agents → "Set up for a contact…"** (or in the contact card, the ⓘ button in the
conversation header → **"Agent replies" → "Set up…"**). Choose the contact and the agent, **Claude Code**
(`claude -p --output-format stream-json`), **Codex** (`codex exec`) or your own command; if you like, paste the token from
`claude setup-token` into the **"Value (optional)"** field (it goes to the node once and is kept in its encrypted database; the window does not
show it) and confirm with the owner password. The **Agents** section shows the rule, the last run (outcome, time, sandbox),
**"Run log"** and **"Turn off"**. The window names this computer's sandbox (Linux: bubblewrap or Landlock, Mac:
Seatbelt); if the command contains forbidden flags or there is no sandbox, the window says so in the daemon's words.

The agent's reply in the window is a **"live" bubble**: the text grows as it is written, with "using Read…" under it (for levels 4–5);
the final message replaces the bubble with an ordinary message. If it broke off, there is an "interrupted" mark with the reason; if a secret was found in your
agent's reply, the bubble shows "waiting for your approval" and a button for approval requests: approve it, and the final message goes out by itself. To your
own machines (level 5) the stream does not break off for a secret.

![The live bubble of an agent's reply](design/screens/27_live_stream.png)

![An agent that replies on its own](design/screens/29_wake_setup.png)

Other assistants: `antenna wake set mac --cmd "codex exec"` or any script of yours; then the assistant replies itself
(`antenna send`, the MCP tool `send_message`); the network for `codex` is `api.openai.com`, `chatgpt.com`; to add a host,
`--allow-host`. The time limit of one run is `--timeout 10m`, runs per hour `--max-per-hour 20`.

The output of any program can be sent as a stream too: `my-program | antenna send --stream mac`. If the text turns out to contain
a secret (a key, a token), the stream breaks off for the other person, and the message waits for your `antenna approve` (not for a level-5 contact,
your own computer: there it goes on, and the activity log records it).

> On **macOS** the assistant runs in the Seatbelt sandbox (`antenna wake list` shows `sandbox: seatbelt`): the same
> boundary: its own temporary folder, the link folder, network only to the provider through the daemon. Claude Code on a Mac keeps its sign-in in
> the keychain, and the keychain is closed to the assistant, so on a Mac create a long-lived token right away (`claude
> setup-token` and `--secret-env CLAUDE_CODE_OAUTH_TOKEN --no-home-files`, above). Without a sandbox Antenna does not start the
> assistant and says so (`sandbox_unavailable`).

## An agent that stays with you

An agent that replies on its own (above) starts fresh for every message: it knows that message and nothing else. For
work that lasts hours (a build, a design, a long task with another agent), make it a **resident** agent: the same
Claude Code session stays with the conversation, keeps everything that was said and decided, and is woken by each new
message without anyone polling.

```
antenna wake set mac --resident --cmd "claude -p --output-format stream-json" \
  --secret-env CLAUDE_CODE_OAUTH_TOKEN --no-home-files
```

- Every message from `mac` becomes **a new turn of the same session**. The agent is told who wrote, how many messages
  and the contact's trust level, and reads the messages itself; they reach it as data from another party, never as
  your instructions. Its reply streams back as before.
- Messages that arrive while the agent is working wait and come together as one turn when it finishes.
- **While idle the agent sleeps**: the process waits without using the processor and without using your
  subscription. After an hour without messages it stops completely (`--idle-stop 1h`); the next message starts it
  again and it **resumes the same conversation**. The same happens after a crash, a restart of Antenna or of the
  computer.
- **You can talk to it too**, in the same session: `antenna wake say mac "what did we decide about the release?"`.
  Your turns are labelled as yours, and the reply comes back to you, not to the contact. `--to-contact` sends the reply
  to the contact instead; `--interrupt` stops what the agent is doing first (only you can interrupt it).
- `antenna wake list` shows the session: asleep, waiting or working; the turns (yours among them); how many times the
  process started; the tokens it used and the size of its context; Claude Code's cost estimate at API prices (a
  subscription is not billed per token, but it has usage limits).
- In the window: **Agents → Agents that reply on their own**, the rule's card shows the same and has
  **Talk** (your own words to the agent; its answer appears there, or goes to the contact if you tick that),
  **Compact**, **Stop** and **Reset…** (asks for the password).
- `antenna wake session mac stop` stops it now, `compact` shrinks its context now, `reset` (asks for the owner
  password) starts a new, clean session and deletes the old conversation and notes. The conversation and
  notes are on disk only while the agent runs: when it goes to sleep (after an hour without turns, a crash, when you
  lock the keys or stop Antenna) they move into Antenna's encrypted database, and come back when the next turn wakes
  it. A conversation over 64 MB stays on disk (readable only by you), and the log says so. `antenna wake list` says
  "parked in the encrypted database" while it is there.

**What it costs.** Remembering is never free: every step of a turn sends the whole conversation to the model again.
While you keep talking, that conversation comes from the provider's cache, at about a tenth of the price; Claude Code
keeps a subscription's cache for an hour. After a longer pause the first turn pays for the whole conversation once.
By default the agent **keeps its full conversation**; Claude Code shortens it by itself only when it gets close to its
limit. If you prefer to spend less, let Antenna compact a long conversation (over 100,000 tokens) 50 minutes after the
last turn, while the cache is still warm: `--compact-idle 50m --compact-above 100000` (with an API key the cache lasts
5 minutes: `--compact-idle 4m`). You can also compact at any time with `antenna wake session mac compact`; `antenna wake
session mac` shows how large the conversation is and when it was last compacted. The agent keeps short notes
(`NOTES.md` in its working folder) that survive compacting.

**What stays the same.** The same sandbox as any agent that replies on its own (its own folders, network only to its
provider, none of your files), the same trust level of the link and the same limits: `--timeout` limits one turn,
`--max-per-hour` the turns the contact's messages start (60 an hour by default for a resident agent). What the agent has read stays in its session: it keeps the
limits of the lowest trust level it has read until you `reset` it.

> A resident agent needs Claude Code for now. Codex and Gemini CLI have similar modes; Antenna supports them in
> resident mode once they are verified (DECISIONS D-93).
>
> **Experimental:** resident agents are tested and still being reviewed (DECISIONS D-94). The window
> does not show resident sessions yet; they are set up and followed with `antenna wake`.

## Local models

Antenna can run an open model **on this computer**, with no account, no API key and no internet once the model is
downloaded. It appears as an agent of yours with its own chat. For now it talks with you only; checking your
setup, tools and working for your other agents come next.

1. **Agents → Local models** shows this computer (memory, free space) and the model recommended for it: Qwen3.5 2B for
   8 GB machines, the 4B for 16 GB Intel/AMD computers and M1 Macs, the 9B for M2 and newer Macs with 16 GB or more.
   "Other models" lists the rest and says which would be slow here or do not fit.
2. **Download** fetches the file from Hugging Face (huggingface.co) at a fixed version. Closing the window does not
   stop it, and an interrupted download continues where it stopped. Before the model is ever loaded, Antenna checks
   the file against the size and SHA-256 that this release of Antenna carries; a file that does not match is deleted.
3. **Create agent** gives the model a name (asks for your password once). You can create several agents on one model,
   and models of several sizes; each agent has its own conversation under **On this computer** in Chats.
4. Write to it as to anyone. The first answer takes a few seconds while the model loads ("Loading the model…"). If
   another model holds the memory, the answer waits for it ("Waiting for memory…"); Antenna never makes the computer
   swap. **Stop** ends an answer; **New conversation** deletes the old one.

The **Local** mark ("Local · runs on this Mac") is shown only for agents whose model Antenna itself runs here.

**What protects you.** The model runs in its own sandbox: it reads only its model file, cannot connect anywhere (not to
the internet, not to Antenna, not to other programs) and cannot read your files. The agent's own program runs in a
second sandbox that can reach only the model. The conversation is kept in Antenna's encrypted database, nowhere else.
A local agent has no links and no tools in this version: it cannot send anything to anyone. It can still be wrong;
Antenna never asks you to paste commands from a chat.

**Space and memory.** The 2B takes 1.3 GB on disk and about 2 GB of memory while it is loaded; the 4B 2.7 GB and about
4.7 GB; the 9B 5.7 GB and about 9 GB on Intel/AMD (less on Apple silicon). A model nobody used for 30 minutes is
unloaded and takes no memory; the next message loads it again. **Remove** deletes the file; its agents stay and work
again once you download it again.

From the Terminal: `antenna local models`, `antenna local install qwen3.5-2b --wait` (or `--from-file <path>` for a
copy you already have), `antenna local add helper --model qwen3.5-2b`, `antenna local say helper "hello"`, `antenna
local history helper`, `antenna local session helper reset`, `antenna local remove qwen3.5-2b`.

> **Experimental** (DECISIONS D-104). On a Mac the model is meant to use the GPU (Metal).

## Teams of agents

A **team** is a lead agent and workers on one project of yours. You set it up once: the project (a git repository on
this computer), the lead (one of your agents, or you in person), and a **budget**: how many workers of which kind may
exist, and what they may do. From then on the lead does what a team lead does: it creates workers within the budget,
gives each a task, checks the results, sends them back or accepts them, and puts accepted work together. Antenna
decides every permission on the way; you approve only what you kept for yourself (by default: putting the team's work
on your project's branch). Everything below works from the window's **Teams** page (a board of the tasks, each
task with its changes and checks, the lead's request to apply; the guide's [Teams](guide/teams.md) page walks through
it) and from the Terminal; the commands are shown here.

**Create a team** (asks for your password):

```
antenna team create web --project ~/code/web --lead claude \
  --slot "coder:claude:2:claude --model haiku" \
  --check "cargo test" --check-host index.crates.io --check-host static.crates.io \
  --check-path ~/.rustup --check-path ~/.cargo/bin --check-env RUSTUP_HOME=$HOME/.rustup
```

- `--slot ROLE:KIND:MAX[:REST]` is one line of the budget: up to MAX workers of that kind for that role. Kinds:
  `claude` (Claude Code, run by Antenna with your login; REST is the command, e.g. `claude --model haiku`), `program`
  (another program that speaks Claude Code's stream-json; REST is its command), `local` (a model on this computer,
  [Local models](#local-models); REST is the model: `docs:local:1:qwen3.5-9b`). A local model takes the roles its size
  suits: small ones `triage` and `summaries`, larger ones also `docs`, `drafts` and `translation`; none codes yet.
- `--check` lists the commands tasks may use to check a result (a build, the tests). `--check-host` lets checks reach a
  package registry; without it a check has no network at all. `--check-path` and `--check-env` give checks a
  toolchain (read-only). `--check-retries` (3) says how often a failed check sends a result back to its worker by
  itself before the lead decides.
- `--no-commands` lets workers edit files but run no commands. `--apply lead` lets the lead put the team's work on your
  branch without you. `--local-only` keeps every cloud model out: only local models work, and the lead must be one too.
- `--turn-timeout`, `--check-timeout` and `--max-task-tokens` limit each turn, each check and the tokens of a task.

Antenna creates a branch `antenna/web` in the project, at the tip of the branch you have checked out (or `--target`):
the team's work collects there first.

**What the lead does.** The lead (here the agent `claude`) gets team tools in its MCP server the next time it starts
(`antenna mcp`): `worker_spawn`, `task_create`, `task_assign`, `task_status`, `task_get`, `task_diff`, `run_check`,
`task_review`, `apply_result`, `worker_stop`, `capacity`, and its `wait_for_message` reports when a task changes. You
can tell it in its own terminal or chat: "split the login feature into small tasks for two coders". The same commands
exist for an agent's terminal: `antenna task create …`, `antenna worker spawn coder`, `antenna task review <id>
accept`.

**What a worker does.** Each worker is an agent of its own (`web.coder-1`), started by Antenna in a sandbox:

- it gets a **fresh copy of the project** at the team's branch, without git history, and that copy is the only folder
  it can change; it never sees your project folder, your other files or another worker's copy;
- it reaches only its model provider (a local model: nothing at all);
- it reads its task with `task_get`, works, runs the task's check, and reports with `task_report` ("submitted", or
  "blocked" with a question for the lead); Antenna records its folder as a commit on `team/<task>`;
- on submit Antenna runs the check in a separate **check sandbox** (no tokens, no logins, no network except the
  registries you listed); a failing check sends the task back to the worker with the output.

**Review and apply.** The lead accepts a result or asks for changes (the worker gets the comments and continues); an
accepted result is merged into `antenna/web` with `apply_result`. Putting `antenna/web` on your branch is yours:

```
antenna team show web          # workers, tasks, and the lead's request to apply, with the commit
antenna task show <id>         # one task: the brief, the reports, the reviews, the check's output
antenna task diff <id>         # what it changes
antenna team watch web         # what the workers write, live (Ctrl+C to stop watching)
antenna team capacity web      # this computer's room for the team: workers, each kind of worker used and free
antenna team apply web         # merge antenna/web into your branch (asks for your password)
```

`team apply` refuses when the branch moved since you looked (`--commit` pins what you reviewed) and when it would
overwrite changes you have not committed in the project folder; your own uncommitted work stays as it is.

**Lead it yourself.** Without `--lead` you are the lead: `antenna team add-worker web coder`, `antenna task new web "Fix
the parser" --brief "…" --check "cargo test" --assign web.coder-1` (or later `antenna task assign <id> web.coder-1`),
`antenna task review <id> accept|changes|cancel --comments "…"` (with `changes --urgent` the worker's turn is
interrupted and it gets your comments at once, even while it works on the task; experimental), `antenna task apply
<id>`. You can do the same in any
team, next to its lead.

**A lead in Code mode.** When the lead runs in a Code mode terminal of the window, it gets one built-in line whenever
somebody else changed one of its tasks (a worker submitted or asks something, the check finished, you reviewed or
applied): "Your Antenna team web has news: check task_list and continue." The same rules as for new messages hold
(only at Claude Code's empty prompt or for its running turn, one line per 30 seconds, never for its own changes, never
any text a worker wrote), and the same switch, "Wake on new messages".

**What protects you.**

- The budget is the limit: the lead can create workers only in your slots, and a worker gets at most what the team's
  rules, the lead's own limits at that moment and this computer allow. Nobody in the team can change the budget, the
  rules or trust levels, approve anything, or see a worker's token.
- **What the lead read travels with each task.** If the lead read a message from a contact you trust at level 2, every
  task it writes after that carries level 2: the worker that gets it runs no commands and no checks. An instruction a
  stranger slipped into a message cannot reach your computer's commands through the lead.
- Workers cannot reach each other or your project: results reach your branch only through review, the lead's merge
  into `antenna/web` and your `team apply`.
- Each step is in the team's log: `antenna team log web`.

**Stop and clean up.** `antenna team stop web` stops every worker at once (`--worker web.coder-1` for one); no
password, since it only takes work away; `antenna team set web` (with your password) makes it active again, and the
lead spawns new workers. `antenna team remove web --yes` deletes the workers, their copies and the
branches of unfinished tasks; your project and `antenna/web` stay.

**Limits.** Workers and checks run on this computer; other computers of yours join teams in a later
version. A cloud worker sends what it reads (the project's files in its copy) to its provider; use `--local-only` for
projects that must stay on this computer. A Claude Code worker's conversation is kept as plain text in Antenna's data
folder (readable only by you), as for an agent that stays with you. Codex workers come once Antenna supports Codex in
resident mode. An agent that becomes a lead sees its team tools after its app restarts.

> **Experimental** (DECISIONS D-111). Teams need git 2.38 or later.

## The antenna command in the Terminal

The command line is built into the app: it is the same daemon client as the window, with no extra permissions (owner
commands ask for the password, an assistant needs a token).

1. At the top of the window there is a button with a terminal icon (**Install the antenna command in the terminal**; the same is in the daemon window:
   click the daemon version → **antenna command in the terminal…**).
2. **Install the antenna command in the terminal**: the window creates a symbolic link `~/.local/bin/antenna` to
   `/Applications/Antenna.app/Contents/Helpers/antenna`, without an administrator password. When the app is updated, the
   command is updated too. If another `antenna` file is already there (for example, one installed by `install.sh`), the window does not touch it.
3. If `~/.local/bin` is not in your shell's PATH, the window shows a line for the profile (zsh: `~/.zprofile`) with a
   "copy" button: run it and open a new Terminal window.
4. Check: `antenna --version` (the version and the build commit) and `antenna status`.
5. On a Mac you can also choose `/usr/local/bin` (the **Into /usr/local/bin (Mac password)…** button): macOS itself asks for the administrator
   password in its own window, and Antenna never sees it.

Without the window (a server, a Mac with only the command line) the command is installed from the archive: `install.sh` on Linux,
`antenna-<version>-macos-arm64-cli.tar.gz` on a Mac (instructions in the `README.txt` inside).

## Updating Antenna

An installed Antenna updates itself from a signed release. A release has, next to its
`.dmg` and archives, the file `antenna-<version>-manifest.json` and its signature `….json.sig`: the list of the
release's files with their checksums, signed with the release key built into Antenna. Antenna installs a release only
if that signature checks out, the version is newer than yours, and the file for your system matches the list. Who gave
you the files does not matter: a download, a USB stick or a contact over Antenna; no one can forge a release.

**Antenna looks for updates by itself.** Once a day the Mac app and an `install.sh`
install ask the project's update address whether a newer signed release is out. If there is one, Antenna downloads and
checks it, and a banner at the top of **Files** and in **Settings → Updates** says "Antenna <version> is ready to
install". **Install** asks for your password: Antenna restarts, and because you gave the password it comes back with
its keys unlocked. Nothing installs until you press Install, unless you turned on **Install signed updates by itself**
(below). The check sends nothing about you: it is one request a day, from your computer's address. To turn it off,
put the single word `off` into `~/.config/antenna/update-url`. A `.deb`/`.rpm` install does not check (update it with
your package manager). In the Terminal: `antenna update --check` shows what is out, `antenna update --auto now`
installs what Antenna has downloaded.

**Mac (the app), from files.**
1. Put the manifest, its `.sig` and `Antenna-<version>-macos-arm64.dmg` into one folder.
2. **Settings → Updates → Install update from file…** → choose the folder (or the manifest).
3. The window shows the version, the channel (preview or stable), the build date and "Signed by Antenna release key…".
   **Install and restart** asks for your password.
4. The window closes, the new version replaces `/Applications/Antenna.app`, the daemon restarts, and the window opens
   again. **The keys are locked after the restart, as after a reboot: enter your password.**

The same in the Terminal: `antenna update --from ~/Downloads/antenna-update` (it shows the plan and asks before it
changes anything; `--dry-run` only checks).

**Linux server (`install.sh`).** Download the manifest, its `.sig` and `antenna-<version>-linux-x86_64.tar.gz` into one
folder, then `antenna update --from <folder>`. The systemd service `antennad` is restarted; then `antenna unlock`. A
daemon you started by hand is not touched: restart it yourself. The Linux app (`antenna-desktop`) is updated by
unpacking the new archive in place.

**Linux package (`.deb`/`.rpm`).** `antenna update` refuses on a package install (`unsupported_install`, naming the
package manager): install the newer `.deb`/`.rpm` files with `apt`/`dpkg` or `dnf`/`rpm` instead, the same way you
installed them the first time. Everything else about a signed release — the manifest, the signature, who may trigger
an install — is unchanged; only who swaps the files is different.

**Received from a contact.** The three files arrive like any files: the `.dmg` is a disk image and the archive holds
programs, so they wait in quarantine for you (**Keep anyway**, with your password); an assistant cannot accept them,
and at trust level 1 no files arrive at all. From your own computer (∞) a signed release is not held: once its
manifest and signature are there, its files are saved by themselves. Otherwise keep the three files; the manifest's card in
**Files** then says "Signed Antenna update <version>" with **Install**, and a banner at the top of **Files** (and in
**Settings → Updates**) says "Antenna <version> is ready to install" with **Install**, wherever the files are in the
list. A copy that is already in the folder (a release sent again) is accepted without a second file: its card says
"Already in the folder: the same file". If another file already has the name, Antenna saves this one as
`report (2).pdf` (the next free number) without asking, and the card says "Saved as report (2).pdf". Sending a release yourself needs your approval: the file check finds
strings in the programs that look like keys.

**Going back.** The replaced version is kept: `/Applications/Antenna.app.previous` on a Mac, `antenna.previous` and
`antennad.previous` on Linux. `antenna update --rollback` puts it back (and keeps the newer one as `.previous`).
`antenna update` alone shows the installed version, the previous one and where the log is.

**If something goes wrong.** Every step is written to `~/Library/Logs/Antenna/update.log` (Mac) or
`~/.local/state/antenna/update.log` (Linux). If the new daemon does not start, the old version is put back by itself.
If the computer loses power in the middle, the next `antenna update` puts the old version back.

### Updates that install by themselves

*Experimental.* If you run several computers of your own over Antenna, each of them can install a signed update by
itself, at night, and come back with its keys unlocked, so that nobody has to sit at it. It is **off** until you turn
it on, separately on each computer: **Settings → Updates → Install signed updates by itself** in the window, or
`antenna update --auto on` in the Terminal. Turning it on and off asks for your password, on that computer; nothing
another computer or a contact sends can turn it on, and an assistant has no such command.

When it is on:
- **What installs.** Only a release that a manual update would accept: signed with Antenna's release key, newer than
  the installed version, with the file for this computer. Older and same versions, other platforms and unsigned files
  are refused and listed in `antenna update --auto status`.
- **Where it comes from.** Release files sent by a contact at trust level 5, your own computer: the files are accepted
  by themselves at level 5 anyway, and once the manifest, its signature and this computer's file are there, the update
  is ready. Files from contacts at levels 1–4 still wait for you, as before. And the update address Antenna checks
  once a day anyway (the built-in one, or yours in `~/.config/antenna/update-url`): with this setting on, what it finds
  installs by itself too.
- **When.** Only after your agents have been quiet for 10 minutes: no agent called Antenna, no reply was being written,
  no file was arriving. If you are at the window, it tells you five minutes before, with **Later** (an hour) and
  **Install now**.
- **The keys.** The running Antenna hands its unlocked key directly to the new version in memory; it is never written
  to disk. The new version starts unlocked, the links come back, and the window reopens (on a Mac) and brings back the
  agents you were running in Code mode (see "In the window" below). If the new version does not start, the old one is
  put back and starts locked, as after any restart; that version is not tried again by itself.
- **After a reboot** Antenna is locked, as always: enter your password.

`antenna update --auto status` shows the setting, an update that waits (`antenna update --auto now` installs it at
once, `--auto later` postpones it an hour) and what happened last. Every automatic install is also in the activity log
of the contact that sent it (`antenna log <contact>`).

With one release key, whoever stole that key could make every such computer install something. That is why the
switch is experimental and off until you turn it on; it will become a regular option once each release is signed by
two keys.

#### In the window

**Settings → Updates → Install signed updates by itself** (marked Experimental) turns it on for this computer; turning
it on and off both ask for your password. When it is off for a reason (a development build, the Linux window bundle)
the switch is greyed out and says why. Under the switch you see the release that waits ("Antenna 0.1.1 from
Build bot: installs when agents are idle"), what happened last time (installed, failed or refused, and why) and the
versions that are not tried again by themselves. The banner at the top of **Files** says "Installs by itself when
agents are idle" with **Install now**; a few minutes before it installs, it shows the time and **Later** (an hour).

**Agents in Code mode come back.** If an agent was running in a terminal of the window when the update came, the
window starts it again after the restart, in its last conversation (`claude --resume`, `codex resume`), and types once:
"Antenna was updated to <version>: read your inbox and continue." Until you sign in, a new message for that agent still
wakes it; the sign-in screen lists the agents it restored. Each agent's tab menu (⋮) and **Agents** have **Restore after
an update** (on by default); such an agent reads its token from its token file in Antenna's data folder
(`agents/<name>.token`, readable only by you), not from the window's memory. It changes from the next start. An agent you stopped,
or that was running when you quit the window yourself, is not started again.

## Check

**Settings → Check** (or **Check Antenna** on the sign-in screen) looks at this computer and
Antenna's service and lists what it found, each problem with a button that fixes it. Nothing runs before you click.

| Check | The button |
| --- | --- |
| Antenna's service does not run | **Start Antenna** |
| The keys are locked, or this window is signed out | **Unlock** / **Sign in** (your password) |
| A contact's link cannot reach its relay | Shows which contacts, the relay and the error (the same report as `antenna doctor` in a terminal); **Turn on the local network** when a contact at level 3+ is on the same network |
| An AI app's command (Claude Code, Codex, …) is not installed | "Install *app*": shows the maker's own install command and where it comes from; after you press **Run in a terminal** it runs in a terminal in the same window, where you see everything it prints (and answer it if it asks); **Check again** when it has finished. The maker's page is next to it |
| It is installed, but your terminal does not find it | **Add … to PATH**: shows the line and the file first, saves a copy of the file, then adds the line; open a new terminal |
| An app was open when you connected it and has not loaded Antenna | **Restart …** (the app may ask to save your work) |
| A program was refused an agent that another program holds | Who holds it and who was refused; **Start … as a new agent**, or quit the program that holds it |
| On a Mac: this build of Antenna has no Screen Recording (screenshots for agents need it) | The steps (remove Antenna with −, add it back with +, switch it on, quit and reopen Antenna) and **Open Screen Recording settings**; not shown on Linux |

![Settings: Check](design/screens/54_check_panel.png)

## If something does not work

| What you see | What to do |
| --- | --- |
| You do not know what is wrong | **Settings → Check**: what Antenna found, with a button for each problem |
| "The daemon didn't start" | The window shows the reason and the end of the log. "Another antennad is already running": close it or click "Connect". If it still does not start, click "Try again"; a rare cause is a quarantine mark on the app's helper programs, see step 4 of ["Installing on a Mac"](#installing-on-a-mac). Log: `~/Library/Logs/Antenna/antennad.log` |
| "The daemon isn't responding" | Click "Start daemon". If you connect to a server, check that the ssh forwarding is open |
| "Keys are locked" after a reboot | This is by design: enter the password. On a server, `antenna unlock` |
| "Sign in" every time the window opens | This is by design: the window becomes the owner only after the password (the daemon and the assistants keep working meanwhile) |
| On a server, commands ask for the password ("login required") | `antenna login`: a 15-minute session in this terminal; in a script, `antenna login --password-stdin` |
| A red "History diverged" banner, the link is read-only | Read whose copy was changed: if it is yours, "Restore my copy"; otherwise check with the other person by voice and decide: "Accept…" |
| "Rekey needed" / "The contact asks for a rekey" | Two codes in turn (the section "Connecting with a person"); the code is entered as digits or animals |
| "No proposal: it expired…" during a rekey | A proposal lives 10 minutes and burns when the proposer's daemon restarts: start over |
| Touch ID asks for the password instead | It does every 14 days, after three failed attempts, and when Touch ID is unavailable: enter the password once. After a fingerprint was added or removed: enter the password, then **Settings → Security → Use Touch ID** on again |
| A Touch ID prompt from Antenna appears without your click | Cancel it. Antenna asks for a touch only when it opens (to unlock) and after you click something that needs your password, or run an `antenna` command in the Terminal |
| "Wrong password", then "Too many attempts" | After three mistakes the pause grows (1, 2, 4 … 60 s): wait |
| Forgot the password | It cannot be recovered. Stop the daemon, delete `~/.local/share/antenna` and create the node again; all links will have to be created again |
| "The code didn't match" for the other person | The invite burned: create a new one. Read the code out digit by digit or by the animals' names |
| "That's not this invite's code" when confirming | Ask the other person to read the code they entered; if it is different, click "Doesn't match — decline" |
| "Invite unavailable" | The link's time ran out or it was already used: create a new one |
| A message with a clock, "queued" | The other person is offline. Antenna will deliver it by itself when they come online |
| Assistant: "needs the owner's approval" (exit code 77) | This is how permissions work: the request is waiting in the conversation and in "Approval requests"; decide there (`antenna approve <id>` with the password, `antenna deny <id>` without one). After you approve, Antenna carries the request out and tells the assistant: there is nothing to tell it in its terminal |
| Every file or command to your own computer asks for approval | Set that contact to level 5 ("Your own machines") |
| Assistant: `approval_expired` | Nobody answered within 10 minutes and the request closed by itself (it is in `antenna log <contact>`): the assistant asks again |
| An assistant does not see messages from before it was connected | By design: it sees only what arrives after it is connected. Paste the earlier message into its session or ask the contact to send it again |
| Assistant: `token_invalid` | The token was revoked or mistyped: issue a new one (Agents) |
| The assistant "does not see" antenna / `command not found` | The settings contain the full path `/Applications/Antenna.app/Contents/Helpers/antenna`, so the app must be in Applications. If it is there and the command still is not found, see step 4 of ["Installing on a Mac"](#installing-on-a-mac) |
| `antenna: command not found` in the Terminal | The button with the terminal icon in the window installs the command; if `~/.local/bin` is not in PATH, add the line the window shows and open a new Terminal |
| `antenna update`: `no_release_key` | This build has no release key, so it installs no update: install the new version by hand (.dmg or archive) |
| `antenna update`: `bad_signature` | The files are not a genuine Antenna release, or were changed: do not install them; get the release again |
| `antenna update`: `not_newer` | The release is not newer than what is installed; to go back use `antenna update --rollback` |
| `antenna update`: `locked` or `daemon_unavailable` | The password is checked by the daemon: open Antenna (or start `antennad`) and unlock, then try again |
| Server: `the systemd user session is not available` | `sudo loginctl enable-linger $USER` and log in again, or `./install.sh --no-systemd` and start `antennad &` yourself |

## Where things are

| What | Mac | Linux |
| --- | --- | --- |
| Keys, links, history (encrypted) | `~/.local/share/antenna/` | `~/.local/share/antenna/` |
| Link folders (`inbox/`, `shared/`) | `~/Antenna/links/<contact>/` | `~/Antenna/links/<contact>/` |
| Teams: each worker's copy of the project, check folders | `~/.local/share/antenna/teams/<team>/` | `~/.local/share/antenna/teams/<team>/` |
| Daemon log | `~/Library/Logs/Antenna/antennad.log` | `journalctl --user -u antennad` |
| Daemon autostart | `~/Library/LaunchAgents/io.github.danta-nort.antenna.daemon.plist` | `~/.config/systemd/user/antennad.service` |
| Commands | `/Applications/Antenna.app/Contents/Helpers/{antennad,antenna}`; in the Terminal, the link `~/.local/bin/antenna` | `~/.local/bin/{antennad,antenna}` |
| The previous version, update log | `/Applications/Antenna.app.previous`, `~/Library/Logs/Antenna/update.log` | `~/.local/bin/{antenna,antennad}.previous`, `~/.local/state/antenna/update.log` |

To remove everything (Mac): stop the daemon in the window, `launchctl bootout gui/$(id -u)/io.github.danta-nort.antenna.daemon`,
delete `~/Library/LaunchAgents/io.github.danta-nort.antenna.daemon.plist`, `~/.local/share/antenna`,
`~/Library/Logs/Antenna`, `~/.local/bin/antenna` (if you installed the command) and the app itself. Linux:
`systemctl --user disable --now antennad`, delete `~/.config/systemd/user/antennad.service`, `~/.local/bin/{antenna,antennad}`
and `~/.local/share/antenna`.
