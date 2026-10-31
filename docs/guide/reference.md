<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Reference

## Where things are

- *In the window:* [USER-GUIDE: "Where things are in the window"](../USER-GUIDE.md#where-things-are-in-the-window)
  — every navigation item, Settings section and panel, by its exact English label.
- *On disk:* [USER-GUIDE: "Where things are"](../USER-GUIDE.md#where-things-are) — keys, link folders, logs and
  autostart files, Mac and Linux.

## CLI commands

`antenna --help` and `antenna <command> --help` are the source of truth (owner commands need the owner password or
`antenna login`; an agent token cannot reach them at all — SPEC §9). The protocol they speak: `docs/CONTROL.md`.

| Area | Commands |
| --- | --- |
| Setup and the node | `init`, `unlock`, `lock`, `login`, `status` |
| Pairing and trust | `invite`, `join`, `trust`, `rename`, `revoke`, `contacts` |
| Messages | `send`, `inbox`, `topics`, `history` (`--chat <agent>`, `--person`) |
| Chats per agent | `chats`, `chats new` / `rename` / `notify` / `archive` / `unarchive` |
| Approvals | `approve`, `deny` |
| Agents | `agent add` / `list` / `set` / `revoke`, `mcp`, `connect claude-code` / `codex` (a session as its own agent) |
| The agent map | `agent connect` / `disconnect` (an agent's default counterpart and the other side), `agent traffic` (who talked to whom) |
| Agents that reply on their own | `wake set` / `list` / `off` / `say` / `session` |
| Agent sessions in tmux (servers) | `session start` / `list` / `attach` / `stop` / `wake on` / `wake off` |
| Local models | `local models`, `local install`, `local add`, `local say`, `local history`, `local session`, `local remove` |
| Teams of agents | `team create` / `list` / `show` / `set` / `add-worker` / `stop` / `remove` / `apply` / `log`, `task new` / `list` / `show` / `diff` / `review` / `apply`; for an agent: `team info`, `task …`, `worker spawn` / `stop` |
| My devices | `devices`, `devices approve` / `deny` (a request of another own computer), `devices confirm` / `forget` (its keys), `devices lend on` / `off`, `devices revoke` (a lost computer), `devices dismiss` |
| Profile pictures | `picture` (yours, your agents' and your contacts'), `picture set` / `photo` / `remove` (`--agent <name>` for an agent), `picture save` |
| Keys and recovery | `rotate`, `rekey`, `owner-key list` / `remove` |
| Network | `lan on` / `off` / `lan` |
| Updates | `update`, `update --auto status` / `now` / `later` / `--rollback` |
| Diagnostics | `doctor`, `log <contact>` |

## MCP tools

An assistant's MCP server (`antenna mcp`) offers the same actions as its CLI token allows, minus every owner
command (SPEC §9: absent, not merely refused). `tools/mcp_smoke.py` is a live, reproducible list of what
`tools/list` returns against a running daemon. The team tools (`team_info`, `task_…`, `run_check`, `apply_result`,
`worker_spawn`, `worker_stop`, `capacity`) are listed only for an agent that leads or works in a team
(`docs/CONTROL.md` §25). `send_message` without a contact goes to the agent's default counterpart, which
`get_session` shows as `counterpart` (the owner sets it on the agent map, `docs/CONTROL.md` §30).

## Error codes

Every error the daemon and the CLI return is a typed code, never a bare message to match on
(`antenna_proto::control::code`); the window turns a code into text, and USER-GUIDE's ["If something does not
work"](../USER-GUIDE.md#if-something-does-not-work) lists the ones a person sees most often, with what to do.

## Known gap

The three tables above are written and kept by hand for now; the proposal (the product plan
§4.1) calls for generating them from `antenna --help`, the MCP server's own tool list and the `code` modules, so
they can never drift from the binaries. Not built yet — `tools/guide_check.py` cannot catch a stale command name on
this page the way it catches a stale window label, so double-check against `--help` when one of these changes.
