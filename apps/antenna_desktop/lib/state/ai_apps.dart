// SPDX-License-Identifier: AGPL-3.0-only
// "AI apps": the AI apps people already use with their own subscription, and how each one gets Antenna's MCP server.
// The facts per app (where its configuration lives, its format, its one-click install path) are in
// docs/CONNECT-APPS.md with sources, checked 2026-10-03; this file follows that document. Pure Dart, except the
// default file checks.
//
// Every route ends in the same thing: the app starts `<antenna> mcp --token-file <data-dir>/agents/<agent>.token`
// itself, as a local STDIO MCP server. The token file is written by the daemon in the owner flow (`agent_add` /
// `agent_token` with `token_file`); the app's configuration (or install link) holds only its path. A token file is
// also the only form that works everywhere: several apps start MCP servers with a filtered environment (Gemini CLI
// drops every `*TOKEN*` variable, Codex forwards only listed ones, Claude Desktop a "limited subset").

import 'dart:convert';
import 'dart:io';

import '../host/program_locator.dart';
import 'agent_launch.dart' show AgentCli;
import 'cli_installer.dart' show VendorInstall;
import 'mcp_config.dart';

/// The apps the window knows, in the order the Agents section lists them.
enum AiApp {
  chatgpt,
  codex,
  claudeDesktop,
  claudeCode,
  geminiCli,
  cursor,
  vscode,
  windsurf,
  zed,
  lmStudio,
  grok,
}

/// How "Connect" reaches the app.
enum ConnectRoute {
  /// The window writes the app's MCP configuration file, after showing exactly what and where.
  configFile,

  /// The window opens the app's own install link; the app shows what it adds and asks the owner to confirm. When the
  /// app is not found here, the window writes its file instead (the link would have nothing to open).
  link,

  /// No one-click path: the step-by-step guide.
  guide,
}

enum ConfigFormat { json, toml }

/// Where an app's file is looked up on Windows: the environment (`APPDATA`, `LOCALAPPDATA`) and whether a folder
/// exists (an MSIX package's).
typedef WindowsPlace = ({Map<String, String> env, bool Function(String path) dirExists});

/// The Windows place of this computer.
WindowsPlace windowsPlace(Map<String, String> env) => (env: env, dirExists: (p) => Directory(p).existsSync());

/// Claude Desktop's file on Windows (WP-17). Its MSIX install reads its settings inside its package (the app's writes
/// to `%APPDATA%` are redirected there), so when that package is installed the file it reads is
/// `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\…`; otherwise `%APPDATA%\Claude\…`.
String? claudeDesktopOnWindows(WindowsPlace w) {
  final local = w.env['LOCALAPPDATA'];
  if (local != null && local.isNotEmpty) {
    final package = '$local\\Packages\\Claude_pzs8sxrjxfjjc';
    if (w.dirExists(package)) return '$package\\LocalCache\\Roaming\\Claude\\claude_desktop_config.json';
  }
  final roaming = w.env['APPDATA'];
  return roaming != null && roaming.isNotEmpty ? '$roaming\\Claude\\claude_desktop_config.json' : null;
}

/// An app's MCP configuration file.
final class AppConfigSpec {
  const AppConfigSpec({
    required this.macos,
    required this.linux,
    this.windows,
    this.format = ConfigFormat.json,
    this.key = 'mcpServers',
    this.style = JsonEntryStyle.plain,
    this.restart = true,
  });

  /// The path under the home folder on macOS and on Linux (`null`: no such file there).
  final String? macos;
  final String? linux;

  /// The file on Windows, found in that computer's place; `null` (the field, or its answer): Connect writes nothing
  /// there and shows the manual steps. Only paths checked on a Windows PC are given (D-134 item 9, WP-17).
  final String? Function(WindowsPlace)? windows;
  final ConfigFormat format;

  /// The JSON object that holds the servers.
  final String key;
  final JsonEntryStyle style;

  /// The app reads the file when it starts: an open app must be restarted.
  final bool restart;

  /// The file's path: on Windows ([windows] given) from [AppConfigSpec.windows], never under a home folder (Windows
  /// has no `HOME`, and the Linux path would land at the drive's root); elsewhere under [home].
  String? pathFor(String home, {required bool macos, WindowsPlace? windows}) {
    if (windows != null) return this.windows?.call(windows);
    return switch (macos ? this.macos : linux) {
      final String p => '$home/$p',
      null => null,
    };
  }
}

/// What the window knows about one app.
final class AiAppDef {
  const AiAppDef(
    this.id, {
    required this.name,
    required this.agent,
    this.terminal,
    this.macApps = const [],
    this.binaries = const [],
    this.linuxFiles = const [],
    this.config,
    this.route = ConnectRoute.guide,
    this.link,
    this.onMac = true,
    this.onLinux = true,
    this.sharesWith,
    this.installUrl,
    this.install,
  });

