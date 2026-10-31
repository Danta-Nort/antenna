<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Agent map

*Where it is.* **Agents** → **Map**, the toggle next to **Connect an agent** at the top of the page (**List** brings
the cards back). The window remembers the choice until it closes. Experimental.

The map shows who your agents work with, and it is where you connect and disconnect them, like a board you draw
on. A line you draw sets an agent's *default counterpart*: the agent or person its messages go to when it does not
name anyone. It can also make that counterpart's messages *tasks* for the agent rather than plain information.
Antenna's service on each computer sets both, and decides everything else as before.

![The agent map: your other computers on the left, this computer in the middle, contacts on the right](img/86_agent_map.png)

## How to connect and disconnect agents

1. Open **Agents** → **Map**.
2. Find the two ends. Each agent card has a small circle on its side, its *handle*.
3. Drag from the handle of one agent to the other agent (or to a person) and let go. The cards you can drop on light
   up while you drag.
4. Check what the dialog says will change, type your password and press **Connect**.
5. To disconnect, click the line, then **Disconnect** in the box that opens (or press Delete or Backspace).

Every action says how it went in a strip at the bottom of the map: running, done, or why it was refused.

## Moving around the map

- *Pan*: drag the empty background, scroll with a mouse wheel, or scroll with two fingers on a trackpad.
- *Zoom*: pinch on a trackpad, or hold Ctrl (Cmd on a Mac) and scroll; or use −, + and **Fit** at the bottom right
  (**Fit** shows the whole map; a click on the percentage goes back to 100%).
- *Move a group*: drag a computer or a contact by its header. Put it anywhere.
- *Reorder agents*: drag an agent card by its body to another place in its group. An agent stays on its computer: a
  card dropped on another group goes back, and the map says why.
- **Arrange automatically** (top right) puts every group and card back where the map places them and shows the whole
  map.

The window remembers the arrangement, the zoom and whether recent messages show, in its own settings file, so the
map looks the same the next time you open it and after a restart. Nothing of it is sent anywhere. A new contact or
computer appears where the map would put it, below what is already in its column.

## What is on the map

