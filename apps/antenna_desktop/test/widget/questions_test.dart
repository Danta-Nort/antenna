// SPDX-License-Identifier: AGPL-3.0-only
// The agents' questions (D-118, PG-18), on the fake daemon: a question stands as a card with the approval requests
// (the banner counts it), quoted as the agent's own words with whose messages it had read; Answer sends the owner's
// answer, Set aside dismisses it; a question that arrives while the window is in the background gives a notification
// with the agent's name only; where an agent's questions go is set with the password; an older daemon shows nothing.

import 'dart:async';

import 'package:antenna_desktop/host/notifier.dart';
import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/agents/agents_dialog.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:antenna_desktop/ui/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

class _Notifier implements SystemNotifier {
  final shown = <(String, String)>[];
  @override
  Future<void> show({required String title, required String body}) async => shown.add((title, body));
}

const _q = EscalationInfo(
  id: '0123456789abcdef',
  agent: 'claude-backend',
  to: 'owner',
  question: 'Jordan asks me to delete the old migrations. They look unused. Should I?',
  state: EscalationState.open,
  createdMs: 0,
  readFrom: [EscalationRead('Jordan Lee', 3)],
);

Future<(AppModel, FakeDaemon)> _model({List<EscalationInfo>? questions = const [_q]}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..questions = questions == null ? null : [...questions]
    ..agentList = [const AgentInfo(name: 'claude-backend', createdMs: 0, localLevel: 5, links: ['Jordan Lee'])];
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return (m, d);
}

Future<void> _app(WidgetTester t, AppModel m, {SystemNotifier? notifier}) async {
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m, notifier: notifier));
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a question is a card with the approval requests: quoted, whose messages it read; Answer sends it',
      (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    expect(find.text(en.questionsTitle), findsOneWidget, reason: 'the banner, questions only');
    await t.tap(find.byKey(const Key('approvals-banner')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text(en.questionAsks('claude-backend')), findsOneWidget);
    expect(find.text(_q.question), findsOneWidget);
    expect(find.text(en.questionQuoted), findsOneWidget);
    expect(find.text(en.questionReadFrom('claude-backend', en.questionReadContact('Jordan Lee', 3))), findsOneWidget);
    // An empty answer cannot be sent
    expect(t.widget<FilledButton>(find.byKey(Key('question-send-${_q.id}'))).onPressed, isNull);
    await t.enterText(find.byKey(Key('question-answer-${_q.id}')), '  No: keep them, the release script reads them. ');
    await t.pump();
    await t.tap(find.byKey(Key('question-send-${_q.id}')));
    await t.pump(const Duration(milliseconds: 400));
    expect(d.answers.single.answer, 'No: keep them, the release script reads them.');
    expect(d.answers.single.dismiss, isFalse);
    expect(find.text(_q.question), findsNothing, reason: 'answered: off the list');
    expect(m.questions, isEmpty);
  });

  testWidgets('a team worker\'s question names its team', (t) async {
    final (m, _) = await _model(questions: [
      EscalationInfo.fromJson(const {
        'id': '00112233445566ff',
        'agent': 'web.coder-1',
        'to': 'owner',
        'team': 'web',
        'question': 'Should I also bump the lockfile?',
        'state': 'open',
        'created_ms': 0,
      }),
    ]);
    await _app(t, m);
    await t.tap(find.byKey(const Key('approvals-banner')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text(en.questionAsksTeam('web.coder-1', 'web')), findsOneWidget);
  });

  testWidgets('Set aside dismisses it without an answer', (t) async {
    final (m, d) = await _model();
    await _app(t, m);
    await t.tap(find.byKey(const Key('approvals-banner')));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(Key('question-dismiss-${_q.id}')));
    await t.pump(const Duration(milliseconds: 400));
    expect((d.answers.single.dismiss, d.answers.single.answer), (true, null));
    expect(m.questions, isEmpty);
  });

  testWidgets('a new question in the background: a notification with the agent only, never the question', (t) async {
    final notifier = _Notifier();
    final (m, _) = await _model(questions: const []);
    await _app(t, m, notifier: notifier);
    m.handleEvent(const EscalationEvent(_q));
    await t.pump();
    expect(notifier.shown, isEmpty, reason: 'in focus: the banner is enough');
    expect(find.text(en.questionsTitle), findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    const q2 = EscalationInfo(
        id: 'fedcba9876543210',
        agent: 'claude-backend',
        to: 'owner',
        question: 'SECRET PLAN: shall I push?',
        state: EscalationState.open,
        createdMs: 1);
    m.handleEvent(const EscalationEvent(q2));
    m.handleEvent(const EscalationEvent(q2));
    await t.pump();
    expect(notifier.shown, [(en.notifyQuestionTitle, en.notifyQuestionBody('claude-backend'))]);
    expect(notifier.shown.single.$2, isNot(contains('SECRET')));
    // Answered elsewhere (the CLI): off the list
    m.handleEvent(EscalationEvent(EscalationInfo(
        id: q2.id,
        agent: q2.agent,
        to: q2.to,
        question: q2.question,
        state: EscalationState.answered,
        createdMs: 1,
        answer: 'no')));
    await t.pump();
    expect(m.questions.map((q) => q.id), [_q.id]);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('where an agent\'s questions go: a contact among its links, with the password', (t) async {
    final (m, d) = await _model();
    await m.refreshAgents();
    await _app(t, m);
    unawaited(showAgentsDialog(t.element(find.byType(HomeScreen))));
    await t.pump(const Duration(milliseconds: 600));
    final edit = find.byKey(const Key('agent-escalate-edit-claude-backend'));
    await t.ensureVisible(edit);
    await t.pump();
    await t.tap(edit);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('escalate-to-owner')), findsOneWidget);
    expect(find.byKey(const Key('escalate-to-Emily Carter')), findsNothing, reason: 'not among its links');
    await t.tap(find.byKey(const Key('escalate-to-Jordan Lee')));
    await t.pump();
    await t.enterText(find.byType(TextField).last, d.password);
    await t.tap(find.byKey(const Key('escalate-save')));
    await t.pump(const Duration(milliseconds: 400));
    expect(d.escalateSet, {'claude-backend': 'Jordan Lee'});
  });

  testWidgets('an older daemon without questions: nothing shown, no setting', (t) async {
    final (m, _) = await _model(questions: null);
    await _app(t, m);
    expect(m.questionsSupported, isFalse);
    expect(find.text(en.questionsTitle), findsNothing);
    expect(find.byKey(const Key('approvals-banner')), findsNothing);
  });
}
