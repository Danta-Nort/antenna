// SPDX-License-Identifier: AGPL-3.0-only
// Agents → AI apps on a fake daemon, a fake file system and a fake launcher: the list (found first, status of each
// app), every Connect route (an app's file, an install link, the guide), what the owner sees before anything is
// written (path and entry, never the token), backups and untouched entries, an older daemon without token files,
// Disconnect, and whose messages an agent treats as tasks.

import 'dart:convert';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/ai_apps.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/mcp_config.dart';
import 'package:antenna_desktop/ui/agents/connect_app_dialog.dart';
import 'package:antenna_desktop/ui/agents/connect_widgets.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/code/start_agent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _cli = '/Applications/Antenna.app/Contents/Helpers/antenna';
const _home = '/Users/owner';
const _claudeConfig = '$_home/Library/Application Support/Claude/claude_desktop_config.json';
const _codexConfig = '$_home/.codex/config.toml';

/// A Mac with ChatGPT, Claude Desktop, Cursor, VS Code and LM Studio, and the Claude Code and Codex CLIs.
FakeAgentComputer _mac({Set<String>? installed}) => FakeAgentComputer(
      macos: true,
      installed: installed ??
          const {
            '/Applications/ChatGPT.app',
            '/Applications/Claude.app',
            '/Applications/Cursor.app',
            '/Applications/Visual Studio Code.app',
            '/Applications/LM Studio.app',
            '/Users/owner/.local/bin/claude',
            '/opt/homebrew/bin/codex',
          },
      env: const {'HOME': _home, 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    );

AgentInfo _agent(String name, {int? pid, String? comm, bool? alive, int? seenMs, List<String>? tasks}) => AgentInfo(
      name: name,
      createdMs: 0,
      localLevel: 5,
      boundPid: pid,
      boundComm: comm,
      boundAlive: alive,
      lastSeenMs: seenMs,
      tokenFile: '$_home/.local/share/antenna/agents/$name.token',
      tasksFrom: tasks ?? [buildBotName],
    );

Future<(AppModel, FakeDaemon, FakeConnectorFs, FakeAppLauncher)> _setup({
  List<AgentInfo> agents = const [],
  Map<String, String> files = const {},
  FakeAgentComputer? computer,
}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..agentList = [...agents];
  final fs = FakeConnectorFs(files);
  final launcher = FakeAppLauncher();
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: (computer ?? _mac()).host,
    defaultSocket: d.socketPath,
    connectorFs: fs,
    appLauncher: launcher,
  );
  await m.connect();
  return (m, d, fs, launcher);
}

Future<void> _agentsPage(WidgetTester t, AppModel m, {Appearance? look}) async {
  t.view.physicalSize = const Size(1440, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: look ?? Appearance(rolePreset: RolePreset.assistant)));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('agents-button')));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Finder _in(String row, Finder f) => find.descendant(of: find.byKey(Key('app-$row')), matching: f);

