<!-- SPDX-License-Identifier: Apache-2.0 -->
# Connecting AI apps

Antenna is a bridge between the AI apps people already use, from different companies, inside their own
subscriptions: ChatGPT, Codex, Claude, Gemini, Cursor and others talk to each other and to people through Antenna,
with no API keys. Each app runs Antenna's MCP server, `antenna mcp`, as a local STDIO server; the daemon decides what
the app's agent may do by the trust level of each contact (SPEC §9).

This page lists, for every app the window knows, what the vendor's documentation says today (checked 2026-10-03) and
what Agents → **AI apps** does with it. Decisions: DECISIONS D-85…D-89, D-UI-17. User steps: USER-GUIDE "Connecting AI
apps".

## How every connection works

1. **One agent per app.** Connect creates the app's agent (`chatgpt`, `claude-desktop`, `cursor`…) with the owner
   password, so each app has its own token, permissions and status. An existing agent of that name gets a new token
   instead (`agent_token`).
2. **A token file, never the token.** The daemon writes the token to `<data-dir>/agents/<agent>.token` (0600, folder
   0700) and the app's configuration names that file: `antenna mcp --token-file <path>`. App settings get synced,
   shared and pasted into chats; a path is useless to anyone else. A token file is also the only form that works in
   every app: several apps start MCP servers with a filtered environment (Gemini CLI drops every `*TOKEN*` variable,
   Codex forwards only variables it is told to, Claude Desktop passes "a limited subset", Copilot CLI only `PATH`). The
   CLI reads the file like ssh reads a key: no symlink, owned by the user, no group or other permissions, at most
   4 KiB (CONTROL §5).
3. **Shown before written.** Connect shows exactly what it will add and where (or which install link it opens) before
   anything changes. A file is backed up next to itself (`<file>.antenna-backup-<time>`, never wider than 0600) and
   only Antenna's entry changes; a file that is not plain JSON (comments, trailing commas) is never rewritten, and the
   window shows the guide instead. If the file changed while the owner was reading, nothing is written and the new
   content is shown first.
4. **Status from the daemon.** "Connected" means the app's MCP server is bound to a running process (the daemon binds
   a token to its first MCP host, D-28); "Waiting for the app" means the token was issued but the app has not called
   yet; "Disconnected" means that process has ended; "Revoked" means the app still names an agent that no longer
   exists. The daemon reports the process and the last call (`agent_list`) and tells the window at once when an app
   binds (the `agent` event, CONTROL §8).
5. **Tasks and data.** Messages from the contacts an agent "takes tasks from" (by default the contacts at trust level
   5) reach it as tasks the owner authorized; everything else is data (D-88). Connect shows the set and lets the owner
   change it.
6. **Disconnect** removes Antenna's entry (after a backup) and revokes the agent, which also deletes its token file.
7. **What to do now.** Connect ends with concrete steps, one at a time. An app that reads its MCP settings only when
   it starts (Claude Desktop, ChatGPT, Devin Desktop) and was found here as a macOS app: when it is open, "Restart
   <app> now" asks it to quit with its own Quit (an Apple Event; the first time macOS asks whether Antenna may control
   it), waits until it has closed and opens it again; when it is not open, "Open <app>"; "I'll restart it myself"
   touches nothing, and nothing happens without the click. A CLI is simply started again; an app connected through its
   install link needs no restart. Then: "In <app>, start a new chat and ask: Check my Antenna messages"; the status
   turns to Connected when the app's server binds the token.

**Finding the apps.** App bundles are looked for in `/Applications` and `~/Applications`; CLIs (`claude`, `codex`,
`gemini`…) where the user's terminal would find them, although a window started from Finder or the Dock has launchd's
short PATH: the window's PATH, the login shell's PATH (read once per window session in the background, with `npm
prefix -g`), then the installers' folders (`~/.local/bin`, `~/.claude/local`, `~/.npm-global/bin` or the `prefix` in
`~/.npmrc`, `~/.bun/bin`, `~/.volta/bin`, `~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`). Only an
executable file counts. The AI apps list looks again when the window comes back to the front, and Start in Code mode
runs exactly the path the list shows.

The server's entry is the same everywhere, in each vendor's shape:

```json
{"command": "/Applications/Antenna.app/Contents/Helpers/antenna",
 "args": ["mcp", "--token-file", "/Users/alice/.local/share/antenna/agents/claude-desktop.token"]}
```

