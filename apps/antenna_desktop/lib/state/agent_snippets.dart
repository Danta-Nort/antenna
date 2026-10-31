// SPDX-License-Identifier: AGPL-3.0-only
// Ready-made snippets for connecting an agent (docs/CONTROL.md §5, "Connecting an agent"). Pure Dart.
// The path to `antenna` is absolute (from the app), so the agent does not need `antenna` in PATH.
// Titles, "where to put it" and notes are in the window's language; the snippet text (commands, JSON, TOML) is not
// translated, except for the human-readable comments in the example script.

import 'dart:convert';

import '../l10n/app_localizations.dart';

/// Local data labels of an agent (Q-15: the owner chooses, there is no default). The label says "how sensitive is
/// what the agent reads bypassing the daemon": anything sent to a contact below this label needs approval (no write
/// down, SPEC §9).
final class DataLabel {
  const DataLabel._(this.level);
  final int level;

  static const all = <DataLabel>[
    DataLabel._(5),
    DataLabel._(4),
    DataLabel._(3),
    DataLabel._(2),
    DataLabel._(1),
    DataLabel._(0),
  ];

  String title(AppLocalizations l) => switch (level) {
        5 => l.dataLabel5Title,
        4 => l.dataLabel4Title,
        3 => l.dataLabel3Title,
        2 => l.dataLabel2Title,
        1 => l.dataLabel1Title,
        _ => l.dataLabel0Title,
      };

  String hint(AppLocalizations l) => switch (level) {
        5 => l.dataLabel5Hint,
        4 => l.dataLabel4Hint,
        3 => l.dataLabel3Hint,
        2 => l.dataLabel2Hint,
        1 => l.dataLabel1Hint,
        _ => l.dataLabel0Hint,
      };
}

/// A snippet: title, where to put it, text.
final class Snippet {
  const Snippet(this.id, this.title, this.where, this.text, {this.note});
  final String id;
  final String title;
  final String where;
  final String text;
  final String? note;
}

const _json = JsonEncoder.withIndent('  ');

/// THE ONLY SWITCH for "MCP on macOS" (docs/DESIGN.md, "MCP on macOS switch"). `true` since the core port was merged
/// (docs/PORTABILITY.md M-3…M-6, DECISIONS D-P-2): on macOS the daemon reads the process chain (`proc_pidinfo`) and
/// binds the `antenna mcp` token to the MCP host, as on Linux. So macOS gets the same tabs and token-less hooks as
/// Linux. `false` brings back the "will work after the core changes" notes, the "Any script" tab and the token in
/// hook commands.
const mcpWorksOnMacos = true;

/// The default snippet tab for this OS.
String defaultSnippetTab({required bool macos}) => macos && !mcpWorksOnMacos ? 'script' : 'claude';