  final AiApp id;

  /// The name as people know it.
  final String name;

  /// The agent the window creates for this app: one agent per app (per configuration file), so each has its own
  /// token, permissions and status.
  final String agent;

  /// The CLI Code mode starts in the window's terminal (`null`: not a terminal agent the window can start).
  final AgentCli? terminal;

  /// Where the app is installed: macOS app bundles (`/Applications/…` or `~/Applications/…`), CLI names looked up in
  /// PATH and the usual install folders, other files on Linux.
  final List<String> macApps;
  final List<String> binaries;
  final List<String> linuxFiles;

  final AppConfigSpec? config;
  final ConnectRoute route;

  /// The app's install link for [route] `link`.
  final String Function(McpServer server)? link;
  final bool onMac;
  final bool onLinux;

  /// Another app that reads the same configuration file (ChatGPT and Codex share `~/.codex/config.toml`):
  /// connecting one connects both.
  final AiApp? sharesWith;

  /// The vendor's page that installs its command-line program (the Check panel's "Install guide"; checked
  /// 2026-10-05). `null`: no command-line program to install.
  final String? installUrl;

  /// The vendor's own install command for its command-line program (the Check panel's "Install `app`", run in a
  /// terminal in the window after the owner saw it and pressed Run, D-110). `null`: the guide only.
  final VendorInstall? install;

  bool availableOn({required bool macos}) => macos ? onMac : onLinux;
}

String _b64(Object json) => Uri.encodeComponent(base64.encode(utf8.encode(jsonEncode(json))));

/// Cursor: `cursor://anysphere.cursor-deeplink/mcp/install?name=…&config=<base64 of the entry without its name>`
/// (cursor.com/docs/context/mcp/install-links). Cursor shows the server and asks to install it.
String cursorLink(McpServer s) =>
    'cursor://anysphere.cursor-deeplink/mcp/install?name=$mcpServerName&config=${_b64(jsonEntry(s, JsonEntryStyle.typed))}';

/// VS Code: `vscode:mcp/install?<URL-encoded JSON with the name>` (code.visualstudio.com/api/extension-guides/ai/mcp).
String vscodeLink(McpServer s) =>
    'vscode:mcp/install?${Uri.encodeComponent(jsonEncode({'name': mcpServerName, ...jsonEntry(s, JsonEntryStyle.typed)}))}';

/// LM Studio: `lmstudio://add_mcp?name=…&config=<base64 of the entry>` (lmstudio.ai/docs/app/mcp/deeplink).
String lmStudioLink(McpServer s) =>
    'lmstudio://add_mcp?name=$mcpServerName&config=${_b64(jsonEntry(s, JsonEntryStyle.plain))}';

const _codexConfig = AppConfigSpec(macos: '.codex/config.toml', linux: '.codex/config.toml', format: ConfigFormat.toml);