`ANTENNA_SOCKET` is added to `env` only when the window does not use the default socket. The server's name is always
`antenna`: several apps also read other apps' configurations (Grok Build reads `~/.claude.json` and `.cursor/mcp.json`,
Warp reads Claude and Codex files, VS Code can discover several), and one name keeps Antenna from appearing twice.

## The apps

| App | Local STDIO MCP | Configuration | One-click path | Subscription login | macOS / Linux | What the window does | Checked |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **ChatGPT** (desktop app: Chat, Work, Codex) | yes | `~/.codex/config.toml`, shared with Codex | none from OpenAI (no link scheme) | ChatGPT Free, Go, Plus, Pro, Business, Edu, Enterprise | yes / preview | **Connect**: writes the shared TOML table | partly |
| **Codex** by OpenAI (CLI, IDE extension) | yes | `~/.codex/config.toml` | `codex mcp add` | Sign in with ChatGPT (same plans) | yes / yes | **Connect** (same file as ChatGPT) and **Start in Code mode** | yes |
| **Claude Desktop** | yes | macOS `~/Library/Application Support/Claude/claude_desktop_config.json`; Linux `~/.config/Claude/claude_desktop_config.json` | `.mcpb` desktop extension (install dialog in the app) | claude.ai account | yes / beta | **Connect**: writes the JSON file (restart the app) | partly |
| **Claude Code** | yes | `~/.claude.json` (its own state file) | `claude mcp add --scope user` | Claude Pro, Max, Team, Enterprise | yes / yes | **Start in Code mode**; guide with the `claude mcp add` command | yes |
| **Gemini CLI** | yes | `~/.gemini/settings.json` | `gemini mcp add -s user` | Sign in with Google (free tier, Google AI Pro, Ultra) | yes / yes | **Connect**: writes the JSON file | yes |
| **Cursor** | yes | `~/.cursor/mcp.json` | `cursor://anysphere.cursor-deeplink/mcp/install?…` | Cursor account; MCP is listed under the paid plan | yes / yes | **Connect**: opens the install link (writes the file if Cursor is not found) | yes |
| **VS Code** with GitHub Copilot | yes | user `mcp.json` (`servers`); new portable `~/.copilot/mcp-config.json` | `vscode:mcp/install?…`, `code --add-mcp` | Copilot Free, Pro, Pro+, Max; Business/Enterprise need the org policy | yes / yes | **Connect**: opens the install link (writes the user `mcp.json` if VS Code is not found) | yes |
| **Devin Desktop** (formerly Windsurf) | yes | `~/.config/devin/mcp_config.json` | none for Cascade | Pro, Max, Teams | not checked | **Connect**: writes the JSON file | partly |
| **Zed** | yes (tools and prompts) | `~/.config/zed/settings.json`, `context_servers` | none | Zed Pro; ChatGPT Plus/Pro through "Sign in with OpenAI" | yes / yes | **Set up**: guide (the settings file usually has comments) | yes |
| **LM Studio** | yes (0.3.17+) | `~/.lmstudio/mcp.json` | `lmstudio://add_mcp?…` | none: local models | yes / yes | **Connect**: opens the install link (writes the file if LM Studio is not found) | yes |
| **Grok Build** (xAI's CLI) | yes | `~/.grok/config.toml` | `grok mcp add` | browser login; plan requirements not verified | yes / yes | **Connect**: writes the TOML table | partly |

Not in the list: **ChatGPT on the web** and **Grok** on the web and in its apps take only remote MCP servers over
HTTPS (ChatGPT also through OpenAI's Secure MCP Tunnel); they need a public endpoint for each user, which Antenna does
not have yet. **Perplexity** for Mac is reported to run local MCP servers through a helper app, but its help pages
could not be read (403). JetBrains AI Assistant, Goose, Cline and Warp also run local MCP servers (sources below);
Goose's install links accept only `npx`, `uvx`, `jbang`, `goosed` or `docker` as the command, so they cannot start
Antenna's binary.

### ChatGPT (desktop app)

- The new ChatGPT desktop app (Chat, Work and Codex in one app) runs local STDIO servers and shares its MCP settings
  with the Codex CLI and IDE extension: "The ChatGPT desktop app, Codex CLI, and IDE extension support MCP servers and
  share MCP configuration for the same Codex host." Supported: "STDIO servers: Servers that run as a local process
  (started by a command)". [learn.chatgpt.com/docs/extend/mcp](https://learn.chatgpt.com/docs/extend/mcp)
- Menu, verbatim: "Open **Settings**, then select **MCP servers**." "Select **Add server**." "Enter a name, choose
  **STDIO** or **Streamable HTTP**, and provide the server's command or URL." "Save the server, then select
  **Restart**." "In the composer, type `/mcp` to view connected servers." (same page)
- Plans: "ChatGPT Work and Codex are included in your ChatGPT Free, Go, Plus, Pro, Business, Edu, or Enterprise plan"
  ([pricing](https://learn.chatgpt.com/docs/pricing)); sign-in "with ChatGPT for subscription access"
  ([auth](https://learn.chatgpt.com/docs/auth)).
- Platforms: "Download ChatGPT for macOS, Windows, or Linux" ([app](https://learn.chatgpt.com/docs/app)); Linux is a
  preview (reported on the community forum, not by OpenAI staff).
- No install link exists; the alternatives are `codex mcp add`, the file, or a local plugin marketplace
  ([plugins](https://developers.openai.com/plugins/build/plugins)). The window writes the file.
- **Not verified:** whether the Chat and Work modes (not only Codex) use servers from `config.toml`. The guide says to
  check with `/mcp`.

### Codex

- File and format: `~/.codex/config.toml`, one `[mcp_servers.<name>]` table per server; STDIO keys `command`, `args`,
  `env`, `env_vars`, `cwd`; "`env_vars`: Additional environment variables to whitelist for an MCP stdio server"
  ([config reference](https://learn.chatgpt.com/docs/config-file/config-reference)). Example from OpenAI:

  ```toml
  [mcp_servers.context7]
  command = "npx"
  args = ["-y", "@upstash/context7-mcp"]
  ```

- CLI: `codex mcp add <server-name> --env VAR1=VALUE1 -- <stdio server-command>`; IDE extension: "Open the gear menu,
  then select MCP servers. Select Add server. … Save the server, then select Restart extension."
- Schema: `https://developers.openai.com/codex/config-schema.json` (redirects to
  `https://learn.chatgpt.com/docs/config-schema.json`); our generated file is validated against its `model` and `mcp_servers` parts in
  `apps/antenna_desktop/test/host/mcp_config_test.dart`.
- The window edits only the lines of `[mcp_servers.antenna]` (and its sub-tables); every other line stays byte for
  byte. If Antenna's server is defined some other way (dotted keys, an inline table), it does not guess and shows the
  guide.
- Code mode keeps passing its own token on the command line (`-c mcp_servers.antenna.*`, D-83), which overrides the
  file's entry for that session.
- One token binds to one MCP host at a time (D-28): the ChatGPT app and a Codex CLI session that run at the same time
  share the file's agent, and the second one is refused until the first ends. Code mode is not affected (its own
  agent).

### Claude Desktop

- Config file: macOS `~/Library/Application Support/Claude/claude_desktop_config.json`, Windows
  `%APPDATA%\Claude\claude_desktop_config.json`
  ([modelcontextprotocol.io](https://modelcontextprotocol.io/docs/develop/connect-local-servers)); Linux
  `~/.config/Claude/claude_desktop_config.json` according to VS Code's discovery table
  ([code.visualstudio.com](https://code.visualstudio.com/docs/copilot/reference/mcp-configuration)); Anthropic's Linux
  page does not state it. Top-level `mcpServers`, entries with `command`, `args`, `env`.
- Menu: "Click on the Claude menu in your system's menu bar … and select 'Settings…'", the "Developer" tab, "Edit
  Config"; after editing, "completely quit Claude Desktop and restart it"; check under "Add files, connectors, and
  more /" → "Connectors" → "Manage connectors" (same page).
- MCP servers "inherit only a limited subset of environment variables", and "the working directory … may be undefined
  (like / on macOS)" ([debugging](https://modelcontextprotocol.io/legacy/tools/debugging)): absolute paths and a token
  file are required.
- Desktop extensions (`.mcpb`, formerly `.dxt`) install with a dialog in the app: "Double-click the .mcpb file", drag it
  into the window, or "Settings > Extensions > Advanced settings > Install Extension…"
  ([claude.com](https://claude.com/docs/connectors/building/mcpb),
  [support](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop));
  manifest spec and schemas in [modelcontextprotocol/mcpb](https://github.com/modelcontextprotocol/mcpb). The
  reference loader passes `command` through unchanged, so an absolute path outside the bundle is not forbidden by the
  spec, but **this is not verified in Claude Desktop itself**; the window writes the documented file for now.
- Linux: an official beta for Ubuntu 22.04+ and Debian 12+
  ([code.claude.com](https://code.claude.com/docs/en/desktop-linux)). Plans: all claude.ai plans
  ([download](https://claude.com/download)); **not verified** that local MCP works on the Free plan.

### Claude Code

- `claude mcp add [options] <name> -- <command> [args...]`; "The `--` (double dash) separator is required."; user scope
  (`--scope user`) is stored in `~/.claude.json` ([code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp)).
  The guide gives: `claude mcp add --scope user --transport stdio antenna -- <antenna> mcp --token-file <path>`.
- Login: "Claude Pro or Max subscription: log in with your claude.ai account"
  ([authentication](https://code.claude.com/docs/en/authentication)).
- The window's main path is Code mode (D-83): Claude Code in the window's terminal with Antenna's server and Antenna's
  hooks for that session only. A user-level connection carries no hooks: adding them to `~/.claude/settings.json`
  would apply to every Claude Code session, including those where Antenna's server is not bound, and the hook then
  blocks every tool.

### Gemini CLI

- `~/.gemini/settings.json`, top-level `mcpServers`, keys `command`, `args`, `env`, `cwd`, `timeout`, `trust`…
  ([mcp-server.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/mcp-server.md),
  [configuration](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md)); schema
  `https://raw.githubusercontent.com/google-gemini/gemini-cli/main/schemas/settings.schema.json`, against whose `mcpServers` and `ui` parts our
  generated file is validated.
- "By default, the CLI redacts sensitive environment variables from the base environment … `*TOKEN*`, `*SECRET*`,
  `*PASSWORD*`, `*KEY*`, `*AUTH*`, `*CREDENTIAL*`": `ANTENNA_AGENT_TOKEN` would not reach the server; the token file does.
- CLI: `gemini mcp add [options] <name> <commandOrUrl> [args...]`, scope `-s user` (the default is the project);
  arguments that start with `--` go after `--`. Reload: `/mcp reload`.
- Login: "Sign in with Google" for personal accounts, the free tier and Google AI Pro and Ultra
  ([authentication](https://github.com/google-gemini/gemini-cli/blob/main/docs/get-started/authentication.mdx)).

### Cursor

- `~/.cursor/mcp.json`, `mcpServers`; `type` (`"stdio"`), `command` ("Must be available on your system path or contain
  its full path"), `args`, `env`; "For custom servers, update your local files and restart Cursor."
  ([cursor.com/docs/context/mcp](https://cursor.com/docs/context/mcp)).
- Install link: `cursor://anysphere.cursor-deeplink/mcp/install?name=$NAME&config=$BASE64_ENCODED_CONFIG`, "JSON.stringify
  the configuration then base64 encode it"; "Cursor prompts to install the server"
  ([install links](https://cursor.com/docs/context/mcp/install-links)). The whole configuration travels in the link;
  ours carries only the token file's path.
- Plans: the pricing page lists "MCPs, skills, and hooks" under the paid plan ([pricing](https://cursor.com/pricing));
  **not verified** whether the free Hobby plan runs MCP servers.

### VS Code with GitHub Copilot

- User `mcp.json` ("MCP: Open User Configuration"; in the user settings folder, so `~/Library/Application
  Support/Code/User/mcp.json` on macOS and `~/.config/Code/User/mcp.json` on Linux, derived from
  [settings](https://code.visualstudio.com/docs/configure/settings)), top-level `servers`, entries with
  `"type": "stdio"`, `command`, `args`, `env`
  ([reference](https://code.visualstudio.com/docs/copilot/reference/mcp-configuration)). VS Code now prefers the portable
  `~/.copilot/mcp-config.json` and lists the user profile file as a "deprecated destination" kept for compatibility
  ([MCP servers](https://code.visualstudio.com/docs/copilot/customization/mcp-servers)).
- Install link: "`vscode:mcp/install?{json-configuration}`", built as ``vscode:mcp/install?${encodeURIComponent(JSON.stringify(obj))}``
  with the name inside ([extension guide](https://code.visualstudio.com/api/extension-guides/ai/mcp)); CLI
  `code --add-mcp '<json>'`. Non-workspace servers show a trust dialog "when a server first starts".
- Business and Enterprise: the "MCP servers in Copilot" policy "must be enabled" and is "disabled by default"
  ([GitHub docs](https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp/extend-copilot-chat-with-mcp)).
- No public schema URL was found.

### Devin Desktop (formerly Windsurf)

- Windsurf was renamed Devin Desktop on 2026-06-02 (reported by the press; `docs.windsurf.com` redirects to
  `docs.devin.ai`). Cascade's file: `~/.config/devin/mcp_config.json`, `mcpServers`, `command`, `args`, `env`
  ([docs.devin.ai](https://docs.devin.ai/desktop/cascade/mcp)); the Devin CLI uses the same user file since v3000.3
  ([CLI](https://docs.devin.ai/cli/extensibility/mcp/configuration)), while another page still names
  `~/.config/devin/config.json`. The old `~/.codeium/windsurf/mcp_config.json` is outdated.
- "Cascade does not have an MCP Marketplace or one-click install." CLI: `devin mcp add -s user <name> -- <command>`.
- **Not verified:** the platforms and a free plan.

### Zed

- "Settings → AI → MCP Servers … Click **Add Server** … then choose **Add Local Server**"; the entry goes into
  `context_servers` with a flat `command` string ([zed.dev/docs/ai/mcp](https://zed.dev/docs/ai/mcp)). "Zed currently
  supports MCP's Tools and Prompts features."
- Zed's settings file is JSON with comments, so the window does not edit it and shows the guide.
- "ChatGPT Plus and Pro can be used through Zed's ChatGPT Subscription provider"
  ([existing subscription](https://zed.dev/docs/ai/use-an-existing-subscription)).

### LM Studio

- "Starting 0.3.17 (b10), LM Studio supports both local and remote MCP servers"; "LM Studio currently follows Cursor's
  mcp.json notation" ([lmstudio.ai/docs/app/mcp](https://lmstudio.ai/docs/app/mcp)); the file is `~/.lmstudio/mcp.json`,
  loaded when saved ([0.3.17 notes](https://lmstudio.ai/blog/lmstudio-v0.3.17)). An open bug reports a macOS copy at
  `~/.cache/lm-studio/mcp.json` ([issue 1371](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1371)).
- Install link: `lmstudio://add_mcp?name=…&config=<base64>` ([deeplink](https://lmstudio.ai/docs/app/mcp/deeplink)).
- No subscription: the models run on the computer.

### Grok Build (xAI)

- `grok mcp add filesystem -- npx -y @modelcontextprotocol/server-filesystem /path/to/dir` ("everything after -- is the
  server command"); `~/.grok/config.toml` with `[mcp_servers.<name>]` tables; "Grok also loads MCP configurations from
  `~/.claude.json`, `.cursor/mcp.json`, and project `.mcp.json` files, merged below config.toml"
  ([docs.x.ai](https://docs.x.ai/build/features/mcp-servers)). Login: "On first launch, Grok opens a browser for
  authentication" ([overview](https://docs.x.ai/build/overview)); **plan requirements not verified**.
- Grok on the web and in its apps: "Your MCP server must be reachable over the public internet"
  ([connectors](https://docs.x.ai/grok/connectors)).

### Other apps, briefly

- JetBrains AI Assistant: "Settings | Tools | AI Assistant | Model Context Protocol (MCP)", **Add**, JSON with
  `mcpServers` ([jetbrains.com](https://www.jetbrains.com/help/ai-assistant/mcp.html)).
- GitHub Copilot CLI: `~/.copilot/mcp-config.json`; "The PATH variable is automatically inherited from your
  environment. All other environment variables must be configured here."
  ([docs.github.com](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers)).
- Cline: `mcpServers` JSON ([docs.cline.bot](https://docs.cline.bot/mcp/configuring-mcp-servers)); Warp:
  `~/.warp/.mcp.json` and third-party files behind a toggle ([docs.warp.dev](https://docs.warp.dev/agent-platform/capabilities/mcp/)).

## Files from an app's own cloud

`share_file` takes a path on this computer, so an agent whose output lives in its vendor's cloud could not send it.
`share_file_content` (CONTROL §5, D-87) takes the bytes as base64 (25 MiB by default, `antennad
--share-content-max-mib`) and sends them through exactly the same check, policy, approvals and quarantine. The model has
to write the base64 into the tool call itself, so in practice this suits small files; agents on this computer (Codex,
Claude Code, Gemini CLI, Cursor) should keep using a path. Only hosted ChatGPT apps have a documented way to hand a
file to a tool, `_meta["openai/fileParams"]` with a download URL
([reference](https://developers.openai.com/plugins/reference)), and it applies to remote servers; the MCP specification
has no file inputs yet (proposals SEP-2356 and SEP-2631, WATCHLIST W-22).

## Marks

The list shows an app's mark only where its owner's guidelines allow using it to refer to an integration, small, next
to the app's name, with no endorsement implied; elsewhere it shows a neutral monogram tile. The SVG path data comes from
[Simple Icons](https://simpleicons.org) 16.33.0 (CC0-1.0 for the SVG data; "that doesn't mean to imply that all icons
within the project are also CC0" and users should "seek the correct permissions"). Files, sources and licences:
`apps/antenna_desktop/assets/logos/` (`sources.json`, `README.md`). Checked 2026-10-03.

| Brand | Shown | Why | Source |
| --- | --- | --- | --- |
| Claude, Claude Code (Anthropic) | mark (`#D97757`) | Anthropic publishes the marks in its press kit; no third-party usage terms were found | Simple Icons `claude`, `claudecode`; [press kit](https://www.anthropic.com/press-kit) |
| Cursor (Anysphere) | mark (black / white) | The brand page offers the icon in light and dark; no third-party terms were found | Simple Icons `cursor`; [cursor.com/brand](https://cursor.com/brand) |
| Zed (Zed Industries) | mark (brand blue `#1348DC` / white) | "You may not use the Zed name or logos in any way that could mistakenly imply any official connection with or endorsement"; colours only brand blue, white, black | Simple Icons `zedindustries`; [zed.dev/brand](https://zed.dev/brand) |
| LM Studio | mark (black / white) | "Use LM Studio logo when referring to LM Studio"; "Don't imply sponsorship, endorsement, or a formal partnership"; "Do not recolor" | Simple Icons `lmstudio`; [lmstudio.ai/brand](https://lmstudio.ai/brand) |
| OpenAI (ChatGPT, Codex) | monogram | Simple Icons removed the mark in 16.0.0 (2025-11-30) because OpenAI's terms grant a non-transferable licence; openai.com/brand could not be read (403) | [openai.com/brand](https://openai.com/brand/) |
| Google Gemini | monogram | Product icons are "Ask first": permission through the Partner Marketing Hub | [Google brand guidance](https://about.google/brand-resource-center/guidance/) |
| VS Code, GitHub Copilot | monogram | VS Code: "Not OK — Using the icon to identify or promote your own product"; Copilot has had no standalone logo since 2025 | [code.visualstudio.com/brand](https://code.visualstudio.com/brand), [github.com/logos](https://github.com/logos) |
| Devin Desktop (Windsurf) | monogram | "For any use not explicitly covered, please contact us with a visual mockup"; no Devin mark in Simple Icons | [windsurf.com/brand](https://windsurf.com/brand) |
| xAI (Grok) | monogram | No mark in Simple Icons; "Use our Marks only to accurately refer to us", logos "exactly as provided" | [x.ai brand guidelines](https://x.ai/legal/brand-guidelines) |

An agent's avatar uses the mark of the app it was connected for, or of the CLI the window started it with in Code
mode; nothing is guessed from a name. A contact's agent always gets the neutral agent mark with its name: the contact
chooses that name, so it proves nothing (DECISIONS D-UI-18).

## What still needs a real Mac

- Every connection end to end with the real app: ChatGPT (and whether Chat and Work modes use the server), Claude
  Desktop (the GUI host binding, D-P-3, when the app starts the server from a helper process), Cursor's and LM Studio's
  install links, VS Code's link and trust dialog, Gemini CLI, Devin Desktop, Zed, Grok Build.
- Whether an app starts one MCP server per window: the second one is refused while the first runs (one host per
  token, D-28).
- Claude Desktop with a `.mcpb` bundle whose command is the absolute path of the bundled `antenna`.
- "Restart <app> now" with the real apps: the Automation prompt (Antenna's `NSAppleEventsUsageDescription`), the
  quit of Claude Desktop, ChatGPT and Devin Desktop (an app that asks before quitting), and `open -a` afterwards.
- Detection of the CLIs from a window started from the Dock: Claude Code's native install (`~/.local/bin/claude`), an
  npm install under nvm (found through the login shell), Homebrew.

## Changes in the MCP specification

The current MCP specification revision is 2026-07-28: stateless, no `initialize`, a mandatory `server/discover`, a
`resultType` on every result ([changelog](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2026-07-28/changelog.mdx)).
Antenna's server (rmcp) answers the `initialize` handshake that today's clients use (the live tests speak protocol
version 2025-06-18); whether it also answers `server/discover`, for clients that move to the new revision without a
fallback, is tracked in WATCHLIST W-10.