String _sh(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Claude Code hooks (CONTROL §5): before every tool the daemon decides, the harness enforces it; reads of local files
/// raise the session's data label. [prefix] goes before the command (environment variables, if any). Used by the
/// snippet for `~/.claude/settings.json` and by Code mode (`--settings` for one session). [quote]: `false` for a bare
/// command name (Code mode on Windows runs `antenna`, which the agent's Path finds first, in whatever shell runs it).
Map<String, Object?> claudeCodeHooks(String xPath, {String prefix = '', bool quote = true}) => {
      'hooks': {
        'PreToolUse': [
          {
            'matcher': '*',
            'hooks': [
              {'type': 'command', 'command': '$prefix${quote ? _sh(xPath) : xPath} hook claude-code'},
            ],
          },
        ],
        'PostToolUse': [
          {
            'matcher': 'Read|Grep|Glob|NotebookRead',
            'hooks': [
              {'type': 'command', 'command': '$prefix${quote ? _sh(xPath) : xPath} hook claude-code --mark-level 5'},
            ],
          },
        ],
      },
    };

/// Snippets for agent [name]. With [tokenFile] (preview.4: the daemon wrote the token to a file only the owner can
/// read) the snippets name that file (`--token-file`, `ANTENNA_AGENT_TOKEN_FILE`) and never hold the token: configs
/// get synced, shared and pasted into chats. Without it (an older daemon), they carry [token] itself. [xPath] is the
/// absolute path to `antenna`; [socket] is non-null if the socket is not the default; [macos] means the window runs on
/// macOS: while [mcpWorksOnMacos] is `false` there is no process-tree binding there, and the hook needs the token in
/// its environment. [l] is the language of titles and notes.
List<Snippet> agentSnippets(
  AppLocalizations l, {
  required String name,
  required String token,
  required String xPath,
  String? tokenFile,
  String? socket,
  bool macos = false,
  String exampleContact = 'bob',
}) {
  final macosMcpNote = l.snippetMacosMcpNote;
  final byFile = tokenFile != null;
  final env = <String, String>{
    if (byFile) 'ANTENNA_AGENT_TOKEN_FILE': tokenFile else 'ANTENNA_AGENT_TOKEN': token,
    'ANTENNA_SOCKET': ?socket,
  };
  // MCP configs: the token file goes in the arguments, so the entry has no secret and no token variable.
  final mcpArgs = ['mcp', if (byFile) ...['--token-file', tokenFile]];
  final mcpEnv = <String, String>{if (!byFile) 'ANTENNA_AGENT_TOKEN': token, 'ANTENNA_SOCKET': ?socket};
  final envFlags = mcpEnv.entries.map((e) => '--env ${e.key}=${_sh(e.value)}').join(' ');
  final envExports = env.entries.map((e) => 'export ${e.key}=${_sh(e.value)}').join('\n');
  final mcpJson = _json.convert({
    'mcpServers': {
      'antenna': {
        'command': xPath,
        'args': mcpArgs,
        if (mcpEnv.isNotEmpty) 'env': mcpEnv,
      },
    },
  });
  final tokenInHook = macos && !mcpWorksOnMacos;
  final hookPrefix =
      tokenInHook ? env.entries.map((e) => '${e.key}=${_sh(e.value)} ').join() : (socket == null ? '' : 'ANTENNA_SOCKET=${_sh(socket)} ');
  final hooks = _json.convert(claudeCodeHooks(xPath, prefix: hookPrefix));
  final codexEnv = mcpEnv.entries.map((e) => '${e.key} = ${jsonEncode(e.value)}').join(', ');
  return [
    Snippet(
      'claude',
      'Claude Code',
      l.snippetWhereTerminal,
      'claude mcp add antenna --scope user${envFlags.isEmpty ? '' : ' $envFlags'} -- ${_sh(xPath)} mcp'
          '${byFile ? ' --token-file ${_sh(tokenFile)}' : ''}',
      note: macos && !mcpWorksOnMacos ? macosMcpNote : l.snippetClaudeNote,
    ),
    Snippet(
      'mcp_json',
      '.mcp.json',
      l.snippetWhereProjectRoot,
      mcpJson,
      note: macos && !mcpWorksOnMacos ? macosMcpNote : null,
    ),
    Snippet(
      'hooks',
      l.snippetHooksTitle,
      '~/.claude/settings.json',
      hooks,
      note: tokenInHook ? l.snippetHooksTokenNote : l.snippetHooksNote,
    ),
    Snippet(
      'codex',
      'Codex',
      '~/.codex/config.toml',
      '[mcp_servers.antenna]\ncommand = ${jsonEncode(xPath)}\nargs = [${mcpArgs.map(jsonEncode).join(', ')}]\n'
          '${codexEnv.isEmpty ? '' : 'env = { $codexEnv }\n'}',
      note: macos && !mcpWorksOnMacos ? macosMcpNote : l.snippetCodexNote,
    ),
    Snippet(
      'script',
      l.snippetScriptTitle,
      l.snippetWhereBash,
      '''# ${l.snippetScriptHeader(name)}
$envExports
A=${_sh(xPath)}
while true; do
  out=\$("\$A" --json inbox --wait --timeout 60s) || { sleep 5; continue; }
  echo "\$out" | jq -c '.messages[]?' | while read -r m; do
    from=\$(echo "\$m" | jq -r .from)
    text=\$(echo "\$m" | jq -r .text)   # ${l.snippetScriptExternal}
    reply="${l.snippetScriptReply('\${#text}')}"  # ${l.snippetScriptYourProgram}
    "\$A" --json send "\$from" "\$reply" >/dev/null
  done
done''',
      note: l.snippetScriptNote(exampleContact),
    ),
  ];
}
