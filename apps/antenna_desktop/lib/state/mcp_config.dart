// SPDX-License-Identifier: AGPL-3.0-only
// Editing an AI app's MCP configuration: add, find and remove Antenna's server entry, leaving every other entry as it
// was. Pure Dart (docs/CONNECT-APPS.md).
//
// - JSON files (Claude Desktop, Cursor, Gemini CLI, VS Code, Windsurf, LM Studio): the entry goes under the app's key
//   (`mcpServers`, or `servers` for VS Code). The file is parsed strictly; a file that is not plain JSON (comments,
//   trailing commas) is never rewritten: the window falls back to the step-by-step guide, so nothing of the owner's is
//   lost. Other entries keep their content and order; the whitespace becomes the window's two-space indent.
// - TOML (Codex `config.toml`): only the lines of Antenna's own table (`[mcp_servers.antenna]` and its sub-tables) are
//   replaced or removed; every other line stays byte for byte. If Antenna's server is defined some other way (dotted
//   keys or an inline table), the window does not guess: it falls back to the guide.
//
// What the entry holds: the absolute path of the `antenna` CLI and `mcp --token-file <path>`. The token itself is never
// in an app's configuration: app configs get synced, shared and pasted into chats, a path leaks nothing useful.

import 'dart:convert';

/// The name of Antenna's server in every app's configuration.
const mcpServerName = 'antenna';

/// The MCP server as the app should start it.
final class McpServer {
  const McpServer({required this.command, required this.args, this.env = const {}});

  /// The `antenna` CLI's absolute path (from the app bundle; a GUI app's PATH may not have it).
  final String command;
  final List<String> args;

  /// Only non-secret variables (`ANTENNA_SOCKET` when the window uses another socket).
  final Map<String, String> env;

  /// `antenna mcp --token-file <file>`.
  factory McpServer.antenna({required String cli, required String tokenFile, String? socket}) => McpServer(
        command: cli,
        args: ['mcp', '--token-file', tokenFile],
        env: {'ANTENNA_SOCKET': ?socket},
      );

  /// The agent whose token file this entry names (`…/agents/<name>.token`), or `null`.
  static String? agentOfArgs(List<String> args) {
    final i = args.indexOf('--token-file');
    final path = i >= 0 && i + 1 < args.length
        ? args[i + 1]
        : args.where((a) => a.startsWith('--token-file=')).map((a) => a.substring('--token-file='.length)).firstOrNull;
    if (path == null) return null;
    final base = path.split('/').last;
    return base.endsWith('.token') && base.length > '.token'.length ? base.substring(0, base.length - 6) : null;
  }
}

/// The JSON shape of one server entry.
enum JsonEntryStyle {
  /// `{"command", "args", "env"}`: Claude Desktop, Cursor, Gemini CLI, Windsurf, LM Studio.
  plain,

  /// `{"type": "stdio", "command", "args", "env"}`: VS Code (`servers`).
  typed,
}

Map<String, Object?> jsonEntry(McpServer s, JsonEntryStyle style) => {
      if (style == JsonEntryStyle.typed) 'type': 'stdio',
      'command': s.command,
      'args': s.args,
      if (s.env.isNotEmpty) 'env': s.env,
    };

/// The file cannot be edited safely (not plain JSON, or the key holds something unexpected): show the guide instead.
final class ConfigNotEditable implements Exception {
  const ConfigNotEditable(this.reason);
  final String reason;

  @override
  String toString() => 'ConfigNotEditable($reason)';
}

const _indent = JsonEncoder.withIndent('  ');

Map<String, Object?> _parseObject(String? text) {
  if (text == null || text.trim().isEmpty) return {};
  final Object? v;
  try {
    v = jsonDecode(text);
  } on FormatException catch (e) {
    throw ConfigNotEditable('not plain JSON: ${e.message}');
  }
  if (v is! Map<String, Object?>) throw const ConfigNotEditable('the file is not a JSON object');
  return v;
}

Map<String, Object?> _section(Map<String, Object?> root, String key, {required bool create}) {
  final v = root[key];
  if (v == null) {
    if (!create) return {};
    final m = <String, Object?>{};
    root[key] = m;
    return m;
  }
  if (v is Map<String, Object?>) return v;
  throw ConfigNotEditable('"$key" is not an object');
}

/// [text] (the file's content, `null`: no file) with Antenna's entry set under [key]; other entries untouched.
String jsonWithServer(String? text, {required String key, required Map<String, Object?> entry, String name = mcpServerName}) {
  final root = _parseObject(text);
  _section(root, key, create: true)[name] = entry;
  return '${_indent.convert(root)}\n';
}

/// [text] without Antenna's entry (`null`: there was none, nothing to write). An emptied section stays as `{}`.
String? jsonWithoutServer(String text, {required String key, String name = mcpServerName}) {
  final root = _parseObject(text);
  final s = _section(root, key, create: false);
  if (!s.containsKey(name)) return null;
  s.remove(name);
  return '${_indent.convert(root)}\n';
}

/// Antenna's entry in [text], if any (`null` also for an unreadable file).
Map<String, Object?>? jsonServer(String? text, {required String key, String name = mcpServerName}) {
  try {
    final e = _section(_parseObject(text), key, create: false)[name];
    return e is Map<String, Object?> ? e : null;
  } on ConfigNotEditable {
    return null;
  }
}

/// The agent an app's JSON entry is connected as (its token file), or `null`.
String? agentOfJsonEntry(Map<String, Object?>? e) {
  final args = e?['args'];
  return args is List ? McpServer.agentOfArgs([for (final a in args) '$a']) : null;
}