/// The catalog (docs/CONNECT-APPS.md has the sources and what is verified).
const aiApps = <AiAppDef>[
  // The ChatGPT desktop app (Chat, Work, Codex) and the Codex CLI and IDE extension share one MCP configuration.
  AiAppDef(
    AiApp.chatgpt,
    name: 'ChatGPT',
    agent: 'chatgpt',
    macApps: ['ChatGPT.app'],
    binaries: ['chatgpt'],
    config: _codexConfig,
    route: ConnectRoute.configFile,
    sharesWith: AiApp.codex,
  ),
  AiAppDef(
    AiApp.codex,
    name: 'Codex',
    agent: 'chatgpt',
    terminal: AgentCli.codex,
    binaries: ['codex'],
    installUrl: 'https://learn.chatgpt.com/docs/codex/cli',
    install: VendorInstall('curl -fsSL https://chatgpt.com/codex/install.sh | sh',
        source: 'https://learn.chatgpt.com/docs/codex/cli', checked: '2026-10-06'),
    config: _codexConfig,
    route: ConnectRoute.configFile,
    sharesWith: AiApp.chatgpt,
  ),
  AiAppDef(
    AiApp.claudeDesktop,
    name: 'Claude Desktop',
    agent: 'claude-desktop',
    macApps: ['Claude.app'],
    binaries: ['claude-desktop'],
    linuxFiles: ['/usr/bin/claude-desktop', '/opt/Claude/claude-desktop'],
    config: AppConfigSpec(
      macos: 'Library/Application Support/Claude/claude_desktop_config.json',
      linux: '.config/Claude/claude_desktop_config.json',
      windows: claudeDesktopOnWindows,
    ),
    route: ConnectRoute.configFile,
  ),
  // Claude Code runs in the window's terminal (Code mode, with Antenna's hooks for that session); its own user
  // configuration (`~/.claude.json`) is its internal state file, edited through `claude mcp add` (the guide).
  AiAppDef(
    AiApp.claudeCode,
    name: 'Claude Code',
    agent: 'claude-code',
    terminal: AgentCli.claude,
    binaries: ['claude'],
    installUrl: 'https://code.claude.com/docs/en/setup',
    install: VendorInstall('curl -fsSL https://claude.ai/install.sh | bash',
        source: 'https://code.claude.com/docs/en/setup', checked: '2026-10-06'),
  ),
  AiAppDef(
    AiApp.geminiCli,
    name: 'Gemini CLI',
    agent: 'gemini-cli',
    binaries: ['gemini'],
    installUrl: 'https://github.com/google-gemini/gemini-cli',
    // The README's npm line (Node.js on the PATH of the login shell); Homebrew is its other option.
    install: VendorInstall('npm install -g @google/gemini-cli',
        source: 'https://github.com/google-gemini/gemini-cli', checked: '2026-10-06'),
    config: AppConfigSpec(macos: '.gemini/settings.json', linux: '.gemini/settings.json'),
    route: ConnectRoute.configFile,
  ),
  AiAppDef(
    AiApp.cursor,
    name: 'Cursor',
    agent: 'cursor',
    macApps: ['Cursor.app'],
    binaries: ['cursor'],
    linuxFiles: ['/opt/cursor/cursor', '/usr/share/cursor/cursor'],
    config: AppConfigSpec(macos: '.cursor/mcp.json', linux: '.cursor/mcp.json', style: JsonEntryStyle.typed),
    route: ConnectRoute.link,
    link: cursorLink,
  ),
  AiAppDef(
    AiApp.vscode,
    name: 'VS Code',
    agent: 'vscode',
    macApps: ['Visual Studio Code.app'],
    binaries: ['code'],
    config: AppConfigSpec(
      macos: 'Library/Application Support/Code/User/mcp.json',
      linux: '.config/Code/User/mcp.json',
      key: 'servers',
      style: JsonEntryStyle.typed,
      restart: false,
    ),
    route: ConnectRoute.link,
    link: vscodeLink,
  ),
  // Windsurf was renamed Devin Desktop (2026-06-02); its MCP file moved to ~/.config/devin/mcp_config.json.
  AiAppDef(
    AiApp.windsurf,
    name: 'Devin Desktop',
    agent: 'devin',
    macApps: ['Devin.app', 'Devin Desktop.app', 'Windsurf.app'],
    binaries: ['devin', 'windsurf'],
    config: AppConfigSpec(macos: '.config/devin/mcp_config.json', linux: '.config/devin/mcp_config.json'),
    route: ConnectRoute.configFile,
  ),
  // Zed keeps MCP servers in its settings file, which usually has comments: the guide (Settings → AI → MCP Servers).
  AiAppDef(
    AiApp.zed,
    name: 'Zed',
    agent: 'zed',
    macApps: ['Zed.app'],
    binaries: ['zed', 'zeditor'],
    config: AppConfigSpec(macos: '.config/zed/settings.json', linux: '.config/zed/settings.json', key: 'context_servers'),
  ),
  AiAppDef(
    AiApp.lmStudio,
    name: 'LM Studio',
    agent: 'lm-studio',
    macApps: ['LM Studio.app'],
    binaries: ['lms', 'lm-studio'],
    config: AppConfigSpec(macos: '.lmstudio/mcp.json', linux: '.lmstudio/mcp.json', restart: false),
    route: ConnectRoute.link,
    link: lmStudioLink,
  ),
  // xAI's Grok Build CLI (the Grok apps and grok.com take only remote MCP servers).
  AiAppDef(
    AiApp.grok,
    name: 'Grok Build',
    agent: 'grok',
    binaries: ['grok'],
    installUrl: 'https://docs.x.ai/build/overview',
    install: VendorInstall('curl -fsSL https://x.ai/cli/install.sh | bash',
        source: 'https://docs.x.ai/build/overview', checked: '2026-10-06'),
    config: AppConfigSpec(macos: '.grok/config.toml', linux: '.grok/config.toml', format: ConfigFormat.toml),
    route: ConnectRoute.configFile,
  ),
];

AiAppDef aiAppDef(AiApp id) => aiApps.firstWhere((a) => a.id == id);

/// Where [app] is installed here (a path to show), or `null`. Its CLIs are looked up with [programs], the same
/// locator Code mode starts them from.
String? detectAiApp(
  AiAppDef app,
  ProgramLocator programs, {
  required bool macos,
  bool Function(String path)? fileExists,
  bool Function(String path)? dirExists,
}) {
  final isFile = fileExists ?? (String p) => File(p).existsSync();
  final isDir = dirExists ?? (String p) => Directory(p).existsSync();
  final home = programs.home;
  if (macos) {
    for (final a in app.macApps) {
      for (final p in ['/Applications/$a', if (home.isNotEmpty) '$home/Applications/$a']) {
        if (isDir(p)) return p;
      }
    }
  } else {
    for (final p in app.linuxFiles) {
      if (isFile(p)) return p;
    }
  }
  for (final b in app.binaries) {
    if (programs.locate(b) case final p?) return p;
  }
  return null;
}

