// SPDX-License-Identifier: AGPL-3.0-only
// What Connect writes into AI apps' configurations (docs/CONNECT-APPS.md): Antenna's entry in each vendor's documented
// shape, other entries untouched, never the token itself, files that are not plain JSON left alone, Codex's TOML
// edited line by line; the install links decode to the same entry. Where a vendor publishes a schema (Codex
// config.toml, Gemini CLI settings.json; copies in test/fixtures/schemas), the generated file is validated against it
// with Python's jsonschema when that is installed.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/program_locator.dart';
import 'package:antenna_desktop/state/ai_apps.dart';
import 'package:antenna_desktop/state/mcp_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _cli = '/Applications/Antenna.app/Contents/Helpers/antenna';
const _file = '/Users/owner/.local/share/antenna/agents/chatgpt.token';
const _server = McpServer(command: _cli, args: ['mcp', '--token-file', _file]);

/// Validate [text] (a file's content as JSON text) against the schema in test/fixtures/schemas; [toml]: parse the
/// text with tomllib first. `out` is the checker's verdict; `skip` says why there is no checker here (then the test
/// says so and passes).
Future<({String? skip, String out})> _validate(String schema, String text, {bool toml = false}) async {
  const script = r'''
import json, sys
try:
    import jsonschema
except ImportError:
    print("SKIP python3 has no jsonschema"); sys.exit(0)
schema = json.load(open(sys.argv[1]))
text = sys.stdin.read()
if sys.argv[2] == "toml":
    try:
        import tomllib
    except ImportError:
        print("SKIP python3 has no tomllib (Python 3.11 or later)"); sys.exit(0)
    data = tomllib.loads(text)
else:
    data = json.loads(text)
cls = jsonschema.validators.validator_for(schema)
errors = sorted(cls(schema).iter_errors(data), key=lambda e: list(e.path))
for e in errors:
    print("ERROR", list(e.path), e.message)
print("OK" if not errors else "FAIL")
''';
  final Process p;
  try {
    p = await Process.start('python3', ['-c', script, 'test/fixtures/schemas/$schema', toml ? 'toml' : 'json']);
  } on ProcessException {
    return (skip: 'python3 is not installed', out: '');
  }
  p.stdin.write(text);
  await p.stdin.close();
  final err = p.stderr.drain<void>();
  final out = (await p.stdout.transform(utf8.decoder).join()).trim();
  final code = await p.exitCode;
  await err;
  return (skip: _noChecker(code, out), out: out);
}

/// Why the schema checker did not run, from its exit code and output, or `null` when it ran. On Windows without
/// Python, `python3` is the Microsoft Store's stub, which exits 9009 and prints nothing on stdout. Any other empty
/// output is a failure of the check, not a skip.
String? _noChecker(int exitCode, String out) {
  if (exitCode == 9009 && out.isEmpty) return 'python3 is the Microsoft Store stub, not Python';
  if (out.startsWith('SKIP ')) return out.substring('SKIP '.length);
  return null;
}