/// An entry written before token files existed: the token sits in the config's `env` (preview.3 snippets).
bool jsonEntryHoldsToken(Map<String, Object?>? e) {
  final env = e?['env'];
  return env is Map && env.containsKey('ANTENNA_AGENT_TOKEN');
}

// TOML (Codex).

final _tableHeader = RegExp(r'^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$');

String _tomlKeyPath(String raw) => raw.split('.').map((p) => p.trim().replaceAll('"', '').replaceAll("'", '')).join('.');

/// Lines [start, end) of Antenna's table and its sub-tables in a Codex config, or `null`.
(int, int)? _tomlBlock(List<String> lines, String name) {
  final own = 'mcp_servers.$name';
  int? start;
  for (var i = 0; i < lines.length; i++) {
    final m = _tableHeader.firstMatch(lines[i]);
    if (m == null) continue;
    final path = _tomlKeyPath(m.group(1)!);
    final ours = path == own || path.startsWith('$own.');
    if (start == null && ours) {
      start = i;
    } else if (start != null && !ours) {
      return (_withLeadingComment(lines, start), i);
    }
  }
  return start == null ? null : (_withLeadingComment(lines, start), lines.length);
}

/// The comment line Antenna writes right above its table belongs to the block.
int _withLeadingComment(List<String> lines, int start) =>
    start > 0 && lines[start - 1].trim() == _tomlComment ? start - 1 : start;

const _tomlComment = '# Antenna (added by the Antenna window; "Disconnect" there removes it)';

/// Antenna's server defined as dotted keys (`mcp_servers.antenna.command = …`) or an inline table (`antenna = {…}`
/// under `[mcp_servers]`): the window does not edit such a file.
bool _tomlDefinedElsewhere(List<String> lines, String name) {
  String table = '';
  for (final l in lines) {
    final m = _tableHeader.firstMatch(l);
    if (m != null) {
      table = _tomlKeyPath(m.group(1)!);
      continue;
    }
    final t = l.trimLeft();
    if (t.startsWith('#') || !t.contains('=')) continue;
    final key = _tomlKeyPath(t.substring(0, t.indexOf('=')));
    final full = table.isEmpty ? key : '$table.$key';
    if (full == 'mcp_servers.$name' || full.startsWith('mcp_servers.$name.')) {
      if (table != 'mcp_servers.$name' && !table.startsWith('mcp_servers.$name.')) return true;
    }
  }
  return false;
}

String _tomlString(String s) => jsonEncode(s); // A JSON string is a valid TOML basic string for these paths.

/// Antenna's table for Codex.
String tomlTable(McpServer s, {String name = mcpServerName}) {
  final b = StringBuffer()
    ..writeln(_tomlComment)
    ..writeln('[mcp_servers.$name]')
    ..writeln('command = ${_tomlString(s.command)}')
    ..writeln('args = [${s.args.map(_tomlString).join(', ')}]');
  if (s.env.isNotEmpty) {
    b.writeln('env = { ${s.env.entries.map((e) => '${e.key} = ${_tomlString(e.value)}').join(', ')} }');
  }
  return b.toString();
}

/// [text] with Antenna's table replaced (or appended at the end); every other line stays as it was.
String tomlWithServer(String? text, McpServer s, {String name = mcpServerName}) {
  final lines = (text ?? '').split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (_tomlDefinedElsewhere(lines, name)) throw const ConfigNotEditable('the antenna server is defined in another form');
  final table = tomlTable(s, name: name).trimRight().split('\n');
  final block = _tomlBlock(lines, name);
  if (block != null) {
    final (a, b) = block;
    final keepBlank = b < lines.length ? [''] : <String>[];
    lines.replaceRange(a, b, [...table, ...keepBlank]);
  } else {
    if (lines.isNotEmpty && lines.last.trim().isNotEmpty) lines.add('');
    lines.addAll(table);
  }
  return '${lines.join('\n')}\n';
}

/// [text] without Antenna's table (`null`: there was none).
String? tomlWithoutServer(String text, {String name = mcpServerName}) {
  final lines = text.split('\n');
  final block = _tomlBlock(lines, name);
  if (block == null) return null;
  var (a, b) = block;
  // Drop one blank line the table was separated by, so repeated connect/disconnect does not grow the file.
  if (a > 0 && lines[a - 1].trim().isEmpty) a--;
  lines.removeRange(a, b);
  final out = lines.join('\n');
  return out.trim().isEmpty ? '' : (out.endsWith('\n') ? out : '$out\n');
}

/// The `args` of Antenna's table in a Codex config, or `null`.
List<String>? tomlServerArgs(String? text, {String name = mcpServerName}) {
  if (text == null) return null;
  final lines = text.split('\n');
  final block = _tomlBlock(lines, name);
  if (block == null) return null;
  for (final l in lines.sublist(block.$1, block.$2)) {
    final t = l.trim();
    if (!t.startsWith('args')) continue;
    final eq = t.indexOf('=');
    if (eq < 0) continue;
    try {
      final v = jsonDecode(t.substring(eq + 1).trim());
      if (v is List) return [for (final a in v) '$a'];
    } on FormatException {
      return const [];
    }
  }
  return const [];
}

/// Whether Antenna's Codex table carries the token itself (a preview.3 snippet).
bool tomlServerHoldsToken(String? text, {String name = mcpServerName}) {
  if (text == null) return false;
  final lines = text.split('\n');
  final block = _tomlBlock(lines, name);
  if (block == null) return false;
  return lines.sublist(block.$1, block.$2).any((l) => l.contains('ANTENNA_AGENT_TOKEN') && !l.contains('env_vars'));
}
