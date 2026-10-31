// SPDX-License-Identifier: AGPL-3.0-only
// The last step of Connect says what to do now. An app that reads its MCP settings only when it starts (Claude
// Desktop) is restarted on the owner's click: quit (its own Quit), then open, in that order; or opened when it is
// not running; nothing is touched when the owner restarts it by hand. Then the exact question to ask, and the status
// turns to Connected when the daemon reports the binding. A CLI is simply started again; an app connected through its
// own install link needs no restart.

import 'package:antenna_desktop/host/app_connect.dart';
import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/ui/app.dart';
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
const _home = '/Users/owner';
const _claude = '/Applications/Claude.app';

Future<(AppModel, FakeDaemon, FakeAppLauncher)> _setup(WidgetTester t, {Set<String> running = const {}}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
  final launcher = FakeAppLauncher()..running.addAll(running);
  final computer = FakeAgentComputer(
    macos: true,
    installed: const {_claude, '/Applications/Visual Studio Code.app', '/opt/homebrew/bin/gemini'},
    env: const {'HOME': _home, 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
  );
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: computer.host,
    defaultSocket: d.socketPath,
    connectorFs: FakeConnectorFs(),
    appLauncher: launcher,
  );
  await m.connect();
  t.view.physicalSize = const Size(1440, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(rolePreset: RolePreset.assistant)));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('agents-button')));
  await _settle(t);
  return (m, d, launcher);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}

/// Connect [app] up to the last step: the password, then Write (or Open for an install link).
Future<void> _connect(WidgetTester t, FakeDaemon d, String app) async {
  await _tap(t, find.byKey(Key('app-connect-$app')));
  await t.enterText(find.byKey(const Key('owner-password')), d.password);
  await _tap(t, find.byKey(const Key('connect-continue')));
  await _tap(t, find.byKey(const Key('connect-write')));
}

Finder _live(Key k) => find.descendant(of: find.byKey(const Key('connect-live-status')), matching: find.byKey(k));

