// SPDX-License-Identifier: AGPL-3.0-only
// Conversations that read like a group chat of agents (D-UI-24), on the fake daemon:
// - my own messages carry no picture and no name; every other sender in a link where agents take part has a picture
//   beside the first bubble of its group and its name above it;
// - an agent's picture is its AI's mark only for my own agent and only from a fact the window has (a Code mode start,
//   remembered, or an AI app's configuration on this computer); otherwise a neutral monogram with the agent badge;
// - my agents that run on this computer carry "this Mac"; a contact's agent never does, even under the same name;
// - consecutive messages of one sender form a group: one name, one picture.

import 'dart:convert';

import 'package:antenna_desktop/host/binaries.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/state/appearance.dart';
import 'package:antenna_desktop/state/threads.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/widgets/ai_logo.dart';
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
const _claudeConfig = '$_home/Library/Application Support/Claude/claude_desktop_config.json';

Future<AppModel> _model(FakeDaemon d, {Map<String, String> files = const {}}) async {
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    agentHost: FakeAgentComputer(
      macos: true,
      installed: const {'/Applications/Claude.app', '$_home/.local/bin/claude'},
      env: const {'HOME': _home, 'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
    ).host,
    defaultSocket: d.socketPath,
    connectorFs: FakeConnectorFs(files),
    appLauncher: FakeAppLauncher(),
  );
  await m.connect();
  m.scanAiApps(notify: false);
  return m;
}

Future<void> _app(WidgetTester t, AppModel m, {Appearance? look}) async {
  t.view.physicalSize = const Size(1440, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, appearance: look ?? Appearance()));
  await t.pump(const Duration(milliseconds: 300));
}

Finder _key(String k) => find.byKey(Key(k));
Finder _within(Finder of, Finder f) => find.descendant(of: of, matching: f);
String idOf(int seq) => hex(seq * 7 + 3);

/// Jordan's agent `claude-backend` talks with my agents; one of mine runs here (remembered from Code mode as Claude
/// Code), another is Claude Desktop connected on this computer, a third only holds a token. The contact also has an
/// agent that calls itself `claude-code`, like my local one.
List<HistoryItem> _history() => [
      msg(70, true, 'Status of build 413?', ago(minutes: 30), viaAgent: 'claude-code', to: 'agent',
          toAgent: 'claude-backend'),
      msg(71, false, 'Green. Tests pass.', ago(minutes: 29), viaAgent: 'claude-backend', to: 'agent',
          toAgent: 'claude-code'),
      msg(72, false, 'The log is in shared/.', ago(minutes: 28), viaAgent: 'claude-backend', to: 'agent',
          toAgent: 'claude-code'),
      msg(73, false, 'And the flaky test is quarantined.', ago(minutes: 20), viaAgent: 'claude-backend', to: 'agent',
          toAgent: 'claude-code'),
      msg(74, true, 'Thanks, both of you.', ago(minutes: 19), to: 'agent', toAgent: 'claude-backend'),
      msg(75, true, 'Merged.', ago(minutes: 18), to: 'agent', toAgent: 'claude-backend'),
      msg(76, true, 'Drafts attached.', ago(minutes: 17), viaAgent: 'claude-desktop', to: 'agent',
          toAgent: 'claude-backend'),
      msg(77, true, 'Nightly report sent.', ago(minutes: 16), viaAgent: 'reporter', to: 'agent',
          toAgent: 'claude-backend'),
    ];

ContactInfo get _jordan => contact(jordanName, 23, peerKind: 'mixed', agents: [
      PeerAgent(name: 'claude-backend', state: 'active', sinceMs: ms(ago(days: 2))),
      PeerAgent(name: 'claude-code', state: 'active', sinceMs: ms(ago(days: 2))),
    ]);

