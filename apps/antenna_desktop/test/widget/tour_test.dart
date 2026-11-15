// SPDX-License-Identifier: AGPL-3.0-only
// The first-run tour (D-151): a new node (no contacts, no agents) lands in it after the first unlock; Skip and Escape
// close it and it never comes back by itself; a node already in use never gets it (and is settled at once); Settings →
// Help shows it again. The AI apps step points at the real button of the app found here, and a press there moves on.

import 'dart:convert';
import 'dart:io';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/ai_apps.dart';
import 'package:antenna_desktop/state/ai_apps_model.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/tour.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

FakeAgentComputer _mac(Set<String> installed) => FakeAgentComputer(
      macos: true,
      installed: installed,
      env: const {'HOME': _home, 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    );

AgentInfo _agent(String name) => AgentInfo(
      name: name,
      createdMs: 0,
      localLevel: 5,
      tokenFile: '$_home/.local/share/antenna/agents/$name.token',
      tasksFrom: const [],
    );

/// A node with [contacts] and [agents], unlocked; a Mac with [installed] apps when given.
Future<(AppModel, FakeDaemon)> _model({
  List<ContactInfo> contacts = const [],
  List<AgentInfo> agents = const [],
  Set<String>? installed,
  DaemonState state = DaemonState.unlocked,
}) async {
  final d = FakeDaemon(contacts: contacts, history: demoHistory(), state: state)..agentList = [...agents];
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    defaultSocket: d.socketPath,
    agentHost: installed == null ? null : _mac(installed).host,
    connectorFs: FakeConnectorFs(),
    appLauncher: FakeAppLauncher(),
  );
  await m.connect();
  return (m, d);
}

