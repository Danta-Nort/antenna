// SPDX-License-Identifier: AGPL-3.0-only
// The Experimental tag (D-94) wherever the window shows a mechanism of our own design: addressing and topics (the
// composer's address line, the topic menu) and task authority (the AI apps menu, Connect, "Takes tasks from…"; a
// tooltip, not a tag, on each agent's row). Every tag carries its tooltip; English and Russian. A conversation between
// two people keeps its input line without a tag.

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/widgets/experimental_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_connect.dart';
import '../support/fake_daemon.dart';
import '../support/fake_pty.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');
final ru = l10nFor('ru');

const _bins = CoreBinaries(
  daemon: '/Applications/Antenna.app/Contents/Helpers/antennad',
  cli: '/Applications/Antenna.app/Contents/Helpers/antenna',
  bundled: true,
);
const _home = '/Users/owner';

Future<void> _app(WidgetTester t, AppModel m, {double height = 1000}) async {
  t.view.physicalSize = Size(1440, height);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: Appearance(rolePreset: RolePreset.assistant)));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _tapVisible(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> _russian(WidgetTester t) async {
  t.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
  addTearDown(t.platformDispatcher.clearLocalesTestValue);
  await _settle(t);
}

/// The tag under [key]: its word and its tooltip in [l].
void _expectTag(WidgetTester t, String key, AppLocalizations l) {
  final tag = find.byKey(Key(key));
  expect(tag, findsOneWidget, reason: key);
  expect(t.widget(tag), isA<ExperimentalTag>());
  expect(find.descendant(of: tag, matching: find.text(l.experimentalTag)), findsOneWidget, reason: key);
  expect(t.widget<Tooltip>(find.descendant(of: tag, matching: find.byType(Tooltip))).message, l.experimentalTip,
      reason: key);
}

Future<AppModel> _team() async {
  final d = FakeDaemon(
    contacts: [jordanTeam, emily, buildBot, ryan, rachel],
    history: {...demoHistory(), jordanTeam.linkId: teamHistory()},
  );
  d.topicMap[jordanTeam.linkId] = teamTopics();
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return m;
}

/// A Mac with the ChatGPT app; its agent `chatgpt` takes tasks from Build bot.
Future<AppModel> _apps() async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..agentList = [
      AgentInfo(
        name: 'chatgpt',
        createdMs: 0,
        localLevel: 5,
        tokenFile: '$_home/.local/share/antenna/agents/chatgpt.token',
        tasksFrom: [buildBotName],
      ),
    ];
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: FakeAgentComputer(
      macos: true,
      installed: const {'/Applications/ChatGPT.app'},
      env: const {'HOME': _home, 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    ).host,
    defaultSocket: d.socketPath,
    connectorFs: FakeConnectorFs({}),
    appLauncher: FakeAppLauncher(),
  );
  await m.connect();
  return m;
}

void main() {
  testWidgets('addressing and topics: the address line and the topic menu are labelled; two people see no tag',
      (t) async {
    final m = await _team();
    // The person chat: the To line offers the person and everyone (a chat with an agent has no choice of recipient).
    await m.select(jordanTeam.linkId, chat: ThreadKey.person);
    await _app(t, m);
    _expectTag(t, 'experimental-address', en);
    expect(find.text('Experimental'), findsOneWidget);
    expect(en.experimentalTip, 'New in this preview: tested, still being reviewed.');

    // The "#" button opens the topic menu; its first line says what the menu is for and carries the tag.
    await t.tap(find.byKey(const Key('composer-topic')));
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('topic-menu-header')), matching: find.text(en.composerTopicTip)),
        findsOneWidget);
    _expectTag(t, 'experimental-topic-menu', en);
    // The header is not an item: choosing a topic still works as before.
    await t.tap(find.byKey(const Key('topic-none')).last);
    await t.pumpAndSettle();

    // A conversation between two people: no address line, no tag in the input line, the menu still says it.
    await m.select(emily.linkId);
    await _settle(t);
    expect(find.byKey(const Key('composer-to')), findsNothing);
    expect(find.byType(ExperimentalTag), findsNothing);
    await t.tap(find.byKey(const Key('composer-topic')));
    await t.pumpAndSettle();
    _expectTag(t, 'experimental-topic-menu', en);
  });

  testWidgets('addressing and topics in Russian', (t) async {
    final m = await _team();
    // The person chat: the To line offers the person and everyone (a chat with an agent has no choice of recipient).
    await m.select(jordanTeam.linkId, chat: ThreadKey.person);
    await _app(t, m);
    await _russian(t);
    _expectTag(t, 'experimental-address', ru);
    expect(find.text(ru.experimentalTag), findsOneWidget);
    expect(ru.experimentalTag, isNot(en.experimentalTag));
    await t.tap(find.byKey(const Key('composer-topic')));
    await t.pumpAndSettle();
    _expectTag(t, 'experimental-topic-menu', ru);
  });

  testWidgets('task authority: the AI apps menu, "Takes tasks from…", Connect; a tooltip on the agent row', (t) async {
    final m = await _apps();
    await _app(t, m, height: 1100);
    await t.tap(find.byKey(const Key('agents-button')));
    await _settle(t);

    // The agent's row: whose tasks it takes, with a tooltip rather than a tag on every row.
    final row = find.byKey(const Key('agent-row-chatgpt'));
    expect(find.descendant(of: row, matching: find.byType(ExperimentalTag)), findsNothing);
    expect(
      t.widget<Tooltip>(find.ancestor(of: find.byKey(const Key('agent-tasks-chatgpt')), matching: find.byType(Tooltip)).first)
          .message,
      '${en.experimentalTag} · ${en.experimentalTip}',
    );
    expect(find.byTooltip('Takes tasks from… · Experimental'), findsOneWidget);

    // AI apps → ⋯ → "Takes tasks from…" carries the tag, and so does the dialog it opens.
    await _tapVisible(t, find.byKey(const Key('app-menu-chatgpt')));
    _expectTag(t, 'experimental-app-menu-chatgpt', en);
    await _tapVisible(t, find.byKey(const Key('app-menu-tasks-chatgpt')).last);
    _expectTag(t, 'experimental-tasks-dialog', en);
    expect(find.textContaining('Whose messages are tasks for “chatgpt”'), findsOneWidget);
    await _russian(t);
    _expectTag(t, 'experimental-tasks-dialog', ru);
    await t.tap(find.text(ru.commonCancel));
    await t.pumpAndSettle();

    // Connect: the line "This agent will do tasks from: …" carries the tag.
    t.platformDispatcher.clearLocalesTestValue();
    await _settle(t);
    await _tapVisible(t, find.byKey(const Key('app-connect-geminiCli')));
    expect(find.byKey(const Key('connect-tasks-text')), findsOneWidget);
    _expectTag(t, 'experimental-connect-tasks', en);
  });
}