- *This computer*, in the middle: its agents, each with its picture, a status dot and what it runs as (*Claude Code*,
  *Codex*, *Local model*, *Replies on wake*, or a team's worker). An agent on a local model, a link's wake agent and a
  team's worker are shown with a struck link icon and have no handle: Antenna's service decides where those write, so
  they cannot be connected. Hover over one to see why.
- *Your other computers*, on the left: the contacts you set to ∞, online or offline, with the agents each one reports
  (the same list as in [My devices](my-devices.md)). One of your computers is always on the left, also when it is
  the only other computer you have. Until it has reported its agents to this one, its header says "Waiting for its
  report".
- *Contacts*, on the right: each contact with their person and the agents they announced or that wrote to you.

A line between two of your other computers' agents is set on those computers and does not show here.

## The lines

A row under the header explains them; no line is ever dashed.

- *Connected* (solid blue): where an agent's messages without an address go. The arrow points at the counterpart.
  When both sides point at each other, one line carries arrows at both ends.
- A small *tasks* mark at an end: that agent takes the other end's messages as tasks.
- *Waiting* (grey, "Waiting for approval on …"): this computer's side is set, and the request for the other side
  waits for your approval on that computer.
- *Team* (thin violet, with the team's name): a team's lead and each of its workers ([Teams](teams.md)). The team
  sets these lines; they are not disconnected here.

Hover over a line to see what it means, in words.

The map is read again when you open it, every 15 seconds while it is open, and whenever an agent or one of your
computers changes.

## Connecting two agents

Drag from an agent's handle to an agent or a person on another computer, and let go. A line can start at either end:
from one of this computer's agents, or from the other computer's agent towards it. Dragging a card's body moves the
card; only the handle draws a line.

From the keyboard: an agent's ⋯ menu → **Connect to…** → pick the other end.

Nothing is sent until you press **Connect** in the dialog. It shows both ends and exactly what will change:

- *On this computer*: messages from your agent without an address go to the other end (this is what the line
  sets), and a checkbox, *Messages from … are tasks for …*. It starts ticked for your own computers and for contacts
  the agent already takes tasks from, unticked for anyone else: tasks are for people you trust. It changes only
  when you change it, so an agent that follows the default list (your computers at ∞) keeps it.
- *On your other computer* (when the other end is an agent of one of your computers): that agent's messages without
  an address come back to your agent, and a checkbox, *Messages from this computer are tasks for …*, ticked. That
  computer does not change anything by itself: it asks you to approve it, there or here in **My devices**.
- *A contact's agent*: only this computer changes. The contact's side is the contact's decision, and Antenna does not
  change anything on their computer.
- *A person*: your agent's messages without an address go to that person.

Connecting asks for your password, which the window does not keep. The same line from a terminal is printed under
the password field.

![Connecting an agent to an agent of your own Mac mini](img/87_agent_connect.png)

After **Connect** the dialog says what happened on each side, and the strip at the bottom of the map says it again
once the dialog is closed:

- this computer: connected;
- your other computer: waiting for your approval, with **Approve now**, which opens that computer's request right
  here with **Approve with Touch ID** (or **Approve with password**) and **Deny**, as in **My devices**;
- that computer already has this connection; its Antenna does not know connections yet (update it); it could not be
  reached (this side is set: **Ask again** sends the same request, with your password); or it refused, with its
  reason;
- a contact: their side is their decision; a person: they read these messages in person.

The approval on the other computer says in plain words what it will set, for example "Connect session-2 with volna
on MacBook: messages from session-2 without an address go to volna. Messages from MacBook become tasks for
session-2." It shows there among the approval requests, and here in **My devices** on that computer's card. That
computer carries it out once you approve.

## A line's box, and disconnecting

Click a line (or the small circle in its middle, or its label). It is drawn thicker, and a box opens under it that
says what the line does: its two ends and their computer, where each side's messages without an address go, and who
takes whose messages as tasks.

![A selected line with its box; recent messages shown as a grey line](img/93_map_line_selected.png)

- **Disconnect** removes the line at once, with the usual choices: your agent keeps taking tasks from that contact,
  and one of your own computers is asked to disconnect its side too (another approval request there). Delete or
  Backspace does the same while the line is selected.
- **Options…** opens the disconnect dialog with its choices: *Also stop taking tasks from …* (off unless you tick
  it); for your own computer *Ask … to disconnect … too* (on) and *Also ask … to stop taking tasks from this
  computer* (off).
- For a waiting line, **Approve now** answers the request on that computer from here.

Disconnecting takes no password: it only takes something away. While it runs the line is drawn faded and the strip
says "Disconnecting …"; then it says what happened on each side, or why it could not be done. A line only the other
computer drew (its agent points at yours) is removed the same way, by asking that computer. Press Escape, the ×, or
click the empty map to close the box.

## Recent messages

**Show recent messages** (top right) adds thin grey lines between agents that wrote to each other in the last 30 days
without being connected, labelled "messages, not connected" and the time of the last one. It is off by default, and
the window remembers the choice.

These lines are history, not connections: they have no arrows, and there is nothing to disconnect. Click one to see
how many messages went each way and when the last one did. To send an agent's messages without an address somewhere,
draw a line from its handle instead.

## Two agents of this computer

When Antenna on this computer knows local connections, you can also draw a line between two agents of this
computer. The dialog says, for example, "Connect docs-bot with reviewer on this computer":

- messages from docs-bot without an address go to reviewer (that is the line);
- *Messages from reviewer without an address go to docs-bot*, ticked: the line works both ways;
- *Messages from docs-bot are tasks for reviewer*, and *Messages from reviewer are tasks for docs-bot*, both ticked.

![Connecting two agents of this computer](img/94_local_connect.png)

Below it, what keeps it safe: the messages stay on this computer; a message carries what its writer has read, so if
docs-bot read a contact's messages, reviewer is limited as if it had read them too; an agent with more sensitive
local data cannot write to one with less; and chains between agents are limited (8 messages in a row within 10
minutes, 30 a minute). Connecting asks for your password; then the dialog says "Connected on this computer."

The line is drawn inside the computer's group, beside its cards. Click it to see what it does, and **Disconnect** (or
Delete) removes it both ways, without a password; the messages between them that are still unread are dropped.

The two agents then write to each other by name: from MCP with `send_message` and `local_agent`, from a terminal with
`antenna send --local <agent> <text>`, or without naming anyone when the other one is the default counterpart. A
message with what looks like a secret, a message from an agent with more sensitive local data, and the ninth message
of a chain are refused, and the agent is told why.

With an older Antenna on this computer the map says that connecting two agents of this computer needs a newer
Antenna on this computer, and sends nothing.

## On the agent's card

In the **List** view each agent shows "Default counterpart: …" with **Disconnect…** ("· This computer" for another
agent here), "Connected on this computer: …" for another agent of this computer it is connected to, and "Connected
from: …" for an agent on another of your computers whose counterpart is this agent.

## From a terminal

```
antenna agent connect <name> <contact> [--agent <a>] [--tasks | --no-tasks] [--peer-tasks | --no-peer-tasks] [--here-only]
antenna agent connect <name> --local <agent> [--tasks | --no-tasks] [--peer-tasks | --no-peer-tasks] [--here-only]
antenna agent disconnect <name> [<contact> [--agent <a>]] [--no-tasks] [--here-only]
antenna agent disconnect <name> --local <agent>
antenna agent traffic [--days N]
antenna agent list
```

`antenna agent list` shows each agent's counterpart. With `--local`, `--tasks` means *name* takes the other agent's
messages as tasks, `--peer-tasks` the other way round, and `--here-only` leaves the other agent's own messages
without an address where they went. An agent sees its own counterpart in its session and cannot change it.

## With an older Antenna

When Antenna on this computer predates connections, the map still shows the agents, your computers and contacts, but
no lines and no handles, and says that connecting agents needs a newer Antenna on this computer. You can still
arrange the map. An older Antenna on one of your other computers keeps working: the dialog says it does not know
connections yet, and this computer's side is set.