void main() {
  test('JSON: the entry is added under the app\'s key; other servers and settings stay as they were', () {
    const before = '{\n  "theme": "dark",\n  "mcpServers": {\n    "filesystem": {"command": "npx", "args": ["-y", "x"],'
        ' "env": {"API_KEY": "secret"}}\n  },\n  "zzz": 1\n}';
    final after = jsonWithServer(before, key: 'mcpServers', entry: jsonEntry(_server, JsonEntryStyle.plain));
    final j = jsonDecode(after) as Map<String, Object?>;
    expect(j.keys.toList(), ['theme', 'mcpServers', 'zzz'], reason: 'order kept');
    final servers = j['mcpServers']! as Map;
    expect(servers['filesystem'], {
      'command': 'npx',
      'args': ['-y', 'x'],
      'env': {'API_KEY': 'secret'},
    });
    expect(servers['antenna'], {
      'command': _cli,
      'args': ['mcp', '--token-file', _file],
    });
    expect(after, isNot(contains('xat_')));
    // Again: the same text (connecting twice changes nothing).
    expect(jsonWithServer(after, key: 'mcpServers', entry: jsonEntry(_server, JsonEntryStyle.plain)), after);
    // Remove: only Antenna's entry goes.
    final removed = jsonDecode(jsonWithoutServer(after, key: 'mcpServers')!) as Map;
    expect((removed['mcpServers'] as Map).keys, ['filesystem']);
    expect(jsonWithoutServer(jsonWithoutServer(after, key: 'mcpServers')!, key: 'mcpServers'), isNull);
  });

  test('JSON with comments or an odd shape is never rewritten: the guide instead', () {
    const jsonc = '// Zed settings\n{\n  "context_servers": {}\n}';
    expect(() => jsonWithServer(jsonc, key: 'context_servers', entry: const {}), throwsA(isA<ConfigNotEditable>()));
    expect(() => jsonWithServer('[1, 2]', key: 'mcpServers', entry: const {}), throwsA(isA<ConfigNotEditable>()));
    expect(() => jsonWithServer('{"mcpServers": []}', key: 'mcpServers', entry: const {}),
        throwsA(isA<ConfigNotEditable>()));
    expect(jsonServer(jsonc, key: 'context_servers'), isNull);
  });

  test('the agent is read from the token file\'s name; an entry with the token itself is recognized', () {
    expect(McpServer.agentOfArgs(const ['mcp', '--token-file', _file]), 'chatgpt');
    expect(McpServer.agentOfArgs(['mcp', '--token-file=$_file']), 'chatgpt');
    expect(McpServer.agentOfArgs(const ['mcp']), isNull);
    expect(jsonEntryHoldsToken(const {'env': {'ANTENNA_AGENT_TOKEN': 'xat_x'}}), isTrue);
    final app = aiAppDef(AiApp.cursor);
    String? read(String p) => p == '/h/.cursor/mcp.json'
        ? '{"mcpServers": {"antenna": {"command": "antenna", "args": ["mcp"], "env": {"ANTENNA_AGENT_TOKEN": "xat_1"}}}}'
        : null;
    expect(configuredAgent(app, home: '/h', macos: true, read: read), '', reason: 'set up by hand, token in the file');
  });

  test('Codex TOML: Antenna\'s table is appended or replaced; every other line stays byte for byte', () {
    const before = '#:schema https://developers.openai.com/codex/config-schema.json\n'
        'model = "gpt-5.5"\n'
        '\n'
        '[mcp_servers.context7]\n'
        'command = "npx"\n'
        'args = ["-y", "@upstash/context7-mcp"]\n'
        '\n'
        '[mcp_servers.context7.env]\n'
        'MY_ENV_VAR = "MY_ENV_VALUE"\n';
    final once = tomlWithServer(before, _server);
    expect(once, startsWith(before), reason: 'appended after everything else');
    expect(once, contains('[mcp_servers.antenna]\ncommand = "$_cli"\nargs = ["mcp", "--token-file", "$_file"]\n'));
    expect(tomlServerArgs(once), ['mcp', '--token-file', _file]);
    // Reconnect with another file: replaced in place, not duplicated.
    final other = tomlWithServer(once, const McpServer(command: _cli, args: ['mcp', '--token-file', '/x/codex.token']));
    expect('[mcp_servers.antenna]'.allMatches(other).length, 1);
    expect(tomlServerArgs(other), ['mcp', '--token-file', '/x/codex.token']);
    // An old hand-written table with its env sub-table, between two others.
    const old = 'a = 1\n[mcp_servers.antenna]\ncommand = "antenna"\nargs = ["mcp"]\n[mcp_servers.antenna.env]\n'
        'ANTENNA_AGENT_TOKEN = "xat_old"\n[profiles.x]\nmodel = "o"\n';
    expect(tomlServerHoldsToken(old), isTrue);
    final fixed = tomlWithServer(old, _server);
    expect(fixed, isNot(contains('xat_old')));
    expect(fixed, startsWith('a = 1\n'));
    expect(fixed, contains('[profiles.x]\nmodel = "o"\n'));
    // Disconnect: back to the original text.
    expect(tomlWithoutServer(once), before);
    expect(tomlWithoutServer(before), isNull);
    // Defined as dotted keys or an inline table: not edited.
    expect(() => tomlWithServer('[mcp_servers]\nantenna = { command = "x" }\n', _server),
        throwsA(isA<ConfigNotEditable>()));
    expect(() => tomlWithServer('mcp_servers.antenna.command = "x"\n', _server), throwsA(isA<ConfigNotEditable>()));
  });

  test('Codex TOML validates against the published Codex config schema', () async {
    const before = 'model = "gpt-5.5"\n\n[mcp_servers.context7]\ncommand = "npx"\nargs = ["-y", "x"]\n';
    final text = tomlWithServer(before, const McpServer(command: _cli, args: ['mcp', '--token-file', _file], env: {
      'ANTENNA_SOCKET': '/tmp/a.sock',
    }));
    final r = await _validate('codex-config.schema.json', text, toml: true);
    if (r.skip != null) return markTestSkipped(r.skip!);
    expect(r.out, 'OK');
    // Negative control: the schema does reject a wrong entry (arguments as a string).
    final bad = await _validate('codex-config.schema.json', '[mcp_servers.antenna]\ncommand = "x"\nargs = "mcp"\n',
        toml: true);
    expect(bad.out, endsWith('FAIL'));
  });

  test('Gemini CLI settings validate against the published Gemini CLI schema', () async {
    final app = aiAppDef(AiApp.geminiCli);
    final plan = connectPlan(app, _server, home: '/h', macos: false, found: true, read: (_) => '{"ui": {"theme": "Default"}}');
    expect(plan, isA<WriteConfigPlan>());
    final text = (plan as WriteConfigPlan).after;
    expect(plan.path, '/h/.gemini/settings.json');
    final r = await _validate('gemini-settings.schema.json', text);
    if (r.skip != null) return markTestSkipped(r.skip!);
    expect(r.out, 'OK');
    // Negative control: arguments as a string are rejected.
    final bad = await _validate('gemini-settings.schema.json', '{"mcpServers": {"antenna": {"command": "x", "args": "mcp"}}}');
    expect(bad.out, endsWith('FAIL'));
  });

  test('the schema checks skip only when there is no checker; empty output from a real Python fails', () {
    expect(_noChecker(9009, ''), 'python3 is the Microsoft Store stub, not Python');
    expect(_noChecker(0, 'SKIP python3 has no jsonschema'), 'python3 has no jsonschema');
    expect(_noChecker(0, 'SKIP python3 has no tomllib (Python 3.11 or later)'),
        'python3 has no tomllib (Python 3.11 or later)');
    expect(_noChecker(0, 'OK'), isNull);
    expect(_noChecker(0, "ERROR ['mcp_servers'] 'mcp' is not of type 'array'\nFAIL"), isNull);
    // Controls: a Python that crashed (a traceback on stderr, nothing on stdout), and exit code 9009 with output.
    expect(_noChecker(1, ''), isNull);
    expect(_noChecker(9009, 'OK'), isNull);
  });

  test('each app gets its vendor\'s documented shape and path', () {
    String? none(String _) => null;
    WriteConfigPlan plan(AiApp id, {bool macos = true, bool found = false}) =>
        connectPlan(aiAppDef(id), _server, home: '/h', macos: macos, found: found, read: none) as WriteConfigPlan;
    Map<String, Object?> j(WriteConfigPlan p) => jsonDecode(p.after) as Map<String, Object?>;

    // Claude Desktop: claude_desktop_config.json, "mcpServers" → command, args (modelcontextprotocol.io).
    final cd = plan(AiApp.claudeDesktop);
    expect(cd.path, '/h/Library/Application Support/Claude/claude_desktop_config.json');
    expect(j(cd), {
      'mcpServers': {
        'antenna': {'command': _cli, 'args': ['mcp', '--token-file', _file]},
      },
    });
    expect(plan(AiApp.claudeDesktop, macos: false).path, '/h/.config/Claude/claude_desktop_config.json');
    // Cursor (when not installed: its file): ~/.cursor/mcp.json, "mcpServers", type stdio (cursor.com/docs).
    expect(j(plan(AiApp.cursor))['mcpServers'], {
      'antenna': {'type': 'stdio', 'command': _cli, 'args': ['mcp', '--token-file', _file]},
    });
    // VS Code: the user mcp.json, "servers" with type stdio (code.visualstudio.com).
    final vs = plan(AiApp.vscode);
    expect(vs.path, '/h/Library/Application Support/Code/User/mcp.json');
    expect((j(vs)['servers']! as Map)['antenna'], containsPair('type', 'stdio'));
    expect(plan(AiApp.vscode, macos: false).path, '/h/.config/Code/User/mcp.json');
    // Devin Desktop (formerly Windsurf): ~/.config/devin/mcp_config.json (docs.devin.ai).
    expect(plan(AiApp.windsurf).path, '/h/.config/devin/mcp_config.json');
    // LM Studio: ~/.lmstudio/mcp.json, Cursor's notation (lmstudio.ai/docs).
    expect(plan(AiApp.lmStudio).path, '/h/.lmstudio/mcp.json');
    // ChatGPT and Codex: one file, ~/.codex/config.toml (learn.chatgpt.com/docs/extend/mcp); Grok Build: its own.
    expect(plan(AiApp.chatgpt).path, '/h/.codex/config.toml');
    expect(plan(AiApp.codex).path, '/h/.codex/config.toml');
    expect(plan(AiApp.grok).path, '/h/.grok/config.toml');
    // Zed and Claude Code: the guide (Zed's settings file has comments; Claude Code runs in Code mode).
    for (final id in [AiApp.zed, AiApp.claudeCode]) {
      expect(connectPlan(aiAppDef(id), _server, home: '/h', macos: true, found: true, read: none), isA<GuidePlan>());
    }
  });

  test('install links carry the same entry, and only the token file\'s path', () {
    String? none(String _) => null;
    OpenLinkPlan link(AiApp id) =>
        connectPlan(aiAppDef(id), _server, home: '/h', macos: true, found: true, read: none) as OpenLinkPlan;

    final c = Uri.parse(link(AiApp.cursor).url);
    expect('${c.scheme}://${c.host}${c.path}', 'cursor://anysphere.cursor-deeplink/mcp/install');
    expect(c.queryParameters['name'], 'antenna');
    expect(jsonDecode(utf8.decode(base64.decode(c.queryParameters['config']!))), {
      'type': 'stdio',
      'command': _cli,
      'args': ['mcp', '--token-file', _file],
    });

    final lm = Uri.parse(link(AiApp.lmStudio).url);
    expect('${lm.scheme}://${lm.host}', 'lmstudio://add_mcp');
    expect(jsonDecode(utf8.decode(base64.decode(lm.queryParameters['config']!))), {
      'command': _cli,
      'args': ['mcp', '--token-file', _file],
    });

    final vs = link(AiApp.vscode).url;
    expect(vs, startsWith('vscode:mcp/install?'));
    expect(jsonDecode(Uri.decodeComponent(vs.substring('vscode:mcp/install?'.length))), {
      'name': 'antenna',
      'type': 'stdio',
      'command': _cli,
      'args': ['mcp', '--token-file', _file],
    });
    for (final id in [AiApp.cursor, AiApp.lmStudio, AiApp.vscode]) {
      expect(link(id).url, isNot(contains('xat_')));
    }
  });

  test('Windows (WP-17): Claude Desktop where its install reads, the other apps by hand, nothing under a home', () {
    const local = r'C:\Users\o\AppData\Local';
    const roaming = r'C:\Users\o\AppData\Roaming';
    const package = r'C:\Users\o\AppData\Local\Packages\Claude_pzs8sxrjxfjjc';
    WindowsPlace place({bool msix = false, Map<String, String>? env}) =>
        (env: env ?? {'LOCALAPPDATA': local, 'APPDATA': roaming}, dirExists: (p) => msix && p == package);
    final claude = aiAppDef(AiApp.claudeDesktop);
    expect(claudeDesktopOnWindows(place(msix: true)),
        r'C:\Users\o\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json');
    expect(claudeDesktopOnWindows(place()), r'C:\Users\o\AppData\Roaming\Claude\claude_desktop_config.json');
    expect(claudeDesktopOnWindows(place(env: {})), isNull);
    final plan = connectPlan(claude, _server, home: '/', macos: false, found: true, read: (_) => null, windows: place(msix: true))
        as WriteConfigPlan;
    expect(plan.path, startsWith(package));
    // Every other app with a file has no checked Windows path yet: the manual steps, and never a path under the home
    // folder (on Windows `HOME` is unset, and the Linux path would land at the drive's root).
    for (final app in aiApps.where((a) => a.config != null && a.id != AiApp.claudeDesktop)) {
      expect(app.config!.pathFor('/', macos: false, windows: place()), isNull, reason: app.name);
      if (app.route == ConnectRoute.configFile) {
        expect(connectPlan(app, _server, home: '/', macos: false, found: true, read: (_) => null, windows: place()),
            isA<GuidePlan>(),
            reason: app.name);
        // The control: on Linux the same app gets its file.
        expect(connectPlan(app, _server, home: '/h', macos: false, found: true, read: (_) => null), isA<WriteConfigPlan>(),
            reason: app.name);
      }
    }
  });

  test('detection: apps in /Applications on a Mac, CLIs in PATH and the usual folders', () {
    const env = {'HOME': '/Users/o', 'PATH': '/usr/bin'};
    bool dir(String p) => {'/Applications/ChatGPT.app', '/Users/o/Applications/Cursor.app'}.contains(p);
    bool file(String p) => {'/Users/o/.local/bin/claude', '/opt/homebrew/bin/codex', '/usr/bin/gemini'}.contains(p);
    final programs = ProgramLocator(windows: false, env: env, isExecutable: file, readFile: (_) => null);
    String? at(AiApp id, {bool macos = true}) =>
        detectAiApp(aiAppDef(id), programs, macos: macos, fileExists: file, dirExists: dir);
    expect(at(AiApp.chatgpt), '/Applications/ChatGPT.app');
    expect(at(AiApp.cursor), '/Users/o/Applications/Cursor.app');
    expect(at(AiApp.claudeCode), '/Users/o/.local/bin/claude');
    expect(at(AiApp.codex), '/opt/homebrew/bin/codex');
    expect(at(AiApp.geminiCli), '/usr/bin/gemini');
    expect(at(AiApp.claudeDesktop), isNull);
    expect(at(AiApp.chatgpt, macos: false), isNull, reason: 'app bundles are a macOS thing');
  });
}