Future<AppModel> _setup(WidgetTester t, {List<HistoryItem>? history}) async {
  final d = FakeDaemon(contacts: [_jordan, emily], history: {_jordan.linkId: history ?? _history()})
    ..agentList = [
      const AgentInfo(name: 'claude-code', createdMs: 0, localLevel: 5),
      const AgentInfo(name: 'claude-desktop', createdMs: 0, localLevel: 5),
      const AgentInfo(name: 'reporter', createdMs: 0, localLevel: 3),
    ];
  final m = await _model(d, files: {
    _claudeConfig: jsonEncode({
      'mcpServers': {
        'antenna': {'command': _bins.cli, 'args': ['mcp', '--token-file', '/x/claude-desktop.token']},
      },
    }),
  });
  await m.refreshAgents();
  await m.select(_jordan.linkId);
  await _app(t, m, look: Appearance(agentRuns: {
    'claude-code': {'cli': 'claude', 'dir': '$_home/app'},
  }));
  // This group reads the whole thread, not the default "With me" filter of an agent's chat (D-UI-44).
  await t.tap(_key('thread-filter-all'));
  await t.pump(const Duration(milliseconds: 300));
  return m;
}

void main() {
  group('a group of bubbles', () {
    ChatEntry e(int minutes, {bool out = false, String? via, String? to, String? toAgent, DateTime? at}) => ChatEntry(
          id: 'x$minutes',
          kind: out ? EntryKind.outgoing : EntryKind.incoming,
          text: 't',
          at: at ?? fixedNow.add(Duration(minutes: minutes)),
          viaAgent: via,
          to: to,
          toAgent: toAgent,
        );

    test('continues for the same sender and addressee within 3 minutes on the same day', () {
      expect(continuesGroup(e(0, via: 'a'), e(2, via: 'a')), isTrue);
      expect(continuesGroup(null, e(0)), isFalse, reason: 'the first message starts a group');
      expect(continuesGroup(e(0, via: 'a'), e(1, via: 'b')), isFalse, reason: 'another agent');
      expect(continuesGroup(e(0, via: 'a'), e(1)), isFalse, reason: 'the person after their agent');
      expect(continuesGroup(e(0), e(1, out: true)), isFalse, reason: 'the other side');
      expect(continuesGroup(e(0, out: true), e(1, out: true, via: 'mine')), isFalse, reason: 'my agent after me');
      expect(continuesGroup(e(0, to: 'person'), e(1, to: 'everyone')), isFalse, reason: 'another addressee');
      expect(continuesGroup(e(0, to: 'agent', toAgent: 'a'), e(1, to: 'agent', toAgent: 'b')), isFalse);
      expect(continuesGroup(e(0), e(3)), isFalse, reason: '3 minutes apart');
      expect(continuesGroup(e(0), e(1), prevIsFile: true), isFalse, reason: 'a file card between');
      final late = DateTime(2026, 10, 2, 23, 59);
      expect(continuesGroup(e(0, at: late), e(0, at: late.add(const Duration(minutes: 2)))), isFalse,
          reason: 'past midnight a day divider stands between');
    });
  });

  testWidgets('my own messages: no picture and no name; every other sender: both, once per group', (t) async {
    await _setup(t);
    // Mine (74, 75): no avatar, no author line, as in any messenger.
    for (final s in [74, 75]) {
      expect(_key('avatar-${idOf(s)}'), findsNothing, reason: 'my message $s');
      expect(_key('author-${idOf(s)}'), findsNothing, reason: 'my message $s');
    }
    expect(find.text(en.authorYou), findsNothing);
    // claude-backend wrote 71, 72 within 3 minutes: one group, one name and one picture; 73 came 8 minutes later.
    expect(_key('avatar-${idOf(71)}'), findsOneWidget);
    expect(_key('author-${idOf(71)}'), findsOneWidget);
    expect(_key('avatar-${idOf(72)}'), findsNothing);
    expect(_key('author-${idOf(72)}'), findsNothing);
    expect(_key('avatar-${idOf(73)}'), findsOneWidget, reason: 'a new group after a pause');
    // A grouped bubble keeps the picture's column: it starts where the group's first bubble starts.
    final first = t.getTopLeft(find.text('Green. Tests pass.')).dx;
    expect(t.getTopLeft(find.text('The log is in shared/.')).dx, first);
    // My agents' pictures stand on my side (right of their bubbles), the contact's on theirs.
    expect(t.getCenter(_key('avatar-${idOf(70)}')).dx, greaterThan(t.getCenter(find.text('Status of build 413?')).dx));
    expect(t.getCenter(_key('avatar-${idOf(71)}')).dx, lessThan(t.getCenter(find.text('Green. Tests pass.')).dx));
  });

  testWidgets('pictures: the AI mark only for my agent the window knows; a neutral monogram otherwise', (t) async {
    await _setup(t);
    // claude-code: remembered as started with Claude Code here.
    expect(_within(_key('avatar-${idOf(70)}'), _key('ai-logo-claudecode')), findsOneWidget);
    // claude-desktop: Claude Desktop's configuration on this computer names it.
    expect(_within(_key('avatar-${idOf(76)}'), _key('ai-logo-claude')), findsOneWidget);
    // reporter: only a token; nothing known about its AI.
    expect(_within(_key('avatar-${idOf(77)}'), _key('agent-mark-generic')), findsOneWidget);
    expect(_within(_key('avatar-${idOf(77)}'), find.byType(AiLogo)), findsNothing);
    // The contact's agents: neutral, whatever they are called.
    expect(_within(_key('avatar-${idOf(71)}'), _key('agent-mark-generic')), findsOneWidget);
    expect(_within(_key('avatar-${idOf(71)}'), find.byType(AiLogo)), findsNothing);
  });

  testWidgets('"this Mac" for my agents that run here, never for a contact\'s agent of the same name', (t) async {
    await _setup(t, history: [
      ..._history(),
      // The contact's agent calls itself claude-code, like mine.
      msg(78, false, 'I am claude-code too.', ago(minutes: 10), viaAgent: 'claude-code', to: 'agent',
          toAgent: 'claude-code'),
    ]);
    final mac = en.authorThisMac;
    // The latest message opened the contact's claude-code chat; the chat with claude-backend first. Each chat reads
    // its own whole thread here, not the default "With me" filter of D-UI-44.
    await t.tap(_key('chat-Jordan Lee-agent-claude-backend'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(_key('thread-filter-all'));
    await t.pump(const Duration(milliseconds: 300));
    expect(_within(_key('author-${idOf(70)}'), find.text(mac)), findsOneWidget, reason: 'started here in Code mode');
    expect(_within(_key('author-${idOf(76)}'), find.text(mac)), findsOneWidget, reason: 'an app configured here');
    expect(_key('this-computer-${idOf(77)}'), findsNothing, reason: 'only a token: where it runs is not known');
    expect(_key('this-computer-${idOf(71)}'), findsNothing, reason: "the contact's agent");
    await t.tap(_key('chat-Jordan Lee-agent-claude-code'));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(_key('thread-filter-all'));
    await t.pump(const Duration(milliseconds: 300));
    expect(_key('avatar-${idOf(78)}'), findsOneWidget);
    expect(_key('this-computer-${idOf(78)}'), findsNothing, reason: 'a name proves nothing');
    expect(_within(_key('avatar-${idOf(78)}'), find.byType(AiLogo)), findsNothing);
    expect(find.text(mac), findsNothing);
  });

  testWidgets('a conversation between two people keeps unsigned bubbles without pictures', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory());
    final m = await _model(d);
    await m.select(emily.linkId);
    await _app(t, m);
    bool keyed(Widget w, String prefix) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix);
    expect(find.text('Hi! I\'m not on my phone yet — writing from the laptop.'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => keyed(w, 'avatar-')), findsNothing);
    expect(find.byWidgetPredicate((w) => keyed(w, 'author-')), findsNothing);
  });
}