/// The daemon binds the agent's token to the app's MCP server and says so with an `agent` event.
void _bind(AppModel m, FakeDaemon d, String agent) {
  d.agentList = [
    for (final a in d.agentList)
      a.name == agent
          ? AgentInfo(
              name: a.name,
              createdMs: a.createdMs,
              localLevel: a.localLevel,
              links: a.links,
              boundPid: 4242,
              boundComm: 'Claude',
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
  testWidgets('Claude Desktop running: Restart quits it, then opens it; then the question; bound → Connected',
      (t) async {
    final (m, d, launcher) = await _setup(t, running: {_claude});
    await _connect(t, d, 'claudeDesktop');
    expect(find.text(en.connectDone('Claude Desktop')), findsOneWidget);
    expect(find.text(en.connectRestartRunning('Claude Desktop')), findsOneWidget);
    expect(find.byKey(const Key('connect-restart')), findsOneWidget);
    expect(find.text(en.connectRestartNow('Claude Desktop')), findsOneWidget);
    expect(find.byKey(const Key('connect-ask')), findsNothing, reason: 'one step at a time');
    expect(launcher.appCalls, isEmpty, reason: 'nothing happens before the click');

    await _tap(t, find.byKey(const Key('connect-restart')));
    expect(launcher.appCalls, ['quit:$_claude', 'open:$_claude'], reason: 'quit first, then open');
    expect(find.byKey(const Key('connect-restarted')), findsOneWidget);
    expect(find.byKey(const Key('connect-ask')), findsOneWidget);
    expect(find.text(en.connectAskChat('Claude Desktop')), findsOneWidget);
    expect(find.text('“${en.connectAskPrompt}”'), findsOneWidget);
    expect(find.text('“Check my Antenna messages”'), findsOneWidget);
    expect(_live(const Key('status-waiting')), findsOneWidget);
    expect(find.text(en.connectWaitingFirstCall('Claude Desktop')), findsOneWidget);

    // The new chat calls Antenna: the daemon binds the token and tells the window.
    _bind(m, d, 'claude-desktop');
    await _settle(t);
    expect(_live(const Key('status-connected')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('connect-live-status')), matching: find.byIcon(Icons.check_circle_rounded)),
        findsOneWidget, reason: 'Connected ✓');
  });

  testWidgets('Claude Desktop not running: Open opens it and never quits anything', (t) async {
    final (_, d, launcher) = await _setup(t);
    await _connect(t, d, 'claudeDesktop');
    expect(find.text(en.connectNotRunning('Claude Desktop')), findsOneWidget);
    expect(find.byKey(const Key('connect-restart')), findsNothing);
    await _tap(t, find.byKey(const Key('connect-open-app')));
    expect(launcher.appCalls, ['open:$_claude']);
    expect(find.byKey(const Key('connect-opened')), findsOneWidget);
    expect(find.byKey(const Key('connect-ask')), findsOneWidget);
  });

  testWidgets('"I\'ll restart it myself": the window touches nothing and shows what to do', (t) async {
    final (_, d, launcher) = await _setup(t, running: {_claude});
    await _connect(t, d, 'claudeDesktop');
    await _tap(t, find.byKey(const Key('connect-restart-skip')));
    expect(launcher.appCalls, isEmpty);
    expect(launcher.running, {_claude}, reason: 'still running: not quit');
    expect(find.text(en.connectRestartByHand('Claude Desktop')), findsOneWidget);
    expect(find.byKey(const Key('connect-ask')), findsOneWidget);
  });

  testWidgets('macOS does not let Antenna quit it: the owner is told, and Open is still there', (t) async {
    final (_, d, launcher) = await _setup(t, running: {_claude});
    launcher.quitResult = AppQuitResult.notAllowed;
    await _connect(t, d, 'claudeDesktop');
    await _tap(t, find.byKey(const Key('connect-restart')));
    expect(launcher.appCalls, ['quit:$_claude'], reason: 'not opened while it may still run');
    expect(find.text(en.connectQuitNotAllowed('Claude Desktop')), findsOneWidget);
    expect(find.byKey(const Key('connect-ask')), findsOneWidget);
    await _tap(t, find.byKey(const Key('connect-open-app')));
    expect(launcher.appCalls, ['quit:$_claude', 'open:$_claude']);
  });

  testWidgets('the app keeps running (it asked something): no open, the owner quits it', (t) async {
    final (_, d, launcher) = await _setup(t, running: {_claude});
    launcher.quitResult = AppQuitResult.stillRunning;
    await _connect(t, d, 'claudeDesktop');
    await _tap(t, find.byKey(const Key('connect-restart')));
    expect(launcher.appCalls, ['quit:$_claude']);
    expect(find.text(en.connectQuitStillRunning('Claude Desktop')), findsOneWidget);
  });

  testWidgets('where the window cannot tell whether it runs: restart by hand, no buttons', (t) async {
    final (_, d, launcher) = await _setup(t);
    launcher.canTell = false;
    await _connect(t, d, 'claudeDesktop');
    expect(find.text(en.connectRestartByHand('Claude Desktop')), findsOneWidget);
    expect(find.byKey(const Key('connect-restart')), findsNothing);
    expect(find.byKey(const Key('connect-open-app')), findsNothing);
    expect(find.byKey(const Key('connect-ask')), findsOneWidget);
  });

  testWidgets('Gemini CLI: start it again, then the question; no restart buttons', (t) async {
    final (_, d, launcher) = await _setup(t);
    await _connect(t, d, 'geminiCli');
    expect(find.text(en.connectRestartCli('Gemini CLI')), findsOneWidget);
    expect(find.byKey(const Key('connect-restart')), findsNothing);
    expect(find.text(en.connectAskCli('Gemini CLI')), findsOneWidget);
    expect(launcher.appCalls, isEmpty);
  });

  testWidgets('VS Code through its install link: no restart step, only the question', (t) async {
    final (_, d, launcher) = await _setup(t);
    await _connect(t, d, 'vscode');
    expect(launcher.urls.single, startsWith('vscode:mcp/install?'));
    expect(find.byKey(const Key('connect-restart')), findsNothing);
    expect(find.textContaining('reads its settings'), findsNothing);
    expect(find.text(en.connectAskChat('VS Code')), findsOneWidget);
    expect(launcher.appCalls, isEmpty);
  });
}