AppearanceStore _store() {
  final dir = Directory.systemTemp.createTempSync('antenna-tour-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return AppearanceStore('${dir.path}/window.json');
}

Map<String, Object?> _file(AppearanceStore s) => json.decode(File(s.path).readAsStringSync()) as Map<String, Object?>;

Future<void> _start(WidgetTester t, AppModel m, Appearance look, {Size size = const Size(1440, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  // A new window, not the last one's state with another model.
  await t.pumpWidget(const SizedBox.shrink());
  await t.pumpWidget(XApp(model: m, appearance: look));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(Key(key)));
  await _settle(t);
}

final _line = find.byKey(const Key('tour-line'));

String? _lineText(WidgetTester t) => _line.evaluate().isEmpty ? null : t.widget<Text>(_line).data;

void main() {
  testWidgets('a new node lands in the tour; it walks the real screens; Skip closes it for good', (t) async {
    final store = _store();
    final (m, _) = await _model(installed: const {'/Users/owner/.local/bin/claude'});
    await _start(t, m, Appearance.load(store));

    // Step 1: the chat list.
    expect(find.byKey(const Key('tour-chats')), findsOneWidget);
    expect(_lineText(t), en.tourChats);
    expect(t.widget<Text>(find.byKey(const Key('tour-count'))).data, en.tourStepOf(1, 3));
    expect(find.byKey(const Key('tour-skip')), findsOneWidget);
    expect(_file(store)['tour_seen'], isTrue, reason: 'remembered as soon as it shows');

    // Step 2: Agents → AI apps, pointing at Claude Code's own button.
    await _tap(t, 'tour-next');
    expect(find.byKey(const Key('ai-apps')), findsOneWidget, reason: 'the step opens the Agents section');
    expect(_lineText(t), en.tourAppsPress(en.appsStartCode, 'Claude Code'));
    expect(en.tourAppsPress(en.appsStartCode, 'Claude Code'), 'Press Start in Code mode next to Claude Code');
    expect(find.byKey(const Key('app-start-claudeCode')), findsOneWidget);
    // The tour takes no clicks but its own: the real button under the ring opens its dialog.
    await _tap(t, 'app-start-claudeCode');
    expect(find.byKey(const Key('code-start-go')), findsOneWidget);
    // Escape belongs to the dialog while it is open, not to the tour.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(t);
    expect(find.byKey(const Key('tour-aiApps')), findsOneWidget);
    if (find.byKey(const Key('code-start-go')).evaluate().isNotEmpty) {
      await t.tap(find.text(en.commonCancel));
      await _settle(t);
    }
    expect(find.byKey(const Key('code-start-go')), findsNothing);
    expect(find.byKey(const Key('tour-aiApps')), findsOneWidget, reason: 'nothing was started: the step stays');

    // Skip: gone, and not back on the next start.
    await _tap(t, 'tour-skip');
    expect(_line, findsNothing);
    final (m2, _) = await _model(installed: const {'/Users/owner/.local/bin/claude'});
    await _start(t, m2, Appearance.load(store));
    expect(_line, findsNothing);
  });

  testWidgets('Next to the end: no AI app here says how to get one; the last step points at Invite', (t) async {
    final store = _store();
    final (m, _) = await _model(installed: const {});
    await _start(t, m, Appearance.load(store));
    await _tap(t, 'tour-next');
    expect(_lineText(t), en.tourAppsNone);
    await _tap(t, 'tour-next');
    expect(find.byKey(const Key('tour-invite')), findsOneWidget);
    expect(_lineText(t), en.tourInvite);
    expect(find.byKey(const Key('first-invite')), findsOneWidget, reason: 'the step opens Chats with Invite');
    expect(find.text(en.commonDone), findsOneWidget, reason: 'the last step says Done');
    await _tap(t, 'tour-next');
    expect(_line, findsNothing);
  });

  testWidgets('Escape closes the tour', (t) async {
    final (m, _) = await _model();
    await _start(t, m, Appearance.load(_store()));
    expect(_line, findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(t);
    expect(_line, findsNothing);
  });

  testWidgets('connecting an app on the AI apps step moves the tour on', (t) async {
    final (m, d) = await _model(installed: const {'/Users/owner/.local/bin/claude'});
    await _start(t, m, Appearance.load(_store()));
    await _tap(t, 'tour-next');
    expect(find.byKey(const Key('tour-aiApps')), findsOneWidget);
    // An agent appears (as Connect makes one) while no dialog is open: the next step.
    d.agentList = [_agent('claude-code')];
    await m.refreshAgents();
    await _settle(t);
    expect(find.byKey(const Key('tour-invite')), findsOneWidget);
  });

  testWidgets('a node in use never gets the tour, and is settled at once', (t) async {
    final store = _store();
    final (m, _) = await _model(contacts: demoContacts());
    final look = settledLook(store);
    await _start(t, m, look);
    expect(_line, findsNothing);
    expect(look.tourDue, isFalse);
    expect(_file(store)['tour_seen'], isTrue);

    final store2 = _store();
    final (m2, _) = await _model(agents: [_agent('build-bot')]);
    final look2 = Appearance.load(store2);
    await _start(t, m2, look2);
    expect(_line, findsNothing, reason: 'an agent and no contacts is a node in use too');
    expect(look2.tourDue, isFalse);
  });

  testWidgets('the tour waits for the unlock; without a settings file it does not start by itself', (t) async {
    final store = _store();
    final (m, d) = await _model(state: DaemonState.locked);
    final look = Appearance.load(store);
    await _start(t, m, look);
    expect(_line, findsNothing);
    expect(look.tourDue, isTrue);
    expect(await m.unlock(d.password), isNull);
    await _settle(t);
    expect(_line, findsOneWidget);

    final (m2, _) = await _model();
    await _start(t, m2, Appearance());
    expect(_line, findsNothing);
  });

  testWidgets('Settings → Help shows the tour again', (t) async {
    final (m, _) = await _model(contacts: demoContacts());
    await _start(t, m, settledLook(_store()));
    expect(_line, findsNothing);
    await _tap(t, 'nav-settings');
    await _tap(t, 'settings-help');
    expect(find.text(en.settingsTourShow), findsOneWidget);
    await _tap(t, 'tour-show');
    expect(find.byKey(const Key('tour-chats')), findsOneWidget);
    expect(find.byKey(const Key('nav-settings')), findsOneWidget);
    expect(_lineText(t), en.tourChats);
  });

  testWidgets('a narrow window points at New contact on the last step', (t) async {
    final (m, _) = await _model();
    await _start(t, m, Appearance.load(_store()), size: const Size(820, 700));
    await _tap(t, 'tour-next');
    await _tap(t, 'tour-next');
    expect(find.byKey(const Key('tour-invite')), findsOneWidget);
    expect(find.byKey(const Key('new-link')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test('the app the tour points at: Claude Code first, then Codex, then the first found app not connected', () {
    AiAppRow row(AiApp id, {bool found = true}) =>
        AiAppRow(aiAppDef(id), foundAt: found ? '/somewhere' : null);
    final rows = [row(AiApp.chatgpt), row(AiApp.codex), row(AiApp.claudeCode), row(AiApp.zed)];
    expect(tourApp(rows, code: true)?.$1.app.id, AiApp.claudeCode);
    expect(tourApp(rows, code: true)?.$2, TourAppAction.start);
    expect(tourApp([row(AiApp.chatgpt), row(AiApp.codex)], code: true)?.$1.app.id, AiApp.codex);
    // Without Code mode (Windows), the first found app's Connect.
    expect(tourApp(rows, code: false)?.$1.app.id, AiApp.chatgpt);
    expect(tourApp(rows, code: false)?.$2, TourAppAction.connect);
    expect(tourApp([row(AiApp.claudeCode, found: false)], code: true), isNull);
    expect(freshForTour(contacts: 0, agents: 0, localAgents: 0), isTrue);
    expect(freshForTour(contacts: 0, agents: 0, localAgents: 1), isFalse);
  });
}
