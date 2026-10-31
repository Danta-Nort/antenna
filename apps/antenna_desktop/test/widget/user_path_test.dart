// SPDX-License-Identifier: AGPL-3.0-only
// The user path on the fake daemon: first launch (the window starts the daemon → node creation), a start error,
// stopping the daemon from the window, "Connect an agent" (required label, password, token, ready-made snippets), and
// the antenna terminal command.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/host/cli_install.dart';
import 'package:antenna_desktop/host/daemon_host.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/agent_snippets.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/agents/agents_dialog.dart';
import 'package:antenna_desktop/ui/agents/agents_page.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/cli/cli_dialog.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_host.dart';
import '../support/fixtures.dart';

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
);

Future<AppModel> _model(FakeDaemon d, {DaemonHost? host, CliInstaller? cli}) async {
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    defaultSocket: d.socketPath,
    host: host,
    binaries: _bins,
    cliInstaller: cli,
    live: false,
    clock: () => fixedNow,
  );
  await m.connect();
  return m;
}

/// App strings: the test system is English.
final en = l10nFor('en');

Future<void> _app(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('first run: daemon is not running → the window starts it → "new node" screen', (t) async {
    final d = FakeDaemon(reachable: false, state: DaemonState.uninitialized);
    final host = FakeHost(d);
    final m = await _model(d, host: host);
    expect(host.starts, 1);
    expect(m.phase, Phase.uninitialized);
    await _app(t, m);
    expect(find.text('New node'), findsOneWidget);
    expect(find.textContaining("It can't be recovered"), findsOneWidget);
    await t.enterText(find.byKey(const Key('password')), 'my long password');
    await t.enterText(find.byKey(const Key('password2')), 'my long password');
    await t.tap(find.byKey(const Key('submit')));
    await t.pump(const Duration(milliseconds: 500));
    expect(m.phase, Phase.unlocked);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('daemon failed to start: the error and the log tail are shown, retry button', (t) async {
    final d = FakeDaemon(reachable: false);
    final host = FakeHost(
      d,
      fail: const DaemonStartException(
        DaemonStartFailure.exited,
        exitCode: 1,
        logTail: 'antennad: another antennad is already listening on /x.sock',
        logPath: '/log',
      ),
    );
    final m = await _model(d, host: host);
    await _app(t, m);
    expect(find.text("The daemon didn't start"), findsOneWidget);
    expect(find.text('The daemon exited during startup (exit code 1)'), findsOneWidget);
    expect(find.textContaining('another antennad is already listening'), findsOneWidget);
    expect(find.textContaining('Another antennad is already running'), findsOneWidget);
    expect(find.byKey(const Key('start-daemon')), findsOneWidget);
  });

  testWidgets('stop the daemon from the window: no silent restart', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final host = FakeHost(d);
    final m = await _model(d, host: host);
    await _app(t, m);
    await t.tap(find.byKey(const Key('daemon-pill')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('daemon-stop')));
    await t.pump(const Duration(milliseconds: 400));
    expect(host.stops, 1);
    expect(m.phase, Phase.unreachable);
    expect(host.starts, 0, reason: 'the owner stopped it — the window does not start it again by itself');
    expect(find.byKey(const Key('start-daemon')), findsOneWidget);
  });

  testWidgets('connect an agent: mandatory label, owner password, one-time token, snippets', (t) async {
    final clip = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map<Object?, Object?>)['text']! as String);
      return null;
    });
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await _app(t, m);
    // "Agents" in the navigation → the Agents section → "Connect an agent".
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(AgentsPage), findsOneWidget);
    await t.tap(find.byKey(const Key('agent-connect')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(AgentsDialog), findsOneWidget);

    await t.tap(find.byKey(const Key('agent-issue')));
    await t.pump();
    expect(find.textContaining('Give the agent a name'), findsOneWidget);
    await t.enterText(find.byKey(const Key('agent-name')), 'jarvis');
    await t.tap(find.byKey(const Key('agent-issue')));
    await t.pump();
    expect(find.textContaining('Choose a data label'), findsOneWidget, reason: 'Q-15: no default label');
    expect(d.calls, isNot(contains('agent_add')));

    await t.tap(find.byKey(const Key('label-5')));
    await t.enterText(find.byKey(const Key('owner-password')), 'wrong');
    await t.tap(find.byKey(const Key('agent-issue')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.errWrongPassword), findsOneWidget);

    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('agent-issue')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.agentList.single.name, 'jarvis');
    expect(d.agentList.single.localLevel, 5);
    expect(find.text('Agent “jarvis” connected'), findsOneWidget);
    // The daemon wrote the token to a file only the owner can read: the window shows the file, never the token.
    expect(d.calls.where((c) => c == 'agent_add'), hasLength(2));
    expect(find.byKey(const Key('agent-token-file')), findsOneWidget);
    expect(find.text(d.tokenFileOf('jarvis')), findsOneWidget);
    expect(find.textContaining('xat_'), findsNothing);
    // The default tab depends on the "MCP on macOS" switch: pick it explicitly so the test does not depend on the OS.
    await t.tap(find.byKey(const Key('snippet-claude')));
    await t.pump();
    expect(find.textContaining('claude mcp add antenna --scope user'), findsOneWidget);
    expect(find.textContaining('/Applications/Antenna.app/Contents/Helpers/antenna'), findsWidgets);

    await t.tap(find.byKey(const Key('snippet-codex')));
    await t.pump();
    expect(find.textContaining('[mcp_servers.antenna]'), findsOneWidget);
    await t.tap(find.byKey(const Key('copy-codex')));
    await t.pump();
    expect(clip.last, contains('args = ["mcp", "--token-file", "${d.tokenFileOf('jarvis')}"]'));
    expect(clip.last, isNot(contains('xat_')));

    await t.tap(find.byKey(const Key('snippet-script')));
    await t.pump();
    expect(find.textContaining('inbox --wait --timeout 60s'), findsOneWidget);
  });

  testWidgets('connect an agent with an older daemon (no token files): the token once, with the warning and '
      '"Revoke and create a new token"', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..tokenFiles = false;
    final m = await _model(d);
    await _app(t, m);
    await t.tap(find.byKey(const Key('agents-button')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('agent-connect')));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('agent-name')), 'jarvis');
    await t.tap(find.byKey(const Key('label-5')));
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('agent-issue')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.agentList.single.name, 'jarvis', reason: 'issued again without the field the older daemon rejects');
    expect(find.byKey(const Key('token-warning')), findsOneWidget);
    expect(find.text(en.tokenWarn), findsOneWidget);
    final first = find.textContaining('xat_').evaluate().length;
    expect(first, greaterThan(0));
    await t.ensureVisible(find.byKey(const Key('token-rotate')));
    await t.tap(find.byKey(const Key('token-rotate')));
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('owner-password')).last, d.password);
    await t.tap(find.byKey(const Key('password-ok')));
    await t.pump(const Duration(milliseconds: 300));
    expect(d.calls, contains('agent_token'), reason: 'the old token stops working');
  });

  testWidgets('the terminal button installs the `antenna` command: link in ~/.local/bin, PATH hint', (t) async {
    final root = Directory.systemTemp.createTempSync('cli-widget-');
    addTearDown(() => root.deleteSync(recursive: true));
    final cli = File('${root.path}/Antenna.app/Contents/Helpers/antenna')..createSync(recursive: true);
    final installer = CliInstaller(
      cliPath: cli.path,
      home: '${root.path}/home',
      os: 'macos',
      shell: '/bin/zsh',
      runner: (exe, args, {required timeout}) async => ProcessResult(1, 0, '__ANTENNA_PATH__/usr/bin:/bin\n', ''),
    );
    final m = await _model(FakeDaemon(contacts: demoContacts(), history: demoHistory()), cli: installer);
    await _app(t, m);
    // The button is in Settings.
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('settings-advanced')));
    await t.pump(const Duration(milliseconds: 300));
    await t.ensureVisible(find.byKey(const Key('cli-button')));
    await t.pump();
    await t.tap(find.byKey(const Key('cli-button')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(); // the link state is read asynchronously (login shell)
    expect(find.byType(CliDialog), findsOneWidget);
    expect(find.text('not installed'), findsOneWidget);
    expect(find.byKey(const Key('cli-install-system')), findsOneWidget, reason: 'macOS: /usr/local/bin by explicit choice');
    await t.tap(find.byKey(const Key('cli-install')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(Link('${root.path}/home/.local/bin/antenna').targetSync(), cli.path);
    expect(find.byKey(const Key('cli-done')), findsOneWidget);
    expect(find.text('installed (a link to this app)'), findsOneWidget);
    expect(find.textContaining("~/.local/bin isn't in your shell's PATH"), findsOneWidget);
    expect(find.textContaining('>> ~/.zprofile'), findsOneWidget);
  });

  test('one switch decides the default tab and the macOS MCP note', () {
    expect(defaultSnippetTab(macos: false), 'claude');
    expect(defaultSnippetTab(macos: true), mcpWorksOnMacos ? 'claude' : 'script');
    final note = agentSnippets(en, name: 'j', token: 't', xPath: '/x', macos: true).first.note!;
    expect(note.contains('PORTABILITY'), !mcpWorksOnMacos);
  });

  test('the macOS core port is merged: MCP works on macOS like on Linux', () {
    // On macOS the core binds `antenna mcp` to the MCP host (docs/PORTABILITY.md M-3…M-6, D-P-2), and the window says so.
    expect(mcpWorksOnMacos, isTrue);
    expect(defaultSnippetTab(macos: true), 'claude');
    final mac = {for (final x in agentSnippets(en, name: 'j', token: 'xat_T', xPath: '/A/x', macos: true)) x.id: x};
    final linux = {for (final x in agentSnippets(en, name: 'j', token: 'xat_T', xPath: '/A/x')) x.id: x};
    for (final id in mac.keys) {
      expect(mac[id]!.text, linux[id]!.text, reason: id);
      expect(mac[id]!.note, linux[id]!.note, reason: id);
    }
    expect(mac['hooks']!.text, isNot(contains('xat_T')), reason: 'hooks are descendants of the host: no token');
  });

  test('snippets: JSON is valid, the token and the absolute path are inside, no ANTENNA_SOCKET by default', () {
    final s = {
      for (final x in agentSnippets(en, name: 'j', token: 'xat_T', xPath: '/A/x', macos: true)) x.id: x,
    };
    expect(s.keys, ['claude', 'mcp_json', 'hooks', 'codex', 'script']);
    expect(s['claude']!.text, "claude mcp add antenna --scope user --env ANTENNA_AGENT_TOKEN='xat_T' -- '/A/x' mcp");
    expect(s['mcp_json']!.text, contains('"command": "/A/x"'));
    expect(s['mcp_json']!.text, contains('"antenna": {'));
    expect(s['mcp_json']!.text, isNot(contains('SOCKET')));
    if (mcpWorksOnMacos) {
      expect(s['hooks']!.text, contains("'/A/x' hook claude-code"));
      expect(s['hooks']!.text, isNot(contains('xat_T')), reason: 'macOS: the daemon sees the host tree — no token');
    } else {
      expect(s['hooks']!.text, contains("ANTENNA_AGENT_TOKEN='xat_T' '/A/x' hook claude-code"),
          reason: 'macOS: no process-tree binding yet — the hook carries the token');
      expect(s['claude']!.note, contains('PORTABILITY'), reason: 'macOS: antenna mcp does not start yet — said honestly');
    }
    final linux = agentSnippets(en, name: 'j', token: 'xat_T', xPath: '/A/x', socket: '/s.sock');
    expect(linux.firstWhere((x) => x.id == 'hooks').text, contains("ANTENNA_SOCKET='/s.sock' '/A/x' hook claude-code"));
    expect(linux.firstWhere((x) => x.id == 'hooks').text, isNot(contains('xat_T')));
    expect(linux.firstWhere((x) => x.id == 'codex').text, contains('ANTENNA_SOCKET = "/s.sock"'));

    // With a token file (preview.4) no snippet holds the token: they name the file.
    final byFile = {
      for (final x in agentSnippets(en, name: 'j', token: 'xat_T', tokenFile: '/D/agents/j.token', xPath: '/A/x')) x.id: x,
    };
    for (final x in byFile.values) {
      expect(x.text, isNot(contains('xat_T')), reason: x.id);
    }
    expect(byFile['claude']!.text, "claude mcp add antenna --scope user -- '/A/x' mcp --token-file '/D/agents/j.token'");
    expect(jsonDecode(byFile['mcp_json']!.text), {
      'mcpServers': {
        'antenna': {'command': '/A/x', 'args': ['mcp', '--token-file', '/D/agents/j.token']},
      },
    });
    expect(byFile['codex']!.text, '[mcp_servers.antenna]\ncommand = "/A/x"\nargs = ["mcp", "--token-file", '
        '"/D/agents/j.token"]\n');
    expect(byFile['script']!.text, contains("export ANTENNA_AGENT_TOKEN_FILE='/D/agents/j.token'"));
  });

  test('snippets: titles and notes follow the window language, code stays as is', () {
    final ru = l10nFor('ru');
    final e = {for (final x in agentSnippets(en, name: 'j', token: 'xat_T', xPath: '/A/x')) x.id: x};
    final r = {for (final x in agentSnippets(ru, name: 'j', token: 'xat_T', xPath: '/A/x')) x.id: x};
    expect(e['script']!.title, 'Any script');
    expect(r['script']!.title, ru.snippetScriptTitle);
    expect(e['hooks']!.title, 'Claude Code hooks');
    expect(r['hooks']!.title, ru.snippetHooksTitle);
    // Commands and configs are not translated; in the script example only the comments and the sample reply are.
    for (final id in ['claude', 'mcp_json', 'hooks', 'codex']) {
      expect(r[id]!.text, e[id]!.text, reason: id);
    }
    expect(e['script']!.text, contains('reply="received: \${#text} characters"'));
    expect(r['script']!.text, contains('reply="${ru.snippetScriptReply(r'${#text}')}"'));
  });
}