Future<void> _tapVisible(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

/// Step 1 of Connect: the role (a new agent) and the password, then Continue.
Future<void> _setUp(WidgetTester t, FakeDaemon d, {bool role = false}) async {
  if (role) await _tapVisible(t, find.descendant(of: find.byType(ConnectAppDialog), matching: find.byKey(const Key('role-assistant'))));
  await t.enterText(find.descendant(of: find.byType(ConnectAppDialog), matching: find.byKey(const Key('owner-password'))), d.password);
  await _tapVisible(t, find.byKey(const Key('connect-continue')));
}

/// The daemon reports that [agent]'s MCP server is bound to [comm] (and tells the window with an `agent` event).
void _bind(AppModel m, FakeDaemon d, String agent, String comm) {
  d.agentList = [
    for (final a in d.agentList)
      a.name == agent
          ? AgentInfo(
              name: a.name,
              createdMs: a.createdMs,
              localLevel: a.localLevel,
              links: a.links,
              boundPid: 4242,
              boundComm: comm,
              boundAlive: true,
              lastSeenMs: fixedNow.millisecondsSinceEpoch,
              tokenFile: a.tokenFile,
              tasksFrom: a.tasksFrom,
            )
          : a,
  ];
  m.handleEvent(AgentEvent(name: agent, change: 'bound'));
}

void main() {
  testWidgets('the list: found apps first, each with whether it is really connected and its best action', (t) async {
    final ago = fixedNow.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch;
    final (m, _, _, _) = await _setup(
      agents: [
        _agent('chatgpt', pid: 3100, comm: 'ChatGPT', alive: true, seenMs: ago),
        _agent('cursor'),
        _agent('lm-studio', pid: 3200, comm: 'LM Studio', alive: false, seenMs: ago),
      ],
      files: {
        _codexConfig: '[mcp_servers.antenna]\ncommand = "$_cli"\nargs = ["mcp", "--token-file", "/x/chatgpt.token"]\n',
        _claudeConfig: jsonEncode({
          'mcpServers': {
            'antenna': {'command': _cli, 'args': ['mcp', '--token-file', '/x/claude-desktop.token']},
          },
        }),
      },
    );
    await _agentsPage(t, m);
    expect(find.byKey(const Key('ai-apps')), findsOneWidget);
    // Every app of the catalog has a row; ChatGPT, named as people know it, is there.
    for (final id in ['chatgpt', 'codex', 'claudeDesktop', 'claudeCode', 'geminiCli', 'cursor', 'vscode', 'windsurf',
      'zed', 'lmStudio', 'grok']) {
      expect(find.byKey(Key('app-$id')), findsOneWidget, reason: id);
    }
    expect(_in('codex', find.text('Codex by OpenAI · with your ChatGPT plan')), findsOneWidget);
    // Found here first: ChatGPT above Gemini CLI (not installed), which is under "Not found on this computer".
    expect(t.getTopLeft(find.byKey(const Key('app-chatgpt'))).dy, lessThan(t.getTopLeft(find.byKey(const Key('app-geminiCli'))).dy));
    expect(find.text('NOT FOUND ON THIS COMPUTER'), findsOneWidget);
    expect(_in('chatgpt', find.byKey(const Key('detected-chatgpt'))), findsOneWidget);

    // ChatGPT: connected, by the process and when it was last seen; Codex shares the file, so the same.
    expect(_in('chatgpt', find.byKey(const Key('status-connected'))), findsOneWidget);
    expect(_in('chatgpt', find.textContaining('ChatGPT (process 3100) · last seen 2 min ago')), findsOneWidget);
    expect(_in('codex', find.byKey(const Key('status-connected'))), findsOneWidget);
    expect(_in('codex', find.textContaining('shares its MCP settings with ChatGPT')), findsOneWidget);
    // Cursor: a token, but Cursor has not called yet.
    expect(_in('cursor', find.byKey(const Key('status-waiting'))), findsOneWidget);
    expect(_in('cursor', find.text('Open Cursor and start a chat that uses Antenna.')), findsOneWidget);
    // LM Studio: its process ended.
    expect(_in('lmStudio', find.byKey(const Key('status-disconnected'))), findsOneWidget);
    // Claude Desktop: in its file, but the agent is gone.
    expect(_in('claudeDesktop', find.byKey(const Key('status-revoked'))), findsOneWidget);
    expect(_in('claudeDesktop', find.byKey(const Key('app-connect-claudeDesktop'))), findsOneWidget);
    expect(_in('claudeDesktop', find.text('Reconnect')), findsOneWidget);
    // Claude Code: runs in Code mode; Zed: no one-click path, "Set up".
    expect(_in('claudeCode', find.byKey(const Key('app-start-claudeCode'))), findsOneWidget);
    expect(_in('zed', find.text('Set up')), findsOneWidget);
    expect(_in('geminiCli', find.text('Connect')), findsOneWidget);
    // No token anywhere on the page.
    expect(find.textContaining('xat_'), findsNothing);
  });

  testWidgets('Connect Claude Desktop: one password, the exact entry and path first, a backup, other servers kept, '
      'then Waiting → Connected', (t) async {
    const other = {'command': 'npx', 'args': ['-y', '@modelcontextprotocol/server-filesystem', '/Users/owner/Desktop']};
    final (m, d, fs, _) = await _setup(files: {
      _claudeConfig: jsonEncode({'mcpServers': {'filesystem': other}, 'globalShortcut': 'Ctrl+Space'}),
    });
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-claudeDesktop')));
    expect(find.byType(ConnectAppDialog), findsOneWidget);
    expect(find.text('Connect Claude Desktop'), findsOneWidget);
    // Tasks: by default, contacts at trust level 5.
    expect(find.text('This agent will do tasks from: $buildBotName (∞ · own computer)'), findsOneWidget);

    // Wrong password: nothing issued, nothing written.
    await t.enterText(find.byKey(const Key('owner-password')), 'wrong');
    await _tapVisible(t, find.byKey(const Key('connect-continue')));
    expect(find.text(en.errWrongPassword), findsOneWidget);
    expect(fs.writes, isEmpty);

    await _setUp(t, d);
    expect(d.calls.where((c) => c == 'agent_add'), hasLength(2), reason: 'the wrong password, then the right one');
    expect(d.agentList.single.name, 'claude-desktop');
    expect(d.agentList.single.localLevel, 5, reason: 'the role preset');
    expect(d.calls, isNot(contains('agent_tasks')), reason: 'the default needs no call');
    // Review: where and what; nothing written yet; no token on screen.
    expect(find.text('Antenna will add this entry to $_claudeConfig:'), findsOneWidget);
    final entry = t.widget<CodeBlock>(find.byKey(const Key('connect-review-entry'))).text;
    expect(entry, contains('"--token-file"'));
    expect(entry, contains(d.tokenFileOf('claude-desktop')));
    expect(find.textContaining('xat_'), findsNothing);
    expect(fs.writes, isEmpty, reason: 'nothing before the owner confirms');

    await _tapVisible(t, find.byKey(const Key('connect-write')));
    expect(fs.backups.values, [_claudeConfig]);
    final written = jsonDecode(fs.files[_claudeConfig]!) as Map;
    expect(written['globalShortcut'], 'Ctrl+Space');
    expect((written['mcpServers'] as Map)['filesystem'], other);
    expect((written['mcpServers'] as Map)['antenna'], {
      'command': _cli,
      'args': ['mcp', '--token-file', d.tokenFileOf('claude-desktop')],
    });
    expect(fs.files[_claudeConfig], isNot(contains('xat_')));
    expect(find.byKey(const Key('connect-backup')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('connect-live-status')), matching: find.byKey(const Key('status-waiting'))),
        findsOneWidget);

    // Claude Desktop starts the server: the daemon binds the token and says so.
    _bind(m, d, 'claude-desktop', 'Claude');
    await _settle(t);
    expect(find.descendant(of: find.byKey(const Key('connect-live-status')), matching: find.byKey(const Key('status-connected'))),
        findsOneWidget);
    await _tapVisible(t, find.byKey(const Key('connect-done')));
    expect(_in('claudeDesktop', find.byKey(const Key('status-connected'))), findsOneWidget);
  });

  testWidgets('one app with several MCP processes (D-97): "Connected · 2 sessions"; one or none: "Connected"',
      (t) async {
    AgentInfo bound(String name, String comm, int? processes) => AgentInfo(
          name: name,
          createdMs: 0,
          localLevel: 5,
          boundPid: 3100,
          boundComm: comm,
          boundAlive: true,
          lastSeenMs: fixedNow.millisecondsSinceEpoch,
          mcpProcesses: processes,
          tokenFile: '$_home/.local/share/antenna/agents/$name.token',
        );
    final (m, _, _, _) = await _setup(
      agents: [bound('claude-desktop', 'Claude', 2), bound('chatgpt', 'ChatGPT', null), bound('cursor', 'Cursor', 1)],
      files: {
        _claudeConfig: jsonEncode({
          'mcpServers': {
            'antenna': {'command': _cli, 'args': ['mcp', '--token-file', '/x/claude-desktop.token']},
          },
        }),
        _codexConfig: '[mcp_servers.antenna]\ncommand = "$_cli"\nargs = ["mcp", "--token-file", "/x/chatgpt.token"]\n',
        '$_home/.cursor/mcp.json': jsonEncode({
          'mcpServers': {
            'antenna': {'type': 'stdio', 'command': _cli, 'args': ['mcp', '--token-file', '/x/cursor.token']},
          },
        }),
      },
    );
    await _agentsPage(t, m);
    // Taller: each app row also names its agent now, and the agents' own rows sit below the apps
    t.view.physicalSize = const Size(1440, 1400);
    await _settle(t);
    expect(_in('claudeDesktop', find.text('Connected · 2 sessions')), findsOneWidget);
    expect(_in('claudeDesktop', find.text(en.statusConnectedSessions(2))), findsOneWidget);
    expect(_in('chatgpt', find.text(en.statusConnected)), findsOneWidget, reason: 'an older daemon says nothing');
    expect(_in('cursor', find.text(en.statusConnected)), findsOneWidget, reason: 'one process is just connected');
    // The agent's own row says the same.
    expect(find.descendant(of: find.byKey(const Key('agent-status-claude-desktop')), matching: find.text('Connected · 2 sessions')),
        findsOneWidget);
    // Each row names the agent contacts address, so the owner can tell them what to write to (D-UI-32).
    expect(_in('chatgpt', find.text(en.appsAddressedAs('chatgpt'))), findsOneWidget);
    expect(_in('claudeDesktop', find.text(en.appsAddressedAs('claude-desktop'))), findsOneWidget);
    expect(find.text('Contacts write to it as chatgpt'), findsWidgets);
  });

  testWidgets('back to the window after installing a CLI: the list looks again and finds it', (t) async {
    final installed = {'/Applications/Claude.app'};
    final (m, _, _, _) = await _setup(computer: _mac(installed: installed));
    await _agentsPage(t, m);
    expect(_in('claudeCode', find.text(en.appsNotFound)), findsOneWidget);
    // Claude Code's installer puts it into ~/.local/bin while the Agents page stays open.
    installed.add('/Users/owner/.local/bin/claude');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(t);
    expect(_in('claudeCode', find.text(en.appsFoundAt('/Users/owner/.local/bin/claude'))), findsOneWidget);
    expect(_in('claudeCode', find.byKey(const Key('app-start-claudeCode'))), findsOneWidget);
  });

  testWidgets('Connect ChatGPT writes ~/.codex/config.toml, which Codex shares; other tables stay byte for byte',
      (t) async {
    const before = 'model = "gpt-5.5"\n\n[mcp_servers.context7]\ncommand = "npx"\nargs = ["-y", "@upstash/context7-mcp"]\n';
    final (m, d, fs, _) = await _setup(files: {_codexConfig: before});
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-chatgpt')));
    await _setUp(t, d);
    expect(find.text('Antenna will add this entry to $_codexConfig:'), findsOneWidget);
    await _tapVisible(t, find.byKey(const Key('connect-write')));
    final after = fs.files[_codexConfig]!;
    expect(after, startsWith(before));
    expect(after, contains('[mcp_servers.antenna]\ncommand = "$_cli"\nargs = ["mcp", "--token-file", '
        '"${d.tokenFileOf('chatgpt')}"]\n'));
    await _tapVisible(t, find.byKey(const Key('connect-done')));
    expect(_in('chatgpt', find.byKey(const Key('status-waiting'))), findsOneWidget);
    expect(_in('codex', find.byKey(const Key('status-waiting'))), findsOneWidget, reason: 'the same file, the same agent');
  });

  testWidgets('Cursor, VS Code, LM Studio found here: Connect opens their install link, which names only the token '
      'file', (t) async {
    final (m, d, fs, launcher) = await _setup();
    await _agentsPage(t, m);
    for (final (row, scheme) in [('cursor', 'cursor://'), ('vscode', 'vscode:'), ('lmStudio', 'lmstudio://')]) {
      await _tapVisible(t, find.byKey(Key('app-connect-$row')));
      await _setUp(t, d, role: true);
      expect(find.textContaining('install link'), findsOneWidget, reason: row);
      await _tapVisible(t, find.byKey(const Key('connect-write')));
      expect(launcher.urls.last, startsWith(scheme));
      expect(launcher.urls.last, isNot(contains('xat_')));
      await _tapVisible(t, find.byKey(const Key('connect-done')));
    }
    final cursor = Uri.parse(launcher.urls.first);
    expect(jsonDecode(utf8.decode(base64.decode(cursor.queryParameters['config']!)))['args'],
        ['mcp', '--token-file', d.tokenFileOf('cursor')]);
    expect(fs.writes, isEmpty, reason: 'the apps write their own files');
  });

  testWidgets('an app that is not installed yet: its file is written instead of opening a link', (t) async {
    final (m, d, fs, launcher) = await _setup(computer: _mac(installed: const {}));
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-cursor')));
    await _setUp(t, d, role: true);
    await _tapVisible(t, find.byKey(const Key('connect-write')));
    expect(launcher.urls, isEmpty);
    expect(fs.backups, isEmpty, reason: 'no file before, nothing to back up');
    expect(jsonDecode(fs.files['$_home/.cursor/mcp.json']!), {
      'mcpServers': {
        'antenna': {'type': 'stdio', 'command': _cli, 'args': ['mcp', '--token-file', d.tokenFileOf('cursor')]},
      },
    });
  });

  testWidgets('Zed: Set up issues the agent, then the step-by-step guide with the token file filled in', (t) async {
    final (m, d, fs, _) = await _setup();
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-zed')));
    await _setUp(t, d, role: true);
    expect(find.byKey(const Key('guide-zed')), findsOneWidget);
    expect(find.text('Connect Zed step by step'), findsOneWidget);
    expect(find.textContaining('Settings → AI → MCP Servers'), findsOneWidget);
    expect(find.text('mcp --token-file ${d.tokenFileOf('zed')}'), findsOneWidget, reason: 'the arguments to copy');
    expect(find.textContaining('xat_'), findsNothing);
    expect(fs.writes, isEmpty);
    expect(find.byKey(const Key('connect-live-status')), findsOneWidget);
  });

  testWidgets('a file that is not plain JSON is left alone: the guide says why', (t) async {
    const jsonc = '// my settings\n{"mcpServers": {}}';
    final (m, d, fs, _) = await _setup(files: {_claudeConfig: jsonc});
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-claudeDesktop')));
    await _setUp(t, d, role: true);
    expect(find.byKey(const Key('guide-claudeDesktop')), findsOneWidget);
    expect(find.textContaining('does not edit $_claudeConfig by itself'), findsOneWidget);
    expect(fs.files[_claudeConfig], jsonc);
    expect(fs.writes, isEmpty);
  });

  testWidgets('an older daemon without token files: the token is shown once, with the warning and a way to replace it',
      (t) async {
    final (m, d, fs, _) = await _setup();
    d.tokenFiles = false;
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-geminiCli')));
    await _setUp(t, d, role: true);
    expect(find.byKey(const Key('token-warning')), findsOneWidget);
    expect(find.text('Paste this only into the app\'s settings, never into a chat. The AI does not need to see it.'),
        findsOneWidget);
    final first = d.agentList.single.name;
    expect(first, 'gemini-cli');
    expect(fs.writes, isEmpty, reason: 'a token is never written into an app\'s file');
    // "Revoke and create a new token": the old token stops working (agent_token), the password again.
    await _tapVisible(t, find.byKey(const Key('token-rotate')));
    await t.enterText(find.byKey(const Key('owner-password')).last, d.password);
    await _tapVisible(t, find.byKey(const Key('password-ok')));
    expect(d.calls, contains('agent_token'));
  });

  testWidgets('an existing agent gets a new token, not a twin; whose messages are tasks can be changed on the way',
      (t) async {
    final (m, d, _, _) = await _setup(agents: [_agent('grok')]);
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-grok')));
    expect(find.textContaining('Grok Build connects as your agent “grok”, with a new token.'), findsOneWidget);
    await _tapVisible(t, find.byKey(const Key('connect-tasks-change')));
    await _tapVisible(t, find.byKey(const Key('tasks-mode-2')));
    expect(find.text('This agent takes no tasks from contacts: every message is data it summarizes for you.'),
        findsOneWidget);
    await _setUp(t, d);
    expect(d.calls, isNot(contains('agent_add')));
    expect(d.calls, containsAllInOrder(['agent_token', 'agent_tasks']));
    expect(d.tasksSet['grok'], isEmpty);
    expect(d.passwords['agent_tasks'], d.password, reason: 'the same password, asked once');
  });

  testWidgets('the file changed after the review: nothing is overwritten, the new content is shown first', (t) async {
    final (m, d, fs, _) = await _setup(computer: _mac(installed: const {}));
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-connect-windsurf')));
    await _setUp(t, d, role: true);
    const path = '$_home/.config/devin/mcp_config.json';
    fs.files[path] = '{"mcpServers": {"other": {"command": "x"}}}';
    await _tapVisible(t, find.byKey(const Key('connect-write')));
    expect(find.textContaining('The file changed while you were reading it'), findsOneWidget);
    expect(fs.writes, isEmpty);
    await _tapVisible(t, find.byKey(const Key('connect-write')));
    expect((jsonDecode(fs.files[path]!)['mcpServers'] as Map).keys, ['other', 'antenna']);
  });

  testWidgets('Disconnect: Antenna\'s entry goes (backup first), other servers stay, the agent is revoked', (t) async {
    final (m, d, fs, _) = await _setup(
      agents: [_agent('claude-desktop', pid: 3300, comm: 'Claude', alive: true)],
      files: {
        _claudeConfig: jsonEncode({
          'mcpServers': {
            'filesystem': {'command': 'npx'},
            'antenna': {'command': _cli, 'args': ['mcp', '--token-file', '/x/claude-desktop.token']},
          },
        }),
      },
    );
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-menu-claudeDesktop')));
    await _tapVisible(t, find.byKey(const Key('app-menu-disconnect-claudeDesktop')).last);
    expect(find.textContaining('removes its entry from $_claudeConfig'), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')).last, d.password);
    await _tapVisible(t, find.byKey(const Key('password-ok')));
    expect(d.calls, contains('agent_remove'));
    expect(d.agentList, isEmpty);
    expect(fs.backups.values, [_claudeConfig]);
    expect(jsonDecode(fs.files[_claudeConfig]!), {
      'mcpServers': {'filesystem': {'command': 'npx'}},
    });
    expect(_in('claudeDesktop', find.text('Connect')), findsOneWidget);
  });

  testWidgets('Claude Code starts in Code mode; its guide gives the claude mcp add command with the token file',
      (t) async {
    final (m, d, _, _) = await _setup();
    await _agentsPage(t, m);
    await _tapVisible(t, find.byKey(const Key('app-start-claudeCode')));
    expect(find.byType(StartAgentDialog), findsOneWidget);
    Navigator.of(t.element(find.byType(StartAgentDialog))).pop();
    await _settle(t);
    await _tapVisible(t, find.byKey(const Key('app-menu-claudeCode')));
    await _tapVisible(t, find.byKey(const Key('app-menu-guide-claudeCode')).last);
    await _setUp(t, d, role: true);
    expect(
      find.text('claude mcp add --scope user --transport stdio antenna -- $_cli mcp --token-file '
          '${d.tokenFileOf('claude-code')}'),
      findsOneWidget,
    );
  });

  testWidgets('Agents: each agent\'s status and whose messages are its tasks; changing that needs the password',
      (t) async {
    final (m, d, _, _) = await _setup(agents: [_agent('chatgpt', pid: 3100, comm: 'ChatGPT', alive: true)]);
    await _agentsPage(t, m);
    expect(find.byKey(const Key('agent-status-chatgpt')), findsOneWidget);
    expect(find.byKey(const Key('agent-tasks-chatgpt')), findsOneWidget);
    // Build bot is at level 5: the owner's own computer, marked as such.
    expect(find.text('takes tasks from $buildBotName (own computer)'), findsOneWidget);
    await _tapVisible(t, find.byKey(const Key('agent-tasks-edit-chatgpt')));
    await _tapVisible(t, find.byKey(const Key('tasks-mode-1')));
    expect(find.byKey(Key('self-mark-$buildBotName')), findsOneWidget);
    expect(find.byKey(Key('self-mark-$emilyName')), findsNothing, reason: 'level 4');
    await _tapVisible(t, find.byKey(Key('tasks-contact-$emilyName')));
    await t.enterText(find.byKey(const Key('owner-password')).last, d.password);
    await _tapVisible(t, find.byKey(const Key('tasks-save')));
    expect(d.tasksSet['chatgpt'], unorderedEquals([buildBotName, emilyName]));
    expect(find.text('takes tasks from $buildBotName (own computer), $emilyName'), findsOneWidget);
  });

  test('Windows comes from the agent host, not from the machine the test runs on (WP-17)', () async {
    const env = {
      'HOME': _home,
      'LOCALAPPDATA': r'C:\Users\o\AppData\Local',
      'APPDATA': r'C:\Users\o\AppData\Roaming',
      'PATH': '/usr/bin:/bin',
    };
    for (final windows in [true, false]) {
      final (m, _, _, _) = await _setup(computer: FakeAgentComputer(windows: windows, env: env));
      final plan = m.planConnect(aiAppDef(AiApp.claudeDesktop), '$_home/.local/share/antenna/agents/claude.token');
      expect(
        (plan as WriteConfigPlan).path,
        windows
            ? r'C:\Users\o\AppData\Roaming\Claude\claude_desktop_config.json'
            : '$_home/.config/Claude/claude_desktop_config.json',
        reason: windows ? 'Windows' : 'control: Linux, on any test machine',
      );
    }
  });

  test('an app entry is McpServer.antenna: the token file in the arguments, the socket only when not the default', () {
    final s = McpServer.antenna(cli: _cli, tokenFile: '/f/a.token', socket: '/tmp/s.sock');
    expect(s.args, ['mcp', '--token-file', '/f/a.token']);
    expect(s.env, {'ANTENNA_SOCKET': '/tmp/s.sock'});
    expect(McpServer.antenna(cli: _cli, tokenFile: '/f/a.token').env, isEmpty);
  });
}
