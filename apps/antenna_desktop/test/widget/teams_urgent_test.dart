// SPDX-License-Identifier: AGPL-3.0-only
// "Urgent: interrupt the worker now" in a task's review (CONTROL §33, experimental) on the fake daemon: the switch
// sends `urgent: true` with `verdict: changes` and turns itself off; while it is on, changes can also be asked of a
// task its worker is working on; without it a request for changes carries no `urgent`; a blocked task's Answer has no
// switch.

import 'package:antenna_desktop/l10n/l10n.dart';
import 'package:antenna_desktop/protocol/x_control.dart';
import 'package:antenna_desktop/state/app_model.dart';
import 'package:antenna_desktop/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_daemon.dart';
import '../support/fake_teams.dart';
import '../support/fixtures.dart';

final en = l10nFor('en');

Future<(AppModel, FakeDaemon)> _model() async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory())
    ..teamsEnabled = true
    ..agentList = [const AgentInfo(name: 'claude', createdMs: 0, localLevel: 5)];
  d.addTeam(demoTeam());
  final m = AppModel(connector: (_) => d, socketPath: d.socketPath, live: false, clock: () => fixedNow);
  await m.connect();
  return (m, d);
}

Future<void> _pump(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await _pump(t);
}

Future<void> _open(WidgetTester t, AppModel m, int task) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(XApp(model: m));
  await _pump(t);
  await _tap(t, find.byKey(const Key('nav-teams')));
  await _tap(t, find.byKey(const Key('team-open-web')));
  await _tap(t, find.byKey(Key('task-open-${demoTask(task, title: '').id.substring(0, 6)}')));
}

List<Map<String, Object?>> _reviews(FakeDaemon d) => [for (final (c, f) in d.teamCalls) if (c == 'task_review') f];

void main() {
  testWidgets('a task being worked on: changes only as urgent; they go with urgent: true and the switch resets',
      (t) async {
    final (m, d) = await _model();
    await _open(t, m, 3);
    expect(find.byKey(const Key('task-urgent')), findsOneWidget);
    expect(find.text(en.taskUrgent), findsOneWidget);
    expect(find.byKey(const Key('experimental-task-urgent')), findsOneWidget);
    expect(find.byKey(const Key('task-changes')), findsNothing, reason: 'a working task gets changes only urgently');
    await _tap(t, find.byKey(const Key('task-urgent')));
    await _tap(t, find.byKey(const Key('task-changes')));
    await t.enterText(find.byKey(const Key('task-comment')), 'Stop: the parser must keep ISO weeks, not US ones.');
    await _tap(t, find.byKey(const Key('task-send-comment')));
    final id = demoTask(3, title: '').id;
    expect(_reviews(d).last, {
      'id': id,
      'verdict': TaskVerdict.changes,
      'comments': 'Stop: the parser must keep ISO weeks, not US ones.',
      'urgent': true,
    });
    expect(m.task(id)!.state, TaskState.returned);
    expect(t.widget<Switch>(find.byKey(const Key('task-urgent'))).value, isFalse, reason: 'for one request');
  });

  testWidgets('a submitted result: Request changes without the switch carries no urgent; with it, urgent: true',
      (t) async {
    final (m, d) = await _model();
    await _open(t, m, 4);
    await _tap(t, find.byKey(const Key('task-changes')));
    expect(find.byKey(const Key('task-urgent')), findsOneWidget, reason: 'the switch stays next to the comment');
    await t.enterText(find.byKey(const Key('task-comment')), 'Evict on logout too.');
    await _tap(t, find.byKey(const Key('task-send-comment')));
    expect(_reviews(d).last.containsKey('urgent'), isFalse);

    d.addTeam(demoTeam());
    await m.refreshTeam('web');
    await _pump(t);
    await _tap(t, find.byKey(const Key('task-changes')));
    await _tap(t, find.byKey(const Key('task-urgent')));
    await t.enterText(find.byKey(const Key('task-comment')), 'Evict on logout too, now.');
    await _tap(t, find.byKey(const Key('task-send-comment')));
    expect(_reviews(d).last['urgent'], true);
  });

  testWidgets('Accept and a blocked task\'s Answer never carry urgent; Answer has no switch', (t) async {
    final (m, d) = await _model();
    await _open(t, m, 4);
    expect(find.byKey(const Key('task-urgent')), findsNothing, reason: 'for a result under review: with the comment');
    // On in the comment box, then the box closed and the result accepted: no urgent.
    await _tap(t, find.byKey(const Key('task-changes')));
    await _tap(t, find.byKey(const Key('task-urgent')));
    await _tap(t, find.text(en.commonCancel).last);
    await _tap(t, find.byKey(const Key('task-accept')));
    expect(_reviews(d).last, {'id': demoTask(4, title: '').id, 'verdict': TaskVerdict.accept});
    await t.tapAt(const Offset(4, 4));
    await _pump(t);
    await _tap(t, find.byKey(Key('task-open-${demoTask(5, title: '').id.substring(0, 6)}')));
    expect(find.byKey(const Key('task-urgent')), findsNothing);
    await _tap(t, find.byKey(const Key('task-answer')));
    expect(find.byKey(const Key('task-urgent')), findsNothing);
  });
}
