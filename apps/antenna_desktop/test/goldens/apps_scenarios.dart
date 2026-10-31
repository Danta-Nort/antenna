// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for Agents → AI apps: the list on a Mac with apps in every state (connected, waiting for the app, the
// app's process ended, revoked, not connected, not found), light and dark (the marks on both tiles), the Connect
// review step (exactly what is written where) and a step-by-step guide. No token appears in any frame.

part of 'scenarios.dart';

const _home = '/Users/owner';
const _tokens = '/Users/owner/.local/share/antenna/agents';

/// A Mac with the ChatGPT app, Claude Desktop, Cursor, Zed and LM Studio, and the Claude Code and Codex CLIs.
FakeAgentComputer _appsMac() => FakeAgentComputer(
      macos: true,
      installed: const {
        '/Applications/ChatGPT.app',
        '/Applications/Claude.app',
        '/Applications/Cursor.app',
        '/Applications/Zed.app',
        '/Applications/LM Studio.app',
        '/Users/owner/.local/bin/claude',
        '/opt/homebrew/bin/codex',
      },
      env: const {'HOME': _home, 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    );

AgentInfo _appAgent(String name, {String? comm, bool? alive, Duration? seen, int level = 5}) => AgentInfo(
      name: name,
      createdMs: 0,
      localLevel: level,
      boundPid: comm == null ? null : 4100 + name.length,
      boundComm: comm,
      boundAlive: alive,
      lastSeenMs: seen == null ? null : fixedNow.subtract(seen).millisecondsSinceEpoch,
      tokenFile: '$_tokens/$name.token',
      tasksFrom: [buildBotName],
    );

/// ChatGPT connected (Codex shares its file), Claude Desktop connected, Cursor waiting for the app, LM Studio's
/// process ended.
Future<(AppModel, FakeDaemon)> _appsModel({FakeConnectorFs? fs, List<AgentInfo>? agents, FakeAppLauncher? launcher}) async {
  final d = _demo()
    ..tokenDir = '$_home/.local/share/antenna'
    ..agentList = agents ??
        [
          _appAgent('chatgpt', comm: 'ChatGPT', alive: true, seen: const Duration(minutes: 2)),
          _appAgent('claude-desktop', comm: 'Claude', alive: true, seen: const Duration(seconds: 20)),
          _appAgent('cursor', level: 3),
          _appAgent('lm-studio', comm: 'LM Studio', alive: false, seen: const Duration(hours: 3), level: 0),
        ];
  final files = fs ??
      FakeConnectorFs({
        '$_home/.codex/config.toml':
            '[mcp_servers.antenna]\ncommand = "${_bins.cli}"\nargs = ["mcp", "--token-file", "$_tokens/chatgpt.token"]\n',
        '$_home/Library/Application Support/Claude/claude_desktop_config.json':
            '{"mcpServers": {"antenna": {"command": "${_bins.cli}", "args": ["mcp", "--token-file", '
                '"$_tokens/claude-desktop.token"]}}}',
        '$_home/.cursor/mcp.json':
            '{"mcpServers": {"antenna": {"type": "stdio", "command": "${_bins.cli}", "args": ["mcp", "--token-file", '
                '"$_tokens/cursor.token"]}}}',
        '$_home/.lmstudio/mcp.json':
            '{"mcpServers": {"antenna": {"command": "${_bins.cli}", "args": ["mcp", "--token-file", '
                '"$_tokens/lm-studio.token"]}}}',
      });
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
    agentHost: _appsMac().host,
    connectorFs: files,
    appLauncher: launcher ?? FakeAppLauncher(),
  );
  await m.connect();
  return (m, d);
}

Future<void> _appsPage(WidgetTester t, AppModel m, Appearance look) async {
  await _frame(t, XApp(model: m, appearance: look));
  await t.tap(find.byKey(const Key('agents-button')));
  await t.pump(const Duration(milliseconds: 400));
}

void _defineAppsScenarios() {
  _s('37_ai_apps', (t) async {
    const name = '37_ai_apps';
    final (m, _) = await _appsModel();
    await _appsPage(t, m, Appearance(rolePreset: RolePreset.assistant));
    await _snap(t, name);
  });

  _s('37_ai_apps_dark', (t) async {
    const name = '37_ai_apps_dark';
    final (m, _) = await _appsModel();
    await _appsPage(t, m, Appearance(initial: ThemeChoice.dark, rolePreset: RolePreset.assistant));
    await _snap(t, name);
  });

  // Connect Gemini CLI: after the password, exactly what will be written to ~/.gemini/settings.json.
  _s('38_connect_review', (t) async {
    const name = '38_connect_review';
    final (m, d) = await _appsModel(
      fs: FakeConnectorFs({'$_home/.gemini/settings.json': '{"ui": {"theme": "Default"}}'}),
    );
    await _appsPage(t, m, Appearance(rolePreset: RolePreset.assistant));
    await t.ensureVisible(find.byKey(const Key('app-connect-geminiCli')));
    await t.pump();
    await t.tap(find.byKey(const Key('app-connect-geminiCli')));
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('connect-continue')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });

  // Connect Claude Desktop while it is open: the file is written, and the last step offers to restart it (it reads its
  // settings only when it starts), then says what to ask; the status waits for the first call.
  _s('43_connect_restart', (t) async {
    const name = '43_connect_restart';
    final (m, d) = await _appsModel(
      fs: FakeConnectorFs(),
      agents: const [],
      launcher: FakeAppLauncher()..running.add('/Applications/Claude.app'),
    );
    await _appsPage(t, m, Appearance(rolePreset: RolePreset.assistant));
    await t.ensureVisible(find.byKey(const Key('app-connect-claudeDesktop')));
    await t.pump();
    await t.tap(find.byKey(const Key('app-connect-claudeDesktop')));
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('connect-continue')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('connect-write')));
    await t.pump(const Duration(milliseconds: 400));
    // Whether Claude Desktop runs arrives after the step's first frame.
    await t.pump();
    expect(find.byKey(const Key('connect-restart')), findsOneWidget);
    await _snap(t, name);
  });

  // Zed has no one-click path: after the password, the guide with the token file's path filled in.
  _s('39_connect_guide', (t) async {
    const name = '39_connect_guide';
    final (m, d) = await _appsModel(fs: FakeConnectorFs());
    await _appsPage(t, m, Appearance(rolePreset: RolePreset.frontDesk));
    await t.ensureVisible(find.byKey(const Key('app-connect-zed')));
    await t.pump();
    await t.tap(find.byKey(const Key('app-connect-zed')));
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('connect-continue')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  });
}
