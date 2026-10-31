// SPDX-License-Identifier: AGPL-3.0-only
// A resident agent's session in the window (PG-23; x-control/6, CONTROL §21; parked: D-121) on the fake daemon: the
// rule's card shows the session's state and counters, its taint and that it is parked; Compact and Stop go to the
// daemon; Reset asks for the password; Talk sends the owner's words and streams the answer, or sends it to the
// contact; a one-shot rule and an older daemon show none of it.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

const _session = ResidentInfo(
  state: ResidentState.sleeping,
  sessionId: 'c0ffee00-1111-4222-8333-444455556666',
  turns: 14,
  ownerTurns: 3,
  starts: 4,
  inputTokens: 1200,
  outputTokens: 5400,
  cacheReadTokens: 410000,
  contextTokens: 38200,
  costMicroUsd: 1840000,
  compactions: 1,
  ceiling: 3,
  idleStopSecs: 3600,
  parked: true,
);

WakeRuleInfo _rule({ResidentInfo? resident = _session}) => WakeRuleInfo(
      contact: jordan.label,
      linkId: jordan.linkId,
      agent: 'wake-jordan',
      argv: const ['/usr/local/bin/claude', '-p', '--output-format', 'stream-json'],
      mode: 'claude_stream',
      timeoutSecs: 600,
      maxRunsPerHour: 60,
      resident: resident,
    );

Future<(AppModel, FakeDaemon)> _model({ResidentInfo? resident = _session}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())..wakeRuleList = [_rule(resident: resident)];
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return (m, d);
}