/// What "Connect" will do for an app, shown to the owner before anything happens.
sealed class ConnectPlan {
  const ConnectPlan(this.app);
  final AiAppDef app;
}

/// Write [after] to [path] (backing up [before] first when the file exists).
final class WriteConfigPlan extends ConnectPlan {
  const WriteConfigPlan(super.app, {required this.path, required this.before, required this.after, required this.entry});
  final String path;

  /// The file now (`null`: there is no file yet).
  final String? before;
  final String after;

  /// Antenna's entry alone, as it appears in the file (what the owner reads).
  final String entry;

  bool get changes => before != after;
}

/// Open [url]; the app shows the server and asks to confirm.
final class OpenLinkPlan extends ConnectPlan {
  const OpenLinkPlan(super.app, {required this.url, required this.entry});
  final String url;
  final String entry;
}

/// No one-click path for this app (or its file cannot be edited safely): the guide.
final class GuidePlan extends ConnectPlan {
  const GuidePlan(super.app, {this.reason});

  /// Why the window does not edit the file itself (for example: the file has comments).
  final String? reason;
}

/// The plan for connecting [app] as the MCP server [server]. [found]: the app is installed here (an install link
/// needs the app to open it). [read] gives the current text of a file (`null`: none).
ConnectPlan connectPlan(
  AiAppDef app,
  McpServer server, {
  required String home,
  required bool macos,
  required bool found,
  required String? Function(String path) read,
  WindowsPlace? windows,
}) {
  if (app.route == ConnectRoute.link && found && app.link != null) {
    return OpenLinkPlan(app, url: app.link!(server), entry: entryText(app, server));
  }
  final c = app.config;
  final path = c?.pathFor(home, macos: macos, windows: windows);
  if (app.route == ConnectRoute.guide || c == null || path == null) return GuidePlan(app);
  final before = read(path);
  try {
    return WriteConfigPlan(
      app,
      path: path,
      before: before,
      after: switch (c.format) {
        ConfigFormat.json => jsonWithServer(before, key: c.key, entry: jsonEntry(server, c.style)),
        ConfigFormat.toml => tomlWithServer(before, server),
      },
      entry: entryText(app, server),
    );
  } on ConfigNotEditable catch (e) {
    return GuidePlan(app, reason: e.reason);
  }
}

/// Antenna's entry as the app's configuration shows it (for the review step and the guide).
String entryText(AiAppDef app, McpServer server) {
  final c = app.config;
  if (c?.format == ConfigFormat.toml) return tomlTable(server).trimRight();
  final key = c?.key ?? 'mcpServers';
  return const JsonEncoder.withIndent('  ').convert({
    key: {mcpServerName: jsonEntry(server, c?.style ?? JsonEntryStyle.plain)},
  });
}

/// What "Disconnect" will change in the app's file: the new text, or `null` when Antenna's entry is not there (or
/// the file cannot be edited safely; the window then says to remove it by hand).
WriteConfigPlan? disconnectPlan(
  AiAppDef app, {
  required String home,
  required bool macos,
  required String? Function(String path) read,
  WindowsPlace? windows,
}) {
  final c = app.config;
  final path = c?.pathFor(home, macos: macos, windows: windows);
  if (c == null || path == null) return null;
  final before = read(path);
  if (before == null) return null;
  try {
    final after = switch (c.format) {
      ConfigFormat.json => jsonWithoutServer(before, key: c.key),
      ConfigFormat.toml => tomlWithoutServer(before),
    };
    if (after == null) return null;
    return WriteConfigPlan(app, path: path, before: before, after: after, entry: '');
  } on ConfigNotEditable {
    return null;
  }
}

/// The agent an app's configuration connects it as, read from its file: the agent name from the token file, `''` for
/// an entry that holds the token itself (set up by hand before token files), `null` when Antenna is not in the file.
String? configuredAgent(
  AiAppDef app, {
  required String home,
  required bool macos,
  required String? Function(String) read,
  WindowsPlace? windows,
}) {
  final c = app.config;
  final path = c?.pathFor(home, macos: macos, windows: windows);
  if (c == null || path == null) return null;
  final text = read(path);
  if (text == null) return null;
  switch (c.format) {
    case ConfigFormat.json:
      final e = jsonServer(text, key: c.key);
      if (e == null) return null;
      return agentOfJsonEntry(e) ?? '';
    case ConfigFormat.toml:
      final args = tomlServerArgs(text);
      if (args == null) return null;
      return McpServer.agentOfArgs(args) ?? '';
  }
}