Future<void> _agents(WidgetTester t, AppModel m) async {
  t.view.physicalSize = const Size(1440, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.byKey(const Key('agents-button')));
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester t, Key k) async {
  await t.ensureVisible(find.byKey(k));
  await t.pump();
  await t.tap(find.byKey(k));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  final who = jordan.label;

  testWidgets('the card: state, counters, taint and that it sleeps in the encrypted database', (t) async {
    final (m, _) = await _model();
    await _agents(t, m);
    final block = find.byKey(Key('resident-$who'));
    await t.ensureVisible(block);
    expect(find.descendant(of: block, matching: find.text(en.residentStateSleeping)), findsOneWidget);
    final facts = t.widget<Text>(find.byKey(Key('resident-facts-$who'))).data!;
    expect(facts, contains(en.residentCounters(14, 3, 4)));
    expect(facts, contains(en.residentTokens(38200, 1200, 5400, 410000)));
    expect(facts, contains(en.residentCost('1.84')));
    expect(facts, contains(en.residentCompactions(1)));
    expect(find.text(en.residentCeiling(3)), findsOneWidget);
    expect(find.byKey(Key('resident-parked-$who')), findsOneWidget);
    // Asleep: nothing to stop
    expect(t.widget<TextButton>(find.byKey(Key('resident-stop-$who'))).onPressed, isNull);
  });

  testWidgets('Compact and Stop go to the daemon; Reset asks for the password', (t) async {
    final (m, d) = await _model(resident: const ResidentInfo(
      state: ResidentState.idle,
      sessionId: 'c0ffee00-1111-4222-8333-444455556666',
      turns: 2,
      starts: 1,
      contextTokens: 52000,
    ));
    await _agents(t, m);
    await _tap(t, Key('resident-compact-$who'));
    expect(d.wakeSessions.last.$2, ResidentAction.compact);
    expect(t.widget<Text>(find.byKey(Key('resident-facts-$who'))).data, contains(en.residentCompactions(1)));
    await _tap(t, Key('resident-stop-$who'));
    expect(d.wakeSessions.last.$2, ResidentAction.stop);
    expect(find.descendant(of: find.byKey(Key('resident-$who')), matching: find.text(en.residentStateSleeping)),
        findsOneWidget);
    await _tap(t, Key('resident-reset-$who'));
    expect(find.text(en.residentResetTitle('wake-jordan')), findsOneWidget);
    await t.enterText(find.byKey(const Key('owner-password')), 'wrong');
    await t.tap(find.byKey(const Key('resident-reset-do')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.residentResetTitle('wake-jordan')), findsOneWidget, reason: 'a wrong password keeps it open');
    await t.enterText(find.byKey(const Key('owner-password')), d.password);
    await t.tap(find.byKey(const Key('resident-reset-do')));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 600));
    expect(d.wakeSessions.last, (jordan.linkId, ResidentAction.reset, d.password));
    expect(find.text(en.residentResetTitle('wake-jordan')), findsNothing);
    expect(find.text(en.residentNoSession), findsOneWidget);
  });

  testWidgets('Talk: the owner\'s words go as the owner\'s, the answer streams in; or the answer goes to the contact',
      (t) async {
    final (m, d) = await _model();
    await _agents(t, m);
    await _tap(t, Key('resident-talk-$who'));
    expect(find.text(en.residentTalkTitle('wake-jordan')), findsOneWidget);
    await t.enterText(find.byKey(const Key('resident-text')), 'What did we decide about the release?');
    await t.tap(find.byKey(const Key('resident-send')));
    await t.pump();
    final (contact, text, toContact, dialog) = d.wakeSays.single;
    expect((contact, text, toContact), (jordan.linkId, 'What did we decide about the release?', false));
    expect(find.text(en.residentAnswering), findsOneWidget);
    dialog.emit(ResidentDeltaEvent(contact: who, turn: 15, delta: 'We decided '));
    await t.pump();
    dialog.emit(ResidentDeltaEvent(contact: who, turn: 15, delta: 'to ship on Friday.'));
    await t.pump();
    expect(find.text('We decided to ship on Friday.'), findsOneWidget);
    dialog.finish(ResidentTurnReply(contact: who, turn: 15, outcome: 'done', text: 'We decided to ship on Friday.'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.residentAnswering), findsNothing);
    expect(find.text('We decided to ship on Friday.'), findsOneWidget);
    // To the contact: the answer is the agent's reply there
    await t.tap(find.byKey(const Key('resident-to-contact')));
    await t.pump();
    await t.enterText(find.byKey(const Key('resident-text')), 'Tell Jordan the date.');
    await t.tap(find.byKey(const Key('resident-send')));
    await t.pump();
    final second = d.wakeSays.last;
    expect((second.$2, second.$3), ('Tell Jordan the date.', true));
    second.$4.finish(ResidentTurnReply(contact: who, turn: 16, outcome: 'done', messageId: 'abc'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text(en.residentSentToContact(who)), findsOneWidget);
  });

  testWidgets('the own-machine profile is on the card (D-122)', (t) async {
    final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
      ..wakeRuleList = [
        WakeRuleInfo.fromJson({
          'contact': jordan.label,
          'link_id': jordan.linkId,
          'agent': 'wake-jordan',
          'argv': ['/usr/local/bin/claude', '-p'],
          'mode': 'plain',
          'timeout_secs': 600,
          'max_runs_per_hour': 20,
          'project': '/home/me/code/payments',
          'tool_paths': ['/home/me/.cargo/bin', '/home/me/.rustup'],
          'env': ['RUSTUP_HOME=/home/me/.rustup'],
        }),
      ];
    final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
    await m.connect();
    await _agents(t, m);
    expect(find.textContaining(en.wakeProjectFact('/home/me/code/payments')), findsOneWidget);
    expect(find.textContaining(en.wakeToolsFact('/home/me/.cargo/bin, /home/me/.rustup')), findsOneWidget);
  });

  testWidgets('a one-shot rule and an older daemon show no session', (t) async {
    final (m, _) = await _model(resident: null);
    await _agents(t, m);
    expect(find.byKey(Key('wake-rule-$who')), findsOneWidget);
    expect(find.byKey(Key('resident-$who')), findsNothing);
  });
}
